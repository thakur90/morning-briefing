import CoreLocation
import Foundation

/// Something that can produce the Mac's current location.
public protocol CurrentLocating: Sendable {
    func currentLocation() async throws -> LocationInfo
}

/// CoreLocation fix plus a reverse-geocoded place name.
public struct CoreLocationLocator: CurrentLocating {
    private let timeout: Duration

    public init(timeout: Duration = .seconds(20)) {
        self.timeout = timeout
    }

    public func currentLocation() async throws -> LocationInfo {
        let (fix, name) = try await Self.locate(timeout: timeout)
        return LocationInfo(
            latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
            accuracyMeters: fix.horizontalAccuracy, name: name, source: .current, timestamp: fix.timestamp)
    }

    @MainActor
    private static func locate(timeout: Duration) async throws -> (CLLocation, String?) {
        let fix = try await LocationAccess().currentLocation(timeout: timeout)
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(fix).first
        let name = [placemark?.locality, placemark?.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        return (fix, name.nilIfEmpty)
    }
}

/// Resolves the location for weather (design doc §5):
/// current → cached (≤ 6 h) → IP-based (ipapi.co) → `fallbackCity` (Open-Meteo geocoding).
public struct LocationService: Sendable {
    public static let cacheMaxAge: TimeInterval = 6 * 3600

    private let config: Config.Location
    private let paths: AppPaths
    private let http: HTTPClient
    private let locator: CurrentLocating
    private let now: @Sendable () -> Date

    public init(
        config: Config.Location, paths: AppPaths, http: HTTPClient, locator: CurrentLocating,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.config = config
        self.paths = paths
        self.http = http
        self.locator = locator
        self.now = now
    }

    public func resolve() async -> (LocationInfo?, SourceStatus) {
        var problems: [String] = []

        if config.mode == .current {
            do {
                let location = try await locator.currentLocation()
                saveCache(location)
                let accuracy = location.accuracyMeters.map { String(format: " (±%.0f m)", $0) } ?? ""
                return (location, .ok("location", "current location\(accuracy)"))
            } catch {
                problems.append("current: \(error)")
            }
            if let cached = loadCache(), now().timeIntervalSince(cached.timestamp) <= Self.cacheMaxAge {
                var location = cached
                location.source = .cached
                return (location, .ok("location", "last known location (\(problems.joined(separator: "; ")))"))
            }
        }

        if config.mode != .fixed {
            do {
                return (try await ipLocation(), .ok("location", Self.fallbackDetail("IP-based, city-level", problems)))
            } catch {
                problems.append("ip: \(error)")
            }
        }

        if let city = config.fallbackCity?.nilIfEmpty {
            do {
                return (try await cityLocation(city), .ok("location", Self.fallbackDetail("city from config", problems)))
            } catch {
                problems.append("city: \(error)")
            }
        } else if config.mode == .fixed {
            problems.append("location.mode is \"fixed\" but location.fallbackCity is not set")
        }

        return (nil, .failed("location", problems.joined(separator: "; ")))
    }

    private static func fallbackDetail(_ what: String, _ problems: [String]) -> String {
        problems.isEmpty ? what : "\(what) (\(problems.joined(separator: "; ")))"
    }

    // MARK: Fallbacks

    private struct IPAPIResponse: Decodable {
        let latitude: Double?
        let longitude: Double?
        let city: String?
        let region_code: String?
        let error: Bool?
        let reason: String?
    }

    private func ipLocation() async throws -> LocationInfo {
        let data = try await http.get(URL(string: "https://ipapi.co/json/")!)
        let response = try JSONDecoder().decode(IPAPIResponse.self, from: data)
        guard response.error != true, let latitude = response.latitude, let longitude = response.longitude else {
            throw LocationError.failed(response.reason ?? "no coordinates in response")
        }
        let name = [response.city, response.region_code].compactMap { $0 }.joined(separator: ", ")
        return LocationInfo(
            latitude: latitude, longitude: longitude, accuracyMeters: nil,
            name: name.nilIfEmpty, source: .ip, timestamp: now())
    }

    private struct GeocodingResponse: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let admin1: String?
        }
        let results: [Result]?
    }

    private func cityLocation(_ city: String) async throws -> LocationInfo {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
        let data = try await http.get(components.url!)
        guard let result = try JSONDecoder().decode(GeocodingResponse.self, from: data).results?.first else {
            throw LocationError.failed("city \"\(city)\" not found")
        }
        let name = [result.name, result.admin1].compactMap { $0 }.joined(separator: ", ")
        return LocationInfo(
            latitude: result.latitude, longitude: result.longitude, accuracyMeters: nil,
            name: name, source: .configCity, timestamp: now())
    }

    // MARK: Cache

    private func saveCache(_ location: LocationInfo) {
        try? FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        try? JSONEncoder.briefing.encode(location).write(to: paths.locationCache, options: .atomic)
    }

    private func loadCache() -> LocationInfo? {
        guard let data = try? Data(contentsOf: paths.locationCache) else { return nil }
        return try? JSONDecoder.briefing.decode(LocationInfo.self, from: data)
    }
}
