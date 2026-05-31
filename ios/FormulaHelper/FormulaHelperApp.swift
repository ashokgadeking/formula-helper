import SwiftUI

@main
struct FormulaHelperApp: App {
    @StateObject private var auth = AuthManager.shared
    @StateObject private var users = UserStore.shared

    init() {
        // Touch the singleton so its CBCentralManager is constructed before
        // launch returns — that's what makes iOS rehydrate paired peripherals
        // for background auto-reconnect.
        _ = BookooManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .environmentObject(users)
                .preferredColorScheme(.dark)
                .task(id: auth.authState) {
                    if auth.authState.userName == "ashok" {
                        await users.load()
                    }
                }
        }
    }
}
