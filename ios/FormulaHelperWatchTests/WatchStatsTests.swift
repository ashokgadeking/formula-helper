import XCTest
@testable import FormulaHelperWatch

final class WatchStatsTests: XCTestCase {
    /// Fixed "now": 2026-07-04 02:30 PM local.
    private let now = Formatters.entry.date(from: "2026-07-04 02:30 PM")!

    private func makeState(
        mixLog: [LogEntry] = [],
        diapers: [DiaperEntry] = [],
        naps: [NapEntry]? = nil,
        countdownEnd: Double = 0
    ) -> AppStateResponse {
        AppStateResponse(
            countdown_end: countdownEnd,
            mixed_at_str: "",
            mixed_ml: 0,
            remaining_secs: 0,
            expired: true,
            ntfy_sent: false,
            mix_log: mixLog,
            settings: AppSettings(countdown_secs: 9000, ss_timeout_min: 5,
                                  preset1_ml: 90, preset2_ml: 120),
            combos: [],
            powder_per_60: 9.4,
            weight_log: [],
            diaper_log: diapers,
            nap_log: naps
        )
    }

    private func entry(_ date: String, ml: Int, leftover: String = "0") -> LogEntry {
        LogEntry(sk: "LOG#\(date)", text: "", leftover: leftover, ml: ml,
                 date: date, created_by: "ashok",
                 source: nil, measured_grams: nil, measured_ml: nil)
    }

    func testLastFeedPicksNewestEntry() {
        let state = makeState(mixLog: [
            entry("2026-07-04 09:00 AM", ml: 90),
            entry("2026-07-04 01:00 PM", ml: 120),
            entry("2026-07-03 11:00 PM", ml: 60),
        ])
        let last = WatchStats.lastFeed(state)
        XCTAssertEqual(last?.ml, 120)
        XCTAssertEqual(last?.date, Formatters.entry.date(from: "2026-07-04 01:00 PM"))
    }

    func testLastFeedNilWhenEmpty() {
        XCTAssertNil(WatchStats.lastFeed(makeState()))
    }

    func testTodayMlSumsConsumedMlForTodayOnly() {
        let state = makeState(mixLog: [
            entry("2026-07-04 09:00 AM", ml: 90),
            entry("2026-07-04 01:00 PM", ml: 120, leftover: "20"),  // consumed 100
            entry("2026-07-03 11:00 PM", ml: 60),                    // yesterday
        ])
        XCTAssertEqual(WatchStats.todayMl(state, now: now), 190)
    }

    func testTodayDiaperAndNapCounts() {
        let state = makeState(
            diapers: [
                DiaperEntry(sk: "D#1", type: "pee", date: "2026-07-04 08:00 AM", created_by: "a"),
                DiaperEntry(sk: "D#2", type: "poo", date: "2026-07-04 10:00 AM", created_by: "a"),
                DiaperEntry(sk: "D#3", type: "pee", date: "2026-07-03 08:00 AM", created_by: "a"),
            ],
            naps: [NapEntry(sk: "N#1", date: "2026-07-04 11:00 AM", created_by: "a", duration_mins: nil)]
        )
        XCTAssertEqual(WatchStats.todayDiapers(state, now: now), 2)
        XCTAssertEqual(WatchStats.todayNaps(state, now: now), 1)
    }

    func testTodayNapsZeroWhenNapLogNil() {
        XCTAssertEqual(WatchStats.todayNaps(makeState(naps: nil), now: now), 0)
    }

    func testCountdownRemaining() {
        let state = makeState(countdownEnd: now.timeIntervalSince1970 + 600)
        XCTAssertEqual(WatchStats.countdownRemaining(state, now: now), 600)
        let expired = makeState(countdownEnd: now.timeIntervalSince1970 - 10)
        XCTAssertNil(WatchStats.countdownRemaining(expired, now: now))
    }
}
