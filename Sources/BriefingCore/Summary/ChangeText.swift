import Foundation

/// Wording for live-update changes: notification lines and per-event notes (design doc §4.3, §6.3).
public struct ChangeText: Sendable {
    private let text: TimeText

    public init(calendar: Calendar = .current, locale: Locale = .current) {
        self.text = TimeText(calendar: calendar, locale: locale)
    }

    public static let notificationTitle = "Calendar updated"
    static let maxLines = 4

    /// "New: Dentist at 3:00 PM (Home)"
    public func line(_ change: EventChange) -> String {
        switch change.kind {
        case .added:
            let event = change.after!
            return "New: \(event.title) \(when(event)) (\(event.calendar.title))"
        case .moved:
            let event = change.after!
            return "Moved: \(event.title) → \(event.isAllDay ? "all day" : text.time(event.start))"
        case .renamed:
            return "Renamed: \(change.before!.title) → \(change.after!.title)"
        case .updated:
            return "Updated: \(change.title) (\(whatChanged(change)))"
        case .cancelled:
            let event = change.before!
            return "Cancelled: \(event.title) \(when(event))"
        }
    }

    /// One line per change, grouped into a single notification body.
    public func notificationBody(_ changes: [EventChange]) -> String {
        var lines = changes.prefix(Self.maxLines).map(line)
        if changes.count > Self.maxLines { lines.append("…and \(changes.count - Self.maxLines) more") }
        return lines.joined(separator: "\n")
    }

    /// Note under the event on the page, e.g. "Moved from 1:00 PM".
    public func note(_ change: EventChange) -> EventNote? {
        switch change.kind {
        case .added: EventNote(kind: .added, text: "Added at \(text.time(change.detectedAt))")
        case .moved: change.before.map { EventNote(kind: .moved, text: "Moved from \($0.isAllDay ? "all day" : text.time($0.start))") }
        case .renamed: change.before.map { EventNote(kind: .renamed, text: "Renamed from “\($0.title)”") }
        case .updated: EventNote(kind: .updated, text: whatChanged(change).prefix(1).uppercased() + whatChanged(change).dropFirst() + " changed")
        case .cancelled: nil
        }
    }

    /// "Cancelled at 10:52 AM"
    public func cancelledMeta(_ change: EventChange) -> String {
        "Cancelled at \(text.time(change.detectedAt))"
    }

    private func when(_ event: Event) -> String {
        event.isAllDay ? "(all day)" : "at \(text.time(event.start))"
    }

    private func whatChanged(_ change: EventChange) -> String {
        guard let before = change.before, let after = change.after else { return "details" }
        var parts: [String] = []
        if before.location != after.location { parts.append("location") }
        if before.calendar != after.calendar { parts.append("calendar") }
        return parts.isEmpty ? "details" : parts.joined(separator: " and ")
    }
}

extension Briefing {
    /// Adds "Added at …" / "Moved from …" notes for the current changes.
    mutating func applyChangeNotes(_ wording: ChangeText) {
        for change in changes ?? [] {
            guard let event = change.after, let note = wording.note(change) else { continue }
            notes[event.id, default: []].append(note)
        }
    }
}
