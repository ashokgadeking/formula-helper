import SwiftUI
import UIKit

enum Haptics {
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        let g = UIImpactFeedbackGenerator(style: style)
        g.impactOccurred()
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var auth: AuthManager
    @StateObject private var vm = StateViewModel()

    var body: some View {
        Group {
            switch auth.authState {
            case .loading:       LoadingView()
            case .unauthenticated: AuthView()
            case .authenticated:
                MainView(vm: vm).task {
                    await vm.load()
                    await NotificationManager.shared.requestPermission()
                    NotificationManager.shared.onActionComplete = { [weak vm] in
                        await vm?.refresh()
                    }
                }
            }
        }
        .task { await auth.checkStatus() }
    }
}

// MARK: - Loading

struct LoadingView: View {
    var body: some View {
        ZStack { Color.primaryBackground.ignoresSafeArea(); ProgressView().tint(Color.secondaryLabel) }
    }
}

// MARK: - ViewModel

@MainActor
final class StateViewModel: ObservableObject {
    @Published var state: AppStateResponse?
    @Published var errorMessage: String?

    private(set) var avgDayRatePerMl: Double?
    private(set) var avgNightRatePerMl: Double?
    private var pollTask: Task<Void, Never>?

    func load() async {
        if let cached = CacheManager.shared.restore(), state == nil {
            state = cached; computeRates()
        }
        await refresh()
        startPolling()
    }

    func refresh() async {
        do {
            let fresh = try await APIClient.shared.getState()
            state = fresh; CacheManager.shared.save(fresh); computeRates(); errorMessage = nil
            syncNotification()
        } catch { if state == nil { errorMessage = error.localizedDescription } }
    }

    func startFeeding(ml: Int) async {
        // Optimistic: update local state so the banner/timer renders immediately.
        if var s = state {
            let now = Date().timeIntervalSince1970
            let secs = Double(s.settings.countdown_secs)
            s.countdown_end = now + secs
            s.remaining_secs = secs
            s.expired = false
            let f = DateFormatter(); f.dateFormat = "h:mm a"
            s.mixed_at_str = f.string(from: Date())
            s.mixed_ml = ml
            let dateF = DateFormatter()
            dateF.dateFormat = "yyyy-MM-dd hh:mm a"
            dateF.locale = Locale(identifier: "en_US_POSIX")
            let pending = LogEntry(
                sk: "pending-\(UUID().uuidString)",
                text: "\(ml)ml @ \(f.string(from: Date()))",
                leftover: "",
                ml: ml,
                date: dateF.string(from: Date()),
                created_by: ""
            )
            s.mix_log.append(pending)
            state = s
            syncNotification()
        }
        do {
            let _ = try await APIClient.shared.startFeeding(ml: ml)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
        }
    }

    func logDiaper(type: String) async {
        do { try await APIClient.shared.logDiaper(type: type); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func logNap() async {
        do { try await APIClient.shared.logNap(); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func resetTimer() async {
        do {
            try await APIClient.shared.resetTimer()
            NotificationManager.shared.cancelExpiry()
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    private func syncNotification() {
        if let end = state?.countdown_end, end > Date().timeIntervalSince1970 {
            let secs = Double(state?.settings.countdown_secs ?? 3900)
            NotificationManager.shared.scheduleExpiry(at: end, mixedAt: end - secs)
        } else {
            NotificationManager.shared.cancelExpiry()
        }
    }

    var nextFeedingEstimate: String? {
        guard let state, !state.mix_log.isEmpty else { return nil }
        let last = state.mix_log.last!
        let consumed = Double(last.consumedMl > 0 ? last.consumedMl : last.ml)
        guard consumed > 0 else { return nil }
        let h = Calendar.current.component(.hour, from: Date())
        let rate = (h >= 10 && h < 22) ? avgDayRatePerMl : avgNightRatePerMl
        guard let rate, rate > 0 else { return nil }
        let gapMins = rate * consumed
        guard gapMins > 0 && gapMins < 360 else { return nil }
        let nextDate = (parseDate(last.date) ?? Date()).addingTimeInterval(gapMins * 60)
        guard nextDate > Date() else { return nil }
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return "EST. NEXT \(f.string(from: nextDate).uppercased())"
    }

    var todayDiaperCounts: (pee: Int, poo: Int) {
        guard let log = state?.diaper_log else { return (0, 0) }
        let cutoff = Calendar.current.startOfDay(for: Date())
        let f = diaperDateFormatter
        let today = log.filter { f.date(from: $0.date).map { $0 >= cutoff } ?? false }
        return (today.filter { $0.type == "pee" }.count, today.filter { $0.type == "poo" }.count)
    }

    /// Returns timestamp string only if the most recent diaper entry overall is of the given type.
    func lastDiaperTime(type: String) -> String? {
        guard let log = state?.diaper_log, !log.isEmpty else { return nil }
        let f = diaperDateFormatter
        let last = log
            .compactMap { e -> (date: Date, type: String)? in
                guard let d = f.date(from: e.date) else { return nil }
                return (d, e.type)
            }
            .max(by: { $0.date < $1.date })
        guard let last, last.type == type else { return nil }
        let out = DateFormatter(); out.dateFormat = "h:mm a"
        return out.string(from: last.date)
    }

    var todayNapCount: Int {
        guard let log = state?.nap_log else { return 0 }
        let cutoff = Calendar.current.startOfDay(for: Date())
        let f = diaperDateFormatter
        return log.filter { f.date(from: $0.date).map { $0 >= cutoff } ?? false }.count
    }

    var lastNapTime: String? {
        guard let log = state?.nap_log, !log.isEmpty else { return nil }
        let f = diaperDateFormatter
        let last = log.compactMap { f.date(from: $0.date) }.max()
        guard let last else { return nil }
        let out = DateFormatter(); out.dateFormat = "h:mm a"
        return out.string(from: last)
    }

    private var diaperDateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    private func computeRates() {
        guard let entries = state?.mix_log, entries.count >= 2 else { return }
        let sorted = entries.compactMap { e -> (date: Date, ml: Int)? in
            guard let d = parseDate(e.date), e.ml > 0 else { return nil }
            return (d, e.consumedMl > 0 ? e.consumedMl : e.ml)
        }.sorted { $0.date < $1.date }
        var day: [Double] = [], night: [Double] = []
        for i in 1..<sorted.count {
            let prev = sorted[i-1], curr = sorted[i]
            let ml = Double(prev.ml); guard ml > 0 else { continue }
            let gap = curr.date.timeIntervalSince(prev.date) / 60
            guard gap > 0 && gap <= 360 else { continue }
            let h = Calendar.current.component(.hour, from: prev.date)
            if h >= 10 && h < 22 { day.append(gap/ml) } else { night.append(gap/ml) }
        }
        avgDayRatePerMl   = day.isEmpty   ? nil : day.reduce(0,+)   / Double(day.count)
        avgNightRatePerMl = night.isEmpty ? nil : night.reduce(0,+) / Double(night.count)
    }

    func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }
    }
}

// MARK: - Main view

struct MainView: View {
    @ObservedObject var vm: StateViewModel
    var body: some View { RootTabView(vm: vm) }
}

// MARK: - Root tab view

struct RootTabView: View {
    @ObservedObject var vm: StateViewModel
    @Environment(\.scenePhase) private var scenePhase

    init(vm: StateViewModel) {
        self.vm = vm
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .black
        let selected = UIColor.white
        let unselected = UIColor(red: 0.25, green: 0.25, blue: 0.27, alpha: 1.0)
        for item in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            item.selected.iconColor = selected
            item.selected.titleTextAttributes = [.foregroundColor: selected]
            item.normal.iconColor = unselected
            item.normal.titleTextAttributes = [.foregroundColor: unselected]
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().unselectedItemTintColor = unselected
        UITabBar.appearance().tintColor = selected
    }

    var body: some View {
        TabView {
            FeedTab(vm: vm)
                .tabItem { Image(systemName: "drop.fill") }
            LogsView(vm: vm)
                .tabItem { Image(systemName: "list.bullet") }
            TrendsView(vm: vm, section: .formula)
                .tabItem { Image(systemName: "chart.bar.fill") }
            SettingsView(vm: vm)
                .tabItem { Image(systemName: "gearshape.fill") }
        }
        .toolbarBackground(Color.primaryBackground.opacity(0.85), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .tint(.white)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await vm.refresh() }
            }
        }
    }
}

// MARK: - Feed tab

struct FeedTab: View {
    @ObservedObject var vm: StateViewModel
    @State private var showCustom = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.primaryBackground.ignoresSafeArea()

            VStack(spacing: 16) {
                HeroCard(vm: vm)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                QuickLogSection(vm: vm, showCustom: $showCustom)
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
            .padding(.horizontal, 8)

        }
        .sheet(isPresented: $showCustom) {
            AmountSheet(title: "Custom Amount", cta: "Start Feeding", isPresented: $showCustom,
                        powderPer60: vm.state?.powder_per_60 ?? 8.3) { ml in
                Task { await vm.startFeeding(ml: ml) }
            }
        }
    }
}

// MARK: - Hero card (timer)

struct HeroCard: View {
    @ObservedObject var vm: StateViewModel

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1.0)) { context in
            BannerContent(vm: vm, now: context.date)
        }
    }
}

private struct BannerContent: View {
    @ObservedObject var vm: StateViewModel
    let now: Date   // driven by TimelineView — guarantees 1s re-render

    private var liveRemaining: Double {
        guard let end = vm.state?.countdown_end, end > 0 else { return -1 }
        return max(0, end - now.timeIntervalSince1970)
    }

    private var isExpired: Bool {
        guard let end = vm.state?.countdown_end, end > 0 else { return false }
        return now.timeIntervalSince1970 >= end
    }

    private var hasBottle: Bool { (vm.state?.countdown_end ?? 0) > 0 }

    /// Seconds elapsed since the most recent bottle was mixed.
    /// Derived from `countdown_end - countdown_secs` (the mix instant the server anchored to).
    private var sinceMixedSecs: Double? {
        guard let state = vm.state, state.countdown_end > 0 else { return nil }
        let mixedAt = state.countdown_end - Double(state.settings.countdown_secs)
        let elapsed = now.timeIntervalSince1970 - mixedAt
        return elapsed > 0 ? elapsed : nil
    }

    private func formatSinceMixed(_ secs: Double) -> String {
        let total = Int(secs)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m since last bottle" }
        return "\(m)m since last bottle"
    }

    var body: some View {
        ZStack {
            if isExpired {
                LinearGradient(
                    colors: [Color.red.opacity(0.08), Color(hex: "#50000a").opacity(0.35)],
                    startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                Color.primaryBackground
            }

            VStack(spacing: 8) {
                if let state = vm.state {
                    if !hasBottle {
                        subLabel("No active bottle", expired: false)
                        Text("–")
                            .font(.custom("Outfit", size: 72, relativeTo: .largeTitle).bold())
                            .foregroundColor(Color.tertiaryLabel)
                    } else if isExpired {
                        Text("Bottle expired — mixed at \(state.mixed_at_str)".uppercased())
                            .appFont(.subheadline)
                            .tracking(1.5)
                            .foregroundColor(Color.red.opacity(0.7))
                        Text("DISCARD")
                            .font(.custom("Outfit", size: 52, relativeTo: .largeTitle).bold())
                            .foregroundColor(Color.red)
                            .tracking(-0.5)
                    } else {
                        subLabel("\(state.mixed_ml)ml mixed at \(state.mixed_at_str)", expired: false)
                        Text(formatTimer(liveRemaining))
                            .font(.custom("Outfit", size: 72, relativeTo: .largeTitle).bold())
                            .foregroundColor(Color.green)
                            .monospacedDigit()
                            .tracking(-1.5)
                    }

                    if let est = vm.nextFeedingEstimate {
                        Text(est)
                            .appFont(isExpired ? .body : .subheadline)
                            .tracking(1.2)
                            .foregroundColor(isExpired ? Color.red.opacity(0.6) : Color.secondaryLabel)
                            .padding(.top, 4)
                    }

                    if isExpired, let secs = sinceMixedSecs {
                        Text(formatSinceMixed(secs))
                            .appFont(.body)
                            .tracking(1.2)
                            .foregroundColor(Color.red.opacity(0.6))
                            .padding(.top, 4)
                    }
                } else {
                    ProgressView().tint(Color.secondaryLabel)
                }
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func subLabel(_ s: String, expired: Bool) -> some View {
        Text(s.uppercased())
            .appFont(.footnote)
            .tracking(1.5)
            .foregroundColor(expired ? Color.red.opacity(0.7) : Color.secondaryLabel)
    }

    private func formatTimer(_ secs: Double) -> String {
        let s = max(0, Int(secs))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Quick log cards

struct QuickLogSection: View {
    @ObservedObject var vm: StateViewModel
    @Binding var showCustom: Bool

    private let pooColor = Color(hex: "#c87941")

    private var preset1: Int { vm.state?.settings.preset1_ml ?? 90 }
    private var preset2: Int { vm.state?.settings.preset2_ml ?? 120 }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                FormulaCard(ml: preset1) { Task { await vm.startFeeding(ml: preset1) } }
                FormulaCard(ml: preset2) { Task { await vm.startFeeding(ml: preset2) } }
                CustomFormulaCard { showCustom = true }
            }

            HStack(spacing: 8) {
                DiaperCard(
                    symbol: nil,
                    label: "PEE",
                    count: vm.todayDiaperCounts.pee,
                    lastTime: vm.lastDiaperTime(type: "pee"),
                    fg: Color.yellow,
                    bg: Color.yellow.opacity(0.06),
                    border: Color.yellow.opacity(0.18)
                ) { Task { await vm.logDiaper(type: "pee") } }

                DiaperCard(
                    symbol: nil,
                    label: "POO",
                    count: vm.todayDiaperCounts.poo,
                    lastTime: vm.lastDiaperTime(type: "poo"),
                    fg: pooColor,
                    bg: pooColor.opacity(0.08),
                    border: pooColor.opacity(0.20)
                ) { Task { await vm.logDiaper(type: "poo") } }

                DiaperCard(
                    symbol: nil,
                    label: "NAP",
                    count: vm.todayNapCount,
                    lastTime: vm.lastNapTime,
                    fg: Color.purple,
                    bg: Color.purpleFill,
                    border: Color.purpleBorder
                ) { Task { await vm.logNap() } }
            }
        }
    }
}

struct CustomFormulaCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            VStack(spacing: 0) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Color.green)
                Text("CUSTOM")
                    .appFont(.caption2)
                    .tracking(1.5)
                    .foregroundColor(Color.green.opacity(0.55))
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.greenBorder, lineWidth: 1)
            )
        }
        .buttonStyle(ScaledButtonStyle())
        .accessibilityLabel("Log custom amount")
    }
}

struct FormulaCard: View {
    let ml: Int
    let action: () -> Void

    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            VStack(spacing: 0) {
                Text("\(ml)")
                    .font(.custom("Outfit", size: 32, relativeTo: .title).bold())
                    .foregroundColor(Color.green)
                    .monospacedDigit()
                    .tracking(-0.5)
                Text("ml")
                    .appFont(.caption2)
                    .tracking(1.5)
                    .foregroundColor(Color.green.opacity(0.55))
            }
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.greenBorder, lineWidth: 1)
            )
        }
        .buttonStyle(ScaledButtonStyle())
        .accessibilityLabel("Start \(ml) millilitre bottle")
    }
}

struct DiaperCard: View {
    let symbol: String?
    let label: String
    let count: Int
    let lastTime: String?
    let fg: Color
    let bg: Color
    let border: Color
    let action: () -> Void

    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            ZStack(alignment: .bottomLeading) {
                VStack(alignment: .center, spacing: 6) {
                    Text(label)
                        .appFont(.headline)
                        .tracking(0.5)
                        .foregroundColor(fg)
                    if let ts = lastTime {
                        Text("LAST \(ts.uppercased())")
                            .appFont(.caption2)
                            .tracking(1.2)
                            .foregroundColor(fg.opacity(0.45))
                    } else {
                        Text(" ")
                            .appFont(.caption2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
        }
        .buttonStyle(ScaledButtonStyle())
        .accessibilityLabel("Log \(label.lowercased()) diaper")
    }
}

// MARK: - Amount sheet

struct AmountSheet: View {
    let title: String
    let cta: String
    @Binding var isPresented: Bool
    let powderPer60: Double
    let onConfirm: (Int) -> Void
    @State private var water: Int = 90

    private var powder: Double { Double(water) * (powderPer60 / 60.0) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.primaryBackground.ignoresSafeArea()

                VStack(spacing: 24) {
                    // ── Display panels ──
                    HStack(spacing: 12) {
                        amountPanel(
                            label: "WATER",
                            value: "\(water)",
                            unit: "ml",
                            color: Color.blue,
                            fill: Color.blueFill,
                            border: Color.blueBorder
                        )
                        amountPanel(
                            label: "POWDER",
                            value: water > 0 ? String(format: "%.1f", powder) : "—",
                            unit: "g",
                            color: water > 0 ? Color.green : Color.tertiaryLabel,
                            fill: water > 0 ? Color.greenFill : Color.tertiaryFill,
                            border: water > 0 ? Color.greenBorder : Color.separator
                        )
                    }
                    .frame(height: 196)
                    .padding(.horizontal, 16)

                    // ── Stepper row ──
                    HStack(spacing: 16) {
                        stepperBtn(symbol: "minus", fill: Color.redFill, fg: Color.red, border: Color.redBorder) {
                            water = max(0, water - 10)
                        }
                        .accessibilityLabel("Decrease by 10 ml")

                        Text("\(water) ml")
                            .appFont(.title3)
                            .foregroundColor(Color.primaryLabel)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .center)

                        stepperBtn(symbol: "plus", fill: Color.blueFill, fg: Color.blue, border: Color.blueBorder) {
                            water = min(500, water + 10)
                        }
                        .accessibilityLabel("Increase by 10 ml")
                    }
                    .padding(.horizontal, 16)

                    // ── CTA ──
                    Button {
                        guard water > 0 else { return }
                        onConfirm(water)
                        isPresented = false
                    } label: {
                        Text(cta)
                            .appFont(.headline)
                            .foregroundColor(water > 0 ? Color.green : Color.tertiaryLabel)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(water > 0 ? Color.greenFill : Color.tertiaryFill)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(water > 0 ? Color.greenBorder : Color.separator, lineWidth: 1)
                            )
                    }
                    .disabled(water <= 0)
                    .buttonStyle(ScaledButtonStyle())
                    .padding(.horizontal, 16)
                    .accessibilityLabel(cta)
                }
                .padding(.top, 8)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .foregroundColor(Color.secondaryLabel)
                }
            }
        }
        .presentationDetents([.fraction(0.6), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.primaryBackground)
    }

    private func amountPanel(label: String, value: String, unit: String,
                              color: Color, fill: Color, border: Color) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .appFont(.caption2)
                .tracking(1.2)
                .foregroundColor(color)
                .padding(.top, 20)
            Spacer()
            Text(value)
                .font(.custom("Outfit", size: 52, relativeTo: .largeTitle).bold())
                .foregroundColor(color)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(unit)
                .appFont(.callout)
                .foregroundColor(Color.secondaryLabel)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(fill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
    }

    private func stepperBtn(symbol: String, fill: Color, fg: Color, border: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(fg)
                .frame(width: 56, height: 56)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(border, lineWidth: 1)
                )
        }
        .buttonStyle(ScaledButtonStyle())
    }
}

#Preview {
    ContentView().environmentObject(AuthManager.shared)
}
