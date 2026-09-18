// Tests/TimeTrackKitTests/WorklogExportTests.swift
import XCTest
@testable import TimeTrackKit

// Tests for Store.worklog (docs/interchange-format.md §5, issue #59 Phase B).
// Fixture strategy mirrors ReportNormalisationTests: all intervals on a fixed
// PAST day (or two) so closeTs never clips an interval short.
final class WorklogExportTests: XCTestCase {

    // MARK: - Shared fixture helpers

    private var pastDay: Date {
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: -5, to: today)!
    }

    private var pastDayMinus1: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: pastDay)!
    }

    private func makeStore() throws -> Store {
        let dir = try makeTmpDir()
        return try Store(url: dir.appendingPathComponent("test.db"))
    }

    @discardableResult
    private func makeTaskBound(
        _ store: Store, name: String, jiraKey: String
    ) throws -> Int64 {
        var t = Task(id: nil, name: name, code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        let kt = try store.addKnownTask(jiraKey: jiraKey, description: name)
        try store.bind(taskId: t.id!, knownTaskId: kt.id!, comment: nil)
        return t.id!
    }

    @discardableResult
    private func makeTaskProvisional(
        _ store: Store, name: String, description: String
    ) throws -> (taskId: Int64, knownTaskId: Int64) {
        var t = Task(id: nil, name: name, code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        let kt = try store.addKnownTask(jiraKey: nil, description: description)
        try store.bind(taskId: t.id!, knownTaskId: kt.id!, comment: nil)
        return (t.id!, kt.id!)
    }

    @discardableResult
    private func makeUnboundTask(_ store: Store, name: String) throws -> Int64 {
        var t = Task(id: nil, name: name, code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        return t.id!
    }

    private func appendBlock(
        _ store: Store, taskId: Int64, startMs: Int64, durationSec: Int
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

    // MARK: - Basic day-grain record

    func testBasicDayGrainRecord() throws {
        let store = try makeStore()
        let taskId = try makeTaskBound(store, name: "Widget", jiraKey: "PROJ-1")
        let start = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: taskId, startMs: start, durationSec: 1_500)

        let records = try store.worklog(from: pastDay, to: pastDay)
        XCTAssertEqual(records.count, 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.jiraKey, "PROJ-1")
        XCTAssertEqual(r.status, .reconciled)
        XCTAssertEqual(r.seconds, 1_500)
        XCTAssertEqual(r.rawSeconds, 1_500)
        XCTAssertEqual(r.captureTasks, ["Widget"])
        XCTAssertEqual(r.date, pastDay)
        XCTAssertEqual(Int64(r.started.timeIntervalSince1970 * 1_000), start)
        XCTAssertNil(r.ended, "ended is only populated at --by interval grain")
    }

    // MARK: - Multiple capture tasks on the same key/day merge into one record

    func testMultipleCaptureTasksSameKeySameDayMerge() throws {
        let store = try makeStore()
        var t1 = Task(id: nil, name: "Part1", code: nil, category: "project", archived: false)
        t1 = try store.upsertTask(t1)
        var t2 = Task(id: nil, name: "Part2", code: nil, category: "project", archived: false)
        t2 = try store.upsertTask(t2)
        let kt = try store.addKnownTask(jiraKey: "SAME-1", description: "Shared")
        try store.bind(taskId: t1.id!, knownTaskId: kt.id!, comment: nil)
        try store.bind(taskId: t2.id!, knownTaskId: kt.id!, comment: nil)

        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: t1.id!, startMs: base, durationSec: 300)
        try appendBlock(store, taskId: t2.id!, startMs: base + 600_000, durationSec: 200)

        let records = try store.worklog(from: pastDay, to: pastDay)
        XCTAssertEqual(records.count, 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.seconds, 500)
        XCTAssertEqual(r.captureTasks, ["Part1", "Part2"], "first-seen chronological order")
        XCTAssertEqual(Int64(r.started.timeIntervalSince1970 * 1_000), base,
            "started is the earliest contributing interval")
    }

    // MARK: - --by key aggregates across days; date is nil

    func testByKeyAggregatesAcrossDays() throws {
        let store = try makeStore()
        let taskId = try makeTaskBound(store, name: "Widget", jiraKey: "PROJ-1")
        try appendBlock(store, taskId: taskId, startMs: baseMs(pastDayMinus1) + 9 * 3_600_000, durationSec: 300)
        try appendBlock(store, taskId: taskId, startMs: baseMs(pastDay) + 9 * 3_600_000, durationSec: 300)

        let records = try store.worklog(from: pastDayMinus1, to: pastDay, by: .key)
        XCTAssertEqual(records.count, 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertNil(r.date, "date is null for --by key")
        XCTAssertEqual(r.seconds, 600)
    }

    // MARK: - --by interval: lossless, no normalisation, one record per interval

    func testByIntervalIsLosslessAndUnnormalised() throws {
        let store = try makeStore()
        let taskId = try makeTaskBound(store, name: "Flicker", jiraKey: "FL-1")
        let base = baseMs(pastDay) + 9 * 3_600_000
        // 5s interval — would be dropped by dropBelowSec at day/key grain, but
        // --by interval must ignore normalisation entirely (§5.1).
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 5)
        try appendBlock(store, taskId: taskId, startMs: base + 60_000, durationSec: 45)

        let records = try store.worklog(
            from: pastDay, to: pastDay, by: .interval,
            dropBelowSec: 30, minIntervalMin: 1, roundToMin: 15)

        XCTAssertEqual(records.count, 2, "one record per raw interval, no drop/floor/round")
        XCTAssertEqual(records.map { $0.seconds }.sorted(), [5, 45])
        XCTAssertEqual(records.map { $0.rawSeconds }.sorted(), [5, 45])
        for r in records {
            XCTAssertEqual(r.seconds, r.rawSeconds, "raw_seconds == seconds at interval grain")
            XCTAssertNotNil(r.ended)
        }
    }

    // MARK: - Gate: unbound time blocks export by default

    func testGateThrowsUnboundByDefault() throws {
        let store = try makeStore()
        let taskId = try makeUnboundTask(store, name: "Stray")
        try appendBlock(store, taskId: taskId, startMs: baseMs(pastDay) + 9 * 3_600_000, durationSec: 300)

        XCTAssertThrowsError(try store.worklog(from: pastDay, to: pastDay)) { error in
            guard case Store.ReconcileError.unbound(let tasks) = error else {
                XCTFail("expected .unbound, got \(error)"); return
            }
            XCTAssertEqual(tasks.first?.task.name, "Stray")
        }
    }

    // MARK: - Gate: provisional-with-time blocks export by default

    func testGateThrowsProvisionalByDefault() throws {
        let store = try makeStore()
        let (taskId, _) = try makeTaskProvisional(store, name: "Misc", description: "Misc work")
        try appendBlock(store, taskId: taskId, startMs: baseMs(pastDay) + 9 * 3_600_000, durationSec: 300)

        XCTAssertThrowsError(try store.worklog(from: pastDay, to: pastDay)) { error in
            guard case Store.ReconcileError.provisional(let known) = error else {
                XCTFail("expected .provisional, got \(error)"); return
            }
            XCTAssertEqual(known.first?.description, "Misc work")
        }
    }

    // MARK: - includeUnreconciled: emits unbound/provisional records instead of throwing

    func testIncludeUnreconciledEmitsUnboundAndProvisional() throws {
        let store = try makeStore()
        let strayId = try makeUnboundTask(store, name: "Stray")
        let (miscId, miscKnownId) = try makeTaskProvisional(store, name: "Misc", description: "Misc work")
        let reconciledId = try makeTaskBound(store, name: "Widget", jiraKey: "PROJ-1")

        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: strayId, startMs: base, durationSec: 300)
        try appendBlock(store, taskId: miscId, startMs: base + 400_000, durationSec: 300)
        try appendBlock(store, taskId: reconciledId, startMs: base + 800_000, durationSec: 300)

        let records = try store.worklog(from: pastDay, to: pastDay, includeUnreconciled: true)
        XCTAssertEqual(records.count, 3)

        let stray = try XCTUnwrap(records.first { $0.captureTasks.contains("Stray") })
        XCTAssertEqual(stray.status, .unbound)
        XCTAssertNil(stray.jiraKey)
        XCTAssertNil(stray.knownTaskId)
        XCTAssertNil(stray.description)

        let misc = try XCTUnwrap(records.first { $0.captureTasks.contains("Misc") })
        XCTAssertEqual(misc.status, .provisional)
        XCTAssertNil(misc.jiraKey)
        XCTAssertEqual(misc.knownTaskId, miscKnownId)
        XCTAssertEqual(misc.description, "Misc work")

        let widget = try XCTUnwrap(records.first { $0.captureTasks.contains("Widget") })
        XCTAssertEqual(widget.status, .reconciled)
        XCTAssertEqual(widget.jiraKey, "PROJ-1")
    }

    // MARK: - Break time is excluded

    func testBreakTimeExcluded() throws {
        let store = try makeStore()
        var breakTask = Task(id: nil, name: "Break", code: nil, category: "break", archived: false)
        breakTask = try store.upsertTask(breakTask)
        let taskId = try makeTaskBound(store, name: "Widget", jiraKey: "PROJ-1")

        let base = baseMs(pastDay) + 9 * 3_600_000
        try appendBlock(store, taskId: breakTask.id!, startMs: base, durationSec: 300)
        try appendBlock(store, taskId: taskId, startMs: base + 400_000, durationSec: 300)

        let records = try store.worklog(from: pastDay, to: pastDay, includeUnreconciled: true)
        XCTAssertEqual(records.count, 1, "break-task interval must not appear as its own record")
        XCTAssertEqual(records.first?.jiraKey, "PROJ-1")
    }

    // MARK: - Per-day normalisation: sub-quantum stays sub-quantum per day, not summed first

    func testPerDayRoundingDoesNotSumAcrossDaysFirst() throws {
        // Two separate days, each 600s (10 min) — each is individually below a
        // 900s (15 min) quantum, so each day's record stays raw (600s), even
        // though the WINDOW total (1200s) would round up to 1800s under
        // reconciledReport's single whole-window bucket. Documents §5.4.1.
        let store = try makeStore()
        let taskId = try makeTaskBound(store, name: "Widget", jiraKey: "PROJ-1")
        try appendBlock(store, taskId: taskId, startMs: baseMs(pastDayMinus1) + 9 * 3_600_000, durationSec: 600)
        try appendBlock(store, taskId: taskId, startMs: baseMs(pastDay) + 9 * 3_600_000, durationSec: 600)

        let records = try store.worklog(
            from: pastDayMinus1, to: pastDay, by: .day, roundToMin: 15)

        XCTAssertEqual(records.count, 2)
        for r in records {
            XCTAssertEqual(r.seconds, 600, "sub-quantum day stays raw, unresolved, no forced rounding")
        }
    }

    // MARK: - drop-below-sec / min-interval-min applied per interval before grouping

    func testDropAndFloorAppliedPerIntervalWithinGroup() throws {
        let store = try makeStore()
        let taskId = try makeTaskBound(store, name: "Widget", jiraKey: "PROJ-1")
        let base = baseMs(pastDay) + 9 * 3_600_000
        // 20s — below dropBelowSec=30 → dropped entirely.
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 20)
        // 45s — survives, floored to minIntervalMin=1 (60s).
        try appendBlock(store, taskId: taskId, startMs: base + 60_000, durationSec: 45)

        let records = try store.worklog(
            from: pastDay, to: pastDay, dropBelowSec: 30, minIntervalMin: 1)
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.seconds, 60, "20s dropped, 45s floored to 60s")
        XCTAssertEqual(r.rawSeconds, 65, "raw_seconds is the untouched sum (20 + 45)")
    }

    // MARK: - aggregate-key force-rounds even sub-quantum credited time

    func testAggregateKeyForceRoundsSubQuantum() throws {
        let store = try makeStore()
        let taskId = try makeTaskBound(store, name: "Misc catch-all", jiraKey: "MISC")
        let base = baseMs(pastDay) + 9 * 3_600_000
        // 300s (5 min) directly tracked under the aggregate key — sub-quantum
        // (900s), but the aggregate bucket always force-rounds when non-zero.
        try appendBlock(store, taskId: taskId, startMs: base, durationSec: 300)

        let records = try store.worklog(
            from: pastDay, to: pastDay, roundToMin: 15, aggregateKey: "MISC")
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.seconds, 900, "aggregate bucket force-rounds up even sub-quantum")

        // A same-size, non-aggregate key does NOT force-round.
        let store2 = try makeStore()
        let taskId2 = try makeTaskBound(store2, name: "Other", jiraKey: "OTHER-1")
        try appendBlock(store2, taskId: taskId2, startMs: base, durationSec: 300)
        let records2 = try store2.worklog(
            from: pastDay, to: pastDay, roundToMin: 15, aggregateKey: "MISC")
        let r2 = try XCTUnwrap(records2.first)
        XCTAssertEqual(r2.seconds, 300, "non-aggregate sub-quantum key is reported as-is")
    }

    // MARK: - Records are deterministically ordered

    func testRecordsSortedByDateThenStarted() throws {
        let store = try makeStore()
        let taskA = try makeTaskBound(store, name: "A", jiraKey: "A-1")
        let taskB = try makeTaskBound(store, name: "B", jiraKey: "B-1")
        try appendBlock(store, taskId: taskB, startMs: baseMs(pastDay) + 10 * 3_600_000, durationSec: 60)
        try appendBlock(store, taskId: taskA, startMs: baseMs(pastDay) + 9 * 3_600_000, durationSec: 60)

        let records = try store.worklog(from: pastDay, to: pastDay)
        XCTAssertEqual(records.map { $0.jiraKey }, ["A-1", "B-1"], "earlier-started record sorts first")
    }
}
