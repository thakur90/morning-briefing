import Foundation

public enum RunKind: String, Codable, Sendable {
    /// The 7:00 weekday run (or its catch-up).
    case morning
    /// `briefing today`.
    case manual
    /// A live update after a calendar change (milestone 5).
    case refresh
}

public enum RunOutcome: String, Codable, Sendable {
    /// Every source worked.
    case full
    /// Briefing written, but some sources failed (e.g. no network → no weather).
    case partial
    /// Nothing written.
    case failed
}

/// One briefing generation, kept in state.json for `briefing status` (design doc A.1, RunStateStore).
public struct RunRecord: Codable, Sendable, Equatable {
    public var kind: RunKind
    /// "yyyy-MM-dd" the briefing is for.
    public var day: String
    public var startedAt: Date
    public var finishedAt: Date
    public var outcome: RunOutcome
    public var failedSources: [String]
    public var error: String?

    public init(
        kind: RunKind, day: String, startedAt: Date, finishedAt: Date, outcome: RunOutcome,
        failedSources: [String] = [], error: String? = nil
    ) {
        self.kind = kind
        self.day = day
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.failedSources = failedSources
        self.error = error
    }
}
