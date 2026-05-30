import XCTest
@testable import TimeTrackKit

final class RegistryTests: XCTestCase {

    func testAddWithJiraKeyIsNotProvisional() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        let task = try store.addKnownTask(jiraKey: "ABC-1", description: "A real task")

        XCTAssertFalse(task.provisional)
        XCTAssertEqual(task.jiraKey, "ABC-1")
    }

    func testAddWithoutJiraKeyIsProvisional() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        let task = try store.addKnownTask(jiraKey: nil, description: "A provisional task")

        XCTAssertTrue(task.provisional)
        XCTAssertNil(task.jiraKey)
    }

    func testPromoteSetsKeyAndClearsProvisional() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        let provisional = try store.addKnownTask(jiraKey: nil, description: "Needs a key")
        let id = try XCTUnwrap(provisional.id)

        try store.promoteKnownTask(id: id, jiraKey: "PROJ-42")

        let all = try store.knownTasks()
        let promoted = try XCTUnwrap(all.first { $0.id == id })
        XCTAssertFalse(promoted.provisional)
        XCTAssertEqual(promoted.jiraKey, "PROJ-42")
    }

    // Key invariant: binds reference the registry id, not the key string.
    // Promoting a provisional entry propagates to all existing bindings automatically —
    // no re-binding is needed because the stored knownTaskId is stable.
    func testPromotePropagatesViaRegistryId() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        // Create a capture task.
        var captureTask = Task(id: nil, name: "Feature work", code: nil, category: "project", archived: false)
        captureTask = try store.upsertTask(captureTask)
        let captureTaskId = try XCTUnwrap(captureTask.id)

        // Add a provisional KnownTask (no jiraKey).
        let provisional = try store.addKnownTask(jiraKey: nil, description: "Provisional feature")
        let knownTaskId = try XCTUnwrap(provisional.id)

        // Bind the capture task to the provisional KnownTask.
        try store.bind(taskId: captureTaskId, knownTaskId: knownTaskId, comment: nil)

        // Verify the binding exists before promotion.
        let bindingsBefore = try store.bindings()
        XCTAssertEqual(bindingsBefore[captureTaskId], knownTaskId)

        // Promote the KnownTask with a real jira key.
        try store.promoteKnownTask(id: knownTaskId, jiraKey: "FEAT-99")

        // The binding still maps to the same KnownTask id — no re-binding was needed.
        let bindingsAfter = try store.bindings()
        XCTAssertEqual(bindingsAfter[captureTaskId], knownTaskId)

        // The KnownTask now has the real key and is no longer provisional.
        let allTasks = try store.knownTasks()
        let promoted = try XCTUnwrap(allTasks.first { $0.id == knownTaskId })
        XCTAssertEqual(promoted.jiraKey, "FEAT-99")
        XCTAssertFalse(promoted.provisional)
    }

    func testRetireExcludesFromActiveList() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        let kept = try store.addKnownTask(jiraKey: "KEEP-1", description: "Keep me")
        let retired = try store.addKnownTask(jiraKey: "GONE-1", description: "Retire me")
        let retiredId = try XCTUnwrap(retired.id)
        let keptId = try XCTUnwrap(kept.id)

        try store.retireKnownTask(id: retiredId)

        let active = try store.knownTasks(activeOnly: true)
        XCTAssertTrue(active.contains { $0.id == keptId }, "kept task should appear in active list")
        XCTAssertFalse(active.contains { $0.id == retiredId }, "retired task should not appear in active list")

        let all = try store.knownTasks(activeOnly: false)
        XCTAssertTrue(all.contains { $0.id == keptId }, "kept task should appear in full list")
        XCTAssertTrue(all.contains { $0.id == retiredId }, "retired task should appear in full list")
    }

    func testKnownTasksDefaultActiveOnly() throws {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))

        let active = try store.addKnownTask(jiraKey: "ACT-1", description: "Active task")
        let toRetire = try store.addKnownTask(jiraKey: "OLD-1", description: "To be retired")
        let retiredId = try XCTUnwrap(toRetire.id)
        let activeId = try XCTUnwrap(active.id)

        try store.retireKnownTask(id: retiredId)

        // Default call with no argument should exclude retired entries.
        let defaultResult = try store.knownTasks()
        XCTAssertTrue(defaultResult.contains { $0.id == activeId }, "active task should appear by default")
        XCTAssertFalse(defaultResult.contains { $0.id == retiredId }, "retired task should be excluded by default")
    }
}
