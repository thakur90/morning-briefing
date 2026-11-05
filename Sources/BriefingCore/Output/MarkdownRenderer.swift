import Foundation

/// Plain-text copy of the briefing (design doc §7).
public struct MarkdownRenderer: Sendable {
    private let text: TimeText

    public init(calendar: Calendar = .current, locale: Locale = .current) {
        self.text = TimeText(calendar: calendar, locale: locale)
    }

    public func render(_ briefing: Briefing) -> String {
        let context = briefing.context
        var lines: [String] = []
        let date = context.generatedAt.formatted(
            Date.FormatStyle(locale: text.locale, calendar: text.calendar, timeZone: text.calendar.timeZone).weekday(.wide).month(.wide).day())
        lines.append("# \(briefing.headline)")
        var stamp = "\(date) · Generated \(text.time(briefing.generatedAt))"
        if let updated = briefing.updatedAt { stamp += " · Updated \(text.time(updated))" }
        lines += ["", "_\(stamp)_"]
        if let changes = briefing.changes, !changes.isEmpty {
            let wording = ChangeText(calendar: text.calendar, locale: text.locale)
            lines += ["", "## Changes since this morning", ""] + changes.map { "- \(wording.line($0))" }
        }
        lines += ["", "## Your day", "", briefing.sentences.joined(separator: " ")]

        if let weather = context.weather {
            let place = context.location?.name.map { " · \($0)" } ?? ""
            lines += ["", "## Weather\(place)", "",
                      "\(text.degrees(weather.currentTemperature)) \(weather.currentDescription) · High \(text.degrees(weather.high)) · Low \(text.degrees(weather.low))"]
            let hours = weather.hourly.enumerated().filter { $0.offset % 2 == 0 }.prefix(8)
                .map { "\(text.hour($0.element.time)) \(text.degrees($0.element.temperature)) (\($0.element.precipitationProbability)%)" }
            if !hours.isEmpty { lines += ["", hours.joined(separator: " · ")] }
        }

        lines += ["", "## Schedule", ""]
        if context.events.isEmpty { lines.append("No events today.") }
        for event in context.events {
            let time = event.isAllDay ? "All day" : text.range(event.start, event.end)
            var line = "- **\(time)** \(event.title) · \(event.calendar.title) (\(event.calendar.account))"
            if let location = event.location { line += " · \(location)" }
            lines.append(line)
            for note in briefing.notes[event.id] ?? [] { lines.append("  - \(note.text)") }
        }
        if !context.freeBlocks.isEmpty {
            lines.append("")
            lines.append("Free: " + context.freeBlocks.map { "\(text.range($0.start, $0.end)) (\(text.duration(minutes: $0.minutes)))" }.joined(separator: ", "))
        }

        if !context.reminders.isEmpty {
            lines += ["", "## Reminders", ""]
            for reminder in context.reminders {
                let due = reminder.due.map { reminder.isOverdue ? "overdue, due \(text.day($0))" : "today" } ?? "no date"
                lines.append("- [ ] \(reminder.title) (\(due) · \(reminder.list))")
            }
        }

        let failed = context.sources.filter { !$0.ok }
        lines += ["", "---", failed.isEmpty ? "All sources OK" : "Unavailable: " + failed.map(\.name).joined(separator: ", "), ""]
        return lines.joined(separator: "\n")
    }
}
