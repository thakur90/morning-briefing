import Foundation

public struct CalendarRef: Codable, Sendable, Hashable {
    public var title: String
    public var account: String
    /// sRGB hex, e.g. "#2F6FDE".
    public var colorHex: String?

    public init(title: String, account: String, colorHex: String? = nil) {
        self.title = title
        self.account = account
        self.colorHex = colorHex
    }
}

public struct CalendarInfo: Codable, Sendable, Hashable {
    public var id: String
    public var ref: CalendarRef
    public var provider: String

    public init(id: String, ref: CalendarRef, provider: String) {
        self.id = id
        self.ref = ref
        self.provider = provider
    }
}

public struct Event: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var calendar: CalendarRef
    /// Other calendars the same event was found in (after de-duplication).
    public var alsoIn: [CalendarRef]
    /// Stable across edits (EventKit's calendarItemIdentifier). Used to match events between snapshots.
    public var seriesID: String?
    /// For recurring events: the original date of this occurrence, which also stays fixed when it's moved.
    public var occurrence: Date?

    /// Identifies "the same event" before and after an edit (live updates, §4.3).
    public var matchKey: String {
        (seriesID ?? id) + (occurrence.map { "@\(Int($0.timeIntervalSince1970))" } ?? "")
    }

    public init(
        id: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
        location: String? = nil, calendar: CalendarRef, alsoIn: [CalendarRef] = [],
        seriesID: String? = nil, occurrence: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.calendar = calendar
        self.alsoIn = alsoIn
        self.seriesID = seriesID
        self.occurrence = occurrence
    }
}

public struct FreeBlock: Codable, Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public struct Overlap: Codable, Sendable, Equatable {
    public var firstID: String
    public var secondID: String
    public var firstTitle: String
    public var secondTitle: String
    public var start: Date
    public var end: Date
}
