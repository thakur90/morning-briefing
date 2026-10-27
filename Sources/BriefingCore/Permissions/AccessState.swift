import CoreLocation
import EventKit

/// A permission state, unified across EventKit and CoreLocation.
public enum AccessState: String, Sendable {
    case granted
    case denied
    case restricted
    case notDetermined = "not determined"
    case writeOnly = "write-only"

    public var isGranted: Bool { self == .granted }

    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .fullAccess: self = .granted
        case .writeOnly: self = .writeOnly
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied
        }
    }

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: self = .granted
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied
        }
    }
}
