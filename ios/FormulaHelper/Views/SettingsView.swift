import SwiftUI
import UIKit

// MARK: - Settings (native insetGrouped list)

struct SettingsView: View {
    @ObservedObject var vm: StateViewModel
    @EnvironmentObject var auth: AuthManager
    @State private var showResetConfirm = false
    @State private var households: [Household] = []
    @State private var activeHhId: String?
    @State private var prefetchedMembers: [String: [HouseholdMember]] = [:]
    @State private var showRedeemEntry = false
    @State private var redeemMessage: String?
    @State private var redeemError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.primaryBackground.ignoresSafeArea()

                List {
                    householdSection
                    timerSection
                    presetsSection
                    accountSection
                    aboutSection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.primaryBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task { await loadHouseholds() }
            .sheet(isPresented: $showRedeemEntry) {
                InviteCodeSheet(isPresented: $showRedeemEntry) { token in
                    Task { await redeem(token: token) }
                }
            }
        }
    }

    // MARK: Household section

    @ViewBuilder
    private var householdSection: some View {
        Section {
            if let active = activeHousehold {
                NavigationLink {
                    HouseholdDetailView(
                        household: active,
                        initialMembers: prefetchedMembers[active.hh_id] ?? [],
                        vm: vm
                    ) {
                        Task { await loadHouseholds() }
                    }
                    .environmentObject(auth)
                } label: {
                    SettingsRow(
                        icon: "house.fill",
                        tint: .orange,
                        title: active.name.isEmpty ? "Household" : active.name,
                        trailing: active.role.capitalized
                    )
                }
                .listRowBackground(Color.elevatedBackground)
            }

            Button {
                redeemMessage = nil
                redeemError = nil
                showRedeemEntry = true
            } label: {
                SettingsRow(
                    icon: "envelope.open.fill",
                    tint: .purple,
                    title: "Redeem invite code"
                )
            }
            .listRowBackground(Color.elevatedBackground)
        } header: {
            Text("Household").foregroundColor(Color.secondaryLabel)
        } footer: {
            if let redeemError {
                Text(redeemError).foregroundColor(Color.red.opacity(0.85))
            } else if let redeemMessage {
                Text(redeemMessage).foregroundColor(Color.secondaryLabel)
            }
        }
    }

    private var activeHousehold: Household? {
        guard let id = activeHhId else { return households.first }
        return households.first(where: { $0.hh_id == id }) ?? households.first
    }

    private func loadHouseholds() async {
        do {
            let resp = try await APIClient.shared.listHouseholds()
            households = resp.households
            activeHhId = resp.active_hh
            await prefetchMembers()
        } catch {
            // Non-fatal — just hide the section
        }
    }

    private func prefetchMembers() async {
        guard let active = activeHousehold else { return }
        if let resp = try? await APIClient.shared.listMembers(hhId: active.hh_id) {
            prefetchedMembers[active.hh_id] = HouseholdDetailView.sortMembers(resp.members)
        }
    }

    private func redeem(token: String) async {
        redeemMessage = nil
        redeemError = nil
        do {
            let resp = try await APIClient.shared.redeemInvite(token: token)
            var switched = false
            if let hhId = resp.hh_id {
                do {
                    _ = try await APIClient.shared.switchHousehold(hhId: hhId)
                    switched = true
                } catch {
                    // Joined but couldn't switch — surface as a non-fatal warning;
                    // user can switch manually from Settings.
                    redeemError = "Joined, but couldn't switch active household: \(error.localizedDescription)"
                }
            }
            await loadHouseholds()
            await vm.refresh()
            if redeemError == nil {
                let raw = resp.hh_name ?? ""
                let name = raw.isEmpty ? "household" : raw
                redeemMessage = switched
                    ? "Joined \(name). Switched to this household."
                    : "Joined \(name)."
            }
        } catch {
            redeemError = error.localizedDescription
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

    // MARK: Presets section

    @ViewBuilder
    private var presetsSection: some View {
        Section {
            NavigationLink {
                PresetsDetailView(vm: vm)
            } label: {
                SettingsRow(
                    icon: "square.grid.2x2.fill",
                    tint: .blue,
                    title: "Quick Amounts",
                    trailing: "\(preset1) · \(preset2) ml"
                )
            }
            .listRowBackground(Color.elevatedBackground)
        } header: {
            Text("Presets").foregroundColor(Color.secondaryLabel)
        }
    }

    private var preset1: Int { vm.state?.settings.preset1_ml ?? 90 }
    private var preset2: Int { vm.state?.settings.preset2_ml ?? 120 }

    private var hasActiveBottle: Bool {
        guard let end = vm.state?.countdown_end else { return false }
        return end > Date().timeIntervalSince1970
    }

    // MARK: Account section

    @ViewBuilder
    private var accountSection: some View {
        Section {
            Button(role: .destructive) {
                Task { await auth.logout() }
            } label: {
                SettingsRow(
                    icon: "rectangle.portrait.and.arrow.right",
                    tint: .red,
                    title: "Sign Out",
                    titleColor: .red
                )
            }
            .listRowBackground(Color.elevatedBackground)
        } header: {
            Text("Account").foregroundColor(Color.secondaryLabel)
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

            if let name = auth.authState.userName, !name.isEmpty {
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

// MARK: - Presets detail

struct PresetsDetailView: View {
    @ObservedObject var vm: StateViewModel
    @State private var preset1: Double
    @State private var preset2: Double
    @State private var saving = false

    init(vm: StateViewModel) {
        self.vm = vm
        _preset1 = State(initialValue: Double(vm.state?.settings.preset1_ml ?? 90))
        _preset2 = State(initialValue: Double(vm.state?.settings.preset2_ml ?? 120))
    }

    var body: some View {
        ZStack {
            Color.primaryBackground.ignoresSafeArea()

            List {
                presetSection(
                    title: "First Button",
                    value: $preset1,
                    tint: Color.blue
                )
                presetSection(
                    title: "Second Button",
                    value: $preset2,
                    tint: Color.blue
                )
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Quick Amounts")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func presetSection(title: String, value: Binding<Double>, tint: Color) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(value.wrappedValue))")
                        .font(.custom("Outfit", size: 48, relativeTo: .largeTitle).bold())
                        .foregroundColor(tint)
                        .monospacedDigit()
                    Text("ml")
                        .appFont(.title3)
                        .foregroundColor(Color.secondaryLabel)
                    Spacer()
                    if saving {
                        ProgressView().tint(Color.secondaryLabel).scaleEffect(0.8)
                    }
                }
                Slider(value: value, in: 30...240, step: 5) { editing in
                    if !editing { Task { await save() } }
                }
                .tint(tint)
                HStack {
                    Text("30 ml")
                    Spacer()
                    Text("240 ml")
                }
                .appFont(.caption1)
                .foregroundColor(Color.tertiaryLabel)
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.elevatedBackground)
        } header: {
            Text(title).foregroundColor(Color.secondaryLabel)
        }
    }

    private func save() async {
        saving = true
        try? await APIClient.shared.savePresets(preset1: Int(preset1), preset2: Int(preset2))
        await vm.refresh()
        saving = false
    }
}

// MARK: - Household detail

struct HouseholdDetailView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    let household: Household
    let vm: StateViewModel
    let onChange: () -> Void

    @State private var members: [HouseholdMember]
    @State private var loadingMembers = false
    @State private var membersError: String?

    init(household: Household, initialMembers: [HouseholdMember] = [], vm: StateViewModel, onChange: @escaping () -> Void) {
        self.household = household
        self.vm = vm
        self.onChange = onChange
        _members = State(initialValue: initialMembers)
    }

    @State private var creatingInvite = false
    @State private var inviteResult: InviteCreateResponse?
    @State private var showInviteShare = false
    @State private var inviteError: String?

    @State private var showLeaveConfirm = false
    @State private var leaveBlockedAlert = false
    @State private var showDeleteConfirm = false


    private var isOwner: Bool { household.role.lowercased() == "owner" }

    var body: some View {
        ZStack {
            Color.primaryBackground.ignoresSafeArea()
            List {
                membersSection
                if isOwner {
                    inviteSection
                }
                dangerZoneSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await loadMembers() }
        }
        .navigationTitle(household.name.isEmpty ? "Household" : household.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.primaryBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await loadMembers() }
        // Refresh the members list every time this view re-appears (e.g. after the
        // invite-share sheet dismisses, or after returning from background) so a
        // newly-joined member shows up without the user having to leave Settings.
        .onAppear {
            Task { await loadMembers() }
        }
        .sheet(isPresented: $showInviteShare, onDismiss: {
            // Someone may have redeemed the invite while the share sheet was open.
            Task { await loadMembers() }
        }) {
            if let invite = inviteResult {
                InviteShareSheet(invite: invite, isPresented: $showInviteShare)
            }
        }
    }

    // MARK: Sections

    private var membersSection: some View {
        Section {
            if loadingMembers && members.isEmpty {
                HStack {
                    ProgressView().tint(Color.secondaryLabel).scaleEffect(0.8)
                    Text("Loading members…")
                        .appFont(.footnote)
                        .foregroundColor(Color.secondaryLabel)
                }
                .listRowBackground(Color.elevatedBackground)
            } else if members.isEmpty {
                Text(membersError ?? "No members found")
                    .appFont(.footnote)
                    .foregroundColor(Color.secondaryLabel)
                    .listRowBackground(Color.elevatedBackground)
            } else {
                ForEach(members) { m in
                    if canChangeRole(m) {
                        NavigationLink {
                            MemberDetailView(
                                household: household,
                                member: m,
                                members: $members,
                                membersError: $membersError
                            )
                            .environmentObject(auth)
                        } label: {
                            memberRow(m)
                        }
                        .listRowBackground(Color.elevatedBackground)
                    } else {
                        memberRow(m)
                            .listRowBackground(Color.elevatedBackground)
                    }
                }
            }
        } header: {
            Text("Members").foregroundColor(Color.secondaryLabel)
        } footer: {
            if let membersError, !members.isEmpty {
                Text(membersError).foregroundColor(Color.red.opacity(0.85))
            } else if members.contains(where: canChangeRole) {
                Text("Tap a member to manage their role or remove them.")
                    .appFont(.footnote)
                    .foregroundColor(Color.secondaryLabel)
            }
        }
    }

    private func canChangeRole(_ m: HouseholdMember) -> Bool {
        guard isOwner else { return false }
        if m.role.lowercased() == "owner" { return false }
        if m.user_id == auth.authState.userId { return false }
        return true
    }

    private func memberRow(_ m: HouseholdMember) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.secondaryBackground)
                    .frame(width: 32, height: 32)
                Text(HouseholdDetailView.initials(for: m.name))
                    .font(.outfit(13, weight: .semibold))
                    .foregroundColor(Color.primaryLabel)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name.isEmpty ? "Unnamed" : m.name)
                    .appFont(.body)
                    .foregroundColor(Color.primaryLabel)
            }
            Spacer()
            Text(m.role.capitalized)
                .appFont(.footnote)
                .foregroundColor(Color.secondaryLabel)
        }
        .padding(.vertical, 2)
    }

    private var inviteSection: some View {
        Section {
            Button {
                Task { await createInvite() }
            } label: {
                HStack {
                    SettingsRow(
                        icon: "person.crop.circle.badge.plus",
                        tint: .green,
                        title: "Invite someone"
                    )
                    Spacer()
                    if creatingInvite {
                        ProgressView().tint(Color.secondaryLabel).scaleEffect(0.8)
                    }
                }
            }
            .disabled(creatingInvite)
            .listRowBackground(Color.elevatedBackground)
        } footer: {
            if let inviteError {
                Text(inviteError).foregroundColor(Color.red.opacity(0.85))
            }
        }
    }

    private var dangerZoneSection: some View {
        Section {
            Button(role: .destructive) {
                if isOwner {
                    leaveBlockedAlert = true
                } else {
                    showLeaveConfirm = true
                }
            } label: {
                SettingsRow(
                    icon: "rectangle.portrait.and.arrow.forward",
                    tint: .red,
                    title: "Leave household",
                    titleColor: .red
                )
            }
            .listRowBackground(Color.elevatedBackground)
            .confirmationDialog(
                "Leave \(household.name.isEmpty ? "household" : household.name)?",
                isPresented: $showLeaveConfirm,
                titleVisibility: .visible
            ) {
                Button("Leave", role: .destructive) {
                    Task { await leave() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll lose access to this household's logs and settings. Someone will need to send you a new invite to rejoin.")
            }
            .alert("Owners can't leave", isPresented: $leaveBlockedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Transfer ownership to another member or delete the household before leaving.")
            }

            if isOwner {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    SettingsRow(
                        icon: "trash.fill",
                        tint: .red,
                        title: "Delete household",
                        titleColor: .red
                    )
                }
                .listRowBackground(Color.elevatedBackground)
                .confirmationDialog(
                    "Delete \(household.name.isEmpty ? "household" : household.name)?",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        Task { await deleteHousehold() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All members will lose access. Logs, settings, and invites are retained but hidden. This can be reversed only via support.")
                }
            }
        } header: {
            Text("Danger Zone").foregroundColor(Color.red.opacity(0.85))
        }
    }

    // MARK: Actions

    private func loadMembers() async {
        loadingMembers = true
        defer { loadingMembers = false }
        do {
            let resp = try await APIClient.shared.listMembers(hhId: household.hh_id)
            members = HouseholdDetailView.sortMembers(resp.members)
            membersError = nil
        } catch {
            membersError = error.localizedDescription
        }
    }

    static func sortMembers(_ members: [HouseholdMember]) -> [HouseholdMember] {
        members.sorted { a, b in
            let order: (String) -> Int = { r in
                switch r.lowercased() {
                case "owner": return 0
                case "admin": return 1
                default: return 2
                }
            }
            let oa = order(a.role), ob = order(b.role)
            if oa != ob { return oa < ob }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func createInvite() async {
        inviteError = nil
        creatingInvite = true
        defer { creatingInvite = false }
        do {
            inviteResult = try await APIClient.shared.createInvite()
            showInviteShare = true
        } catch {
            inviteError = error.localizedDescription
        }
    }

    private func leave() async {
        do {
            _ = try await APIClient.shared.leaveHousehold(hhId: household.hh_id)
            await transitionAfterRemoval()
        } catch {
            inviteError = error.localizedDescription
        }
    }

    private func deleteHousehold() async {
        do {
            try await APIClient.shared.deleteHousehold(hhId: household.hh_id)
            await transitionAfterRemoval()
        } catch {
            inviteError = error.localizedDescription
        }
    }

    /// After leaving or deleting the current household, pick the next viable one
    /// or log out only if the user genuinely has no remaining memberships. A
    /// transient list-fetch failure must NOT log the user out — we surface the
    /// error and bail; the user can retry from the still-mounted detail view.
    private func transitionAfterRemoval() async {
        let list: HouseholdsListResponse
        do {
            list = try await APIClient.shared.listHouseholds()
        } catch {
            inviteError = "Couldn't refresh households (\(error.localizedDescription)). You're still signed in."
            return
        }
        if let next = list.households.first(where: { $0.hh_id != household.hh_id }) {
            do {
                _ = try await APIClient.shared.switchHousehold(hhId: next.hh_id)
            } catch {
                inviteError = "Couldn't switch household (\(error.localizedDescription))."
                return
            }
            await vm.refresh()
            onChange()
            dismiss()
        } else {
            // Genuinely no households left — sign out.
            await auth.logout()
        }
    }

    static func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map { String($0) }
        return letters.joined().uppercased().ifEmpty("·")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: - Member detail

struct MemberDetailView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    let household: Household
    let member: HouseholdMember
    @Binding var members: [HouseholdMember]
    @Binding var membersError: String?

    @State private var working = false
    @State private var confirmPromote = false
    @State private var confirmKick = false
    @State private var localError: String?

    /// Live role from the parent's members array (so this view reflects updates that
    /// happened while it was on screen — e.g. a refetch from another device).
    private var currentRole: String {
        members.first(where: { $0.user_id == member.user_id })?.role ?? member.role
    }

    private var isAdmin: Bool { currentRole.lowercased() == "admin" }

    var body: some View {
        ZStack {
            Color.primaryBackground.ignoresSafeArea()
            List {
                headerSection
                roleSection
                removeSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .disabled(working)
        }
        .navigationTitle(member.name.isEmpty ? "Member" : member.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.primaryBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .alert("Make \(displayName) an admin?", isPresented: $confirmPromote) {
            Button("Make admin") { Task { await applyRole("admin") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Admins can invite and remove other members. Only owners can change roles or delete the household.")
        }
        .alert("Remove \(displayName)?", isPresented: $confirmKick) {
            Button("Remove", role: .destructive) { Task { await performKick() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They'll immediately lose access to this household's logs and settings.")
        }
        // If the parent's members array no longer contains this user (kicked from
        // another device, or removed via pull-to-refresh while we were open),
        // dismiss back to the list rather than showing a stale page.
        .onChange(of: members) { _, newMembers in
            if !newMembers.contains(where: { $0.user_id == member.user_id }) {
                dismiss()
            }
        }
    }

    private var displayName: String { member.name.isEmpty ? "this member" : member.name }

    // MARK: Sections

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.secondaryBackground)
                        .frame(width: 48, height: 48)
                    Text(HouseholdDetailView.initials(for: member.name))
                        .font(.outfit(17, weight: .semibold))
                        .foregroundColor(Color.primaryLabel)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(member.name.isEmpty ? "Unnamed" : member.name)
                        .font(.outfit(17, weight: .semibold))
                        .foregroundColor(Color.primaryLabel)
                    rolePill(currentRole)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.elevatedBackground)
        }
    }

    private func rolePill(_ role: String) -> some View {
        Text(role.capitalized.isEmpty ? "Member" : role.capitalized)
            .font(.outfit(11, weight: .semibold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundColor(role.lowercased() == "admin" ? .green : Color.secondaryLabel)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(role.lowercased() == "admin" ? Color.greenFill : Color.secondaryBackground)
            )
            .overlay(
                Capsule().stroke(role.lowercased() == "admin" ? Color.greenBorder : Color.opaqueSeparator, lineWidth: 1)
            )
    }

    private var roleSection: some View {
        Section {
            roleRow(
                role: "admin",
                title: "Admin",
                subtitle: "Can invite and remove members."
            )
            roleRow(
                role: "member",
                title: "Member",
                subtitle: "Can view and log entries."
            )
        } header: {
            Text("Role").foregroundColor(Color.secondaryLabel)
        } footer: {
            if let localError {
                Text(localError).foregroundColor(Color.red.opacity(0.85))
            }
        }
    }

    private func roleRow(role: String, title: String, subtitle: String) -> some View {
        let isCurrent = currentRole.lowercased() == role
        return Button {
            tapRole(role)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .appFont(.body)
                        .foregroundColor(Color.primaryLabel)
                    Text(subtitle)
                        .appFont(.footnote)
                        .foregroundColor(Color.secondaryLabel)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.green)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent || working)
        .listRowBackground(Color.elevatedBackground)
    }

    private var removeSection: some View {
        Section {
            Button(role: .destructive) {
                confirmKick = true
            } label: {
                HStack {
                    SettingsRow(
                        icon: "person.crop.circle.badge.minus",
                        tint: .red,
                        title: "Remove from household",
                        titleColor: .red
                    )
                    Spacer()
                    if working {
                        ProgressView().tint(Color.secondaryLabel).scaleEffect(0.8)
                    }
                }
            }
            .disabled(working)
            .listRowBackground(Color.elevatedBackground)
        } header: {
            Text("Danger zone").foregroundColor(Color.red.opacity(0.85))
        }
    }

    // MARK: Actions

    private func tapRole(_ newRole: String) {
        guard currentRole.lowercased() != newRole else { return }
        if newRole == "admin" {
            // Promotion grants invite + kick capabilities — confirm first.
            confirmPromote = true
        } else {
            // Demotion is reversible and lower-stakes — apply immediately.
            Task { await applyRole(newRole) }
        }
    }

    private func applyRole(_ newRole: String) async {
        localError = nil
        working = true
        defer { working = false }
        do {
            try await APIClient.shared.updateMemberRole(
                hhId: household.hh_id,
                userId: member.user_id,
                role: newRole
            )
            if let idx = members.firstIndex(where: { $0.user_id == member.user_id }) {
                let m = members[idx]
                members[idx] = HouseholdMember(
                    user_id: m.user_id,
                    name: m.name,
                    role: newRole,
                    joined_at: m.joined_at
                )
            }
            members = HouseholdDetailView.sortMembers(members)
            membersError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func performKick() async {
        localError = nil
        working = true
        do {
            try await APIClient.shared.kickMember(hhId: household.hh_id, userId: member.user_id)
            members.removeAll { $0.user_id == member.user_id }
            // dismiss() will fire via the `.onChange(of: members)` above, but call it
            // explicitly so the back-pop animation isn't gated on a state diff round-trip.
            dismiss()
        } catch {
            localError = error.localizedDescription
            working = false
        }
    }
}

// MARK: - Invite share sheet

struct InviteShareSheet: View {
    let invite: InviteCreateResponse
    @Binding var isPresented: Bool
    @State private var justCopied = false

    private var expiresText: String {
        let remaining = invite.expires - Date().timeIntervalSince1970
        if remaining <= 0 { return "Expired" }
        let hours = Int(remaining / 3600)
        if hours >= 24 { return "Expires in \(hours / 24) day\(hours / 24 == 1 ? "" : "s")" }
        if hours >= 1 { return "Expires in \(hours) hour\(hours == 1 ? "" : "s")" }
        let mins = max(1, Int(remaining / 60))
        return "Expires in \(mins) min"
    }

    private var shareMessage: String {
        let name = invite.hh_name.isEmpty ? "our household" : invite.hh_name
        return "Join \(name) on AvantiLog. Open the app, tap Join with Invite, and paste this code: \(invite.token)"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.primaryBackground.ignoresSafeArea()
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Text(invite.token)
                                    .font(.custom("Outfit", size: 22, relativeTo: .title).weight(.semibold))
                                    .foregroundColor(Color.primaryLabel)
                                    .monospaced()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    UIPasteboard.general.string = invite.token
                                    withAnimation { justCopied = true }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        withAnimation { justCopied = false }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                                            .font(.system(size: 13, weight: .semibold))
                                        Text(justCopied ? "Copied" : "Copy")
                                            .font(.outfit(13, weight: .semibold))
                                    }
                                    .foregroundColor(Color.green)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.greenFill)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.greenBorder, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                            Text(expiresText)
                                .appFont(.footnote)
                                .foregroundColor(Color.secondaryLabel)
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.elevatedBackground)
                    } header: {
                        Text("Invite code").foregroundColor(Color.secondaryLabel)
                    } footer: {
                        Text("Anyone with this code can join the household until it expires or is used.")
                            .appFont(.footnote)
                            .foregroundColor(Color.secondaryLabel)
                    }

                    Section {
                        ShareLink(item: shareMessage) {
                            SettingsRow(
                                icon: "square.and.arrow.up",
                                tint: .blue,
                                title: "Share"
                            )
                        }
                        .listRowBackground(Color.elevatedBackground)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Invite someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }
}
