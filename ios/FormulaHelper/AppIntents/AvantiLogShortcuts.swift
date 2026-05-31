import AppIntents

struct AvantiLogShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogBottleIntent(),
            phrases: [
                "Log a \(\.$amount) bottle in \(.applicationName)",
                "Log a \(\.$amount) ml bottle in \(.applicationName)",
                "Record a \(\.$amount) bottle in \(.applicationName)",
                "Log a bottle in \(.applicationName)",
            ],
            shortTitle: "Log Bottle",
            systemImageName: "drop.fill"
        )
    }
}
