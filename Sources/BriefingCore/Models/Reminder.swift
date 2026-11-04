import Foundation

public struct Reminder: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var due: Date?
    /// False for date-only reminders ("due Tuesday"), true for "due Tuesday 3 PM".
    public var dueHasTime: Bool
    public var isOverdue: Bool
    /// EventKit priority: 0 = none, 1 = high … 9 = low.
    public var priority: Int
    public var list: String

    public init(
        id: String, title: String, due: Date?, dueHasTime: Bool, isOverdue: Bool,
        priority: Int = 0, list: String
    ) {
        self.id = id
        self.title = title
        self.due = due
        self.dueHasTime = dueHasTime
        self.isOverdue = isOverdue
        self.priority = priority
        self.list = list
    }

    /// Date-only reminders are overdue from the next day; timed ones from their due time.
    public static func isOverdue(due: Date, hasTime: Bool, now: Date, calendar: Calendar) -> Bool {
        hasTime ? due < now : due < calendar.startOfDay(for: now)
    }
}
