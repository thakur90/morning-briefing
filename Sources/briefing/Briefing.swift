import ArgumentParser
import BriefingCore
import Foundation

@main
struct Briefing: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "briefing",
        abstract: "Your morning briefing: calendars, reminders and weather.",
        version: "0.2.0",
        subcommands: [Today.self, Status.self, Install.self, Uninstall.self, Check.self, Agent.self]
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
        abstract: "Show today's briefing data (collected by the background agent).")

    @Flag(help: "Collect and print today's data without summarizing (the only mode until milestone 3).")
    var dryRun = false

    @Flag(help: "Print the raw DayContext JSON.")
    var json = false

    func run() async throws {
        guard dryRun else {
            throw ValidationError("AI summaries arrive in milestone 3. For now, use: briefing today --dry-run")
        }
        try requireRunningAgent()
        let response = try await AgentChannel.send(.todayDryRun)
        guard response.ok, let context = response.context else {
            throw ValidationError(response.error ?? "The agent returned no data.")
        }
        if json {
            print(String(decoding: try JSONEncoder.briefing.encode(context), as: UTF8.self))
        } else {
            print(DayContextTextRenderer.render(context))
        }
    }
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
