import SwiftUI

struct WatchRootView: View {
    @StateObject private var vm = WatchViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if vm.signedIn {
                loggedInBody
            } else {
                signedOutBody
            }
        }
        .task { await vm.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await vm.refresh() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionDidChange)) { _ in
            Task { await vm.refresh() }
        }
    }

    private var signedOutBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title2)
            Text("Open AvantiLog on your iPhone to sign in")
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var loggedInBody: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                if let msg = vm.errorMessage {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                diaperButtons
                feedButtons
                napButton
            }
        }
    }

    private var header: some View {
        TimelineView(.everyMinute) { context in
            VStack(spacing: 2) {
                if let state = vm.state {
                    if let remaining = WatchStats.countdownRemaining(state, now: context.date) {
                        Text("Next feed in \(Self.hhmm(remaining))")
                            .font(.headline)
                    } else if let last = WatchStats.lastFeed(state) {
                        Text("\(Self.hhmm(context.date.timeIntervalSince(last.date))) since \(last.ml) ml")
                            .font(.headline)
                    } else {
                        Text("No feeds yet").font(.headline)
                    }
                    Text("Today: \(WatchStats.todayMl(state, now: context.date)) ml · \(WatchStats.todayDiapers(state, now: context.date)) 💩 · \(WatchStats.todayNaps(state, now: context.date)) 😴")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
    }

    private var feedButtons: some View {
        HStack {
            presetButton(ml: vm.state?.settings.preset1_ml ?? 90)
            presetButton(ml: vm.state?.settings.preset2_ml ?? 120)
        }
    }

    private func presetButton(ml: Int) -> some View {
        Button {
            Task { await vm.logFeed(ml: ml) }
        } label: {
            VStack(spacing: 0) {
                Text("\(ml)").font(.title3.bold())
                Text("ml").font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .tint(.blue)
        .disabled(vm.isLogging)
    }

    private var diaperButtons: some View {
        HStack {
            Button("💧 Pee") { Task { await vm.logDiaper(type: "pee") } }
            Button("💩 Poo") { Task { await vm.logDiaper(type: "poo") } }
        }
        .disabled(vm.isLogging)
    }

    private var napButton: some View {
        Button("😴 Nap") { Task { await vm.logNap() } }
            .disabled(vm.isLogging)
    }

    private static func hhmm(_ interval: TimeInterval) -> String {
        let mins = max(0, Int(interval)) / 60
        return mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m"
    }
}
