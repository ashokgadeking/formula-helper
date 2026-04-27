import AuthenticationServices
import Foundation
import UIKit

// MARK: - Signup draft

struct SignUpDraft: Identifiable {
    let siwaToken: String
    let suggestedFirstName: String?
    let email: String?

    var id: String { siwaToken }
}

// MARK: - Auth result

enum SiwaAuthResult {
    case signedIn(returning: Bool)
    case setupRequired
}

// MARK: - State

enum AuthState: Equatable {
    case loading
    case authenticated(userName: String, userId: String, activeHh: String?)
    case unauthenticated

    var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }

    var userName: String? {
        if case .authenticated(let name, _, _) = self { return name }
        return nil
    }

    var userId: String? {
        if case .authenticated(_, let id, _) = self { return id }
        return nil
    }

    var activeHouseholdId: String? {
        if case .authenticated(_, _, let hh) = self { return hh }
        return nil
    }
}

// MARK: - Errors

enum AuthError: LocalizedError {
    case cancelled
    case missingSiwaToken

    var errorDescription: String? {
        switch self {
        case .cancelled:        return "Sign-in was cancelled"
        case .missingSiwaToken: return "Apple didn't return an identity token"
        }
    }
}

// MARK: - Manager

@MainActor
final class AuthManager: NSObject, ObservableObject {
    @Published var authState: AuthState = .loading

    static let shared = AuthManager()

    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    // MARK: - Public API

    func checkStatus() async {
        do {
            let status = try await APIClient.shared.authStatus()
            let userId = status.user_id ?? ""
            if status.authenticated, !userId.isEmpty {
                authState = .authenticated(
                    userName: status.user_name ?? "",
                    userId: userId,
                    activeHh: status.active_hh
                )
            } else {
                authState = .unauthenticated
            }
        } catch {
            authState = .unauthenticated
        }
    }

    /// Trigger Sign in with Apple and capture the id_token + any name/email Apple returns.
    /// Returns a draft the UI uses to (a) hand the token to `siwaAuth`, and (b) pre-fill the
    /// paged setup form when the server responds 412 / "setup required".
    func beginSignUp() async throws -> SignUpDraft {
        let (token, name, email) = try await requestSiwaCredential()
        return SignUpDraft(siwaToken: token, suggestedFirstName: name, email: email)
    }

    /// Single auth call. Pair with `beginSignUp()` to obtain the `idToken`.
    /// Returns:
    /// - `.signedIn(returning: true)` — existing account, session cookie set, AuthState updated.
    /// - `.signedIn(returning: false)` — new account just created, session cookie set.
    /// - `.setupRequired` — server needs `user_name` + `household_name`-or-`invite_token`. Caller
    ///   should present the paged setup form and call `siwaAuth` again with the same `idToken`.
    func siwaAuth(
        idToken: String,
        userName: String?,
        householdName: String?,
        childName: String?,
        childDob: String?,
        inviteToken: String?
    ) async throws -> SiwaAuthResult {
        do {
            let resp = try await APIClient.shared.siwaAuth(
                idToken: idToken,
                userName: userName,
                householdName: householdName,
                childName: childName,
                childDob: childDob,
                inviteToken: inviteToken
            )
            await checkStatus()
            return .signedIn(returning: resp.returning)
        } catch APIError.setupRequired {
            return .setupRequired
        }
    }

    func logout() async {
        try? await APIClient.shared.logout()
        authState = .unauthenticated
    }

    // MARK: - Private: Sign in with Apple

    private func requestSiwaCredential() async throws -> (token: String, firstName: String?, email: String?) {
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let authorization = try await perform(request: request)
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8)
        else { throw AuthError.missingSiwaToken }

        let firstName = cred.fullName?.givenName
        return (token, firstName, cred.email)
    }

    // MARK: - Private: ASAuthorization controller wrapper

    private func perform(request: ASAuthorizationRequest) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AuthManager: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            continuation?.resume(returning: authorization)
            continuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            let authError = (error as? ASAuthorizationError)?.code == .canceled
                ? AuthError.cancelled as Error
                : error
            continuation?.resume(throwing: authError)
            continuation = nil
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AuthManager: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? UIWindow()
    }
}
