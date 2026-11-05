import Foundation

public enum AgentCommand: String, Codable, Sendable {
    case today
    case todayDryRun = "today-dry-run"
    case check
}

public struct AgentRequest: Codable, Sendable, Equatable {
    public var id: String
    public var command: AgentCommand
    /// `today` only: post a notification (default true).
    public var notify: Bool?

    public init(id: String = UUID().uuidString, command: AgentCommand, notify: Bool? = nil) {
        self.id = id
        self.command = command
        self.notify = notify
    }
}

public struct AgentResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var context: DayContext?
    public var files: BriefingFiles?
    public var output: String?
    public var error: String?

    public init(
        id: String, ok: Bool, context: DayContext? = nil, files: BriefingFiles? = nil,
        output: String? = nil, error: String? = nil
    ) {
        self.id = id
        self.ok = ok
        self.context = context
        self.files = files
        self.output = output
        self.error = error
    }
}

public enum AgentChannelError: Error, CustomStringConvertible {
    case timedOut(TimeInterval)
    case badResponse(String)

    public var description: String {
        switch self {
        case .timedOut(let seconds): "the background agent didn't answer within \(Int(seconds)) s (see ~/Library/Logs/Briefing/)"
        case .badResponse(let message): "unreadable response from the agent: \(message)"
        }
    }
}

/// CLI → agent requests (design doc §3.2). The CLI posts a distributed
/// notification; the agent answers by writing `responses/<id>.json`.
public enum AgentChannel {
    static let requestName = Notification.Name("com.thakur90.briefing.request")
    static let requestKey = "request"

    // MARK: CLI side

    public static func send(
        _ command: AgentCommand, notify: Bool? = nil, paths: AppPaths = AppPaths(), timeout: TimeInterval = 90
    ) async throws -> AgentResponse {
        let request = AgentRequest(command: command, notify: notify)
        try FileManager.default.createDirectory(at: paths.responsesDir, withIntermediateDirectories: true)
        let responseURL = paths.responsesDir.appending(path: "\(request.id).json")
        defer { try? FileManager.default.removeItem(at: responseURL) }

        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        DistributedNotificationCenter.default().postNotificationName(
            requestName, object: nil, userInfo: [requestKey: json], deliverImmediately: true)

        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if let data = try? Data(contentsOf: responseURL) {
                do {
                    return try JSONDecoder.briefing.decode(AgentResponse.self, from: data)
                } catch {
                    throw AgentChannelError.badResponse("\(error)")
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw AgentChannelError.timedOut(timeout)
    }

    // MARK: Agent side

    /// Starts handling requests on the main actor. Keep the returned token alive.
    @MainActor
    public static func listen(
        paths: AppPaths = AppPaths(),
        handler: @escaping @MainActor (AgentRequest) async -> AgentResponse
    ) -> NSObjectProtocol {
        try? FileManager.default.createDirectory(at: paths.responsesDir, withIntermediateDirectories: true)
        pruneResponses(paths: paths)
        return DistributedNotificationCenter.default().addObserver(forName: requestName, object: nil, queue: .main) { note in
            guard let json = note.userInfo?[requestKey] as? String,
                  let request = try? JSONDecoder().decode(AgentRequest.self, from: Data(json.utf8)),
                  isValid(id: request.id)
            else { return }
            Task { @MainActor in
                let response = await handler(request)
                let url = paths.responsesDir.appending(path: "\(request.id).json")
                try? JSONEncoder.briefing.encode(response).write(to: url, options: .atomic)
            }
        }
    }

    /// Request IDs become file names, so only accept UUIDs (no path separators).
    public static func isValid(id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// Removes responses the CLI never picked up (older than an hour).
    static func pruneResponses(paths: AppPaths) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: paths.responsesDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < Date.now.addingTimeInterval(-3600) { try? fm.removeItem(at: file) }
        }
    }
}
