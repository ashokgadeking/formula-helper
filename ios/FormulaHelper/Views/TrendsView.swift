import SwiftUI
import Charts

// MARK: - Trends page

struct TrendsView: View {
    @ObservedObject var vm: StateViewModel
    @Environment(\.dismiss) private var dismiss
    @State var section: TrendSection

    enum TrendSection { case formula, diaper }

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                headerView
                sectionTabBar
                Divider().background(Color.border)
                // Both sections fill remaining space — no outer ScrollView
                if section == .formula {
                    FormulaTrends(vm: vm)
                } else {
                    DiaperTrends(vm: vm)
                }
                bottomBar
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 4) {
            Text(section == .formula ? "FORMULA" : "DIAPERS")
                .font(.outfit(10, weight: .medium))
                .tracking(2.5)
                .foregroundColor(Color.dim)
            Text(section == .formula ? "Consumption" : "Diaper Log")
                .font(.outfit(28, weight: .bold))
                .foregroundColor(Color.wht)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Section tabs

    private var sectionTabBar: some View {
        HStack(spacing: 1) {
            sectionTabBtn("Formula", s: .formula)
            sectionTabBtn("Diapers", s: .diaper)
        }
        .background(Color.border)
    }

    private func sectionTabBtn(_ label: String, s: TrendSection) -> some View {
        Button { withAnimation(.spring(duration: 0.2)) { section = s } } label: {
            Text(label)
                .font(.outfit(13, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(section == s ? Color.blue : Color.dim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(section == s ? Color.blueBg : Color.bg2)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            Button { dismiss() } label: {
                Text("Back")
                    .font(.outfit(15, weight: .semibold))
                    .foregroundColor(Color.dim)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
            }
        }
        .background(Color.bg2)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.borderLight).frame(height: 1)
        }
    }
}

// MARK: - Formula Trends

private struct FormulaTrends: View {
    @ObservedObject var vm: StateViewModel
    @State private var range: FormulaRange = .week

    enum FormulaRange: String, CaseIterable {
        case week = "Week", month = "Month", year = "Year", all = "All"
        var days: Int? {
            switch self {
            case .week:  return 7
            case .month: return 30
            case .year:  return 365
            case .all:   return nil
            }
        }
    }

    struct DailyBar: Identifiable {
        let id = UUID()
        let day: Date
        let kind: String  // "Consumed" | "Leftover"
        let ml: Int
    }

    // MARK: Computed

    private var entryFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    private func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    private var filtered: [LogEntry] {
        guard let entries = vm.state?.mix_log else { return [] }
        guard let days = range.days,
              let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else {
            return entries
        }
        let f = entryFormatter
        return entries.filter { e in
            guard let d = f.date(from: e.date) else { return false }
            return d >= cutoff
        }
    }

    private var totalMl: Int { filtered.reduce(0) { $0 + $1.ml } }
    private var bottleCount: Int { filtered.count }

    private var avgMlPerDay: Int {
        let f = entryFormatter
        let days = Set(filtered.compactMap { f.date(from: $0.date).map { dayKey($0) } }).count
        return days > 0 ? totalMl / days : 0
    }

    private var dayGap: String { formatGap(avgGap(isDay: true)) }
    private var nightGap: String { formatGap(avgGap(isDay: false)) }

    private var dailyBars: [DailyBar] {
        let f = entryFormatter
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        var byDay: [String: (date: Date, consumed: Int, leftover: Int)] = [:]
        for e in filtered {
            guard let d = f.date(from: e.date) else { continue }
            let key = dayKey(d)
            let lo = Int(e.leftover.filter(\.isNumber)) ?? 0
            let consumed = max(0, e.ml - lo)
            if byDay[key] == nil { byDay[key] = (d, 0, 0) }
            byDay[key]!.consumed += consumed
            byDay[key]!.leftover += lo
        }
        var bars: [DailyBar] = []
        for (_, v) in byDay {
            let dayStart = Calendar.current.startOfDay(for: v.date)
            bars.append(DailyBar(day: dayStart, kind: "Consumed", ml: v.consumed))
            if v.leftover > 0 {
                bars.append(DailyBar(day: dayStart, kind: "Leftover", ml: v.leftover))
            }
        }
        return bars.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            return $0.kind == "Consumed"
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Range pill tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(FormulaRange.allCases, id: \.self) { r in
                        Button { withAnimation(.spring(duration: 0.2)) { range = r } } label: {
                            Text(r.rawValue)
                                .font(.outfit(12, weight: .semibold))
                                .foregroundColor(range == r ? Color.blue : Color.dim)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                                .background(range == r ? Color.blueBg : Color.card)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(range == r ? Color.blueBd : Color.border, lineWidth: 1))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            // Stat cards
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 8) {
                statCard(value: fmtMl(totalMl),     label: "Total ml",    color: Color.blue)
                statCard(value: "\(bottleCount)",    label: "Bottles",     color: Color.green)
                statCard(value: fmtMl(avgMlPerDay), label: "Avg ml/day",  color: Color.yellow)
            }
            .padding(.horizontal, 14)

            // Insight cards
            HStack(spacing: 8) {
                insightCard(value: dayGap,   label: "☀️ Avg gap · Day",   color: Color.yellow)
                insightCard(value: nightGap, label: "🌙 Avg gap · Night", color: Color.purple)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            // Bar chart — fills all remaining space
            if dailyBars.isEmpty {
                Spacer()
                Text("No entries for this period")
                    .font(.outfit(13))
                    .foregroundColor(Color.dim2)
                Spacer()
            } else {
                barChart
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - Bar chart

    private var barChart: some View {
        Chart(dailyBars) { item in
            BarMark(
                x: .value("Day", item.day, unit: .day),
                y: .value("ml", item.ml)
            )
            .foregroundStyle(item.kind == "Leftover" ? Color.yellow.opacity(0.55) : Color.blue.opacity(0.75))
            .cornerRadius(item.kind == "Leftover" ? 4 : 0)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: chartStride)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                    .font(.outfit(9))
                    .foregroundStyle(Color.dim)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)").font(.outfit(9)).foregroundStyle(Color.dim)
                    }
                }
                AxisGridLine().foregroundStyle(Color.border)
            }
        }
        .chartLegend(position: .topTrailing, spacing: 8) {
            HStack(spacing: 10) {
                legendDot(Color.blue.opacity(0.75),   "Consumed")
                legendDot(Color.yellow.opacity(0.75), "Leftover")
            }
        }
        .chartPlotStyle { plot in
            plot.background(Color.card2).cornerRadius(12)
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.outfit(10)).foregroundColor(Color.dim)
        }
    }

    private var chartStride: Int {
        switch range {
        case .week:  return 1
        case .month: return 5
        case .year:  return 30
        case .all:   return 60
        }
    }

    // MARK: - Helpers

    private func avgGap(isDay: Bool) -> Double? {
        let f = entryFormatter
        let sorted = filtered.compactMap { e -> (date: Date, ml: Int)? in
            guard let d = f.date(from: e.date), e.ml > 0 else { return nil }
            return (d, e.ml)
        }.sorted { $0.date < $1.date }
        guard sorted.count >= 2 else { return nil }
        var gaps: [Double] = []
        for i in 1..<sorted.count {
            let prev = sorted[i-1], curr = sorted[i]
            let ml = Double(prev.ml); guard ml > 0 else { continue }
            let gap = curr.date.timeIntervalSince(prev.date) / 60
            guard gap > 0 && gap <= 360 else { continue }
            let h = Calendar.current.component(.hour, from: prev.date)
            if (h >= 10 && h < 22) == isDay { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return nil }
        return gaps.reduce(0, +) / Double(gaps.count)
    }

    private func formatGap(_ mins: Double?) -> String {
        guard let mins else { return "—" }
        let h = Int(mins) / 60; let m = Int(mins) % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func fmtMl(_ v: Int) -> String {
        v >= 1000 ? String(format: "%.1fL", Double(v) / 1000) : "\(v)"
    }

    private func statCard(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.outfit(22, weight: .bold))
                .foregroundColor(color)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(.outfit(8, weight: .semibold))
                .tracking(1.5)
                .foregroundColor(Color.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(Color.card2)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.25), lineWidth: 1)
                .overlay(alignment: .top) {
                    Rectangle().fill(color).frame(height: 2)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
        )
    }

    private func insightCard(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.outfit(20, weight: .bold))
                .foregroundColor(color)
            Text(label.uppercased())
                .font(.outfit(8, weight: .semibold))
                .tracking(1.5)
                .foregroundColor(Color.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.card2)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.25), lineWidth: 1)
                .overlay(alignment: .top) {
                    Rectangle().fill(color).frame(height: 2)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
        )
    }
}

// MARK: - Diaper Trends

private struct DiaperTrends: View {
    @ObservedObject var vm: StateViewModel
    @State private var range: DiaperRange = .today

    enum DiaperRange: String, CaseIterable {
        case today = "Today", week = "Week", month = "Month", all = "All"
    }

    private var entryFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    private var filtered: [DiaperEntry] {
        guard let entries = vm.state?.diaper_log else { return [] }
        let f = entryFormatter
        let now = Date()
        let cutoff: Date?
        switch range {
        case .today:  cutoff = Calendar.current.startOfDay(for: now)
        case .week:   cutoff = Calendar.current.date(byAdding: .day, value: -7,  to: now)
        case .month:  cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now)
        case .all:    cutoff = nil
        }
        guard let cutoff else { return entries }
        return entries.filter { e in
            guard let d = f.date(from: e.date) else { return false }
            return d >= cutoff
        }
    }

    // Group entries by "YYYY-MM-DD" key, sorted ascending
    private var byDate: [(key: String, entries: [DiaperEntry])] {
        let f = entryFormatter
        var dict: [String: [DiaperEntry]] = [:]
        for e in filtered {
            guard let d = f.date(from: e.date) else { continue }
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let key = df.string(from: d)
            dict[key, default: []].append(e)
        }
        return dict.map { (key: $0.key, entries: $0.value) }.sorted { $0.key < $1.key }
    }

    private var total: Int { filtered.count }
    private var peeCount: Int { filtered.filter { $0.type == "pee" }.count }
    private var pooCount: Int { filtered.filter { $0.type == "poo" }.count }

    var body: some View {
        VStack(spacing: 0) {
            // Range pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(DiaperRange.allCases, id: \.self) { r in
                        Button { withAnimation(.spring(duration: 0.2)) { range = r } } label: {
                            Text(r.rawValue)
                                .font(.outfit(12, weight: .semibold))
                                .foregroundColor(range == r ? Color.blue : Color.dim)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                                .background(range == r ? Color.blueBg : Color.card)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(range == r ? Color.blueBd : Color.border, lineWidth: 1))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            // Stat cards
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 8) {
                statCard(value: "\(total)",    label: "Total",  color: Color.blue)
                statCard(value: "\(peeCount)", label: "💧 Pee", color: Color.yellow)
                statCard(value: "\(pooCount)", label: "💩 Poo", color: Color(hex: "#c87941"))
            }
            .padding(.horizontal, 14)

            // Timeline chart fills all remaining space
            DiaperTimeline(byDate: byDate)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .frame(maxHeight: .infinity)
        }
    }

    private func statCard(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.outfit(22, weight: .bold))
                .foregroundColor(color)
            Text(label.uppercased())
                .font(.outfit(8, weight: .semibold))
                .tracking(1.5)
                .foregroundColor(Color.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(Color.card2)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.25), lineWidth: 1)
                .overlay(alignment: .top) {
                    Rectangle().fill(color).frame(height: 2)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
        )
    }
}

// MARK: - Diaper timeline

/// 24-hour scatter timeline matching the web app.
/// Y axis: bottom = midnight (start of day), top = midnight (end of day).
/// Each day is a vertical column; each diaper event is a colored band at its time-of-day position.
private struct DiaperTimeline: View {
    let byDate: [(key: String, entries: [DiaperEntry])]

    private let yAxisW: CGFloat = 26
    private let labelH: CGFloat = 22
    private let colGap: CGFloat = 3
    private let minColW: CGFloat = 24
    private let barH: CGFloat = 14

    // Y axis labels: position from top → time of day
    // top:0% = midnight end, top:25% = 6pm, top:50% = noon, top:75% = 6am, top:100% = midnight start
    private let yLabels = ["12a", "6p", "12p", "6a", "12a"]

    var body: some View {
        GeometryReader { geo in
            let chartH = max(0, geo.size.height - labelH)
            let availW  = max(0, geo.size.width - yAxisW - 8)
            let colW    = byDate.isEmpty ? minColW
                : max(minColW, (availW - CGFloat(byDate.count - 1) * colGap) / CGFloat(byDate.count))

            HStack(alignment: .top, spacing: 0) {
                // ── Y axis ──
                ZStack(alignment: .topLeading) {
                    ForEach(Array(yLabels.enumerated()), id: \.offset) { i, label in
                        Text(label)
                            .font(.system(size: 7, weight: .medium))
                            .foregroundColor(Color.dim)
                            .frame(width: yAxisW, alignment: .trailing)
                            .offset(y: chartH * CGFloat(i) / 4 - 5)
                    }
                }
                .frame(width: yAxisW, height: chartH)
                .padding(.trailing, 2)

                if byDate.isEmpty {
                    Text("No data")
                        .font(.outfit(12))
                        .foregroundColor(Color.dim2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // ── Scrollable day columns ──
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: colGap) {
                            ForEach(byDate, id: \.key) { item in
                                VStack(spacing: 0) {
                                    DayColumn(entries: item.entries, height: chartH, barH: barH)
                                        .frame(width: colW, height: chartH)
                                    dayLabel(item.key)
                                        .frame(width: colW, height: labelH)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private func dayLabel(_ key: String) -> some View {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let d = df.date(from: key) ?? Date()
        let weekday = ["Su","Mo","Tu","We","Th","Fr","Sa"][Calendar.current.component(.weekday, from: d) - 1]
        let dayNum  = Calendar.current.component(.day, from: d)
        return VStack(spacing: 1) {
            Text(weekday)
                .font(.system(size: 7, weight: .medium))
                .foregroundColor(Color.dim)
            Text("\(dayNum)")
                .font(.system(size: 7))
                .foregroundColor(Color.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 3)
    }
}

// MARK: - Day column

private struct DayColumn: View {
    let entries: [DiaperEntry]
    let height: CGFloat
    let barH: CGFloat

    private var formatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    // Fraction of day (0 = midnight start, 1 = midnight end)
    private func dayFraction(_ dateStr: String) -> CGFloat {
        let f = formatter
        guard let d = f.date(from: dateStr) else { return 0.5 }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: d)
        let mins = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return CGFloat(mins) / 1440.0
    }

    // Short time string: "1:30 PM" → "1:30p"
    private func shortTime(_ dateStr: String) -> String {
        let f = formatter
        guard let d = f.date(from: dateStr) else { return "" }
        let out = DateFormatter()
        out.dateFormat = "h:mm"
        return out.string(from: d)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Column background
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.yellow.opacity(0.07))

            // Horizontal grid lines at 0 / 25 / 50 / 75 / 100% from bottom
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { frac in
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 1)
                    // offset from bottom: frac * height, then flip to ZStack bottom alignment
                    .offset(y: -(height * frac))
            }

            // Diaper events — positioned by time of day
            ForEach(entries) { entry in
                let frac = dayFraction(entry.date)
                let isPee = entry.type == "pee"
                let bg: Color = isPee ? Color.yellow : Color(hex: "#c87941")
                let textFg: Color = isPee ? Color.black.opacity(0.6) : Color.white.opacity(0.8)

                Text(shortTime(entry.date))
                    .font(.system(size: 6, weight: .semibold))
                    .foregroundColor(textFg)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, minHeight: barH, maxHeight: barH)
                    .background(bg.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    // bottom-align: offset from bottom edge by frac * height, minus half bar height
                    .offset(y: -(height * frac))
            }
        }
        .clipped()
    }
}
