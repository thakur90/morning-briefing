import Foundation

/// Written by the agent; read by `briefing status` (design doc A.1, RunStateStore).
/// Milestone 2 keeps only startup info; run history arrives with milestone 3.
public struct AgentState: Codable, Sendable {
    public var pid: Int32
    public var version: String
    public var startedAt: Date
    /// "calendars" / "reminders" / "location" / "notifications" → AccessState raw value.
    public var permissions: [String: String]

    public init(pid: Int32, version: String, startedAt: Date, permissions: [String: String]) {
        self.pid = pid
        self.version = version
        self.startedAt = startedAt
        self.permissions = permissions
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
