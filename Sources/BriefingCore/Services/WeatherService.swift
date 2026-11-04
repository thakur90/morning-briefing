import Foundation

/// Today's forecast from Open-Meteo (free, no API key). Coordinates are
/// rounded to 2 decimals (~1 km) before they leave the Mac.
public struct WeatherService: Sendable {
    private let http: HTTPClient
    private let unit: TemperatureUnit

    public init(http: HTTPClient, unit: TemperatureUnit) {
        self.http = http
        self.unit = unit
    }

    public func forecast(latitude: Double, longitude: Double, now: Date = .now) async throws -> WeatherForecast {
        let data = try await http.get(Self.url(latitude: latitude, longitude: longitude, unit: unit))
        return try Self.parse(data, unit: unit, now: now)
    }

    static func url(latitude: Double, longitude: Double, unit: TemperatureUnit) -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", latitude)),
            .init(name: "longitude", value: String(format: "%.2f", longitude)),
            .init(name: "current", value: "temperature_2m,weather_code"),
            .init(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
            .init(name: "temperature_unit", value: unit.rawValue),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "1"),
        ]
        return components.url!
    }

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
        }
        struct Hourly: Decodable {
            let time: [String]
            let temperature_2m: [Double?]
            let precipitation_probability: [Int?]
            let weather_code: [Int?]
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let precipitation_probability_max: [Int?]
            let sunrise: [String]
            let sunset: [String]
        }
        let utc_offset_seconds: Int
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }

    static func parse(_ data: Data, unit: TemperatureUnit, now: Date) throws -> WeatherForecast {
        let response = try JSONDecoder().decode(Response.self, from: data)

        // Open-Meteo returns local times without an offset ("2026-11-04T09:00") plus the offset separately.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: response.utc_offset_seconds)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"

        let hourly = response.hourly
        let thisHour = now.addingTimeInterval(-3600)
        let hours: [HourlyWeather] = hourly.time.indices.compactMap { i in
            guard let time = formatter.date(from: hourly.time[i]), time > thisHour,
                  let temperature = hourly.temperature_2m[safe: i] ?? nil
            else { return nil }
            return HourlyWeather(
                time: time,
                temperature: temperature,
                precipitationProbability: (hourly.precipitation_probability[safe: i] ?? nil) ?? 0,
                description: WeatherCode.describe((hourly.weather_code[safe: i] ?? nil) ?? -1))
        }

        let daily = response.daily
        let temperatures = hourly.temperature_2m.compactMap { $0 }
        return WeatherForecast(
            unit: unit,
            currentTemperature: response.current.temperature_2m,
            currentDescription: WeatherCode.describe(response.current.weather_code),
            high: (daily.temperature_2m_max.first ?? nil) ?? temperatures.max() ?? response.current.temperature_2m,
            low: (daily.temperature_2m_min.first ?? nil) ?? temperatures.min() ?? response.current.temperature_2m,
            maxPrecipitationProbability: (daily.precipitation_probability_max.first ?? nil) ?? 0,
            sunrise: daily.sunrise.first.flatMap(formatter.date(from:)),
            sunset: daily.sunset.first.flatMap(formatter.date(from:)),
            hourly: hours)
    }
}

/// WMO weather interpretation codes, as used by Open-Meteo.
enum WeatherCode {
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61: "Light rain"
        case 63: "Rain"
        case 65: "Heavy rain"
        case 66, 67: "Freezing rain"
        case 71: "Light snow"
        case 73: "Snow"
        case 75: "Heavy snow"
        case 77: "Snow grains"
        case 80, 81: "Rain showers"
        case 82: "Heavy rain showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorm"
        case 96, 99: "Thunderstorm with hail"
        default: "Unknown"
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
