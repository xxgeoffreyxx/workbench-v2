import Foundation

/// Twitter-style age for list rows ("now", "5m ago", "5h ago", "3d ago", "Sep 28", "Dec 4, 2025").
/// A plain string, so it stays fixed until the list's next refresh instead of ticking every second.
public enum ShortAge {
    public static func text(for date: Date, now: Date = Date(), calendar: Calendar = .current,
                            locale: Locale = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d ago" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "MMMdyyyy")
        return formatter.string(from: date)
    }
}
