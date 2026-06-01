import XCTest
@testable import TimeTrackKit

// Tests for Store.currentStatus() — the event-log reader the CLI uses to
// determine current tracking state without an in-memory Tracker instance.
final class CLIStatusTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() throws -> Store {
        let dir = try makeTmpDir()
        return try Store(url: dir.appendingPathComponent("test.db"))
    }

    private func appendEvent(_ store: Store, ts: Int64, type: EventType,
                              taskId: Int64? = nil, prevTaskId: Int64? = nil,
                              phaseId: String? = nil) throws {
        try store.append(Event(
            id: nil, ts: ts, type: type.rawValue,
            taskId: taskId, prevTaskId: prevTaskId,
            phaseId: phaseId, profileName: nil,
            extendMin: nil, comment: nil))
    }

    private func makeTask(_ store: Store, name: String) throws -> Task {
        var t = Task(id: nil, name: name, code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        return t
    }

    private let t0: Int64 = 1_000_000_000  // fixed epoch ms

    // MARK: - Idle states

    func testIdleWhenNoEvents() throws {
        let store = try makeStore()
        let status = try store.currentStatus()
        guard case .idle = status else {
            return XCTFail("expected .idle, got \(status)")
        }
    }

    func testIdleAfterStop() throws {
        let store = try makeStore()
        let task = try makeTask(store, name: "Work")
        try appendEvent(store, ts: t0,          type: .start,  taskId: task.id)
        try appendEvent(store, ts: t0 + 60_000, type: .stop,   prevTaskId: task.id)

        let status = try store.currentStatus()
        guard case .idle = status else {
            return XCTFail("expected .idle after stop, got \(status)")
        }
    }

    // MARK: - Tracking state

    func testTrackingAfterStart() throws {
        let store = try makeStore()
        let task = try makeTask(store, name: "My Task")
        try appendEvent(store, ts: t0, type: .start, taskId: task.id)

        let status = try store.currentStatus()
        guard case .tracking(let t, _) = status else {
            return XCTFail("expected .tracking, got \(status)")
        }
        XCTAssertEqual(t.name, "My Task")
    }

    func testTrackingAfterSwitch() throws {
        let store = try makeStore()
        let taskA = try makeTask(store, name: "Task A")
        let taskB = try makeTask(store, name: "Task B")
        try appendEvent(store, ts: t0,          type: .start,  taskId: taskA.id)
        try appendEvent(store, ts: t0 + 30_000, type: .switch, taskId: taskB.id, prevTaskId: taskA.id)

        let status = try store.currentStatus()
        guard case .tracking(let t, _) = status else {
            return XCTFail("expected .tracking after switch, got \(status)")
        }
        XCTAssertEqual(t.name, "Task B")
    }

    func testSinceReflectsStartTimestamp() throws {
        let store = try makeStore()
        let task = try makeTask(store, name: "Timed")
        let startTs = t0
        try appendEvent(store, ts: startTs, type: .start, taskId: task.id)

        let status = try store.currentStatus()
        guard case .tracking(_, let since) = status else {
            return XCTFail("expected .tracking, got \(status)")
        }
        let expectedSince = Date(timeIntervalSince1970: Double(startTs) / 1000.0)
        XCTAssertEqual(since.timeIntervalSince1970, expectedSince.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testSinceUpdatesAfterSwitch() throws {
        let store = try makeStore()
        let taskA = try makeTask(store, name: "A")
        let taskB = try makeTask(store, name: "B")
        try appendEvent(store, ts: t0,           type: .start,  taskId: taskA.id)
        let switchTs = t0 + 120_000
        try appendEvent(store, ts: switchTs, type: .switch, taskId: taskB.id, prevTaskId: taskA.id)

        let status = try store.currentStatus()
        guard case .tracking(_, let since) = status else {
            return XCTFail("expected .tracking, got \(status)")
        }
        let expectedSince = Date(timeIntervalSince1970: Double(switchTs) / 1000.0)
        XCTAssertEqual(since.timeIntervalSince1970, expectedSince.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    // MARK: - Armed state

    func testArmedAfterPhaseArm() throws {
        let store = try makeStore()
        let task = try makeTask(store, name: "Focus")
        try appendEvent(store, ts: t0,          type: .start,    taskId: task.id, phaseId: "work")
        try appendEvent(store, ts: t0 + 900_000, type: .phaseArm, taskId: task.id, phaseId: "work")

        let status = try store.currentStatus()
        guard case .armed(let t, let phase, _) = status else {
            return XCTFail("expected .armed, got \(status)")
        }
        XCTAssertEqual(t.name, "Focus")
        XCTAssertEqual(phase, "work")
    }

    func testArmedSinceIsOriginalStartNotArmTime() throws {
        let store = try makeStore()
        let task = try makeTask(store, name: "Focus")
        let startTs = t0
        try appendEvent(store, ts: startTs,         type: .start,    taskId: task.id)
        try appendEvent(store, ts: startTs + 900_000, type: .phaseArm, taskId: task.id)

        let status = try store.currentStatus()
        guard case .armed(_, _, let since) = status else {
            return XCTFail("expected .armed, got \(status)")
        }
        // since should be the original start timestamp, not the arm time
        let expectedSince = Date(timeIntervalSince1970: Double(startTs) / 1000.0)
        XCTAssertEqual(since.timeIntervalSince1970, expectedSince.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    // MARK: - Non-state events are ignored

    func testIrrelevantEventsDoNotChangeState() throws {
        let store = try makeStore()
        let task = try makeTask(store, name: "Work")
        try appendEvent(store, ts: t0,           type: .start,        taskId: task.id)
        // These events must not affect the derived state.
        try appendEvent(store, ts: t0 + 10_000, type: .interruption, taskId: task.id)
        try appendEvent(store, ts: t0 + 20_000, type: .idleGap,      taskId: task.id)

        let status = try store.currentStatus()
        guard case .tracking(let t, _) = status else {
            return XCTFail("expected .tracking, got \(status)")
        }
        XCTAssertEqual(t.name, "Work")
    }
}
