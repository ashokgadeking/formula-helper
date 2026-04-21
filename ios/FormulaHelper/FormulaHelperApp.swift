import SwiftUI

@main
struct FormulaHelperApp: App {
    @StateObject private var auth = AuthManager.shared
    @StateObject private var users = UserStore.shared

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
