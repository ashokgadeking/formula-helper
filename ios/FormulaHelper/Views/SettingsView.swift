import SwiftUI

// MARK: - Settings (native insetGrouped list)

struct SettingsView: View {
    @ObservedObject var vm: StateViewModel
    @EnvironmentObject var auth: AuthManager
    @StateObject private var users = UserStore()
    @State private var showInvite = false
    @State private var showResetConfirm = false

    private var isAdmin: Bool { auth.authState.userName == "ashok" }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.primaryBackground.ignoresSafeArea()

                List {
                    timerSection
                    if isAdmin { usersSection }
                    aboutSection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.primaryBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .task { if isAdmin { await users.load() } }
        .sheet(isPresented: $showInvite) {
            InviteUserSheet(isPresented: $showInvite) { name in
                try await users.invite(name: name)
            }
        }
    }

    // MARK: Timer section

    @ViewBuilder
    private var timerSection: some View {
        Section {
            NavigationLink {
                TimerDetailView(vm: vm)
            } label: {
                SettingsRow(
                    icon: "timer",
                    tint: .green,
                    title: "Countdown",
                    trailing: "\(timerMinutes) min"
                )
            }
            .listRowBackground(Color.elevatedBackground)

            if hasActiveBottle {
                Button {
                    showResetConfirm = true
                } label: {
                    SettingsRow(
                        icon: "arrow.counterclockwise",
                        tint: .red,
                        title: "Reset active timer",
                        titleColor: .red
                    )
                }
                .listRowBackground(Color.elevatedBackground)
                .confirmationDialog(
                    "Reset active timer?",
                    isPresented: $showResetConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        Task { await vm.resetTimer() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Clears the countdown without logging a new bottle.")
                }
            }
        } header: {
            Text("Bottle Timer").foregroundColor(Color.secondaryLabel)
        }
    }

    private var timerMinutes: Int {
        (vm.state?.settings.countdown_secs ?? 3900) / 60
    }

    private var hasActiveBottle: Bool {
        guard let end = vm.state?.countdown_end else { return false }
        return end > Date().timeIntervalSince1970
    }

    // MARK: Users section

    @ViewBuilder
    private var usersSection: some View {
        Section {
            if users.loading {
                HStack {
                    Spacer()
                    ProgressView().tint(Color.secondaryLabel)
                    Spacer()
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.elevatedBackground)
            } else {
                ForEach(users.users) { user in
                    NavigationLink {
                        UserDetailView(user: user, store: users)
                    } label: {
                        UserRow(user: user)
                    }
                    .listRowBackground(Color.elevatedBackground)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !user.isAdmin {
                            Button(role: .destructive) {
                                Task { await users.remove(name: user.name) }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }

                Button { showInvite = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(Color.green)
                        Text("Invite User")
                            .appFont(.body)
                            .foregroundColor(Color.primaryLabel)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .listRowBackground(Color.elevatedBackground)
            }
        } header: {
            Text("Users").foregroundColor(Color.secondaryLabel)
        }
    }

    // MARK: About section

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            HStack {
                SettingsRow(icon: "info.circle.fill", tint: .blue, title: "Version")
                Spacer()
                Text(appVersion)
                    .appFont(.body)
                    .foregroundColor(Color.secondaryLabel)
            }
            .listRowBackground(Color.elevatedBackground)

            if let name = auth.authState.userName {
                SettingsRow(
                    icon: "person.crop.circle.fill",
                    tint: .purple,
                    title: "Signed in as",
                    trailing: name.capitalized
                )
                .listRowBackground(Color.elevatedBackground)
            }
        } header: {
            Text("About").foregroundColor(Color.secondaryLabel)
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = info["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

// MARK: - User store

@MainActor
final class UserStore: ObservableObject {
    struct User: Identifiable {
        let name: String
        let credentials: [APIClient.Credential]
        let isAdmin: Bool
        var id: String { name }
        var isPending: Bool { credentials.isEmpty && !isAdmin }
    }

    @Published var users: [User] = []
    @Published var loading = true

    func load() async {
        loading = true
        async let u = try? APIClient.shared.listAllowedUsers()
        async let c = try? APIClient.shared.listCredentials()
        let allowed = await u ?? []
        let creds = await c ?? []
        let grouped = Dictionary(grouping: creds, by: \.user_name)
        let names = Set(allowed + grouped.keys + ["ashok"])
        users = names.sorted().map { name in
            User(name: name, credentials: grouped[name] ?? [], isAdmin: name == "ashok")
        }
        loading = false
    }

    func invite(name: String) async throws {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        try await APIClient.shared.addAllowedUser(name: n)
        await load()
    }

    func remove(name: String) async {
        try? await APIClient.shared.removeAllowedUser(name: name)
        await load()
    }

    func revoke(credId: String) async {
        try? await APIClient.shared.deleteCredential(credId: credId)
        await load()
    }
}

// MARK: - Reusable row (iOS Settings style)

struct SettingsRow: View {
    let icon: String
    let tint: Color
    let title: String
    var titleColor: Color = Color.primaryLabel
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.opacity(0.18))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(tint)
            }
            .frame(width: 30, height: 30)

            Text(title)
                .appFont(.body)
                .foregroundColor(titleColor)

            Spacer()

            if let trailing {
                Text(trailing)
                    .appFont(.body)
                    .foregroundColor(Color.secondaryLabel)
            }
        }
    }
}

// MARK: - User row

struct UserRow: View {
    let user: UserStore.User

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name.capitalized)
                    .appFont(.body)
                    .foregroundColor(Color.primaryLabel)
                Text(subtitle)
                    .appFont(.footnote)
                    .foregroundColor(Color.secondaryLabel)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 4)
    }

    private var avatarTint: Color {
        user.isAdmin ? Color.green : (user.isPending ? Color.yellow : Color.blue)
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(avatarTint.opacity(0.18))
            Text(String(user.name.prefix(1)).uppercased())
                .appFont(.headline)
                .foregroundColor(avatarTint)
        }
        .frame(width: 36, height: 36)
    }

    private var subtitle: String {
        if user.isPending { return "Waiting for passkey" }
        let n = user.credentials.count
        return n == 1 ? "1 passkey" : "\(n) passkeys"
    }

    @ViewBuilder
    private var trailing: some View {
        if user.isAdmin {
            PillBadge(text: "ADMIN", color: Color.green)
        } else if user.isPending {
            PillBadge(text: "PENDING", color: Color.yellow)
        }
    }
}

struct PillBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .appFont(.caption2)
            .tracking(1.2)
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(color.opacity(0.30), lineWidth: 1))
    }
}

// MARK: - Timer detail

struct TimerDetailView: View {
    @ObservedObject var vm: StateViewModel
    @State private var mins: Double
    @State private var saving = false

    init(vm: StateViewModel) {
        self.vm = vm
        _mins = State(initialValue: Double((vm.state?.settings.countdown_secs ?? 3900) / 60))
    }

    var body: some View {
        ZStack {
            Color.primaryBackground.ignoresSafeArea()

            List {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(Int(mins))")
                                .font(.custom("Outfit", size: 48, relativeTo: .largeTitle).bold())
                                .foregroundColor(Color.green)
                                .monospacedDigit()
                            Text("min")
                                .appFont(.title3)
                                .foregroundColor(Color.secondaryLabel)
                            Spacer()
                            if saving {
                                ProgressView().tint(Color.secondaryLabel).scaleEffect(0.8)
                            }
                        }
                        Slider(value: $mins, in: 30...180, step: 5) { editing in
                            if !editing { Task { await save() } }
                        }
                        .tint(Color.green)
                        HStack {
                            Text("30 min")
                            Spacer()
                            Text("180 min")
                        }
                        .appFont(.caption1)
                        .foregroundColor(Color.tertiaryLabel)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.elevatedBackground)
                } header: {
                    Text("Duration").foregroundColor(Color.secondaryLabel)
                } footer: {
                    Text("How long before a mixed bottle should be discarded. Changes save automatically.")
                        .appFont(.footnote)
                        .foregroundColor(Color.secondaryLabel)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Countdown")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() async {
        saving = true
        try? await APIClient.shared.saveSettings(countdownSecs: Int(mins) * 60)
        await vm.refresh()
        saving = false
    }
}

// MARK: - User detail

struct UserDetailView: View {
    let user: UserStore.User
    @ObservedObject var store: UserStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false
    @State private var confirmRevoke: APIClient.Credential?

    var body: some View {
        ZStack {
            Color.primaryBackground.ignoresSafeArea()

            List {
                Section {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().fill(avatarTint.opacity(0.18))
                            Text(String(user.name.prefix(1)).uppercased())
                                .font(.custom("Outfit", size: 28, relativeTo: .title).bold())
                                .foregroundColor(avatarTint)
                        }
                        .frame(width: 56, height: 56)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(user.name.capitalized)
                                .appFont(.title2)
                                .foregroundColor(Color.primaryLabel)
                            if user.isAdmin {
                                PillBadge(text: "ADMIN", color: Color.green)
                            } else if user.isPending {
                                PillBadge(text: "PENDING", color: Color.yellow)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.elevatedBackground)
                }

                Section {
                    if user.credentials.isEmpty {
                        Text(user.isPending
                             ? "No passkey registered yet. Share sign-in instructions with this user."
                             : "No passkeys on file.")
                            .appFont(.footnote)
                            .foregroundColor(Color.secondaryLabel)
                            .listRowBackground(Color.elevatedBackground)
                    } else {
                        ForEach(user.credentials) { cred in
                            passkeyRow(cred)
                                .listRowBackground(Color.elevatedBackground)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        confirmRevoke = cred
                                    } label: {
                                        Label("Revoke", systemImage: "trash")
                                    }
                                }
                        }
                    }
                } header: {
                    Text("Passkeys").foregroundColor(Color.secondaryLabel)
                } footer: {
                    if !user.credentials.isEmpty {
                        Text("Swipe left on a passkey to revoke it.")
                            .appFont(.footnote)
                            .foregroundColor(Color.secondaryLabel)
                    }
                }

                if !user.isAdmin {
                    Section {
                        Button(role: .destructive) {
                            confirmRemove = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("Remove User")
                                    .appFont(.body)
                                    .foregroundColor(Color.red)
                                Spacer()
                            }
                        }
                        .listRowBackground(Color.elevatedBackground)
                    } footer: {
                        Text("Revokes all passkeys and removes this user from the allowlist.")
                            .appFont(.footnote)
                            .foregroundColor(Color.secondaryLabel)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(user.name.capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove \(user.name.capitalized)?",
            isPresented: $confirmRemove,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    await store.remove(name: user.name)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This revokes all passkeys and removes them from the allowlist.")
        }
        .confirmationDialog(
            "Revoke this passkey?",
            isPresented: Binding(
                get: { confirmRevoke != nil },
                set: { if !$0 { confirmRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let c = confirmRevoke {
                    Task { await store.revoke(credId: c.cred_id) }
                }
                confirmRevoke = nil
            }
            Button("Cancel", role: .cancel) { confirmRevoke = nil }
        } message: {
            Text("This passkey will no longer be able to sign in.")
        }
    }

    private var avatarTint: Color {
        user.isAdmin ? Color.green : (user.isPending ? Color.yellow : Color.blue)
    }

    private func passkeyRow(_ cred: APIClient.Credential) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.blue.opacity(0.18))
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.blue)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("Passkey")
                    .appFont(.body)
                    .foregroundColor(Color.primaryLabel)
                Text("Added \(shortDate(cred.created))")
                    .appFont(.footnote)
                    .foregroundColor(Color.secondaryLabel)
            }
            Spacer()
        }
    }

    private func shortDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) else { return "—" }
        let r = DateFormatter(); r.dateStyle = .medium; r.timeStyle = .none
        return r.string(from: d)
    }
}

// MARK: - Invite user sheet

struct InviteUserSheet: View {
    @Binding var isPresented: Bool
    let onSubmit: (String) async throws -> Void

    @State private var name = ""
    @State private var error: String?
    @State private var submitting = false
    @FocusState private var focused: Bool

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.primaryBackground.ignoresSafeArea()

                List {
                    Section {
                        TextField("e.g. anu", text: $name)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .appFont(.body)
                            .foregroundColor(Color.primaryLabel)
                            .focused($focused)
                            .submitLabel(.send)
                            .onSubmit { Task { await submit() } }
                            .listRowBackground(Color.elevatedBackground)
                    } header: {
                        Text("Name").foregroundColor(Color.secondaryLabel)
                    } footer: {
                        Text("Lowercase letters only. They'll create a passkey on their first sign-in.")
                            .appFont(.footnote)
                            .foregroundColor(Color.secondaryLabel)
                    }

                    if let error {
                        Section {
                            Text(error)
                                .appFont(.footnote)
                                .foregroundColor(Color.red)
                                .listRowBackground(Color.elevatedBackground)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Invite User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .foregroundColor(Color.secondaryLabel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Invite") { Task { await submit() } }
                        .disabled(submitting || trimmed.isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func submit() async {
        guard !trimmed.isEmpty, !submitting else { return }
        error = nil; submitting = true
        defer { submitting = false }
        do {
            try await onSubmit(trimmed)
            isPresented = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}
