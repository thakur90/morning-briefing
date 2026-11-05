import Foundation

/// Refreshes today's briefing when calendars change (design doc §4.3):
/// listen → debounce → `BriefingPipeline.refresh()` (which re-fetches and diffs).
@MainActor
public final class CalendarWatcher {
    public static let debounce: Duration = .seconds(10)

    private let changes: AsyncStream<Void>
    private let pipeline: BriefingPipeline
    private let log: @MainActor (String) -> Void
    private var listener: Task<Void, Never>?
    private var pending: Task<Void, Never>?

    public init(changes: AsyncStream<Void>, pipeline: BriefingPipeline, log: @escaping @MainActor (String) -> Void) {
        self.changes = changes
        self.pipeline = pipeline
        self.log = log
    }

    public func start() {
        listener = Task { [weak self, changes] in
            for await _ in changes {
                self?.scheduleRefresh()
            }
        }
    }

    public func stop() {
        listener?.cancel()
        pending?.cancel()
    }

    /// A sync usually posts several notifications in a row; wait until they settle.
    private func scheduleRefresh() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            let outcome = await self.pipeline.refresh()
            switch outcome {
            case .refreshed(let count): self.log("calendar changed: briefing refreshed (\(count) calendar change(s))")
            case .noChange: break  // e.g. a notes-only edit or a change on another day
            case .noBriefingYet: self.log("calendar changed: no briefing yet today, nothing to update")
            case .disabled: break
            case .failed(let reason): self.log("calendar changed: refresh failed: \(reason)")
            }
        }
    }
}
