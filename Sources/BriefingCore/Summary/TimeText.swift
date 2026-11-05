import Foundation

/// Locale-aware time and count formatting for summaries.
struct TimeText: Sendable {
    let calendar: Calendar
    let locale: Locale

    private var timeStyle: Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }

    /// "9:30 AM"
    func time(_ date: Date) -> String { date.formatted(timeStyle) }

    /// "4 PM"
    func hour(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour())
    }

    /// "12:00 – 3:00 PM"
    func range(_ start: Date, _ end: Date) -> String {
        guard start < end else { return time(start) }
        let style = Date.IntervalFormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        return (start..<end).formatted(style)
    }

    /// "Sep 13"
    func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day())
    }

    /// "3 h", "1 h 30 min", "45 min"
    func duration(minutes: Int) -> String {
        let (h, m) = (minutes / 60, minutes % 60)
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) h"
        default: return "\(h) h \(m) min"
        }
    }

    /// "1 meeting", "3 meetings"
    func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : plural ?? singular + "s")"
    }

    func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }
}
