import Foundation
import Network

/// Waits for a network connection, e.g. right after the Mac wakes (design doc A.1).
public enum NetworkWaiter {
    /// True once online; false if `timeout` passes first.
    public static func waitUntilOnline(timeout: TimeInterval = 120) async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = Once()
            let queue = DispatchQueue(label: "com.thakur90.briefing.network")
            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied, once.claim() {
                    monitor.cancel()
                    continuation.resume(returning: true)
                }
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() {
                    monitor.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

/// True for the first caller only.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
