import EventKit
import Foundation

/// Reads every calendar in the Calendar app: iCloud, Google, Exchange/Outlook,
/// CalDAV (design doc §4.1).
public struct EventKitProvider: CalendarProvider {
    public let id = "eventkit"
    private let eventKit: EventKitStore

    public init(eventKit: EventKitStore) {
        self.eventKit = eventKit
    }

    public func calendars() async throws -> [CalendarInfo] {
        try requireAccess()
        return eventKit.store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, ref: EventKitStore.ref($0), provider: id)
        }
    }

    public func events(in range: DateInterval) async throws -> [Event] {
        try requireAccess()
        let store = eventKit.store
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
        return store.events(matching: predicate).map { event in
            Event(
                // Recurring occurrences share an identifier; the start date makes each one unique.
                id: "\(event.calendarItemIdentifier)@\(Int(event.startDate.timeIntervalSince1970))",
                title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "(no title)",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                calendar: EventKitStore.ref(event.calendar)
            )
        }
    }

    private func requireAccess() throws {
        let state = AccessState(EKEventStore.authorizationStatus(for: .event))
        guard state.isGranted else { throw CalendarError.accessNotGranted(state) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
