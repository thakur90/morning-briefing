import Foundation

/// Decides whether the morning briefing should run now, and when it runs next
/// (design doc A.3). Pure, so every case is unit-tested.
public struct ScheduleGuard: Sendable {
    public enum SkipReason: String, Codable, Sendable {
        case notARunDay = "not-a-run-day"
        case tooEarly = "too-early"
        case alreadyDone = "already-done"
    }

    public enum Decision: Equatable, Sendable {
        case run
        case skip(SkipReason)
    }

    private let runAt: String
    private let weekdaysOnly: Bool
    private let calendar: Calendar

    public init(runAt: String, weekdaysOnly: Bool, calendar: Calendar = .current) {
        self.runAt = runAt
        self.weekdaysOnly = weekdaysOnly
        self.calendar = calendar
    }

    public init(config: Config, calendar: Calendar = .current) {
        self.init(runAt: config.runAt, weekdaysOnly: config.weekdaysOnly, calendar: calendar)
    }

    /// Monday–Friday when `weekdaysOnly`, otherwise every day.
    public func isRunDay(_ date: Date) -> Bool {
        guard weekdaysOnly else { return true }
        let weekday = calendar.component(.weekday, from: date)  // 1 = Sunday … 7 = Saturday
        return (2...6).contains(weekday)
    }

    /// `lastMorningDay` is the "yyyy-MM-dd" of the last completed morning run.
    public func decide(now: Date, lastMorningDay: String?) throws -> Decision {
        guard isRunDay(now) else { return .skip(.notARunDay) }
        guard now >= (try Config.time(runAt, on: now, calendar: calendar)) else { return .skip(.tooEarly) }
        guard lastMorningDay != dayString(now) else { return .skip(.alreadyDone) }
        return .run
    }

    /// The next run time strictly after `now`.
    public func nextRun(after now: Date) throws -> Date {
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { continue }
            let candidate = try Config.time(runAt, on: day, calendar: calendar)
            if candidate > now, isRunDay(candidate) { return candidate }
        }
        throw ConfigError.invalidTime(runAt)
    }

    public func dayString(_ date: Date) -> String {
        Self.dayString(date, calendar: calendar)
    }

    public static func dayString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
