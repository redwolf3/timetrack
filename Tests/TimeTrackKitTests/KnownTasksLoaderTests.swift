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

    func testPromotePathAssignsJiraKeyToProvisionalEntry() throws {
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
            guard case KnownTasksLoader.ValidationError.emptyDescription(let source) = error else {
                return XCTFail("expected .emptyDescription, got \(error)")
            }
            XCTAssertEqual(source, "known_tasks.yaml")
        }
    }

    func testWhitespaceOnlyDescriptionThrowsEmptyDescription() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let url = try writeYAML("known_tasks:\n  - description: \"   \"\n", to: dir)

        XCTAssertThrowsError(try KnownTasksLoader.ingest(from: url, into: store)) { error in
            guard case KnownTasksLoader.ValidationError.emptyDescription(let source) = error else {
                return XCTFail("expected .emptyDescription, got \(error)")
            }
            XCTAssertEqual(source, "known_tasks.yaml")
        }
    }

    // The refactor that shared validation across every reader moved trimming
    // out of validateWithinFile and into each decoder independently — the
    // decoders all trim before constructing a KnownTaskEntry, but the seam
    // itself (ingest(entries:...)) did not, so a caller that builds a
    // KnownTaskEntry directly (bypassing every decoder) could sneak a
    // whitespace-only description past validation. Tested directly against the
    // public seam, not through a decoder, so this holds regardless of which
    // reader is ever added next.
    func testWhitespaceOnlyDescriptionRejectedAtThePublicSeamDirectly() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let entries = [KnownTasksLoader.KnownTaskEntry(description: "   ", jiraKey: nil)]

        XCTAssertThrowsError(
            try KnownTasksLoader.ingest(entries: entries, into: store, sourceName: "direct.json")
        ) { error in
            guard case KnownTasksLoader.ValidationError.emptyDescription(let source) = error else {
                return XCTFail("expected .emptyDescription, got \(error)")
            }
            XCTAssertEqual(source, "direct.json")
        }

        XCTAssertTrue(try store.knownTasks(activeOnly: false).isEmpty, "rejected entry must not have been inserted")
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
            guard case KnownTasksLoader.ValidationError.duplicateJiraKey(let key, let source) = error else {
                return XCTFail("expected .duplicateJiraKey, got \(error)")
            }
            XCTAssertEqual(key, "PROJ-1")
            XCTAssertEqual(source, "known_tasks.yaml")
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
            guard case KnownTasksLoader.ValidationError.duplicateProvisionalDescription(let desc, let source) = error else {
                return XCTFail("expected .duplicateProvisionalDescription, got \(error)")
            }
            XCTAssertEqual(desc, "Same provisional description")
            XCTAssertEqual(source, "known_tasks.yaml")
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
            guard case KnownTasksLoader.ValidationError.ambiguousJiraKey(let key, let ids, let source) = error else {
                return XCTFail("expected .ambiguousJiraKey, got \(error)")
            }
            XCTAssertEqual(key, "PROJ-DUP")
            XCTAssertEqual(Set(ids), Set([aId, bId]))
            XCTAssertEqual(source, "known_tasks.yaml")
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
            guard case KnownTasksLoader.ValidationError.ambiguousProvisionalDescription(let desc, let ids, let source) = error else {
                return XCTFail("expected .ambiguousProvisionalDescription, got \(error)")
            }
            XCTAssertEqual(desc, "Ambiguous provisional")
            XCTAssertEqual(Set(ids), Set([aId, bId]))
            XCTAssertEqual(source, "known_tasks.yaml")
        }
    }

    // Reproduces the reported bug directly: a registry holding a pre-existing
    // ambiguous jiraKey (two rows sharing DUP-1) must reject the WHOLE input —
    // including entries earlier in the file than the ambiguous one — rather
    // than partially applying and then throwing mid-loop. Both ambiguousJiraKey
    // and ambiguousProvisionalDescription are pre-scanned from the registry
    // snapshot before any write (KnownTasksLoader.checkAmbiguity), so this must
    // leave the registry byte-for-byte as it started.
    func testAmbiguityFailureLeavesRegistryUnchangedEvenWithEarlierEntries() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let a = try store.addKnownTask(jiraKey: "DUP-1", description: "Entry A")
        let b = try store.addKnownTask(jiraKey: "DUP-1", description: "Entry B")
        let aId = try XCTUnwrap(a.id)
        let bId = try XCTUnwrap(b.id)

        let before = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(before.count, 2, "pre-condition: two ambiguous rows seeded")

        // LATER-1 comes first in the file and would insert cleanly on its own;
        // DUP-1 comes second and is ambiguous. Before the fix, LATER-1 would
        // already be written by the time DUP-1's ambiguity was discovered.
        let entries = [
            KnownTasksLoader.KnownTaskEntry(description: "Brand new", jiraKey: "LATER-1"),
            KnownTasksLoader.KnownTaskEntry(description: "Some description", jiraKey: "DUP-1")
        ]

        XCTAssertThrowsError(
            try KnownTasksLoader.ingest(entries: entries, into: store, sourceName: "sprint-42.json")
        ) { error in
            guard case KnownTasksLoader.ValidationError.ambiguousJiraKey(let key, let ids, let source) = error else {
                return XCTFail("expected .ambiguousJiraKey, got \(error)")
            }
            XCTAssertEqual(key, "DUP-1")
            XCTAssertEqual(Set(ids), Set([aId, bId]))
            XCTAssertEqual(source, "sprint-42.json")
        }

        let after = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(after.count, 2, "no row from the earlier, individually-valid entry must have been inserted")
        XCTAssertFalse(after.contains { $0.jiraKey == "LATER-1" },
                        "LATER-1 must not have been written before the later ambiguity was discovered")
        XCTAssertEqual(Set(after.map { $0.id }), Set([aId, bId]), "the two pre-existing rows must be untouched")
    }

    // Same reproduction for the provisional-description ambiguity branch.
    func testProvisionalAmbiguityFailureLeavesRegistryUnchangedEvenWithEarlierEntries() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let a = try store.addKnownTask(jiraKey: nil, description: "Ambiguous provisional")
        let b = try store.addKnownTask(jiraKey: nil, description: "Ambiguous provisional")
        let aId = try XCTUnwrap(a.id)
        let bId = try XCTUnwrap(b.id)

        let entries = [
            KnownTasksLoader.KnownTaskEntry(description: "Brand new", jiraKey: "LATER-2"),
            KnownTasksLoader.KnownTaskEntry(description: "Ambiguous provisional", jiraKey: "PROJ-NEW")
        ]

        XCTAssertThrowsError(
            try KnownTasksLoader.ingest(entries: entries, into: store, sourceName: "sprint-42.json")
        ) { error in
            guard case KnownTasksLoader.ValidationError.ambiguousProvisionalDescription(let desc, let ids, let source) = error else {
                return XCTFail("expected .ambiguousProvisionalDescription, got \(error)")
            }
            XCTAssertEqual(desc, "Ambiguous provisional")
            XCTAssertEqual(Set(ids), Set([aId, bId]))
            XCTAssertEqual(source, "sprint-42.json")
        }

        let after = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(after.count, 2, "no row from the earlier, individually-valid entry must have been inserted")
        XCTAssertFalse(after.contains { $0.jiraKey == "LATER-2" })
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

    // MARK: - Regression: within-pass snapshot consistency

    // Scenario 1: non-idempotent ingest without snapshot sync.
    //
    // Pre-seed a provisional "X". Ingest a file containing BOTH a keyed entry
    // {PROJ-1, "X"} AND a keyless entry {description: "X"}.
    //
    // Without snapshot sync: the keyless entry still sees "X" as provisional in
    // the stale snapshot and no-ops. On the SECOND ingest the row is now
    // non-provisional, the keyless entry finds no provisional match, and inserts a
    // new provisional row → second ingest returns non-zero (not idempotent).
    //
    // With snapshot sync: after the promote the in-memory snapshot immediately
    // marks the row non-provisional. The keyless entry correctly sees no
    // provisional match and inserts its own distinct provisional on the FIRST
    // pass. The SECOND ingest finds PROJ-1 by key (no-op) and the new provisional
    // by description (no-op) → returns 0. Idempotency is restored.
    func testIngestWithKeyedAndKeylessForSameDescriptionIsIdempotent() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        // Pre-seed a provisional entry that will be promoted by the keyed YAML line.
        _ = try store.addKnownTask(jiraKey: nil, description: "Feature work")

        // YAML has both a keyed entry (promotes the provisional) and a separate
        // keyless entry (distinct provisional intent — two entries in the file,
        // two eventual registry rows).
        let yaml = """
        known_tasks:
          - jiraKey: PROJ-1
            description: "Feature work"
          - description: "Feature work"
        """
        let url = try writeYAML(yaml, to: dir)

        // First ingest: 1 promote + 1 insert of a new provisional = 2 changes.
        // (The snapshot-sync fix makes this correct on the first pass rather than
        // deferring the insert to a second pass.)
        let first = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(first, 2, "first ingest: 1 promote + 1 provisional insert = 2 changes")

        let allAfterFirst = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(allAfterFirst.count, 2, "two registry rows: promoted keyed entry + new provisional")
        XCTAssertTrue(allAfterFirst.contains { $0.jiraKey == "PROJ-1" && !$0.provisional },
                      "promoted row must carry PROJ-1 and be non-provisional")
        XCTAssertTrue(allAfterFirst.contains { $0.provisional && $0.description == "Feature work" },
                      "a separate provisional row must exist for the keyless YAML entry")

        // Second ingest must return 0 — the state already matches the file.
        let second = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(second, 0, "second ingest of same file must return 0 (idempotent)")

        let allAfterSecond = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(allAfterSecond.count, 2, "no new rows created by idempotent second ingest")
    }

    // Scenario 2: double-promote without snapshot sync.
    //
    // Pre-seed a provisional "X". Ingest a file with two keyed entries that both
    // match "X" by description but carry different keys: {PROJ-1, "X"} and
    // {PROJ-2, "X"}. Without snapshot sync both entries find the same provisional
    // row in the stale snapshot and emit two promote events for the same registry
    // id — the second silently overwrites the first. With snapshot sync the first
    // promote marks the row non-provisional in the local copy; the second entry
    // finds no provisional match and inserts a SEPARATE keyed row for PROJ-2.
    func testTwoKeyedEntriesSharingDescriptionDoNotDoublePromoteSameId() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        // Pre-seed a provisional entry.
        let provisional = try store.addKnownTask(jiraKey: nil, description: "Shared feature")
        let provisionalId = try XCTUnwrap(provisional.id)

        let yaml = """
        known_tasks:
          - jiraKey: PROJ-1
            description: "Shared feature"
          - jiraKey: PROJ-2
            description: "Shared feature"
        """
        let url = try writeYAML(yaml, to: dir)

        let count = try KnownTasksLoader.ingest(from: url, into: store)
        XCTAssertEqual(count, 2, "one promote + one insert = 2 changes")

        let all = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(all.count, 2, "exactly two distinct registry entries: promoted + new keyed")

        // The original provisional row must be promoted to PROJ-1 (first match).
        let promoted = try XCTUnwrap(all.first { $0.id == provisionalId })
        XCTAssertFalse(promoted.provisional, "originally-provisional row must now be non-provisional")
        XCTAssertEqual(promoted.jiraKey, "PROJ-1", "first keyed entry wins the promote")

        // PROJ-2 must be a NEW, separate keyed row (different id).
        let proj2 = try XCTUnwrap(all.first { $0.jiraKey == "PROJ-2" })
        XCTAssertNotEqual(proj2.id, provisionalId, "PROJ-2 must be a distinct registry entry, not a double-promote on the same id")
        XCTAssertFalse(proj2.provisional)
    }

    // MARK: - New public seam: ingest(entries:into:sourceName:dryRun:)

    // The entries-based seam must produce the same registry outcome as the YAML
    // path for an equivalent input (docs/interchange-format.md §4.2: JSON/CSV
    // must reuse this exact upsert, not a second implementation).
    func testIngestEntriesProducesSameOutcomeAsYAMLPath() throws {
        let dirYAML = try makeTmpDir()
        let storeYAML = try makeStore(in: dirYAML)
        let yaml = """
        known_tasks:
          - jiraKey: PROJ-1
            description: "Build the widget"
          - description: "Some provisional thing"
        """
        let url = try writeYAML(yaml, to: dirYAML)
        let yamlCount = try KnownTasksLoader.ingest(from: url, into: storeYAML)

        let dirEntries = try makeTmpDir()
        let storeEntries = try makeStore(in: dirEntries)
        let entries = [
            KnownTasksLoader.KnownTaskEntry(description: "Build the widget", jiraKey: "PROJ-1"),
            KnownTasksLoader.KnownTaskEntry(description: "Some provisional thing", jiraKey: nil)
        ]
        let result = try KnownTasksLoader.ingest(entries: entries, into: storeEntries, sourceName: "sprint-42.json")

        XCTAssertEqual(yamlCount, result.changeCount, "entries-based seam must report the same change count as the equivalent YAML ingest")

        let yamlRows = try storeYAML.knownTasks(activeOnly: false)
        let entryRows = try storeEntries.knownTasks(activeOnly: false)
        XCTAssertEqual(yamlRows.count, entryRows.count)
        XCTAssertEqual(Set(yamlRows.map { $0.jiraKey }), Set(entryRows.map { $0.jiraKey }))
        XCTAssertEqual(Set(yamlRows.map { $0.description }), Set(entryRows.map { $0.description }))
        XCTAssertEqual(Set(yamlRows.map { $0.provisional }), Set(entryRows.map { $0.provisional }))
    }

    // Each of the four outcome categories must be reported with the data needed
    // to describe it to a user (docs/interchange-format.md §4.2 dry-run diff).
    func testEachOutcomeCategoryIsReportedCorrectly() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        // Pre-seed registry state for promote / descriptionUpdate / noOp to match against.
        let provisional = try store.addKnownTask(jiraKey: nil, description: "Feature to promote")
        let provisionalId = try XCTUnwrap(provisional.id)
        let stale = try store.addKnownTask(jiraKey: "PROJ-STALE", description: "Old text")
        let staleId = try XCTUnwrap(stale.id)
        let unchanged = try store.addKnownTask(jiraKey: "PROJ-SAME", description: "Already correct")
        let unchangedId = try XCTUnwrap(unchanged.id)

        let entries = [
            KnownTasksLoader.KnownTaskEntry(description: "Brand new entry", jiraKey: "PROJ-NEW"),                 // insert
            KnownTasksLoader.KnownTaskEntry(description: "Feature to promote", jiraKey: "PROJ-PROMOTED"),          // promote
            KnownTasksLoader.KnownTaskEntry(description: "New text", jiraKey: "PROJ-STALE"),                       // descriptionUpdate
            KnownTasksLoader.KnownTaskEntry(description: "Already correct", jiraKey: "PROJ-SAME")                  // noOp
        ]

        let result = try KnownTasksLoader.ingest(entries: entries, into: store, sourceName: "sprint-42.csv")
        XCTAssertEqual(result.changes.count, entries.count, "one Change per input entry")

        guard case .insert = result.changes[0].outcome else {
            return XCTFail("expected .insert, got \(result.changes[0].outcome)")
        }
        guard case .promote(let promotedId) = result.changes[1].outcome else {
            return XCTFail("expected .promote, got \(result.changes[1].outcome)")
        }
        XCTAssertEqual(promotedId, .existing(provisionalId))
        guard case .descriptionUpdate(let updId, let previous) = result.changes[2].outcome else {
            return XCTFail("expected .descriptionUpdate, got \(result.changes[2].outcome)")
        }
        XCTAssertEqual(updId, .existing(staleId))
        XCTAssertEqual(previous, "Old text")
        guard case .noOp(let noOpId) = result.changes[3].outcome else {
            return XCTFail("expected .noOp, got \(result.changes[3].outcome)")
        }
        XCTAssertEqual(noOpId, .existing(unchangedId))

        XCTAssertEqual(result.changeCount, 3, "insert + promote + descriptionUpdate count; noOp does not")
    }

    // `dryRun: true` must write nothing to the store, yet return exactly the
    // same `changes` a subsequent real run would produce.
    func testDryRunWritesNothingButMatchesRealRunChanges() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        _ = try store.addKnownTask(jiraKey: nil, description: "Feature to promote")
        _ = try store.addKnownTask(jiraKey: "PROJ-STALE", description: "Old text")

        let entries = [
            KnownTasksLoader.KnownTaskEntry(description: "Brand new entry", jiraKey: "PROJ-NEW"),
            KnownTasksLoader.KnownTaskEntry(description: "Feature to promote", jiraKey: "PROJ-PROMOTED"),
            KnownTasksLoader.KnownTaskEntry(description: "New text", jiraKey: "PROJ-STALE")
        ]

        let beforeCount = try store.knownTasks(activeOnly: false).count

        let dryResult = try KnownTasksLoader.ingest(entries: entries, into: store, sourceName: "x.json", dryRun: true)

        let afterDryRun = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(afterDryRun.count, beforeCount, "dryRun must perform zero writes (no rows inserted)")
        XCTAssertTrue(afterDryRun.contains { $0.description == "Feature to promote" && $0.provisional },
                      "dryRun must not have promoted the provisional row")
        XCTAssertTrue(afterDryRun.contains { $0.jiraKey == "PROJ-STALE" && $0.description == "Old text" },
                      "dryRun must not have updated the description in the store")

        let realResult = try KnownTasksLoader.ingest(entries: entries, into: store, sourceName: "x.json", dryRun: false)

        XCTAssertEqual(dryResult.changes.map(\.outcome.categoryLabel), realResult.changes.map(\.outcome.categoryLabel),
                        "dry run and the subsequent real run must report the same outcome categories")
        XCTAssertEqual(dryResult.changeCount, realResult.changeCount)

        // Insert outcomes carry no id, so they always match; promote/descriptionUpdate
        // ids must agree between the synthesised dry-run pass and the real pass.
        for (dry, real) in zip(dryResult.changes, realResult.changes) {
            XCTAssertEqual(dry.entry, real.entry)
        }
        if case .promote(let dryId) = dryResult.changes[1].outcome, case .promote(let realId) = realResult.changes[1].outcome {
            XCTAssertEqual(dryId, realId, "promote must target the same real registry id under dryRun as under a real run")
        } else {
            XCTFail("expected both changes[1] to be .promote")
        }
    }

    // Note on scope: a literal pair of textually-identical provisional entries
    // (same description, no jiraKey, twice in one input) is rejected up front by
    // validateWithinFile per docs/interchange-format.md §4.2 rule 8 ("a
    // description repeated among provisional records in the file is an error") —
    // that rule is required and already covered by
    // testDuplicateProvisionalDescriptionInFileThrows, and it fires before the
    // matching loop ever runs, dryRun or not. So "two identical entries" can only
    // legally reach the matching loop when they are identical in description but
    // differ in jiraKey-namespace membership. This test is the dryRun analogue of
    // testTwoKeyedEntriesSharingDescriptionDoNotDoublePromoteSameId: without
    // snapshot sync of the *synthesised* rows, the second entry would re-match the
    // same (still-provisional-looking) row and either double-promote it or, if the
    // sync only ran one level deep, report a phantom second change against the
    // same id. With sync, the second entry correctly sees the first's synthesised
    // promote and inserts a brand-new distinct row instead.
    func testDryRunSnapshotSyncPreventsDoublePromoteOnSharedDescription() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let provisional = try store.addKnownTask(jiraKey: nil, description: "Shared feature")
        let provisionalId = try XCTUnwrap(provisional.id)

        let entries = [
            KnownTasksLoader.KnownTaskEntry(description: "Shared feature", jiraKey: "PROJ-1"),
            KnownTasksLoader.KnownTaskEntry(description: "Shared feature", jiraKey: "PROJ-2")
        ]

        let result = try KnownTasksLoader.ingest(entries: entries, into: store, sourceName: "dup.json", dryRun: true)

        XCTAssertEqual(result.changes.count, 2)
        guard case .promote(let promotedId) = result.changes[0].outcome else {
            return XCTFail("expected first entry to be .promote, got \(result.changes[0].outcome)")
        }
        XCTAssertEqual(promotedId, .existing(provisionalId), "first entry promotes the real pre-existing provisional row")
        guard case .insert = result.changes[1].outcome else {
            return XCTFail("expected second entry to be a distinct .insert (not a double-promote of the same id), got \(result.changes[1].outcome)")
        }

        // dryRun: the store must be untouched — still exactly the one pre-seeded
        // provisional row, still provisional.
        let all = try store.knownTasks(activeOnly: false)
        XCTAssertEqual(all.count, 1, "dryRun must not have written anything")
        XCTAssertTrue(all[0].provisional, "dryRun must not have performed the promote against the store")
    }

    // A validation error raised via the entries seam with a non-YAML source name
    // must render that source name, not the historical "known_tasks.yaml:" literal.
    func testValidationErrorRendersNonYAMLSourceName() throws {
        let dir = try makeTmpDir()
        let store = try makeStore(in: dir)

        let entries = [
            KnownTasksLoader.KnownTaskEntry(description: "", jiraKey: nil)
        ]

        XCTAssertThrowsError(try KnownTasksLoader.ingest(entries: entries, into: store, sourceName: "sprint-42.csv")) { error in
            guard case KnownTasksLoader.ValidationError.emptyDescription(let source) = error else {
                return XCTFail("expected .emptyDescription, got \(error)")
            }
            XCTAssertEqual(source, "sprint-42.csv")
            XCTAssertEqual("\(error)", "sprint-42.csv: description must not be empty")
            XCTAssertFalse("\(error)".contains("known_tasks.yaml"), "error must not name the wrong file")
        }
    }
}

private extension KnownTasksLoader.IngestResult.Outcome {
    // Test-only label so dry-run vs real-run changes can be compared by category
    // without caring about the specific (possibly synthetic) id involved.
    var categoryLabel: String {
        switch self {
        case .insert: return "insert"
        case .promote: return "promote"
        case .descriptionUpdate: return "descriptionUpdate"
        case .noOp: return "noOp"
        }
    }
}
