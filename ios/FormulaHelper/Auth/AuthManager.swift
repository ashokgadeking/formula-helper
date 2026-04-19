import AuthenticationServices
import Foundation
import UIKit

// MARK: - State

enum AuthState: Equatable {
    case loading
    case authenticated(userName: String)
    case unauthenticated(registered: Bool)   // registered = any passkey exists

    var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }

    var userName: String? {
        if case .authenticated(let name) = self { return name }
        return nil
    }
}

// MARK: - Errors

enum AuthError: LocalizedError {
    case invalidCredential
    case missingChallenge
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidCredential: return "Unexpected credential type from authenticator"
        case .missingChallenge:  return "Challenge missing from server response"
        case .cancelled:         return "Sign-in was cancelled"
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
            if status.authenticated {
                authState = .authenticated(userName: status.user_name)
            } else {
                authState = .unauthenticated(registered: status.registered)
            }
        } catch {
            authState = .unauthenticated(registered: false)
        }
    }

    func signIn() async throws {
        let rawOptions = try await APIClient.shared.loginOptions()
        let options = try JSONSerialization.jsonObject(with: rawOptions) as? [String: Any]
            ?? [:]

        guard let challengeStr = options["challenge"] as? String,
              let challenge = Data(base64URLEncoded: challengeStr)
        else { throw AuthError.missingChallenge }

        let rpId = options["rpId"] as? String ?? "d20oyc88hlibbe.cloudfront.net"

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: rpId
        )
        let request = provider.createCredentialAssertionRequest(challenge: challenge)

        let authorization = try await perform(request: request)
        guard let credential = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion
        else { throw AuthError.invalidCredential }

        let body: [String: Any] = [
            "id":     credential.credentialID.base64URLEncoded,
            "rawId":  credential.credentialID.base64URLEncoded,
            "type":   "public-key",
            "response": [
                "clientDataJSON":    credential.rawClientDataJSON.base64URLEncoded,
                "authenticatorData": credential.rawAuthenticatorData.base64URLEncoded,
                "signature":         credential.signature.base64URLEncoded,
                "userHandle":        credential.userID.base64URLEncoded,
            ]
        ]

        let result = try await APIClient.shared.loginVerify(body)
        authState = .authenticated(userName: result.user_name)
    }

    func register(userName: String) async throws {
        let rawOptions = try await APIClient.shared.registerOptions()
        let options = try JSONSerialization.jsonObject(with: rawOptions) as? [String: Any]
            ?? [:]

        guard let challengeStr = options["challenge"] as? String,
              let challenge = Data(base64URLEncoded: challengeStr)
        else { throw AuthError.missingChallenge }

        let rp = options["rp"] as? [String: Any] ?? [:]
        let rpId = rp["id"] as? String ?? "d20oyc88hlibbe.cloudfront.net"

        let user = options["user"] as? [String: Any] ?? [:]
        let userIdStr = user["id"] as? String ?? ""
        let userId = Data(base64URLEncoded: userIdStr) ?? Data(userName.utf8)

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: rpId
        )
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge,
            name: userName,
            userID: userId
        )

        let authorization = try await perform(request: request)
        guard let credential = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialRegistration
        else { throw AuthError.invalidCredential }

        guard let attestationObject = credential.rawAttestationObject else {
            throw AuthError.invalidCredential
        }

        let body: [String: Any] = [
            "id":        credential.credentialID.base64URLEncoded,
            "rawId":     credential.credentialID.base64URLEncoded,
            "type":      "public-key",
            "response": [
                "clientDataJSON":   credential.rawClientDataJSON.base64URLEncoded,
                "attestationObject": attestationObject.base64URLEncoded,
            ],
            "user_name": userName,
        ]

        let result = try await APIClient.shared.registerVerify(body)
        authState = .authenticated(userName: result.user_name ?? userName)
    }

    // MARK: - Private

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

// MARK: - Data + base64url

extension Data {
    init?(base64URLEncoded string: String) {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = s.count % 4
        if pad != 0 { s += String(repeating: "=", count: 4 - pad) }
        self.init(base64Encoded: s)
    }

    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
