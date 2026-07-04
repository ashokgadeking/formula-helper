import Foundation

extension Notification.Name {
    static let sessionDidChange = Notification.Name("sessionDidChange")
}

/// Persists the session token relayed from the iPhone and installs it as the
/// `session` cookie so APIClient's URLSession attaches it automatically.
final class SessionStore: @unchecked Sendable {
    static let shared = SessionStore()

    private static let tokenKey = "sessionToken"
    private let defaults: UserDefaults
    private let cookieStorage: HTTPCookieStorage

    init(defaults: UserDefaults = .standard, cookieStorage: HTTPCookieStorage = .shared) {
        self.defaults = defaults
        self.cookieStorage = cookieStorage
    }

    var token: String? { defaults.string(forKey: Self.tokenKey) }
    var isSignedIn: Bool { token != nil }

    func update(token: String) {
        defaults.set(token, forKey: Self.tokenKey)
        installCookie()
        NotificationCenter.default.post(name: .sessionDidChange, object: nil)
    }

    func clear() {
        defaults.removeObject(forKey: Self.tokenKey)
        deleteSessionCookies()
        NotificationCenter.default.post(name: .sessionDidChange, object: nil)
    }

    /// Idempotent; called at launch and after every token update.
    func installCookie() {
        guard let token,
              let url = URL(string: APIClient.baseURL),
              let host = url.host,
              let cookie = HTTPCookie(properties: [
                  .name: "session",
                  .value: token,
                  .domain: host,
                  .path: "/",
                  .secure: "TRUE",
                  // Backend sessions live 30 days; the phone re-relays fresh
                  // tokens, so an optimistic far-future expiry here is fine.
                  .expires: Date().addingTimeInterval(30 * 24 * 3600),
              ])
        else { return }
        cookieStorage.setCookie(cookie)
    }

    private func deleteSessionCookies() {
        guard let url = URL(string: APIClient.baseURL) else { return }
        for c in cookieStorage.cookies(for: url) ?? [] where c.name == "session" {
            cookieStorage.deleteCookie(c)
        }
    }
}
