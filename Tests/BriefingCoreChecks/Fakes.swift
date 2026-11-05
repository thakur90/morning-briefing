import BriefingCore
import Foundation

final class FakeHTTP: HTTPClient, @unchecked Sendable {
    private let responses: [String: String]
    private(set) var requested: [URL] = []

    /// host → response body. Unknown hosts fail.
    init(_ responses: [String: String]) {
        self.responses = responses
    }

    func get(_ url: URL) async throws -> Data {
        requested.append(url)
        guard let body = responses[url.host() ?? ""] else { throw URLError(.cannotConnectToHost) }
        return Data(body.utf8)
    }
}

struct FakeLocator: CurrentLocating {
    let result: Result<LocationInfo, Error>
    init(_ result: Result<LocationInfo, Error>) { self.result = result }
    func currentLocation() async throws -> LocationInfo { try result.get() }
}

struct FakeCalendars: CalendarProvider {
    let id = "fake"
    let events: [Event]
    func calendars() async throws -> [CalendarInfo] {
        Set(events.map(\.calendar)).map { CalendarInfo(id: $0.title, ref: $0, provider: id) }
    }
    func events(in range: DateInterval) async throws -> [Event] {
        events.filter { $0.end > range.start && $0.start < range.end }
    }
    func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

struct FakeReminders: ReminderSource {
    var reminders: [Reminder] = []
    func due(on day: Date, now: Date, calendar: Calendar) async throws -> [Reminder] { reminders }
}

func tempHome() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "briefing-tests-\(UUID().uuidString)")
}

let seattle = LocationInfo(
    latitude: 47.61, longitude: -122.33, accuracyMeters: 35, name: "Seattle, WA",
    source: .current, timestamp: at(12))

let sampleIP = #"{"city": "Bothell", "region_code": "WA", "latitude": 47.76, "longitude": -122.2}"#

let sampleGeocoding = #"{"results": [{"name": "Seattle", "latitude": 47.6062, "longitude": -122.3321, "admin1": "Washington"}]}"#

let sampleForecast = """
{
  "utc_offset_seconds": -28800,
  "current": {"temperature_2m": 48.2, "weather_code": 3},
  "hourly": {
    "time": ["2026-11-04T08:00", "2026-11-04T10:00", "2026-11-04T15:00"],
    "temperature_2m": [45.1, 47.9, 51.0],
    "precipitation_probability": [0, 10, 70],
    "weather_code": [3, 3, 63]
  },
  "daily": {
    "temperature_2m_max": [53.1],
    "temperature_2m_min": [44.0],
    "precipitation_probability_max": [70],
    "sunrise": ["2026-11-04T07:02"],
    "sunset": ["2026-11-04T16:41"]
  }
}
"""
