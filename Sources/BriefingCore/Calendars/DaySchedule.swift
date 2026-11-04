import Foundation

/// Pure schedule logic: de-duplication, free blocks and overlaps.
public enum DaySchedule {
    /// Merges events that appear in more than one calendar (e.g. a Google
    /// invite also copied to iCloud): same title, start and end.
    public static func dedupe(_ events: [Event]) -> [Event] {
        var result: [Event] = []
        var indexByKey: [String: Int] = [:]
        for event in events.sorted(by: order) {
            let key = "\(event.title.lowercased())|\(event.start.timeIntervalSince1970)|\(event.end.timeIntervalSince1970)"
            if let index = indexByKey[key] {
                if result[index].calendar != event.calendar, !result[index].alsoIn.contains(event.calendar) {
                    result[index].alsoIn.append(event.calendar)
                }
            } else {
                indexByKey[key] = result.count
                result.append(event)
            }
        }
        return result
    }

    /// Gaps of at least `minMinutes` between timed events, inside `window`.
    public static func freeBlocks(_ events: [Event], window: DateInterval, minMinutes: Int) -> [FreeBlock] {
        let busy = events
            .filter { !$0.isAllDay }
            .compactMap { DateInterval(start: $0.start, end: max($0.start, $0.end)).intersection(with: window) }
            .sorted { $0.start < $1.start }

        var blocks: [FreeBlock] = []
        var cursor = window.start
        for interval in busy {
            if interval.start > cursor { blocks.append(FreeBlock(start: cursor, end: interval.start)) }
            cursor = max(cursor, interval.end)
        }
        if window.end > cursor { blocks.append(FreeBlock(start: cursor, end: window.end)) }
        return blocks.filter { $0.minutes >= minMinutes }
    }

    /// Pairs of timed events that overlap by at least a minute.
    public static func overlaps(_ events: [Event]) -> [Overlap] {
        let timed = events.filter { !$0.isAllDay }.sorted(by: order)
        var result: [Overlap] = []
        for (i, first) in timed.enumerated() {
            for second in timed[(i + 1)...] {
                guard second.start < first.end else { break }
                let end = min(first.end, second.end)
                guard end.timeIntervalSince(second.start) >= 60 else { continue }
                result.append(Overlap(
                    firstID: first.id, secondID: second.id,
                    firstTitle: first.title, secondTitle: second.title,
                    start: second.start, end: end))
            }
        }
        return result
    }

    /// Today's local day as an interval.
    public static func dayInterval(for date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    /// All-day events first, then by start time, then by title.
    static func order(_ a: Event, _ b: Event) -> Bool {
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        if a.start != b.start { return a.start < b.start }
        return a.title < b.title
    }
}
