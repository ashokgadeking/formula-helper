import SwiftUI

private let rowHeight: CGFloat = 64

// MARK: - Logs page

struct LogsView: View {
    @ObservedObject var vm: StateViewModel

    @State private var selectedDate: String = ""   // "YYYY-MM-DD"
    @State private var tab: LogTab = .formula
    @State private var showAddSheet = false
    @State private var expandedId: String?

    enum LogTab { case formula, diaper, nap }

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

    private var napDates: [String] {
        let raw = (vm.state?.nap_log ?? []).compactMap { dayPrefix($0.date) }
        return Array(Set(raw)).sorted()
    }

    private var activeDates: [String] {
        switch tab {
        case .formula: return formulaDates
        case .diaper:  return diaperDates
        case .nap:     return napDates
        }
    }

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

    private var napEntries: [NapEntry] {
        (vm.state?.nap_log ?? [])
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

    private var napSubtitle: String {
        let total = napEntries.compactMap { $0.duration_mins }.reduce(0, +)
        let withDur = napEntries.filter { $0.duration_mins != nil }.count
        if total > 0 {
            return "\(napEntries.count) \(napEntries.count == 1 ? "nap" : "naps") · \(total)m"
                + (withDur < napEntries.count ? " (\(napEntries.count - withDur) untimed)" : "")
        }
        return "\(napEntries.count) \(napEntries.count == 1 ? "nap" : "naps")"
    }

    private var activeSubtitle: String {
        switch tab {
        case .formula: return formulaSubtitle
        case .diaper:  return diaperSubtitle
        case .nap:     return napSubtitle
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.primaryBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    // ── Segmented picker ──
                    Picker("", selection: $tab) {
                        Text("Formula").tag(LogTab.formula)
                        Text("Diapers").tag(LogTab.diaper)
                        Text("Naps").tag(LogTab.nap)
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 8)

                    // ── Day banner ──
                    ZStack {
                        VStack(spacing: 4) {
                            Text(activeSubtitle)
                                .appFont(.caption2)
                                .tracking(1.2)
                                .foregroundColor(Color.secondaryLabel)

                            Text(dateLabel(selectedDate))
                                .appFont(.title1)
                                .foregroundColor(Color.primaryLabel)
                        }

                        HStack {
                            navBtn(direction: -1)
                            Spacer()
                            navBtn(direction: +1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)

                    // ── Entry list ──
                    switch tab {
                    case .formula:
                        if formulaEntries.isEmpty {
                            emptyState("No mixes recorded")
                        } else {
                            List {
                                ForEach(formulaEntries) { entry in
                                    LogRow(entry: entry, vm: vm, expanded: binding(for: entry.sk))
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                Task { try? await APIClient.shared.deleteEntry(sk: entry.sk); await vm.refresh() }
                                            } label: { Image(systemName: "trash.fill") }
                                            .tint(.red)
                                        }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .background(Color.primaryBackground)
                        }
                    case .diaper:
                        if diaperEntries.isEmpty {
                            emptyState("No diapers recorded")
                        } else {
                            List {
                                ForEach(diaperEntries) { entry in
                                    DiaperRow(entry: entry, vm: vm, expanded: binding(for: entry.sk))
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                Task { try? await APIClient.shared.deleteDiaper(sk: entry.sk); await vm.refresh() }
                                            } label: { Image(systemName: "trash.fill") }
                                            .tint(.red)
                                        }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .background(Color.primaryBackground)
                        }
                    case .nap:
                        if napEntries.isEmpty {
                            emptyState("No naps recorded")
                        } else {
                            List {
                                ForEach(napEntries) { entry in
                                    NapRow(entry: entry, vm: vm, expanded: binding(for: entry.sk))
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            Button(role: .destructive) {
                                                Task { try? await APIClient.shared.deleteNap(sk: entry.sk); await vm.refresh() }
                                            } label: { Image(systemName: "trash.fill") }
                                            .tint(.red)
                                        }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .background(Color.primaryBackground)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.primaryBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarTrailing) {
                        plusButton
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        plusButton
                    }
                }
            }
        }
        .onAppear { initDate() }
        .onChange(of: tab) { _, _ in initDate() }
        .sheet(isPresented: $showAddSheet) {
            ManualAddSheet(tab: tab, vm: vm, isPresented: $showAddSheet)
        }
    }

    private var plusButton: some View {
        Image(systemName: "plus")
            .font(.system(size: 14, weight: .regular))
            .foregroundColor(Color.primaryLabel.opacity(0.5))
            .contentShape(Rectangle())
            .onTapGesture { Haptics.tap(.light); showAddSheet = true }
            .accessibilityLabel("Add entry")
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
                .foregroundColor(enabled ? Color.primaryLabel : Color.tertiaryLabel)
                .frame(width: 36, height: 36)
                .background(Color.elevatedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.separator, lineWidth: 1))
        }
        .disabled(!enabled)
    }

    private func emptyState(_ msg: String) -> some View {
        Spacer()
            .overlay(
                Text(msg)
                    .font(.outfit(14))
                    .foregroundColor(Color.tertiaryLabel)
            )
    }

    // MARK: - Helpers

    private func binding(for sk: String) -> Binding<Bool> {
        Binding(
            get: { expandedId == sk },
            set: { expandedId = $0 ? sk : nil }
        )
    }

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
    @Binding var expanded: Bool
    @State private var editDate = Date()
    @State private var saving = false

    var fg: Color { entry.type == "pee" ? Color.yellow : Color(hex: "#c87941") }
    var label: String { entry.type == "pee" ? "Pee" : "Poo" }

    private static let parseFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var parsedDate: Date? { DiaperRow.parseFormatter.date(from: entry.date) }

    var timeStr: String {
        guard let d = parsedDate else { return entry.date }
        let out = DateFormatter(); out.timeStyle = .short
        return out.string(from: d)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Rectangle().fill(fg.opacity(0.4)).frame(width: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.outfit(16, weight: .semibold))
                        .foregroundColor(fg)
                    if !entry.created_by.isEmpty {
                        Text("\(entry.created_by)")
                            .font(.outfit(11))
                            .foregroundColor(Color.tertiaryLabel)
                    }
                }
                .padding(.leading, 12)

                Spacer()

                Text(timeStr)
                    .font(.outfit(14))
                    .foregroundColor(Color.secondaryLabel)
                    .padding(.trailing, 14)
            }
            .frame(height: rowHeight)
            .background(Color.elevatedBackground)
            .contentShape(Rectangle())
            .onTapGesture {
                if expanded { withAnimation(.spring(duration: 0.2)) { expanded = false } }
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                Haptics.tap(.medium)
                editDate = parsedDate ?? Date()
                withAnimation(.spring(duration: 0.2)) { expanded.toggle() }
            }

            if expanded {
                HStack(spacing: 8) {
                    DatePicker("", selection: $editDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .environment(\.colorScheme, .dark)

                    Spacer()

                    Button(saving ? "…" : "Save") {
                        guard !saving else { return }
                        Haptics.tap(.medium)
                        saving = true
                        let f = DateFormatter()
                        f.dateFormat = "yyyy-MM-dd hh:mm a"
                        f.locale = Locale(identifier: "en_US_POSIX")
                        let dateStr = f.string(from: editDate)
                        Task {
                            try? await APIClient.shared.updateDiaper(sk: entry.sk, date: dateStr)
                            await vm.refresh(); saving = false; expanded = false
                        }
                    }
                    .font(.outfit(14, weight: .semibold)).foregroundColor(Color.green)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color.greenFill)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.greenBorder, lineWidth: 1))
                    .disabled(saving)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.overlayBackground)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.separator, lineWidth: 1))
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

// MARK: - Nap entry row

struct NapRow: View {
    let entry: NapEntry
    @ObservedObject var vm: StateViewModel
    @Binding var expanded: Bool
    @State private var editDate = Date()
    @State private var durationText = ""
    @State private var saving = false

    private static let parseFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var parsedDate: Date? { NapRow.parseFormatter.date(from: entry.date) }

    var timeStr: String {
        guard let d = parsedDate else { return entry.date }
        let out = DateFormatter(); out.timeStyle = .short
        return out.string(from: d)
    }

    var durationStr: String {
        guard let m = entry.duration_mins, m > 0 else { return "untimed" }
        if m >= 60 {
            let h = m / 60, r = m % 60
            return r == 0 ? "\(h)h" : "\(h)h \(r)m"
        }
        return "\(m)m"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Rectangle().fill(Color.purple.opacity(0.4)).frame(width: 3)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Text("Nap")
                            .font(.outfit(16, weight: .semibold))
                            .foregroundColor(Color.purple)
                        Text(durationStr)
                            .font(.outfit(14))
                            .foregroundColor(entry.duration_mins != nil ? Color.primaryLabel : Color.tertiaryLabel)
                    }
                    if !entry.created_by.isEmpty {
                        Text("\(entry.created_by)")
                            .font(.outfit(11))
                            .foregroundColor(Color.tertiaryLabel)
                    }
                }
                .padding(.leading, 12)

                Spacer()

                Text(timeStr)
                    .font(.outfit(14))
                    .foregroundColor(Color.secondaryLabel)
                    .padding(.trailing, 14)
            }
            .frame(height: rowHeight)
            .background(Color.elevatedBackground)
            .contentShape(Rectangle())
            .onTapGesture {
                if expanded { withAnimation(.spring(duration: 0.2)) { expanded = false } }
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                Haptics.tap(.medium)
                editDate = parsedDate ?? Date()
                durationText = entry.duration_mins.map(String.init) ?? ""
                withAnimation(.spring(duration: 0.2)) { expanded.toggle() }
            }

            if expanded {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        DatePicker("", selection: $editDate, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .environment(\.colorScheme, .dark)
                        Spacer()
                    }

                    HStack(spacing: 8) {
                        TextField("Duration (min)", text: $durationText)
                            .keyboardType(.numberPad)
                            .font(.outfit(14)).foregroundColor(Color.primaryLabel)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(Color.primaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.opaqueSeparator, lineWidth: 1))

                        Button(saving ? "…" : "Save") {
                            guard !saving else { return }
                            Haptics.tap(.medium)
                            saving = true
                            let f = DateFormatter()
                            f.dateFormat = "yyyy-MM-dd hh:mm a"
                            f.locale = Locale(identifier: "en_US_POSIX")
                            let dateStr = f.string(from: editDate)
                            let mins = Int(durationText.trimmingCharacters(in: .whitespaces))
                            Task {
                                try? await APIClient.shared.updateNap(sk: entry.sk, date: dateStr, durationMins: mins)
                                await vm.refresh(); saving = false; expanded = false
                            }
                        }
                        .font(.outfit(14, weight: .semibold)).foregroundColor(Color.green)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Color.greenFill)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.greenBorder, lineWidth: 1))
                        .disabled(saving)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.overlayBackground)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.separator, lineWidth: 1))
        .animation(.spring(duration: 0.2), value: expanded)
    }
}

// MARK: - Formula log row

struct LogRow: View {
    let entry: LogEntry
    @ObservedObject var vm: StateViewModel
    @Binding var expanded: Bool
    @State private var leftover = ""
    @State private var mlText = ""
    @State private var editDate = Date()
    @State private var saving   = false

    private static let parseFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var parsedDate: Date? { LogRow.parseFormatter.date(from: entry.date) }

    var timeStr: String {
        guard let d = parsedDate else { return entry.date }
        let out = DateFormatter(); out.timeStyle = .short
        return out.string(from: d)
    }

    /// Strips any unit suffix the user typed (e.g. "20ml" → "20"); nil if no digits.
    var normalizedLeftover: String? {
        let digits = entry.leftover.filter(\.isNumber)
        return digits.isEmpty ? nil : digits
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Rectangle().fill(Color.green.opacity(0.4)).frame(width: 3)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Text("\(entry.ml)ml")
                            .font(.outfit(16, weight: .semibold))
                            .foregroundColor(Color.green)
                        if let lo = normalizedLeftover {
                            Text("\(lo)ml left")
                                .font(.outfit(14))
                                .foregroundColor(Color.yellow)
                        }
                    }
                    if !entry.created_by.isEmpty {
                        Text("\(entry.created_by)")
                            .font(.outfit(11))
                            .foregroundColor(Color.tertiaryLabel)
                    }
                }
                .padding(.leading, 12)

                Spacer()

                Text(timeStr)
                    .font(.outfit(14))
                    .foregroundColor(Color.secondaryLabel)
                    .padding(.trailing, 14)
            }
            .frame(height: rowHeight)
            .background(Color.elevatedBackground)
            .contentShape(Rectangle())
            .onTapGesture {
                if expanded { withAnimation(.spring(duration: 0.2)) { expanded = false } }
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                Haptics.tap(.medium)
                mlText = String(entry.ml)
                leftover = entry.leftover
                editDate = parsedDate ?? Date()
                withAnimation(.spring(duration: 0.2)) { expanded.toggle() }
            }

            if expanded {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        DatePicker("", selection: $editDate, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .environment(\.colorScheme, .dark)
                        Spacer()
                    }

                    HStack(spacing: 8) {
                        TextField("ml", text: $mlText)
                            .keyboardType(.numberPad).font(.outfit(14)).foregroundColor(Color.primaryLabel)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                            .background(Color.primaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.opaqueSeparator, lineWidth: 1))

                        TextField("Leftover", text: $leftover)
                            .keyboardType(.numberPad).font(.outfit(14)).foregroundColor(Color.primaryLabel)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                            .background(Color.primaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.opaqueSeparator, lineWidth: 1))

                        Button(saving ? "…" : "Save") {
                            guard !saving else { return }
                            Haptics.tap(.medium)
                            saving = true
                            let newMl = Int(mlText.trimmingCharacters(in: .whitespaces)) ?? entry.ml
                            let dateStr = LogRow.parseFormatter.string(from: editDate)
                            let timeOnly: String = {
                                let f = DateFormatter()
                                f.dateFormat = "hh:mm a"
                                f.locale = Locale(identifier: "en_US_POSIX")
                                return f.string(from: editDate)
                            }()
                            let newText = "\(newMl)ml @ \(timeOnly)"
                            Task {
                                try? await APIClient.shared.updateEntry(
                                    sk: entry.sk,
                                    text: newText,
                                    leftover: leftover.filter(\.isNumber),
                                    ml: newMl,
                                    date: dateStr
                                )
                                await vm.refresh(); saving = false; expanded = false
                            }
                        }
                        .font(.outfit(14, weight: .semibold)).foregroundColor(Color.green)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Color.greenFill)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.greenBorder, lineWidth: 1))
                        .disabled(saving)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10).background(Color.overlayBackground)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.separator, lineWidth: 1))
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

// MARK: - Manual add sheet

struct ManualAddSheet: View {
    let tab: LogsView.LogTab
    @ObservedObject var vm: StateViewModel
    @Binding var isPresented: Bool

    @State private var date = Date()
    @State private var ml: Double = 90
    @State private var diaperType: String = "pee"
    @State private var napDuration: String = ""
    @State private var submitting = false
    @State private var error: String?

    private static let apiFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var title: String {
        switch tab {
        case .formula: return "Add Mix"
        case .diaper:  return "Add Diaper"
        case .nap:     return "Add Nap"
        }
    }

    private var accent: Color {
        switch tab {
        case .formula: return Color.green
        case .diaper:  return Color.yellow
        case .nap:     return Color.purple
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.primaryBackground.ignoresSafeArea()

                List {
                    Section {
                        DatePicker("Time", selection: $date, displayedComponents: [.date, .hourAndMinute])
                            .environment(\.colorScheme, .dark)
                            .listRowBackground(Color.elevatedBackground)
                    } header: {
                        Text("When").foregroundColor(Color.secondaryLabel)
                    }

                    switch tab {
                    case .formula:
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("\(Int(ml))")
                                        .font(.custom("Outfit", size: 40, relativeTo: .largeTitle).bold())
                                        .foregroundColor(accent)
                                        .monospacedDigit()
                                    Text("ml")
                                        .appFont(.title3)
                                        .foregroundColor(Color.secondaryLabel)
                                }
                                Slider(value: $ml, in: 30...240, step: 5).tint(accent)
                            }
                            .padding(.vertical, 6)
                            .listRowBackground(Color.elevatedBackground)
                        } header: {
                            Text("Amount").foregroundColor(Color.secondaryLabel)
                        }
                    case .diaper:
                        Section {
                            Picker("Type", selection: $diaperType) {
                                Text("Pee").tag("pee")
                                Text("Poo").tag("poo")
                            }
                            .pickerStyle(.segmented)
                            .listRowBackground(Color.elevatedBackground)
                        } header: {
                            Text("Type").foregroundColor(Color.secondaryLabel)
                        }
                    case .nap:
                        Section {
                            TextField("Minutes (optional)", text: $napDuration)
                                .keyboardType(.numberPad)
                                .foregroundColor(Color.primaryLabel)
                                .listRowBackground(Color.elevatedBackground)
                        } header: {
                            Text("Duration").foregroundColor(Color.secondaryLabel)
                        } footer: {
                            Text("Leave blank to log an untimed nap.")
                                .appFont(.footnote)
                                .foregroundColor(Color.secondaryLabel)
                        }
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
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                        .foregroundColor(Color.secondaryLabel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Haptics.tap(.medium); Task { await submit() } }
                        .disabled(submitting)
                }
            }
        }
    }

    private func submit() async {
        guard !submitting else { return }
        submitting = true
        error = nil
        defer { submitting = false }

        let dateStr = Self.apiFormatter.string(from: date)
        do {
            switch tab {
            case .formula:
                _ = try await APIClient.shared.logEntry(ml: Int(ml), date: dateStr)
            case .diaper:
                try await APIClient.shared.logDiaper(type: diaperType, date: dateStr)
            case .nap:
                let mins = Int(napDuration.trimmingCharacters(in: .whitespaces))
                try await APIClient.shared.logNap(date: dateStr, durationMins: mins)
            }
            await vm.refresh()
            isPresented = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}
