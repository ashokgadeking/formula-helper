import Foundation

/// Pure helpers turning the server state into glanceable numbers.
enum WatchStats {
    static func lastFeed(_ state: AppStateResponse) -> (date: Date, ml: Int)? {
        state.mix_log
            .compactMap { e in Formatters.entry.date(from: e.date).map { ($0, e.ml) } }
            .max { $0.0 < $1.0 }
    }

    static func todayMl(_ state: AppStateResponse, now: Date = Date(),
                        calendar: Calendar = .current) -> Int {
        state.mix_log
            .filter { isSameDay($0.date, as: now, calendar) }
            .reduce(0) { $0 + $1.consumedMl }
    }

    static func todayDiapers(_ state: AppStateResponse, now: Date = Date(),
                             calendar: Calendar = .current) -> Int {
        state.diaper_log.filter { isSameDay($0.date, as: now, calendar) }.count
    }

    static func todayNaps(_ state: AppStateResponse, now: Date = Date(),
                          calendar: Calendar = .current) -> Int {
        (state.nap_log ?? []).filter { isSameDay($0.date, as: now, calendar) }.count
    }

    static func countdownRemaining(_ state: AppStateResponse, now: Date = Date()) -> TimeInterval? {
        let remaining = state.countdown_end - now.timeIntervalSince1970
        return remaining > 0 ? remaining : nil
    }

    private static func isSameDay(_ dateString: String, as now: Date, _ calendar: Calendar) -> Bool {
        guard let d = Formatters.entry.date(from: dateString) else { return false }
        return calendar.isDate(d, inSameDayAs: now)
    }
}
