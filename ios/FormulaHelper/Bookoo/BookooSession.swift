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
        case ready                        // peak <= 3, waiting for powder
        case tracking(peak: Double)       // peak > 3, accumulating
        case logged(at: Date)             // cooldown — ignore everything
    }

    private let measureFloor: Double = 3.0    // peak grams needed before a log can fire
    private let liftThreshold: Double = -5.0  // weight below this = bottle lifted
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

        // Lift detected — bottle off scale drives a sharp negative reading.
        // Use the raw `w` (not smoothed) so the lift fires on the first
        // negative sample rather than waiting for the EMA to chase it down.
        if w < liftThreshold && peak >= measureFloor {
            fireLog(addedGrams: peak, liftMagnitudeG: abs(w), at: now)
        }
    }

    private func fireLog(addedGrams: Double, liftMagnitudeG: Double, at now: Date) {
        let cached = CacheManager.shared.restore()
        let powderPer60 = cached?.powder_per_60 ?? 8.3
        // Global bottle calibration: if the user has captured a dry-bottle
        // weight, compute water_ml = liftMagnitude − dry. That's a real
        // measurement instead of the formula-derived guess. Shared across all
        // scales since the user mixes in the same bottles.
        let dry = BookooPairingStore.loadDryBottleWeight()
        let waterMl: Double
        if let dry, dry > 0, liftMagnitudeG > dry {
            waterMl = liftMagnitudeG - dry
        } else {
            guard powderPer60 > 0 else {
                phase = .logged(at: now); peak = 0
                return
            }
            waterMl = addedGrams * 60.0 / powderPer60
        }
        let rounded = Int((waterMl / 10.0).rounded()) * 10
        guard rounded >= mlFloor, rounded <= mlCeiling else {
            phase = .logged(at: now); peak = 0
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
