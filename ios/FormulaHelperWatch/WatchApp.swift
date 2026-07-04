import SwiftUI

@main
struct FormulaHelperWatchApp: App {
    init() {
        SessionStore.shared.installCookie()
        SessionSync.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            Text("AvantiLog")
        }
    }
}
