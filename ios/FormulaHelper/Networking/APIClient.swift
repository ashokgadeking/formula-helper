import Foundation

// MARK: - Errors

enum APIError: LocalizedError {
    case badStatus(Int, String)
    case decodingFailed(String)
    /// 412 from `POST /api/auth/siwa` — caller must collect setup details and retry.
    case setupRequired(needs: [String])

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let msg): return "Server error \(code): \(msg)"
        case .decodingFailed(let msg): return "Decode error: \(msg)"
        case .setupRequired:                return "Setup required to finish signing up."
        }
    }
}

// MARK: - Client

actor APIClient {
    static let shared = APIClient()

    static let baseURL: String = {
        Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String ?? ""
    }()

    /// RP ID used by ASAuthorizationPlatformPublicKeyCredentialProvider. Sourced from Info.plist (per-config build setting).
    static let rpId: String = {
        Bundle.main.object(forInfoDictionaryKey: "RPID") as? String ?? ""
    }()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.httpCookieStorage = .shared
        session = URLSession(configuration: config)
    }

    // MARK: - State

    func getState() async throws -> AppStateResponse {
        try await get("/api/state")
    }

    // MARK: - Auth

    func authStatus() async throws -> AuthStatusResponse {
        try await get("/api/auth/status")
    }

    /// Single SIWA endpoint. On 412 throws `APIError.setupRequired(needs:)`; the caller should
    /// present setup UI and re-call with the same `idToken` plus `userName` and either
    /// `householdName` or `inviteToken`.
    func siwaAuth(
        idToken: String,
        userName: String?,
        householdName: String?,
        childName: String?,
        childDob: String?,
        inviteToken: String?
    ) async throws -> SiwaAuthResponse {
        var body: [String: Any] = ["siwa_id_token": idToken]
        if let v = userName,      !v.isEmpty { body["user_name"]      = v }
        if let v = householdName, !v.isEmpty { body["household_name"] = v }
        if let v = childName,     !v.isEmpty { body["child_name"]     = v }
        if let v = childDob,      !v.isEmpty { body["child_dob"]      = v }
        if let v = inviteToken,   !v.isEmpty { body["invite_token"]   = v }
        return try await post("/api/auth/siwa", body: body)
    }

    func logout() async throws {
        let _: OkResponse = try await post("/api/auth/logout", body: [:])
    }

    func devLogin() async throws -> AuthOkResponse {
        try await post("/api/auth/dev-login", body: [:])
    }

    // MARK: - Households

    func listHouseholds() async throws -> HouseholdsListResponse {
        try await get("/api/households")
    }

    func createHousehold(name: String) async throws -> OkResponse {
        try await post("/api/households", body: ["name": name])
    }

    func switchHousehold(hhId: String) async throws -> OkResponse {
        try await post("/api/households/switch", body: ["hh_id": hhId])
    }

    func leaveHousehold(hhId: String) async throws -> OkResponse {
        try await post("/api/households/\(encodePathComponent(hhId))/leave", body: [:])
    }

    func deleteHousehold(hhId: String) async throws {
        try await delete("/api/households/\(encodePathComponent(hhId))")
    }

    func listMembers(hhId: String) async throws -> HouseholdMembersResponse {
        try await get("/api/households/\(encodePathComponent(hhId))/members")
    }

    func kickMember(hhId: String, userId: String) async throws {
        try await delete("/api/households/\(encodePathComponent(hhId))/members/\(encodePathComponent(userId))")
    }

    func updateMemberRole(hhId: String, userId: String, role: String) async throws {
        let _: OkResponse = try await put(
            "/api/households/\(encodePathComponent(hhId))/members/\(encodePathComponent(userId))",
            body: ["role": role]
        )
    }

    // MARK: - Invites

    func previewInvite(token: String) async throws -> InvitePreview {
        try await get("/api/invites/\(encodePathComponent(token))")
    }

    func createInvite() async throws -> InviteCreateResponse {
        try await post("/api/invites", body: [:])
    }

    func redeemInvite(token: String) async throws -> InviteRedeemResponse {
        try await post("/api/invites/\(encodePathComponent(token))/redeem", body: [:])
    }

    // MARK: - Feeding

    func startFeeding(ml: Int) async throws -> OkResponse {
        try await post("/api/start", body: ["ml": ml])
    }

    func logEntry(ml: Int, date: String? = nil) async throws -> OkResponse {
        var body: [String: Any] = ["ml": ml]
        if let date { body["date"] = date }
        return try await post("/api/feedings", body: body)
    }

    func updateEntry(sk: String, text: String? = nil, leftover: String? = nil, ml: Int? = nil, date: String? = nil) async throws {
        var body: [String: Any] = [:]
        if let text { body["text"] = text }
        if let leftover { body["leftover"] = leftover }
        if let ml { body["ml"] = ml }
        if let date { body["date"] = date }
        let encoded = encodePathComponent(sk)
        let _: OkResponse = try await put("/api/feedings/\(encoded)", body: body)
    }

    func deleteEntry(sk: String) async throws {
        let encoded = encodePathComponent(sk)
        try await delete("/api/feedings/\(encoded)")
    }

    // MARK: - Diaper

    func logDiaper(type: String, date: String? = nil) async throws {
        var body: [String: Any] = ["type": type]
        if let date { body["date"] = date }
        let _: OkResponse = try await post("/api/diapers", body: body)
    }

    func deleteDiaper(sk: String) async throws {
        let encoded = encodePathComponent(sk)
        try await delete("/api/diapers/\(encoded)")
    }

    func updateDiaper(sk: String, date: String) async throws {
        let encoded = encodePathComponent(sk)
        let _: OkResponse = try await put("/api/diapers/\(encoded)", body: ["date": date])
    }

    // MARK: - Nap

    func logNap(date: String? = nil, durationMins: Int? = nil) async throws {
        var body: [String: Any] = [:]
        if let date { body["date"] = date }
        if let durationMins { body["duration_mins"] = durationMins }
        let _: OkResponse = try await post("/api/naps", body: body)
    }

    func deleteNap(sk: String) async throws {
        let encoded = encodePathComponent(sk)
        try await delete("/api/naps/\(encoded)")
    }

    func updateNap(sk: String, date: String? = nil, durationMins: Int? = nil) async throws {
        var body: [String: Any] = [:]
        if let date { body["date"] = date }
        if let durationMins { body["duration_mins"] = durationMins }
        let encoded = encodePathComponent(sk)
        let _: OkResponse = try await put("/api/naps/\(encoded)", body: body)
    }

    // MARK: - Timer

    func resetTimer() async throws {
        let _: OkResponse = try await post("/api/reset-timer", body: [:])
    }

    // MARK: - Settings

    func saveSettings(countdownSecs: Int) async throws {
        let _: OkResponse = try await post("/api/settings", body: ["countdown_secs": countdownSecs])
    }

    func savePresets(preset1: Int, preset2: Int) async throws {
        let _: OkResponse = try await post("/api/settings", body: [
            "preset1_ml": preset1,
            "preset2_ml": preset2,
        ])
    }

    // MARK: - Private HTTP helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: url(path))
        req.httpMethod = "GET"
        return try await execute(req)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await execute(req)
    }

    private func postRaw(_ path: String, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        try checkStatus(response, data)
        return data
    }

    private func put<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: url(path))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await execute(req)
    }

    private func delete(_ path: String) async throws {
        var req = URLRequest(url: url(path))
        req.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: req)
        try checkStatus(response, data)
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try checkStatus(response, data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingFailed(error.localizedDescription)
        }
    }

    private func checkStatus(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            // 412 from /auth/siwa is expected first-time-no-setup signaling — surface
            // it as a typed error so callers can pattern-match without parsing strings.
            if http.statusCode == 412 {
                let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let needs = (parsed?["needs"] as? [String]) ?? []
                throw APIError.setupRequired(needs: needs)
            }
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.badStatus(http.statusCode, msg)
        }
    }

    private func url(_ path: String) -> URL {
        URL(string: Self.baseURL + path)!
    }

    private nonisolated func encodePathComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}
