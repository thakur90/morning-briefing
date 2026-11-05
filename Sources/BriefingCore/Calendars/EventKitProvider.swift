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
                calendar: EventKitStore.ref(event.calendar),
                seriesID: event.calendarItemIdentifier,
                occurrence: event.hasRecurrenceRules ? event.occurrenceDate : nil
            )
        }
    }

    /// EventKit posts `EKEventStoreChanged` for any change to any calendar or reminder
    /// list, including changes that arrive by sync from other devices.
    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let token = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: eventKit.store, queue: nil
            ) { _ in continuation.yield() }
            let box = ObserverToken(token)
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(box.token) }
        }
    }

    private func requireAccess() throws {
        let state = AccessState(EKEventStore.authorizationStatus(for: .event))
        guard state.isGranted else { throw CalendarError.accessNotGranted(state) }
    }
}

/// NotificationCenter tokens are thread-safe to remove, but aren't marked Sendable.
private final class ObserverToken: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
