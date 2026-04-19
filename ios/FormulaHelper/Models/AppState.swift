import Foundation

// MARK: - State response from GET /api/state

struct AppStateResponse: Codable {
    let countdown_end: Double
    let mixed_at_str: String
    let mixed_ml: Int
    let remaining_secs: Double
    let expired: Bool
    let ntfy_sent: Bool
    let mix_log: [LogEntry]
    let settings: AppSettings
    let combos: [[Double]]
    let powder_per_60: Double
    let weight_log: [WeightEntry]
    let diaper_log: [DiaperEntry]
}

struct LogEntry: Codable, Identifiable {
    let sk: String
    let text: String
    let leftover: String
    let ml: Int
    let date: String
    let created_by: String

    var id: String { sk }

    /// ml actually consumed (total minus leftover)
    var consumedMl: Int {
        let lo = Int(leftover.filter(\.isNumber)) ?? 0
        return max(0, ml - lo)
    }
}

struct DiaperEntry: Codable, Identifiable {
    let sk: String
    let type: String   // "pee" | "poo"
    let date: String
    let created_by: String

    var id: String { sk }
}

struct AppSettings: Codable {
    let countdown_secs: Int
    let ss_timeout_min: Int
}

struct WeightEntry: Codable {
    let date: String
    let lbs: Double
}

// MARK: - Auth

struct AuthStatusResponse: Codable {
    let authenticated: Bool
    let registered: Bool
    let user_name: String
}

struct LoginVerifyResponse: Codable {
    let ok: Bool
    let user_name: String
}

struct RegisterVerifyResponse: Codable {
    let ok: Bool
    let user_name: String?
}

// MARK: - Write responses

struct OkResponse: Codable {
    let ok: Bool
    let sk: String?
}

// MARK: - Cached state (stored in App Group UserDefaults)

struct CachedState: Codable {
    var state: AppStateResponse
    var fetchedAt: Double   // Unix timestamp
}
