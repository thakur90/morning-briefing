import AppKit
import EventKit

/// One shared EKEventStore for calendars and reminders. EventKit recommends a
/// single long-lived store per process.
public final class EventKitStore: @unchecked Sendable {
    public let store = EKEventStore()

    public init() {}

    static func hex(_ color: CGColor?) -> String? {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return nil }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static func ref(_ calendar: EKCalendar) -> CalendarRef {
        CalendarRef(title: calendar.title, account: calendar.source.title, colorHex: hex(calendar.cgColor))
    }
}
