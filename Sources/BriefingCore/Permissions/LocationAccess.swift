import CoreLocation
import Foundation

public enum LocationError: Error, Sendable, CustomStringConvertible {
    case notAuthorized(AccessState)
    case timedOut
    case failed(String)

    public var description: String {
        switch self {
        case .notAuthorized(let state): "location access \(state.rawValue)"
        case .timedOut: "timed out waiting for a location fix"
        case .failed(let message): message
        }
    }
}

/// One-shot current location via CoreLocation. Must run on the main actor,
/// because CLLocationManager delivers callbacks on the run loop it was created on.
@MainActor
public final class LocationAccess: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    public var status: AccessState { AccessState(manager.authorizationStatus) }

    public func currentLocation(timeout: Duration = .seconds(20)) async throws -> CLLocation {
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.finish(.failure(LocationError.timedOut))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            switch status {
            case .notDetermined: manager.requestWhenInUseAuthorization()  // continues in didChangeAuthorization
            case .granted: manager.requestLocation()
            case let other: finish(.failure(LocationError.notAuthorized(other)))
            }
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch status {
        case .notDetermined: break
        case .granted: manager.requestLocation()
        case let other: finish(.failure(LocationError.notAuthorized(other)))
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.last { finish(.success(location)) }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(LocationError.failed(error.localizedDescription)))
    }
}
