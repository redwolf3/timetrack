import XCTest
@testable import TimeTrackKit

// Tests covering kit behaviors that had zero coverage in the initial test suite:
//   M5/M8  switchFromArmed: canonical two-event sequence (break and non-break)
//   nextPhaseId  read-back: override phase (long_break), legacy nil fallback
//   accrualTaskId parity: M2/M4 single-source-of-truth shared by advance() and CLI
//   M9  currentStatus .phaseAdvance: since == phase_advance ts, not now()
//   M10 currentStatus phaseExtend: un-arms, since == original start
//   userTasks filter: break task excluded; tasks() still includes it

final class PhaseAdvanceTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() throws -> Store {
        let dir = try makeTmpDir()
        return try Store(url: dir.appendingPathComponent("test.db"))
    }

    private func makeTask(_ store: Store, name: String, category: String = "project") throws -> Task {
        var t = Task(id: nil, name: name, code: nil, category: category, archived: false)
        t = try store.upsertTask(t)
        return t
    }

    // Append an event with explicit ts.
    @discardableResult
    private func appendEvent(_ store: Store,
                              ts: Int64,
                              type: EventType,
                              taskId: Int64? = nil,
                              prevTaskId: Int64? = nil,
                              phaseId: String? = nil,
                              profileName: String? = nil,
                              nextPhaseId: String? = nil) throws -> Event {
        return try store.append(Event(
            id: nil, ts: ts, type: type.rawValue,
            taskId: taskId, prevTaskId: prevTaskId,
            phaseId: phaseId, profileName: profileName,
            extendMin: nil, comment: nil,
            nextPhaseId: nextPhaseId))
    }

    // A minimal two-phase profile: work → break (mirrors makeBreakProfile but
    // fully inline so this file is self-contained).
    private func twoPhaseProfile() -> Profile {
        let arm = ArmConfig(sound: "Tink", color: "amber", actions: [])
        return Profile(
            name: "test_two",
            cycle: [
                Phase(id: "work",  durationMin: 25, accrueAs: nil,     onArm: arm),
                Phase(id: "break", durationMin: 5,  accrueAs: "break", onArm: arm)
            ],
            longCycleEvery: nil, longCycleOverride: nil,
            idleThresholdMin: 5, wiggleRoomMin: 2,
            escalation: .default)
    }

    // A profile with a long_break override in longCycleOverride (Pomodoro-style).
    private func pomodoroProfile() -> Profile {
        let arm = ArmConfig(sound: "Tink", color: "amber", actions: [])
        return Profile(
            name: "pomodoro",
            cycle: [
                Phase(id: "work",        durationMin: 25, accrueAs: nil,     onArm: arm),
                Phase(id: "short_break", durationMin: 5,  accrueAs: "break", onArm: arm)
            ],
            longCycleEvery: 4,
            longCycleOverride: [
                Phase(id: "long_break",  durationMin: 15, accrueAs: "break", onArm: arm)
            ],
            idleThresholdMin: 5, wiggleRoomMin: 2,
            escalation: .default)
    }

    private let t0: Int64 = 1_000_000_000  // fixed epoch ms

    // MARK: - M5/M8  switchFromArmed canonical two-event sequence

    // Non-break next phase: work → work (one-phase profile, wraps).
    // The arm event carries nextPhaseId="work".
    // Expected: phase_advance(taskId=workTask, prevTaskId=workTask, phaseId="work")
    //           switch(taskId=targetTask, prevTaskId=workTask, phaseId="work")
    func testSwitchFromArmedNonBreakPhaseAppendsCanonicalTwoEvents() throws {
        let store = try makeStore()
        let workTask   = try makeTask(store, name: "WorkTask")
        let targetTask = try makeTask(store, name: "NewTask")
        let wid = workTask.id!
        let tid = targetTask.id!

        // The one-phase profile wraps work→work.
        let profile = makeTestProfile()

        // Seed a start event so the DB is non-empty.
        try appendEvent(store, ts: t0, type: .start,
                        taskId: wid, phaseId: "work", profileName: profile.name)

        // Phase arms: next phase = "work" (wraps back after the single work phase).
        try appendEvent(store, ts: t0 + 900_000, type: .phaseArm,
                        taskId: wid, phaseId: "work", profileName: profile.name,
                        nextPhaseId: "work")

        // Execute the CLI's stateless switch-from-armed.
        try store.switchFromArmed(
            armedTaskId:  wid,
            armedPhaseId: "work",
            targetTaskId: tid,
            profile:      profile)

        // Read ALL events, look at the last two.
        let events = try store.readAllEventsInternal()
        XCTAssertGreaterThanOrEqual(events.count, 2,
            "switchFromArmed must append exactly two events")

        let advance = events[events.count - 2]
        let switchEv = events[events.count - 1]

        // phase_advance: taskId=workTask (non-break carries the armed task),
        //                prevTaskId=workTask (the armed task).
        XCTAssertEqual(advance.type,       EventType.phaseAdvance.rawValue)
        XCTAssertEqual(advance.taskId,     wid,
            "phase_advance.taskId must be the accrual task (same as armed for non-break)")
        XCTAssertEqual(advance.prevTaskId, wid,
            "phase_advance.prevTaskId must be the armed task")
        XCTAssertEqual(advance.phaseId,    "work")

        // switch: taskId=targetTask, prevTaskId=advance.taskId (the accrual task).
        XCTAssertEqual(switchEv.type,       EventType.switch.rawValue)
        XCTAssertEqual(switchEv.taskId,     tid,
            "switch.taskId must be the requested target task")
        XCTAssertEqual(switchEv.prevTaskId, wid,
            "switch.prevTaskId must be the accrual task from phase_advance")
        XCTAssertEqual(switchEv.phaseId,    "work")
    }

    // Break next phase: work → break.
    // The arm event carries nextPhaseId="break".
    // Expected: phase_advance(taskId=breakSynthetic, prevTaskId=workTask, phaseId="break")
    //           switch(taskId=targetTask, prevTaskId=breakSynthetic, phaseId="break")
    func testSwitchFromArmedBreakPhaseUsesBreakTaskForAccrual() throws {
        let store = try makeStore()
        let workTask   = try makeTask(store, name: "WorkTask")
        let targetTask = try makeTask(store, name: "AfterBreak")
        let wid = workTask.id!
        let tid = targetTask.id!
        let breakId = try store.breakTaskId()

        let profile = twoPhaseProfile()

        try appendEvent(store, ts: t0, type: .start,
                        taskId: wid, phaseId: "work", profileName: profile.name)
        try appendEvent(store, ts: t0 + 900_000, type: .phaseArm,
                        taskId: wid, phaseId: "work", profileName: profile.name,
                        nextPhaseId: "break")

        try store.switchFromArmed(
            armedTaskId:  wid,
            armedPhaseId: "work",
            targetTaskId: tid,
            profile:      profile)

        let events = try store.readAllEventsInternal()
        let advance  = events[events.count - 2]
        let switchEv = events[events.count - 1]

        // phase_advance: taskId MUST be the synthetic break task.
        XCTAssertEqual(advance.type,       EventType.phaseAdvance.rawValue)
        XCTAssertEqual(advance.taskId,     breakId,
            "phase_advance into a break phase must accrue to the synthetic break task")
        XCTAssertEqual(advance.prevTaskId, wid,
            "phase_advance.prevTaskId must be the armed work task")
        XCTAssertEqual(advance.phaseId,    "break")

        // switch: prevTaskId must be the break task (valid FK).
        XCTAssertEqual(switchEv.type,       EventType.switch.rawValue)
        XCTAssertEqual(switchEv.taskId,     tid)
        XCTAssertEqual(switchEv.prevTaskId, breakId,
            "switch.prevTaskId must be the accrual task from phase_advance (break task)")
        XCTAssertEqual(switchEv.phaseId,    "break")
    }

    // MARK: - nextPhaseId read-back: override phase (long_break)

    // A phase_arm with nextPhaseId='long_break' (an override-only phase that is NOT
    // in the base cycle) must be resolved without error, and the emitted
    // phase_advance must carry phaseId='long_break'.
    func testSwitchFromArmedResolvesLongBreakOverridePhase() throws {
        let store = try makeStore()
        let workTask   = try makeTask(store, name: "Work")
        let targetTask = try makeTask(store, name: "NewWork")
        let wid = workTask.id!
        let tid = targetTask.id!
        let breakId = try store.breakTaskId()

        let profile = pomodoroProfile()

        try appendEvent(store, ts: t0, type: .start,
                        taskId: wid, phaseId: "work", profileName: profile.name)
        // The arm event records nextPhaseId="long_break" — the long-cycle override.
        try appendEvent(store, ts: t0 + 900_000, type: .phaseArm,
                        taskId: wid, phaseId: "work", profileName: profile.name,
                        nextPhaseId: "long_break")

        // Must not throw even though "long_break" is in longCycleOverride, not cycle.
        XCTAssertNoThrow(
            try store.switchFromArmed(
                armedTaskId:  wid,
                armedPhaseId: "work",
                targetTaskId: tid,
                profile:      profile),
            "switchFromArmed must resolve long_break from longCycleOverride without error")

        let events = try store.readAllEventsInternal()
        let advance = events[events.count - 2]

        XCTAssertEqual(advance.type,    EventType.phaseAdvance.rawValue)
        XCTAssertEqual(advance.phaseId, "long_break",
            "phase_advance.phaseId must be 'long_break' (the override phase recorded at arm time)")
        XCTAssertEqual(advance.taskId,  breakId,
            "long_break accrues as 'break', so taskId must be the synthetic break task")
    }

    // Legacy nil nextPhaseId: arm event written before nextPhaseId column existed.
    // Falls back to profile.phaseAfter without crashing.
    func testSwitchFromArmedLegacyNilNextPhaseIdFallsBackToPhaseAfter() throws {
        let store = try makeStore()
        let workTask   = try makeTask(store, name: "Work")
        let targetTask = try makeTask(store, name: "Target")
        let wid = workTask.id!
        let tid = targetTask.id!

        let profile = twoPhaseProfile()  // work → break

        try appendEvent(store, ts: t0, type: .start,
                        taskId: wid, phaseId: "work", profileName: profile.name)
        // nextPhaseId is nil — simulates a legacy arm event (pre-v3 migration).
        try appendEvent(store, ts: t0 + 900_000, type: .phaseArm,
                        taskId: wid, phaseId: "work", profileName: profile.name,
                        nextPhaseId: nil)

        // Must not throw; phaseAfter("work") in the two-phase profile yields "break".
        XCTAssertNoThrow(
            try store.switchFromArmed(
                armedTaskId:  wid,
                armedPhaseId: "work",
                targetTaskId: tid,
                profile:      profile),
            "Legacy nil nextPhaseId must fall back to profile.phaseAfter without crashing")

        let events = try store.readAllEventsInternal()
        let advance = events[events.count - 2]

        XCTAssertEqual(advance.type,    EventType.phaseAdvance.rawValue)
        XCTAssertEqual(advance.phaseId, "break",
            "Legacy fallback must use profile.phaseAfter which yields 'break' from 'work'")
    }

    // MARK: - accrualTaskId parity (M2/M4 single-source-of-truth)

    // Store.accrualTaskId must return the break task for a break-phase next-phase.
    func testAccrualTaskIdReturnsBreakTaskForBreakPhase() throws {
        let store = try makeStore()
        let workTask = try makeTask(store, name: "Work")
        let wid = workTask.id!
        let breakId = try store.breakTaskId()

        let arm = ArmConfig(sound: "Tink", color: "amber", actions: [])
        let breakPhase = Phase(id: "break", durationMin: 5, accrueAs: "break", onArm: arm)

        let result = try store.accrualTaskId(
            forNextPhase:         breakPhase,
            carriedTaskId:        wid,
            previousWorkTaskId:   nil)

        XCTAssertEqual(result, breakId,
            "accrualTaskId must return the synthetic break task when accrueAs == 'break'")
    }

    // For a work-phase next-phase (accrueAs == nil), must return the carried task
    // when previousWorkTaskId is nil (mirrors advance()'s current nil stub).
    func testAccrualTaskIdReturnsCarriedTaskForNonBreakPhase() throws {
        let store = try makeStore()
        let workTask = try makeTask(store, name: "Work")
        let wid = workTask.id!

        let arm = ArmConfig(sound: "Tink", color: "amber", actions: [])
        let workPhase = Phase(id: "work", durationMin: 25, accrueAs: nil, onArm: arm)

        let result = try store.accrualTaskId(
            forNextPhase:         workPhase,
            carriedTaskId:        wid,
            previousWorkTaskId:   nil)

        XCTAssertEqual(result, wid,
            "accrualTaskId with accrueAs==nil and no previousWorkTaskId must return the carried task")
    }

    // Returning from break (accrueAs == nil) with a known previousWorkTaskId
    // must resume the prior work task, not the carried break-accrual task.
    func testAccrualTaskIdReturnsResumedTaskForReturnFromBreak() throws {
        let store = try makeStore()
        let breakCarried = try makeTask(store, name: "Carried")
        let priorWork    = try makeTask(store, name: "PriorWork")
        let cid = breakCarried.id!
        let pid = priorWork.id!

        let arm = ArmConfig(sound: "Tink", color: "amber", actions: [])
        let workPhase = Phase(id: "work", durationMin: 25, accrueAs: nil, onArm: arm)

        let result = try store.accrualTaskId(
            forNextPhase:         workPhase,
            carriedTaskId:        cid,
            previousWorkTaskId:   pid)

        XCTAssertEqual(result, pid,
            "accrualTaskId returning from break must prefer previousWorkTaskId over carried task")
    }

    // MARK: - M9  currentStatus .phaseAdvance: since == phase_advance ts

    // After a start event followed by a phase_advance into a break task,
    // currentStatus() must return .tracking(task: breakTask) and since must equal
    // the phase_advance timestamp — NOT now() — because the break task has no
    // start/switch row of its own.
    func testCurrentStatusAfterPhaseAdvanceSinceIsAdvanceTs() throws {
        let store = try makeStore()
        let workTask = try makeTask(store, name: "Work")
        let wid = workTask.id!
        let breakId = try store.breakTaskId()

        let advanceTs: Int64 = t0 + 900_000

        try appendEvent(store, ts: t0, type: .start, taskId: wid, phaseId: "work")
        try appendEvent(store, ts: advanceTs, type: .phaseAdvance,
                        taskId: breakId, prevTaskId: wid, phaseId: "break")

        let status = try store.currentStatus()

        guard case .tracking(let task, let since) = status else {
            return XCTFail("expected .tracking after phase_advance, got \(status)")
        }

        // Confirm we are on the break task.
        XCTAssertEqual(task.id, breakId,
            "currentStatus after phase_advance into break must show the break task")

        // Confirm since == the phase_advance ts, not now().
        let expectedSince = Date(timeIntervalSince1970: Double(advanceTs) / 1000.0)
        XCTAssertEqual(since.timeIntervalSince1970,
                       expectedSince.timeIntervalSince1970,
                       accuracy: 0.001,
            "currentStatus.since after phase_advance must equal the advance timestamp, not now()")
    }

    // MARK: - M10  currentStatus phaseExtend: awaiting-ack is over, since == original start

    // After start → phaseArm → phaseExtend, the user has acknowledged the arm
    // (extend() acks), so currentStatus() must return .tracking (not .armed).
    // The since date must trace back to the original start timestamp — the original
    // start/switch event for the task, not the extend time.
    func testCurrentStatusAfterPhaseExtendIsTrackingWithOriginalStartSince() throws {
        let store = try makeStore()
        let workTask = try makeTask(store, name: "Work")
        let wid = workTask.id!

        let startTs: Int64  = t0
        let armTs: Int64    = t0 + 900_000
        let extendTs: Int64 = t0 + 910_000

        try appendEvent(store, ts: startTs,  type: .start,       taskId: wid, phaseId: "work")
        try appendEvent(store, ts: armTs,    type: .phaseArm,    taskId: wid, phaseId: "work")
        try appendEvent(store, ts: extendTs, type: .phaseExtend, taskId: wid, phaseId: "work")

        let status = try store.currentStatus()

        guard case .tracking(let task, let since) = status else {
            return XCTFail("expected .tracking after phaseExtend, got \(status)")
        }

        XCTAssertEqual(task.id, wid,
            "currentStatus after phaseExtend must show the original work task")

        // Since must be the original start timestamp (the most recent start/switch
        // for this task), not the arm or extend time.
        let expectedSince = Date(timeIntervalSince1970: Double(startTs) / 1000.0)
        XCTAssertEqual(since.timeIntervalSince1970,
                       expectedSince.timeIntervalSince1970,
                       accuracy: 0.001,
            "currentStatus.since after phaseExtend must equal the original start ts")
    }

    // MARK: - userTasks filter

    // userTasks() must exclude the synthetic break task (category == "break")
    // even though tasks() includes it.
    func testUserTasksExcludesBreakTask() throws {
        let store = try makeStore()
        // The store creates the break task automatically in ensureBreakTask().
        // Add a normal project task to confirm userTasks is not empty.
        _ = try makeTask(store, name: "MyProject")

        let all   = try store.tasks()
        let users = try store.userTasks()

        // tasks() must include the synthetic break task.
        let allHasBreak = all.contains { $0.category == "break" }
        XCTAssertTrue(allHasBreak,
            "tasks() must include the synthetic break task (category == 'break')")

        // userTasks() must exclude it.
        let userHasBreak = users.contains { $0.category == "break" }
        XCTAssertFalse(userHasBreak,
            "userTasks() must exclude the synthetic break task")

        // userTasks() must still include the regular project task.
        let userHasProject = users.contains { $0.name == "MyProject" }
        XCTAssertTrue(userHasProject,
            "userTasks() must still include user-created project tasks")
    }

    // userTasks() excludes the break task even when includeArchived: true.
    func testUserTasksExcludesBreakTaskEvenWhenIncludingArchived() throws {
        let store = try makeStore()
        _ = try makeTask(store, name: "Archived Project")
        // Archive it directly (not via a dedicated API — just upsert).
        var archived = try store.userTasks()[0]
        archived.archived = true
        _ = try store.upsertTask(archived)

        let users = try store.userTasks(includeArchived: true)
        let userHasBreak = users.contains { $0.category == "break" }
        XCTAssertFalse(userHasBreak,
            "userTasks(includeArchived:true) must still exclude the synthetic break task")
    }

    // MARK: - switchFromArmed unresolvable-next-phase throw path

    // When the most recent phase_arm has nextPhaseId == nil AND the armedPhaseId
    // is not present in the loaded profile's base cycle (so the legacy
    // phaseAfter fallback also fails), switchFromArmed must throw
    // SwitchFromArmedError.unresolvableNextPhase AND must NOT append any events
    // (atomicity: event count is unchanged after the throw).
    func testSwitchFromArmedThrowsWhenNextPhaseUnresolvable() throws {
        let store = try makeStore()
        let workTask   = try makeTask(store, name: "WorkTask")
        let targetTask = try makeTask(store, name: "TargetTask")
        let wid = workTask.id!
        let tid = targetTask.id!

        // Build a one-phase profile whose only phase id is "work".
        // The arm event records armedPhaseId = "ghost_phase" — a phase id that
        // does NOT appear in this profile at all. Combined with nextPhaseId=nil,
        // both resolution paths fail: resolvePhase finds nothing, phaseAfter
        // finds nothing, so switchFromArmed MUST throw.
        let profile = makeTestProfile()  // cycle: [Phase(id: "work", ...)]

        // Seed a start event so the DB is non-empty.
        try appendEvent(store, ts: t0, type: .start,
                        taskId: wid, phaseId: "ghost_phase", profileName: profile.name)

        // Arm event: armedPhaseId = "ghost_phase", nextPhaseId = nil.
        // "ghost_phase" is absent from the profile's cycle, so the legacy
        // phaseAfter fallback cannot resolve it either.
        try appendEvent(store, ts: t0 + 900_000, type: .phaseArm,
                        taskId: wid, phaseId: "ghost_phase", profileName: profile.name,
                        nextPhaseId: nil)

        // Record the event count BEFORE calling switchFromArmed.
        let countBefore = try store.readAllEventsInternal().count

        // switchFromArmed must throw .unresolvableNextPhase.
        XCTAssertThrowsError(
            try store.switchFromArmed(
                armedTaskId:  wid,
                armedPhaseId: "ghost_phase",
                targetTaskId: tid,
                profile:      profile)
        ) { err in
            guard case Store.SwitchFromArmedError.unresolvableNextPhase(
                    let phase, let prof) = err else {
                return XCTFail("expected .unresolvableNextPhase, got \(err)")
            }
            XCTAssertEqual(phase, "ghost_phase",
                "error must carry the phase id that could not be resolved")
            XCTAssertEqual(prof, profile.name,
                "error must carry the profile name for diagnostics")
        }

        // Atomicity: no events must have been appended; the log is unchanged.
        let countAfter = try store.readAllEventsInternal().count
        XCTAssertEqual(countAfter, countBefore,
            "switchFromArmed must not append any events when it throws (append-only invariant)")
    }
}

// readAllEventsInternal() is an internal method on Store (Sources/TimeTrackKit/Store.swift).
// @testable import makes it visible here without any extension trampoline needed.
