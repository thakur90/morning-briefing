import Foundation

/// `~/Library/Application Support/Briefing/config.json` (design doc §10).
/// Missing keys fall back to the defaults below, so a partial file is fine.
public struct Config: Codable, Sendable, Equatable {
    public struct Day: Codable, Sendable, Equatable {
        public init() {}

        /// Free blocks are only reported inside this window.
        public var start = "08:00"
        public var end = "18:00"
        public var minFreeMinutes = 30
    }

    public struct Location: Codable, Sendable, Equatable {
        public init() {}

        public enum Mode: String, Codable, Sendable { case current, ip, fixed }
        public var mode: Mode = .current
        /// Used when `mode` is `fixed`, or as the last fallback (e.g. "Seattle").
        public var fallbackCity: String?
    }

    public struct Calendars: Codable, Sendable, Equatable {
        public init() {}

        public var providers = ["eventkit"]
        /// Calendar titles (or "Account/Title") to leave out entirely.
        public var exclude = ["Holidays in United States", "Birthdays", "Siri Suggestions"]
    }

    public struct Reminders: Codable, Sendable, Equatable {
        public init() {}

        /// Reminder list titles to include; empty = all.
        public var lists: [String] = []
    }

    public struct LiveUpdates: Codable, Sendable, Equatable {
        public init() {}

        public var enabled = true
        public var notifyOnChanges = true
    }

    /// Thresholds for the rule-based summary (design doc §6).
    public struct Summary: Codable, Sendable, Equatable {
        public init() {}

        /// Rain chance (%) at which the summary mentions rain.
        public var rainThreshold = 50
        /// Gaps shorter than this count as back-to-back.
        public var backToBackGapMinutes = 5
        /// Free blocks at least this long are called out.
        public var highlightFreeMinutes = 60
    }

    public var runAt = "07:00"
    public var weekdaysOnly = true
    public var outputDir = "~/Briefings"
    public var temperatureUnit: TemperatureUnit =
        Locale.current.measurementSystem == .us ? .fahrenheit : .celsius
    public var day = Day()
    public var location = Location()
    public var calendars = Calendars()
    public var reminders = Reminders()
    public var liveUpdates = LiveUpdates()
    public var summary = Summary()

    public init() {}

    /// Decodes `data` on top of the defaults: keys present in `data` win.
    public static func decode(_ data: Data) throws -> Config {
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config()))
        let user = try JSONSerialization.jsonObject(with: data)
        guard let defaults = defaults as? [String: Any], let user = user as? [String: Any] else {
            throw ConfigError.notAnObject
        }
        let merged = try JSONSerialization.data(withJSONObject: deepMerge(defaults, user))
        return try JSONDecoder().decode(Config.self, from: merged)
    }

    /// Loads the config, writing a default file first if there isn't one.
    public static func loadOrCreate(paths: AppPaths = AppPaths()) throws -> Config {
        let url = paths.config
        if let data = try? Data(contentsOf: url) {
            return try decode(data)
        }
        let config = Config()
        try FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        try JSONEncoder.briefing.encode(config).write(to: url, options: .atomic)
        return config
    }

    private static func deepMerge(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in override {
            if let baseDict = base[key] as? [String: Any], let overrideDict = value as? [String: Any] {
                result[key] = deepMerge(baseDict, overrideDict)
            } else {
                result[key] = value
            }
        }
        return result
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case notAnObject
    case invalidTime(String)

    public var description: String {
        switch self {
        case .notAnObject: "config.json must contain a JSON object"
        case .invalidTime(let value): "invalid time \"\(value)\" (expected HH:mm)"
        }
    }
}

extension Config {
    /// "07:30" → today at 07:30 in `calendar`'s time zone.
    public static func time(_ hhmm: String, on day: Date, calendar: Calendar) throws -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]),
              let date = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
        else { throw ConfigError.invalidTime(hhmm) }
        return date
    }
}
