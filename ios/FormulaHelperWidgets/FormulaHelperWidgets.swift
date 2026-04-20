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
                    TimelineView(.periodic(from: .now, by: 10)) { tl in
                        let isExpired = tl.date >= context.state.countdownEnd
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isExpired ? "NOT FRESH" : "TIME LEFT")
                                .font(.system(size: 8, weight: .semibold))
                                .tracking(1.5)
                                .foregroundColor(.secondary)
                            if isExpired {
                                Text("EXPIRED")
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .foregroundColor(.red)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            } else {
                                Text(timerInterval: Date.now...context.state.countdownEnd, countsDown: true)
                                    .font(.system(size: 22, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                        }
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
                TimelineView(.periodic(from: context.state.countdownStart, by: 10)) { tl in
                    let isExpired = tl.date >= context.state.countdownEnd
                    let total = context.state.countdownEnd.timeIntervalSince(context.state.countdownStart)
                    let elapsed = tl.date.timeIntervalSince(context.state.countdownStart)
                    let fraction = Double(max(0, min(1, total > 0 ? elapsed / total : 1)))
                    let timerColor = Color(red: fraction, green: 1 - fraction, blue: 0)
                    if isExpired {
                        Text("EXP")
                            .font(.caption2.bold())
                            .foregroundColor(.red)
                            .frame(width: 36)
                    } else {
                        Text(timerInterval: Date.now...context.state.countdownEnd, countsDown: true)
                            .monospacedDigit()
                            .font(.caption2.bold())
                            .foregroundColor(timerColor)
                            .frame(width: 36)
                            .minimumScaleFactor(0.8)
                    }
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let isExpired = context.date >= state.countdownEnd
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    // Left — countdown or EXPIRED
                    VStack(alignment: .leading, spacing: 3) {
                        if isExpired {
                            Text("EXPIRED")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundColor(.red.opacity(0.9))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        } else {
                            Text(timerInterval: Date.now...state.countdownEnd, countsDown: true)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        Text(isExpired ? "NOT FRESH" : "TIME LEFT")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(1.5)
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Center — quantity
                    VStack(alignment: .center, spacing: 3) {
                        Text("\(state.lastMl)ml")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor((isExpired ? green.opacity(0.4) : green.opacity(0.85)))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("AMOUNT")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(1.5)
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    // Right — mixed at
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(mixedAt(state.countdownStart))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(isExpired ? 0.4 : 0.85))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("MIXED AT")
                            .font(.system(size: 8, weight: .semibold))
                            .tracking(1.5)
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                FreshnessBar(start: state.countdownStart, end: state.countdownEnd)
                    .frame(height: 8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
    }
}

// MARK: - Remaining-time bar (fills left, depletes right→left, green→yellow→red)

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
                ZStack(alignment: .leading) {
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
