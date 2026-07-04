import Foundation
import WatchConnectivity

/// Receives the session token the iPhone relays via application context.
final class SessionSync: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = SessionSync()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    static func handle(context: [String: Any], store: SessionStore = .shared) {
        guard let token = context["sessionToken"] as? String, !token.isEmpty,
              token != store.token else { return }
        store.update(token: token)
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // Context pushed while this app was closed is available here.
        Self.handle(context: session.receivedApplicationContext)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Self.handle(context: applicationContext)
    }
}
