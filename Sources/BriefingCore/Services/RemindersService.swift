import EventKit
import Foundation

public protocol ReminderSource: Sendable {
    func due(on day: Date, now: Date, calendar: Calendar) async throws -> [Reminder]
}

/// Incomplete reminders that are due today or overdue. EventKit doesn't
/// expose the Reminders app's "flagged" state, so priority is reported instead.
public struct RemindersService: ReminderSource {
    private let eventKit: EventKitStore
    private let lists: [String]

    public init(eventKit: EventKitStore, lists: [String]) {
        self.eventKit = eventKit
        self.lists = lists
    }

    public func due(on day: Date, now: Date = .now, calendar: Calendar = .current) async throws -> [Reminder] {
        let state = AccessState(EKEventStore.authorizationStatus(for: .reminder))
        guard state.isGranted else { throw CalendarError.accessNotGranted(state) }

        let store = eventKit.store
        let end = DaySchedule.dayInterval(for: day, calendar: calendar).end
        let calendars = lists.isEmpty ? nil : store.calendars(for: .reminder).filter { lists.contains($0.title) }
        if let calendars, calendars.isEmpty { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: calendars)

        let reminders: [Reminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { items in
                let mapped = (items ?? []).compactMap { item -> Reminder? in
                    guard let components = item.dueDateComponents, let due = calendar.date(from: components) else {
                        return nil
                    }
                    let hasTime = components.hour != nil
                    return Reminder(
                        id: item.calendarItemIdentifier,
                        title: item.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "(no title)",
                        due: due,
                        dueHasTime: hasTime,
                        isOverdue: Reminder.isOverdue(due: due, hasTime: hasTime, now: now, calendar: calendar),
                        priority: item.priority,
                        list: item.calendar.title)
                }
                continuation.resume(returning: mapped)
            }
        }
        return reminders.sorted { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }
    }
}
