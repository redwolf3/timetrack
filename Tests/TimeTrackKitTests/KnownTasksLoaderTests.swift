import Foundation
import XCTest
@testable import TimeTrackKit

final class KnownTasksLoaderTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(in dir: URL) throws -> Store {
        try Store(url: dir.appendingPathComponent("test.db"))
    }

    private func writeYAML(_ content: String, to dir: URL, name: String = "known_tasks.yaml") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Test 1: Missing file → returns 0, registry empty

    func testMissingFileReturnsZeroAndRegistryEmpty() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)
        let missing = dir.appendingPathComponent("nonexistent.yaml")

        let count = try KnownTasksLoader.ingest(from: missing, into: store)
        XCTAssertEqual(count, 0, "missing file must be a silent no-op returning 0")

        let all = try store.knownTasks(activeOnly: false)
        XCTAssertTrue(all.isEmpty, "no registry rows should exist when file is absent")
    }

    // MARK: - Test 2: Fresh ingest of a keyed entry

    func testFreshIngestOfKeyedEntryInsertsOne() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        known_tasks:
          - jiraKey: PROJ-1
            description: "Build the widget"
        """
        let url = try writeYAML(yaml, to: dir)

        let count = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(count, 1, "should insert 1 new keyed entry")

        let all = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(all.count, 1)
        let task = try XCTUnwrap(all.first)
        XCTAssertFalse(task.provisional, "keyed entry must not be provisional")
        XCTAssertEqual(task.jiraKey, "PROJ-1")
        XCTAssertEqual(task.description, "Build the widget")
    }

    // MARK: - Test 3: Fresh ingest of a provisional entry (no jiraKey)

    func testFreshIngestOfProvisionalEntryInsertsOne() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        known_tasks:
          - description: "Some provisional thing"
        """
        let url = try writeYAML(yaml, to: dir)

        let count = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(count, 1, "should insert 1 provisional entry")

        let all = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(all.count, 1)
        let task = try XCTUnwrap(all.first)
        XCTAssertTrue(task.provisional, "entry without jiraKey must be provisional")
        XCTAssertNil(task.jiraKey, "provisional entry must have nil jiraKey")
        XCTAssertEqual(task.description, "Some provisional thing")
    }

    // MARK: - Test 4: Re-ingest of the same file → returns 0 (idempotent)

    func testReIngestSameFileIsIdempotent() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        known_tasks:
          - jiraKey: PROJ-1
            description: "Build the widget"
          - description: "Some provisional thing"
        """
        let url = try writeYAML(yaml, to: dir)

        let first = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(first, 2, "first ingest should insert 2 entries")

        let second = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(second, 0, "re-ingest of unchanged file must return 0")

        let all = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(all.count, 2, "no duplicate rows should be created")
    }

    // MARK: - Test 5: Keyed entry description changed on re-ingest → updates in place

    func testChangedDescriptionUpdatesInPlace() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml1 = """
        known_tasks:
          - jiraKey: PROJ-5
            description: "Old description"
        """
        let url = try writeYAML(yaml1, to: dir)
        _ = try KnownTasksLoader.ingest(from: url, into: store)

        let allBefore = try store.knownTasks(activeOnly: false)
        let originalId = try XCTUnwrap(allBefore.first?.id)

        let yaml2 = """
        known_tasks:
          - jiraKey: PROJ-5
            description: "New description"
        """
        _ = try writeYAML(yaml2, to: dir)

        let count = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(count, 1, "description change counts as 1 update")

        let allAfter = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(allAfter.count, 1, "no new row should be created")
        let updated = try XCTUnwrap(allAfter.first { $0.id == originalId })
        XCTAssertEqual(updated.description, "New description", "description should be updated")
        XCTAssertEqual(updated.jiraKey, "PROJ-5", "jiraKey must remain unchanged")
        XCTAssertEqual(updated.id, originalId, "row id must not change on update")
    }

    // MARK: - Test 6: Promote path

    func testPromotePathAssignsjiraKeyToProvisionalEntry() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        // Pre-seed a provisional entry via the store API.
        let provisional = try store.addKnownTask(jiraKey: nil, description: "My feature work")
        let provisionalId = try XCTUnwrap(provisional.id)

        // Ingest a file that keys this same description.
        let yaml = """
        known_tasks:
          - jiraKey: PROJ-9
            description: "My feature work"
        """
        let url = try writeYAML(yaml, to: dir)

        let count = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(count, 1, "promote counts as 1 change")

        let all = try store.knownTasks(activeOnly: false)
        // The SAME registry id must be present — not a new row.
        XCTAssertEqual(all.count, 1, "promote must not insert a new row (total count stays 1)")

        let promoted = try XCTUnwrap(all.first { $0.id == provisionalId })
        XCTAssertFalse(promoted.provisional, "promoted entry must not be provisional")
        XCTAssertEqual(promoted.jiraKey, "PROJ-9", "promoted entry must carry the new jiraKey")
        XCTAssertEqual(promoted.id, provisionalId, "id must be the same as pre-seeded provisional")

        // Re-ingest is idempotent.
        let second = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(second, 0, "re-ingest after promote must return 0")
    }

    // MARK: - Test 7: Key match wins over provisional description match

    func testKeyMatchWinsOverProvisionalDescriptionMatch() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        // Seed a keyed entry with PROJ-1.
        _ = try store.addKnownTask(jiraKey: "PROJ-1", description: "Widget work")
        // Seed a provisional with the same description.
        _ = try store.addKnownTask(jiraKey: nil, description: "Widget work")

        let allBefore = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(allBefore.count, 2, "pre-condition: 2 entries seeded")

        // Ingest a keyed entry that matches the existing key.
        let yaml = """
        known_tasks:
          - jiraKey: PROJ-1
            description: "Widget work"
        """
        let url = try writeYAML(yaml, to: dir)

        let count = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(count, 0, "keyed match with same description = no-op")

        let allAfter = try store.knownTasks(activeOnly: false)
        // Still 2 rows: the key match consumed the entry, provisional untouched.
        XCTAssertEqual(allAfter.count, 2, "no new row should be created")
    }

    // MARK: - Test 8: Whitespace-only jiraKey treated as provisional

    func testWhitespaceOnlyJiraKeyTreatedAsProvisional() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        known_tasks:
          - jiraKey: "   "
            description: "Provisional due to whitespace key"
        """
        let url = try writeYAML(yaml, to: dir)

        let count = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(count, 1, "whitespace-only jiraKey should insert a provisional entry")

        let all = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(all.count, 1)
        let task = try XCTUnwrap(all.first)
        XCTAssertTrue(task.provisional, "whitespace-only jiraKey must result in provisional entry")
        XCTAssertNil(task.jiraKey, "whitespace-only jiraKey must be stored as nil")
    }

    // MARK: - Test 9: Empty/whitespace description → throws .emptyDescription

    func testEmptyDescriptionThrowsValidationError() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let url = try writeYAML("known_tasks:\n  - jiraKey: PROJ-1\n    description: \"\"\n", to: dir)

        XCTAssertThrowsError(try KnownTasksLoader.ingest(from: url, into: store)) { error in
            guard case KnownTasksLoader.ValidationError.emptyDescription = error else {
                return XCTFail("expected .emptyDescription, got \(error)")
            }
        }
    }

    func testWhitespaceOnlyDescriptionThrowsEmptyDescription() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let url = try writeYAML("known_tasks:\n  - description: \"   \"\n", to: dir)

        XCTAssertThrowsError(try KnownTasksLoader.ingest(from: url, into: store)) { error in
            guard case KnownTasksLoader.ValidationError.emptyDescription = error else {
                return XCTFail("expected .emptyDescription, got \(error)")
            }
        }
    }

    // MARK: - Test 10: Duplicate jiraKey in file → throws .duplicateJiraKey

    func testDuplicateJiraKeyInFileThrows() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        known_tasks:
          - jiraKey: PROJ-1
            description: "First"
          - jiraKey: PROJ-1
            description: "Second"
        """
        let url = try writeYAML(yaml, to: dir)

        XCTAssertThrowsError(try KnownTasksLoader.ingest(from: url, into: store)) { error in
            guard case KnownTasksLoader.ValidationError.duplicateJiraKey(let key) = error else {
                return XCTFail("expected .duplicateJiraKey, got \(error)")
            }
            XCTAssertEqual(key, "PROJ-1")
        }
    }

    // MARK: - Test 11: Duplicate provisional description in file → throws .duplicateProvisionalDescription

    func testDuplicateProvisionalDescriptionInFileThrows() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        known_tasks:
          - description: "Same provisional description"
          - description: "Same provisional description"
        """
        let url = try writeYAML(yaml, to: dir)

        XCTAssertThrowsError(try KnownTasksLoader.ingest(from: url, into: store)) { error in
            guard case KnownTasksLoader.ValidationError.duplicateProvisionalDescription(let desc) = error else {
                return XCTFail("expected .duplicateProvisionalDescription, got \(error)")
            }
            XCTAssertEqual(desc, "Same provisional description")
        }
    }

    // MARK: - Test 12: Two registry entries with same jiraKey → throws .ambiguousJiraKey

    func testAmbiguousJiraKeyInRegistryThrows() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        // Pre-seed two entries with the same jiraKey (bypassing the loader).
        let a = try store.addKnownTask(jiraKey: "PROJ-DUP", description: "Entry A")
        let b = try store.addKnownTask(jiraKey: "PROJ-DUP", description: "Entry B")
        let aId = try XCTUnwrap(a.id)
        let bId = try XCTUnwrap(b.id)

        let yaml = """
        known_tasks:
          - jiraKey: PROJ-DUP
            description: "Some description"
        """
        let url = try writeYAML(yaml, to: dir)

        XCTAssertThrowsError(try KnownTasksLoader.ingest(from: url, into: store)) { error in
            guard case KnownTasksLoader.ValidationError.ambiguousJiraKey(let key, let ids) = error else {
                return XCTFail("expected .ambiguousJiraKey, got \(error)")
            }
            XCTAssertEqual(key, "PROJ-DUP")
            XCTAssertEqual(Set(ids), Set([aId, bId]))
        }
    }

    // MARK: - Test 13: Two provisional entries with same description → throws .ambiguousProvisionalDescription

    func testAmbiguousProvisionalDescriptionInRegistryThrows() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        // Pre-seed two provisional entries with the same description.
        let a = try store.addKnownTask(jiraKey: nil, description: "Ambiguous provisional")
        let b = try store.addKnownTask(jiraKey: nil, description: "Ambiguous provisional")
        let aId = try XCTUnwrap(a.id)
        let bId = try XCTUnwrap(b.id)

        // Ingest a keyed entry with the same description (no key match, triggers provisional search).
        let yaml = """
        known_tasks:
          - jiraKey: PROJ-NEW
            description: "Ambiguous provisional"
        """
        let url = try writeYAML(yaml, to: dir)

        XCTAssertThrowsError(try KnownTasksLoader.ingest(from: url, into: store)) { error in
            guard case KnownTasksLoader.ValidationError.ambiguousProvisionalDescription(let desc, let ids) = error else {
                return XCTFail("expected .ambiguousProvisionalDescription, got \(error)")
            }
            XCTAssertEqual(desc, "Ambiguous provisional")
            XCTAssertEqual(Set(ids), Set([aId, bId]))
        }
    }

    // MARK: - Test 14: Retired entry not resurrected

    func testRetiredEntryNotResurrected() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        // Add a keyed entry and retire it.
        let task = try store.addKnownTask(jiraKey: "PROJ-RET", description: "Will be retired")
        let taskId = try XCTUnwrap(task.id)
        _ = try store.retireKnownTask(id: taskId)

        // Verify it's retired before ingest.
        let beforeIngest = try store.knownTasks(activeOnly: false)
        let retiredTask = try XCTUnwrap(beforeIngest.first { $0.id == taskId })
        XCTAssertTrue(retiredTask.retired, "pre-condition: entry should be retired")

        // Ingest the file with the same key and SAME description → returns 0.
        let yaml = """
        known_tasks:
          - jiraKey: PROJ-RET
            description: "Will be retired"
        """
        let url = try writeYAML(yaml, to: dir)

        let count = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(count, 0, "retired entry with unchanged description → no change")

        let afterIngest = try store.knownTasks(activeOnly: false)
        let stillRetired = try XCTUnwrap(afterIngest.first { $0.id == taskId })
        XCTAssertTrue(stillRetired.retired, "retired entry must NOT be resurrected by ingest")
    }

    func testRetiredEntryDescriptionUpdatedButStaysRetired() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        // Add and retire a keyed entry.
        let task = try store.addKnownTask(jiraKey: "PROJ-RETUPD", description: "Old description")
        let taskId = try XCTUnwrap(task.id)
        _ = try store.retireKnownTask(id: taskId)

        // Ingest with changed description → should update in place (count 1) but remain retired.
        let yaml = """
        known_tasks:
          - jiraKey: PROJ-RETUPD
            description: "New description"
        """
        let url = try writeYAML(yaml, to: dir)

        let count = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(count, 1, "description change on retired entry counts as 1 update")

        let afterIngest = try store.knownTasks(activeOnly: false)
        let updated = try XCTUnwrap(afterIngest.first { $0.id == taskId })
        XCTAssertTrue(updated.retired, "retired entry must remain retired after description update")
        XCTAssertEqual(updated.description, "New description", "description should be updated")
    }

    // MARK: - Test 15: Entries absent from the file are left untouched

    func testAbsentEntryLeftUntouched() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        // Seed an entry that won't appear in the ingest file.
        let absent = try store.addKnownTask(jiraKey: "ABSENT-1", description: "I'm not in the file")
        let absentId = try XCTUnwrap(absent.id)

        // Ingest a file with a different entry.
        let yaml = """
        known_tasks:
          - jiraKey: NEW-1
            description: "Brand new entry"
        """
        let url = try writeYAML(yaml, to: dir)

        _ = try KnownTasksLoader.ingest(from: url, into: store)

        // The absent entry must still exist, untouched.
        let all = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(all.count, 2, "absent entry must not be removed")
        let stillPresent = try XCTUnwrap(all.first { $0.id == absentId })
        XCTAssertEqual(stillPresent.jiraKey, "ABSENT-1", "absent entry jiraKey must be unchanged")
        XCTAssertEqual(stillPresent.description, "I'm not in the file", "absent entry description must be unchanged")
        XCTAssertFalse(stillPresent.retired, "absent entry must not be retired")
    }

    // MARK: - Additional edge cases

    func testWhitespaceTrimmedFromDescriptionAndKey() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        known_tasks:
          - jiraKey: "  PROJ-TRIM  "
            description: "  Padded description  "
        """
        let url = try writeYAML(yaml, to: dir)

        _ = try KnownTasksLoader.ingest(from: url, into: store)

        let all = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].jiraKey, "PROJ-TRIM", "jiraKey must be trimmed")
        XCTAssertEqual(all[0].description, "Padded description", "description must be trimmed")
    }

    func testNewlineInDescriptionTrimmed() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = "known_tasks:\n  - description: \"\\n\\tPadded\\n\"\n"
        let url = try writeYAML(yaml, to: dir)

        _ = try KnownTasksLoader.ingest(from: url, into: store)

        let all = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].description, "Padded", "description must be trimmed of newlines and tabs")
    }

    func testSameDescriptionCanAppearOnceKeyedAndOnceProvisional() throws {
        // Per the implementation: "the same description may appear once keyed and
        // once provisional without colliding" (separate namespaces).
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let yaml = """
        known_tasks:
          - jiraKey: PROJ-1
            description: "Shared description"
          - description: "Shared description"
        """
        let url = try writeYAML(yaml, to: dir)

        // This should NOT throw — keyed vs provisional are separate namespaces.
        let count = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(count, 2, "keyed and provisional with same description are separate entries")

        let all = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(all.count, 2)
    }
}
