import EventKit
import Foundation

public struct CalendarEventSummary: Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendar: String
    public let account: String
}

public struct ReminderSummary: Sendable {
    public let title: String
    public let due: Date?
    public let list: String
}

/// Reads calendars and reminders through EventKit, which covers every account
/// added in System Settings → Internet Accounts (iCloud, Google, Exchange, …).
public final class EventKitAccess: @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public static func status(for type: EKEntityType) -> AccessState {
        AccessState(EKEventStore.authorizationStatus(for: type))
    }

    /// Prompts for full access if needed and returns the resulting state.
    public func requestAccess(to type: EKEntityType) async -> AccessState {
        if Self.status(for: type) == .notDetermined {
            switch type {
            case .event: _ = try? await store.requestFullAccessToEvents()
            case .reminder: _ = try? await store.requestFullAccessToReminders()
            @unknown default: break
            }
        }
        return Self.status(for: type)
    }

    public func events(on day: Date, calendar: Calendar = .current) -> [CalendarEventSummary] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map {
                CalendarEventSummary(
                    title: $0.title ?? "(no title)",
                    start: $0.startDate,
                    end: $0.endDate,
                    isAllDay: $0.isAllDay,
                    calendar: $0.calendar.title,
                    account: $0.calendar.source.title
                )
            }
    }

    /// Incomplete reminders due before the end of `day`, including overdue ones.
    public func dueReminders(through day: Date, calendar: Calendar = .current) async -> [ReminderSummary] {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))!
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: end, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let summaries = (reminders ?? []).map {
                    ReminderSummary(
                        title: $0.title ?? "(no title)",
                        due: $0.dueDateComponents.flatMap { calendar.date(from: $0) },
                        list: $0.calendar.title
                    )
                }
                continuation.resume(returning: summaries.sorted {
                    ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture)
                })
            }
        }
    }
}
