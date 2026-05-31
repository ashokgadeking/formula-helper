import AppIntents
import Foundation

struct LogBottleIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Bottle"
    static let description = IntentDescription("Log a bottle feeding to AvantiLog.")

    @Parameter(
        title: "Amount",
        description: "Milliliters in the bottle.",
        requestValueDialog: "What's the amount in milliliters?"
    )
    var amount: BottleAmount

    static var parameterSummary: some ParameterSummary {
        Summary("Log a \(\.$amount) ml bottle")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ml = amount.rawValue

        let authed = await MainActor.run { AuthManager.shared.authState.isAuthenticated }
        guard authed else {
            return .result(dialog: "Open Formula Helper to sign in, then try again.")
        }

        do {
            _ = try await APIClient.shared.logEntry(ml: ml, date: nil)
            return .result(dialog: "Logged \(ml) milliliters.")
        } catch APIError.badStatus(401, _) {
            return .result(dialog: "Open Formula Helper to sign in, then try again.")
        } catch {
            return .result(dialog: "Couldn't log the bottle — try again or open the app.")
        }
    }
}
