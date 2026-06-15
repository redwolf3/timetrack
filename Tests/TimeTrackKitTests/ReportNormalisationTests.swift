// Tests/TimeTrackKitTests/ReportNormalisationTests.swift
import XCTest
@testable import TimeTrackKit

// Tests for report-layer time normalisation added to Store.reconciledReport.
//
// Fixture strategy (mirrors ReconcileGateTests):
//   - All intervals on a FIXED PAST day (3 days ago) so closeTs = endOfDay.
//   - Tasks are created, bound to a non-provisional KnownTask with a real JIRA key,
//     so the reconcile gate always passes.
//   - appendBlock(store:taskId:startMs:durationSec:) creates closed start/stop pairs.
final class ReportNormalisationTests: XCTestCase {

    // MARK: - Shared fixture helpers

    // Fixed past day: always at least 3 days in the past so closeTs = endOfDay.
    private var pastDay: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: -3, to: today)!
    }

    private func makeStore() throws -> Store {
        let dir = try makeTmpDir()
        return try Store(url: dir.appendingPathComponent("test.db"))
    }

    // Create a project task and bind it to a non-provisional KnownTask.
    // Returns (taskId, jiraKey).
    private func makeTaskBound(
        _ store: Store,
        name: String,
        jiraKey: String
    ) throws -> (taskId: Int64, jiraKey: String) {
        var t = Task(id: nil, name: name, code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        let kt = try store.addKnownTask(jiraKey: jiraKey, description: name)
        try store.bind(taskId: t.id!, knownTaskId: kt.id!, comment: nil)
        return (t.id!, jiraKey)
    }

    // Append a closed start/stop block.
    private func appendBlock(
        _ store: Store,
        taskId: Int64,
        startMs: Int64,
        durationSec: Int
    ) throws {
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

    private func baseMs(_ day: Date) -> Int64 {
        Int64(day.timeIntervalSince1970 * 1_000)
    }

    // MARK: - Test 1: No-op defaults equal current totals (equivalence)

    func testNoOpDefaultsEqualCurrentTotals() throws {
        let store = try makeStore()
        let (taskId, _) = try makeTaskBound(store, name: "Work", jiraKey: "ABC-1")

        // 25 minutes = 1500 seconds
        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 1_500)

        let rows = try store.reconciledReport(
            from: pastDay, to: pastDay,
            dropBelowSec: 0, minIntervalMin: 0, roundToMin: 0)

        let row = try XCTUnwrap(rows.first(where: { $0.jiraKey == "ABC-1" }))
        XCTAssertEqual(row.totalSeconds, 1_500,
            "With all-zero normalisation params, totals must match raw windowSeconds")
    }

    // MARK: - Test 2: Per-interval drop and floor

    func testPerIntervalDropAndFloor() throws {
        let store = try makeStore()
        let (taskId, _) = try makeTaskBound(store, name: "Flicker", jiraKey: "FL-1")

        let base = baseMs(pastDay) + 9 * 3_600_000

        // Short interval: 20 seconds — below dropBelowSec=30 → dropped.
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 20)
        // Long interval: 45 seconds — survives, floored to minIntervalMin=1 → 60s.
        try appendBlock(store, taskId: taskId, startMs: base + 60_000, durationSec: 45)

        let rows = try store.reconciledReport(
            from: pastDay, to: pastDay,
            dropBelowSec: 30, minIntervalMin: 1, roundToMin: 0)

        let row = try XCTUnwrap(rows.first(where: { $0.jiraKey == "FL-1" }))
        // 20s dropped → 0. 45s survived, floored to 60s.
        XCTAssertEqual(row.totalSeconds, 60, "20s dropped, 45s floored to 60s")
    }

    // MARK: - Test 3: Non-contiguous tiny intervals evaluated separately

    func testNonContiguousTinyIntervalsEvaluatedSeparately() throws {
        let store = try makeStore()
        let (taskA, _) = try makeTaskBound(store, name: "A", jiraKey: "NC-A")
        let (taskB, _) = try makeTaskBound(store, name: "B", jiraKey: "NC-B")

        let base = baseMs(pastDay) + 10 * 3_600_000

        // A for 25s → below 30s → dropped.
        try appendBlock(store, taskId: taskA, startMs: base, durationSec: 25)
        // B for 60s (separator — breaks any contiguity for A).
        try appendBlock(store, taskId: taskB, startMs: base + 30_000, durationSec: 60)
        // A for 25s again → below 30s → dropped (non-contiguous with first A block).
        try appendBlock(store, taskId: taskA, startMs: base + 120_000, durationSec: 25)

        let rows = try store.reconciledReport(
            from: pastDay, to: pastDay,
            dropBelowSec: 30, minIntervalMin: 0, roundToMin: 0)

        // A's two 25s intervals are each < 30s → both dropped → A absent.
        let aRow = rows.first(where: { $0.jiraKey == "NC-A" })
        XCTAssertNil(aRow, "Non-contiguous 25s+25s intervals each drop independently")
        // B's 60s survives.
        let bRow = try XCTUnwrap(rows.first(where: { $0.jiraKey == "NC-B" }))
        XCTAssertEqual(bRow.totalSeconds, 60)
    }

    // MARK: - Test 4: Contiguous same-task segments merge before drop evaluation

    func testContiguousSameTaskSegmentsMerge() throws {
        let store = try makeStore()
        let (taskId, _) = try makeTaskBound(store, name: "Cont", jiraKey: "MRG-1")

        let base = baseMs(pastDay) + 8 * 3_600_000

        // Two adjacent same-task blocks (40s each) that merge into 80s.
        // If each were evaluated separately, both 40s < 60s dropBelowSec → both dropped.
        // After merge: 80s >= 60s → survives.
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 40)
        try appendBlock(store, taskId: taskId, startMs: base + 40_000, durationSec: 40)

        let rows = try store.reconciledReport(
            from: pastDay, to: pastDay,
            dropBelowSec: 60, minIntervalMin: 0, roundToMin: 0)

        let row = try XCTUnwrap(rows.first(where: { $0.jiraKey == "MRG-1" }))
        XCTAssertEqual(row.totalSeconds, 80,
            "Adjacent same-task blocks must merge before drop evaluation")
    }

    // MARK: - Test 5: idle_resolve reattribution at interval level

    func testIdleResolveReattributionAtIntervalLevel() throws {
        let store = try makeStore()
        let (taskA, _) = try makeTaskBound(store, name: "OrigTask", jiraKey: "IDLE-A")
        let (taskB, _) = try makeTaskBound(store, name: "NewTask",  jiraKey: "IDLE-B")

        let base = baseMs(pastDay) + 9 * 3_600_000

        // A active for 120s.
        try appendBlock(store, taskId: taskA, startMs: base, durationSec: 120)

        // Resolve the last 20s of that block from A to B.
        // With dropBelowSec=30: B's 20s segment is below threshold → dropped.
        // A's remaining 100s segment survives.
        let resolveStart = base + 100_000   // 100s into the block
        let resolveEnd   = base + 120_000
        try store.append(Event(
            id: nil, ts: resolveEnd + 1_000, type: EventType.idleResolve.rawValue,
            taskId: taskB, prevTaskId: taskA,
            phaseId: nil, profileName: nil, extendMin: nil, comment: nil,
            rangeStart: resolveStart, rangeEnd: resolveEnd))

        let rows = try store.reconciledReport(
            from: pastDay, to: pastDay,
            dropBelowSec: 30, minIntervalMin: 0, roundToMin: 0)

        let aRow = try XCTUnwrap(rows.first(where: { $0.jiraKey == "IDLE-A" }))
        let bRow = rows.first(where: { $0.jiraKey == "IDLE-B" })
        XCTAssertEqual(aRow.totalSeconds, 100, "A gets 100s after resolve reattributes last 20s")
        XCTAssertNil(bRow, "B's 20s interval < 30s drop threshold → dropped")
    }

    // MARK: - Test 6: Pass-2 per-key round-up

    func testPassTwoRoundUp() throws {
        // 25 minutes = 1500s. With quantum=15min=900s: 1500 → ceil to 1800 (30m).
        let store = try makeStore()
        let (taskId, _) = try makeTaskBound(store, name: "Rounder", jiraKey: "RND-1")
        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 1_500)

        var rows = try store.reconciledReport(
            from: pastDay, to: pastDay,
            dropBelowSec: 0, minIntervalMin: 0, roundToMin: 15)
        var row = try XCTUnwrap(rows.first(where: { $0.jiraKey == "RND-1" }))
        XCTAssertEqual(row.totalSeconds, 1_800, "25m → round up to 30m")

        // 31 minutes = 1860s → 45m (2700s).
        let store2 = try makeStore()
        let (taskId2, _) = try makeTaskBound(store2, name: "Rounder2", jiraKey: "RND-2")
        let base2 = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store2, taskId: taskId2, startMs: base2, durationSec: 1_860)

        rows = try store2.reconciledReport(
            from: pastDay, to: pastDay,
            dropBelowSec: 0, minIntervalMin: 0, roundToMin: 15)
        row = try XCTUnwrap(rows.first(where: { $0.jiraKey == "RND-2" }))
        XCTAssertEqual(row.totalSeconds, 2_700, "31m → round up to 45m")
    }

    // MARK: - Test 7: Two tasks on the same key → whole-window sum is sub-15 candidate

    func testTwoTasksSameKeyWholeWindowSubFifteen() throws {
        let store = try makeStore()

        // Two capture tasks both bound to the same KnownTask (JIRA key SAME-1).
        // Per-task totals are 480s and 240s; the per-key total is 720s (12 min)
        // which is below the 900s quantum — a sub-15 candidate, NOT rounded up.
        var t1 = Task(id: nil, name: "Part1", code: nil, category: "project", archived: false)
        t1 = try store.upsertTask(t1)
        var t2 = Task(id: nil, name: "Part2", code: nil, category: "project", archived: false)
        t2 = try store.upsertTask(t2)
        let kt = try store.addKnownTask(jiraKey: "SAME-1", description: "Shared")
        try store.bind(taskId: t1.id!, knownTaskId: kt.id!, comment: nil)
        try store.bind(taskId: t2.id!, knownTaskId: kt.id!, comment: nil)

        let base = baseMs(pastDay) + 9 * 3_600_000
        // t1: 8 min = 480s. t2: 4 min = 240s. Key total = 720s.
        try appendBlock(store, taskId: t1.id!, startMs: base, durationSec: 480)
        try appendBlock(store, taskId: t2.id!, startMs: base + 600_000, durationSec: 240)

        let rows = try store.reconciledReport(
            from: pastDay, to: pastDay,
            dropBelowSec: 0, minIntervalMin: 0, roundToMin: 15)

        // No resolution provided → sub-15 reported as-is at raw seconds.
        let row = try XCTUnwrap(rows.first(where: { $0.jiraKey == "SAME-1" }))
        XCTAssertEqual(row.totalSeconds, 720,
            "Sub-15 with no resolution is reported as-is (not rounded to 900)")
    }

    // MARK: - Test 8: subFifteenCandidates returns the sub-quantum key

    func testSubFifteenCandidatesReturnsSubFifteenKey() throws {
        let store = try makeStore()
        let (taskId, _) = try makeTaskBound(store, name: "Tiny", jiraKey: "TINY-1")

        let base = baseMs(pastDay) + 9 * 3_600_000
        // 720s (12 min) < 900s quantum → candidate.
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 720)

        let candidates = try store.subFifteenCandidates(
            from: pastDay, to: pastDay,
            dropBelowSec: 0, minIntervalMin: 0, roundToMin: 15)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.jiraKey, "TINY-1")
        XCTAssertEqual(candidates.first?.totalSeconds, 720)
    }

    // MARK: - Test 9a: recordAs15 resolution

    func testSubFifteenRecordAs15() throws {
        let store = try makeStore()
        let (taskId, _) = try makeTaskBound(store, name: "As15", jiraKey: "S15-1")

        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 720)

        let rows = try store.reconciledReport(
            from: pastDay, to: pastDay,
            dropBelowSec: 0, minIntervalMin: 0, roundToMin: 15,
            subFifteenResolutions: ["S15-1": .recordAs15])

        let row = try XCTUnwrap(rows.first(where: { $0.jiraKey == "S15-1" }))
        XCTAssertEqual(row.totalSeconds, 900, "recordAs15 → one quantum = 900s")
    }

    // MARK: - Test 9b: drop resolution

    func testSubFifteenDrop() throws {
        let store = try makeStore()
        let (taskId, _) = try makeTaskBound(store, name: "ToDrop", jiraKey: "DROP-1")

        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 720)

        let rows = try store.reconciledReport(
            from: pastDay, to: pastDay,
            dropBelowSec: 0, minIntervalMin: 0, roundToMin: 15,
            subFifteenResolutions: ["DROP-1": .drop])

        XCTAssertNil(rows.first(where: { $0.jiraKey == "DROP-1" }),
            "drop resolution → key absent from report")
    }

    // MARK: - Test 9c: rollIntoAggregate resolution

    func testSubFifteenRollIntoAggregate() throws {
        let store = try makeStore()
        let (taskId, _) = try makeTaskBound(store, name: "Roller", jiraKey: "ROLL-1")

        let base = baseMs(pastDay) + 9 * 3_600_000
        // 720s (12 min) → rolls into MISC bucket → MISC = 720s → rounds up to 900s.
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 720)

        let rows = try store.reconciledReport(
            from: pastDay, to: pastDay,
            dropBelowSec: 0, minIntervalMin: 0, roundToMin: 15,
            aggregateKey: "MISC",
            subFifteenResolutions: ["ROLL-1": .rollIntoAggregate])

        XCTAssertNil(rows.first(where: { $0.jiraKey == "ROLL-1" }),
            "Rolled key must be absent from report")
        let miscRow = try XCTUnwrap(rows.first(where: { $0.jiraKey == "MISC" }),
            "MISC aggregate bucket must appear")
        XCTAssertEqual(miscRow.totalSeconds, 900,
            "720s rolled in → rounds up to one 900s quantum")
    }

    // MARK: - Test M2: No-op reconciledReport equals report(day:) grand total when idle_resolve is present

    // Verifies that sliceTimeline (used by reconciledReport pass-1) and the
    // report(day:) subtract/add delta agree when an idle_resolve event
    // reattributes a sub-segment from one task to another. With all normalisation
    // disabled (dropBelowSec:0, minIntervalMin:0, roundToMin:0) the grand total
    // of reconciledReport must equal the grand total of report(day:) for the
    // same window, excluding break tasks.
    func testNoOpEqualsReportDayWithIdleResolve() throws {
        let store = try makeStore()
        let (taskA, jiraA) = try makeTaskBound(store, name: "OrigTask", jiraKey: "EQ-A")
        let (taskB, jiraB) = try makeTaskBound(store, name: "NewTask",  jiraKey: "EQ-B")

        let base = baseMs(pastDay) + 9 * 3_600_000

        // A is active for 180s.
        try appendBlock(store, taskId: taskA, startMs: base, durationSec: 180)

        // Resolve the last 60s of that block from A to B.
        // After reattribution: A = 120s, B = 60s. Grand total = 180s.
        let resolveStart = base + 120_000   // 120s into the block
        let resolveEnd   = base + 180_000
        try store.append(Event(
            id: nil, ts: resolveEnd + 1_000, type: EventType.idleResolve.rawValue,
            taskId: taskB, prevTaskId: taskA,
            phaseId: nil, profileName: nil, extendMin: nil, comment: nil,
            rangeStart: resolveStart, rangeEnd: resolveEnd))

        // reconciledReport with no normalisation.
        let reconciledRows = try store.reconciledReport(
            from: pastDay, to: pastDay,
            dropBelowSec: 0, minIntervalMin: 0, roundToMin: 0)
        let reconciledTotal = reconciledRows.reduce(0) { $0 + $1.totalSeconds }

        // report(day:) totals, summed across the two tasks (excluding breaks).
        let dayRows = try store.report(day: pastDay)
        let dayRowsByTaskId: [Int64: Int] = Dictionary(
            dayRows.compactMap { r -> (Int64, Int)? in
                guard r.task.category != "break", let tid = r.task.id else { return nil }
                return (tid, r.totalSeconds)
            },
            uniquingKeysWith: +)
        let dayTotalA = dayRowsByTaskId[taskA] ?? 0
        let dayTotalB = dayRowsByTaskId[taskB] ?? 0
        let reportDayTotal = dayTotalA + dayTotalB

        // Grand totals must match: reconciledReport (pass-1 via sliceTimeline) and
        // report(day:) (subtract/add delta) must agree when normalisation is off.
        XCTAssertEqual(reconciledTotal, reportDayTotal,
            "reconciledReport grand total (\(reconciledTotal)s) must equal " +
            "report(day:) grand total (\(reportDayTotal)s) when normalisation is disabled")

        // Also verify per-key totals match the expected reattribution.
        let reconciledA = reconciledRows.first(where: { $0.jiraKey == jiraA })?.totalSeconds ?? 0
        let reconciledB = reconciledRows.first(where: { $0.jiraKey == jiraB })?.totalSeconds ?? 0
        XCTAssertEqual(reconciledA, 120, "A should have 120s after reattribution")
        XCTAssertEqual(reconciledB, 60,  "B should have 60s after reattribution")
        XCTAssertEqual(dayTotalA, 120, "report(day:) A should have 120s after idle_resolve")
        XCTAssertEqual(dayTotalB, 60,  "report(day:) B should have 60s after idle_resolve")
    }

    // MARK: - Test 10: Gate still throws with normalisation params set

    func testGateThrowsUnboundWithNormalisationParams() throws {
        let store = try makeStore()
        // Task with time but NO binding — gate must throw .unbound.
        var t = Task(id: nil, name: "Unbound", code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: t.id!, startMs: base, durationSec: 1_500)

        XCTAssertThrowsError(try store.reconciledReport(
            from: pastDay, to: pastDay,
            dropBelowSec: 30, minIntervalMin: 1, roundToMin: 15)
        ) { error in
            guard case Store.ReconcileError.unbound = error else {
                XCTFail("Expected .unbound, got \(error)")
                return
            }
        }
    }
}
