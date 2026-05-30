import XCTest
@testable import TimeTrackKit

// Tests for idle_resolve reattribution math in Store.report(day:).
//
// All tests use past days (yesterday or earlier) so that closeTs = min(endMs, now) = endMs,
// ensuring corrections are never clamped by the current time.
final class IdleReattributionTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(in dir: URL) throws -> Store {
        try Store(url: dir.appendingPathComponent("events.db"))
    }

    // Returns the start of the day N days before today (always in the past).
    private func pastDay(daysAgo: Int) -> Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: -daysAgo, to: today)!
    }

    private func baseMillis(_ day: Date) -> Int64 {
        Int64(day.timeIntervalSince1970 * 1_000)
    }

    // MARK: - 1. Resolved segment subtracts from original and adds to target

    func testResolvedSegmentSubtractsFromOriginalAndAddsToTarget() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        var taskA = Task(id: nil, name: "TaskA", code: nil, category: "project", archived: false)
        taskA = try store.upsertTask(taskA)
        var taskB = Task(id: nil, name: "TaskB", code: nil, category: "project", archived: false)
        taskB = try store.upsertTask(taskB)

        let day = pastDay(daysAgo: 1)
        let base = baseMillis(day)
        let h1 = base + 3_600_000   // day+1h
        let h2 = base + 7_200_000   // day+2h
        let h3 = base + 10_800_000  // day+3h

        // A active [day+1h, day+3h] = 2h
        try store.append(Event(id: nil, ts: h1, type: EventType.start.rawValue,
            taskId: taskA.id!, prevTaskId: nil, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))
        try store.append(Event(id: nil, ts: h3, type: EventType.stop.rawValue,
            taskId: nil, prevTaskId: nil, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))

        // Resolve [day+2h, day+3h] from A to B
        try store.append(Event(id: nil, ts: h3 + 1_000, type: EventType.idleResolve.rawValue,
            taskId: taskB.id!, prevTaskId: taskA.id!,
            phaseId: nil, profileName: nil, extendMin: nil, comment: nil,
            rangeStart: h2, rangeEnd: h3))

        let rows = try store.report(day: day)
        let seconds = Dictionary(uniqueKeysWithValues: rows.map { ($0.task.id!, $0.totalSeconds) })

        XCTAssertEqual(seconds[taskA.id!] ?? 0, 3_600, "A should have 1h after losing 1h to B")
        XCTAssertEqual(seconds[taskB.id!] ?? 0, 3_600, "B should gain the 1h resolved from A")
    }

    // MARK: - 2. Discarded segment subtracts from original and adds to nothing

    func testDiscardedSegmentSubtractsFromOriginalAddsToNothing() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        var taskA = Task(id: nil, name: "TaskA", code: nil, category: "project", archived: false)
        taskA = try store.upsertTask(taskA)

        let day = pastDay(daysAgo: 1)
        let base = baseMillis(day)
        let h1 = base + 3_600_000   // day+1h
        let h2 = base + 7_200_000   // day+2h
        let h3 = base + 10_800_000  // day+3h

        // A active [day+1h, day+3h] = 2h
        try store.append(Event(id: nil, ts: h1, type: EventType.start.rawValue,
            taskId: taskA.id!, prevTaskId: nil, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))
        try store.append(Event(id: nil, ts: h3, type: EventType.stop.rawValue,
            taskId: nil, prevTaskId: nil, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))

        // Discard [day+1h, day+2h] from A (taskId = nil)
        try store.append(Event(id: nil, ts: h3 + 1_000, type: EventType.idleResolve.rawValue,
            taskId: nil, prevTaskId: taskA.id!,
            phaseId: nil, profileName: nil, extendMin: nil, comment: nil,
            rangeStart: h1, rangeEnd: h2))

        let rows = try store.report(day: day)
        let seconds = Dictionary(uniqueKeysWithValues: rows.map { ($0.task.id!, $0.totalSeconds) })

        XCTAssertEqual(seconds[taskA.id!] ?? 0, 3_600, "A should have 1h after discarding 1h")
        let otherTotal = rows
            .filter { $0.task.id != taskA.id }
            .reduce(0) { $0 + $1.totalSeconds }
        XCTAssertEqual(otherTotal, 0, "No other task should receive the discarded time")
    }

    // MARK: - 3. Midnight-straddling segment clamps per day

    func testMidnightStraddlingSegmentClampsPerDay() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        var taskA = Task(id: nil, name: "TaskA", code: nil, category: "project", archived: false)
        taskA = try store.upsertTask(taskA)
        var taskB = Task(id: nil, name: "TaskB", code: nil, category: "project", archived: false)
        taskB = try store.upsertTask(taskB)

        // Use 2 days ago and yesterday so both days are fully in the past.
        let day1 = pastDay(daysAgo: 2)
        let day2 = pastDay(daysAgo: 1)

        let day1Base = baseMillis(day1)
        let day2Base = baseMillis(day2)

        // A active from day1+23h to day2+1h (crosses midnight, 2h total — 1h each side).
        let startTs  = day1Base + 23 * 3_600_000  // day1+23h
        let stopTs   = day2Base +  1 * 3_600_000  // day2+1h

        try store.append(Event(id: nil, ts: startTs, type: EventType.start.rawValue,
            taskId: taskA.id!, prevTaskId: nil, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))
        try store.append(Event(id: nil, ts: stopTs, type: EventType.stop.rawValue,
            taskId: nil, prevTaskId: nil, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))

        // Resolve the full 2h window [day1+23h, day2+1h] from A to B.
        // report() clamps each day's portion to [startOfDay, endOfDay] independently.
        try store.append(Event(id: nil, ts: stopTs + 1_000, type: EventType.idleResolve.rawValue,
            taskId: taskB.id!, prevTaskId: taskA.id!,
            phaseId: nil, profileName: nil, extendMin: nil, comment: nil,
            rangeStart: startTs, rangeEnd: stopTs))

        // day1: walk attributes 1h [23h, midnight] to A; resolve clamps to same → A=0, B=1h
        let rowsDay1 = try store.report(day: day1)
        let secDay1 = Dictionary(uniqueKeysWithValues: rowsDay1.map { ($0.task.id!, $0.totalSeconds) })
        XCTAssertEqual(secDay1[taskA.id!] ?? 0, 0,     "A should have 0s on day1 after full resolve")
        XCTAssertEqual(secDay1[taskB.id!] ?? 0, 3_600, "B should have 1h on day1 from clamped resolve")

        // day2: walk attributes 1h [midnight, 1h] to A (carry-forward from prior event); resolve clamps to same → A=0, B=1h
        let rowsDay2 = try store.report(day: day2)
        let secDay2 = Dictionary(uniqueKeysWithValues: rowsDay2.map { ($0.task.id!, $0.totalSeconds) })
        XCTAssertEqual(secDay2[taskA.id!] ?? 0, 0,     "A should have 0s on day2 after full resolve")
        XCTAssertEqual(secDay2[taskB.id!] ?? 0, 3_600, "B should have 1h on day2 from clamped resolve")

        // Sanity: total across both days = 2h, all on B.
        let totalA = (secDay1[taskA.id!] ?? 0) + (secDay2[taskA.id!] ?? 0)
        let totalB = (secDay1[taskB.id!] ?? 0) + (secDay2[taskB.id!] ?? 0)
        XCTAssertEqual(totalA, 0,     "A total across both days should be 0")
        XCTAssertEqual(totalB, 7_200, "B total across both days should be 2h")
    }

    // MARK: - 4. Multi-day window totals are correct

    func testMultiDayWindowTotalsAreCorrect() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        var taskA = Task(id: nil, name: "TaskA", code: nil, category: "project", archived: false)
        taskA = try store.upsertTask(taskA)
        var taskB = Task(id: nil, name: "TaskB", code: nil, category: "project", archived: false)
        taskB = try store.upsertTask(taskB)

        // Use 2 days ago and yesterday so both days are fully in the past.
        let day1 = pastDay(daysAgo: 2)
        let day2 = pastDay(daysAgo: 1)

        let d1Base = baseMillis(day1)
        let d2Base = baseMillis(day2)

        // Day 1: A active 2h [day1+1h, day1+3h]
        let d1Start = d1Base + 3_600_000
        let d1Stop  = d1Base + 10_800_000
        try store.append(Event(id: nil, ts: d1Start, type: EventType.start.rawValue,
            taskId: taskA.id!, prevTaskId: nil, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))
        try store.append(Event(id: nil, ts: d1Stop, type: EventType.stop.rawValue,
            taskId: nil, prevTaskId: nil, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))

        // Day 1 resolve: move [day1+2h, day1+3h] from A to B (1h).
        // Placed 1s before the stop so the stop is the last event before day2;
        // activeTaskFromPrior(stop) → nil, so no phantom carry-forward to day2.
        let d1ResolveStart = d1Base + 7_200_000
        let d1ResolveEnd   = d1Base + 10_800_000
        try store.append(Event(id: nil, ts: d1Stop - 1_000, type: EventType.idleResolve.rawValue,
            taskId: taskB.id!, prevTaskId: taskA.id!,
            phaseId: nil, profileName: nil, extendMin: nil, comment: nil,
            rangeStart: d1ResolveStart, rangeEnd: d1ResolveEnd))

        // Day 2: A active 3h [day2+1h, day2+4h], no resolve
        let d2Start = d2Base + 3_600_000
        let d2Stop  = d2Base + 14_400_000
        try store.append(Event(id: nil, ts: d2Start, type: EventType.start.rawValue,
            taskId: taskA.id!, prevTaskId: nil, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))
        try store.append(Event(id: nil, ts: d2Stop, type: EventType.stop.rawValue,
            taskId: nil, prevTaskId: nil, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))

        let rowsDay1 = try store.report(day: day1)
        let secDay1 = Dictionary(uniqueKeysWithValues: rowsDay1.map { ($0.task.id!, $0.totalSeconds) })
        let rowsDay2 = try store.report(day: day2)
        let secDay2 = Dictionary(uniqueKeysWithValues: rowsDay2.map { ($0.task.id!, $0.totalSeconds) })

        // Day 1: A=1h, B=1h
        XCTAssertEqual(secDay1[taskA.id!] ?? 0, 3_600,  "Day1 A should be 1h after resolve")
        XCTAssertEqual(secDay1[taskB.id!] ?? 0, 3_600,  "Day1 B should be 1h from resolve")

        // Day 2: A=3h, B=0h
        XCTAssertEqual(secDay2[taskA.id!] ?? 0, 10_800, "Day2 A should be 3h (no resolve)")
        XCTAssertEqual(secDay2[taskB.id!] ?? 0, 0,      "Day2 B should have 0s")

        // Summed totals: A=4h, B=1h
        let totalA = (secDay1[taskA.id!] ?? 0) + (secDay2[taskA.id!] ?? 0)
        let totalB = (secDay1[taskB.id!] ?? 0) + (secDay2[taskB.id!] ?? 0)
        XCTAssertEqual(totalA, 14_400, "A total across both days should be 4h")
        XCTAssertEqual(totalB,  3_600, "B total across both days should be 1h")
    }

    // MARK: - 5. Two non-overlapping resolves on the same task are independent

    func testTwoNonOverlappingResolvesAreEachApplied() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        var taskA = Task(id: nil, name: "TaskA", code: nil, category: "project", archived: false)
        taskA = try store.upsertTask(taskA)
        var taskB = Task(id: nil, name: "TaskB", code: nil, category: "project", archived: false)
        taskB = try store.upsertTask(taskB)

        let day = pastDay(daysAgo: 1)
        let base = baseMillis(day)
        let h0 = base                    // day+0h (midnight)
        let h1 = base + 3_600_000        // day+1h
        let h2 = base + 7_200_000        // day+2h
        let h3 = base + 10_800_000       // day+3h
        let h4 = base + 14_400_000       // day+4h

        // A active [day+0h+1s, day+4h] = ~4h
        try store.append(Event(id: nil, ts: h0 + 1_000, type: EventType.start.rawValue,
            taskId: taskA.id!, prevTaskId: nil, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))
        try store.append(Event(id: nil, ts: h4, type: EventType.stop.rawValue,
            taskId: nil, prevTaskId: nil, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))

        // Resolve [day+0h, day+1h] from A to B (1h)
        try store.append(Event(id: nil, ts: h4 + 1_000, type: EventType.idleResolve.rawValue,
            taskId: taskB.id!, prevTaskId: taskA.id!,
            phaseId: nil, profileName: nil, extendMin: nil, comment: nil,
            rangeStart: h0, rangeEnd: h1))

        // Resolve [day+2h, day+3h] from A to B (another 1h, non-overlapping)
        try store.append(Event(id: nil, ts: h4 + 2_000, type: EventType.idleResolve.rawValue,
            taskId: taskB.id!, prevTaskId: taskA.id!,
            phaseId: nil, profileName: nil, extendMin: nil, comment: nil,
            rangeStart: h2, rangeEnd: h3))

        let rows = try store.report(day: day)
        let seconds = Dictionary(uniqueKeysWithValues: rows.map { ($0.task.id!, $0.totalSeconds) })

        // A started 1s past midnight, so walked ~4h - 1s ≈ 14399s.
        // Two 1h resolves subtract 7200s → A ≈ 7199s.
        // B gains 7200s from the two resolves.
        // Allow ±1s tolerance for the 1-second start offset.
        let aSeconds = seconds[taskA.id!] ?? 0
        let bSeconds = seconds[taskB.id!] ?? 0
        XCTAssertEqual(aSeconds, 7_199, "A should have ~2h after two 1h resolves (minus 1s start offset)")
        XCTAssertEqual(bSeconds, 7_200, "B should have 2h from two non-overlapping resolves")
    }
}
