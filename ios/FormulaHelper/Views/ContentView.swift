import SwiftUI
@preconcurrency import ActivityKit

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
                }
            }
        }
        .task { await auth.checkStatus() }
    }
}

// MARK: - Loading

struct LoadingView: View {
    var body: some View {
        ZStack { Color.bg.ignoresSafeArea(); ProgressView().tint(Color.dim) }
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
    private var liveActivity: Activity<FormulaActivityAttributes>?
    private var expiryTask: Task<Void, Never>?

    func load() async {
        // Reconnect to any existing Live Activity from a previous session
        liveActivity = Activity<FormulaActivityAttributes>.activities.first
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
            await syncLiveActivity()
        } catch { if state == nil { errorMessage = error.localizedDescription } }
    }

    func startFeeding(ml: Int) async {
        do { let _ = try await APIClient.shared.startFeeding(ml: ml); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func logDiaper(type: String) async {
        do { try await APIClient.shared.logDiaper(type: type); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func resetTimer() async {
        do {
            try await APIClient.shared.resetTimer()
            NotificationManager.shared.cancelExpiry()
            await endLiveActivity()
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    private func syncLiveActivity() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let end = state?.countdown_end, end > Date().timeIntervalSince1970 else {
            await endLiveActivity(); return
        }
        let secs = Double(state?.settings.countdown_secs ?? 3900)
        let contentState = FormulaActivityAttributes.ContentState(
            countdownEnd: Date(timeIntervalSince1970: end),
            countdownStart: Date(timeIntervalSince1970: end - secs),
            lastMl: state?.mix_log.last?.ml ?? 0
        )
        let endDate = Date(timeIntervalSince1970: end)
        // staleDate set 2 min after expiry — expiryTask ends it cleanly before that
        let staleDate = endDate.addingTimeInterval(120)
        if let activity = liveActivity {
            await activity.update(ActivityContent(state: contentState, staleDate: staleDate))
        } else {
            do {
                liveActivity = try Activity.request(
                    attributes: FormulaActivityAttributes(),
                    content: ActivityContent(state: contentState, staleDate: staleDate)
                )
            } catch { /* ActivityKit unavailable or denied */ }
        }
        scheduleActivityExpiry(at: endDate)
    }

    private func endLiveActivity() async {
        expiryTask?.cancel()
        expiryTask = nil
        await liveActivity?.end(dismissalPolicy: .immediate)
        liveActivity = nil
    }

    private func scheduleActivityExpiry(at end: Date) {
        expiryTask?.cancel()
        expiryTask = Task {
            let delay = end.timeIntervalSinceNow
            guard delay > 0 else { await endLiveActivity(); return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await endLiveActivity()
        }
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

#if DEBUG
    func debugStartLiveActivity() async {
        let end = Date().addingTimeInterval(2 * 60)   // 2-min window for easy testing
        let contentState = FormulaActivityAttributes.ContentState(
            countdownEnd: end,
            countdownStart: Date(),
            lastMl: 120
        )
        do {
            liveActivity = try Activity.request(
                attributes: FormulaActivityAttributes(),
                content: ActivityContent(state: contentState, staleDate: end.addingTimeInterval(120))
            )
            scheduleActivityExpiry(at: end)
        } catch { print("LA error: \(error)") }
    }
#endif

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
    @EnvironmentObject var auth: AuthManager
    @State private var showSettings = false
    @State private var showLogs     = false
    @State private var showCustom   = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                Color.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // ── Banner ── ~75% of screen
                    BannerView(vm: vm)
                        .frame(height: geo.size.height * 0.70)

                    // ── Fixed button grid ── ~25%
                    ButtonGrid(vm: vm, showLogs: $showLogs, showCustom: $showCustom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Gear — ashok only
                if auth.authState.userName == "ashok" {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(Color.dim2)
                            .font(.system(size: 20))
                            .padding(16)
                    }
                    .padding(.top, 44)
                }

#if DEBUG
                // Live Activity test button — bottom left
                VStack {
                    Spacer()
                    HStack {
                        Button("▶ LA") {
                            Task { await vm.debugStartLiveActivity() }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.dim)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.card2)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.border, lineWidth: 1))
                        .padding(.leading, 14).padding(.bottom, 20)
                        Spacer()
                    }
                }
#endif
            }
        }
        .ignoresSafeArea(edges: .top)
        .sheet(isPresented: $showSettings) { SettingsView(vm: vm) }
        .sheet(isPresented: $showLogs)     { LogsView(vm: vm) }
        .sheet(isPresented: $showCustom) {
            AmountSheet(title: "Custom Amount", cta: "Start Feeding", isPresented: $showCustom,
                        powderPer60: vm.state?.powder_per_60 ?? 8.3) { ml in
                Task { await vm.startFeeding(ml: ml) }
            }
        }
    }
}

// MARK: - Banner

struct BannerView: View {
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

    var body: some View {
        ZStack {
            if isExpired {
                LinearGradient(
                    colors: [Color.red.opacity(0.08), Color(hex: "#50000a").opacity(0.4)],
                    startPoint: .top, endPoint: .bottom)
            } else {
                RadialGradient(
                    colors: [Color.green.opacity(0.04), Color.bg],
                    center: UnitPoint(x: 0.5, y: 0.4),
                    startRadius: 0, endRadius: 280)
            }

            VStack(spacing: 8) {
                Spacer()

                if let state = vm.state {
                    if !hasBottle {
                        subLabel("No active bottle", expired: false)
                        Text("–")
                            .font(.outfit(58, weight: .bold))
                            .foregroundColor(Color.dim2)
                    } else if isExpired {
                        subLabel("Bottle expired", expired: true)
                        Text("DISCARD")
                            .font(.outfit(44, weight: .bold))
                            .foregroundColor(Color.red)
                            .tracking(-0.5)
                    } else {
                        subLabel("\(state.mixed_ml)ml mixed at \(state.mixed_at_str)", expired: false)
                        Text(formatTimer(liveRemaining))
                            .font(.outfit(68, weight: .bold))
                            .foregroundColor(Color.green)
                            .monospacedDigit()
                            .tracking(-2)
                    }

                    if let est = vm.nextFeedingEstimate {
                        Text(est)
                            .font(.outfit(11, weight: .medium))
                            .tracking(2.5)
                            .foregroundColor(isExpired ? Color.red.opacity(0.6) : Color.dim)
                            .padding(.top, 2)
                    }
                } else {
                    ProgressView().tint(Color.dim)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func subLabel(_ s: String, expired: Bool) -> some View {
        Text(s.uppercased())
            .font(.outfit(11, weight: .medium))
            .tracking(2.5)
            .foregroundColor(expired ? Color.red.opacity(0.7) : Color.dim)
    }

    private func formatTimer(_ secs: Double) -> String {
        let s = max(0, Int(secs))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Button grid (fixed layout)

struct ButtonGrid: View {
    @ObservedObject var vm: StateViewModel
    @Binding var showLogs: Bool
    @Binding var showCustom: Bool

    // Use combos from state, drop 60ml, keep 90/100/120
    var presets: [Int] {
        vm.state?.combos.map { Int($0[0]) } ?? [90, 100, 120]
    }

    var pee: Int { vm.todayDiaperCounts.pee }
    var poo: Int { vm.todayDiaperCounts.poo }

    var body: some View {
        // Rows 1 & 2 share weight 10 each, row 3 gets weight 7 (30% less)
        // Total weight = 27 → row1&2 = 10/27 each, row3 = 7/27
        // Weights: presets=8, diapers=14, log/custom=5  (total=27)
        GeometryReader { geo in
            let h = geo.size.height
            let presetH = h * 8 / 27
            let diaperH = h * 14 / 27
            let actionH = h * 5 / 27

            VStack(spacing: 1) {
                // Row 1: 90 | 100 | 120
                HStack(spacing: 1) {
                    ForEach(presets, id: \.self) { ml in startBtn(ml: ml) }
                }
                .frame(height: presetH)

                // Row 2: Pee | Poo
                HStack(spacing: 1) {
                    diaperBtn(type: "pee", count: pee, label: "PEE",
                              fg: Color.yellow, bg: Color.yellow.opacity(0.06))
                    diaperBtn(type: "poo", count: poo, label: "POO",
                              fg: Color(hex: "#c87941"), bg: Color(hex: "#c87941").opacity(0.08))
                }
                .frame(height: diaperH)

                // Row 3: Log | Custom
                HStack(spacing: 1) {
                    gridBtn("Log", fg: Color.blue, bg: Color.blueBg)               { showLogs   = true }
                    gridBtn("Custom Amount", fg: Color.purple, bg: Color.purpleBg) { showCustom = true }
                }
                .frame(height: actionH)
            }
            .background(Color.border)
        }
    }

    private func startBtn(ml: Int) -> some View {
        Button { Task { await vm.startFeeding(ml: ml) } } label: {
            VStack(spacing: 2) {
                Text("\(ml)")
                    .font(.outfit(36, weight: .bold))
                    .foregroundColor(Color.green)
                    .tracking(-1)
                Text("ML")
                    .font(.outfit(9, weight: .medium))
                    .tracking(0.5)
                    .foregroundColor(Color.green.opacity(0.4))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.green.opacity(0.06))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func diaperBtn(type: String, count: Int, label: String, fg: Color, bg: Color) -> some View {
        Button { Task { await vm.logDiaper(type: type) } } label: {
            VStack(spacing: 3) {
                // Last changed — only on the most recently used diaper type
                if let ts = vm.lastDiaperTime(type: type) {
                    Text("LAST \(ts)")
                        .font(.outfit(11, weight: .medium))
                        .tracking(0.8)
                        .foregroundColor(fg.opacity(0.4))
                } else {
                    Text(" ").font(.outfit(11))
                }

                // Label
                Text(label)
                    .font(.outfit(36, weight: .bold))
                    .tracking(-1)
                    .foregroundColor(fg.opacity(0.85))

                // Count
                Text("\(count)")
                    .font(.outfit(11, weight: .medium))
                    .tracking(0.8)
                    .foregroundColor(fg.opacity(0.4))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(bg)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func gridBtn(_ label: String, fg: Color, bg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.outfit(14, weight: .semibold))
                .foregroundColor(fg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(bg)
        }
        .buttonStyle(PlainButtonStyle())
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
        ZStack {
            Color.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                // ── Header ──
                Text(title)
                    .font(.outfit(16, weight: .semibold))
                    .foregroundColor(Color.wht)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 20)
                    .padding(.bottom, 24)

                // ── Two panels ──
                HStack(spacing: 12) {
                    // Water panel
                    ZStack(alignment: .bottom) {
                        VStack(spacing: 6) {
                            Text("WATER")
                                .font(.outfit(10, weight: .semibold))
                                .tracking(1.5)
                                .foregroundColor(Color.blue)
                            Text("\(water)")
                                .font(.outfit(52, weight: .bold))
                                .foregroundColor(Color.blue)
                                .monospacedDigit()
                            Text("ml")
                                .font(.outfit(14, weight: .medium))
                                .foregroundColor(Color.dim)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        HStack(spacing: 10) {
                            pmButton("-", bg: Color.redBg, fg: Color.red) { water = max(0, water - 10) }
                            pmButton("+", bg: Color.blueBg, fg: Color.blue) { water = min(500, water + 10) }
                        }
                        .padding(.bottom, 20)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.bg2)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.border, lineWidth: 1))

                    // Powder panel
                    VStack(spacing: 6) {
                        Text("POWDER")
                            .font(.outfit(10, weight: .semibold))
                            .tracking(1.5)
                            .foregroundColor(water > 0 ? Color.green : Color.dim)
                        Text(water > 0 ? String(format: "%.1f", powder) : "--")
                            .font(.outfit(52, weight: .bold))
                            .foregroundColor(water > 0 ? Color.green : Color.dim)
                            .monospacedDigit()
                        Text("g")
                            .font(.outfit(14, weight: .medium))
                            .foregroundColor(Color.dim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(water > 0 ? Color(red: 0.07, green: 0.17, blue: 0.1) : Color.bg2)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.border, lineWidth: 1))
                }
                .padding(.horizontal, 20)

                // ── Bottom bar ──
                HStack(spacing: 0) {
                    Button("Cancel") { isPresented = false }
                        .font(.outfit(15, weight: .semibold))
                        .foregroundColor(Color.dim)
                        .frame(maxWidth: .infinity, minHeight: 64)

                    Rectangle().fill(Color.border).frame(width: 1, height: 64)

                    Button(cta) {
                        if water > 0 { onConfirm(water); isPresented = false }
                    }
                    .disabled(water <= 0)
                    .font(.outfit(15, weight: .semibold))
                    .foregroundColor(water > 0 ? Color.green : Color.dim)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(water > 0 ? Color.greenBg : Color.clear)
                }
                .background(Color.bg2)
                .overlay(Rectangle().fill(Color.border).frame(height: 1), alignment: .top)
            }
        }
    }

    private func pmButton(_ label: String, bg: Color, fg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.outfit(22, weight: .bold))
                .foregroundColor(fg)
                .frame(width: 52, height: 44)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

#Preview {
    ContentView().environmentObject(AuthManager.shared)
}
