import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private let center = UNUserNotificationCenter.current()
    private let id = "formula.expiry"

    func requestPermission() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Schedule (or reschedule) the expiry notification.
    /// - Parameters:
    ///   - timestamp: Unix timestamp when the bottle expires.
    ///   - mixedAt: Unix timestamp when the bottle was mixed (for the body copy).
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

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancelExpiry() {
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }
}
