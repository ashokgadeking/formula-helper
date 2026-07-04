import XCTest
@testable import FormulaHelperWatch

final class SessionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: SessionStore!
    private let host = URL(string: APIClient.baseURL)!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SessionStoreTests")!
        defaults.removePersistentDomain(forName: "SessionStoreTests")
        store = SessionStore(defaults: defaults, cookieStorage: .shared)
        clearSessionCookies()
    }

    override func tearDown() {
        clearSessionCookies()
        defaults.removePersistentDomain(forName: "SessionStoreTests")
        super.tearDown()
    }

    private func clearSessionCookies() {
        for c in HTTPCookieStorage.shared.cookies(for: host) ?? [] where c.name == "session" {
            HTTPCookieStorage.shared.deleteCookie(c)
        }
    }

    private func sessionCookie() -> HTTPCookie? {
        HTTPCookieStorage.shared.cookies(for: host)?.first { $0.name == "session" }
    }

    func testUpdatePersistsTokenAndInstallsCookie() {
        store.update(token: "tok123")
        XCTAssertEqual(store.token, "tok123")
        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(sessionCookie()?.value, "tok123")
        XCTAssertEqual(sessionCookie()?.domain, host.host)
    }

    func testUpdateReplacesExistingCookie() {
        store.update(token: "old")
        store.update(token: "new")
        let sessions = HTTPCookieStorage.shared.cookies(for: host)?.filter { $0.name == "session" }
        XCTAssertEqual(sessions?.count, 1)
        XCTAssertEqual(sessions?.first?.value, "new")
    }

    func testClearRemovesTokenAndCookie() {
        store.update(token: "tok123")
        store.clear()
        XCTAssertNil(store.token)
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(sessionCookie())
    }

    func testInstallCookieWithoutTokenDoesNothing() {
        store.installCookie()
        XCTAssertNil(sessionCookie())
    }

    func testInstallCookieRestoresFromPersistedToken() {
        defaults.set("persisted", forKey: "sessionToken")
        store.installCookie()
        XCTAssertEqual(sessionCookie()?.value, "persisted")
    }
}
