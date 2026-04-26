import SwiftUI
import OSLog

private let authLog = Logger(subsystem: "com.ashokteja.formulahelper", category: "auth")

struct AuthView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var signUpDraft: SignUpDraft?
    @State private var joinDraft: SignUpDraft?
    @State private var showJoinCodeEntry = false
    @State private var pendingInviteToken = ""

    private var isDevStack: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "IsDevStack") as? String) == "YES"
    }

    var body: some View {
        ZStack {
            Color.primaryBackground.ignoresSafeArea()
            RadialGradient(
                colors: [Color.green.opacity(0.03), Color.primaryBackground],
                center: UnitPoint(x: 0.5, y: 0.35),
                startRadius: 0, endRadius: 350
            ).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 8) {
                    Text("Formula Helper")
                        .font(.outfit(28, weight: .bold))
                        .foregroundColor(Color.primaryLabel)
                    Text("Sign in with your passkey")
                        .font(.outfit(11, weight: .medium))
                        .tracking(2.5)
                        .foregroundColor(Color.secondaryLabel)
                        .textCase(.uppercase)
                }

                Spacer()

                VStack(spacing: 12) {
                    if let error = errorMessage {
                        Text(error)
                            .font(.outfit(12))
                            .foregroundColor(Color.red.opacity(0.85))
                            .multilineTextAlignment(.center)
                    }

                    primaryButton(label: "Sign In with Passkey", icon: "person.badge.key.fill") {
                        await run { try await auth.signIn() }
                    }

                    secondaryButton(label: "Create Account") {
                        Task { await startSignUp() }
                    }

                    secondaryButton(label: "Join with Invite") {
                        showJoinCodeEntry = true
                    }

                    Button {
                        Task { await run { try await auth.recover() } }
                    } label: {
                        Text("Can't sign in? Recover with Apple ID")
                            .font(.outfit(12))
                            .foregroundColor(Color.secondaryLabel)
                    }
                    .padding(.top, 4)

                    if isDevStack {
                        Button {
                            Task { await run {
                                _ = try await APIClient.shared.devLogin()
                                await auth.checkStatus()
                            } }
                        } label: {
                            Text("Dev Login (bypass)")
                                .font(.outfit(12, weight: .semibold))
                                .foregroundColor(Color.orange)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 28)

                Spacer(minLength: 50)
            }
        }
        .fullScreenCover(item: $signUpDraft) { draft in
            SignUpFlowView(draft: draft, inviteToken: nil) {
                signUpDraft = nil
            }
            .environmentObject(auth)
        }
        .fullScreenCover(item: $joinDraft) { draft in
            SignUpFlowView(draft: draft, inviteToken: pendingInviteToken) {
                joinDraft = nil
                pendingInviteToken = ""
            }
            .environmentObject(auth)
        }
        .sheet(isPresented: $showJoinCodeEntry) {
            InviteCodeSheet(isPresented: $showJoinCodeEntry) { token in
                pendingInviteToken = token
                Task { await startJoin() }
            }
        }
    }

    // MARK: - Triggers

    private func startSignUp() async {
        errorMessage = nil; isWorking = true
        defer { isWorking = false }
        do {
            authLog.notice("starting SIWA for sign-up")
            let draft = try await auth.beginSignUp()
            authLog.notice("SIWA returned, firstName=\(draft.suggestedFirstName ?? "<nil>", privacy: .private)")
            signUpDraft = draft
            authLog.notice("signUpDraft set, presenting cover")
        } catch {
            authLog.error("sign-up error: \(String(describing: error), privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    private func startJoin() async {
        errorMessage = nil; isWorking = true
        defer { isWorking = false }
        do {
            authLog.notice("starting SIWA for join")
            let draft = try await auth.beginSignUp()
            joinDraft = draft
        } catch {
            authLog.error("join error: \(String(describing: error), privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    private func run(_ op: @escaping () async throws -> Void) async {
        errorMessage = nil; isWorking = true
        defer { isWorking = false }
        do { try await op() }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Buttons

    private func primaryButton(label: String, icon: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 10) {
                if isWorking {
                    ProgressView().tint(Color.green).scaleEffect(0.85)
                } else {
                    Image(systemName: icon).font(.system(size: 15))
                }
                Text(label).font(.outfit(15, weight: .semibold))
            }
            .foregroundColor(Color.green)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.greenFill)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.greenBorder, lineWidth: 1))
        }
        .disabled(isWorking)
    }

    private func secondaryButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.outfit(14, weight: .medium))
                .foregroundColor(Color.primaryLabel)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Color.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.opaqueSeparator, lineWidth: 1))
        }
        .disabled(isWorking)
    }
}

// MARK: - Invite code entry

struct InviteCodeSheet: View {
    @Binding var isPresented: Bool
    let onContinue: (String) -> Void

    @State private var token = ""
    @FocusState private var focused: Bool

    private var trimmed: String { token.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.primaryBackground.ignoresSafeArea()
                List {
                    Section {
                        TextField("Paste invite code", text: $token)
                            .textContentType(.oneTimeCode)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .appFont(.body)
                            .foregroundColor(Color.primaryLabel)
                            .focused($focused)
                            .listRowBackground(Color.elevatedBackground)
                    } footer: {
                        Text("Someone in the household you're joining needs to send you an invite code.")
                            .appFont(.footnote)
                            .foregroundColor(Color.secondaryLabel)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Join Household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .foregroundColor(Color.secondaryLabel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        isPresented = false
                        onContinue(trimmed)
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }
}

// MARK: - Paged signup flow

struct SignUpFlowView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    let draft: SignUpDraft
    let inviteToken: String?
    let onFinish: () -> Void

    @State private var step: Int = 0
    @State private var userName: String = ""
    @State private var householdName: String = ""
    @State private var childName: String = ""
    @State private var childDob: Date = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var isInvite: Bool { inviteToken != nil }
    private var totalSteps: Int { isInvite ? 1 : 3 }
    private var isLastStep: Bool { step == totalSteps - 1 }

    var body: some View {
        ZStack {
            Color.primaryBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer(minLength: 20)

                pageContent
                    .padding(.horizontal, 28)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .id(step)

                Spacer()

                footer
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
            }
        }
        .onAppear {
            if userName.isEmpty, let suggested = draft.suggestedFirstName, !suggested.isEmpty {
                userName = suggested
            }
        }
    }

    // MARK: - Header (progress + close)

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    if step == 0 {
                        dismiss()
                        onFinish()
                    } else {
                        withAnimation { step -= 1 }
                    }
                } label: {
                    Image(systemName: step == 0 ? "xmark" : "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color.secondaryLabel)
                        .frame(width: 36, height: 36)
                        .background(Color.secondaryBackground)
                        .clipShape(Circle())
                }
                Spacer()
                Text("Step \(step + 1) of \(totalSteps)")
                    .font(.outfit(11, weight: .medium))
                    .tracking(1.5)
                    .foregroundColor(Color.tertiaryLabel)
                    .textCase(.uppercase)
                Spacer()
                Color.clear.frame(width: 36, height: 36)
            }

            // Progress dots
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Capsule()
                        .fill(i <= step ? Color.green : Color.opaqueSeparator)
                        .frame(height: 3)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    // MARK: - Pages

    @ViewBuilder
    private var pageContent: some View {
        if isInvite {
            namePage
        } else {
            switch step {
            case 0: namePage
            case 1: householdPage
            default: childPage
            }
        }
    }

    private var namePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageTitle("What should we call you?", subtitle: nil)

            TextField("First name", text: $userName)
                .textContentType(.givenName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .font(.outfit(17))
                .foregroundColor(Color.primaryLabel)
                .padding(14)
                .background(Color.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.opaqueSeparator, lineWidth: 1))
        }
    }

    private var householdPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageTitle("Name your household", subtitle: "Everyone you invite will share this space. You can change it later.")

            TextField("e.g. Gadepalli", text: $householdName)
                .textContentType(.organizationName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .font(.outfit(17))
                .foregroundColor(Color.primaryLabel)
                .padding(14)
                .background(Color.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.opaqueSeparator, lineWidth: 1))
        }
    }

    private var childPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageTitle("Tell us about your little one", subtitle: "Used to personalize the app. You can skip and add later.")

            TextField("Baby's name", text: $childName)
                .textContentType(.givenName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.words)
                .font(.outfit(17))
                .foregroundColor(Color.primaryLabel)
                .padding(14)
                .background(Color.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.opaqueSeparator, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                Text("Date of birth")
                    .font(.outfit(13))
                    .foregroundColor(Color.secondaryLabel)
                DatePicker("", selection: $childDob, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .background(Color.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func pageTitle(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.outfit(24, weight: .bold))
                .foregroundColor(Color.primaryLabel)
            if let subtitle {
                Text(subtitle)
                    .font(.outfit(13))
                    .foregroundColor(Color.secondaryLabel)
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Footer (continue / finish)

    private var footer: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.outfit(12))
                    .foregroundColor(Color.red.opacity(0.85))
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await advance() }
            } label: {
                HStack(spacing: 10) {
                    if isWorking {
                        ProgressView().tint(Color.green).scaleEffect(0.85)
                    } else if isLastStep {
                        Image(systemName: "faceid").font(.system(size: 15))
                    }
                    Text(isLastStep ? "Create Passkey & Finish" : "Continue")
                        .font(.outfit(15, weight: .semibold))
                }
                .foregroundColor(Color.green)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.greenFill)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.greenBorder, lineWidth: 1))
            }
            .disabled(isWorking || !canAdvance)
        }
    }

    private var canAdvance: Bool {
        switch currentPageKey {
        case .name:      return !userName.trimmingCharacters(in: .whitespaces).isEmpty
        case .household: return !householdName.trimmingCharacters(in: .whitespaces).isEmpty
        case .child:     return true  // child name + DOB both optional
        }
    }

    private enum PageKey { case name, household, child }

    private var currentPageKey: PageKey {
        if isInvite { return .name }
        switch step {
        case 0: return .name
        case 1: return .household
        default: return .child
        }
    }

    private func advance() async {
        errorMessage = nil
        if !isLastStep {
            withAnimation { step += 1 }
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let dobStr = childName.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : isoDate(childDob)
            try await auth.completeSignUp(
                draft: draft,
                userName: userName.trimmingCharacters(in: .whitespaces),
                householdName: isInvite ? nil : householdName.trimmingCharacters(in: .whitespaces),
                childName: childName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : childName.trimmingCharacters(in: .whitespaces),
                childDob: dobStr,
                inviteToken: inviteToken
            )
            dismiss()
            onFinish()
        } catch AuthError.cancelled {
            // user dismissed the passkey sheet — stay on this page
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isoDate(_ date: Date) -> String {
        // Format in the user's local timezone so a "today" pick at 23:30 UTC+14
        // doesn't get serialized as yesterday in UTC.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: date)
    }
}

#Preview {
    AuthView().environmentObject(AuthManager.shared)
}
