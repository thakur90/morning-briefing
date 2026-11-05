import BriefingCore
import Foundation

func tracked(_ series: String, _ title: String, _ start: Date, _ end: Date, _ calendar: CalendarRef = work,
             location: String? = nil, occurrence: Date? = nil) -> Event {
    Event(id: "\(series)@\(Int(start.timeIntervalSince1970))", title: title, start: start, end: end,
          location: location, calendar: calendar, seriesID: series, occurrence: occurrence)
}

@MainActor
func runLiveUpdateTests() async {
    let now = at(12)
    let wording = ChangeText(calendar: pacific, locale: english)

    await Harness.test("diff: added, cancelled, moved, renamed, updated") {
        let old = [
            tracked("standup", "Standup", at(13), at(13, 30)),
            tracked("lunch", "Team lunch", at(12, 30), at(13, 30)),
            tracked("review", "Review", at(15), at(16)),
            tracked("sync", "Sync", at(16), at(16, 30)),
        ]
        let new = [
            tracked("standup", "Standup", at(13), at(13, 30), location: "Room 4B"),  // updated
            tracked("review", "Design review", at(15), at(16)),                      // renamed
            tracked("sync", "Sync", at(16, 30), at(17)),                             // moved (new id!)
            tracked("dentist", "Dentist", at(15), at(16), home),                     // added
        ]
        let changes = EventDiff.diff(old: old, new: new, now: now)
        expectEqual(Set(changes.map { "\($0.kind.rawValue):\($0.title)" }),
                    ["cancelled:Team lunch", "updated:Standup", "renamed:Design review", "moved:Sync", "added:Dentist"])
    }

    await Harness.test("diff: identical snapshots and past-only changes produce nothing") {
        let events = [tracked("a", "Standup", at(9), at(9, 30)), tracked("b", "Review", at(15), at(16))]
        expect(EventDiff.diff(old: events, new: events, now: now).isEmpty)
        // Deleting a meeting that already ended isn't worth a notification.
        expect(EventDiff.diff(old: events, new: [events[1]], now: now).isEmpty)
    }

    await Harness.test("diff: a moved recurring occurrence is matched by its original date") {
        let original = at(10, day: 4)
        let old = [tracked("weekly", "1:1", at(14), at(14, 30), occurrence: original)]
        let new = [tracked("weekly", "1:1", at(16, 30), at(17), occurrence: original)]
        expectEqual(EventDiff.diff(old: old, new: new, now: now).map(\.kind), [.moved])
    }

    await Harness.test("merge keeps when a change was first noticed") {
        let first = EventDiff.diff(old: [], new: [tracked("d", "Dentist", at(15), at(16))], now: at(10, 52))
        let again = EventDiff.diff(old: [], new: [tracked("d", "Dentist", at(15), at(16))], now: at(14))
        expectEqual(EventDiff.merge(again, keepingTimesFrom: first).first?.detectedAt, at(10, 52))
    }

    await Harness.test("change notification lines") {
        let old = [tracked("p", "1:1 with Priya", at(13), at(13, 30)), tracked("l", "Team lunch", at(12, 30), at(13, 30))]
        let new = [tracked("p", "1:1 with Priya", at(16, 30), at(17)), tracked("d", "Dentist", at(15), at(16), home)]
        let body = plain(wording.notificationBody(EventDiff.diff(old: old, new: new, now: now)))
        expectEqual(body, "Cancelled: Team lunch at 12:30 PM\nNew: Dentist at 3:00 PM (Home)\nMoved: 1:1 with Priya → 4:30 PM")
    }

    await Harness.test("change notification groups many changes") {
        let new = (0..<6).map { tracked("e\($0)", "Event \($0)", at(13 + $0), at(13 + $0, 30)) }
        let body = wording.notificationBody(EventDiff.diff(old: [], new: new, now: now))
        expectEqual(body.split(separator: "\n").count, 5)
        expect(body.hasSuffix("…and 2 more"), body)
    }

    await Harness.test("event notes for changes") {
        let moved = EventDiff.diff(old: [tracked("p", "1:1", at(13), at(13, 30))], new: [tracked("p", "1:1", at(16, 30), at(17))], now: now)
        expectEqual(moved.first.flatMap(wording.note).map { plain($0.text) }, "Moved from 1:00 PM")
        let added = EventDiff.diff(old: [], new: [tracked("d", "Dentist", at(15), at(16))], now: at(14, 13))
        expectEqual(added.first.flatMap(wording.note).map { plain($0.text) }, "Added at 2:13 PM")
        let renamed = EventDiff.diff(old: [tracked("r", "Review", at(15), at(16))], new: [tracked("r", "Design review", at(15), at(16))], now: now)
        expectEqual(renamed.first.flatMap(wording.note)?.text, "Renamed from “Review”")
    }

    await Harness.test("page shows changes and cancelled events (escaped)") {
        let lunch = tracked("l", "<b>Team lunch</b>", at(12, 30), at(13, 30))
        let dentist = tracked("d", "Dentist", at(15), at(16), home)
        var briefing = summary.build(context(events: [dentist], now: now))
        briefing.changes = EventDiff.diff(old: [lunch], new: [dentist], now: at(10, 52))
        let html = HTMLRenderer(calendar: pacific, locale: english).render(briefing)
        expect(html.contains("id=\"changes\"") && html.contains("Changes since this morning"))
        expect(html.contains("<span class=\"tag new\">New</span>Dentist"), "new tag")
        expect(html.contains("<div class=\"event cancelled\">"), "cancelled row")
        expect(html.contains("&lt;b&gt;Team lunch&lt;/b&gt;") && !html.contains("<b>Team"), "escaped")
        expect(plain(html).contains("Cancelled at 10:52 AM"))
        let markdown = MarkdownRenderer(calendar: pacific, locale: english).render(briefing)
        expect(markdown.contains("## Changes since this morning"))
        let quiet = HTMLRenderer(calendar: pacific, locale: english).render(summary.build(context(events: [dentist], now: now)))
        expect(!quiet.contains("id=\"changes\""), "no section without changes")
    }

    await Harness.test("collector reuses recent weather on refresh") {
        let calls = FakeHTTP(["api.open-meteo.com": sampleForecast])
        let collector = DayCollector(
            config: Config(), providers: [FakeCalendars(events: [])], reminders: FakeReminders(),
            location: LocationService(config: .init(), paths: AppPaths(home: tempHome()), http: calls, locator: FakeLocator(.success(seattle))),
            weather: WeatherService(http: calls, unit: .fahrenheit), calendar: pacific)
        let morning = await collector.collect(now: at(10))
        expectEqual(calls.requested.count, 1)
        _ = await collector.collect(now: at(10, 30), reusingWeatherFrom: morning)
        expectEqual(calls.requested.count, 1)  // reused
        _ = await collector.collect(now: at(11, 30), reusingWeatherFrom: morning)
        expectEqual(calls.requested.count, 2)  // more than an hour old: fetched again
    }

    await Harness.test("briefings saved before live updates still load") {
        let dir = tempHome()
        defer { try? FileManager.default.removeItem(at: dir) }
        var briefing = summary.build(context(events: [tracked("a", "Standup", at(13), at(13, 30))], now: now))
        briefing.baseline = nil
        briefing.changes = nil
        try OutputWriter(directory: dir).write(briefing, html: "", markdown: "")
        let loaded = OutputWriter(directory: dir).loadBriefing(for: "2026-11-04")
        expectEqual(loaded?.headline, briefing.headline)
        expect(loaded?.changes == nil)
    }
}
