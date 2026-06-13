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

    private func todayWindow() -> (from: Date, to: Date) {
        let today = Calendar.current.startOfDay(for: Date())
        return (today, today)
    }

    // MARK: - Tests

    // Gate condition 1: a project task with time and no binding throws .unbound.
    func testThrowsUnboundWhenTaskHasTimeButNoBinding() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        var task = Task(id: nil, name: "Unbound", code: nil, category: "project", archived: false)
        task = try store.upsertTask(task)
        let taskId = task.id!

        let (from, to) = todayWindow()
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

        let (from, to) = todayWindow()
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

        let (from, to) = todayWindow()
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

    // Break task time is never reportable and must not block the gate.
    func testBreakTimeExcludedFromGate() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        let breakId = try store.breakTaskId()

        let (from, to) = todayWindow()
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
        let (from, to) = todayWindow()
        let unbound = try store.unreconciled(from: from, to: to)
        XCTAssertFalse(unbound.contains(where: { $0.task.id == taskId }),
            "Zero-second task must not appear in the unreconciled list")
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

        let (from, to) = todayWindow()
        try appendOneHour(store: store, taskId: taskId, day: from)

        let rows = try store.reconciledReport(from: from, to: to)
        XCTAssertTrue(rows.contains(where: { $0.jiraKey == "B-1" }),
            "Last bind should resolve to B-1")
        XCTAssertFalse(rows.contains(where: { $0.jiraKey == "A-1" }),
            "Earlier bind A-1 should not appear after rebind")
    }
}
