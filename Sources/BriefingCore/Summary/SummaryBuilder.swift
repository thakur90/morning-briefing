import Foundation

/// Builds the briefing summary from a DayContext with fixed rules, no AI (design doc §6).
public struct SummaryBuilder: Sendable {
    private let config: Config.Summary
    private let text: TimeText

    public init(config: Config.Summary, calendar: Calendar = .current, locale: Locale = .current) {
        self.config = config
        self.text = TimeText(calendar: calendar, locale: locale)
    }

    public func build(_ context: DayContext, generatedAt: Date? = nil) -> Briefing {
        let headline = headline(context)
        return Briefing(
            context: context,
            headline: headline,
            sentences: sentences(context),
            notes: notes(context),
            notificationTitle: headline,
            notificationBody: notificationBody(context),
            generatedAt: generatedAt ?? context.generatedAt)
    }

    // MARK: Headline (§6.1)

    func headline(_ context: DayContext) -> String {
        let timed = Self.timed(context.events)
        let base: String
        if timed.isEmpty {
            base = "Clear day: no meetings"
        } else if let first = context.overlaps.first {
            base = "\(text.count(timed.count, "meeting")) today, \(text.count(context.overlaps.count, "conflict")) at \(text.time(first.start))"
        } else if let noon = text.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: context.generatedAt),
                  case let morning = timed.filter({ $0.start < noon }).count, morning >= 3 {
            base = "Busy morning: \(morning) meetings before noon"
        } else if timed.count >= 5 {
            base = "Packed day: \(timed.count) meetings, \(text.range(timed.first!.start, timed.map(\.end).max()!))"
        } else {
            base = "\(text.count(timed.count, "meeting")) today, first at \(text.time(timed.first!.start))"
        }
        return base + (weatherSuffix(context.weather).map { " · \($0)" } ?? "")
    }

    func weatherSuffix(_ weather: WeatherForecast?) -> String? {
        guard let weather else { return nil }
        if let rain = firstRainyHour(weather) { return "rain from \(text.hour(rain.time))" }
        if weather.low <= freezing(weather.unit) { return "freezing tonight" }
        if weather.high >= hot(weather.unit) { return "hot afternoon" }
        return nil
    }

    // MARK: "Your day" paragraph (§6.2)

    func sentences(_ context: DayContext) -> [String] {
        let timed = Self.timed(context.events)
        var result: [String] = []

        // 1. Shape
        if let first = timed.first, let lastEnd = timed.map(\.end).max() {
            result.append(timed.count == 1
                ? "You have 1 meeting, \(text.range(first.start, first.end))."
                : "You have \(timed.count) meetings between \(text.time(first.start)) and \(text.time(lastEnd)).")
        } else {
            result.append("No meetings today.")
        }

        // 2. Back-to-back runs
        for run in backToBackRuns(timed) {
            result.append("\(text.range(run.first!.start, run.map(\.end).max()!)) is back-to-back (\(run.count) meetings).")
        }

        // 3. Conflicts
        for overlap in context.overlaps {
            result.append("\(overlap.firstTitle) overlaps \(overlap.secondTitle), \(text.range(overlap.start, overlap.end)).")
        }

        // 4. Longest free block
        if !timed.isEmpty, let longest = context.freeBlocks.max(by: { $0.minutes < $1.minutes }),
           longest.minutes >= config.highlightFreeMinutes {
            result.append("Your longest free block is \(text.range(longest.start, longest.end)) (\(text.duration(minutes: longest.minutes))).")
        }

        // 5. All-day events
        let allDay = context.events.filter(\.isAllDay).map(\.title)
        if !allDay.isEmpty { result.append("All day: \(allDay.joined(separator: ", ")).") }

        // 6. Reminders
        if let sentence = remindersSentence(context.reminders) { result.append(sentence) }

        // 7. Weather advice
        if let weather = context.weather {
            if let rain = firstRainyHour(weather) {
                result.append("Rain likely from \(text.hour(rain.time)) (\(rain.precipitationProbability)%), so take an umbrella.")
            }
            if weather.low <= freezing(weather.unit) { result.append("Low of \(text.degrees(weather.low)) tonight.") }
            if weather.high >= hot(weather.unit) { result.append("High of \(text.degrees(weather.high)).") }
        }
        return result
    }

    func remindersSentence(_ reminders: [Reminder]) -> String? {
        let overdue = reminders.filter(\.isOverdue)
        let dueToday = reminders.count - overdue.count
        var parts: [String] = []
        if !overdue.isEmpty {
            let oldest = overdue.compactMap(\.due).min().map { " (oldest from \(text.day($0)))" } ?? ""
            parts.append(overdue.count == 1 ? "1 reminder is overdue\(oldest)" : "\(overdue.count) reminders are overdue\(oldest)")
        }
        if dueToday > 0 {
            parts.append(parts.isEmpty
                ? (dueToday == 1 ? "1 reminder is due today" : "\(dueToday) reminders are due today")
                : "\(dueToday) \(dueToday == 1 ? "is" : "are") due today")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ") + "."
    }

    // MARK: Per-event notes (§6.3)

    func notes(_ context: DayContext) -> [String: [EventNote]] {
        let timed = Self.timed(context.events)
        var notes: [String: [EventNote]] = [:]
        if let first = timed.first, timed.count > 1 {
            notes[first.id, default: []].append(EventNote(kind: .first, text: "First meeting of the day"))
        }
        for (previous, next) in zip(timed, timed.dropFirst()) where isBackToBack(previous, next) {
            notes[next.id, default: []].append(EventNote(kind: .backToBack, text: "Back-to-back with \(previous.title)"))
        }
        for overlap in context.overlaps {
            let range = text.range(overlap.start, overlap.end)
            notes[overlap.firstID, default: []].append(EventNote(kind: .overlap, text: "Overlaps \(overlap.secondTitle) (\(range))"))
            notes[overlap.secondID, default: []].append(EventNote(kind: .overlap, text: "Overlaps \(overlap.firstTitle) (\(range))"))
        }
        return notes
    }

    // MARK: Notification (§6.4)

    public static let notificationLimit = 200

    func notificationBody(_ context: DayContext) -> String {
        let timed = Self.timed(context.events)
        var parts: [String] = []
        if let first = timed.first(where: { $0.end > context.generatedAt }) ?? timed.first {
            parts.append("First up: \(first.title) \(text.time(first.start)).")
        } else {
            parts.append("No meetings.")
        }
        if let longest = context.freeBlocks.max(by: { $0.minutes < $1.minutes }), longest.minutes >= config.highlightFreeMinutes, !timed.isEmpty {
            parts.append("Free \(text.range(longest.start, longest.end)).")
        }
        if !context.reminders.isEmpty {
            let overdue = context.reminders.filter(\.isOverdue).count
            parts.append(overdue > 0
                ? "\(text.count(context.reminders.count, "reminder")) (\(overdue) overdue)."
                : "\(text.count(context.reminders.count, "reminder")) due.")
        }
        if let weather = context.weather {
            if let rain = firstRainyHour(weather) {
                parts.append("Rain from \(text.hour(rain.time)), take an umbrella.")
            } else {
                parts.append("\(weather.currentDescription), high \(text.degrees(weather.high)).")
            }
        }
        return Self.truncate(parts.joined(separator: " "), to: Self.notificationLimit)
    }

    static func truncate(_ string: String, to limit: Int) -> String {
        guard string.count > limit else { return string }
        return String(string.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Helpers

    static func timed(_ events: [Event]) -> [Event] {
        events.filter { !$0.isAllDay }.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// Next starts less than `backToBackGapMinutes` after previous ends (overlaps excluded: they get their own note).
    func isBackToBack(_ previous: Event, _ next: Event) -> Bool {
        let gap = next.start.timeIntervalSince(previous.end)
        return gap >= 0 && gap < Double(config.backToBackGapMinutes * 60)
    }

    func backToBackRuns(_ timed: [Event]) -> [[Event]] {
        var runs: [[Event]] = []
        var current: [Event] = []
        for event in timed {
            if let last = current.last, isBackToBack(last, event) {
                current.append(event)
            } else {
                if current.count >= 2 { runs.append(current) }
                current = [event]
            }
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    func firstRainyHour(_ weather: WeatherForecast) -> HourlyWeather? {
        weather.hourly.first { $0.precipitationProbability >= config.rainThreshold }
    }

    private func freezing(_ unit: TemperatureUnit) -> Double { unit == .fahrenheit ? 32 : 0 }
    private func hot(_ unit: TemperatureUnit) -> Double { unit == .fahrenheit ? 86 : 30 }
}
