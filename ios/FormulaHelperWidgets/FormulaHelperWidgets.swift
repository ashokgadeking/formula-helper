import WidgetKit
import SwiftUI

// MARK: - Helpers

/// Minute-precision "Xh Ym ago" / "Ym ago" / "<1m ago". Seconds are intentionally
/// dropped — widget timelines re-emit per-minute entries so the text ticks at
/// minute boundaries instead of every second.
func minuteAgoString(from date: Date, now: Date = Date()) -> String {
    let secs = max(0, Int(now.timeIntervalSince(date)))
    let mins = secs / 60
    if mins < 1 { return "just now" }
    let h = mins / 60
    let m = mins % 60
    if h > 0 { return "\(h)h \(m)m ago" }
    return "\(m)m ago"
}

/// Per-minute entry dates for the next `count` minutes, anchored on the next
/// minute boundary so updates align with the wall clock.
func nextMinuteBoundaries(from now: Date, count: Int) -> [Date] {
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
    guard let truncated = cal.date(from: comps) else { return [] }
    let start = truncated.addingTimeInterval(60)
    return (0..<count).map { start.addingTimeInterval(TimeInterval($0 * 60)) }
}

// MARK: - Bundle

@main
struct FormulaHelperWidgets: WidgetBundle {
    var body: some Widget {
        LastBottleWidget()
        LastDiaperWidget()
    }
}

// MARK: - Snapshot

/// What we render. Computed from `CachedState` at timeline-build time.
enum BottleSnapshot {
    case none
    case past(ml: Int, consumedMl: Int, mixedAt: Date)
    case running(ml: Int, mixedAt: Date, end: Date)
    case expired(ml: Int, mixedAt: Date)
}

struct LastBottleEntry: TimelineEntry {
    let date: Date
    let snapshot: BottleSnapshot
}

// MARK: - Timeline

struct LastBottleProvider: TimelineProvider {
    func placeholder(in context: Context) -> LastBottleEntry {
        LastBottleEntry(
            date: Date(),
            snapshot: .past(ml: 120, consumedMl: 90, mixedAt: Date().addingTimeInterval(-6240))
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LastBottleEntry) -> Void) {
        completion(LastBottleEntry(date: Date(), snapshot: load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LastBottleEntry>) -> Void) {
        let now = Date()
        let snapshot = load()

        // Emit per-minute entries so the pre-formatted "X ago" string ticks at
        // minute boundaries. For the running case, the countdown timer is
        // iOS-native auto-updating, but we still emit minute entries so the
        // mixedAt "ago" line in the same view updates, and we cap entries at
        // the countdown end where the view flips to .expired.
        var entries: [LastBottleEntry] = [LastBottleEntry(date: now, snapshot: snapshot)]
        let boundaries = nextMinuteBoundaries(from: now, count: 60)
        let nextReload: Date

        switch snapshot {
        case .running(let ml, let mixedAt, let end):
            for b in boundaries where b < end {
                entries.append(LastBottleEntry(date: b, snapshot: .running(ml: ml, mixedAt: mixedAt, end: end)))
            }
            entries.append(LastBottleEntry(date: end, snapshot: .expired(ml: ml, mixedAt: mixedAt)))
            // After expiry, keep emitting per-minute updates for the .expired
            // view's "X ago" line.
            for b in nextMinuteBoundaries(from: end, count: 30) {
                entries.append(LastBottleEntry(date: b, snapshot: .expired(ml: ml, mixedAt: mixedAt)))
            }
            nextReload = end.addingTimeInterval(60 * 31)
        case .past(let ml, let consumedMl, let mixedAt):
            for b in boundaries {
                entries.append(LastBottleEntry(date: b, snapshot: .past(ml: ml, consumedMl: consumedMl, mixedAt: mixedAt)))
            }
            nextReload = boundaries.last ?? now.addingTimeInterval(600)
        case .none:
            nextReload = now.addingTimeInterval(600)
        case .expired:
            // Should be unreachable from load() (load only returns .past/.running/.none),
            // but handle defensively.
            nextReload = now.addingTimeInterval(600)
        }
        completion(Timeline(entries: entries, policy: .after(nextReload)))
    }

    private static let entryDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func load() -> BottleSnapshot {
        guard let state = CacheManager.shared.restore() else { return .none }
        // Last entry by parsed date — the SK order is by creation time on the
        // server, which diverges from chronological for backfills (see LogsView's
        // chronoDesc). Reproduce that sort here so the widget never shows a
        // backfilled-yesterday entry as "the latest bottle".
        let parsed = state.mix_log.compactMap { e -> (ml: Int, consumed: Int, date: Date)? in
            guard let d = Self.entryDateFormatter.date(from: e.date) else { return nil }
            return (e.ml, e.consumedMl, d)
        }
        guard let last = parsed.max(by: { $0.date < $1.date }) else { return .none }

        let timerEnd = state.countdown_end
        let now = Date().timeIntervalSince1970
        if timerEnd > now {
            return .running(ml: last.ml, mixedAt: last.date, end: Date(timeIntervalSince1970: timerEnd))
        }
        return .past(ml: last.ml, consumedMl: last.consumed, mixedAt: last.date)
    }
}

// MARK: - Widget

struct LastBottleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LastBottleWidget", provider: LastBottleProvider()) { entry in
            LastBottleEntryView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Last Bottle")
        .description("Time since the last bottle was mixed; current bottle timer if one is running.")
        .supportedFamilies([.accessoryRectangular])
    }
}

// MARK: - View

/// Full-height emoji on the left of accessoryRectangular widgets. The
/// minimumScaleFactor keeps it visible even when the system shrinks the
/// vertical bounds for certain lock-screen complications.
private struct WidgetEmoji: View {
    let value: String
    var body: some View {
        Text(value)
            .font(.system(size: 32))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .frame(maxHeight: .infinity)
            .frame(width: 36)
    }
}

struct LastBottleEntryView: View {
    let entry: LastBottleEntry

    var body: some View {
        HStack(spacing: 6) {
            WidgetEmoji(value:"🍼")
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch entry.snapshot {
        case .none:
            Text("No bottles yet")
                .font(.system(size: 14, weight: .semibold))

        case .past(let ml, let consumedMl, let mixedAt):
            VStack(alignment: .leading, spacing: 2) {
                Text(minuteAgoString(from: mixedAt, now: entry.date))
                    .font(.system(size: 14, weight: .semibold))
                Text(consumedMl < ml ? "\(ml)ml | \(consumedMl)ml consumed" : "\(ml) ml mixed")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

        case .running(let ml, let mixedAt, let end):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 11))
                    Text(timerInterval: Date.now...end, countsDown: true)
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                }
                Text("\(ml) ml · \(minuteAgoString(from: mixedAt, now: entry.date))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

        case .expired(let ml, let mixedAt):
            VStack(alignment: .leading, spacing: 2) {
                Text("DISCARD BOTTLE")
                    .font(.system(size: 14, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.red)
                Text("\(ml) ml · \(minuteAgoString(from: mixedAt, now: entry.date))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Last diaper widget

enum DiaperSnapshot {
    case none
    case some(lastType: String, lastAt: Date, peeToday: Int, pooToday: Int)
}

struct LastDiaperEntry: TimelineEntry {
    let date: Date
    let snapshot: DiaperSnapshot
}

struct LastDiaperProvider: TimelineProvider {
    func placeholder(in context: Context) -> LastDiaperEntry {
        LastDiaperEntry(
            date: Date(),
            snapshot: .some(lastType: "pee", lastAt: Date().addingTimeInterval(-8040), peeToday: 4, pooToday: 2)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LastDiaperEntry) -> Void) {
        completion(LastDiaperEntry(date: Date(), snapshot: load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LastDiaperEntry>) -> Void) {
        let now = Date()
        let snapshot = load()
        var entries = [LastDiaperEntry(date: now, snapshot: snapshot)]

        // Per-minute entries so the pre-formatted "X ago" string ticks at
        // minute boundaries. Also emit midnight rollover for today-counts.
        for b in nextMinuteBoundaries(from: now, count: 60) {
            entries.append(LastDiaperEntry(date: b, snapshot: snapshot))
        }
        let cal = Calendar.current
        if let nextMidnight = cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) {
            entries.append(LastDiaperEntry(date: nextMidnight, snapshot: rollOverForMidnight(snapshot)))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }

    private static let entryDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func load() -> DiaperSnapshot {
        guard let state = CacheManager.shared.restore() else { return .none }
        let parsed: [(type: String, date: Date)] = state.diaper_log.compactMap { e in
            guard let d = Self.entryDateFormatter.date(from: e.date) else { return nil }
            return (e.type, d)
        }
        guard let last = parsed.max(by: { $0.date < $1.date }) else { return .none }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let today = parsed.filter { $0.date >= startOfDay }
        let pee = today.filter { $0.type == "pee" }.count
        let poo = today.filter { $0.type == "poo" }.count
        return .some(lastType: last.type, lastAt: last.date, peeToday: pee, pooToday: poo)
    }

    /// After midnight, today-counts reset to zero but the "last" entry stays.
    private func rollOverForMidnight(_ snapshot: DiaperSnapshot) -> DiaperSnapshot {
        switch snapshot {
        case .none: return .none
        case .some(let lastType, let lastAt, _, _):
            return .some(lastType: lastType, lastAt: lastAt, peeToday: 0, pooToday: 0)
        }
    }
}

struct LastDiaperWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LastDiaperWidget", provider: LastDiaperProvider()) { entry in
            LastDiaperEntryView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Last Diaper")
        .description("Time since the last diaper change and today's totals.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct LastDiaperEntryView: View {
    let entry: LastDiaperEntry

    var body: some View {
        HStack(spacing: 6) {
            WidgetEmoji(value:emojiValue)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var emojiValue: String {
        switch entry.snapshot {
        case .none: return "👶"
        case .some(let lastType, _, _, _): return lastType == "poo" ? "💩" : "🌊"
        }
    }

    @ViewBuilder private var content: some View {
        switch entry.snapshot {
        case .none:
            Text("No diapers yet")
                .font(.system(size: 14, weight: .semibold))

        case .some(let lastType, let lastAt, _, _):
            VStack(alignment: .leading, spacing: 2) {
                Text(minuteAgoString(from: lastAt, now: entry.date))
                    .font(.system(size: 14, weight: .semibold))
                Text("\(lastType) diaper")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
