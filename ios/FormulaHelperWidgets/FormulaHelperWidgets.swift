import WidgetKit
import SwiftUI
import ActivityKit

// MARK: - Widget bundle

@main
struct FormulaHelperWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FormulaLiveActivityWidget()
    }
}

// MARK: - Widget config

struct FormulaLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FormulaActivityAttributes.self) { context in
            LockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TIME LEFT")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(1.5)
                            .foregroundColor(.secondary)
                        Text(timerInterval: Date.now...context.state.countdownEnd, countsDown: true)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("MIXED AT")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(1.5)
                            .foregroundColor(.secondary)
                        Text(mixedAt(context.state.countdownStart))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        Text("\(context.state.lastMl)ml")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(green)
                        ProgressView(
                            timerInterval: context.state.countdownStart...context.state.countdownEnd,
                            countsDown: false
                        ) { EmptyView() } currentValueLabel: { EmptyView() }
                        .progressViewStyle(.linear)
                        .tint(green)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Text("🍼")
                    .font(.system(size: 15))
            } compactTrailing: {
                let safeEnd = max(context.state.countdownEnd, Date.now.addingTimeInterval(1))
                TimelineView(.periodic(from: context.state.countdownStart, by: 10)) { tl in
                    let total = context.state.countdownEnd.timeIntervalSince(context.state.countdownStart)
                    let elapsed = tl.date.timeIntervalSince(context.state.countdownStart)
                    let fraction = Double(max(0, min(1, total > 0 ? elapsed / total : 1)))
                    let timerColor = Color(red: fraction, green: 1 - fraction, blue: 0)
                    Text(timerInterval: Date.now...safeEnd, countsDown: true)
                        .monospacedDigit()
                        .font(.caption2.bold())
                        .foregroundColor(timerColor)
                        .frame(width: 36)
                        .minimumScaleFactor(0.8)
                }
            } minimal: {
                Text("🍼")
                    .font(.system(size: 12))
            }
        }
    }
}

// MARK: - Lock Screen view

struct LockScreenView: View {
    let state: FormulaActivityAttributes.ContentState

    private var safeEnd: Date { max(state.countdownEnd, Date.now) }

    var body: some View {
        VStack(spacing: 14) {
            // ── Row: Timer | ML | Mixed At ──
            HStack(alignment: .center) {
                // Left — countdown
                VStack(alignment: .leading, spacing: 3) {
                    if state.countdownEnd > Date.now {
                        Text(timerInterval: Date.now...safeEnd, countsDown: true)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.white.opacity(0.85))
                            .minimumScaleFactor(0.7)
                    } else {
                        Text("0:00")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.white.opacity(0.4))
                    }
                    Text("TIME LEFT")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(1.5)
                        .foregroundColor(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Center — quantity
                VStack(alignment: .center, spacing: 3) {
                    Text("\(state.lastMl)ml")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(green.opacity(0.85))
                    Text("AMOUNT")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(1.5)
                        .foregroundColor(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity, alignment: .center)

                // Right — mixed at
                VStack(alignment: .trailing, spacing: 3) {
                    Text(mixedAt(state.countdownStart))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.85))
                        .minimumScaleFactor(0.7)
                    Text("MIXED AT")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(1.5)
                        .foregroundColor(.white.opacity(0.35))
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            // ── Progress bar — bottle life remaining ──
            VStack(spacing: 4) {
                FreshnessBar(start: state.countdownStart, end: state.countdownEnd)
                    .frame(height: 10)

                ZStack {
                    Text("BOTTLE FRESHNESS")
                        .font(.system(size: 7, weight: .medium))
                        .tracking(1)
                        .foregroundColor(.secondary)
                    HStack {
                        Text("EXPIRED")
                            .font(.system(size: 7, weight: .medium))
                            .tracking(1)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("FRESH")
                            .font(.system(size: 7, weight: .medium))
                            .tracking(1)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }
}

// MARK: - Freshness bar (depletes right→left, green→yellow→red)

struct FreshnessBar: View {
    let start: Date
    let end: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 10)) { context in
            let total = end.timeIntervalSince(start)
            let elapsed = context.date.timeIntervalSince(start)
            let fraction = CGFloat(max(0, min(1, total > 0 ? elapsed / total : 1)))
            let barColor = Color(red: Double(fraction), green: Double(1 - fraction), blue: 0)
                .opacity(0.6)

            GeometryReader { geo in
                ZStack(alignment: .trailing) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(barColor)
                        .frame(width: geo.size.width * (1 - fraction))
                }
            }
        }
    }
}

// MARK: - Helpers

private let green = Color(red: 0.267, green: 0.839, blue: 0.431)

private func mixedAt(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "h:mm"
    return f.string(from: date)
}
