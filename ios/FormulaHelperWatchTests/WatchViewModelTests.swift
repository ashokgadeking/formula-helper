import XCTest
@testable import FormulaHelperWatch

final class WatchViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: SessionStore!
    private let host = URL(string: APIClient.baseURL)!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "WatchViewModelTests")!
        defaults.removePersistentDomain(forName: "WatchViewModelTests")
        store = SessionStore(defaults: defaults, cookieStorage: .shared)
        clearSessionCookies()
    }

    override func tearDown() {
        clearSessionCookies()
        defaults.removePersistentDomain(forName: "WatchViewModelTests")
        super.tearDown()
    }

    private func clearSessionCookies() {
        for c in HTTPCookieStorage.shared.cookies(for: host) ?? [] where c.name == "session" {
            HTTPCookieStorage.shared.deleteCookie(c)
        }
    }

    @MainActor
    func testBadStatus401ClearsSessionAndSignsOut() {
        store.update(token: "tok")
        let vm = WatchViewModel(store: store)

        vm.handle(APIError.badStatus(401, "Unauthorized"))

        XCTAssertNil(store.token)
        XCTAssertFalse(vm.signedIn)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor
    func testOtherErrorSetsMessageAndKeepsSession() {
        store.update(token: "tok")
        let vm = WatchViewModel(store: store)

        vm.handle(APIError.badStatus(500, "boom"))

        XCTAssertEqual(store.token, "tok")
        XCTAssertTrue(vm.signedIn)
        XCTAssertNotNil(vm.errorMessage)
    }
}
