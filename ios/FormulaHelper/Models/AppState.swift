import Foundation

// MARK: - State response from GET /api/state

struct AppStateResponse: Codable {
    var countdown_end: Double
    var mixed_at_str: String
    var mixed_ml: Int
    var remaining_secs: Double
    var expired: Bool
    let ntfy_sent: Bool
    var mix_log: [LogEntry]
    let settings: AppSettings
    let combos: [[Double]]
    let powder_per_60: Double
    let weight_log: [WeightEntry]
    var diaper_log: [DiaperEntry]
    var nap_log: [NapEntry]?
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

struct NapEntry: Codable, Identifiable {
    let sk: String
    let date: String
    let created_by: String
    let duration_mins: Int?

    var id: String { sk }
}

struct AppSettings: Codable {
    let countdown_secs: Int
    let ss_timeout_min: Int
    let preset1_ml: Int?
    let preset2_ml: Int?
}

struct WeightEntry: Codable {
    let date: String
    let lbs: Double
}

// MARK: - Auth

struct AuthStatusResponse: Codable {
    let authenticated: Bool
    let user_id: String?
    let user_name: String?
    let active_hh: String?
}

struct AuthOkResponse: Codable {
    let ok: Bool
    let user_id: String?
    let active_hh: String?
}

/// Raw shape returned by register/start, login/options, recover/start
struct ChallengeEnvelope: Codable {
    let challenge_id: String
    // `options` is decoded separately as raw JSON for passing to ASAuthorization
}

struct Household: Codable, Identifiable {
    let hh_id: String
    let name: String
    let role: String

    var id: String { hh_id }
}

struct HouseholdsListResponse: Codable {
    let active_hh: String?
    let households: [Household]
}

struct HouseholdMember: Codable, Identifiable, Equatable {
    let user_id: String
    let name: String
    let role: String
    let joined_at: String?

    var id: String { user_id }
}

struct HouseholdMembersResponse: Codable {
    let members: [HouseholdMember]
}

struct InvitePreview: Codable {
    let hh_name: String
    let inviter_name: String
    let expires: Double
}

struct InviteCreateResponse: Codable {
    let token: String
    let expires: Double
    let hh_name: String
}

struct InviteRedeemResponse: Codable {
    let ok: Bool
    let hh_id: String?
    let hh_name: String?
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
