import Foundation

/// Minimal test harness (no XCTest / Swift Testing without Xcode).
@MainActor
enum Harness {
    static var passed = 0
    static var failed: [String] = []
    static var current = ""

    static func test(_ name: String, _ body: () async throws -> Void) async {
        current = name
        let before = failed.count
        do {
            try await body()
        } catch {
            failed.append("\(name): threw \(error)")
        }
        if failed.count == before {
            passed += 1
            print("✔ \(name)")
        } else {
            print("✘ \(name)")
        }
    }

    static func finish() -> Never {
        print("\n\(passed) passed, \(failed.count) failed")
        for failure in failed { print("  ✘ \(failure)") }
        exit(failed.isEmpty ? 0 : 1)
    }
}

@MainActor
func expect(_ condition: Bool, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
    if !condition {
        Harness.failed.append("\(Harness.current) (\(file):\(line)) \(message())")
    }
}

@MainActor
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #fileID, line: UInt = #line) {
    expect(actual == expected, "expected \(expected), got \(actual)", file: file, line: line)
}

// MARK: Fixtures (sample data only — never real calendars)

let pacific: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
}()

/// 2026-11-04 at `hh:mm` Los Angeles time.
func at(_ hh: Int, _ mm: Int = 0, day: Int = 4) -> Date {
    pacific.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hh, minute: mm))!
}
