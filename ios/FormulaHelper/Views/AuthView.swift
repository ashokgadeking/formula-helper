import SwiftUI

struct AuthView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var userName = ""
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var showRegister = false

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            RadialGradient(
                colors: [Color.green.opacity(0.03), Color.bg],
                center: UnitPoint(x: 0.5, y: 0.35),
                startRadius: 0, endRadius: 350
            ).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo / title
                VStack(spacing: 8) {
                    Text("Formula Helper")
                        .font(.outfit(28, weight: .bold))
                        .foregroundColor(Color.wht)
                    Text(showRegister ? "Create your passkey" : "Sign in with your passkey")
                        .font(.outfit(11, weight: .medium))
                        .tracking(2.5)
                        .foregroundColor(Color.dim)
                        .textCase(.uppercase)
                }

                Spacer()

                VStack(spacing: 12) {
                    if showRegister {
                        TextField("Your name (e.g. ashok, anu)", text: $userName)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.outfit(15))
                            .foregroundColor(Color.wht)
                            .padding(14)
                            .background(Color.bg2)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.borderLight, lineWidth: 1))
                    }

                    if let error = errorMessage {
                        Text(error)
                            .font(.outfit(12))
                            .foregroundColor(Color.red.opacity(0.85))
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task { await primaryAction() }
                    } label: {
                        HStack(spacing: 10) {
                            if isWorking {
                                ProgressView().tint(Color.green).scaleEffect(0.85)
                            } else {
                                Image(systemName: showRegister ? "faceid" : "person.badge.key.fill")
                                    .font(.system(size: 15))
                            }
                            Text(showRegister ? "Register Passkey" : "Sign In with Passkey")
                                .font(.outfit(15, weight: .semibold))
                        }
                        .foregroundColor(Color.green)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.greenBg)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.greenBd, lineWidth: 1))
                    }
                    .disabled(isWorking || (showRegister && userName.trimmingCharacters(in: .whitespaces).isEmpty))

                    Button {
                        withAnimation { showRegister.toggle(); errorMessage = nil }
                    } label: {
                        Text(showRegister
                             ? "Already have a passkey? Sign in"
                             : "New user? Register a passkey")
                            .font(.outfit(12))
                            .foregroundColor(Color.dim)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 28)

                Spacer(minLength: 50)
            }
        }
    }

    private func primaryAction() async {
        errorMessage = nil; isWorking = true
        defer { isWorking = false }
        do {
            if showRegister {
                try await auth.register(userName: userName.trimmingCharacters(in: .whitespaces).lowercased())
            } else {
                try await auth.signIn()
            }
        } catch AuthError.cancelled {
            // dismissed — no message
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    AuthView().environmentObject(AuthManager.shared)
}
