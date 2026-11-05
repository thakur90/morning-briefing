import Foundation

/// Runs one briefing generation at a time: collect → summarize → write → notify → record
/// (design doc A.4). Runs requested while one is in progress wait their turn.
@MainActor
public final class BriefingPipeline {
    public struct Result: Sendable {
        public var record: RunRecord
        public var briefing: Briefing?
        public var files: BriefingFiles?
    }

    /// After a failed morning run, wait this long before trying again.
    public static let retryDelay: TimeInterval = 15 * 60

    private let paths: AppPaths
    private let eventKit: EventKitStore
    private let calendar: Calendar
    private let log: @MainActor (String) -> Void
    public private(set) var state: AgentState

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var lastFailedMorningAttempt: Date?

    public init(
        paths: AppPaths, eventKit: EventKitStore, state: AgentState,
        calendar: Calendar = .autoupdatingCurrent, log: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.paths = paths
        self.eventKit = eventKit
        self.state = state
        self.calendar = calendar
        self.log = log
    }

    /// The morning run, if the schedule says it's due. Checked again after
    /// waiting for any run in progress, so it can't happen twice.
    public func runMorningIfDue(now: @MainActor () -> Date = { .now }) async -> ScheduleGuard.Decision? {
        await acquire()
        defer { release() }

        guard let config = loadConfig(),
              let decision = try? ScheduleGuard(config: config, calendar: calendar).decide(now: now(), lastMorningDay: state.lastMorningDay)
        else { return nil }
        guard decision == .run else { return decision }
        if let failed = lastFailedMorningAttempt, now().timeIntervalSince(failed) < Self.retryDelay { return nil }

        let online = await NetworkWaiter.waitUntilOnline()
        if !online { log("network still offline after 120 s; building the briefing without it") }
        let result = await generate(.morning, config: config, notify: true, now: now())
        lastFailedMorningAttempt = result.record.outcome == .failed ? now() : nil
        return .run
    }

    /// A manual (or refresh) run: always generates.
    public func run(_ kind: RunKind, notify: Bool, now: @MainActor () -> Date = { .now }) async -> Result {
        await acquire()
        defer { release() }
        guard let config = loadConfig() else {
            let record = RunRecord(kind: kind, day: ScheduleGuard.dayString(now(), calendar: calendar),
                                   startedAt: now(), finishedAt: now(), outcome: .failed, error: "config.json can't be read")
            return Result(record: record)
        }
        return await generate(kind, config: config, notify: notify, now: now())
    }

    public func updateState(_ change: (inout AgentState) -> Void) {
        change(&state)
        try? state.save(paths: paths)
    }

    // MARK: Generation

    private func generate(_ kind: RunKind, config: Config, notify: Bool, now: Date) async -> Result {
        let started = Date.now
        let context = await DayCollector.live(config: config, paths: paths, eventKit: eventKit).collect(now: now)
        let briefing = SummaryBuilder(config: config.summary, calendar: calendar).build(context)
        let failedSources = context.sources.filter { !$0.ok }.map(\.name)

        let record: RunRecord
        var files: BriefingFiles?
        do {
            files = try OutputWriter(config: config, paths: paths).write(
                briefing,
                html: HTMLRenderer(calendar: calendar).render(briefing),
                markdown: MarkdownRenderer(calendar: calendar).render(briefing))
            record = RunRecord(kind: kind, day: context.date, startedAt: started, finishedAt: .now,
                               outcome: failedSources.isEmpty ? .full : .partial, failedSources: failedSources)
        } catch {
            record = RunRecord(kind: kind, day: context.date, startedAt: started, finishedAt: .now,
                               outcome: .failed, failedSources: failedSources, error: "\(error)")
        }

        if notify, let files {
            do {
                try await Notifier.shared.post(
                    title: briefing.notificationTitle, body: briefing.notificationBody,
                    opening: files.html, thread: "briefing-\(context.date)")
            } catch {
                log("notification not sent: \(error.localizedDescription)")
            }
        }
        updateState { $0.record(record) }
        log("\(kind.rawValue) run: \(record.outcome.rawValue)\(failedSources.isEmpty ? "" : " (failed: \(failedSources.joined(separator: ", ")))")")
        return Result(record: record, briefing: briefing, files: files)
    }

    private func loadConfig() -> Config? {
        do {
            return try Config.loadOrCreate(paths: paths)
        } catch {
            log("config.json can't be read: \(error)")
            return nil
        }
    }

    // MARK: One run at a time

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
