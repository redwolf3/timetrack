import XCTest
@testable import TimeTrackKit

// Tests for Store.recentReport(days:asOf:).
//
// Determinism: all tests inject a fixed `asOf` date so behaviour is independent
// of wall-clock now. Events are built with explicit `ts` values computed from
// `asOf`'s startOfDay, matching report(day:)'s own Calendar.current anchoring.
// "Past day" offsets keep every event in the past, so the report's
// min(endOfDay, now) closeTs clamps only today's open interval, not prior days.
final class RecentReportTests: XCTestCase {

    // MARK: - Helpers

    // Fixed reference point: noon on 2025-03-15 (a Saturday).
    // Noon means startOfDay is six hours in the past from asOf — today's events
    // before noon count; the open interval closes at "now" (asOf), not end-of-day.
    private let asOf: Date = {
        var comps = DateComponents()
        comps.year = 2025; comps.month = 3; comps.day = 15
        comps.hour = 12; comps.minute = 0; comps.second = 0
        return Calendar.current.date(from: comps)!
    }()

    private func makeStore() throws -> Store {
        let dir = try makeTmpDir()
        return try Store(url: dir.appendingPathComponent("test.db"))
    }

    private func makeTask(_ store: Store, name: String) throws -> Task {
        var t = Task(id: nil, name: name, code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        return t
    }

    // Append a start/stop block of `durationSec` seconds beginning at `startTs` (ms).
    private func appendBlock(_ store: Store, taskId: Int64,
                             startMs: Int64, durationSec: Int) throws {
        let endMs = startMs + Int64(durationSec) * 1_000
        try store.append(Event(
            id: nil, ts: startMs, type: EventType.start.rawValue,
            taskId: taskId, prevTaskId: nil,
            phaseId: nil, profileName: nil, extendMin: nil, comment: nil))
        try store.append(Event(
            id: nil, ts: endMs, type: EventType.stop.rawValue,
            taskId: nil, prevTaskId: taskId,
            phaseId: nil, profileName: nil, extendMin: nil, comment: nil))
    }

    // startOfDay for a date `daysAgo` before `asOf`.
    private func dayStart(daysAgo: Int) -> Date {
        let todayStart = Calendar.current.startOfDay(for: asOf)
        return Calendar.current.date(byAdding: .day, value: -daysAgo, to: todayStart)!
    }

    private func millisOf(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    // MARK: - 1. Count and ordering

    func testReturnsExactlyDaysEntries() throws {
        let store = try makeStore()
        let result = try store.recentReport(days: 3, asOf: asOf)
        XCTAssertEqual(result.count, 3, "must return exactly `days` entries")
    }

    func testOrderingMostRecentFirst() throws {
        let store = try makeStore()
        let result = try store.recentReport(days: 3, asOf: asOf)
        // result[0] == today, result[1] == yesterday, result[2] == day-before-yesterday
        XCTAssertEqual(result[0].day, dayStart(daysAgo: 0))
        XCTAssertEqual(result[1].day, dayStart(daysAgo: 1))
        XCTAssertEqual(result[2].day, dayStart(daysAgo: 2))
    }

    func testDaysOneReturnsOnlyToday() throws {
        let store = try makeStore()
        let result = try store.recentReport(days: 1, asOf: asOf)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].day, dayStart(daysAgo: 0))
    }

    // MARK: - 2. Empty day yields empty rows and zero total

    func testEmptyDayHasZeroTotals() throws {
        let store = try makeStore()
        let result = try store.recentReport(days: 3, asOf: asOf)
        // No events were appended — every entry should be empty.
        for summary in result {
            XCTAssertTrue(summary.rows.isEmpty,
                          "day \(summary.day) should have no rows; got \(summary.rows.count)")
            XCTAssertEqual(summary.totalSeconds, 0)
        }
    }

    // MARK: - 3. Task tracked yesterday appears under yesterday, not today

    func testYesterdayTaskAppearsUnderYesterdayNotToday() throws {
        let store = try makeStore()
        let task = try makeTask(store, name: "YesterdayWork")

        // One hour starting at 09:00 yesterday.
        let yesterdayStart = dayStart(daysAgo: 1)
        let startMs = millisOf(yesterdayStart) + 9 * 3_600_000
        try appendBlock(store, taskId: task.id!, startMs: startMs, durationSec: 3_600)

        let result = try store.recentReport(days: 3, asOf: asOf)
        let today     = result[0]
        let yesterday = result[1]

        // Today must be empty.
        XCTAssertTrue(today.rows.isEmpty, "today should have no rows")

        // Yesterday must have exactly one row with the task.
        XCTAssertEqual(yesterday.rows.count, 1)
        XCTAssertEqual(yesterday.rows[0].task.id, task.id)
        XCTAssertEqual(yesterday.rows[0].totalSeconds, 3_600)
    }

    // MARK: - 4. Totals match a direct report(day:) call

    func testTotalsMatchDirectReportCall() throws {
        let store = try makeStore()
        let task = try makeTask(store, name: "Verify")

        let yesterdayStart = dayStart(daysAgo: 1)
        let startMs = millisOf(yesterdayStart) + 2 * 3_600_000   // day−1 + 2h
        try appendBlock(store, taskId: task.id!, startMs: startMs, durationSec: 1_800) // 30 min

        // Direct call to report(day:) for yesterday.
        let directRows = try store.report(day: yesterdayStart)
        let directTotal = directRows.reduce(0) { $0 + $1.totalSeconds }

        // recentReport should agree.
        let result = try store.recentReport(days: 2, asOf: asOf)
        let yesterday = result[1]
        XCTAssertEqual(yesterday.totalSeconds, directTotal,
                       "recentReport total should equal report(day:) for the same day")
    }

    // MARK: - 5. Multi-task day: rows sorted desc by seconds, totalSeconds == sum

    func testMultiTaskDaySortedAndTotal() throws {
        let store = try makeStore()
        let taskA = try makeTask(store, name: "LongTask")
        let taskB = try makeTask(store, name: "ShortTask")

        let twoDaysAgo = dayStart(daysAgo: 2)
        let base = millisOf(twoDaysAgo)

        // taskA: 2 hours starting at 09:00
        try appendBlock(store, taskId: taskA.id!,
                        startMs: base + 9 * 3_600_000, durationSec: 7_200)
        // taskB: 30 minutes starting at 11:00
        try appendBlock(store, taskId: taskB.id!,
                        startMs: base + 11 * 3_600_000, durationSec: 1_800)

        let result = try store.recentReport(days: 3, asOf: asOf)
        let day = result[2]  // two days ago is index 2

        XCTAssertEqual(day.rows.count, 2)
        // Sorted descending: A (7200s) before B (1800s).
        XCTAssertEqual(day.rows[0].task.id, taskA.id, "LongTask should be first")
        XCTAssertEqual(day.rows[1].task.id, taskB.id, "ShortTask should be second")
        // totalSeconds == sum of rows.
        XCTAssertEqual(day.totalSeconds, 7_200 + 1_800)
        // computed totalSeconds == rows sum.
        let manualSum = day.rows.reduce(0) { $0 + $1.totalSeconds }
        XCTAssertEqual(day.totalSeconds, manualSum)
    }

    // MARK: - 6. Consecutive startOfDay values are one calendar day apart

    func testConsecutiveDatesAreOneDayApart() throws {
        let store = try makeStore()
        let result = try store.recentReport(days: 5, asOf: asOf)
        for i in 1 ..< result.count {
            let prev = result[i - 1].day
            let curr = result[i].day
            let diff = Calendar.current.dateComponents([.day], from: curr, to: prev).day
            XCTAssertEqual(diff, 1,
                "day[\(i-1)] and day[\(i)] should be exactly one calendar day apart; got \(diff ?? -99)")
        }
    }
}
