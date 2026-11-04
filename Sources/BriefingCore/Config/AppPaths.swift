import Foundation

/// Where Briefing keeps its files. Injectable so tests can use a temporary home.
public struct AppPaths: Sendable {
    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public var supportDir: URL { home.appending(path: "Library/Application Support/Briefing") }
    public var config: URL { supportDir.appending(path: "config.json") }
    public var state: URL { supportDir.appending(path: "state.json") }
    public var locationCache: URL { supportDir.appending(path: "location.json") }
    public var responsesDir: URL { supportDir.appending(path: "responses") }
    public var logsDir: URL { home.appending(path: "Library/Logs/Briefing") }

    public var installedApp: URL { home.appending(path: "Applications/Briefing.app") }
    public var installedExecutable: URL { installedApp.appending(path: "Contents/MacOS/briefing") }
    public var launchAgentPlist: URL { home.appending(path: "Library/LaunchAgents/\(AgentIdentity.label).plist") }
    public var cliSymlink: URL { home.appending(path: ".local/bin/briefing") }

    /// Expands a leading "~/" against `home`.
    public func expand(_ path: String) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }
}

public enum AgentIdentity {
    public static let label = "com.thakur90.briefing"
    public static let bundleID = "com.thakur90.briefing"
}
