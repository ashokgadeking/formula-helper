import Foundation

/// Reads and writes the cached app state to the App Group UserDefaults.
/// Widgets and the Live Activity extension share this same storage.
final class CacheManager: @unchecked Sendable {
    static let shared = CacheManager()

    // Update this to match your actual App Group ID after Xcode project setup
    private let groupID = "group.com.ashokteja.formulahelper"
    private let stateKey = "fh_cached_state"

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: groupID)
    }

    // MARK: - Save

    func save(_ state: AppStateResponse) {
        let cached = CachedState(state: state, fetchedAt: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        defaults?.set(data, forKey: stateKey)
    }

    // MARK: - Restore

    /// Returns the cached state with `remaining_secs` adjusted for elapsed time since fetch.
    func restore() -> AppStateResponse? {
        guard let data = defaults?.data(forKey: stateKey),
              var cached = try? JSONDecoder().decode(CachedState.self, from: data)
        else { return nil }

        let elapsed = Date().timeIntervalSince1970 - cached.fetchedAt
        if elapsed < 0 || elapsed > 3600 { return nil }   // stale beyond 1h — skip

        // Adjust remaining_secs
        if cached.state.remaining_secs > 0 {
            let adjusted = max(0, cached.state.remaining_secs - elapsed)
            cached = CachedState(
                state: AppStateResponse(
                    countdown_end:  cached.state.countdown_end,
                    mixed_at_str:   cached.state.mixed_at_str,
                    mixed_ml:       cached.state.mixed_ml,
                    remaining_secs: adjusted,
                    expired:        adjusted <= 0,
                    ntfy_sent:      cached.state.ntfy_sent,
                    mix_log:        cached.state.mix_log,
                    settings:       cached.state.settings,
                    combos:         cached.state.combos,
                    powder_per_60:  cached.state.powder_per_60,
                    weight_log:     cached.state.weight_log,
                    diaper_log:     cached.state.diaper_log
                ),
                fetchedAt: cached.fetchedAt
            )
        }

        return cached.state
    }

    func clear() {
        defaults?.removeObject(forKey: stateKey)
    }
}
