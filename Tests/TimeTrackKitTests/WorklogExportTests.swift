import XCTest
@testable import TimeTrackKit

// Tests for Store.worklog(from:to:grain:includeUnreconciled:...), the primitive
// behind `timetrack export worklog` (docs/interchange-format.md §5).
//
// Fixture strategy (mirrors ReportNormalisationTests / ReconcileGateTests):
//   - All intervals on a FIXED PAST day (3 days ago) so closeTs = endOfDay and
//     an interval seeded at startOfDay+Nh is never clamped by "now".
//   - appendBlock(store:taskId:startMs:durationSec:) creates closed start/stop pairs.
final class WorklogExportTests: XCTestCase {

    // MARK: - Shared fixture helpers

    private var pastDay: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: -3, to: today)!
    }

    private func makeStore() throws -> Store {
        let dir = try makeTmpDir()
        return try Store(url: dir.appendingPathComponent("test.db"))
    }

    private func baseMs(_ day: Date) -> Int64 {
        Int64(day.timeIntervalSince1970 * 1_000)
    }

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

    // Create a project task and bind it to a non-provisional KnownTask.
    private func makeTaskBound(
        _ store: Store,
        name: String,
        jiraKey: String,
        description: String? = nil
    ) throws -> (taskId: Int64, knownTaskId: Int64) {
        var t = Task(id: nil, name: name, code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        let kt = try store.addKnownTask(jiraKey: jiraKey, description: description ?? name)
        try store.bind(taskId: t.id!, knownTaskId: kt.id!, comment: nil)
        return (t.id!, kt.id!)
    }

    // MARK: - Gate behavior

    func testDefaultThrowsUnboundWhenUnboundTimeExists() throws {
        let store = try makeStore()
        var t = Task(id: nil, name: "Loose", code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: t.id!, startMs: base, durationSec: 600)

        XCTAssertThrowsError(try store.worklog(
            from: pastDay, to: pastDay, grain: .day, includeUnreconciled: false)
        ) { error in
            guard case Store.ReconcileError.unbound(let tasks) = error else {
                return XCTFail("expected .unbound, got \(error)")
            }
            XCTAssertTrue(tasks.contains { $0.task.id == t.id })
        }
    }

    func testDefaultThrowsProvisionalWhenBoundToProvisionalKnownTask() throws {
        let store = try makeStore()
        var t = Task(id: nil, name: "WIP", code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        let kt = try store.addKnownTask(jiraKey: nil, description: "WIP entry")
        try store.bind(taskId: t.id!, knownTaskId: kt.id!, comment: nil)
        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: t.id!, startMs: base, durationSec: 600)

        XCTAssertThrowsError(try store.worklog(
            from: pastDay, to: pastDay, grain: .day, includeUnreconciled: false)
        ) { error in
            guard case Store.ReconcileError.provisional(let known) = error else {
                return XCTFail("expected .provisional, got \(error)")
            }
            XCTAssertTrue(known.contains { $0.id == kt.id })
        }
    }

    func testIncludeUnreconciledEmitsUnboundAndProvisionalRecords() throws {
        let store = try makeStore()

        var loose = Task(id: nil, name: "Loose", code: nil, category: "project", archived: false)
        loose = try store.upsertTask(loose)
        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: loose.id!, startMs: base, durationSec: 600)

        var wip = Task(id: nil, name: "WIP task", code: nil, category: "project", archived: false)
        wip = try store.upsertTask(wip)
        let kt = try store.addKnownTask(jiraKey: nil, description: "WIP entry")
        try store.bind(taskId: wip.id!, knownTaskId: kt.id!, comment: nil)
        try appendBlock(store, taskId: wip.id!, startMs: base + 3_600_000, durationSec: 600)

        let records = try store.worklog(
            from: pastDay, to: pastDay, grain: .day, includeUnreconciled: true)

        let unboundRecord = try XCTUnwrap(records.first { $0.status == .unbound })
        XCTAssertNil(unboundRecord.jiraKey)
        XCTAssertNil(unboundRecord.knownTaskId)
        XCTAssertEqual(unboundRecord.captureTasks, ["Loose"])
        XCTAssertEqual(unboundRecord.seconds, 600)

        let provisionalRecord = try XCTUnwrap(records.first { $0.status == .provisional })
        XCTAssertNil(provisionalRecord.jiraKey)
        XCTAssertEqual(provisionalRecord.knownTaskId, kt.id)
        XCTAssertEqual(provisionalRecord.description, "WIP entry")
        XCTAssertEqual(provisionalRecord.seconds, 600)
    }

    // MARK: - Reconciled export shape

    func testReconciledDayGrainBasics() throws {
        let store = try makeStore()
        let (taskId, ktId) = try makeTaskBound(store, name: "Widget", jiraKey: "PROJ-1", description: "Build the widget")
        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 1_500)

        let records = try store.worklog(
            from: pastDay, to: pastDay, grain: .day, includeUnreconciled: false)

        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.status, .reconciled)
        XCTAssertEqual(r.jiraKey, "PROJ-1")
        XCTAssertEqual(r.knownTaskId, ktId)
        XCTAssertEqual(r.description, "Build the widget")
        XCTAssertEqual(r.seconds, 1_500)
        XCTAssertEqual(r.rawSeconds, 1_500)
        XCTAssertEqual(r.captureTasks, ["Widget"])
        XCTAssertEqual(r.date, pastDay)
        XCTAssertNil(r.ended)
    }

    // Two capture tasks bound to the SAME known task on the same day must roll
    // into a single record whose capture_tasks lists both names.
    func testMultipleCaptureTasksRollIntoOneRecordPerKey() throws {
        let store = try makeStore()
        let kt = try store.addKnownTask(jiraKey: "PROJ-9", description: "Shared bucket")
        var t1 = Task(id: nil, name: "Alpha", code: nil, category: "project", archived: false)
        t1 = try store.upsertTask(t1)
        var t2 = Task(id: nil, name: "Beta", code: nil, category: "project", archived: false)
        t2 = try store.upsertTask(t2)
        try store.bind(taskId: t1.id!, knownTaskId: kt.id!, comment: nil)
        try store.bind(taskId: t2.id!, knownTaskId: kt.id!, comment: nil)

        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: t1.id!, startMs: base, durationSec: 300)
        try appendBlock(store, taskId: t2.id!, startMs: base + 3_600_000, durationSec: 300)

        let records = try store.worklog(
            from: pastDay, to: pastDay, grain: .day, includeUnreconciled: false)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].seconds, 600)
        XCTAssertEqual(records[0].captureTasks, ["Alpha", "Beta"])
    }

    // MARK: - Break time is never reportable, even under --include-unreconciled

    func testBreakTimeIsExcludedEvenWhenUnreconciledIncluded() throws {
        let store = try makeStore()
        var breakTask = Task(id: nil, name: "Break", code: nil, category: "break", archived: false)
        breakTask = try store.upsertTask(breakTask)
        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: breakTask.id!, startMs: base, durationSec: 300)

        let records = try store.worklog(
            from: pastDay, to: pastDay, grain: .day, includeUnreconciled: true)
        XCTAssertTrue(records.isEmpty, "break time must never appear in worklog export")
    }

    // MARK: - Grain: --by key aggregates across the whole window

    func testByKeyGrainAggregatesAcrossDays() throws {
        let store = try makeStore()
        let (taskId, _) = try makeTaskBound(store, name: "Widget", jiraKey: "PROJ-1")
        let day1 = pastDay
        let day2 = Calendar.current.date(byAdding: .day, value: 1, to: pastDay)!

        try appendBlock(store, taskId: taskId, startMs: baseMs(day1) + 9 * 3_600_000, durationSec: 600)
        try appendBlock(store, taskId: taskId, startMs: baseMs(day2) + 9 * 3_600_000, durationSec: 900)

        let byDay = try store.worklog(from: day1, to: day2, grain: .day, includeUnreconciled: false)
        XCTAssertEqual(byDay.count, 2, "day grain keeps one record per (day, key)")
        XCTAssertEqual(Set(byDay.compactMap { $0.date }), Set([day1, day2]))

        let byKey = try store.worklog(from: day1, to: day2, grain: .key, includeUnreconciled: false)
        XCTAssertEqual(byKey.count, 1, "key grain merges across the whole window")
        XCTAssertEqual(byKey[0].seconds, 1_500)
        XCTAssertNil(byKey[0].date)
    }

    // MARK: - Grain: --by interval is lossless and unnormalised

    func testByIntervalGrainSkipsNormalisationAndIsLossless() throws {
        let store = try makeStore()
        let (taskId, _) = try makeTaskBound(store, name: "Flicker", jiraKey: "FL-1")
        let base = baseMs(pastDay) + 9 * 3_600_000

        // Two short intervals that pass1 drop/floor WOULD alter at day/key grain.
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 5)
        try appendBlock(store, taskId: taskId, startMs: base + 60_000, durationSec: 5)

        let records = try store.worklog(
            from: pastDay, to: pastDay, grain: .interval, includeUnreconciled: false,
            dropBelowSec: 30, minIntervalMin: 1, roundToMin: 15)

        XCTAssertEqual(records.count, 2, "interval grain is lossless — one record per raw interval")
        for r in records {
            XCTAssertEqual(r.seconds, r.rawSeconds, "normalisation must not apply at --by interval")
            XCTAssertEqual(r.seconds, 5)
            XCTAssertNotNil(r.ended)
        }
    }

    // MARK: - Normalisation parity with reconciledReport at day/key grain

    func testPassOneDropAndFloorMatchReconciledReport() throws {
        let store = try makeStore()
        let (taskId, _) = try makeTaskBound(store, name: "Flicker", jiraKey: "FL-1")
        let base = baseMs(pastDay) + 9 * 3_600_000

        // 20s: below dropBelowSec=30 → dropped from credited seconds (but still
        // counted in raw_seconds, the audit total).
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 20)
        // 45s: survives, floored to minIntervalMin=1 → 60s credited.
        try appendBlock(store, taskId: taskId, startMs: base + 60_000, durationSec: 45)

        let records = try store.worklog(
            from: pastDay, to: pastDay, grain: .day, includeUnreconciled: false,
            dropBelowSec: 30, minIntervalMin: 1, roundToMin: 0)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].seconds, 60)
        XCTAssertEqual(records[0].rawSeconds, 65, "raw_seconds is the pre-normalisation truth: 20s + 45s")

        let reconciled = try store.reconciledReport(
            from: pastDay, to: pastDay, dropBelowSec: 30, minIntervalMin: 1, roundToMin: 0)
        XCTAssertEqual(reconciled.first(where: { $0.jiraKey == "FL-1" })?.totalSeconds, records[0].seconds,
            "export's normalised total must agree with reconciledReport for the same window/params")
    }

    func testPassTwoRoundingMatchesReconciledReport() throws {
        let store = try makeStore()
        let (taskId, _) = try makeTaskBound(store, name: "Round", jiraKey: "RND-1")
        let base = baseMs(pastDay) + 9 * 3_600_000
        // 25 minutes → rounds up to 30 with a 15-minute quantum.
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 25 * 60)

        let records = try store.worklog(
            from: pastDay, to: pastDay, grain: .day, includeUnreconciled: false,
            roundToMin: 15)
        XCTAssertEqual(records[0].seconds, 30 * 60)
        XCTAssertEqual(records[0].rawSeconds, 25 * 60)

        let reconciled = try store.reconciledReport(from: pastDay, to: pastDay, roundToMin: 15)
        XCTAssertEqual(reconciled.first(where: { $0.jiraKey == "RND-1" })?.totalSeconds, records[0].seconds)
    }

    // Sub-quantum totals are reported as-is — export never resolves sub-15 keys (§5.5).
    func testSubQuantumTotalReportedAsIsWithoutRounding() throws {
        let store = try makeStore()
        let (taskId, _) = try makeTaskBound(store, name: "Tiny", jiraKey: "TINY-1")
        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 300)   // 5 min

        let records = try store.worklog(
            from: pastDay, to: pastDay, grain: .day, includeUnreconciled: false,
            roundToMin: 15)
        XCTAssertEqual(records[0].seconds, 300, "below the 15-minute quantum: reported as-is, no silent rounding")
    }
}
