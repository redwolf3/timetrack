import Foundation
import XCTest
@testable import TimeTrackKit

// Issue #71: typed "KEY - description" input is split into code + name, so
// dedup-by-code ("JIRA key wins", DESIGN.md "Task sources") can see the key —
// while the reconcile gate (CLAUDE.md invariant 4) still ignores it.
final class TaskTitleTests: XCTestCase {

    // MARK: - TaskTitle.parse

    func testParseSpaceDashSpaceSeparator() {
        XCTAssertEqual(TaskTitle.parse("KDAL-1234 - Paginate accounts API"),
                       TaskTitle(key: "KDAL-1234", description: "Paginate accounts API"))
    }

    func testParseColonSeparator() {
        XCTAssertEqual(TaskTitle.parse("KDAL-1234: Paginate accounts API"),
                       TaskTitle(key: "KDAL-1234", description: "Paginate accounts API"))
    }

    func testParseSingleSpaceSeparator() {
        XCTAssertEqual(TaskTitle.parse("KDAL-1234 Paginate accounts API"),
                       TaskTitle(key: "KDAL-1234", description: "Paginate accounts API"))
    }

    func testParseTightPunctuationAndEnDashSeparators() {
        XCTAssertEqual(TaskTitle.parse("KDAL-1234-Paginate"),
                       TaskTitle(key: "KDAL-1234", description: "Paginate"))
        XCTAssertEqual(TaskTitle.parse("KDAL-1234:Paginate"),
                       TaskTitle(key: "KDAL-1234", description: "Paginate"))
        XCTAssertEqual(TaskTitle.parse("KDAL-1234 \u{2013} Paginate"),
                       TaskTitle(key: "KDAL-1234", description: "Paginate"))
    }

    func testParseAlphanumericProjectKey() {
        XCTAssertEqual(TaskTitle.parse("AB2-7 Fix"),
                       TaskTitle(key: "AB2-7", description: "Fix"))
    }

    func testParseNoKeyReturnsTrimmedInputUnchanged() {
        XCTAssertEqual(TaskTitle.parse("Paginate accounts API"),
                       TaskTitle(key: nil, description: "Paginate accounts API"))
        XCTAssertEqual(TaskTitle.parse("Standup - daily"),
                       TaskTitle(key: nil, description: "Standup - daily"))
    }

    func testParseLowerCaseKeyIsUppercased() {
        XCTAssertEqual(TaskTitle.parse("kdal-1234 - desc"),
                       TaskTitle(key: "KDAL-1234", description: "desc"))
    }

    func testParseTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(TaskTitle.parse("   KDAL-1234 - Paginate accounts API  \n"),
                       TaskTitle(key: "KDAL-1234", description: "Paginate accounts API"))
        XCTAssertEqual(TaskTitle.parse("  plain name  "),
                       TaskTitle(key: nil, description: "plain name"))
    }

    // A bare key has no description to show; keep the text as a plain name
    // rather than fabricating an empty description.
    func testParseKeyOnlyIsUnchangedWithNilKey() {
        XCTAssertEqual(TaskTitle.parse("KDAL-1234"),
                       TaskTitle(key: nil, description: "KDAL-1234"))
        XCTAssertEqual(TaskTitle.parse("KDAL-1234 - "),
                       TaskTitle(key: nil, description: "KDAL-1234 -"))
    }

    // The key must be followed by a separator: a key-shaped prefix glued to
    // more text is not a key.
    func testParseKeyWithoutSeparatorIsNotAKey() {
        XCTAssertEqual(TaskTitle.parse("KDAL-1234abc"),
                       TaskTitle(key: nil, description: "KDAL-1234abc"))
        XCTAssertEqual(TaskTitle.parse("1234-KDAL foo"),
                       TaskTitle(key: nil, description: "1234-KDAL foo"))
        XCTAssertEqual(TaskTitle.parse("KDAL- foo"),
                       TaskTitle(key: nil, description: "KDAL- foo"))
    }

    func testParseEmptyInput() {
        XCTAssertEqual(TaskTitle.parse("   "), TaskTitle(key: nil, description: ""))
    }

    // MARK: - Task.title

    func testTaskTitleUsesStoredCode() {
        let t = Task(id: 1, name: "Paginate accounts API", code: "KDAL-1234",
                     category: "project", archived: false)
        XCTAssertEqual(t.title, TaskTitle(key: "KDAL-1234", description: "Paginate accounts API"))
    }

    // A stored code is authoritative: the name is not re-parsed even if it
    // happens to look key-prefixed.
    func testTaskTitleWithCodeDoesNotReparseName() {
        let t = Task(id: 1, name: "OTHER-9 - something", code: "KDAL-1234",
                     category: "project", archived: false)
        XCTAssertEqual(t.title, TaskTitle(key: "KDAL-1234", description: "OTHER-9 - something"))
    }

    // Legacy rows (pre-#71) embed the key in the name with code nil; display
    // splits them without rewriting the row.
    func testTaskTitleFallsBackToParsingNameWhenCodeNil() {
        let legacy = Task(id: 1, name: "KDAL-1234 - Paginate accounts API", code: nil,
                          category: "project", archived: false)
        XCTAssertEqual(legacy.title, TaskTitle(key: "KDAL-1234", description: "Paginate accounts API"))
        XCTAssertNil(legacy.code, "display parse must not mutate the row")

        let emptyCode = Task(id: 2, name: "KDAL-1 - x", code: "", category: "project", archived: false)
        XCTAssertEqual(emptyCode.title, TaskTitle(key: "KDAL-1", description: "x"))

        let plain = Task(id: 3, name: "Standup", code: nil, category: "meeting", archived: false)
        XCTAssertEqual(plain.title, TaskTitle(key: nil, description: "Standup"))
    }

    // MARK: - Tracker.addTask(typedName:)

    func testAddTaskTypedNameStoresKeyAsCode() throws {
        let dir = try makeTmpDir()
        try MainActor.assumeIsolated {
            let (tracker, store, _) = try makeTrackerContext(in: dir)

            let t = try tracker.addTask(typedName: "KDAL-1234 - Paginate accounts API")
            XCTAssertEqual(t.code, "KDAL-1234")
            XCTAssertEqual(t.name, "Paginate accounts API")
            XCTAssertEqual(t.category, "project")

            let stored = try XCTUnwrap(store.tasks().first { $0.id == t.id })
            XCTAssertEqual(stored.code, "KDAL-1234")
            XCTAssertEqual(stored.name, "Paginate accounts API")
            XCTAssertTrue(tracker.tasks.contains { $0.id == t.id }, "tracker cache refreshed")
        }
    }

    func testAddTaskTypedNameWithoutKeyStoresUnchanged() throws {
        let dir = try makeTmpDir()
        try MainActor.assumeIsolated {
            let (tracker, store, _) = try makeTrackerContext(in: dir)

            let t = try tracker.addTask(typedName: "  Paginate accounts API ")
            XCTAssertNil(t.code)
            XCTAssertEqual(t.name, "Paginate accounts API")

            let stored = try XCTUnwrap(store.tasks().first { $0.id == t.id })
            XCTAssertNil(stored.code)
            XCTAssertEqual(stored.name, "Paginate accounts API")
        }
    }

    // MARK: - Dedup by code ("JIRA key wins")

    // (b) Two ad-hoc adds with the same key → one row; the second add returns
    // the first row instead of inserting a duplicate.
    func testAddTaskTypedNameTwiceWithSameKeyReusesRow() throws {
        let dir = try makeTmpDir()
        try MainActor.assumeIsolated {
            let (tracker, store, _) = try makeTrackerContext(in: dir)

            let first = try tracker.addTask(typedName: "KDAL-1234 - Paginate accounts API")
            let second = try tracker.addTask(typedName: "kdal-1234: pagination again")

            XCTAssertEqual(second.id, first.id)
            XCTAssertEqual(second.name, "Paginate accounts API", "first claimant keeps its title")
            let rows = try store.userTasks(includeArchived: true).filter { $0.code == "KDAL-1234" }
            XCTAssertEqual(rows.count, 1)
        }
    }

    // An archived row with the key is reactivated, not duplicated.
    func testAddTaskTypedNameReactivatesArchivedRowWithSameKey() throws {
        let dir = try makeTmpDir()
        try MainActor.assumeIsolated {
            let (tracker, store, _) = try makeTrackerContext(in: dir)

            var old = try store.upsertTask(Task(id: nil, name: "Old title", code: "KDAL-1234",
                                                category: "project", archived: false))
            old.archived = true
            old = try store.upsertTask(old)

            let t = try tracker.addTask(typedName: "KDAL-1234 - Paginate accounts API")
            XCTAssertEqual(t.id, old.id)
            XCTAssertFalse(t.archived)
            let rows = try store.userTasks(includeArchived: true).filter { $0.code == "KDAL-1234" }
            XCTAssertEqual(rows.count, 1)
            XCTAssertFalse(try XCTUnwrap(rows.first).archived)
        }
    }

    // (a) Ad-hoc "KDAL-1234 - …" then tasks.yaml with code KDAL-1234 → ingest
    // matches the ad-hoc row by code and updates it in place; still one row.
    func testAdHocThenYamlWithSameCodeMergesIntoOneRow() throws {
        let dir = try makeTmpDir()
        try MainActor.assumeIsolated {
            let (tracker, store, _) = try makeTrackerContext(in: dir)

            let adHoc = try tracker.addTask(typedName: "KDAL-1234 - Paginate accounts API")

            let yaml = """
            tasks:
              - name: Accounts API pagination
                code: KDAL-1234
                category: project
            """
            let url = dir.appendingPathComponent("tasks.yaml")
            try yaml.write(to: url, atomically: true, encoding: .utf8)
            let changed = try TasksLoader.ingest(from: url, into: store)
            XCTAssertEqual(changed, 1, "yaml renames the existing row rather than inserting")

            let rows = try store.userTasks(includeArchived: true).filter { $0.code == "KDAL-1234" }
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.id, adHoc.id)
            XCTAssertEqual(rows.first?.name, "Accounts API pagination")

            // Re-ingest is a no-op (no .ambiguousCode, no further change).
            XCTAssertEqual(try TasksLoader.ingest(from: url, into: store), 0)
        }
    }

    // Reverse order: yaml first, then a typed ad-hoc add with that key reuses
    // the yaml row.
    func testYamlThenAdHocWithSameCodeReusesYamlRow() throws {
        let dir = try makeTmpDir()
        try MainActor.assumeIsolated {
            let (tracker, store, _) = try makeTrackerContext(in: dir)

            let yaml = """
            tasks:
              - name: Accounts API pagination
                code: KDAL-1234
                category: project
            """
            let url = dir.appendingPathComponent("tasks.yaml")
            try yaml.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(try TasksLoader.ingest(from: url, into: store), 1)
            let yamlRow = try XCTUnwrap(store.userTasks().first { $0.code == "KDAL-1234" })

            let t = try tracker.addTask(typedName: "KDAL-1234 - Paginate accounts API")
            XCTAssertEqual(t.id, yamlRow.id)
            XCTAssertEqual(t.name, "Accounts API pagination")
            XCTAssertEqual(try store.userTasks(includeArchived: true)
                .filter { $0.code == "KDAL-1234" }.count, 1)
        }
    }

    // MARK: - Reconcile gate (CLAUDE.md invariant 4)

    // A parsed key is capture metadata, not a binding: the task stays unbound
    // and blocks the reconciled report until an explicit reconcile_bind.
    func testTypedKeyDoesNotSatisfyReconcileGate() throws {
        let dir = try makeTmpDir()
        try MainActor.assumeIsolated {
            let (tracker, store, _) = try makeTrackerContext(in: dir)

            let t = try tracker.addTask(typedName: "KDAL-1234 - Paginate accounts API")
            let taskId = try XCTUnwrap(t.id)
            XCTAssertEqual(t.code, "KDAL-1234")

            // Fixed past day so the hour is inside the report clamp regardless of
            // what time the suite runs (same rationale as ReconcileGateTests).
            let cal = Calendar.current
            let day = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: Date()))!
            let t0 = Int64(day.timeIntervalSince1970 * 1_000) + 3_600_000
            try store.append(Event(id: nil, ts: t0, type: EventType.start.rawValue,
                taskId: taskId, prevTaskId: nil, phaseId: nil, profileName: nil,
                extendMin: nil, comment: nil))
            try store.append(Event(id: nil, ts: t0 + 3_600_000, type: EventType.stop.rawValue,
                taskId: nil, prevTaskId: taskId, phaseId: nil, profileName: nil,
                extendMin: nil, comment: nil))

            let unbound = try store.unreconciled(from: day, to: day)
            XCTAssertTrue(unbound.contains { $0.task.id == taskId },
                          "a task with a code but no reconcile_bind is still unbound")

            XCTAssertThrowsError(try store.reconciledReport(from: day, to: day)) { error in
                guard case Store.ReconcileError.unbound(let tasks) = error else {
                    return XCTFail("Expected .unbound, got \(error)")
                }
                XCTAssertTrue(tasks.contains { $0.task.id == taskId })
            }
        }
    }
}
