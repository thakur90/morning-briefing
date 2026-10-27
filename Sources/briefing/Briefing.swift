import ArgumentParser
import BriefingCore
import Foundation

@main
struct Briefing: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "briefing",
        abstract: "Your morning briefing: calendars, reminders and weather.",
        version: "0.1.0",
        subcommands: [Check.self, Agent.self]
    )
}

/// Milestone 1: verifies macOS grants Calendar, Reminders and Location access to this binary.
struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check permissions by reading today's events, reminders and location.")

    @Option(help: "Seconds to wait for a location fix.")
    var locationTimeout = 20

    @MainActor
    func run() async throws {
        print("Binary:    \(CommandLine.arguments[0])")
        print("Bundle ID: \(Bundle.main.bundleIdentifier ?? "none (Info.plist not embedded)")\n")

        let report = await PermissionCheck.run(locationTimeout: .seconds(locationTimeout))

        ReportPrinter.print(report)

        if !report.allGranted {
            print("\nGrant access in System Settings → Privacy & Security (Calendars, Reminders, Location Services).")
            throw ExitCode.failure
        }
    }
}
