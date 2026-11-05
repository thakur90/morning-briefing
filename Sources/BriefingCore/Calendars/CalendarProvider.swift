import Foundation

/// A source of calendar events (design doc §4.2).
public protocol CalendarProvider: Sendable {
    var id: String { get }
    func calendars() async throws -> [CalendarInfo]
    func events(in range: DateInterval) async throws -> [Event]
    /// Emits when the provider's data *may* have changed. Coarse: callers re-fetch and diff.
    func changes() -> AsyncStream<Void>
}

public enum CalendarError: Error, CustomStringConvertible {
    case accessNotGranted(AccessState)

    public var description: String {
        switch self {
        case .accessNotGranted(let state): "calendar access \(state.rawValue)"
        }
    }
}
