import BriefingCore
import Foundation

enum ReportPrinter {
    static func print(_ report: PermissionReport) {
        if report.calendars.isGranted {
            Swift.print("Calendars: ✅ granted. \(report.todaysEvents.count) event(s) today")
            for event in report.todaysEvents.prefix(5) {
                let span = event.isAllDay ? "all day    " : "\(time(event.start))–\(time(event.end))"
                Swift.print("  \(span)  \(event.title)  (\(event.calendar) · \(event.account))")
            }
        } else {
            Swift.print("Calendars: ❌ \(report.calendars.rawValue)")
        }

        if report.reminders.isGranted {
            Swift.print("Reminders: ✅ granted. \(report.dueReminders.count) due today or overdue")
            for reminder in report.dueReminders.prefix(5) {
                let due = reminder.due.map { date($0) } ?? "no date"
                Swift.print("  \(due)  \(reminder.title)  (\(reminder.list))")
            }
        } else {
            Swift.print("Reminders: ❌ \(report.reminders.rawValue)")
        }

        switch report.location {
        case .success(let fix):
            Swift.print(String(format: "Location:  ✅ granted. %.3f, %.3f (±%.0f m)",
                         fix.latitude, fix.longitude, fix.accuracyMeters))
        case .failure(let error):
            Swift.print("Location:  ❌ \(error) (location services enabled: \(report.locationServicesEnabled))")
        }

    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private static func date(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}
