import Foundation

/// Written by the agent; read by `briefing status` (design doc A.1, RunStateStore).
public struct AgentState: Codable, Sendable {
    public var pid: Int32
    public var version: String
    public var startedAt: Date
    /// "calendars" / "reminders" / "location" / "notifications" → AccessState raw value.
    public var permissions: [String: String]
    /// Last run of each kind ("morning", "manual", "refresh"). Kept across agent restarts,
    /// so a restart after 7:00 doesn't repeat the morning briefing.
    public var lastRuns: [String: RunRecord]?

    public init(pid: Int32, version: String, startedAt: Date, permissions: [String: String], lastRuns: [String: RunRecord]? = nil) {
        self.pid = pid
        self.version = version
        self.startedAt = startedAt
        self.permissions = permissions
        self.lastRuns = lastRuns
    }

    public func lastRun(_ kind: RunKind) -> RunRecord? {
        lastRuns?[kind.rawValue]
    }

    /// Day of the last morning run that wrote a briefing.
    public var lastMorningDay: String? {
        guard let run = lastRun(.morning), run.outcome != .failed else { return nil }
        return run.day
    }

    public mutating func record(_ run: RunRecord) {
        var runs = lastRuns ?? [:]
        runs[run.kind.rawValue] = run
        lastRuns = runs
    }

    public func save(paths: AppPaths = AppPaths()) throws {
        try FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        try JSONEncoder.briefing.encode(self).write(to: paths.state, options: .atomic)
    }

    public static func load(paths: AppPaths = AppPaths()) -> AgentState? {
        guard let data = try? Data(contentsOf: paths.state) else { return nil }
        return try? JSONDecoder.briefing.decode(AgentState.self, from: data)
    }
}
