import Foundation

/// Cached, reusable DateFormatters. Creating a DateFormatter is expensive
/// (~ms); these are built once and shared. Formatting/parsing on a configured
/// DateFormatter is thread-safe on Apple platforms, and we use them from the
/// main actor in practice.
enum Formatters {
    /// Canonical log-entry timestamp, matching the server format.
    static let entry: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// "yyyy-MM-dd" day bucket key.
    static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// "h:mm a" — display time (e.g. 2:34 PM).
    static let timeShort: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    /// "hh:mm a" — zero-padded time used when composing entry text.
    static let entryTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "hh:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// "MMM d" — chart axis / tooltip dates.
    static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}
