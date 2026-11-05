import BriefingCore
import Foundation

let work = CalendarRef(title: "Work", account: "Google")
let home = CalendarRef(title: "Home", account: "iCloud")

func event(_ id: String, _ title: String, _ start: Date, _ end: Date, _ calendar: CalendarRef = work, allDay: Bool = false) -> Event {
    Event(id: id, title: title, start: start, end: end, isAllDay: allDay, calendar: calendar)
}

// MARK: DaySchedule

await Harness.test("dedupe merges the same event from two calendars") {
    let events = DaySchedule.dedupe([
        event("a", "Standup", at(9, 30), at(10), work),
        event("b", "Standup", at(9, 30), at(10), home),
        event("c", "Standup", at(15), at(15, 30), work),
    ])
    expectEqual(events.count, 2)
    expectEqual(events.first?.alsoIn, [home])
}

await Harness.test("dedupe keeps events with the same title at different times") {
    expectEqual(DaySchedule.dedupe([event("a", "Focus", at(9), at(10)), event("b", "Focus", at(14), at(15))]).count, 2)
}

await Harness.test("dedupe orders all-day events first, then by start") {
    let events = DaySchedule.dedupe([
        event("t", "Lunch", at(12), at(13)),
        event("a", "Holiday", at(0), at(0, day: 5), allDay: true),
        event("s", "Standup", at(9), at(9, 30)),
    ])
    expectEqual(events.map(\.id), ["a", "s", "t"])
}

await Harness.test("free blocks fill the gaps inside the window") {
    let window = DateInterval(start: at(8), end: at(18))
    let blocks = DaySchedule.freeBlocks([
        event("a", "Standup", at(9, 30), at(10)),
        event("b", "Review", at(10), at(11)),
        event("c", "Lunch", at(12), at(13)),
    ], window: window, minMinutes: 30)
    expectEqual(blocks.map(\.start), [at(8), at(11), at(13)])
    expectEqual(blocks.map(\.end), [at(9, 30), at(12), at(18)])
}

await Harness.test("free blocks skip short gaps, all-day events, and clip to the window") {
    let window = DateInterval(start: at(8), end: at(18))
    let blocks = DaySchedule.freeBlocks([
        event("x", "Offsite", at(0), at(0, day: 5), allDay: true),
        event("a", "Early", at(6), at(9)),           // starts before the window
        event("b", "Next", at(9, 20), at(17, 45)),    // 20 min gap before, 15 min after
    ], window: window, minMinutes: 30)
    expectEqual(blocks.count, 0)
}

await Harness.test("free blocks: an empty day is one block") {
    let window = DateInterval(start: at(8), end: at(18))
    expectEqual(DaySchedule.freeBlocks([], window: window, minMinutes: 30).map(\.minutes), [600])
}

await Harness.test("overlaps are detected between timed events only") {
    let overlaps = DaySchedule.overlaps([
        event("a", "Dentist", at(15), at(16)),
        event("b", "Review", at(15, 30), at(16, 30)),
        event("c", "Back-to-back", at(16, 30), at(17)),
        event("d", "Holiday", at(0), at(0, day: 5), allDay: true),
    ])
    expectEqual(overlaps.count, 1)
    expectEqual(overlaps.first?.firstTitle, "Dentist")
    expectEqual(overlaps.first?.start, at(15, 30))
    expectEqual(overlaps.first?.end, at(16))
}

// MARK: Reminders

await Harness.test("date-only reminders are overdue from the next day") {
    expect(!Reminder.isOverdue(due: at(0), hasTime: false, now: at(20), calendar: pacific), "due today")
    expect(Reminder.isOverdue(due: at(0, day: 3), hasTime: false, now: at(8), calendar: pacific), "due yesterday")
}

await Harness.test("timed reminders are overdue after their time") {
    expect(Reminder.isOverdue(due: at(9), hasTime: true, now: at(10), calendar: pacific))
    expect(!Reminder.isOverdue(due: at(15), hasTime: true, now: at(10), calendar: pacific))
}

// MARK: Config

await Harness.test("a partial config keeps defaults for missing keys") {
    let config = try Config.decode(Data(#"{"runAt": "06:45", "day": {"end": "17:00"}, "temperatureUnit": "celsius"}"#.utf8))
    expectEqual(config.runAt, "06:45")
    expectEqual(config.day.end, "17:00")
    expectEqual(config.day.start, "08:00")
    expectEqual(config.temperatureUnit, .celsius)
    expectEqual(config.summary.rainThreshold, 50)
}

await Harness.test("loadOrCreate writes a default config file") {
    let home = FileManager.default.temporaryDirectory.appending(path: "briefing-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let paths = AppPaths(home: home)
    expectEqual(try Config.loadOrCreate(paths: paths), Config())
    expect(FileManager.default.fileExists(atPath: paths.config.path), "config.json created")
}

await Harness.test("times parse as HH:mm and reject bad values") {
    expectEqual(try Config.time("07:30", on: at(12), calendar: pacific), at(7, 30))
    expect((try? Config.time("7.30", on: at(12), calendar: pacific)) == nil)
    expect((try? Config.time("25:00", on: at(12), calendar: pacific)) == nil)
}

// MARK: Weather

await Harness.test("Open-Meteo response parses into a forecast") {
    let http = FakeHTTP(["api.open-meteo.com": sampleForecast])
    let forecast = try await WeatherService(http: http, unit: .fahrenheit)
        .forecast(latitude: 47.6062, longitude: -122.3321, now: at(10, 30))
    expectEqual(forecast.currentTemperature, 48.2)
    expectEqual(forecast.currentDescription, "Overcast")
    expectEqual(forecast.high, 53.1)
    expectEqual(forecast.low, 44.0)
    expectEqual(forecast.maxPrecipitationProbability, 70)
    expectEqual(forecast.hourly.map(\.time), [at(10), at(15)])  // past hours dropped
    expectEqual(forecast.hourly.last?.description, "Rain")
    expectEqual(forecast.sunrise, at(7, 2))
}

await Harness.test("weather requests round coordinates to ~1 km") {
    let http = FakeHTTP(["api.open-meteo.com": sampleForecast])
    _ = try await WeatherService(http: http, unit: .celsius).forecast(latitude: 47.60621, longitude: -122.33207, now: at(9))
    let query = http.requested.first?.query() ?? ""
    expect(query.contains("latitude=47.61") && query.contains("longitude=-122.33"), query)
    expect(query.contains("temperature_unit=celsius"), query)
}

// MARK: Location fallbacks

await Harness.test("location: current location wins and is cached") {
    let paths = AppPaths(home: tempHome())
    let service = LocationService(config: .init(), paths: paths, http: FakeHTTP([:]), locator: FakeLocator(.success(seattle)))
    let (location, status) = await service.resolve()
    expectEqual(location?.source, .current)
    expect(status.ok)
    expect(FileManager.default.fileExists(atPath: paths.locationCache.path), "cache written")
}

await Harness.test("location: falls back to the cache, then IP, then the config city") {
    let paths = AppPaths(home: tempHome())
    let failing = FakeLocator(.failure(LocationError.timedOut))
    let now = at(12)

    // Fresh cache → cached.
    _ = await LocationService(config: .init(), paths: paths, http: FakeHTTP([:]), locator: FakeLocator(.success(seattle)), now: { now }).resolve()
    var (location, _) = await LocationService(config: .init(), paths: paths, http: FakeHTTP([:]), locator: failing, now: { now }).resolve()
    expectEqual(location?.source, .cached)

    // Stale cache → IP.
    let later = now.addingTimeInterval(LocationService.cacheMaxAge + 60)
    (location, _) = await LocationService(config: .init(), paths: paths, http: FakeHTTP(["ipapi.co": sampleIP]), locator: failing, now: { later }).resolve()
    expectEqual(location?.source, .ip)
    expectEqual(location?.name, "Bothell, WA")

    // IP fails → config city.
    var config = Config.Location()
    config.fallbackCity = "Seattle"
    (location, _) = await LocationService(config: config, paths: paths, http: FakeHTTP(["geocoding-api.open-meteo.com": sampleGeocoding]), locator: failing, now: { later }).resolve()
    expectEqual(location?.source, .configCity)
    expectEqual(location?.name, "Seattle, Washington")

    // Nothing works → failure status explains each step.
    let (none, status) = await LocationService(config: .init(), paths: AppPaths(home: tempHome()), http: FakeHTTP([:]), locator: failing).resolve()
    expect(none == nil)
    expect(!status.ok && status.detail?.contains("current:") == true && status.detail?.contains("ip:") == true, status.detail ?? "")
}

await Harness.test("location: fixed mode skips current location and IP") {
    var config = Config.Location()
    config.mode = .fixed
    config.fallbackCity = "Seattle"
    let http = FakeHTTP(["geocoding-api.open-meteo.com": sampleGeocoding, "ipapi.co": sampleIP])
    let (location, _) = await LocationService(config: config, paths: AppPaths(home: tempHome()), http: http, locator: FakeLocator(.success(seattle))).resolve()
    expectEqual(location?.source, .configCity)
    expectEqual(http.requested.map { $0.host() }, ["geocoding-api.open-meteo.com"])
}

// MARK: Collector

await Harness.test("collector combines sources and records failures") {
    let collector = DayCollector(
        config: Config(),
        providers: [FakeCalendars(events: [
            event("a", "Standup", at(9, 30), at(10)),
            event("b", "Standup", at(9, 30), at(10), home),
            event("h", "Holiday", at(0), at(0, day: 5), CalendarRef(title: "Holidays in United States", account: "iCloud"), allDay: true),
        ])],
        reminders: FakeReminders(),
        location: LocationService(config: .init(), paths: AppPaths(home: tempHome()), http: FakeHTTP([:]), locator: FakeLocator(.success(seattle))),
        weather: WeatherService(http: FakeHTTP([:]), unit: .celsius),
        calendar: pacific)
    let context = await collector.collect(now: at(10, 30))
    expectEqual(context.date, "2026-11-04")
    expectEqual(context.events.map(\.title), ["Standup"])  // deduped; holidays excluded by default
    expectEqual(context.location?.source, .current)
    expect(context.weather == nil)
    let failed = context.sources.filter { !$0.ok }.map(\.name)
    expectEqual(failed, ["weather"])
    expectEqual(context.sources.first?.detail, "1 event(s) today · 2 calendar(s) in Google, iCloud")
    // Free time starts now (10:30), not at the 08:00 window start.
    expectEqual(context.freeBlocks.first?.start, at(10, 30))
}

// MARK: Agent channel & launchd

await Harness.test("agent request IDs must be UUIDs") {
    expect(AgentChannel.isValid(id: UUID().uuidString))
    expect(!AgentChannel.isValid(id: "../../etc/passwd"))
}

await Harness.test("agent plist runs the installed app with KeepAlive") {
    let paths = AppPaths(home: URL(fileURLWithPath: "/Users/sample"))
    let plist = PlistBuilder.agentPlist(paths: paths)
    expectEqual(plist["Label"] as? String, "com.thakur90.briefing")
    expectEqual(plist["ProgramArguments"] as? [String], ["/Users/sample/Applications/Briefing.app/Contents/MacOS/briefing", "agent"])
    expectEqual(plist["KeepAlive"] as? Bool, true)
    let xml = String(decoding: try PlistBuilder.xml(plist), as: UTF8.self)
    expect(xml.contains("<key>RunAtLoad</key>"))
}

await Harness.test("launchctl print output is parsed") {
    let running = AgentStatus.parse(LaunchctlResult(status: 0, output: "gui/501/com.thakur90.briefing = {\n\tstate = running\n\tpid = 4242\n}"))
    expect(running.isRunning)
    expectEqual(running.pid, 4242)
    let missing = AgentStatus.parse(LaunchctlResult(status: 113, output: "Could not find service"))
    expect(!missing.loaded && !missing.isRunning)
}

await Harness.test("text renderer shows each section") {
    let context = DayContext(
        date: "2026-11-04", timeZone: "America/Los_Angeles", generatedAt: at(7),
        location: seattle, weather: nil,
        events: [event("a", "Standup", at(9, 30), at(10))],
        freeBlocks: [FreeBlock(start: at(10), end: at(12))], overlaps: [],
        reminders: [Reminder(id: "r", title: "Take vitamins", due: at(0), dueHasTime: false, isOverdue: false, list: "Personal")],
        sources: [.ok("calendars"), .failed("weather", "offline")])
    let text = DayContextTextRenderer.render(context, calendar: pacific)
    for needle in ["Seattle, WA", "Standup", "Free: ", "Take vitamins", "❌ weather: offline"] {
        expect(text.contains(needle), "missing \(needle)")
    }
}

await runSummaryTests()

Harness.finish()
