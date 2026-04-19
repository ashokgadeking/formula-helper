import ActivityKit
import Foundation

struct FormulaActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var countdownEnd: Date
        var countdownStart: Date   // for progress bar + "mixed at" display
        var lastMl: Int
    }
}
