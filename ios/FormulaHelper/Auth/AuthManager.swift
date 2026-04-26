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
    case invalidCredential
    case missingChallenge
    case cancelled
    case missingSiwaToken
    case missingDetails(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredential: return "Unexpected credential type from authenticator"
        case .missingChallenge:  return "Challenge missing from server response"
        case .cancelled:         return "Sign-in was cancelled"
        case .missingSiwaToken:  return "Apple didn't return an identity token"
        case .missingDetails(let m): return m
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

    /// Passkey login. Server picks the credential via resident-key discovery.
    func signIn() async throws {
        let raw = try await APIClient.shared.loginOptions()
        let (challengeId, options) = try parseEnvelope(raw)

        let credential = try await performAssertion(options: options)
        let body: [String: Any] = [
            "challenge_id": challengeId,
            "credential": webauthnAssertionJSON(credential),
        ]
        _ = try await APIClient.shared.loginVerify(body: body)
        await syncAfterAuth()
    }

    /// First step of signup: show Apple sheet, return a draft the UI uses to pre-fill the paged flow.
    func beginSignUp() async throws -> SignUpDraft {
        let (token, name, email) = try await requestSiwaCredential()
        return SignUpDraft(siwaToken: token, suggestedFirstName: name, email: email)
    }

    /// Second step: finish signup — calls register/start then register/finish (passkey).
    /// Pass `householdName` + child info for a new household, or `inviteToken` to join one.
    func completeSignUp(
        draft: SignUpDraft,
        userName: String,
        householdName: String?,
        childName: String?,
        childDob: String?,
        inviteToken: String?
    ) async throws {
        var body: [String: Any] = [
            "siwa_id_token": draft.siwaToken,
            "user_name": userName,
        ]
        if let h = householdName, !h.isEmpty { body["household_name"] = h }
        if let c = childName, !c.isEmpty { body["child_name"] = c }
        if let d = childDob, !d.isEmpty { body["child_dob"] = d }
        if let t = inviteToken, !t.isEmpty { body["invite_token"] = t }

        let raw = try await APIClient.shared.registerStart(body: body)
        let (challengeId, options) = try parseEnvelope(raw)

        let credential = try await performRegistration(options: options, userName: userName)
        let finishBody: [String: Any] = [
            "challenge_id": challengeId,
            "credential": try webauthnAttestationJSON(credential),
        ]
        _ = try await APIClient.shared.registerFinish(body: finishBody)
        await syncAfterAuth()
    }

    /// SIWA-based recovery: issues a new passkey for the existing account.
    func recover() async throws {
        let (siwaToken, _, _) = try await requestSiwaCredential()
        let raw = try await APIClient.shared.recoverStart(siwaIdToken: siwaToken)
        let (challengeId, options) = try parseEnvelope(raw)

        let userName = (options["user"] as? [String: Any])?["name"] as? String ?? "account"
        let credential = try await performRegistration(options: options, userName: userName)
        let body: [String: Any] = [
            "challenge_id": challengeId,
            "credential": try webauthnAttestationJSON(credential),
        ]
        _ = try await APIClient.shared.recoverFinish(body: body)
        await syncAfterAuth()
    }

    func logout() async {
        try? await APIClient.shared.logout()
        authState = .unauthenticated
    }

    // MARK: - Private: envelope parsing

    private func parseEnvelope(_ data: Data) throws -> (String, [String: Any]) {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cid = obj["challenge_id"] as? String,
              let options = obj["options"] as? [String: Any]
        else { throw AuthError.missingChallenge }
        return (cid, options)
    }

    private func syncAfterAuth() async {
        // Pull fresh status so we have user_name populated
        await checkStatus()
    }

    // MARK: - Private: WebAuthn (passkey)

    private func performAssertion(options: [String: Any]) async throws -> ASAuthorizationPlatformPublicKeyCredentialAssertion {
        guard let challengeStr = options["challenge"] as? String,
              let challenge = Data(base64URLEncoded: challengeStr)
        else { throw AuthError.missingChallenge }

        let rpId = (options["rpId"] as? String) ?? APIClient.rpId

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: rpId
        )
        let request = provider.createCredentialAssertionRequest(challenge: challenge)

        let authorization = try await perform(request: request)
        guard let credential = authorization.credential
                as? ASAuthorizationPlatformPublicKeyCredentialAssertion
        else { throw AuthError.invalidCredential }
        return credential
    }

    private func performRegistration(
        options: [String: Any],
        userName: String
    ) async throws -> ASAuthorizationPlatformPublicKeyCredentialRegistration {
        guard let challengeStr = options["challenge"] as? String,
              let challenge = Data(base64URLEncoded: challengeStr)
        else { throw AuthError.missingChallenge }

        let rp = options["rp"] as? [String: Any] ?? [:]
        let rpId = (rp["id"] as? String) ?? APIClient.rpId

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
        return credential
    }

    private func webauthnAssertionJSON(_ c: ASAuthorizationPlatformPublicKeyCredentialAssertion) -> [String: Any] {
        [
            "id":    c.credentialID.base64URLEncoded,
            "rawId": c.credentialID.base64URLEncoded,
            "type":  "public-key",
            "response": [
                "clientDataJSON":    c.rawClientDataJSON.base64URLEncoded,
                "authenticatorData": c.rawAuthenticatorData.base64URLEncoded,
                "signature":         c.signature.base64URLEncoded,
                "userHandle":        c.userID.base64URLEncoded,
            ],
        ]
    }

    private func webauthnAttestationJSON(_ c: ASAuthorizationPlatformPublicKeyCredentialRegistration) throws -> [String: Any] {
        guard let attestation = c.rawAttestationObject else {
            throw AuthError.invalidCredential
        }
        return [
            "id":    c.credentialID.base64URLEncoded,
            "rawId": c.credentialID.base64URLEncoded,
            "type":  "public-key",
            "response": [
                "clientDataJSON":    c.rawClientDataJSON.base64URLEncoded,
                "attestationObject": attestation.base64URLEncoded,
            ],
        ]
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

    // MARK: - Private: common controller wrapper

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
