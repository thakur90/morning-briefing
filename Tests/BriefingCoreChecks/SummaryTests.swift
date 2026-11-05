import BriefingCore
import Foundation

/// Formatting uses narrow/thin spaces ("9:30 AM", "12:00 – 3:00 PM"); compare with plain spaces.
func plain(_ string: String) -> String {
    string.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{2009}", with: " ")
}

let english = Locale(identifier: "en_US")
let summary = SummaryBuilder(config: Config.Summary(), calendar: pacific, locale: english)

func context(
    events: [Event] = [], reminders: [Reminder] = [], weather: WeatherForecast? = nil, now: Date = at(7)
) -> DayContext {
    let window = DateInterval(start: max(at(8), now), end: at(18))
    let deduped = DaySchedule.dedupe(events)
    return DayContext(
        date: "2026-11-04", timeZone: "America/Los_Angeles", generatedAt: now, location: seattle, weather: weather,
        events: deduped, freeBlocks: DaySchedule.freeBlocks(deduped, window: window, minMinutes: 30),
        overlaps: DaySchedule.overlaps(deduped), reminders: reminders, sources: [.ok("calendars")])
}

func forecast(rainAt hours: [Int: Int] = [:], high: Double = 55, low: Double = 40) -> WeatherForecast {
    WeatherForecast(
        unit: .fahrenheit, currentTemperature: 48, currentDescription: "Overcast", high: high, low: low,
        maxPrecipitationProbability: hours.values.max() ?? 0, sunrise: nil, sunset: nil,
        hourly: (8...20).map { HourlyWeather(time: at($0), temperature: 50, precipitationProbability: hours[$0] ?? 0, description: "Overcast") })
}

func reminder(_ title: String, due: Date, overdue: Bool) -> Reminder {
    Reminder(id: title, title: title, due: due, dueHasTime: false, isOverdue: overdue, list: "Personal")
}

@MainActor
func runSummaryTests() async {
    await Harness.test("headline: clear day") {
        expectEqual(summary.build(context()).headline, "Clear day: no meetings")
    }

    await Harness.test("headline: conflict wins over busy morning") {
        let briefing = summary.build(context(events: [
            event("a", "Standup", at(9), at(9, 30)), event("b", "Review", at(9, 15), at(10)), event("c", "Sync", at(11), at(11, 30)),
        ]))
        expectEqual(plain(briefing.headline), "3 meetings today, 1 conflict at 9:15 AM")
    }

    await Harness.test("headline: busy morning") {
        let briefing = summary.build(context(events: [
            event("a", "Standup", at(9), at(9, 30)), event("b", "Review", at(10), at(11)), event("c", "Sync", at(11), at(11, 45)),
        ]))
        expectEqual(briefing.headline, "Busy morning: 3 meetings before noon")
    }

    await Harness.test("headline: packed day") {
        let briefing = summary.build(context(events: (0..<5).map { event("e\($0)", "M\($0)", at(13 + $0), at(13 + $0, 30)) }))
        expectEqual(plain(briefing.headline), "Packed day: 5 meetings, 1:00 – 5:30 PM")
    }

    await Harness.test("headline: default, with rain suffix") {
        let briefing = summary.build(context(events: [event("a", "Standup", at(9, 30), at(10))], weather: forecast(rainAt: [16: 70])))
        expectEqual(plain(briefing.headline), "1 meeting today, first at 9:30 AM · rain from 4 PM")
    }

    await Harness.test("headline: freezing and hot suffixes") {
        expect(summary.build(context(weather: forecast(low: 30))).headline.hasSuffix("· freezing tonight"))
        expect(summary.build(context(weather: forecast(high: 90))).headline.hasSuffix("· hot afternoon"))
        expectEqual(summary.build(context(weather: forecast())).headline, "Clear day: no meetings")
    }

    await Harness.test("paragraph: shape, back-to-back, free block, reminders, weather") {
        let briefing = summary.build(context(
            events: [
                event("a", "Standup", at(9, 30), at(10)), event("b", "Review", at(10), at(11)),
                event("c", "Lunch", at(15), at(16)),
                event("h", "Offsite", at(0), at(0, day: 5), allDay: true),
            ],
            reminders: [reminder("Passport", due: at(0, day: 1), overdue: true), reminder("Vitamins", due: at(0), overdue: false)],
            weather: forecast(rainAt: [17: 60])))
        expectEqual(briefing.sentences.map(plain), [
            "You have 3 meetings between 9:30 AM and 4:00 PM.",
            "9:30 – 11:00 AM is back-to-back (2 meetings).",
            "Your longest free block is 11:00 AM – 3:00 PM (4 h).",
            "All day: Offsite.",
            "1 reminder is overdue (oldest from Nov 1); 1 is due today.",
            "Rain likely from 5 PM (60%), so take an umbrella.",
        ])
    }

    await Harness.test("paragraph: conflicts and a quiet day") {
        let busy = summary.build(context(events: [event("a", "Dentist", at(15), at(16)), event("b", "Review", at(15, 30), at(16, 30))]))
        expect(busy.sentences.map(plain).contains("Dentist overlaps Review, 3:30 – 4:00 PM."), "\(busy.sentences)")
        expectEqual(summary.build(context()).sentences, ["No meetings today."])
    }

    await Harness.test("reminder sentence wording") {
        expectEqual(summary.build(context(reminders: [reminder("A", due: at(0), overdue: false), reminder("B", due: at(0), overdue: false)])).sentences.last,
                    "2 reminders are due today.")
        expectEqual(summary.build(context(reminders: [reminder("A", due: at(0, day: 2), overdue: true), reminder("B", due: at(0, day: 3), overdue: true)])).sentences.last,
                    "2 reminders are overdue (oldest from Nov 2).")
    }

    await Harness.test("event notes: first, back-to-back, overlap") {
        let briefing = summary.build(context(events: [
            event("a", "Standup", at(9, 30), at(10)), event("b", "Review", at(10, 2), at(11)),
            event("c", "Dentist", at(15), at(16)), event("d", "Call", at(15, 30), at(16)),
        ]))
        expectEqual(briefing.notes["a"]?.map(\.kind), [.first])
        expectEqual(briefing.notes["b"]?.map(\.text), ["Back-to-back with Standup"])
        expectEqual(briefing.notes["c"]?.map(\.kind), [.overlap])
        expectEqual(briefing.notes["d"]?.map(\.kind), [.overlap])
    }

    await Harness.test("notification body is short and useful") {
        let briefing = summary.build(context(
            events: [event("a", "Standup", at(9, 30), at(10)), event("b", "Lunch", at(15), at(16))],
            reminders: [reminder("Passport", due: at(0, day: 1), overdue: true)],
            weather: forecast(rainAt: [16: 70])))
        expectEqual(plain(briefing.notificationBody),
                    "First up: Standup 9:30 AM. Free 10:00 AM – 3:00 PM. 1 reminder (1 overdue). Rain from 4 PM, take an umbrella.")
        let long = summary.build(context(events: [event("a", String(repeating: "Very long title ", count: 20), at(9), at(10))]))
        expect(long.notificationBody.count <= SummaryBuilder.notificationLimit && long.notificationBody.hasSuffix("…"))
    }

    await Harness.test("HTML escapes calendar text and rejects bad colours") {
        var evil = event("x", "<script>alert(1)</script> & \"quotes\"", at(9), at(10))
        evil.calendar.colorHex = "red;background:url(x)"
        evil.location = "<img src=x>"
        let html = HTMLRenderer(calendar: pacific, locale: english).render(summary.build(context(events: [evil])))
        expect(!html.contains("<script>") && !html.contains("<img"), "unescaped markup")
        expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;quotes&quot;"))
        expect(!html.contains("url(x)"), "colour injected into style")
        expect(!html.contains("<script") && !html.contains("http"), "page must not load anything")
    }

    await Harness.test("HTML page has the approved sections") {
        let briefing = summary.build(context(
            events: [event("a", "Standup", at(9, 30), at(10))],
            reminders: [reminder("Vitamins", due: at(0), overdue: false)], weather: forecast()))
        let html = HTMLRenderer(calendar: pacific, locale: english).render(briefing)
        for needle in ["<h1>1 meeting today, first at", "<h2>Your day</h2>", "<h2>Weather · Seattle, WA</h2>",
                       "<h2>Schedule</h2>", "Free · ", "<h2>Reminders</h2>", "All sources OK", "prefers-color-scheme: dark"] {
            expect(html.contains(needle), "missing \(needle)")
        }
    }

    await Harness.test("Markdown copy lists events and reminders") {
        let briefing = summary.build(context(events: [event("a", "Standup", at(9, 30), at(10))], reminders: [reminder("Vitamins", due: at(0), overdue: false)]))
        let markdown = plain(MarkdownRenderer(calendar: pacific, locale: english).render(briefing))
        expect(markdown.hasPrefix("# 1 meeting today"))
        expect(markdown.contains("- **9:30 – 10:00 AM** Standup"), markdown)
        expect(markdown.contains("- [ ] Vitamins (today · Personal)"), markdown)
    }

    await Harness.test("output writer saves html, md and json") {
        let dir = tempHome()
        defer { try? FileManager.default.removeItem(at: dir) }
        let briefing = summary.build(context())
        let files = try OutputWriter(directory: dir).write(briefing, html: "<html></html>", markdown: "# hi")
        expectEqual(files.html.lastPathComponent, "2026-11-04.html")
        expectEqual(try String(contentsOf: files.markdown, encoding: .utf8), "# hi")
        let decoded = try JSONDecoder.briefing.decode(Briefing.self, from: Data(contentsOf: files.context))
        expectEqual(decoded, briefing)
        expectEqual(OutputWriter(directory: dir).existingPage(for: "2026-11-04"), files.html)
        expect(OutputWriter(directory: dir).existingPage(for: "2026-11-05") == nil)
    }
}
