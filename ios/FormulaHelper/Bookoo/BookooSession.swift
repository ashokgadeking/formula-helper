import Foundation

/// Per-scale state machine that consumes weight readings and emits a single
/// "log this bottle" decision when the user's mixing workflow completes.
///
/// Workflow detected: scale powers on with bottle+water → auto-tares to 0g →
/// user pours powder → weight settles at a stable peak → user lifts bottle →
/// weight drops sharply → we log.
@MainActor
final class BookooSession {
    enum Phase: Equatable {
        case idle
        case tared(since: Date)
        case measuring(peak: Double)
        case stable(peak: Double, since: Date)
        case logged(at: Date)
    }

    // Thresholds — hardcoded for v1, tune from real usage per Open Question 4
    // in the story.
    private let tareEpsilon: Double = 0.5     // |g| <= this → "tared"
    private let tareDwell: TimeInterval = 0.5 // must hold tare this long
    private let measureFloor: Double = 3.0    // grams to enter measuring
    private let stableEpsilon: Double = 0.2   // peak ± this for "stable"
    private let stableDwell: TimeInterval = 2.0
    private let liftDropFraction: Double = 0.5
    private let liftMinGrams: Double = 1.0    // post-lift weight must be < this
    private let idleTimeout: TimeInterval = 90.0
    private let cooldown: TimeInterval = 60.0
    private let mlFloor = 30
    private let mlCeiling = 300

    let peripheralID: UUID
    private(set) var phase: Phase = .idle
    private var lastTransitionAt: Date = Date()
    /// onLog is called on the main actor when a valid lift is detected.
    var onLog: ((_ ml: Int, _ peripheralID: UUID) -> Void)?

    init(peripheralID: UUID) {
        self.peripheralID = peripheralID
    }

    func ingest(_ reading: BookooReading) {
        let now = Date()
        defer { trimIdle(now: now) }

        switch phase {
        case .idle:
            if abs(reading.weightG) <= tareEpsilon {
                transition(to: .tared(since: now), at: now)
            }

        case .tared(let since):
            if reading.weightG >= measureFloor {
                transition(to: .measuring(peak: reading.weightG), at: now)
            } else if abs(reading.weightG) > tareEpsilon * 4 {
                // Drifted far from zero without crossing the measure floor —
                // probably noise or bottle removed before powder added. Reset.
                transition(to: .idle, at: now)
            } else if now.timeIntervalSince(since) > idleTimeout {
                transition(to: .idle, at: now)
            }

        case .measuring(let peak):
            if reading.weightG > peak {
                phase = .measuring(peak: reading.weightG)
                lastTransitionAt = now
            } else if abs(reading.weightG - peak) <= stableEpsilon {
                transition(to: .stable(peak: peak, since: now), at: now)
            } else if reading.weightG < measureFloor {
                // User removed everything before stabilising.
                transition(to: .idle, at: now)
            }

        case .stable(let peak, let since):
            // Lift detected — single sharp drop. Fires the log.
            if reading.weightG < peak * (1 - liftDropFraction) || reading.weightG < liftMinGrams {
                fireLog(peak: peak, at: now)
            } else if abs(reading.weightG - peak) <= stableEpsilon {
                // Still stable — continue dwelling. (Keep `since` so an idle
                // sweep eventually triggers if user just sat there.)
                if now.timeIntervalSince(since) > idleTimeout {
                    transition(to: .idle, at: now)
                }
            } else if reading.weightG > peak + stableEpsilon {
                // User added more powder after stable — bump peak, drop back
                // to .measuring so we re-stabilise.
                transition(to: .measuring(peak: reading.weightG), at: now)
            }

        case .logged(let at):
            if now.timeIntervalSince(at) > cooldown {
                transition(to: .idle, at: now)
            }
        }
    }

    // MARK: - Internals

    private func transition(to next: Phase, at now: Date) {
        phase = next
        lastTransitionAt = now
    }

    private func trimIdle(now: Date) {
        if case .idle = phase { return }
        if case .logged = phase { return }
        if now.timeIntervalSince(lastTransitionAt) > idleTimeout {
            transition(to: .idle, at: now)
        }
    }

    private func fireLog(peak: Double, at now: Date) {
        let powderPer60 = CacheManager.shared.restore()?.powder_per_60 ?? 8.3
        guard powderPer60 > 0 else {
            transition(to: .idle, at: now)
            return
        }
        let raw = peak * 60.0 / powderPer60
        let rounded = Int((raw / 10.0).rounded()) * 10
        guard rounded >= mlFloor, rounded <= mlCeiling else {
            transition(to: .idle, at: now)
            return
        }
        transition(to: .logged(at: now), at: now)
        onLog?(rounded, peripheralID)
    }
}
