import ArgumentParser
import BriefingCore
import Foundation

struct Briefing: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "briefing",
        abstract: "Your morning briefing: calendars, reminders and weather.",
        version: "0.4.0",
        subcommands: [Today.self, Open.self, Status.self, Install.self, Uninstall.self, Check.self, Agent.self]
    )
}

/// Fails with a helpful message if the background agent isn't running.
func requireRunningAgent() throws {
    let status = LaunchAgentInstaller().status()
    guard status.isRunning else {
        let hint = status.loaded
            ? "The agent is loaded but not running. Check ~/Library/Logs/Briefing/launchd.log."
            : "The agent isn't installed. Run: scripts/build-app.sh --install"
        throw ValidationError("The background agent isn't running. \(hint)")
    }
}

struct Today: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate today's briefing now (via the background agent).")

    @Flag(help: "Only collect and print today's data; don't write the briefing or notify.")
    var dryRun = false

    @Flag(help: "With --dry-run: print the raw DayContext JSON.")
    var json = false

    @Flag(help: "Don't post a notification.")
    var noNotify = false

    @Flag(help: "Open the briefing page when it's ready.")
    var open = false

    func run() async throws {
        try requireRunningAgent()
        if dryRun {
            let response = try await AgentChannel.send(.todayDryRun)
            guard response.ok, let context = response.context else {
                throw ValidationError(response.error ?? "The agent returned no data.")
            }
            print(json
                ? String(decoding: try JSONEncoder.briefing.encode(context), as: UTF8.self)
                : DayContextTextRenderer.render(context))
            return
        }
        let response = try await AgentChannel.send(.today, notify: !noNotify)
        guard response.ok, let files = response.files else {
            throw ValidationError(response.error ?? "The agent didn't write a briefing.")
        }
        print(response.output ?? "")
        print("Page:     \(files.html.path)")
        print("Markdown: \(files.markdown.path)")
        if open { openFile(files.html) }
    }
}

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open today's briefing page.")

    func run() throws {
        guard let page = todaysPage() else {
            throw ValidationError("No briefing for today yet. Generate one with: briefing today")
        }
        openFile(page)
    }
}

func todaysPage(paths: AppPaths = AppPaths()) -> URL? {
    guard let config = try? Config.loadOrCreate(paths: paths) else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return OutputWriter(config: config, paths: paths).existingPage(for: formatter.string(from: .now))
}

func openFile(_ url: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.path]
    try? process.run()
    process.waitUntilExit()
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show whether the background agent is running.")

    func run() throws {
        let paths = AppPaths()
        let status = LaunchAgentInstaller(paths: paths).status()
        let agent = status.isRunning
            ? "running (pid \(status.pid!))"
            : status.loaded ? "loaded but not running (\(status.state ?? "unknown"))" : "not installed"
        print("Agent:        \(agent)")

        let app = FileManager.default.fileExists(atPath: paths.installedApp.path) ? paths.installedApp.path : "not installed"
        print("App:          \(app)")

        if let state = AgentState.load(paths: paths) {
            print("Started:      \(state.startedAt.formatted(date: .abbreviated, time: .shortened)) (v\(state.version), pid \(state.pid))")
            let permissions = ["calendars", "reminders", "location", "notifications"]
                .map { "\($0) \(state.permissions[$0] == AccessState.granted.rawValue ? "✅" : "❌ \(state.permissions[$0] ?? "unknown")")" }
            print("Permissions:  \(permissions.joined(separator: "  "))")
        }
        if let config = try? Config.loadOrCreate(paths: paths) {
            let schedule = ScheduleGuard(config: config, calendar: .autoupdatingCurrent)
            let days = config.weekdaysOnly ? "Mon–Fri" : "every day"
            var line = "\(config.runAt) \(days)"
            let lastMorningDay = AgentState.load(paths: paths)?.lastMorningDay
            if (try? schedule.decide(now: .now, lastMorningDay: lastMorningDay)) == .run {
                line += " · today's run is due now"
            } else if let next = try? schedule.nextRun(after: .now) {
                line += " · next: \(next.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))"
            }
            print("Schedule:     \(line)")
        }
        if let runs = AgentState.load(paths: paths)?.lastRuns, !runs.isEmpty {
            for kind in [RunKind.morning, .manual, .refresh] {
                guard let run = runs[kind.rawValue] else { continue }
                let failed = run.failedSources.isEmpty ? "" : " (unavailable: \(run.failedSources.joined(separator: ", ")))"
                let label = "Last \(kind.rawValue):".padding(toLength: 14, withPad: " ", startingAt: 0)
                print("\(label)\(run.finishedAt.formatted(date: .abbreviated, time: .shortened)) · \(run.outcome.rawValue)\(failed)\(run.error.map { " · \($0)" } ?? "")")
            }
        }
        print("Config:       \(paths.config.path)")
        print("Logs:         \(paths.logsDir.path)")
    }
}

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the background agent at login (needs ~/Applications/Briefing.app).")

    func run() throws {
        let paths = AppPaths()
        try LaunchAgentInstaller(paths: paths).install()
        print("Installed and started \(AgentIdentity.label).")
        print("CLI linked at \(paths.cliSymlink.path).")
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        if !path.split(separator: ":").contains(Substring(paths.cliSymlink.deletingLastPathComponent().path)) {
            print("Add ~/.local/bin to your PATH to run `briefing` from anywhere.")
        }
    }
}

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop and remove the background agent and app (keeps config, briefings and logs).")

    func run() throws {
        try LaunchAgentInstaller().uninstall()
        print("Removed the agent, the CLI link and ~/Applications/Briefing.app.")
    }
}

/// Verifies Calendar, Reminders and Location access (milestone 1).
struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check permissions by reading today's events, reminders and location.")

    @Flag(help: "Run the check in this process instead of asking the agent (location won't work from Terminal).")
    var local = false

    @MainActor
    func run() async throws {
        if !local {
            try requireRunningAgent()
            let response = try await AgentChannel.send(.check)
            print(response.output ?? response.error ?? "No output.")
            if !response.ok { throw ExitCode.failure }
            return
        }
        let report = await PermissionCheck.run(locationTimeout: .seconds(20))
        print(ReportPrinter.render(report))
        if !report.allGranted {
            print("\nGrant access in System Settings → Privacy & Security (Calendars, Reminders, Location Services).")
            throw ExitCode.failure
        }
    }
}
