import Foundation

/// Renders the briefing page (design doc §7.1, layout from docs/mockups/briefing.html).
/// One self-contained file: inline CSS, no JavaScript, no external requests.
public struct HTMLRenderer: Sendable {
    private let text: TimeText

    public init(calendar: Calendar = .current, locale: Locale = .current) {
        self.text = TimeText(calendar: calendar, locale: locale)
    }

    public func render(_ briefing: Briefing) -> String {
        let context = briefing.context
        var body = ""
        body += header(briefing)
        body += section("summary", "Your day", "<p>\(esc(briefing.sentences.joined(separator: " ")))</p>")
        if let weather = context.weather { body += weatherSection(weather, location: context.location) }
        body += scheduleSection(briefing)
        if !context.reminders.isEmpty { body += remindersSection(context.reminders) }
        body += footer(context)

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Briefing · \(esc(dateTitle(context.generatedAt)))</title>
        <style>
        \(Self.css)
        </style>
        </head>
        <body>
        <main>
        \(body)</main>
        </body>
        </html>

        """
    }

    // MARK: Sections

    private func header(_ briefing: Briefing) -> String {
        var stamp = "Generated \(text.time(briefing.generatedAt))"
        if let updated = briefing.updatedAt { stamp += " · Updated \(text.time(updated))" }
        return """
          <header>
            <div class="date">\(esc(dateTitle(briefing.context.generatedAt)))</div>
            <h1>\(esc(briefing.headline))</h1>
            <div class="updated">\(esc(stamp))</div>
          </header>

        """
    }

    private func weatherSection(_ weather: WeatherForecast, location: LocationInfo?) -> String {
        let place = location?.name.map { " · \($0)" } ?? ""
        let hours = weather.hourly.enumerated()
            .filter { $0.offset % 2 == 0 }
            .prefix(8)
            .map { _, hour in
                "<div><div class=\"h\">\(esc(text.hour(hour.time)))</div>\(esc(text.degrees(hour.temperature)))<div class=\"rain\">\(hour.precipitationProbability)%</div></div>"
            }
        var html = """
            <div class="now"><span class="temp">\(esc(text.degrees(weather.currentTemperature)))</span><span>\(esc(weather.currentDescription)) · High \(esc(text.degrees(weather.high))) · Low \(esc(text.degrees(weather.low)))</span></div>
        """
        if !hours.isEmpty {
            html += "\n    <div class=\"hours\" style=\"grid-template-columns: repeat(\(hours.count), 1fr)\">\n      \(hours.joined(separator: "\n      "))\n    </div>"
        }
        return section("weather", "Weather\(place)", html)
    }

    private func scheduleSection(_ briefing: Briefing) -> String {
        let context = briefing.context
        enum Row { case event(Event), free(FreeBlock) }
        let rows: [Row] = (context.events.map(Row.event) + context.freeBlocks.map(Row.free)).sorted { a, b in
            func key(_ row: Row) -> (Int, Date) {
                switch row {
                case .event(let e): (e.isAllDay ? 0 : 1, e.start)
                case .free(let f): (1, f.start)
                }
            }
            return key(a) < key(b)
        }
        guard !rows.isEmpty else { return section("schedule", "Schedule", "<p>No events today.</p>") }

        let html = rows.map { row -> String in
            switch row {
            case .event(let event):
                let time = event.isAllDay ? "All day" : text.range(event.start, event.end)
                var meta = "\(event.calendar.title) · \(event.calendar.account)"
                if let location = event.location { meta += " · \(location)" }
                if !event.alsoIn.isEmpty { meta += " · also in \(event.alsoIn.map(\.title).joined(separator: ", "))" }
                let dot = Self.cssColor(event.calendar.colorHex).map { "<span class=\"cal\" style=\"background:\($0)\"></span>" } ?? ""
                let notes = (briefing.notes[event.id] ?? []).map { note in
                    "<div class=\"note\(note.kind == .overlap || note.kind == .backToBack ? " warn" : "")\">\(esc(note.text))</div>"
                }.joined()
                return """
                    <div class="event">
                      <div class="time">\(esc(time))</div>
                      <div><div class="title">\(dot)\(esc(event.title))</div><div class="meta">\(esc(meta))</div>\(notes)</div>
                    </div>
                """
            case .free(let block):
                return """
                    <div class="event free">
                      <div class="time">\(esc(text.range(block.start, block.end)))</div>
                      <div><div class="title">Free · \(esc(text.duration(minutes: block.minutes)))</div></div>
                    </div>
                """
            }
        }
        return section("schedule", "Schedule", html.joined(separator: "\n"))
    }

    private func remindersSection(_ reminders: [Reminder]) -> String {
        let html = reminders.map { reminder -> String in
            let due: String
            if let date = reminder.due {
                due = reminder.isOverdue
                    ? "Overdue · due \(text.day(date))"
                    : reminder.dueHasTime ? "Today \(text.time(date))" : "Today"
            } else {
                due = "No date"
            }
            return """
                <div class="reminder"><div class="box"></div>
                  <div><div>\(esc(reminder.title))</div><div class="due\(reminder.isOverdue ? " overdue" : "")">\(esc(due)) · \(esc(reminder.list))</div></div></div>
            """
        }
        return section("reminders", "Reminders", html.joined(separator: "\n"))
    }

    private func footer(_ context: DayContext) -> String {
        let failed = context.sources.filter { !$0.ok }
        let status = failed.isEmpty
            ? "All sources OK"
            : "Unavailable: " + failed.map { "\($0.name)\($0.detail.map { " (\($0))" } ?? "")" }.joined(separator: ", ")
        let accounts = Array(Set(context.events.map(\.calendar.account))).sorted()
        let sources = (accounts.isEmpty ? ["Calendars"] : ["Calendars: \(accounts.joined(separator: ", "))"]) + ["Reminders", "Weather: Open-Meteo"]
        return """
          <footer>
            \(esc(sources.joined(separator: " · ")))<br>
            \(esc(status))
          </footer>

        """
    }

    private func section(_ cls: String, _ title: String, _ content: String) -> String {
        """
          <section class="\(cls)">
            <h2>\(esc(title))</h2>
        \(content)
          </section>

        """
    }

    private func dateTitle(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: text.locale, calendar: text.calendar, timeZone: text.calendar.timeZone)
            .weekday(.wide).month(.wide).day())
    }

    // MARK: Escaping

    /// Calendar text (titles, locations) comes from other people via invites, so everything is escaped.
    static func escape(_ string: String) -> String {
        var result = ""
        for character in string {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    private func esc(_ string: String) -> String { Self.escape(string) }

    /// Only "#RRGGBB" passes into the inline style.
    static func cssColor(_ hex: String?) -> String? {
        guard let hex, hex.count == 7, hex.first == "#",
              hex.dropFirst().allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    static let css = """
      :root {
        --bg: #f6f6f4; --card: #ffffff; --text: #1d1d1f; --muted: #6e6e73;
        --line: #e4e4e2; --accent: #2f6fde; --warn: #b4540a; --warn-bg: #fdf1e6;
        --ok: #2e7d4f; --ok-bg: #e8f4ec; --chip: #f0f0ee;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #161617; --card: #1f1f21; --text: #f2f2f2; --muted: #9a9aa0;
          --line: #333336; --accent: #6ea1ff; --warn: #f0a35e; --warn-bg: #3a2a1c;
          --ok: #7cc79a; --ok-bg: #1d3326; --chip: #2a2a2d;
        }
      }
      * { box-sizing: border-box; }
      body {
        margin: 0; background: var(--bg); color: var(--text);
        font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
      }
      main { max-width: 720px; margin: 0 auto; padding: 40px 20px 60px; }
      header .date { color: var(--muted); font-size: 13px; text-transform: uppercase; letter-spacing: .06em; }
      header h1 { font-size: 28px; line-height: 1.25; margin: 6px 0 8px; }
      header .updated { color: var(--muted); font-size: 13px; }
      section {
        background: var(--card); border: 1px solid var(--line); border-radius: 14px;
        padding: 18px 20px; margin-top: 18px;
      }
      h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .06em; color: var(--muted); margin: 0 0 12px; }
      .summary p { margin: 0; }

      .changes { border-color: var(--accent); }
      .changes ul { margin: 0; padding-left: 0; list-style: none; }
      .changes li { padding: 4px 0; }
      .tag { display: inline-block; font-size: 12px; font-weight: 600; padding: 1px 8px; border-radius: 999px; margin-right: 6px; background: var(--chip); }
      .tag.new { background: var(--ok-bg); color: var(--ok); }
      .tag.moved { background: var(--chip); color: var(--accent); }
      .tag.cancelled { background: var(--warn-bg); color: var(--warn); }

      .weather .now { display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap; }
      .weather .temp { font-size: 30px; font-weight: 600; }
      .weather .note { margin: 8px 0 14px; }
      .hours { display: grid; grid-template-columns: repeat(8, 1fr); border-top: 1px solid var(--line); padding-top: 10px; text-align: center; font-size: 13px; }
      .hours .h { color: var(--muted); }
      .hours .rain { color: var(--accent); }

      .event { display: grid; grid-template-columns: 110px 1fr; gap: 12px; padding: 10px 0; border-top: 1px solid var(--line); }
      .event:first-of-type { border-top: 0; padding-top: 0; }
      .event .time { color: var(--muted); font-variant-numeric: tabular-nums; }
      .event .title { font-weight: 600; }
      .event .meta { color: var(--muted); font-size: 13px; }
      .event .note { font-size: 13px; margin-top: 4px; }
      .event .note.warn { color: var(--warn); }
      .event.free .title { font-weight: 500; color: var(--ok); }
      .event.cancelled .title { text-decoration: line-through; color: var(--muted); font-weight: 500; }
      .cal { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; vertical-align: 1px; }

      .reminder { display: flex; gap: 10px; padding: 8px 0; border-top: 1px solid var(--line); }
      .reminder:first-of-type { border-top: 0; padding-top: 0; }
      .box { width: 16px; height: 16px; border: 1.5px solid var(--muted); border-radius: 50%; flex: none; margin-top: 3px; }
      .reminder .due { color: var(--muted); font-size: 13px; }
      .reminder .due.overdue { color: var(--warn); font-weight: 600; }

      footer { color: var(--muted); font-size: 12px; margin-top: 22px; text-align: center; }
    """
}
