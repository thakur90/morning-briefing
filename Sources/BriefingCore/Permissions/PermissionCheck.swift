import CoreLocation
import Foundation

public struct LocationFix: Sendable {
    public let latitude: Double
    public let longitude: Double
    public let accuracyMeters: Double
}

/// Result of probing Calendar, Reminders and Location access (milestone 1).
public struct PermissionReport: Sendable {
    public var calendars: AccessState
    public var todaysEvents: [CalendarEventSummary]
    public var reminders: AccessState
    public var dueReminders: [ReminderSummary]
    public var locationServicesEnabled: Bool
    public var location: Result<LocationFix, LocationError>

    public var allGranted: Bool {
        guard case .success = location else { return false }
        return calendars.isGranted && reminders.isGranted
    }
}

@MainActor
public enum PermissionCheck {
    /// Requests any missing access, then reads today's events, due reminders and a location fix.
    public static func run(locationTimeout: Duration = .seconds(60)) async -> PermissionReport {
        let eventKit = EventKitAccess()

        let calendars = await eventKit.requestAccess(to: .event)
        let events = calendars.isGranted ? eventKit.events(on: .now) : []

        let reminders = await eventKit.requestAccess(to: .reminder)
        let due = reminders.isGranted ? await eventKit.dueReminders(through: .now) : []

        let servicesEnabled = await Task.detached { CLLocationManager.locationServicesEnabled() }.value
        let location: Result<LocationFix, LocationError>
        do {
            let fix = try await LocationAccess().currentLocation(timeout: locationTimeout)
            location = .success(LocationFix(
                latitude: fix.coordinate.latitude,
                longitude: fix.coordinate.longitude,
                accuracyMeters: fix.horizontalAccuracy))
        } catch let error as LocationError {
            location = .failure(error)
        } catch {
            location = .failure(.failed(error.localizedDescription))
        }

        return PermissionReport(
            calendars: calendars, todaysEvents: events,
            reminders: reminders, dueReminders: due,
            locationServicesEnabled: servicesEnabled, location: location)
    }
}
