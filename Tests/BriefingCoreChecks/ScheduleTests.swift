import BriefingCore
import Foundation

// Nov 2026: 4 = Wed, 6 = Fri, 7 = Sat, 8 = Sun, 9 = Mon. DST ended Sun Nov 1.

@MainActor
func runScheduleTests() async {
    let weekdays = ScheduleGuard(runAt: "07:00", weekdaysOnly: true, calendar: pacific)
    let everyDay = ScheduleGuard(runAt: "07:00", weekdaysOnly: false, calendar: pacific)

    await Harness.test("schedule: runs at or after 7:00 on a weekday") {
        expectEqual(try weekdays.decide(now: at(7), lastMorningDay: nil), .run)
        expectEqual(try weekdays.decide(now: at(22), lastMorningDay: "2026-11-03"), .run)  // catch-up late in the day
    }

    await Harness.test("schedule: skips before 7:00, when done, and at weekends") {
        expectEqual(try weekdays.decide(now: at(6, 59), lastMorningDay: nil), .skip(.tooEarly))
        expectEqual(try weekdays.decide(now: at(9), lastMorningDay: "2026-11-04"), .skip(.alreadyDone))
        expectEqual(try weekdays.decide(now: at(9, day: 7), lastMorningDay: nil), .skip(.notARunDay))
        expectEqual(try weekdays.decide(now: at(9, day: 8), lastMorningDay: nil), .skip(.notARunDay))
        expectEqual(try everyDay.decide(now: at(9, day: 7), lastMorningDay: nil), .run)
    }

    await Harness.test("schedule: next run") {
        expectEqual(try weekdays.nextRun(after: at(6)), at(7))                 // later today
        expectEqual(try weekdays.nextRun(after: at(7)), at(7, day: 5))         // exactly 7:00 → tomorrow
        expectEqual(try weekdays.nextRun(after: at(8, day: 6)), at(7, day: 9)) // Friday → Monday
        expectEqual(try everyDay.nextRun(after: at(8, day: 6)), at(7, day: 7)) // Friday → Saturday
    }

    await Harness.test("schedule: next run across the DST change stays at 7:00 local") {
        let next = try everyDay.nextRun(after: pacific.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 8))!)
        let components = pacific.dateComponents([.month, .day, .hour, .minute], from: next)
        expectEqual([components.month, components.day, components.hour, components.minute], [11, 1, 7, 0])
    }

    await Harness.test("schedule: a bad runAt is an error, not a silent skip") {
        let broken = ScheduleGuard(runAt: "7am", weekdaysOnly: true, calendar: pacific)
        expect((try? broken.decide(now: at(9), lastMorningDay: nil)) == nil)
        expect((try? broken.nextRun(after: at(9))) == nil)
    }

    await Harness.test("run state: only a written morning briefing counts as done") {
        var state = AgentState(pid: 1, version: "test", startedAt: at(6), permissions: [:])
        expect(state.lastMorningDay == nil)
        state.record(RunRecord(kind: .morning, day: "2026-11-04", startedAt: at(7), finishedAt: at(7), outcome: .failed))
        expect(state.lastMorningDay == nil, "a failed run doesn't count")
        state.record(RunRecord(kind: .manual, day: "2026-11-04", startedAt: at(7), finishedAt: at(7), outcome: .full))
        expect(state.lastMorningDay == nil, "a manual run doesn't count")
        state.record(RunRecord(kind: .morning, day: "2026-11-04", startedAt: at(7), finishedAt: at(7), outcome: .partial))
        expectEqual(state.lastMorningDay, "2026-11-04")
        expectEqual(state.lastRun(.manual)?.outcome, .full)
    }

    await Harness.test("run state survives a save/load round trip") {
        let paths = AppPaths(home: tempHome())
        var state = AgentState(pid: 1, version: "test", startedAt: at(6), permissions: ["calendars": "granted"])
        state.record(RunRecord(kind: .morning, day: "2026-11-04", startedAt: at(7), finishedAt: at(7, 1), outcome: .full))
        try state.save(paths: paths)
        expectEqual(AgentState.load(paths: paths)?.lastMorningDay, "2026-11-04")
    }

    await Harness.test("old state.json without run history still loads") {
        let paths = AppPaths(home: tempHome())
        try FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        try Data(#"{"pid": 7, "version": "0.2.0", "startedAt": "2026-11-04T15:00:00Z", "permissions": {}}"#.utf8).write(to: paths.state)
        let state = AgentState.load(paths: paths)
        expectEqual(state?.pid, 7)
        expect(state?.lastMorningDay == nil)
    }
}
