import XCTest
@testable import TimeTrackKit

// State-machine tests for Tracker.  All @MainActor methods are reached via
// MainActor.assumeIsolated (XCTest sync methods run on the main thread, which is
// the main-actor executor on both macOS and Linux).
//
// The Tracker's 1Hz Timer is a no-op in tests: tests drive ticks explicitly via
// tick(at:) with synthetic dates, so real wall-clock time is irrelevant.
final class TrackerStateMachineTests: XCTestCase {

    // Creates a fresh Tracker + Store for one test.  Each test gets its own
    // temp directory so tests are fully isolated.
    private func makeCtx() throws -> (tracker: Tracker, store: Store, taskId: Int64) {
        let dir = try makeTmpDir()
        return try MainActor.assumeIsolated { try makeTrackerContext(in: dir) }
    }

    // MARK: - ARM invariant: never auto-advances

    // The state machine must freeze at .armed indefinitely; only user
    // acknowledgment (advance/extend/switch) may change the state.
    func testArmNeverAutoAdvances() throws {
        let (tracker, _, taskId) = try makeCtx()

        MainActor.assumeIsolated {
            tracker.start(taskId: taskId)
            tracker.tick(at: Date().addingTimeInterval(3 * 60 * 60))
        }

        let isArmed = MainActor.assumeIsolated {
            if case .armed = tracker.state { return true }
            return false
        }
        XCTAssertTrue(isArmed, "After tick past deadline the state must be .armed")

        // Many more ticks even further in the future: still armed.
        MainActor.assumeIsolated {
            for _ in 0..<10 { tracker.tick(at: Date().addingTimeInterval(24 * 60 * 60)) }
        }

        let stillArmed = MainActor.assumeIsolated {
            if case .armed = tracker.state { return true }
            return false
        }
        XCTAssertTrue(stillArmed, "ARM must not auto-advance — it freezes until the user acks")
    }

    // MARK: - advance() while armed

    // Acknowledging the arm advances to the next phase and returns to .tracking.
    func testAdvanceWhileArmedTransitionsToNextPhase() throws {
        let (tracker, _, taskId) = try makeCtx()

        MainActor.assumeIsolated {
            tracker.start(taskId: taskId)
            tracker.tick(at: Date().addingTimeInterval(3 * 60 * 60))
        }
        MainActor.assumeIsolated { tracker.advance() }

        let isTracking = MainActor.assumeIsolated {
            if case let .tracking(_, phase, _) = tracker.state {
                // Default profile has one work phase; cycling back gives "work" again.
                return phase.id == "work"
            }
            return false
        }
        XCTAssertTrue(isTracking, "advance() must move state to .tracking on the next phase")
    }

    // Calling advance() when not armed must be a no-op (state stays .tracking).
    func testAdvanceWhileTrackingIsNoOp() throws {
        let (tracker, _, taskId) = try makeCtx()

        MainActor.assumeIsolated { tracker.start(taskId: taskId) }

        let deadlineBefore = MainActor.assumeIsolated { () -> Date? in
            if case let .tracking(_, _, dl) = tracker.state { return dl }
            return nil
        }
        XCTAssertNotNil(deadlineBefore)

        MainActor.assumeIsolated { tracker.advance() }

        let stateAfter = MainActor.assumeIsolated { tracker.state }
        if case let .tracking(tid, _, dl) = stateAfter {
            XCTAssertEqual(tid, taskId)
            XCTAssertEqual(dl, deadlineBefore!, "deadline must be unchanged")
        } else {
            XCTFail("advance() from .tracking must be a no-op; got \(stateAfter)")
        }
    }

    // MARK: - extend() while armed

    // extend() returns to .tracking with a fresh deadline ~N minutes from now.
    func testExtendWhileArmedReturnsToTrackingWithNewDeadline() throws {
        let (tracker, _, taskId) = try makeCtx()

        MainActor.assumeIsolated {
            tracker.start(taskId: taskId)
            tracker.tick(at: Date().addingTimeInterval(3 * 60 * 60))
        }

        let callTime = Date()
        MainActor.assumeIsolated { tracker.extend(minutes: 15) }

        let stateAfter = MainActor.assumeIsolated { tracker.state }
        if case let .tracking(tid, _, deadline) = stateAfter {
            XCTAssertEqual(tid, taskId)
            let expected = callTime.addingTimeInterval(15 * 60)
            XCTAssertEqual(
                deadline.timeIntervalSinceReferenceDate,
                expected.timeIntervalSinceReferenceDate,
                accuracy: 5,
                "New deadline must be ~15 minutes from the extend() call")
        } else {
            XCTFail("extend() must return state to .tracking; got \(stateAfter)")
        }
    }

    // MARK: - switch() during armed

    // Switching while armed is an implicit ack: advance() fires then the switch
    // occurs, ending up in .tracking on the target task.
    func testSwitchDuringArmedIsImplicitAck() throws {
        let (tracker, store, taskId) = try makeCtx()

        let task2 = try store.upsertTask(
            Task(id: nil, name: "Task2", code: nil, category: "project", archived: false))
        let taskId2 = task2.id!

        MainActor.assumeIsolated {
            tracker.start(taskId: taskId)
            tracker.tick(at: Date().addingTimeInterval(3 * 60 * 60))
        }
        MainActor.assumeIsolated { tracker.switchTo(taskId: taskId2) }

        let stateAfter = MainActor.assumeIsolated { tracker.state }
        if case let .tracking(tid, _, _) = stateAfter {
            XCTAssertEqual(tid, taskId2, "After switch-from-armed the active task must be taskId2")
        } else {
            XCTFail("switchTo() from .armed must leave state as .tracking; got \(stateAfter)")
        }
    }

    // MARK: - switch() during tracking

    // Switching while tracking changes the active task but preserves the
    // current phase and deadline.
    func testSwitchDuringTrackingPreservesPhaseAndDeadline() throws {
        let (tracker, store, taskId) = try makeCtx()

        let task2 = try store.upsertTask(
            Task(id: nil, name: "Task2", code: nil, category: "project", archived: false))
        let taskId2 = task2.id!

        MainActor.assumeIsolated { tracker.start(taskId: taskId) }

        let before = MainActor.assumeIsolated { () -> (String, Date)? in
            if case let .tracking(_, phase, dl) = tracker.state { return (phase.id, dl) }
            return nil
        }
        guard let (phaseId, deadlineBefore) = before else {
            XCTFail("Expected .tracking after start()"); return
        }

        MainActor.assumeIsolated { tracker.switchTo(taskId: taskId2) }

        let after = MainActor.assumeIsolated { tracker.state }
        if case let .tracking(tid, phase, deadline) = after {
            XCTAssertEqual(tid, taskId2)
            XCTAssertEqual(phase.id, phaseId,       "Phase must be unchanged after switch")
            XCTAssertEqual(deadline, deadlineBefore, "Deadline must be unchanged after switch")
        } else {
            XCTFail("Expected .tracking after switch; got \(after)")
        }
    }

    // MARK: - stop()

    // stop() from .tracking resets to .idle.
    func testStopFromTrackingResetsToIdle() throws {
        let (tracker, _, taskId) = try makeCtx()

        MainActor.assumeIsolated { tracker.start(taskId: taskId) }
        MainActor.assumeIsolated { tracker.stop() }

        XCTAssertEqual(
            MainActor.assumeIsolated { tracker.state }, .idle,
            "stop() from .tracking must return to .idle")
    }

    // stop() from .armed also resets to .idle (cycle freeze must not survive a stop).
    func testStopFromArmedResetsToIdle() throws {
        let (tracker, _, taskId) = try makeCtx()

        MainActor.assumeIsolated {
            tracker.start(taskId: taskId)
            tracker.tick(at: Date().addingTimeInterval(3 * 60 * 60))
        }
        MainActor.assumeIsolated { tracker.stop() }

        XCTAssertEqual(
            MainActor.assumeIsolated { tracker.state }, .idle,
            "stop() from .armed must reset to .idle")
    }

    // stop() from .idle is a no-op — must not crash.
    func testStopFromIdleIsNoOp() throws {
        let (tracker, _, _) = try makeCtx()

        MainActor.assumeIsolated { tracker.stop() }

        XCTAssertEqual(
            MainActor.assumeIsolated { tracker.state }, .idle,
            "stop() from .idle must leave state unchanged")
    }

    // MARK: - start()

    // start() from .idle enters .tracking.
    func testStartFromIdleEntersTracking() throws {
        let (tracker, _, taskId) = try makeCtx()

        MainActor.assumeIsolated { tracker.start(taskId: taskId) }

        let isTracking = MainActor.assumeIsolated {
            if case let .tracking(tid, _, _) = tracker.state { return tid == taskId }
            return false
        }
        XCTAssertTrue(isTracking, "start() from .idle must enter .tracking on the given task")
    }

    // start() from .tracking stops the current session and begins a new one.
    func testStartFromTrackingRestarts() throws {
        let (tracker, store, taskId) = try makeCtx()

        let task2 = try store.upsertTask(
            Task(id: nil, name: "Task2", code: nil, category: "project", archived: false))
        let taskId2 = task2.id!

        MainActor.assumeIsolated { tracker.start(taskId: taskId) }
        MainActor.assumeIsolated { tracker.start(taskId: taskId2) }

        let activeId = MainActor.assumeIsolated { () -> Int64? in
            if case let .tracking(tid, _, _) = tracker.state { return tid }
            return nil
        }
        XCTAssertEqual(activeId, taskId2, "Second start() must switch to the new task")
    }
}
