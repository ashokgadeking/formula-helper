import Foundation

// MARK: - Errors

enum APIError: LocalizedError {
    case badStatus(Int, String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .badStatus(let code, let msg): return "Server error \(code): \(msg)"
        case .decodingFailed(let msg): return "Decode error: \(msg)"
        }
    }
}

// MARK: - Client

actor APIClient {
    static let shared = APIClient()

    static let baseURL: String = {
        #if DEV_STACK
        return "https://3lgqmzurih.execute-api.us-east-1.amazonaws.com"
        #else
        return "https://d20oyc88hlibbe.cloudfront.net"
        #endif
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

    /// Returns raw JSON data so AuthManager can extract the challenge bytes
    func loginOptions() async throws -> Data {
        try await postRaw("/api/auth/login-options", body: [:])
    }

    func loginVerify(_ body: [String: Any]) async throws -> LoginVerifyResponse {
        try await post("/api/auth/login-verify", body: body)
    }

    /// Returns raw JSON data (challenge + user info needed for registration request)
    func registerOptions() async throws -> Data {
        try await postRaw("/api/auth/register-options", body: [:])
    }

    func registerVerify(_ body: [String: Any]) async throws -> RegisterVerifyResponse {
        try await post("/api/auth/register-verify", body: body)
    }

    // MARK: - Feeding

    func startFeeding(ml: Int) async throws -> OkResponse {
        try await post("/api/start", body: ["ml": ml])
    }

    func logEntry(ml: Int, date: String? = nil) async throws -> OkResponse {
        var body: [String: Any] = ["ml": ml]
        if let date { body["date"] = date }
        return try await post("/api/log", body: body)
    }

    func updateEntry(sk: String, text: String? = nil, leftover: String? = nil, ml: Int? = nil, date: String? = nil) async throws {
        var body: [String: Any] = [:]
        if let text { body["text"] = text }
        if let leftover { body["leftover"] = leftover }
        if let ml { body["ml"] = ml }
        if let date { body["date"] = date }
        let encoded = encodePathComponent(sk)
        let _: OkResponse = try await put("/api/log/\(encoded)", body: body)
    }

    func deleteEntry(sk: String) async throws {
        let encoded = encodePathComponent(sk)
        try await delete("/api/log/\(encoded)")
    }

    // MARK: - Diaper

    func logDiaper(type: String, date: String? = nil) async throws {
        var body: [String: Any] = ["type": type]
        if let date { body["date"] = date }
        let _: OkResponse = try await post("/api/diaper", body: body)
    }

    func deleteDiaper(sk: String) async throws {
        let encoded = encodePathComponent(sk)
        try await delete("/api/diaper/\(encoded)")
    }

    func updateDiaper(sk: String, date: String) async throws {
        let encoded = encodePathComponent(sk)
        let _: OkResponse = try await put("/api/diaper/\(encoded)", body: ["date": date])
    }

    // MARK: - Nap

    func logNap(date: String? = nil, durationMins: Int? = nil) async throws {
        var body: [String: Any] = [:]
        if let date { body["date"] = date }
        if let durationMins { body["duration_mins"] = durationMins }
        let _: OkResponse = try await post("/api/nap", body: body)
    }

    func deleteNap(sk: String) async throws {
        let encoded = encodePathComponent(sk)
        try await delete("/api/nap/\(encoded)")
    }

    func updateNap(sk: String, date: String? = nil, durationMins: Int? = nil) async throws {
        var body: [String: Any] = [:]
        if let date { body["date"] = date }
        if let durationMins { body["duration_mins"] = durationMins }
        let encoded = encodePathComponent(sk)
        let _: OkResponse = try await put("/api/nap/\(encoded)", body: body)
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

    // MARK: - User management (ashok only)

    func listAllowedUsers() async throws -> [String] {
        struct R: Codable { let allowed_users: [String] }
        let r: R = try await get("/api/auth/allowed-users")
        return r.allowed_users
    }

    func addAllowedUser(name: String) async throws {
        let _: OkResponse = try await post("/api/auth/allowed-users", body: ["name": name])
    }

    func removeAllowedUser(name: String) async throws {
        let encoded = encodePathComponent(name)
        try await delete("/api/auth/allowed-users/\(encoded)")
    }

    struct Credential: Codable, Identifiable {
        let cred_id: String
        let user_name: String
        let created: String
        var id: String { cred_id }
    }

    func listCredentials() async throws -> [Credential] {
        struct R: Codable { let credentials: [Credential] }
        let r: R = try await get("/api/auth/credentials")
        return r.credentials
    }

    func deleteCredential(credId: String) async throws {
        let encoded = encodePathComponent(credId)
        try await delete("/api/auth/credentials/\(encoded)")
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
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            throw APIError.badStatus(http.statusCode, msg)
        }
    }

    private func url(_ path: String) -> URL {
        URL(string: Self.baseURL + path)!
    }

    private func encodePathComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}
