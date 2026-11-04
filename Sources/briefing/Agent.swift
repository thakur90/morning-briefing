import ArgumentParser
import BriefingCore
import Foundation

/// The background agent, started by launchd from inside Briefing.app (design doc Appendix A).
struct Agent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the background agent (started by launchd).")

    @Flag(help: "Run the permission check, post the result as a notification, and exit.")
    var once = false

    @MainActor
    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)  // launchd redirects stdout to a file; flush per line
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        log("agent started: \(Bundle.main.bundlePath) v\(version)")

        let paths = AppPaths()
        let report = await PermissionCheck.run(locationTimeout: .seconds(30))
        print(ReportPrinter.render(report))

        let notifications: AccessState = NotificationAccess.isAvailable ? await NotificationAccess.requestAccess() : .denied
        print("Notifications: \(notifications.isGranted ? "✅ granted" : "❌ \(notifications.rawValue)")")

        let locationState: AccessState = switch report.location {
        case .success: .granted
        case .failure(.notAuthorized(let state)): state
        case .failure: .granted  // authorized, but no fix this time
        }
        try? AgentState(
            pid: getpid(), version: version, startedAt: .now,
            permissions: [
                "calendars": report.calendars.rawValue,
                "reminders": report.reminders.rawValue,
                "location": locationState.rawValue,
                "notifications": notifications.rawValue,
            ]
        ).save(paths: paths)

        if once {
            if notifications.isGranted {
                try await NotificationAccess.post(
                    title: report.allGranted ? "Briefing is set up" : "Briefing needs permissions",
                    body: Self.summary(report))
            }
            return
        }

        // Created after the permission prompts: an EKEventStore made before access
        // was granted doesn't see any data.
        let eventKit = EventKitStore()
        let token = AgentChannel.listen(paths: paths) { request in
            log("request \(request.command.rawValue) \(request.id)")
            return await Self.handle(request, eventKit: eventKit, paths: paths)
        }
        log("listening for requests")
        defer { DistributedNotificationCenter.default().removeObserver(token) }
        while true { try await Task.sleep(for: .seconds(3600)) }
    }

    @MainActor
    private static func handle(_ request: AgentRequest, eventKit: EventKitStore, paths: AppPaths) async -> AgentResponse {
        switch request.command {
        case .todayDryRun:
            do {
                let config = try Config.loadOrCreate(paths: paths)
                let context = await DayCollector.live(config: config, paths: paths, eventKit: eventKit).collect()
                return AgentResponse(id: request.id, ok: true, context: context)
            } catch {
                return AgentResponse(id: request.id, ok: false, error: "config: \(error)")
            }
        case .check:
            let report = await PermissionCheck.run(locationTimeout: .seconds(20))
            return AgentResponse(id: request.id, ok: report.allGranted, output: ReportPrinter.render(report))
        }
    }

    private static func summary(_ report: PermissionReport) -> String {
        let location: String = switch report.location {
        case .success: "✅"
        case .failure: "❌"
        }
        return "Calendars \(report.calendars.isGranted ? "✅" : "❌") · Reminders \(report.reminders.isGranted ? "✅" : "❌") · Location \(location)"
    }
}

func log(_ message: String) {
    print("[\(Date.now.formatted(.iso8601))] \(message)")
}
