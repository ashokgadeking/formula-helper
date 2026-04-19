import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: StateViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .users

    enum Tab { case users, timer }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    // Tab bar
                    HStack(spacing: 1) {
                        tabBtn("Users", t: .users)
                        tabBtn("Timer", t: .timer)
                    }
                    .background(Color.border)

                    Divider().background(Color.border)

                    ScrollView {
                        Group {
                            if tab == .users { UsersTab() }
                            else { TimerTab(vm: vm, dismiss: dismiss) }
                        }
                        .padding(20)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.outfit(14, weight: .medium))
                        .foregroundColor(Color.dim)
                }
            }
        }
    }

    private func tabBtn(_ label: String, t: Tab) -> some View {
        Button { withAnimation(.spring(duration: 0.2)) { tab = t } } label: {
            Text(label)
                .font(.outfit(13, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(tab == t ? Color.blue : Color.dim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(tab == t ? Color.blueBg : Color.bg2)
        }
    }
}

// MARK: - Section header

private func sectionHeader(_ s: String) -> some View {
    Text(s.uppercased())
        .font(.outfit(10, weight: .semibold))
        .tracking(2.5)
        .foregroundColor(Color.dim)
}

// MARK: - Users tab

struct UsersTab: View {
    @State private var inviteName   = ""
    @State private var inviteError: String?
    @State private var inviteOk     = false
    @State private var allowedUsers: [String] = []
    @State private var credentials: [APIClient.Credential] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Invite
            sectionHeader("Invite User")

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Name (e.g. anu)", text: $inviteName)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.outfit(14))
                        .foregroundColor(Color.wht)
                        .padding(12)
                        .background(Color.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.borderLight, lineWidth: 1))

                    Button("Add") { Task { await invite() } }
                        .font(.outfit(14, weight: .semibold))
                        .foregroundColor(Color.green)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.greenBg)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.greenBd, lineWidth: 1))
                        .disabled(inviteName.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let err = inviteError {
                    Text(err).font(.outfit(12)).foregroundColor(Color.red.opacity(0.8))
                }
                if inviteOk {
                    Text("Added — they can now register a passkey")
                        .font(.outfit(12)).foregroundColor(Color.green.opacity(0.8))
                }
            }

            Divider().background(Color.border)
            sectionHeader("Users")

            if loading {
                HStack { Spacer(); ProgressView().tint(Color.dim); Spacer() }
            } else {
                let grouped = Dictionary(grouping: credentials, by: \.user_name)
                let allNames = Set(allowedUsers + grouped.keys + ["ashok"])

                VStack(spacing: 8) {
                    ForEach(Array(allNames).sorted(), id: \.self) { name in
                        UserCard(
                            name: name,
                            creds: grouped[name] ?? [],
                            isAdmin: name == "ashok",
                            onRevoke: { id in Task { await revoke(id) } },
                            onRemove: { Task { await remove(name) } }
                        )
                    }
                }
            }
        }
        .task { await loadData() }
    }

    private func loadData() async {
        loading = true
        async let u = try? APIClient.shared.listAllowedUsers()
        async let c = try? APIClient.shared.listCredentials()
        allowedUsers = await u ?? []
        credentials  = await c ?? []
        loading = false
    }

    private func invite() async {
        inviteError = nil; inviteOk = false
        let name = inviteName.trimmingCharacters(in: .whitespaces).lowercased()
        do { try await APIClient.shared.addAllowedUser(name: name); inviteName = ""; inviteOk = true; await loadData() }
        catch { inviteError = error.localizedDescription }
    }

    private func revoke(_ credId: String) async {
        try? await APIClient.shared.deleteCredential(credId: credId); await loadData()
    }

    private func remove(_ name: String) async {
        try? await APIClient.shared.removeAllowedUser(name: name); await loadData()
    }
}

// MARK: - User card

struct UserCard: View {
    let name: String
    let creds: [APIClient.Credential]
    let isAdmin: Bool
    let onRevoke: (String) -> Void
    let onRemove: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(name.capitalized)
                            .font(.outfit(15, weight: .bold))
                            .foregroundColor(Color.wht)
                        if isAdmin {
                            Text("ADMIN")
                                .font(.outfit(9, weight: .semibold))
                                .tracking(1.5)
                                .foregroundColor(Color.dim)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.card2)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.border, lineWidth: 1))
                        }
                    }
                    Text(creds.isEmpty ? "No passkeys" : "\(creds.count) passkey\(creds.count == 1 ? "" : "s")")
                        .font(.outfit(12))
                        .foregroundColor(Color.dim)
                }
                Spacer()
                if !isAdmin {
                    Button {
                        withAnimation(.spring(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.blue)
                            .frame(width: 32, height: 32)
                            .background(Color.blueBg)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blueBd, lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(14)

            if expanded {
                Divider().background(Color.border)
                VStack(spacing: 8) {
                    ForEach(creds) { cred in
                        actionBtn("Revoke passkey (\(shortDate(cred.created)))", fg: Color.red, bg: Color.redBg, bd: Color.redBd) {
                            onRevoke(cred.cred_id)
                        }
                    }
                    actionBtn("Remove user", fg: Color.red, bg: Color.redBg, bd: Color.redBd) {
                        onRemove()
                    }
                }
                .padding(14)
            }
        }
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.border, lineWidth: 1))
        .animation(.spring(duration: 0.2), value: expanded)
    }

    private func actionBtn(_ label: String, fg: Color, bg: Color, bd: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.outfit(13, weight: .semibold))
                .foregroundColor(fg)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(bd, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func shortDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) else { return "—" }
        let r = DateFormatter(); r.dateStyle = .short; r.timeStyle = .none
        return r.string(from: d)
    }
}

// MARK: - Timer tab

struct TimerTab: View {
    @ObservedObject var vm: StateViewModel
    let dismiss: DismissAction
    @State private var countdownMins: Double
    @State private var saving    = false
    @State private var resetting = false

    init(vm: StateViewModel, dismiss: DismissAction) {
        self.vm = vm; self.dismiss = dismiss
        _countdownMins = State(initialValue: Double((vm.state?.settings.countdown_secs ?? 3900) / 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Bottle Countdown")

            VStack(spacing: 12) {
                HStack {
                    Text("\(Int(countdownMins)) minutes")
                        .font(.outfit(22, weight: .bold))
                        .foregroundColor(Color.wht)
                    Spacer()
                }
                Slider(value: $countdownMins, in: 30...180, step: 5)
                    .tint(Color.green)

                Button(saving ? "Saving…" : "Save Duration") {
                    guard !saving else { return }
                    saving = true
                    Task {
                        try? await APIClient.shared.saveSettings(countdownSecs: Int(countdownMins) * 60)
                        await vm.refresh(); saving = false
                    }
                }
                .font(.outfit(14, weight: .semibold))
                .foregroundColor(Color.blue)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.blueBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blueBd, lineWidth: 1))
                .disabled(saving)
            }
            .padding(16)
            .background(Color.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.border, lineWidth: 1))

            Divider().background(Color.border)
            sectionHeader("Reset Timer")

            VStack(alignment: .leading, spacing: 12) {
                Text("Clears the active countdown without logging a new bottle.")
                    .font(.outfit(13))
                    .foregroundColor(Color.dim)

                Button(resetting ? "Resetting…" : "Reset Timer") {
                    guard !resetting else { return }
                    resetting = true
                    Task { await vm.resetTimer(); resetting = false; dismiss() }
                }
                .font(.outfit(14, weight: .semibold))
                .foregroundColor(Color.red)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.redBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.redBd, lineWidth: 1))
                .disabled(resetting)
            }
        }
    }
}
