import ArgumentParser
import BriefingCore
import Foundation

@main
struct Briefing: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "briefing",
        abstract: "Your morning briefing: calendars, reminders and weather.",
        version: "0.1.0",
        subcommands: [Check.self]
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

        if report.calendars.isGranted {
            print("Calendars: ✅ granted. \(report.todaysEvents.count) event(s) today")
            for event in report.todaysEvents.prefix(5) {
                let time = event.isAllDay ? "all day    " : "\(Self.time(event.start))–\(Self.time(event.end))"
                print("  \(time)  \(event.title)  (\(event.calendar) · \(event.account))")
            }
        } else {
            print("Calendars: ❌ \(report.calendars.rawValue)")
        }

        if report.reminders.isGranted {
            print("Reminders: ✅ granted. \(report.dueReminders.count) due today or overdue")
            for reminder in report.dueReminders.prefix(5) {
                let due = reminder.due.map { Self.date($0) } ?? "no date"
                print("  \(due)  \(reminder.title)  (\(reminder.list))")
            }
        } else {
            print("Reminders: ❌ \(report.reminders.rawValue)")
        }

        switch report.location {
        case .success(let fix):
            print(String(format: "Location:  ✅ granted. %.3f, %.3f (±%.0f m)",
                         fix.latitude, fix.longitude, fix.accuracyMeters))
        case .failure(let error):
            print("Location:  ❌ \(error) (location services enabled: \(report.locationServicesEnabled))")
        }

        if !report.allGranted {
            print("\nGrant access in System Settings → Privacy & Security (Calendars, Reminders, Location Services).")
            throw ExitCode.failure
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private static func date(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}
