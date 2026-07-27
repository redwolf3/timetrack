import XCTest
@testable import TimeTrackKit

// Manual phase skip / jump-to-phase (issue #25). Two layers:
//   - CycleIterator.jumpTo(phaseId:) — index moves within the current effective
//     cycle, cycleNumber / long-cycle math untouched, throws for out-of-cycle ids.
//   - Tracker.jumpToPhase(_:) — append-only phase_skip from .tracking and .armed,
//     correct accrual (incl. break-resume), deadline reset; no-op while idle.
final class PhaseSkipTests: XCTestCase {

    private func arm() -> ArmConfig { ArmConfig(sound: "Tink", color: "amber", actions: []) }

    private func assertPos(_ pos: (index: Int, count: Int), _ index: Int, _ count: Int,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pos.index, index, "index", file: file, line: line)
        XCTAssertEqual(pos.count, count, "count", file: file, line: line)
    }

    private func twoPhaseProfile() -> Profile {
        Profile(
            name: "two",
            cycle: [
                Phase(id: "work",        durationMin: 25, accrueAs: nil,     onArm: arm()),
                Phase(id: "short_break", durationMin: 5,  accrueAs: "break", onArm: arm())
            ],
            longCycleEvery: nil, longCycleOverride: nil,
            idleThresholdMin: 5, wiggleRoomMin: 2, escalation: .default)
    }

    // Base cycle = work, short_break (count 2). Every 2nd cycle drops the last
    // base phase and appends short_break + long_break → count 3, long_break in the
    // OVERRIDE only (not the base cycle).
    private func overrideProfile() -> Profile {
        Profile(
            name: "grow",
            cycle: [
                Phase(id: "work",        durationMin: 25, accrueAs: nil,     onArm: arm()),
                Phase(id: "short_break", durationMin: 5,  accrueAs: "break", onArm: arm())
            ],
            longCycleEvery: 2,
            longCycleOverride: [
                Phase(id: "short_break", durationMin: 5,  accrueAs: "break", onArm: arm()),
                Phase(id: "long_break",  durationMin: 15, accrueAs: "break", onArm: arm())
            ],
            idleThresholdMin: 5, wiggleRoomMin: 2, escalation: .default)
    }

    // MARK: - CycleIterator.jumpTo

    // Tracer bullet: jumping to another phase in the current cycle moves the index
    // to it without changing the cycle's length (cycleNumber untouched).
    func testJumpToMovesIndexWithinCycle() throws {
        let it = CycleIterator(profile: twoPhaseProfile())
        XCTAssertEqual(it.currentPhase.id, "work")

        let landed = try it.jumpTo(phaseId: "short_break")
        XCTAssertEqual(landed.id, "short_break")
        XCTAssertEqual(it.currentPhase.id, "short_break")
        assertPos(it.cyclePosition, 2, 2)
    }

    // An id that isn't in the current effective cycle is rejected (the deferred
    // override-only-not-due case surfaces here as a throw, not a silent no-op).
    func testJumpToUnknownPhaseThrows() {
        let it = CycleIterator(profile: twoPhaseProfile())
        XCTAssertThrowsError(try it.jumpTo(phaseId: "long_break")) { error in
            guard case CycleIterator.JumpError.notInCurrentCycle = error else {
                return XCTFail("expected notInCurrentCycle, got \(error)")
            }
        }
    }

    // The core invariant: a jump moves the index but NOT the cycle number. After
    // jumping back to "work" inside the override cycle, the count stays 3 (still in
    // the override cycle) and the natural advance order continues from there —
    // proving cycleNumber and the long-cycle math weren't reset to cycle 1.
    func testJumpToPreservesCycleNumberAndLongCycleMath() throws {
        let it = CycleIterator(profile: overrideProfile())

        // Walk into cycle 2, which uses the override (count 3).
        _ = it.advance()                 // short_break (cycle 1)
        _ = it.advance()                 // work (cycle 2, override → count 3)
        XCTAssertEqual(it.currentPhase.id, "work")
        assertPos(it.cyclePosition, 1, 3)

        // Jump forward to long_break (override tail), then back to work.
        try it.jumpTo(phaseId: "long_break")
        assertPos(it.cyclePosition, 3, 3)
        try it.jumpTo(phaseId: "work")
        // Still in the override cycle — count must remain 3, NOT collapse to 2.
        assertPos(it.cyclePosition, 1, 3)

        // Natural advances continue the override cycle from the jumped position.
        _ = it.advance()                 // short_break
        assertPos(it.cyclePosition, 2, 3)
        _ = it.advance()                 // long_break
        XCTAssertEqual(it.currentPhase.id, "long_break")
        assertPos(it.cyclePosition, 3, 3)

        // Wrapping into cycle 3 (odd → base) drops back to count 2 on schedule,
        // confirming the long-cycle counter advanced normally despite the jumps.
        _ = it.advance()
        XCTAssertEqual(it.currentPhase.id, "work")
        assertPos(it.cyclePosition, 1, 2)
    }

    // Within the override cycle, an override-only phase (long_break) IS a valid
    // jump target because it's part of the current effective cycle.
    func testJumpToOverridePhaseAllowedWithinOverrideCycle() throws {
        let it = CycleIterator(profile: overrideProfile())
        _ = it.advance()                 // short_break (cycle 1)
        _ = it.advance()                 // work (cycle 2, override)
        let landed = try it.jumpTo(phaseId: "long_break")
        XCTAssertEqual(landed.id, "long_break")
    }

    // Forcing an override-only phase (long_break) early — on a BASE cycle where it
    // isn't normally present — enters the override cycle now.
    func testForceLongBreakEarlyEntersOverrideCycle() throws {
        let it = CycleIterator(profile: overrideProfile())   // every 2; override tail long_break
        // Cycle 1 is a base cycle (count 2) that doesn't contain long_break.
        assertPos(it.cyclePosition, 1, 2)
        let landed = try it.jumpTo(phaseId: "long_break")
        XCTAssertEqual(landed.id, "long_break")
        assertPos(it.cyclePosition, 3, 3)                    // now inside the 3-phase override cycle
    }

    // Forcing the long break early RESETS the long-cycle counter: after taking it,
    // the long break does not recur until a full `longCycleEvery` (=2) cycles later.
    func testForceLongBreakResetsLongCycleCounter() throws {
        let it = CycleIterator(profile: overrideProfile())   // every 2
        try it.jumpTo(phaseId: "long_break")                 // forced early on cycle 1

        _ = it.advance()                 // wrap → next cycle, work
        XCTAssertEqual(it.currentPhase.id, "work")
        assertPos(it.cyclePosition, 1, 2)                    // BASE cycle again, not another long cycle
        _ = it.advance()                 // short_break
        assertPos(it.cyclePosition, 2, 2)
        _ = it.advance()                 // long cycle returns exactly `every` cycles after the forced one
        XCTAssertEqual(it.currentPhase.id, "work")
        assertPos(it.cyclePosition, 1, 3)
    }

    // MARK: - Store reconstruction of phase_skip (stateless CLI / reporting)

    private let t0ms: Int64 = 1_000_000_000

    private func makeStore() throws -> Store {
        let dir = try makeTmpDir()
        return try Store(url: dir.appendingPathComponent("test.db"))
    }

    private func makeTask(_ store: Store, _ name: String) throws -> Task {
        try store.upsertTask(Task(id: nil, name: name, code: nil, category: "project", archived: false))
    }

    // A phase_skip is a state-affecting event: after it, the current status is
    // tracking the skip's accrual task, with `since` taken from the event ts
    // (mirroring phase_advance — the target may be a break task with no start row).
    func testCurrentStatusAfterPhaseSkipIsTrackingTarget() throws {
        let store = try makeStore()
        let work = try makeTask(store, "Work")
        let brk  = try makeTask(store, "Break")

        _ = try store.append(Event(
            id: nil, ts: t0ms, type: EventType.start.rawValue,
            taskId: work.id, prevTaskId: nil, phaseId: "work",
            profileName: "default", extendMin: nil, comment: nil))

        let skipTs = t0ms + 300_000   // skipped 5 min in
        _ = try store.append(Event(
            id: nil, ts: skipTs, type: EventType.phaseSkip.rawValue,
            taskId: brk.id, prevTaskId: work.id, phaseId: "short_break",
            profileName: "default", extendMin: nil, comment: nil))

        let status = try store.currentStatus()
        guard case .tracking(let t, let since) = status else {
            return XCTFail("expected .tracking after phase_skip, got \(status)")
        }
        XCTAssertEqual(t.name, "Break")
        XCTAssertEqual(since.timeIntervalSince1970,
                       Double(skipTs) / 1000.0, accuracy: 0.001,
                       "since must be the phase_skip event ts")
    }

    // Reporting accrues across a phase_skip exactly like phase_advance: time before
    // the skip belongs to the prior task, time after to the skip's target.
    func testReportAccruesAcrossPhaseSkip() throws {
        let store = try makeStore()
        let work = try makeTask(store, "Work")
        let brk  = try makeTask(store, "Break")

        // Anchor at NOON of a fixed past day, not "now − 20 min": a run shortly
        // after midnight puts part of the window on yesterday, and report(day:)
        // clips at the day boundary (CI caught 559 ≠ 600 at 00:19 UTC). Same
        // fixed-past-day pattern as ReconcileGateTests (#44). bySettingHour, not
        // startOfDay + 12h of raw seconds: on a DST transition day those differ.
        let cal = Calendar.current
        let pastDay = cal.date(byAdding: .day, value: -3, to: cal.startOfDay(for: Date()))!
        let day = cal.date(bySettingHour: 12, minute: 0, second: 0, of: pastDay)!
        let base = Int64(day.timeIntervalSince1970 * 1000)
        _ = try store.append(Event(
            id: nil, ts: base, type: EventType.start.rawValue,
            taskId: work.id, prevTaskId: nil, phaseId: "work",
            profileName: "default", extendMin: nil, comment: nil))
        _ = try store.append(Event(
            id: nil, ts: base + 600_000, type: EventType.phaseSkip.rawValue,
            taskId: brk.id, prevTaskId: work.id, phaseId: "short_break",
            profileName: "default", extendMin: nil, comment: nil))
        _ = try store.append(Event(
            id: nil, ts: base + 900_000, type: EventType.stop.rawValue,
            taskId: nil, prevTaskId: brk.id, phaseId: nil,
            profileName: "default", extendMin: nil, comment: nil))

        let rows = try store.report(day: day)
        let workSecs = rows.first(where: { $0.task.id == work.id })?.totalSeconds ?? -1
        let brkSecs  = rows.first(where: { $0.task.id == brk.id })?.totalSeconds ?? -1
        XCTAssertEqual(workSecs, 600, "work accrues the 10 min before the skip")
        XCTAssertEqual(brkSecs, 300, "break accrues the 5 min after the skip until stop")
    }

    // MARK: - Tracker.jumpToPhase

    // Pomodoro tracker (work, short_break; long_break override) — gives real
    // multi-phase jump targets unlike the single-phase "default" profile.
    @MainActor
    private func pomodoroTracker() throws -> (tracker: Tracker, store: Store, taskId: Int64) {
        let dir = try makeTmpDir()
        let (tracker, store, taskId) = try makeTrackerContext(in: dir)
        tracker.setProfile("pomodoro")
        return (tracker, store, taskId)
    }

    // Jumping from .tracking to a break phase ends the current phase early, lands
    // on the break with the break task accruing, resets the deadline to the target
    // duration, and logs a phase_skip (so the stateless reader sees the break).
    func testJumpFromTrackingToBreakAccruesToBreakTask() throws {
        try MainActor.assumeIsolated {
            let (tracker, store, taskId) = try pomodoroTracker()
            tracker.start(taskId: taskId)

            tracker.jumpToPhase("short_break")

            guard case let .tracking(tid, phase, deadline) = tracker.state else {
                return XCTFail("expected .tracking after jump, got \(tracker.state)")
            }
            XCTAssertEqual(phase.id, "short_break")
            XCTAssertEqual(tid, try store.breakTaskId(), "break phase accrues to the break task")
            XCTAssertEqual(deadline.timeIntervalSinceNow, 300, accuracy: 5,
                           "deadline reset to the 5-min short_break duration")

            // The append-only phase_skip is the latest state event.
            guard case .tracking(let t, _) = try store.currentStatus() else {
                return XCTFail("currentStatus should be tracking after the skip")
            }
            XCTAssertEqual(t.id, try store.breakTaskId())
        }
    }

    // Jumping out of a break back to work resumes the prior work task (the break
    // task must not bleed into the work phase) — same resume rule as advance().
    func testJumpFromBreakBackToWorkResumesWorkTask() throws {
        try MainActor.assumeIsolated {
            let (tracker, _, taskId) = try pomodoroTracker()
            tracker.start(taskId: taskId)
            tracker.jumpToPhase("short_break")     // now on the break
            tracker.jumpToPhase("work")            // back to work early

            guard case let .tracking(tid, phase, _) = tracker.state else {
                return XCTFail("expected .tracking after jump, got \(tracker.state)")
            }
            XCTAssertEqual(phase.id, "work")
            XCTAssertEqual(tid, taskId, "leaving the break must resume the original work task")
        }
    }

    // Jump is allowed from .armed: it ends the armed phase and lands on the target.
    func testJumpFromArmedWorks() throws {
        try MainActor.assumeIsolated {
            let (tracker, _, taskId) = try pomodoroTracker()
            tracker.start(taskId: taskId)
            tracker.tick(at: Date().addingTimeInterval(60 * 60))   // arm the work phase
            guard case .armed = tracker.state else {
                return XCTFail("precondition: expected .armed, got \(tracker.state)")
            }

            tracker.jumpToPhase("short_break")
            guard case let .tracking(_, phase, _) = tracker.state else {
                return XCTFail("expected .tracking after jump from armed, got \(tracker.state)")
            }
            XCTAssertEqual(phase.id, "short_break")
        }
    }

    // Jumping while idle is a no-op — there is no phase to skip.
    func testJumpWhileIdleIsNoOp() throws {
        try MainActor.assumeIsolated {
            let (tracker, _, _) = try pomodoroTracker()
            tracker.jumpToPhase("short_break")
            guard case .idle = tracker.state else {
                return XCTFail("jump while idle must not change state, got \(tracker.state)")
            }
        }
    }

    // Jumping to the phase we're ALREADY in is a no-op — otherwise a stale UI
    // (or a direct API caller) turns it into an accidental phase restart: fresh
    // deadline, reset phaseStartedAt, and a junk phase_skip in the append-only
    // log. phaseStartedAt/deadline unchanged proves the early return (all
    // mutations and the append live in the same block after the guard).
    func testJumpToCurrentPhaseIsNoOp() throws {
        try MainActor.assumeIsolated {
            let (tracker, _, taskId) = try pomodoroTracker()
            tracker.start(taskId: taskId)
            guard case let .tracking(_, _, deadlineBefore) = tracker.state else {
                return XCTFail("expected .tracking after start, got \(tracker.state)")
            }
            let startedBefore = tracker.phaseStartedAt

            tracker.jumpToPhase("work")

            guard case let .tracking(_, phase, deadlineAfter) = tracker.state else {
                return XCTFail("expected still .tracking, got \(tracker.state)")
            }
            XCTAssertEqual(phase.id, "work")
            XCTAssertEqual(deadlineAfter, deadlineBefore,
                           "jump-to-current must not restart the phase deadline")
            XCTAssertEqual(tracker.phaseStartedAt, startedBefore,
                           "jump-to-current must not reset phaseStartedAt")
        }
    }

    // A phase in NEITHER the current cycle nor the override is a no-op — the
    // iterator rejects it and the tracker leaves state untouched.
    func testJumpToUnknownPhaseIsNoOp() throws {
        try MainActor.assumeIsolated {
            let (tracker, _, taskId) = try pomodoroTracker()
            tracker.start(taskId: taskId)

            tracker.jumpToPhase("does_not_exist")

            guard case let .tracking(_, phase, _) = tracker.state else {
                return XCTFail("expected still .tracking, got \(tracker.state)")
            }
            XCTAssertEqual(phase.id, "work", "an unknown-phase jump must not move the phase")
        }
    }

    // Forcing long_break early from .tracking lands on it with the break task
    // accruing (the override phase is reachable even on a base cycle now).
    func testJumpToLongBreakForcesOverrideCycle() throws {
        try MainActor.assumeIsolated {
            let (tracker, store, taskId) = try pomodoroTracker()
            tracker.start(taskId: taskId)

            tracker.jumpToPhase("long_break")

            guard case let .tracking(tid, phase, _) = tracker.state else {
                return XCTFail("expected .tracking after forcing long_break, got \(tracker.state)")
            }
            XCTAssertEqual(phase.id, "long_break")
            XCTAssertEqual(tid, try store.breakTaskId(), "long_break accrues to the break task")
        }
    }

    // jumpTargets exposes the current cycle's phases PLUS the forceable override
    // phase (long_break), and is empty while idle.
    func testJumpTargetsIncludeForceableOverridePhase() throws {
        try MainActor.assumeIsolated {
            let (tracker, _, taskId) = try pomodoroTracker()
            XCTAssertEqual(tracker.jumpTargets.map(\.id), [], "no targets while idle")

            tracker.start(taskId: taskId)
            XCTAssertEqual(tracker.jumpTargets.map(\.id), ["work", "short_break", "long_break"],
                           "targets are the current cycle's phases plus the forceable long_break")
        }
    }
}
