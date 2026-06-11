import XCTest
@testable import TimeTrackKit

// Break-resume (previousWorkTaskId) tests.
// Spec: docs/superpowers/specs/2026-06-11-previous-work-task-resume-design.md
//
// Unit tests inject `asOf`, so fixed epochs are fine here. Integration tests that drive
// Tracker.advance()/Store.switchFromArmed use real-now-relative timestamps because those paths stale against Date().
final class PreviousWorkTaskTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() throws -> Store {
        let dir = try makeTmpDir()
        return try Store(url: dir.appendingPathComponent("test.db"))
    }

    private func makeTask(_ store: Store, name: String) throws -> Task {
        var t = Task(id: nil, name: name, code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        return t
    }

    @discardableResult
    private func appendEvent(_ store: Store,
                             ts: Int64,
                             type: EventType,
                             taskId: Int64? = nil,
                             prevTaskId: Int64? = nil,
                             phaseId: String? = nil,
                             profileName: String? = nil,
                             nextPhaseId: String? = nil) throws -> Event {
        try store.append(Event(
            id: nil, ts: ts, type: type.rawValue,
            taskId: taskId, prevTaskId: prevTaskId,
            phaseId: phaseId, profileName: profileName,
            extendMin: nil, comment: nil,
            nextPhaseId: nextPhaseId))
    }

    private let arm = ArmConfig(sound: "Tink", color: "amber", actions: [])
    private var breakPhase5: Phase {
        Phase(id: "break", durationMin: 5, accrueAs: "break", onArm: arm)
    }
    private var longBreak15: Phase {
        Phase(id: "long_break", durationMin: 15, accrueAs: "break", onArm: arm)
    }

    // Fixed epoch ms (~2001). Safe ONLY where asOf is injected.
    private let t0: Int64 = 1_000_000_000

    private func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    // Seeds the canonical "work(A) then into break" log. Returns breakStartTs.
    private func seedWorkThenBreak(_ store: Store, a: Int64) throws -> Int64 {
        try appendEvent(store, ts: t0, type: .start, taskId: a, phaseId: "work")
        let breakStart = t0 + 25 * 60_000
        let breakId = try store.breakTaskId()
        try appendEvent(store, ts: breakStart, type: .phaseAdvance,
                        taskId: breakId, prevTaskId: a, phaseId: "break")
        return breakStart
    }

    // MARK: - Unit: resume semantics

    // Normal cycle: work(A) → break, break ran its nominal length → resume A.
    func testResumesPriorWorkTaskAfterNominalBreak() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let breakStart = try seedWorkThenBreak(store, a: a)

        // 5 min into a 5-min break; threshold = 2 × 5 = 10 min.
        let result = try store.previousWorkTaskId(
            leavingBreak: breakPhase5, asOf: date(breakStart + 5 * 60_000))

        XCTAssertEqual(result, a,
            "leaving a nominal-length break must resume the pre-break work task")
    }

    // Stale: break ran past 2× its nominal duration → nil (don't guess).
    func testStaleBreakSuppressesResume() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let breakStart = try seedWorkThenBreak(store, a: a)

        // 11 min into a 5-min break; threshold = 10 min → stale.
        let result = try store.previousWorkTaskId(
            leavingBreak: breakPhase5, asOf: date(breakStart + 11 * 60_000))

        XCTAssertNil(result,
            "a break that ran past staleFactor × durationMin must suppress auto-resume")
    }

    // Boundary: exactly AT the threshold still resumes; strictly past it is stale.
    func testStaleThresholdIsStrictlyGreaterThan() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let breakStart = try seedWorkThenBreak(store, a: a)
        let thresholdMs: Int64 = 10 * 60_000  // 2.0 × 5 min

        XCTAssertEqual(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(breakStart + thresholdMs)),
            a, "elapsed == threshold must still resume (staleness is strict >)")

        XCTAssertNil(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(breakStart + thresholdMs + 1)),
            "elapsed just past the threshold must be stale")
    }

    // Mid-break switch to a real task: the trailing active task is non-break,
    // so it is returned directly — and is never subject to staleness.
    func testMidBreakSwitchWinsOverPreBreakTask() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let b = try makeTask(store, name: "B").id!
        let breakStart = try seedWorkThenBreak(store, a: a)
        let breakId = try store.breakTaskId()
        try appendEvent(store, ts: breakStart + 2 * 60_000, type: .switch,
                        taskId: b, prevTaskId: breakId, phaseId: "break")

        XCTAssertEqual(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(breakStart + 3 * 60_000)),
            b, "an explicit mid-break switch must win over the pre-break task")

        XCTAssertEqual(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(breakStart + 100 * 60_000)),
            b, "already being on a work task is never stale (it IS the carried task)")
    }

    // stop ends the session: resuming across a stop would be a guess → nil.
    // (The merged baseline got this wrong: its unconditional newest-first query ignored stop events.)
    func testStopClearsResume() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let breakStart = try seedWorkThenBreak(store, a: a)
        try appendEvent(store, ts: breakStart + 60_000, type: .stop, prevTaskId: a)

        XCTAssertNil(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(breakStart + 2 * 60_000)),
            "a stop after the break entry must clear the resume candidate")
    }

    // A break with no prior work task at all → nil.
    func testNoPriorWorkTaskReturnsNil() throws {
        let store = try makeStore()
        let breakId = try store.breakTaskId()
        try appendEvent(store, ts: t0, type: .phaseAdvance,
                        taskId: breakId, phaseId: "break")

        XCTAssertNil(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(t0 + 60_000)),
            "no prior work task in the log means nothing to resume")
    }

    // Empty log → nil (and must not throw).
    func testEmptyLogReturnsNil() throws {
        let store = try makeStore()
        XCTAssertNil(
            try store.previousWorkTaskId(leavingBreak: breakPhase5, asOf: Date()),
            "an empty event log has nothing to resume")
    }

    // Multi-cycle: resume reflects the LATEST work task, not the first.
    func testMultiCycleResumesLatestWorkTask() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let b = try makeTask(store, name: "B").id!
        let breakId = try store.breakTaskId()

        // work(A) → break → work(A resumed) → switch(B) → break (trailing)
        try appendEvent(store, ts: t0, type: .start, taskId: a, phaseId: "work")
        try appendEvent(store, ts: t0 + 25 * 60_000, type: .phaseAdvance,
                        taskId: breakId, prevTaskId: a, phaseId: "break")
        try appendEvent(store, ts: t0 + 30 * 60_000, type: .phaseAdvance,
                        taskId: a, prevTaskId: breakId, phaseId: "work")
        try appendEvent(store, ts: t0 + 40 * 60_000, type: .switch,
                        taskId: b, prevTaskId: a, phaseId: "work")
        let secondBreak = t0 + 55 * 60_000
        try appendEvent(store, ts: secondBreak, type: .phaseAdvance,
                        taskId: breakId, prevTaskId: b, phaseId: "break")

        XCTAssertEqual(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(secondBreak + 4 * 60_000)),
            b, "after multiple cycles the most recent work task (B) must resume")
    }

    // idle_gap / idle_resolve are timeline no-ops: they must neither change the
    // resume candidate nor reset the break-run start used for staleness.
    func testIdleEventsDoNotDisturbResumeOrStaleness() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let breakStart = try seedWorkThenBreak(store, a: a)
        // Idle gap detected during the break, later resolved. Both no-ops here.
        try appendEvent(store, ts: breakStart + 60_000, type: .idleGap, taskId: a)
        try store.append(Event(
            id: nil, ts: breakStart + 3 * 60_000, type: EventType.idleResolve.rawValue,
            taskId: a, prevTaskId: a, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil,
            rangeStart: breakStart + 60_000, rangeEnd: breakStart + 2 * 60_000))

        XCTAssertEqual(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(breakStart + 5 * 60_000)),
            a, "idle events are no-ops in the active-task walk")

        XCTAssertNil(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(breakStart + 11 * 60_000)),
            "staleness must anchor to the break entry, not be reset by idle events")
    }

    // long_break: the threshold scales with the LEAVING phase's own duration.
    func testLongBreakUsesItsOwnDurationForStaleness() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let breakStart = try seedWorkThenBreak(store, a: a)
        let asOf = date(breakStart + 20 * 60_000)  // 20 min into the break

        XCTAssertEqual(
            try store.previousWorkTaskId(leavingBreak: longBreak15, asOf: asOf),
            a, "20 min is within 2 × 15 min for a long break → resume")

        XCTAssertNil(
            try store.previousWorkTaskId(leavingBreak: breakPhase5, asOf: asOf),
            "the same 20 min is past 2 × 5 min for a short break → stale")
    }

    // MARK: - Integration: Tracker.advance() out of a break

    // start(A) → arm → advance into short_break → arm → advance out: the new
    // tracking task and the appended phase_advance must both be A, not the
    // break task. Event timestamps are real-now (append stamps Date()), so the
    // ~ms-long "break" is never stale. NOTE: this PASSES on the PR#4 baseline
    // too (unconditional resume) — it pins the behavior through the rewiring;
    // the spec-vs-baseline deltas are covered by the Task-1 unit tests and the
    // Task-3 stale test.
    func testAdvanceOutOfBreakResumesPreBreakTask() throws {
        let dir = try makeTmpDir()
        let (tracker, store, taskA) = try MainActor.assumeIsolated {
            try makeTrackerContext(in: dir)
        }

        MainActor.assumeIsolated {
            // Seeded pomodoro profile: work(25) → short_break(5).
            tracker.setProfile("pomodoro")
            tracker.start(taskId: taskA)
            tracker.tick(at: Date().addingTimeInterval(3 * 60 * 60))  // arm work
            tracker.advance()                                          // → short_break
            tracker.tick(at: Date().addingTimeInterval(6 * 60 * 60))  // arm short_break
            tracker.advance()                                          // → work: resume A
        }

        let activeId = MainActor.assumeIsolated { tracker.activeTask?.id }
        XCTAssertEqual(activeId, taskA,
            "advancing out of a break must resume the pre-break work task")

        let events = try store.readAllEventsInternal()
        let last = events[events.count - 1]
        let breakId = try store.breakTaskId()
        XCTAssertEqual(last.type, EventType.phaseAdvance.rawValue)
        XCTAssertEqual(last.taskId, taskA,
            "the phase_advance out of the break must carry the resumed task")
        XCTAssertEqual(last.prevTaskId, breakId,
            "the carried task at a break exit is the synthetic break task")
    }

    // Work→work advance (no break involved): the leaving-break guard must not
    // fire; accrual stays on the carried work task. Pins the guard's non-break
    // branch in Tracker.advance().
    func testAdvanceWorkToWorkCarriesTaskWithoutResumeLookup() throws {
        let dir = try makeTmpDir()
        let (tracker, store, taskA) = try MainActor.assumeIsolated {
            try makeTrackerContext(in: dir)
        }

        MainActor.assumeIsolated {
            // "default" profile: a single work(45) phase wrapping to itself.
            tracker.start(taskId: taskA)
            tracker.tick(at: Date().addingTimeInterval(3 * 60 * 60))  // arm work
            tracker.advance()                                          // → work again
        }

        let activeId = MainActor.assumeIsolated { tracker.activeTask?.id }
        XCTAssertEqual(activeId, taskA,
            "a work→work advance must keep accruing to the carried work task")

        let events = try store.readAllEventsInternal()
        let last = events[events.count - 1]
        XCTAssertEqual(last.type, EventType.phaseAdvance.rawValue)
        XCTAssertEqual(last.taskId, taskA,
            "the phase_advance on a non-break boundary must carry the work task")
        XCTAssertEqual(last.prevTaskId, taskA)
    }

    // MARK: - CLI path: switchFromArmed off a BREAK boundary

    // Seeds a near-NOW log (switchFromArmed stales against Date()) representing:
    // work(A, 10 min ago) → break (4 min ago) → break phase armed (30 s ago).
    // Returns the break task id. Callers then switch to a target task.
    private func seedArmedBreakBoundaryNearNow(_ store: Store, a: Int64,
                                               profileName: String) throws -> Int64 {
        let breakId = try store.breakTaskId()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try appendEvent(store, ts: nowMs - 10 * 60_000, type: .start,
                        taskId: a, phaseId: "work", profileName: profileName)
        try appendEvent(store, ts: nowMs - 4 * 60_000, type: .phaseAdvance,
                        taskId: breakId, prevTaskId: a, phaseId: "break",
                        profileName: profileName)
        try appendEvent(store, ts: nowMs - 30_000, type: .phaseArm,
                        taskId: breakId, phaseId: "break", profileName: profileName,
                        nextPhaseId: "work")
        return breakId
    }

    // Switch-from-ARMED off a break boundary: the implicit-ack phase_advance
    // must resume A (not stay on the break task), and the switch hangs off A.
    // (Pins baseline-correct behavior through the rewiring.)
    func testSwitchFromArmedOutOfBreakResumesViaPhaseAdvance() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let target = try makeTask(store, name: "Target").id!
        let profile = makeBreakProfile()   // work(25) → break(5)
        let breakId = try seedArmedBreakBoundaryNearNow(store, a: a,
                                                        profileName: profile.name)

        try store.switchFromArmed(armedTaskId: breakId, armedPhaseId: "break",
                                  targetTaskId: target, profile: profile)

        let events = try store.readAllEventsInternal()
        let advanceEv = events[events.count - 2]
        let switchEv  = events[events.count - 1]

        XCTAssertEqual(advanceEv.type, EventType.phaseAdvance.rawValue)
        XCTAssertEqual(advanceEv.taskId, a,
            "the implicit ack out of a break must resume the pre-break task")
        XCTAssertEqual(advanceEv.prevTaskId, breakId,
            "prevTaskId is the carried (break) task at the boundary")
        XCTAssertEqual(switchEv.type, EventType.switch.rawValue)
        XCTAssertEqual(switchEv.taskId, target)
        XCTAssertEqual(switchEv.prevTaskId, a,
            "the switch hangs off the resumed accrual task (valid FK chain)")
    }

    // Stale through the CLI path: the same log shape seeded at a fixed 2001
    // epoch with asOf == Date() is decades stale → resume suppressed → the
    // implicit ack falls back to the carried break task (documented MVP
    // fallback). RED on the PR#4 baseline (it resumes regardless of age).
    func testSwitchFromArmedStaleBreakFallsBackToCarried() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let target = try makeTask(store, name: "Target").id!
        let profile = makeBreakProfile()
        let breakId = try store.breakTaskId()

        try appendEvent(store, ts: t0, type: .start,
                        taskId: a, phaseId: "work", profileName: profile.name)
        try appendEvent(store, ts: t0 + 25 * 60_000, type: .phaseAdvance,
                        taskId: breakId, prevTaskId: a, phaseId: "break",
                        profileName: profile.name)
        try appendEvent(store, ts: t0 + 30 * 60_000, type: .phaseArm,
                        taskId: breakId, phaseId: "break", profileName: profile.name,
                        nextPhaseId: "work")

        try store.switchFromArmed(armedTaskId: breakId, armedPhaseId: "break",
                                  targetTaskId: target, profile: profile)

        let events = try store.readAllEventsInternal()
        let advanceEv = events[events.count - 2]
        let switchEv  = events[events.count - 1]

        XCTAssertEqual(advanceEv.taskId, breakId,
            "a stale break must NOT auto-resume; accrual falls back to carried")
        XCTAssertEqual(switchEv.prevTaskId, breakId,
            "the switch then hangs off the carried break task")
        XCTAssertEqual(switchEv.taskId, target,
            "the explicit switch target is unaffected by staleness")
    }

    // Parity ("never diverge"): on an identical log, the advance()-path
    // computation (previousWorkTaskId + accrualTaskId) and switchFromArmed's
    // appended phase_advance must pick the same accrual task.
    func testAdvancePathAndSwitchFromArmedAgreeOnAccrualTask() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let target = try makeTask(store, name: "Target").id!
        let profile = makeBreakProfile()
        let breakId = try seedArmedBreakBoundaryNearNow(store, a: a,
                                                        profileName: profile.name)

        // What Tracker.advance() computes at this boundary:
        let workPhase = Phase(id: "work", durationMin: 25, accrueAs: nil, onArm: arm)
        // Use the PROFILE's break phase (what switchFromArmed resolves), not a
        // hardcoded twin — so this test fails if the two ever diverge.
        let leavingPh = profile.cycle.first(where: { $0.accrueAs == "break" })!
        let prev = try store.previousWorkTaskId(leavingBreak: leavingPh, asOf: Date())
        let expected = try store.accrualTaskId(forNextPhase: workPhase,
                                               carriedTaskId: breakId,
                                               previousWorkTaskId: prev)

        // What the stateless CLI path actually appends:
        try store.switchFromArmed(armedTaskId: breakId, armedPhaseId: "break",
                                  targetTaskId: target, profile: profile)
        let events = try store.readAllEventsInternal()
        let advanceEv = events[events.count - 2]

        XCTAssertEqual(advanceEv.taskId, expected,
            "advance()-path computation and switchFromArmed must agree (single source of truth)")
        XCTAssertEqual(expected, a, "and on this log the agreed answer is the resumed task A")
    }
}
