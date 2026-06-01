import Foundation

/// Per-scale tracker that consumes weight readings and emits a "log this bottle"
/// decision when the user's mixing workflow completes.
///
/// Assumption (verified with the user 2026-05-31): the scale auto-tares to 0 g
/// every time it's powered on with the bottle + water already sitting on it,
/// so we don't need a dynamic baseline — the formula grams added equal the
/// peak weight ever seen during this session.
///
/// Workflow:
///   - scale powers on → BLE starts streaming ≈ 0 g
///   - user pours powder → weight climbs to ≈ 16 g (for a 120 ml bottle)
///   - user lifts bottle → weight drops well below 0 g (tare-negative)
///   → we log peak × 60 / powder_per_60 ml
@MainActor
final class BookooSession {
    enum Phase: Equatable {
        case ready                                  // peak <= 3, waiting for powder
        case tracking(peak: Double)                 // peak > 3, accumulating
        case lifting(trough: Double, since: Date)   // bottle coming off, settling
        case logged(at: Date)                       // cooldown — ignore everything
    }

    private let measureFloor: Double = 3.0    // peak grams needed before a log can fire
    private let liftThreshold: Double = -5.0  // weight below this = bottle lifted
    private let liftSettleWindow: TimeInterval = 1.2  // collect the trough this long
    private let cooldown: TimeInterval = 60.0
    private let mlFloor = 30
    private let mlCeiling = 300
    // EMA weight on the incoming sample. α = 0.35 cleans up single-sample
    // mechanical spikes (scoop hitting the bottle, transient overshoot) while
    // keeping the response fast enough that a real pour still tracks within a
    // few samples and the lift detection trips on the first negative reading.
    private let smoothingAlpha: Double = 0.35

    let peripheralID: UUID
    private(set) var phase: Phase = .ready
    private(set) var peak: Double = 0
    private var smoothedWeight: Double = 0
    private var smoothedSeeded = false

    var onLog: ((_ ml: Int, _ measuredGrams: Double, _ liftMagnitudeG: Double, _ peripheralID: UUID) -> Void)?

    init(peripheralID: UUID) {
        self.peripheralID = peripheralID
    }

    func ingest(_ reading: BookooReading) {
        let now = Date()
        let w = reading.weightG

        // Cooldown: silently ignore readings for 60 s after a log, so the
        // post-log "put the bottle back briefly" gesture doesn't re-trigger.
        if case .logged(let at) = phase {
            if now.timeIntervalSince(at) < cooldown { return }
            phase = .ready
            peak = 0
            smoothedWeight = 0
            smoothedSeeded = false
        }

        // Once a lift is underway, keep collecting the trough (most-negative
        // reading) for a short window so we use the SETTLED -(bottle+water)
        // value for calibration, not the transient first-negative sample caught
        // mid-sweep. Fire once the window elapses.
        if case .lifting(let trough, let since) = phase {
            let newTrough = min(trough, w)
            if now.timeIntervalSince(since) >= liftSettleWindow {
                fireLog(addedGrams: peak, liftMagnitudeG: abs(newTrough), at: now)
            } else {
                phase = .lifting(trough: newTrough, since: since)
            }
            return
        }

        // EMA smoothing damps single-sample mechanical spikes (scoop bump,
        // brief overshoot) before they latch onto the peak. Seed on first
        // reading so we don't ramp from 0.
        if !smoothedSeeded {
            smoothedWeight = w
            smoothedSeeded = true
        } else {
            smoothedWeight = smoothingAlpha * w + (1 - smoothingAlpha) * smoothedWeight
        }
        let s = smoothedWeight

        // Track max smoothed weight ever seen this session.
        if s > peak { peak = s }
        if peak >= measureFloor {
            phase = .tracking(peak: peak)
        }

        // Lift onset — bottle off scale drives a sharp negative reading. Use
        // the raw `w` (not smoothed) so it trips on the first negative sample.
        // Enter the settling window rather than firing immediately.
        if w < liftThreshold && peak >= measureFloor {
            phase = .lifting(trough: w, since: now)
        }
    }

    private func fireLog(addedGrams: Double, liftMagnitudeG: Double, at now: Date) {
        let powderPer60 = CacheManager.shared.restore()?.powder_per_60 ?? 8.3

        // Candidate 1 — global bottle calibration: water_ml = settled lift
        // magnitude − dry bottle. A real measurement when it lands in range.
        let dry = BookooPairingStore.loadDryBottleWeight()
        let calibrated: Double? = {
            guard let dry, dry > 0, liftMagnitudeG > dry else { return nil }
            return liftMagnitudeG - dry
        }()

        // Candidate 2 — formula fallback from the powder peak. Always available
        // and doesn't depend on the noisy lift magnitude.
        let formula: Double? = powderPer60 > 0 ? addedGrams * 60.0 / powderPer60 : nil

        // Prefer calibration, but only if it rounds in range; otherwise fall
        // back to formula. Reset (no log) only if neither is usable.
        func roundedInRange(_ ml: Double?) -> Int? {
            guard let ml else { return nil }
            let r = Int((ml / 10.0).rounded()) * 10
            return (r >= mlFloor && r <= mlCeiling) ? r : nil
        }

        guard let rounded = roundedInRange(calibrated) ?? roundedInRange(formula) else {
            // Nothing usable — reset and wait for the next prep.
            phase = .logged(at: now); peak = 0
            smoothedWeight = 0; smoothedSeeded = false
            return
        }

        phase = .logged(at: now)
        let measured = addedGrams
        peak = 0
        smoothedWeight = 0
        smoothedSeeded = false
        onLog?(rounded, measured, liftMagnitudeG, peripheralID)
    }
}
