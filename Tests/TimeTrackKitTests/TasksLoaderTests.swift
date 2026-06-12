import Foundation
import XCTest
@testable import TimeTrackKit

final class TasksLoaderTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(in dir: URL) throws -> Store {
        try Store(url: dir.appendingPathComponent("test.db"))
    }

    private func writeYAML(_ content: String, to dir: URL, name: String = "tasks.yaml") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Happy path

    func testFreshIngestInsertsRowsWithCorrectFields() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        tasks:
          - name: Sprint overhead
            code: PROJ-100
            category: overhead
          - name: Feature work
            code: FEAT-1
            category: project
          - name: Design review
            category: meeting
        """
        let url = try writeYAML(yaml, to: dir)

        let count = try TasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(count, 3, "should insert 3 new rows")

        let tasks = try store.tasks(includeArchived: true)
        // Filter out the synthetic break task inserted by Store.init
        let userTasks = tasks.filter { $0.category != "break" }
        XCTAssertEqual(userTasks.count, 3)

        let overhead = try XCTUnwrap(userTasks.first { $0.code == "PROJ-100" })
        XCTAssertEqual(overhead.name, "Sprint overhead")
        XCTAssertEqual(overhead.category, "overhead")
        XCTAssertFalse(overhead.archived)

        let feature = try XCTUnwrap(userTasks.first { $0.code == "FEAT-1" })
        XCTAssertEqual(feature.name, "Feature work")
        XCTAssertEqual(feature.category, "project")

        let design = try XCTUnwrap(userTasks.first { $0.name == "Design review" && $0.code == nil })
        XCTAssertEqual(design.category, "meeting")
    }

    func testSecondIngestSameFileIsNoop() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        tasks:
          - name: Sprint overhead
            code: PROJ-100
            category: overhead
        """
        let url = try writeYAML(yaml, to: dir)

        let first = try TasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(first, 1)

        let second = try TasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(second, 0, "second ingest of unchanged file must return 0 (idempotent)")

        let tasks = try store.tasks(includeArchived: true).filter { $0.category != "break" }
        XCTAssertEqual(tasks.count, 1, "no duplicate rows should be created")
    }

    func testChangedNameAndCategoryUpdatesRowInPlace() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        // Insert an archived task via the store so we can confirm archived is preserved.
        var existing = Task(id: nil, name: "Old Name", code: "PROJ-5", category: "project", archived: true)
        existing = try store.upsertTask(existing)
        let originalId = try XCTUnwrap(existing.id)

        let yaml = """
        tasks:
          - name: New Name
            code: PROJ-5
            category: overhead
        """
        let url = try writeYAML(yaml, to: dir)

        let count = try TasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(count, 1, "update counts as one change")

        let updated = try XCTUnwrap(
            store.tasks(includeArchived: true).first { $0.id == originalId }
        )
        XCTAssertEqual(updated.name, "New Name", "name should be updated from yaml")
        XCTAssertEqual(updated.category, "overhead", "category should be updated from yaml")
        XCTAssertTrue(updated.archived, "archived flag must be preserved")
        XCTAssertEqual(updated.id, originalId, "row id must not change on update")
    }

    func testCodelessEntryMatchedByName() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        var existing = Task(id: nil, name: "Team meeting", code: nil, category: "meeting", archived: false)
        existing = try store.upsertTask(existing)
        let originalId = try XCTUnwrap(existing.id)

        // Same name, different category — should update in place.
        let yaml = """
        tasks:
          - name: Team meeting
            category: overhead
        """
        let url = try writeYAML(yaml, to: dir)

        let count = try TasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(count, 1)

        let updated = try XCTUnwrap(
            store.tasks(includeArchived: true).first { $0.id == originalId }
        )
        XCTAssertEqual(updated.category, "overhead")
        XCTAssertEqual(updated.id, originalId)
    }

    func testCodelessEntryNotDuplicatedOnReIngest() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        tasks:
          - name: Standup
            category: meeting
        """
        let url = try writeYAML(yaml, to: dir)

        _ = try TasksLoader.ingest(from: url, into: store)
        let second = try TasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(second, 0, "re-ingest of code-less entry must be idempotent")

        let tasks = try store.tasks(includeArchived: true).filter { $0.name == "Standup" }
        XCTAssertEqual(tasks.count, 1, "must not create a duplicate row")
    }

    func testMissingFileReturnsZero() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)
        let missing = dir.appendingPathComponent("nonexistent.yaml")

        let count = try TasksLoader.ingest(from: missing, into: store)
        XCTAssertEqual(count, 0, "missing file must be a silent no-op")

        let tasks = try store.tasks(includeArchived: true).filter { $0.category != "break" }
        XCTAssertEqual(tasks.count, 0, "no rows should be inserted when file is absent")
    }

    // MARK: - Break task invariant

    func testBreakTaskInDBNeverTouched() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        // The break task is inserted by Store.init via ensureBreakTask.
        let breakBefore = try store.tasks(includeArchived: true).first { $0.category == "break" }
        let breakId = try XCTUnwrap(breakBefore?.id)

        // Ingest tasks that don't reference break at all.
        let yaml = """
        tasks:
          - name: Sprint overhead
            code: PROJ-100
            category: overhead
        """
        let url = try writeYAML(yaml, to: dir)
        _ = try TasksLoader.ingest(from: url, into: store)

        let breakAfter = try store.tasks(includeArchived: true).first { $0.id == breakId }
        XCTAssertEqual(breakAfter?.name, breakBefore?.name, "break task name must be unchanged")
        XCTAssertEqual(breakAfter?.category, "break", "break task category must be unchanged")
    }

    func testWhitespaceTrimmedFromNameAndCode() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        tasks:
          - name: "  Padded name  "
            code: "  PROJ-9  "
            category: project
        """
        let url = try writeYAML(yaml, to: dir)

        _ = try TasksLoader.ingest(from: url, into: store)
        let tasks = try store.tasks(includeArchived: true).filter { $0.category != "break" }
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].name, "Padded name")
        XCTAssertEqual(tasks[0].code, "PROJ-9")
    }

    func testEmptyAfterTrimCodeTreatedAsNil() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        tasks:
          - name: No code
            code: "   "
            category: project
        """
        let url = try writeYAML(yaml, to: dir)

        _ = try TasksLoader.ingest(from: url, into: store)
        let tasks = try store.tasks(includeArchived: true).filter { $0.category != "break" }
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(tasks[0].code, "whitespace-only code must be treated as absent")
    }

    func testCategoryDefaultsToProject() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        tasks:
          - name: No category task
            code: PROJ-77
        """
        let url = try writeYAML(yaml, to: dir)

        _ = try TasksLoader.ingest(from: url, into: store)
        let tasks = try store.tasks(includeArchived: true).filter { $0.category != "break" }
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].category, "project")
    }

    // Quoted YAML scalars can carry newlines/tabs past a .whitespaces-only trim,
    // and an untrimmed category like "project " must not fail as unknown.
    func testNewlineAndTabWhitespaceTrimmedFromAllFields() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        tasks:
          - name: "\\n\\tPadded task\\n"
            code: "\\nPROJ-9\\t"
            category: "project\\n "
        """
        let url = try writeYAML(yaml, to: dir)

        XCTAssertEqual(try TasksLoader.ingest(from: url, into: store), 1)
        let row = try XCTUnwrap(store.tasks(includeArchived: true).first { $0.code == "PROJ-9" })
        XCTAssertEqual(row.name, "Padded task")
        XCTAssertEqual(row.category, "project")
    }

    func testNewlineOnlyNameThrowsEmptyName() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)
        let url = try writeYAML("tasks:\n  - name: \"\\n\\t\"\n", to: dir)

        XCTAssertThrowsError(try TasksLoader.ingest(from: url, into: store)) { error in
            guard case TasksLoader.ValidationError.emptyName = error else {
                return XCTFail("expected .emptyName, got \(error)")
            }
        }
    }

    // The tasks table has no UNIQUE constraint on code: if duplicates pre-exist,
    // ingest must refuse to pick a row arbitrarily and name the offenders.
    func testPreexistingDuplicateCodeThrowsAmbiguous() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)
        let a = try store.upsertTask(Task(id: nil, name: "First", code: "PROJ-1",
                                          category: "project", archived: false))
        let b = try store.upsertTask(Task(id: nil, name: "Second", code: "PROJ-1",
                                          category: "project", archived: false))
        let url = try writeYAML("tasks:\n  - name: Renamed\n    code: PROJ-1\n", to: dir)

        XCTAssertThrowsError(try TasksLoader.ingest(from: url, into: store)) { error in
            guard case TasksLoader.ValidationError.ambiguousCode(let code, let ids) = error else {
                return XCTFail("expected .ambiguousCode, got \(error)")
            }
            XCTAssertEqual(code, "PROJ-1")
            XCTAssertEqual(Set(ids), Set([a.id, b.id].compactMap { $0 }))
        }
        // Neither row may have been touched.
        let rows = try store.tasks(includeArchived: true).filter { $0.code == "PROJ-1" }
        XCTAssertEqual(Set(rows.map(\.name)), ["First", "Second"])
    }

    func testPreexistingDuplicateCodelessNameThrowsAmbiguous() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)
        _ = try store.upsertTask(Task(id: nil, name: "Overhead", code: nil,
                                      category: "project", archived: false))
        _ = try store.upsertTask(Task(id: nil, name: "Overhead", code: nil,
                                      category: "overhead", archived: true))
        let url = try writeYAML("tasks:\n  - name: Overhead\n    category: overhead\n", to: dir)

        XCTAssertThrowsError(try TasksLoader.ingest(from: url, into: store)) { error in
            guard case TasksLoader.ValidationError.ambiguousCodelessName(let name, let ids) = error else {
                return XCTFail("expected .ambiguousCodelessName, got \(error)")
            }
            XCTAssertEqual(name, "Overhead")
            XCTAssertEqual(ids.count, 2)
        }
    }

    // MARK: - Validation errors

    func testDuplicateCodeThrows() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        tasks:
          - name: First
            code: PROJ-1
            category: project
          - name: Second
            code: PROJ-1
            category: overhead
        """
        let url = try writeYAML(yaml, to: dir)

        XCTAssertThrowsError(try TasksLoader.ingest(from: url, into: store)) { error in
            guard let ve = error as? TasksLoader.ValidationError else {
                return XCTFail("expected TasksLoader.ValidationError, got \(error)")
            }
            let desc = ve.description
            XCTAssertTrue(desc.contains("PROJ-1"), "error must name the duplicate code: \(desc)")
        }
    }

    func testDuplicateCodelessNameThrows() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        tasks:
          - name: Team meeting
            category: meeting
          - name: Team meeting
            category: overhead
        """
        let url = try writeYAML(yaml, to: dir)

        XCTAssertThrowsError(try TasksLoader.ingest(from: url, into: store)) { error in
            guard let ve = error as? TasksLoader.ValidationError else {
                return XCTFail("expected TasksLoader.ValidationError, got \(error)")
            }
            let desc = ve.description
            XCTAssertTrue(desc.contains("Team meeting"), "error must name the duplicate: \(desc)")
        }
    }

    func testEmptyNameThrows() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        tasks:
          - name: ""
            category: project
        """
        let url = try writeYAML(yaml, to: dir)

        XCTAssertThrowsError(try TasksLoader.ingest(from: url, into: store)) { error in
            XCTAssertTrue(error is TasksLoader.ValidationError)
        }
    }

    func testCategoryBreakThrows() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        tasks:
          - name: My break
            category: break
        """
        let url = try writeYAML(yaml, to: dir)

        XCTAssertThrowsError(try TasksLoader.ingest(from: url, into: store)) { error in
            guard let ve = error as? TasksLoader.ValidationError else {
                return XCTFail("expected TasksLoader.ValidationError, got \(error)")
            }
            let desc = ve.description
            XCTAssertTrue(
                desc.contains("break"),
                "error must mention 'break': \(desc)"
            )
        }
    }

    func testUnknownCategoryThrows() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        tasks:
          - name: Some task
            category: bogus
        """
        let url = try writeYAML(yaml, to: dir)

        XCTAssertThrowsError(try TasksLoader.ingest(from: url, into: store)) { error in
            guard let ve = error as? TasksLoader.ValidationError else {
                return XCTFail("expected TasksLoader.ValidationError, got \(error)")
            }
            let desc = ve.description
            XCTAssertTrue(desc.contains("bogus"), "error must name the invalid category: \(desc)")
        }
    }

    // MARK: - Entries absent from yaml are left alone

    func testAbsentEntryNotRemovedOrArchived() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        // Insert a row that won't be in the yaml.
        var existing = Task(id: nil, name: "Old task", code: "OLD-1", category: "project", archived: false)
        existing = try store.upsertTask(existing)
        let oldId = try XCTUnwrap(existing.id)

        let yaml = """
        tasks:
          - name: New task
            code: NEW-1
            category: project
        """
        let url = try writeYAML(yaml, to: dir)
        _ = try TasksLoader.ingest(from: url, into: store)

        // Old row must still exist, unmodified.
        let old = try XCTUnwrap(
            store.tasks(includeArchived: true).first { $0.id == oldId }
        )
        XCTAssertEqual(old.code, "OLD-1")
        XCTAssertFalse(old.archived, "rows absent from yaml must not be archived")
    }
}
