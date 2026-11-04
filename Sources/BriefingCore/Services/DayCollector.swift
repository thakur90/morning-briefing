import Foundation

/// Collects everything for one day (design doc §3.1, read path). Every source
/// can fail on its own; failures are recorded in `DayContext.sources`.
public struct DayCollector: Sendable {
    private let config: Config
    private let providers: [CalendarProvider]
    private let reminders: ReminderSource
    private let location: LocationService
    private let weather: WeatherService
    private let calendar: Calendar

    public init(
        config: Config, providers: [CalendarProvider], reminders: ReminderSource,
        location: LocationService, weather: WeatherService, calendar: Calendar = .current
    ) {
        self.config = config
        self.providers = providers
        self.reminders = reminders
        self.location = location
        self.weather = weather
        self.calendar = calendar
    }

    /// The real sources: EventKit, Core Location (with fallbacks), Open-Meteo.
    public static func live(config: Config, paths: AppPaths = AppPaths(), eventKit: EventKitStore) -> DayCollector {
        let http = URLSessionHTTPClient()
        return DayCollector(
            config: config,
            providers: [EventKitProvider(eventKit: eventKit)],
            reminders: RemindersService(eventKit: eventKit, lists: config.reminders.lists),
            location: LocationService(config: config.location, paths: paths, http: http, locator: CoreLocationLocator()),
            weather: WeatherService(http: http, unit: config.temperatureUnit))
    }

    public func collect(now: Date = .now) async -> DayContext {
        async let calendarResult = collectEvents(now: now)
        async let reminderResult = collectReminders(now: now)
        async let weatherResult = collectLocationAndWeather(now: now)

        let (events, eventStatus) = await calendarResult
        let (dueReminders, reminderStatus) = await reminderResult
        let (place, forecast, weatherStatuses) = await weatherResult

        let day = DaySchedule.dayInterval(for: now, calendar: calendar)
        var freeBlocks: [FreeBlock] = []
        if let start = try? Config.time(config.day.start, on: now, calendar: calendar),
           let end = try? Config.time(config.day.end, on: now, calendar: calendar) {
            // Time that has already passed isn't free.
            let windowStart = max(start, now)
            if windowStart < end {
                freeBlocks = DaySchedule.freeBlocks(
                    events, window: DateInterval(start: windowStart, end: end), minMinutes: config.day.minFreeMinutes)
            }
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        return DayContext(
            date: formatter.string(from: day.start),
            timeZone: calendar.timeZone.identifier,
            generatedAt: now,
            location: place,
            weather: forecast,
            events: events,
            freeBlocks: freeBlocks,
            overlaps: DaySchedule.overlaps(events),
            reminders: dueReminders,
            sources: eventStatus + [reminderStatus] + weatherStatuses)
    }

    private func collectEvents(now: Date) async -> ([Event], [SourceStatus]) {
        let day = DaySchedule.dayInterval(for: now, calendar: calendar)
        var all: [Event] = []
        var statuses: [SourceStatus] = []
        for provider in providers {
            do {
                let calendars = try await provider.calendars().filter { !isExcluded($0.ref) }
                let events = try await provider.events(in: day).filter { !isExcluded($0.calendar) }
                all += events
                // Name the accounts, so a missing one (e.g. Google not added yet) is easy to spot.
                let accounts = Array(Set(calendars.map(\.ref.account))).sorted()
                let seen = accounts.isEmpty ? "no calendars found" : "\(calendars.count) calendar(s) in \(accounts.joined(separator: ", "))"
                statuses.append(.ok("calendars", "\(DaySchedule.dedupe(events).count) event(s) today · \(seen)"))
            } catch {
                statuses.append(.failed("calendars", "\(provider.id): \(error)"))
            }
        }
        return (DaySchedule.dedupe(all), statuses)
    }

    private func isExcluded(_ calendar: CalendarRef) -> Bool {
        config.calendars.exclude.contains { $0 == calendar.title || $0 == "\(calendar.account)/\(calendar.title)" }
    }

    private func collectReminders(now: Date) async -> ([Reminder], SourceStatus) {
        do {
            let due = try await reminders.due(on: now, now: now, calendar: calendar)
            return (due, .ok("reminders", "\(due.count) due or overdue"))
        } catch {
            return ([], .failed("reminders", "\(error)"))
        }
    }

    private func collectLocationAndWeather(now: Date) async -> (LocationInfo?, WeatherForecast?, [SourceStatus]) {
        let (place, locationStatus) = await location.resolve()
        guard let place else {
            return (nil, nil, [locationStatus, .failed("weather", "skipped: no location")])
        }
        do {
            let forecast = try await weather.forecast(latitude: place.latitude, longitude: place.longitude, now: now)
            return (place, forecast, [locationStatus, .ok("weather", "Open-Meteo")])
        } catch {
            return (place, nil, [locationStatus, .failed("weather", "\(error)")])
        }
    }
}
