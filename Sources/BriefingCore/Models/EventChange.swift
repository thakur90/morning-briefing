import Foundation

/// A difference between two snapshots of today's events (design doc §4.3).
public struct EventChange: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case added, moved, renamed, updated, cancelled
    }

    public var kind: Kind
    public var key: String
    public var before: Event?
    public var after: Event?
    /// When the change was first noticed.
    public var detectedAt: Date

    public init(kind: Kind, key: String, before: Event?, after: Event?, detectedAt: Date) {
        self.kind = kind
        self.key = key
        self.before = before
        self.after = after
        self.detectedAt = detectedAt
    }

    public var title: String { after?.title ?? before?.title ?? "" }
}

public enum EventDiff {
    /// Changes from `old` to `new`. Changes that only touch the past (both versions
    /// ended before `now`) are ignored, and so are fields the briefing doesn't show.
    public static func diff(old: [Event], new: [Event], now: Date) -> [EventChange] {
        let oldByKey = Dictionary(old.map { ($0.matchKey, $0) }, uniquingKeysWith: { first, _ in first })
        let newByKey = Dictionary(new.map { ($0.matchKey, $0) }, uniquingKeysWith: { first, _ in first })
        var changes: [EventChange] = []

        for event in new where oldByKey[event.matchKey] == nil && event.end > now {
            changes.append(EventChange(kind: .added, key: event.matchKey, before: nil, after: event, detectedAt: now))
        }
        for event in old where newByKey[event.matchKey] == nil && event.end > now {
            changes.append(EventChange(kind: .cancelled, key: event.matchKey, before: event, after: nil, detectedAt: now))
        }
        for before in old {
            guard let after = newByKey[before.matchKey], before.end > now || after.end > now else { continue }
            let kind: EventChange.Kind? =
                before.start != after.start || before.end != after.end || before.isAllDay != after.isAllDay ? .moved
                : before.title != after.title ? .renamed
                : before.location != after.location || before.calendar != after.calendar ? .updated
                : nil
            if let kind {
                changes.append(EventChange(kind: kind, key: before.matchKey, before: before, after: after, detectedAt: now))
            }
        }
        return changes.sorted { ($0.after ?? $0.before)!.start < ($1.after ?? $1.before)!.start }
    }

    /// Like `diff`, but keeps the original `detectedAt` for changes already in `previous`.
    public static func merge(_ changes: [EventChange], keepingTimesFrom previous: [EventChange]) -> [EventChange] {
        let earlier = Dictionary(previous.map { ("\($0.kind.rawValue)|\($0.key)", $0.detectedAt) }, uniquingKeysWith: min)
        return changes.map { change in
            var change = change
            if let time = earlier["\(change.kind.rawValue)|\(change.key)"] { change.detectedAt = time }
            return change
        }
    }
}
