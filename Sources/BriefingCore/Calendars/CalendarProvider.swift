import Foundation

/// A source of calendar events (design doc §4.2). Live-update support
/// (`changes()`) is added in milestone 5.
public protocol CalendarProvider: Sendable {
    var id: String { get }
    func calendars() async throws -> [CalendarInfo]
    func events(in range: DateInterval) async throws -> [Event]
}

public enum CalendarError: Error, CustomStringConvertible {
    case accessNotGranted(AccessState)

    public var description: String {
        switch self {
        case .accessNotGranted(let state): "calendar access \(state.rawValue)"
        }
    }
}
