import Foundation

public struct EventNote: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case first, backToBack, overlap, added, moved }
    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// The finished briefing: the DayContext plus the rule-based summary (design doc §6).
public struct Briefing: Codable, Sendable, Equatable {
    public var context: DayContext
    public var headline: String
    /// "Your day" paragraph, one sentence per entry.
    public var sentences: [String]
    /// Event ID → notes shown under that event.
    public var notes: [String: [EventNote]]
    public var notificationTitle: String
    public var notificationBody: String
    /// When the morning briefing was first generated (stays fixed across live updates).
    public var generatedAt: Date
    /// Set when a live update (milestone 5) rebuilt the briefing.
    public var updatedAt: Date?

    public init(
        context: DayContext, headline: String, sentences: [String], notes: [String: [EventNote]],
        notificationTitle: String, notificationBody: String, generatedAt: Date, updatedAt: Date? = nil
    ) {
        self.context = context
        self.headline = headline
        self.sentences = sentences
        self.notes = notes
        self.notificationTitle = notificationTitle
        self.notificationBody = notificationBody
        self.generatedAt = generatedAt
        self.updatedAt = updatedAt
    }
}
