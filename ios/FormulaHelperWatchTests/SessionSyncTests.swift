import XCTest
@testable import FormulaHelperWatch

final class SessionSyncTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: SessionStore!
    private let host = URL(string: APIClient.baseURL)!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SessionSyncTests")!
        defaults.removePersistentDomain(forName: "SessionSyncTests")
        store = SessionStore(defaults: defaults, cookieStorage: .shared)
        clearSessionCookies()
    }

    override func tearDown() {
        clearSessionCookies()
        defaults.removePersistentDomain(forName: "SessionSyncTests")
        super.tearDown()
    }

    private func clearSessionCookies() {
        for c in HTTPCookieStorage.shared.cookies(for: host) ?? [] where c.name == "session" {
            HTTPCookieStorage.shared.deleteCookie(c)
        }
    }

    func testHandleContextStoresToken() {
        SessionSync.handle(context: ["sessionToken": "abc"], store: store)
        XCTAssertEqual(store.token, "abc")
    }

    func testHandleContextIgnoresMissingOrEmptyToken() {
        SessionSync.handle(context: [:], store: store)
        XCTAssertNil(store.token)
        SessionSync.handle(context: ["sessionToken": ""], store: store)
        XCTAssertNil(store.token)
    }

    func testHandleContextIgnoresNonStringToken() {
        SessionSync.handle(context: ["sessionToken": 42], store: store)
        XCTAssertNil(store.token)
    }
}
