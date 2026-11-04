import BriefingCore
import Foundation

enum ReportPrinter {
    static func render(_ report: PermissionReport) -> String {
        var lines: [String] = []
        if report.calendars.isGranted {
            lines.append("Calendars: ✅ granted. \(report.todaysEvents.count) event(s) today")
            for event in report.todaysEvents.prefix(5) {
                let span = event.isAllDay ? "all day    " : "\(time(event.start))–\(time(event.end))"
                lines.append("  \(span)  \(event.title)  (\(event.calendar) · \(event.account))")
            }
        } else {
            lines.append("Calendars: ❌ \(report.calendars.rawValue)")
        }

        if report.reminders.isGranted {
            lines.append("Reminders: ✅ granted. \(report.dueReminders.count) due today or overdue")
            for reminder in report.dueReminders.prefix(5) {
                let due = reminder.due.map { date($0) } ?? "no date"
                lines.append("  \(due)  \(reminder.title)  (\(reminder.list))")
            }
        } else {
            lines.append("Reminders: ❌ \(report.reminders.rawValue)")
        }

        switch report.location {
        case .success(let fix):
            lines.append(String(format: "Location:  ✅ granted. %.3f, %.3f (±%.0f m)",
                         fix.latitude, fix.longitude, fix.accuracyMeters))
        case .failure(let error):
            lines.append("Location:  ❌ \(error) (location services enabled: \(report.locationServicesEnabled))")
        }

        return lines.joined(separator: "\n")
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private static func date(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}
