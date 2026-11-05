import AppKit
import Foundation

/// Fires the morning briefing at `runAt` on run days, and catches up after
/// sleep, login or a crash (design doc A.3).
///
/// It re-checks at least once a minute, so config changes (`runAt`, `weekdaysOnly`)
/// and clock changes are picked up without restarting. Waking from sleep and clock
/// or time-zone changes trigger an immediate check.
@MainActor
public final class MorningScheduler {
    static let maxSleep: TimeInterval = 60

    private let pipeline: BriefingPipeline
    private let paths: AppPaths
    private let log: @MainActor (String) -> Void
    private var loop: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sleeper: CheckedContinuation<Void, Never>?
    private var sleepTimer: Task<Void, Never>?
    private var lastLogged: String?

    public init(pipeline: BriefingPipeline, paths: AppPaths, log: @escaping @MainActor (String) -> Void) {
        self.pipeline = pipeline
        self.paths = paths
        self.log = log
    }

    public func start() {
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification, "woke from sleep")
        observe(.default, .NSSystemClockDidChange, "clock changed")
        observe(.default, .NSSystemTimeZoneDidChange, "time zone changed")
        loop = Task { [weak self] in
            while !Task.isCancelled, let self {
                await self.tick()
                await self.sleep(self.secondsUntilNextCheck())
            }
        }
    }

    public func stop() {
        loop?.cancel()
        wake()
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    /// When the next morning run is due (for logging and `briefing status`).
    public func nextRun(now: Date = .now) -> Date? {
        guard let config = try? Config.loadOrCreate(paths: paths) else { return nil }
        return try? ScheduleGuard(config: config, calendar: .autoupdatingCurrent).nextRun(after: now)
    }

    private func tick() async {
        let decision = await pipeline.runMorningIfDue()
        let message: String = switch decision {
        case .run: "morning briefing ran"
        case .skip(let reason): "morning briefing skipped: \(reason.rawValue)"
        case nil: "morning briefing waiting (config error or retry delay)"
        }
        // Only log changes; this runs every minute.
        if message != lastLogged || decision == .run {
            let next = nextRun().map { " · next run \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            log(message + next)
            lastLogged = message
        }
    }

    private func secondsUntilNextCheck() -> TimeInterval {
        guard let next = nextRun() else { return Self.maxSleep }
        return min(max(next.timeIntervalSinceNow, 1), Self.maxSleep)
    }

    // MARK: Interruptible sleep

    private func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            sleeper = continuation
            sleepTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.wake()
            }
        }
    }

    private func wake() {
        sleepTimer?.cancel()
        sleepTimer = nil
        sleeper?.resume()
        sleeper = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ reason: String) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log("\(reason): checking the schedule")
                self?.lastLogged = nil
                self?.wake()
            }
        }
        observers.append((center, token))
    }
}
