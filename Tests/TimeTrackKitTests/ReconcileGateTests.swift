import XCTest
@testable import TimeTrackKit

// Tests for the two-condition reconcile gate in Store.reconciledReport(from:to:).
// Gate condition 1: every project task with time must be explicitly bound to a KnownTask.
// Gate condition 2: no KnownTask with reported time may still be provisional.
// Both conditions must clear before reconciledReport returns rows.
final class ReconcileGateTests: XCTestCase {

    // MARK: - Helpers

    // One-hour start/stop block anchored to the start of day + offset.
    private func appendOneHour(
        store: Store,
        taskId: Int64,
        day: Date,
        hourOffset: Int = 1
    ) throws {
        let dayStart = Calendar.current.startOfDay(for: day)
        let t0 = Int64(dayStart.timeIntervalSince1970 * 1_000) + Int64(hourOffset) * 3_600_000
        let t1 = t0 + 3_600_000

        try store.append(Event(id: nil, ts: t0, type: EventType.start.rawValue,
            taskId: taskId, prevTaskId: nil, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))
        try store.append(Event(id: nil, ts: t1, type: EventType.stop.rawValue,
            taskId: nil, prevTaskId: taskId, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))
    }

    // A FIXED PAST day used as the report window. Anchored to the past (not
    // today) so the seeded interval is always inside sliceTimeline's clamp:
    // reconciledReport clamps each day to min(endOfDay, now), so a "today"
    // fixture seeded at startOfDay+1h..2h reports ZERO time when the suite runs
    // before that hour (e.g. 00:00–02:00), failing the positive-time assertions.
    // Mirrors the fixed-past-day pattern used by the promote/retire tests below.
    private func pastDayWindow() -> (from: Date, to: Date) {
        let cal = Calendar.current
        let pastDay = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: Date()))!
        return (pastDay, pastDay)
    }

    // MARK: - Tests

    // Gate condition 1: a project task with time and no binding throws .unbound.
    func testThrowsUnboundWhenTaskHasTimeButNoBinding() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        var task = Task(id: nil, name: "Unbound", code: nil, category: "project", archived: false)
        task = try store.upsertTask(task)
        let taskId = task.id!

        let (from, to) = pastDayWindow()
        try appendOneHour(store: store, taskId: taskId, day: from)

        XCTAssertThrowsError(try store.reconciledReport(from: from, to: to)) { error in
            guard case Store.ReconcileError.unbound(let tasks) = error else {
                XCTFail("Expected .unbound, got \(error)")
                return
            }
            XCTAssertTrue(tasks.contains(where: { $0.task.id == taskId }),
                "Unbound list should include the task with time")
        }
    }

    // Gate condition 2: a task bound to a provisional KnownTask throws .provisional.
    func testThrowsProvisionalWhenBoundToProvisionalKnownTask() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        var task = Task(id: nil, name: "Provisional", code: nil, category: "project", archived: false)
        task = try store.upsertTask(task)
        let taskId = task.id!

        // jiraKey nil → provisional == true
        let kt = try store.addKnownTask(jiraKey: nil, description: "WIP entry")
        let ktId = try XCTUnwrap(kt.id)
        try store.bind(taskId: taskId, knownTaskId: ktId, comment: nil)

        let (from, to) = pastDayWindow()
        try appendOneHour(store: store, taskId: taskId, day: from)

        XCTAssertThrowsError(try store.reconciledReport(from: from, to: to)) { error in
            guard case Store.ReconcileError.provisional(let provisionals) = error else {
                XCTFail("Expected .provisional, got \(error)")
                return
            }
            XCTAssertTrue(provisionals.contains(where: { $0.id == ktId }),
                "Provisional list should include the provisional KnownTask")
        }
    }

    // Both conditions clear → reconciledReport returns rows with correct jiraKey and time.
    func testSucceedsWhenAllTasksBoundToNonProvisionalKnownTask() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        var task = Task(id: nil, name: "Reconciled", code: nil, category: "project", archived: false)
        task = try store.upsertTask(task)
        let taskId = task.id!

        // jiraKey non-nil → provisional == false
        let kt = try store.addKnownTask(jiraKey: "ABC-1", description: "Known work")
        try store.bind(taskId: taskId, knownTaskId: try XCTUnwrap(kt.id), comment: nil)

        let (from, to) = pastDayWindow()
        try appendOneHour(store: store, taskId: taskId, day: from)

        let rows = try store.reconciledReport(from: from, to: to)
        XCTAssertFalse(rows.isEmpty, "Should return at least one row")
        let row = try XCTUnwrap(rows.first(where: { $0.jiraKey == "ABC-1" }))
        XCTAssertGreaterThan(row.totalSeconds, 0, "Reported time should be positive")
    }

    // Promoting a provisional Known Task must clear it from provisionalWithTime
    // and let reconciledReport resolve the real key. This guards the append-only
    // overlay: promoteKnownTask writes a known_task_promote EVENT and never
    // mutates the base known_tasks row, so a raw KnownTask.fetchOne would still
    // report provisional == true forever — the entry would never leave the
    // provisional gate and the in-app promote action would appear to do nothing.
    // provisionalWithTime/reconciledReport must read knownTasks()'s overlay.
    func testPromoteClearsProvisionalViaEventOverlay() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        var task = Task(id: nil, name: "WIP", code: nil, category: "project", archived: false)
        task = try store.upsertTask(task)
        let taskId = try XCTUnwrap(task.id)

        // Bind to a PROVISIONAL Known Task (no jiraKey yet).
        let kt = try store.addKnownTask(jiraKey: nil, description: "Loose entry")
        let ktId = try XCTUnwrap(kt.id)
        try store.bind(taskId: taskId, knownTaskId: ktId, comment: nil)

        // Anchor the tracked hour to a FIXED PAST day so the real-now bind/promote
        // events (ts = now) fall outside the report window and cannot split the
        // interval (report() truncates per-segment ms, losing ~1s on a split).
        let cal = Calendar.current
        let pastDay = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: Date()))!
        try appendOneHour(store: store, taskId: taskId, day: pastDay)
        let (from, to) = (pastDay, pastDay)

        // Before promote: provisional-with-time lists it; the gate blocks.
        XCTAssertTrue(try store.provisionalWithTime(from: from, to: to).contains { $0.id == ktId },
                      "provisional entry with bound time must appear before promote")
        XCTAssertThrowsError(try store.reconciledReport(from: from, to: to)) { err in
            guard case Store.ReconcileError.provisional = err else {
                return XCTFail("expected .provisional, got \(err)")
            }
        }

        // Promote (append-only: base row keeps provisional == true).
        XCTAssertTrue(try store.promoteKnownTask(id: ktId, jiraKey: "JIRA-9"))

        // After promote: must clear from provisionalWithTime and reconcile cleanly.
        XCTAssertFalse(try store.provisionalWithTime(from: from, to: to).contains { $0.id == ktId },
                       "promoted entry must clear from provisionalWithTime (event overlay applied)")
        let rows = try store.reconciledReport(from: from, to: to)
        XCTAssertTrue(rows.contains { $0.jiraKey == "JIRA-9" },
                      "reconciledReport must resolve the promoted key JIRA-9")
    }

    // Retiring a Known Task must NOT be a backdoor past the gate. If provisional
    // time is bound to an entry that is later retired, that time is still real and
    // unreconciled — it must still appear in provisionalWithTime and still block
    // reconciledReport. (Regression guard: resolving the overlay with
    // activeOnly:true would drop retired entries and let the time slip through.)
    func testRetiredProvisionalKnownTaskStillBlocksGate() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        var task = Task(id: nil, name: "WIP", code: nil, category: "project", archived: false)
        task = try store.upsertTask(task)
        let taskId = try XCTUnwrap(task.id)

        let kt = try store.addKnownTask(jiraKey: nil, description: "Loose entry")  // provisional
        let ktId = try XCTUnwrap(kt.id)
        try store.bind(taskId: taskId, knownTaskId: ktId, comment: nil)

        let cal = Calendar.current
        let pastDay = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: Date()))!
        try appendOneHour(store: store, taskId: taskId, day: pastDay)
        let (from, to) = (pastDay, pastDay)

        // Retire the provisional entry AFTER time is bound to it.
        XCTAssertTrue(try store.retireKnownTask(id: ktId))

        XCTAssertTrue(try store.provisionalWithTime(from: from, to: to).contains { $0.id == ktId },
                      "retired+provisional entry with bound time must still block the gate")
        XCTAssertThrowsError(try store.reconciledReport(from: from, to: to)) { err in
            guard case Store.ReconcileError.provisional = err else {
                return XCTFail("expected .provisional, got \(err)")
            }
        }
    }

    // Conversely, historical time bound to a Known Task that was promoted and then
    // retired must STILL be reported, not silently dropped. (Regression guard for
    // the reconciledReport path: activeOnly:true would drop the retired entry and
    // omit its time from the report entirely.)
    func testRetiredPromotedKnownTaskStillReports() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        var task = Task(id: nil, name: "Done work", code: nil, category: "project", archived: false)
        task = try store.upsertTask(task)
        let taskId = try XCTUnwrap(task.id)

        let kt = try store.addKnownTask(jiraKey: nil, description: "Was loose")
        let ktId = try XCTUnwrap(kt.id)
        try store.bind(taskId: taskId, knownTaskId: ktId, comment: nil)

        let cal = Calendar.current
        let pastDay = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: Date()))!
        try appendOneHour(store: store, taskId: taskId, day: pastDay)
        let (from, to) = (pastDay, pastDay)

        // Promote (real key), then retire the entry.
        XCTAssertTrue(try store.promoteKnownTask(id: ktId, jiraKey: "JIRA-7"))
        XCTAssertTrue(try store.retireKnownTask(id: ktId))

        // Gate clears (no longer provisional) and the time is reported under JIRA-7.
        XCTAssertFalse(try store.provisionalWithTime(from: from, to: to).contains { $0.id == ktId })
        let rows = try store.reconciledReport(from: from, to: to)
        XCTAssertTrue(rows.contains { $0.jiraKey == "JIRA-7" },
                      "time bound to a promoted-then-retired entry must still be reported")
    }

    // Break task time is never reportable and must not block the gate.
    func testBreakTimeExcludedFromGate() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        let breakId = try store.breakTaskId()

        let (from, to) = pastDayWindow()
        try appendOneHour(store: store, taskId: breakId, day: from)

        // No project tasks at all — gate should pass, returning empty rows.
        let rows = try store.reconciledReport(from: from, to: to)
        XCTAssertTrue(rows.isEmpty, "Break time produces no reportable rows")
    }

    // A project task with zero time must not appear in the unreconciled list.
    func testUnboundDoesNotIncludeZeroSecondTasks() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        var task = Task(id: nil, name: "NoTime", code: nil, category: "project", archived: false)
        task = try store.upsertTask(task)
        let taskId = task.id!

        // No events appended — task has zero time.
        let (from, to) = pastDayWindow()
        let unbound = try store.unreconciled(from: from, to: to)
        XCTAssertFalse(unbound.contains(where: { $0.task.id == taskId }),
            "Zero-second task must not appear in the unreconciled list")
    }

    // reconcileState(from:to:) must be semantically identical to calling
    // unreconciled(from:to:) and provisionalWithTime(from:to:) separately.
    // This test builds a fixture that exercises all four exclusion branches in
    // a single window, then compares the combined-walk result against the two
    // independent walks by task-id set and per-task totalSeconds dictionary.
    //
    // Fixture:
    //   taskUnbound     — project task, NO binding, 1 h time  → in unbound only
    //   taskProvisional — project task, bound to provisional KT, 1 h time → in provisional only
    //   taskBound       — project task, bound to non-provisional KT, 1 h time → in neither
    //   breakId         — break task, 1 h time                → excluded from unbound
    //   taskZero        — project task, NO binding, 0 time    → excluded from both
    func testReconcileStateMatchesSeparateMethods() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        // --- Unbound project task (no binding, has time) ---
        var taskUnbound = Task(id: nil, name: "Unbound", code: nil, category: "project", archived: false)
        taskUnbound = try store.upsertTask(taskUnbound)
        let unboundId = try XCTUnwrap(taskUnbound.id)

        // --- Provisional: project task bound to a provisional KnownTask (no jiraKey) ---
        var taskProvisional = Task(id: nil, name: "Provisional", code: nil, category: "project", archived: false)
        taskProvisional = try store.upsertTask(taskProvisional)
        let provisionalTaskId = try XCTUnwrap(taskProvisional.id)
        let provisionalKT = try store.addKnownTask(jiraKey: nil, description: "WIP prov")
        let provisionalKTId = try XCTUnwrap(provisionalKT.id)
        try store.bind(taskId: provisionalTaskId, knownTaskId: provisionalKTId, comment: nil)

        // --- Bound non-provisional: project task bound to a real JIRA key ---
        var taskBound = Task(id: nil, name: "Bound", code: nil, category: "project", archived: false)
        taskBound = try store.upsertTask(taskBound)
        let boundTaskId = try XCTUnwrap(taskBound.id)
        let nonProvKT = try store.addKnownTask(jiraKey: "EQUIV-1", description: "Real entry")
        let nonProvKTId = try XCTUnwrap(nonProvKT.id)
        try store.bind(taskId: boundTaskId, knownTaskId: nonProvKTId, comment: nil)

        // --- Break task (should never appear in unbound) ---
        let breakId = try store.breakTaskId()

        // --- Zero-time project task (no events; must be excluded) ---
        var taskZero = Task(id: nil, name: "Zero", code: nil, category: "project", archived: false)
        taskZero = try store.upsertTask(taskZero)

        // Anchor all events to a fixed past day so the window is fully closed.
        let (from, to) = pastDayWindow()
        try appendOneHour(store: store, taskId: unboundId,         day: from, hourOffset: 1)
        try appendOneHour(store: store, taskId: provisionalTaskId, day: from, hourOffset: 2)
        try appendOneHour(store: store, taskId: boundTaskId,       day: from, hourOffset: 3)
        try appendOneHour(store: store, taskId: breakId,           day: from, hourOffset: 4)
        // taskZero intentionally gets no events.

        // --- Call both independent methods (the baseline) ---
        let unreconciledList = try store.unreconciled(from: from, to: to)
        let provisionalList  = try store.provisionalWithTime(from: from, to: to)

        // --- Call the combined method (the method under test) ---
        let state = try store.reconcileState(from: from, to: to)

        // MARK: unbound equivalence

        // Set of task-ids must match exactly.
        let expectedUnboundIds = Set(unreconciledList.map { $0.task.id })
        let actualUnboundIds   = Set(state.unbound.map { $0.task.id })
        XCTAssertEqual(actualUnboundIds, expectedUnboundIds,
            "reconcileState.unbound task-id set must match unreconciled()")

        // Per-task totalSeconds must also match (keyed by optional task id).
        let expectedUnboundSecs = Dictionary(
            uniqueKeysWithValues: unreconciledList.map { ($0.task.id, $0.totalSeconds) })
        let actualUnboundSecs = Dictionary(
            uniqueKeysWithValues: state.unbound.map { ($0.task.id, $0.totalSeconds) })
        XCTAssertEqual(actualUnboundSecs, expectedUnboundSecs,
            "reconcileState.unbound totalSeconds must match unreconciled()")

        // Sanity: unboundId must be present; break/provisional/bound/zero must not.
        XCTAssertTrue(actualUnboundIds.contains(unboundId),
            "Unbound project task must appear in unbound")
        XCTAssertFalse(actualUnboundIds.contains(breakId),
            "Break task must not appear in unbound")
        XCTAssertFalse(actualUnboundIds.contains(provisionalTaskId),
            "Bound-to-provisional task must not appear in unbound")
        XCTAssertFalse(actualUnboundIds.contains(boundTaskId),
            "Non-provisional bound task must not appear in unbound")
        XCTAssertFalse(actualUnboundIds.contains(taskZero.id),
            "Zero-time task must not appear in unbound")

        // MARK: provisional equivalence

        let expectedProvIds = Set(provisionalList.compactMap { $0.id })
        let actualProvIds   = Set(state.provisional.compactMap { $0.id })
        XCTAssertEqual(actualProvIds, expectedProvIds,
            "reconcileState.provisional KnownTask-id set must match provisionalWithTime()")

        // Sanity: provisionalKTId in list; nonProvKTId absent.
        XCTAssertTrue(actualProvIds.contains(provisionalKTId),
            "Provisional KnownTask with bound time must appear in provisional")
        XCTAssertFalse(actualProvIds.contains(nonProvKTId),
            "Non-provisional KnownTask must not appear in provisional")
    }

    // Last reconcile_bind event wins when a task has been rebound multiple times.
    func testLastBindWins() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        var task = Task(id: nil, name: "Rebound", code: nil, category: "project", archived: false)
        task = try store.upsertTask(task)
        let taskId = task.id!

        // Insert KT-A, then KT-B. knownTasks() returns descending by createdTs,
        // so we insert with a slight sleep to ensure distinct timestamps, or we
        // use the jiraKey to distinguish them after fetching all.
        try store.addKnownTask(jiraKey: "A-1", description: "First")
        try store.addKnownTask(jiraKey: "B-1", description: "Second")

        let allKTs = try store.knownTasks(activeOnly: false)
        let ktA = try XCTUnwrap(allKTs.first(where: { $0.jiraKey == "A-1" }))
        let ktB = try XCTUnwrap(allKTs.first(where: { $0.jiraKey == "B-1" }))

        // Bind to A first, then rebind to B — B should win.
        try store.bind(taskId: taskId, knownTaskId: try XCTUnwrap(ktA.id), comment: nil)
        try store.bind(taskId: taskId, knownTaskId: try XCTUnwrap(ktB.id), comment: nil)

        let (from, to) = pastDayWindow()
        try appendOneHour(store: store, taskId: taskId, day: from)

        let rows = try store.reconciledReport(from: from, to: to)
        XCTAssertTrue(rows.contains(where: { $0.jiraKey == "B-1" }),
            "Last bind should resolve to B-1")
        XCTAssertFalse(rows.contains(where: { $0.jiraKey == "A-1" }),
            "Earlier bind A-1 should not appear after rebind")
    }
}
