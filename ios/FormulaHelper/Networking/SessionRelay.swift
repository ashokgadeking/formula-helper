import Foundation
import WatchConnectivity

/// Pushes the API session cookie to the watch whenever it changes, so the
/// watch app can call the API directly. Application context is durable —
/// it's delivered even if the watch app is closed or the watch is away.
final class SessionRelay: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = SessionRelay()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func pushIfNeeded() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled,
              let url = URL(string: APIClient.baseURL),
              let cookie = HTTPCookieStorage.shared.cookies(for: url)?
                  .first(where: { $0.name == "session" }),
              (session.applicationContext["sessionToken"] as? String) != cookie.value
        else { return }
        try? session.updateApplicationContext(["sessionToken": cookie.value])
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        Self.shared.pushIfNeeded()
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
