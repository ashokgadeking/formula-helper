import SwiftUI

@main
struct FormulaHelperApp: App {
    @StateObject private var auth = AuthManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .preferredColorScheme(.dark)
        }
    }
}
