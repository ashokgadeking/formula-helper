import UserNotifications

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()
    private let id = "formula.expiry"
    private let categoryId = "BOTTLE_EXPIRED"

    /// Set by the app layer so notification actions can refresh UI state.
    var onActionComplete: (() async -> Void)?

    private override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    private func registerCategories() {
        let reset = UNNotificationAction(
            identifier: "RESET_TIMER",
            title: "Reset",
            options: [.authenticationRequired]
        )
        let log = UNNotificationAction(
            identifier: "LOG_FEED",
            title: "Log feed",
            options: [.authenticationRequired, .foreground]
        )
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: [log, reset],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func requestPermission() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Schedule (or reschedule) the expiry notification.
    func scheduleExpiry(at timestamp: Double, mixedAt: Double) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let fireDate = Date(timeIntervalSince1970: timestamp)
        guard fireDate > Date() else { return }

        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        let mixedAtStr = f.string(from: Date(timeIntervalSince1970: mixedAt))

        let content = UNMutableNotificationContent()
        content.title = "Discard bottle"
        content.body = "The bottle mixed at \(mixedAtStr) has expired."
        content.sound = .default
        content.categoryIdentifier = categoryId

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancelExpiry() {
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: - Delegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await handle(actionId: response.actionIdentifier)
    }

    private func handle(actionId: String) async {
        switch actionId {
        case "RESET_TIMER":
            try? await APIClient.shared.resetTimer()
        case "LOG_FEED":
            let state = try? await APIClient.shared.getState()
            let ml = state?.settings.preset1_ml ?? 90
            try? await APIClient.shared.logEntry(ml: ml)
        default:
            return
        }
        await onActionComplete?()
    }
}
