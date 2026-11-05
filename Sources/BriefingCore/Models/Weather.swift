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

    public init(time: Date, temperature: Double, precipitationProbability: Int, description: String) {
        self.time = time
        self.temperature = temperature
        self.precipitationProbability = precipitationProbability
        self.description = description
    }
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

    public init(
        unit: TemperatureUnit, currentTemperature: Double, currentDescription: String, high: Double, low: Double,
        maxPrecipitationProbability: Int, sunrise: Date?, sunset: Date?, hourly: [HourlyWeather]
    ) {
        self.unit = unit
        self.currentTemperature = currentTemperature
        self.currentDescription = currentDescription
        self.high = high
        self.low = low
        self.maxPrecipitationProbability = maxPrecipitationProbability
        self.sunrise = sunrise
        self.sunset = sunset
        self.hourly = hourly
    }
}
