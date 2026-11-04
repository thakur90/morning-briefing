import Foundation

/// Generates the agent's launchd plist (design doc A.2).
public enum PlistBuilder {
    public static func agentPlist(paths: AppPaths) -> [String: Any] {
        let log = paths.logsDir.appending(path: "launchd.log").path
        return [
            "Label": AgentIdentity.label,
            "ProgramArguments": [paths.installedExecutable.path, "agent"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 30,
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
    }

    public static func xml(_ plist: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

public struct LaunchctlResult: Sendable {
    public var status: Int32
    public var output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// Thin wrapper around /bin/launchctl.
public struct LaunchctlClient: Sendable {
    public init() {}

    var domain: String { "gui/\(getuid())" }

    @discardableResult
    public func run(_ arguments: [String]) throws -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return LaunchctlResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    public func bootstrap(plist: URL) throws -> LaunchctlResult { try run(["bootstrap", domain, plist.path]) }
    public func bootout(label: String) throws -> LaunchctlResult { try run(["bootout", "\(domain)/\(label)"]) }
    public func print(label: String) throws -> LaunchctlResult { try run(["print", "\(domain)/\(label)"]) }
}

public struct AgentStatus: Sendable {
    public var loaded: Bool
    public var pid: Int?
    public var state: String?

    public var isRunning: Bool { pid != nil }

    /// Parses `launchctl print` output ("state = running", "pid = 123").
    public static func parse(_ result: LaunchctlResult) -> AgentStatus {
        guard result.status == 0 else { return AgentStatus(loaded: false) }
        func value(_ key: String) -> String? {
            result.output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("\(key) = ") }
                .map { String($0.dropFirst(key.count + 3)) }
        }
        return AgentStatus(loaded: true, pid: value("pid").flatMap { Int($0) }, state: value("state"))
    }
}

public enum InstallError: Error, CustomStringConvertible {
    case appNotInstalled(URL)
    case launchctl(String)

    public var description: String {
        switch self {
        case .appNotInstalled(let url): "\(url.path) not found. Build and install it with: scripts/build-app.sh --install"
        case .launchctl(let output): "launchctl failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// `briefing install / uninstall / status` (design doc A.1, A.5).
public struct LaunchAgentInstaller: Sendable {
    private let paths: AppPaths
    private let launchctl: LaunchctlClient

    public init(paths: AppPaths = AppPaths(), launchctl: LaunchctlClient = LaunchctlClient()) {
        self.paths = paths
        self.launchctl = launchctl
    }

    /// Writes the plist, (re)loads the agent and links `~/.local/bin/briefing`. Safe to run again.
    public func install() throws {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: paths.installedExecutable.path) else {
            throw InstallError.appNotInstalled(paths.installedApp)
        }
        try fm.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.launchAgentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PlistBuilder.xml(PlistBuilder.agentPlist(paths: paths)).write(to: paths.launchAgentPlist, options: .atomic)

        try stopAgent()
        let result = try launchctl.bootstrap(plist: paths.launchAgentPlist)
        guard result.status == 0 else { throw InstallError.launchctl(result.output) }

        try fm.createDirectory(at: paths.cliSymlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: paths.cliSymlink)
        try fm.createSymbolicLink(at: paths.cliSymlink, withDestinationURL: paths.installedExecutable)
    }

    /// Stops the agent and removes the plist, CLI link and app. Keeps config, briefings and logs.
    public func uninstall() throws {
        let fm = FileManager.default
        try? stopAgent()
        try? fm.removeItem(at: paths.launchAgentPlist)
        if let target = try? fm.destinationOfSymbolicLink(atPath: paths.cliSymlink.path),
           target == paths.installedExecutable.path {
            try? fm.removeItem(at: paths.cliSymlink)
        }
        try? fm.removeItem(at: paths.installedApp)
    }

    /// `bootout` returns before the job is gone; bootstrapping again too early
    /// fails with "Bootstrap failed: 5: Input/output error".
    private func stopAgent(timeout: TimeInterval = 10) throws {
        guard status().loaded else { return }
        _ = try? launchctl.bootout(label: AgentIdentity.label)
        let deadline = Date.now.addingTimeInterval(timeout)
        while status().loaded {
            guard Date.now < deadline else { throw InstallError.launchctl("the old agent didn't stop within \(Int(timeout)) s") }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    public func status() -> AgentStatus {
        (try? launchctl.print(label: AgentIdentity.label)).map(AgentStatus.parse) ?? AgentStatus(loaded: false)
    }
}
