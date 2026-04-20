import SwiftUI
import Charts

// MARK: - Trends page

struct TrendsView: View {
    @ObservedObject var vm: StateViewModel
    @State var section: TrendSection

    enum TrendSection { case formula, diaper }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.primaryBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    Picker("", selection: $section) {
                        Text("Formula").tag(TrendSection.formula)
                        Text("Diapers").tag(TrendSection.diaper)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                    Divider().background(Color.separator)

                    if section == .formula {
                        FormulaTrends(vm: vm)
                    } else {
                        DiaperTrends(vm: vm)
                    }
                }
            }
            .navigationTitle("Trends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.primaryBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
            HStack(spacing: 0) {
                ForEach(FormulaRange.allCases, id: \.self) { r in
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { range = r } } label: {
                        Text(r.rawValue)
                            .font(.outfit(12, weight: range == r ? .semibold : .regular))
                            .foregroundColor(range == r ? Color.primaryLabel : Color.secondaryLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.elevatedBackground)
                                    .opacity(range == r ? 1 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.overlayBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.vertical, 10)

            // Stat cards
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 8) {
                statCard(value: fmtMl(totalMl),     label: "Total ml",    color: Color.blue)
                statCard(value: "\(bottleCount)",    label: "Bottles",     color: Color.green)
                statCard(value: fmtMl(avgMlPerDay), label: "Avg ml/day",  color: Color.yellow)
            }

            // Insight cards
            HStack(spacing: 8) {
                insightCard(value: dayGap,   label: "☀️ Avg gap · Day",   color: Color.yellow)
                insightCard(value: nightGap, label: "🌙 Avg gap · Night", color: Color.purple)
            }
            .padding(.top, 8)

            // Bar chart — fills all remaining space
            if dailyBars.isEmpty {
                Spacer()
                Text("No entries for this period")
                    .font(.outfit(13))
                    .foregroundColor(Color.tertiaryLabel)
                Spacer()
            } else {
                barChart
                    .padding(.top, 12)
                    .padding(.bottom, 14)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - Bar chart

    private var barChart: some View {
        let maxMl = dailyBars.map(\.ml).max() ?? 0
        let step = max(100, ((maxMl / 3) / 100) * 100)
        let yVals = Array(stride(from: step, through: maxMl, by: step))
        return Chart(dailyBars) { item in
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
                    .foregroundStyle(Color.secondaryLabel)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Color.separator)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { _ in
                ZStack(alignment: .topLeading) {
                    ForEach(yVals, id: \.self) { v in
                        if let yPos = proxy.position(forY: v) {
                            Text(v >= 1000 ? String(format: "%.1fL", Double(v) / 1000) : "\(v)")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(Color.secondaryLabel)
                                .padding(.horizontal, 3)
                                .background(Color.black.opacity(0.25))
                                .clipShape(RoundedRectangle(cornerRadius: 2))
                                .position(x: 18, y: yPos)
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .chartLegend(position: .topTrailing, spacing: 8) {
            HStack(spacing: 10) {
                legendDot(Color.blue.opacity(0.75),   "Consumed")
                legendDot(Color.yellow.opacity(0.75), "Leftover")
            }
        }
        .chartPlotStyle { plot in
            plot.background(Color.overlayBackground).cornerRadius(12)
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.outfit(10)).foregroundColor(Color.secondaryLabel)
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
                .appFont(.caption2)
                .tracking(1.0)
                .foregroundColor(Color.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(Color.overlayBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.25), lineWidth: 1))
    }

    private func insightCard(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.outfit(20, weight: .bold))
                .foregroundColor(color)
            Text(label.uppercased())
                .appFont(.caption2)
                .tracking(1.0)
                .foregroundColor(Color.secondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.overlayBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.25), lineWidth: 1))
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
        case .today: cutoff = Calendar.current.startOfDay(for: now)
        case .week:  cutoff = Calendar.current.date(byAdding: .day, value: -7,  to: now)
        case .month: cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now)
        case .all:   cutoff = nil
        }
        guard let cutoff else { return entries }
        return entries.filter { e in
            guard let d = f.date(from: e.date) else { return false }
            return d >= cutoff
        }
    }

    private var byDate: [(key: String, entries: [DiaperEntry])] {
        let f = entryFormatter
        var dict: [String: [DiaperEntry]] = [:]
        for e in filtered {
            guard let d = f.date(from: e.date) else { continue }
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            dict[df.string(from: d), default: []].append(e)
        }
        return dict.map { (key: $0.key, entries: $0.value) }.sorted { $0.key < $1.key }
    }

    private var total: Int    { filtered.count }
    private var peeCount: Int { filtered.filter { $0.type == "pee" }.count }
    private var pooCount: Int { filtered.filter { $0.type == "poo" }.count }

    var body: some View {
        VStack(spacing: 0) {
            // Range pills
            HStack(spacing: 0) {
                ForEach(DiaperRange.allCases, id: \.self) { r in
                    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { range = r } } label: {
                        Text(r.rawValue)
                            .font(.outfit(12, weight: range == r ? .semibold : .regular))
                            .foregroundColor(range == r ? Color.primaryLabel : Color.secondaryLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.elevatedBackground)
                                    .opacity(range == r ? 1 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.overlayBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.vertical, 10)

            // Stat cards
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible()), .init(.flexible())], spacing: 8) {
                statCard(value: "\(total)",    label: "Total",  color: Color.blue)
                statCard(value: "\(peeCount)", label: "💧 Pee", color: Color.yellow)
                statCard(value: "\(pooCount)", label: "💩 Poo", color: Color(hex: "#c87941"))
            }

            // Timeline
            DiaperTimeline(byDate: byDate)
                .padding(.top, 12)
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
                .appFont(.caption2)
                .tracking(1.0)
                .foregroundColor(Color.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(Color.overlayBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Diaper timeline

private struct DiaperTimeline: View {
    let byDate: [(key: String, entries: [DiaperEntry])]

    private let labelH: CGFloat = 24
    private let colGap: CGFloat = 4
    private let minColW: CGFloat = 28
    private let dotSize: CGFloat = 18

    private let yLabels: [(label: String, frac: CGFloat)] = [
        ("12a", 0.0), ("6a", 0.25), ("12p", 0.5), ("6p", 0.75), ("12a", 1.0)
    ]

    var body: some View {
        GeometryReader { geo in
            let chartH = max(0, geo.size.height - labelH)
            let availW  = geo.size.width
            let colW    = byDate.isEmpty ? minColW
                : max(minColW, (availW - CGFloat(byDate.count - 1) * colGap) / CGFloat(byDate.count))

            ZStack(alignment: .topLeading) {
                if byDate.isEmpty {
                    Text("No data")
                        .font(.outfit(12))
                        .foregroundColor(Color.tertiaryLabel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: colGap) {
                                ForEach(byDate, id: \.key) { item in
                                    VStack(spacing: 0) {
                                        DayColumn(entries: item.entries, height: chartH, dotSize: dotSize)
                                            .frame(width: colW, height: chartH)
                                        dayLabel(item.key)
                                            .frame(width: colW, height: labelH)
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                        .frame(height: chartH)
                        Spacer().frame(height: labelH)
                    }
                }

                // Y labels overlaid at leading edge, non-interactive
                ZStack(alignment: .topLeading) {
                    ForEach(yLabels, id: \.frac) { item in
                        Text(item.label)
                            .font(.system(size: 7, weight: .regular, design: .monospaced))
                            .foregroundColor(Color.secondaryLabel.opacity(0.3))
                            .offset(x: 6, y: chartH * item.frac - 5)
                    }
                }
                .frame(height: chartH)
                .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    private func dayLabel(_ key: String) -> some View {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let d = df.date(from: key) ?? Date()
        let weekday = ["Su","Mo","Tu","We","Th","Fr","Sa"][Calendar.current.component(.weekday, from: d) - 1]
        let dayNum  = Calendar.current.component(.day, from: d)
        return VStack(spacing: 2) {
            Rectangle()
                .fill(Color.separator.opacity(0.25))
                .frame(height: 1)
            Text(weekday.uppercased())
                .font(.system(size: 7, weight: .semibold, design: .rounded))
                .foregroundColor(Color.secondaryLabel.opacity(0.5))
            Text("\(dayNum)")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Color.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

// MARK: - Day column

private struct DayColumn: View {
    let entries: [DiaperEntry]
    let height: CGFloat
    let dotSize: CGFloat

    private var formatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    private func dayFraction(_ dateStr: String) -> CGFloat {
        guard let d = formatter.date(from: dateStr) else { return 0.5 }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: d)
        let mins = CGFloat((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
        return mins / 1440.0
    }

    private func shortTime(_ dateStr: String) -> String {
        guard let d = formatter.date(from: dateStr) else { return "" }
        let out = DateFormatter()
        out.dateFormat = "h:mm"
        return out.string(from: d)
    }

    // Resolve Y positions so bars never overlap — push down when too close
    private func resolvedPositions() -> [(entry: DiaperEntry, top: CGFloat)] {
        let gap: CGFloat = 1
        let sorted = entries.sorted { dayFraction($0.date) < dayFraction($1.date) }
        var result: [(entry: DiaperEntry, top: CGFloat)] = []
        var nextTop: CGFloat = -CGFloat.infinity
        for entry in sorted {
            let natural = height * dayFraction(entry.date) - dotSize / 2
            let placed  = max(natural, nextTop)
            result.append((entry: entry, top: placed))
            nextTop = placed + dotSize + gap
        }
        return result
    }

    var body: some View {
        let positions = resolvedPositions()
        return ZStack(alignment: .top) {
            // Column background
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.03))

            // Hour grid lines at 6-hour intervals
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { frac in
                Rectangle()
                    .fill(Color.white.opacity(frac == 0.0 || frac == 1.0 ? 0.08 : 0.04))
                    .frame(height: 1)
                    .offset(y: height * CGFloat(frac))
            }

            // Events as full-width bars with centered time label
            ForEach(positions, id: \.entry.id) { item in
                let isPee = item.entry.type == "pee"
                let barColor: Color = isPee ? Color.yellow.opacity(0.85) : Color(hex: "#c87941").opacity(0.9)
                let textColor: Color = isPee ? Color.black.opacity(0.65) : Color.white.opacity(0.85)
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                    Text(shortTime(item.entry.date))
                        .font(.system(size: 7, weight: .semibold, design: .monospaced))
                        .foregroundColor(textColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, minHeight: dotSize, maxHeight: dotSize)
                .offset(y: item.top)
            }
        }
        .clipped()
    }
}
