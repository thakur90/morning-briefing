import Foundation

public enum TemperatureUnit: String, Codable, Sendable {
    case celsius, fahrenheit
    public var symbol: String { "°" }
}

public struct HourlyWeather: Codable, Sendable, Equatable {
    public var time: Date
    public var temperature: Double
    public var precipitationProbability: Int
    public var description: String
}

public struct WeatherForecast: Codable, Sendable, Equatable {
    public var unit: TemperatureUnit
    public var currentTemperature: Double
    public var currentDescription: String
    public var high: Double
    public var low: Double
    public var maxPrecipitationProbability: Int
    public var sunrise: Date?
    public var sunset: Date?
    /// Today's remaining hours.
    public var hourly: [HourlyWeather]
}
