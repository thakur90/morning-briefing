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
        let result = await generate(.morning, config: config, notify: true, now: now(), previous: nil)
        lastFailedMorningAttempt = result.record.outcome == .failed ? now() : nil
        return .run
    }

    public enum RefreshOutcome: Equatable, Sendable {
        case disabled
        case noBriefingYet
        case noChange
        case refreshed(changes: Int)
        case failed(String)
    }

    /// A live update after a calendar change (design doc §4.3): rebuilds today's
    /// briefing if anything visible changed, and notifies about calendar changes.
    public func refresh(now: @MainActor () -> Date = { .now }) async -> RefreshOutcome {
        await acquire()
        defer { release() }
        guard let config = loadConfig() else { return .failed("config.json can't be read") }
        guard config.liveUpdates.enabled else { return .disabled }

        let writer = OutputWriter(config: config, paths: paths)
        let day = ScheduleGuard.dayString(now(), calendar: calendar)
        guard let previous = writer.loadBriefing(for: day) else { return .noBriefingYet }

        let context = await DayCollector.live(config: config, paths: paths, eventKit: eventKit)
            .collect(now: now(), reusingWeatherFrom: previous.context)
        let newChanges = EventDiff.diff(old: previous.context.events, new: context.events, now: now())
        let remindersChanged = previous.context.reminders.map(\.id) != context.reminders.map(\.id)
            || previous.context.reminders.map(\.isOverdue) != context.reminders.map(\.isOverdue)
        guard !newChanges.isEmpty || remindersChanged else { return .noChange }

        let notify = config.liveUpdates.notifyOnChanges && !newChanges.isEmpty
        let result = await generate(.refresh, config: config, context: context, previous: previous,
                                    notification: notify ? newChanges : nil, now: now())
        if result.record.outcome == .failed { return .failed(result.record.error ?? "write failed") }
        return .refreshed(changes: newChanges.count)
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
        let previous = OutputWriter(config: config, paths: paths)
            .loadBriefing(for: ScheduleGuard.dayString(now(), calendar: calendar))
        return await generate(kind, config: config, notify: notify, now: now(), previous: previous)
    }

    public func updateState(_ change: (inout AgentState) -> Void) {
        change(&state)
        try? state.save(paths: paths)
    }

    // MARK: Generation

    private func generate(_ kind: RunKind, config: Config, notify: Bool, now: Date, previous: Briefing?) async -> Result {
        let context = await DayCollector.live(config: config, paths: paths, eventKit: eventKit).collect(now: now)
        return await generate(kind, config: config, context: context, previous: previous,
                              notification: notify ? [] : nil, now: now)
    }

    /// - Parameters:
    ///   - previous: today's earlier briefing. Its baseline and change history carry over
    ///     (except for the morning run, which starts a fresh baseline).
    ///   - notification: nil = no notification; empty = the day summary; changes = a change alert.
    private func generate(
        _ kind: RunKind, config: Config, context: DayContext, previous: Briefing?,
        notification: [EventChange]?, now: Date
    ) async -> Result {
        let started = Date.now
        var briefing = SummaryBuilder(config: config.summary, calendar: calendar).build(context)
        let changeText = ChangeText(calendar: calendar)
        if kind != .morning, let previous {
            let baseline = previous.baseline ?? previous.context.events
            briefing.baseline = baseline
            briefing.changes = EventDiff.merge(
                EventDiff.diff(old: baseline, new: context.events, now: now),
                keepingTimesFrom: previous.changes ?? [])
            briefing.applyChangeNotes(changeText)
            if kind == .refresh {
                briefing.generatedAt = previous.generatedAt
                briefing.updatedAt = now
            }
        } else {
            briefing.baseline = context.events
            briefing.changes = []
        }
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

        if let notification, let files {
            do {
                if notification.isEmpty {
                    try await Notifier.shared.post(
                        title: briefing.notificationTitle, body: briefing.notificationBody,
                        opening: files.html, thread: "briefing-\(context.date)")
                } else {
                    // Opens the page at "Changes since this morning".
                    let url = URL(string: files.html.absoluteString + "#changes") ?? files.html
                    try await Notifier.shared.post(
                        title: ChangeText.notificationTitle, body: changeText.notificationBody(notification),
                        opening: url, thread: "briefing-\(context.date)")
                }
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
