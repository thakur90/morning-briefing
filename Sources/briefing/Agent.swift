import ArgumentParser
import BriefingCore
import Foundation

/// The background agent, started by launchd from inside Briefing.app (design doc Appendix A).
/// Milestone 1: runs the permission check and reports the result as a notification.
struct Agent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the background agent (started by launchd).")

    @Flag(help: "Exit after the permission check instead of staying running.")
    var once = false

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)  // launchd redirects stdout to a file; flush per line
        print("[\(Date.now.formatted(.iso8601))] agent started: \(Bundle.main.bundlePath)")

        let report = await PermissionCheck.run()
        ReportPrinter.print(report)

        guard NotificationAccess.isAvailable else {
            print("Notifications: ❌ not running inside Briefing.app")
            throw ExitCode.failure
        }
        let notifications = await NotificationAccess.requestAccess()
        print("Notifications: \(notifications.isGranted ? "✅ granted" : "❌ \(notifications.rawValue)")")

        if notifications.isGranted {
            try await NotificationAccess.post(
                title: report.allGranted ? "Briefing is set up" : "Briefing needs permissions",
                body: Self.summary(report))
        }

        if once { return }
        while true { try await Task.sleep(for: .seconds(3600)) }
    }

    private static func summary(_ report: PermissionReport) -> String {
        let location: String = switch report.location {
        case .success: "✅"
        case .failure: "❌"
        }
        return "Calendars \(report.calendars.isGranted ? "✅" : "❌") · Reminders \(report.reminders.isGranted ? "✅" : "❌") · Location \(location)"
    }
}
