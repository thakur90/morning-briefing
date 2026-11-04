import Foundation

public enum LocationSource: String, Codable, Sendable {
    case current, cached, ip, configCity = "config-city"
}

public struct LocationInfo: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var accuracyMeters: Double?
    /// e.g. "Lynnwood, WA"
    public var name: String?
    public var source: LocationSource
    public var timestamp: Date

    public init(
        latitude: Double, longitude: Double, accuracyMeters: Double?, name: String?,
        source: LocationSource, timestamp: Date
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracyMeters = accuracyMeters
        self.name = name
        self.source = source
        self.timestamp = timestamp
    }
}

public struct SourceStatus: Codable, Sendable, Equatable {
    public var name: String
    public var ok: Bool
    public var detail: String?

    public static func ok(_ name: String, _ detail: String? = nil) -> SourceStatus {
        SourceStatus(name: name, ok: true, detail: detail)
    }

    public static func failed(_ name: String, _ detail: String) -> SourceStatus {
        SourceStatus(name: name, ok: false, detail: detail)
    }
}

/// Everything collected for one day: the input to the summarizer (milestone 3).
public struct DayContext: Codable, Sendable, Equatable {
    /// "2026-11-04"
    public var date: String
    public var timeZone: String
    public var generatedAt: Date
    public var location: LocationInfo?
    public var weather: WeatherForecast?
    public var events: [Event]
    public var freeBlocks: [FreeBlock]
    public var overlaps: [Overlap]
    public var reminders: [Reminder]
    public var sources: [SourceStatus]

    public init(
        date: String, timeZone: String, generatedAt: Date, location: LocationInfo?, weather: WeatherForecast?,
        events: [Event], freeBlocks: [FreeBlock], overlaps: [Overlap], reminders: [Reminder], sources: [SourceStatus]
    ) {
        self.date = date
        self.timeZone = timeZone
        self.generatedAt = generatedAt
        self.location = location
        self.weather = weather
        self.events = events
        self.freeBlocks = freeBlocks
        self.overlaps = overlaps
        self.reminders = reminders
        self.sources = sources
    }
}

extension JSONEncoder {
    public static var briefing: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    public static var briefing: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
