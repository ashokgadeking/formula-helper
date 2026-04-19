import SwiftUI

// MARK: - Logs page

struct LogsView: View {
    @ObservedObject var vm: StateViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDate: String = ""   // "YYYY-MM-DD"
    @State private var tab: LogTab = .formula
    @State private var showTrends = false

    enum LogTab { case formula, diaper }

    // All unique dates that have formula entries, sorted ascending
    private var formulaDates: [String] {
        let raw = vm.state?.mix_log.compactMap { dayPrefix($0.date) } ?? []
        return Array(Set(raw)).sorted()
    }

    // All unique dates that have diaper entries, sorted ascending
    private var diaperDates: [String] {
        let raw = vm.state?.diaper_log.compactMap { dayPrefix($0.date) } ?? []
        return Array(Set(raw)).sorted()
    }

    private var activeDates: [String] { tab == .formula ? formulaDates : diaperDates }

    // Entries for the selected date
    private var formulaEntries: [LogEntry] {
        (vm.state?.mix_log ?? [])
            .filter { ($0.date).hasPrefix(selectedDate) }
            .reversed()
    }

    private var diaperEntries: [DiaperEntry] {
        (vm.state?.diaper_log ?? [])
            .filter { ($0.date).hasPrefix(selectedDate) }
            .reversed()
    }

    // Navigation
    private var currentIdx: Int { activeDates.firstIndex(of: selectedDate) ?? -1 }
    private var canGoPrev: Bool { currentIdx > 0 }
    private var canGoNext: Bool { currentIdx >= 0 && currentIdx < activeDates.count - 1 }

    // Subtitle counts
    private var formulaSubtitle: String {
        let total = formulaEntries.reduce(0) { $0 + $1.ml }
        return "\(formulaEntries.count) \(formulaEntries.count == 1 ? "mix" : "mixes") · \(total)ml"
    }

    private var diaperSubtitle: String {
        let pee = diaperEntries.filter { $0.type == "pee" }.count
        let poo = diaperEntries.filter { $0.type == "poo" }.count
        return "\(pee) pee · \(poo) poo"
    }

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                // ── Day banner ──
                ZStack {
                    VStack(spacing: 4) {
                        Text(tab == .formula ? formulaSubtitle : diaperSubtitle)
                            .font(.outfit(10, weight: .medium))
                            .tracking(2.5)
                            .textCase(.uppercase)
                            .foregroundColor(Color.dim)

                        Text(dateLabel(selectedDate))
                            .font(.outfit(28, weight: .bold))
                            .foregroundColor(Color.wht)
                    }

                    HStack {
                        navBtn(direction: -1)
                        Spacer()
                        navBtn(direction: +1)
                    }
                    .padding(.horizontal, 14)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)

                // ── Formula / Diapers tabs ──
                HStack(spacing: 1) {
                    tabBtn("Formula", t: .formula)
                    tabBtn("Diapers", t: .diaper)
                }
                .background(Color.border)

                Divider().background(Color.border)

                // ── Entry list ──
                if tab == .formula {
                    if formulaEntries.isEmpty {
                        emptyState("No mixes recorded")
                    } else {
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(Array(formulaEntries.enumerated()), id: \.element.sk) { idx, entry in
                                    LogRow(entry: entry, index: formulaEntries.count - 1 - idx, vm: vm)
                                }
                            }
                            .padding(14)
                            .padding(.bottom, 24)
                        }
                    }
                } else {
                    if diaperEntries.isEmpty {
                        emptyState("No diapers recorded")
                    } else {
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(diaperEntries) { entry in
                                    DiaperRow(entry: entry, vm: vm)
                                }
                            }
                            .padding(14)
                            .padding(.bottom, 24)
                        }
                    }
                }

                // ── Bottom bar ──
                HStack(spacing: 0) {
                    Button { dismiss() } label: {
                        Text("Back")
                            .font(.outfit(15, weight: .semibold))
                            .foregroundColor(Color.dim)
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                    }
                    Rectangle().fill(Color.border).frame(width: 1, height: 64)
                    Button { showTrends = true } label: {
                        Text("Trends")
                            .font(.outfit(15, weight: .semibold))
                            .foregroundColor(Color.blue)
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                            .background(Color.blueBg)
                    }
                }
                .background(Color.bg2)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.borderLight).frame(height: 1)
                }
            }
        }
        .sheet(isPresented: $showTrends) {
            TrendsView(vm: vm, section: tab == .formula ? .formula : .diaper)
        }
        .onAppear { initDate() }
        .onChange(of: tab) { _, _ in initDate() }
    }

    // MARK: - Subviews

    private func tabBtn(_ label: String, t: LogTab) -> some View {
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

    private func navBtn(direction: Int) -> some View {
        let enabled = direction < 0 ? canGoPrev : canGoNext
        return Button {
            guard enabled, currentIdx >= 0 else { return }
            let newIdx = currentIdx + direction
            if newIdx >= 0 && newIdx < activeDates.count {
                selectedDate = activeDates[newIdx]
            }
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(enabled ? Color.wht : Color.dim2)
                .frame(width: 36, height: 36)
                .background(Color.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.border, lineWidth: 1))
        }
        .disabled(!enabled)
    }

    private func emptyState(_ msg: String) -> some View {
        Spacer()
            .overlay(
                Text(msg)
                    .font(.outfit(14))
                    .foregroundColor(Color.dim2)
            )
    }

    // MARK: - Helpers

    private func initDate() {
        let dates = activeDates
        if let last = dates.last, !selectedDate.isEmpty, dates.contains(selectedDate) { return }
        selectedDate = activeDates.last ?? todayString()
    }

    private func dayPrefix(_ dateStr: String) -> String? {
        let parts = dateStr.split(separator: " ")
        return parts.first.map(String.init)
    }

    private func todayString() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    private func dateLabel(_ d: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: d) else { return d }
        let today = Calendar.current.startOfDay(for: Date())
        let target = Calendar.current.startOfDay(for: date)
        let days = Calendar.current.dateComponents([.day], from: target, to: today).day ?? 0
        switch days {
        case 0:  return "Today"
        case 1:  return "Yesterday"
        default:
            let out = DateFormatter(); out.dateFormat = "EEE, MMM d"
            return out.string(from: date)
        }
    }
}

// MARK: - Diaper entry row

struct DiaperRow: View {
    let entry: DiaperEntry
    @ObservedObject var vm: StateViewModel

    var fg: Color { entry.type == "pee" ? Color.yellow : Color(hex: "#c87941") }
    var label: String { entry.type == "pee" ? "Pee 💧" : "Poo 💩" }

    var timeStr: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: entry.date) else { return entry.date }
        let out = DateFormatter(); out.timeStyle = .short
        return out.string(from: d)
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(fg.opacity(0.4)).frame(width: 3)

            Text(label)
                .font(.outfit(14, weight: .semibold))
                .foregroundColor(fg)
                .padding(.horizontal, 12)

            Text(timeStr)
                .font(.outfit(12))
                .foregroundColor(Color.dim)

            Spacer()

            Button {
                Task { try? await APIClient.shared.deleteDiaper(sk: entry.sk); await vm.refresh() }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.red)
                    .frame(width: 32, height: 32)
                    .background(Color.redBg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.redBd, lineWidth: 1))
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.trailing, 14)
        }
        .padding(.vertical, 13)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.border, lineWidth: 1))
    }
}

// MARK: - Formula log row

struct LogRow: View {
    let entry: LogEntry
    let index: Int
    @ObservedObject var vm: StateViewModel
    @State private var expanded = false
    @State private var leftover = ""
    @State private var saving   = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Rectangle().fill(Color.green.opacity(0.4)).frame(width: 3)
                Text("\(index + 1)")
                    .font(.outfit(10, weight: .semibold)).tracking(0.5)
                    .foregroundColor(Color.dim2).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.text)
                        .font(.outfit(15, weight: .medium)).foregroundColor(Color.wht)
                    if !entry.leftover.isEmpty {
                        Text("\(entry.leftover) leftover")
                            .font(.outfit(11)).foregroundColor(Color.yellow)
                    } else {
                        Text("tap ✎ to record leftover")
                            .font(.outfit(11)).foregroundColor(Color.dim2)
                    }
                    if !entry.created_by.isEmpty {
                        Text(entry.created_by)
                            .font(.outfit(10)).foregroundColor(Color.dim2.opacity(0.6))
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    iconBtn("pencil", fg: Color.blue, bg: Color.blueBg, bd: Color.blueBd) {
                        withAnimation(.spring(duration: 0.2)) { expanded.toggle() }
                    }
                    iconBtn("trash", fg: Color.red, bg: Color.redBg, bd: Color.redBd) {
                        Task { try? await APIClient.shared.deleteEntry(sk: entry.sk); await vm.refresh() }
                    }
                }
                .padding(.trailing, 14)
            }
            .padding(.vertical, 13)
            .background(Color.card)

            if expanded {
                HStack(spacing: 8) {
                    TextField("Leftover ml", text: $leftover)
                        .keyboardType(.numberPad).font(.outfit(14)).foregroundColor(Color.wht)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(Color.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.borderLight, lineWidth: 1))
                    Button(saving ? "…" : "Save") {
                        guard !saving else { return }; saving = true
                        Task {
                            try? await APIClient.shared.updateEntry(sk: entry.sk, leftover: leftover)
                            await vm.refresh(); saving = false; expanded = false
                        }
                    }
                    .font(.outfit(14, weight: .semibold)).foregroundColor(Color.green)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color.greenBg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.greenBd, lineWidth: 1))
                    .disabled(saving)
                }
                .padding(.horizontal, 14).padding(.vertical, 10).background(Color.card2)
                .onAppear { leftover = entry.leftover }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.border, lineWidth: 1))
        .animation(.spring(duration: 0.2), value: expanded)
    }

    private func iconBtn(_ sf: String, fg: Color, bg: Color, bd: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: sf).font(.system(size: 12, weight: .semibold))
                .foregroundColor(fg).frame(width: 32, height: 32).background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(bd, lineWidth: 1))
        }
        .buttonStyle(PlainButtonStyle())
    }
}
