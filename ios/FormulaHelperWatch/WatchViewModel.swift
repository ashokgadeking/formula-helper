import Foundation
import WatchKit

@MainActor
final class WatchViewModel: ObservableObject {
    @Published var state: AppStateResponse?
    @Published var signedIn = SessionStore.shared.isSignedIn
    @Published var isLogging = false
    @Published var errorMessage: String?

    func refresh() async {
        signedIn = SessionStore.shared.isSignedIn
        guard signedIn else { return }
        do {
            state = try await APIClient.shared.getState()
        } catch {
            handle(error)
        }
    }

    func logFeed(ml: Int) async {
        await perform { _ = try await APIClient.shared.startFeeding(ml: ml) }
    }

    func logDiaper(type: String) async {
        await perform { try await APIClient.shared.logDiaper(type: type) }
    }

    func logNap() async {
        await perform { try await APIClient.shared.logNap() }
    }

    private func perform(_ op: @Sendable () async throws -> Void) async {
        guard !isLogging else { return }
        isLogging = true
        defer { isLogging = false }
        do {
            try await op()
            WKInterfaceDevice.current().play(.success)
            errorMessage = nil
            await refresh()
        } catch {
            WKInterfaceDevice.current().play(.failure)
            handle(error)
        }
    }

    private func handle(_ error: Error) {
        if case APIError.badStatus(let code, _) = error, code == 401 || code == 403 {
            SessionStore.shared.clear()
            signedIn = false
        } else {
            errorMessage = error.localizedDescription
        }
    }
}
