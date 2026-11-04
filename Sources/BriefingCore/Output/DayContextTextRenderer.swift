import Foundation

/// Plain-text view of a DayContext, for `briefing today --dry-run`.
public enum DayContextTextRenderer {
    public static func render(_ context: DayContext, calendar: Calendar = .current) -> String {
        var lines: [String] = []
        let time = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)
        let hour = Date.FormatStyle(timeZone: calendar.timeZone).hour()

        let heading = context.generatedAt.formatted(
            Date.FormatStyle(timeZone: calendar.timeZone).weekday(.wide).month(.abbreviated).day())
        let place = context.location.map { location in
            let name = location.name ?? String(format: "%.2f, %.2f", location.latitude, location.longitude)
            return " · \(name) (\(label(location.source)))"
        } ?? ""
        lines.append("\(heading)\(place)")
        lines.append("")

        if let weather = context.weather {
            lines.append("Weather    \(degrees(weather.currentTemperature)) \(weather.currentDescription) · High \(degrees(weather.high)) / Low \(degrees(weather.low)) · Rain up to \(weather.maxPrecipitationProbability)%")
            let strip = weather.hourly.enumerated()
                .filter { $0.offset % 2 == 0 }
                .prefix(8)
                .map { "\($0.element.time.formatted(hour)) \(degrees($0.element.temperature))/\($0.element.precipitationProbability)%" }
            if !strip.isEmpty { lines.append("           " + strip.joined(separator: "  ")) }
        } else {
            lines.append("Weather    unavailable")
        }
        lines.append("")

        lines.append("Schedule   \(context.events.count) event(s)")
        for event in context.events {
            let span = event.isAllDay
                ? "all day      "
                : "\(event.start.formatted(time))–\(event.end.formatted(time))".padding(toLength: 13, withPad: " ", startingAt: 0)
            var line = "           \(span) \(event.title)  · \(event.calendar.title) (\(event.calendar.account))"
            if !event.alsoIn.isEmpty { line += " +\(event.alsoIn.count) more" }
            lines.append(line)
            for overlap in context.overlaps where overlap.firstID == event.id {
                lines.append("                         ⚠ overlaps \"\(overlap.secondTitle)\" \(overlap.start.formatted(time))–\(overlap.end.formatted(time))")
            }
        }
        if !context.freeBlocks.isEmpty {
            let blocks = context.freeBlocks.map { "\($0.start.formatted(time))–\($0.end.formatted(time))" }
            lines.append("           Free: \(blocks.joined(separator: ", "))")
        }
        lines.append("")

        lines.append("Reminders  \(context.reminders.count) due")
        for reminder in context.reminders {
            let due = reminder.due.map { date in
                reminder.isOverdue
                    ? "Overdue (\(date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).month(.abbreviated).day())))"
                    : reminder.dueHasTime ? "Today \(date.formatted(time))" : "Today"
            } ?? "No date"
            lines.append("           \(due.padding(toLength: 16, withPad: " ", startingAt: 0)) \(reminder.title)  · \(reminder.list)")
        }
        lines.append("")

        lines.append("Sources")
        for source in context.sources {
            lines.append("           \(source.ok ? "✅" : "❌") \(source.name)\(source.detail.map { ": \($0)" } ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    private static func degrees(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }

    private static func label(_ source: LocationSource) -> String {
        switch source {
        case .current: "current location"
        case .cached: "last known location"
        case .ip: "approximate, from IP"
        case .configCity: "from config"
        }
    }
}
