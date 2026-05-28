import Foundation
import XCTest
@testable import TimeTrackKit

// Fixed epoch for deterministic idle-time arithmetic.
let fixedEpoch = Date(timeIntervalSinceReferenceDate: 1_000_000)

// Minimal one-phase profile.  Both tests and IdleMonitor share it.
// effectiveThreshold = max(idleThresholdMin, wiggleRoomMin) * 60  seconds.
func makeTestProfile(idleThresholdMin: Int = 5, wiggleRoomMin: Int = 2) -> Profile {
    let arm = ArmConfig(sound: "Tink", color: "amber", actions: [])
    return Profile(
        name: "default",
        cycle: [Phase(id: "work", durationMin: 25, accrueAs: nil, onArm: arm)],
        longCycleEvery: nil, longCycleOverride: nil,
        idleThresholdMin: idleThresholdMin, wiggleRoomMin: wiggleRoomMin,
        escalation: .default)
}

// Two-phase profile for break-phase idle tests.
func makeBreakProfile(idleThresholdMin: Int = 5, wiggleRoomMin: Int = 2) -> Profile {
    let arm = ArmConfig(sound: "Tink", color: "amber", actions: [])
    return Profile(
        name: "default",
        cycle: [
            Phase(id: "work",  durationMin: 25, accrueAs: nil,     onArm: arm),
            Phase(id: "break", durationMin: 5,  accrueAs: "break", onArm: arm)
        ],
        longCycleEvery: nil, longCycleOverride: nil,
        idleThresholdMin: idleThresholdMin, wiggleRoomMin: wiggleRoomMin,
        escalation: .default)
}

// Drive one IdleMonitor tick.  Sets the source value before calling tick so
// tests don't have to repeat the source.set() call.
@MainActor
func monitorTick(
    _ monitor: IdleMonitor,
    source: FakeIdleSource,
    idleSec: TimeInterval,
    now: Date,
    profile: Profile,
    taskId: Int64 = 1,
    phaseId: String = "work",
    isBreakPhase: Bool = false,
    armBoundary: Date? = nil,
    breakTaskId: Int64 = 99
) -> IdleMonitor.Signal {
    source.set(idleSec)
    return monitor.tick(
        now: now, profile: profile,
        currentTaskId: taskId, currentPhaseId: phaseId,
        isBreakPhase: isBreakPhase, armBoundary: armBoundary,
        breakTaskId: breakTaskId)
}

// Build a Tracker + Store backed by a temp directory.
// Relies on ProfileLoader seeding the "default" profile (45-min work phase)
// since no profiles.yaml exists at the generated path.
// Must be called from within a MainActor context (use assumeIsolated).
@MainActor
func makeTrackerContext(in dir: URL) throws -> (tracker: Tracker, store: Store, taskId: Int64) {
    let store = try Store(url: dir.appendingPathComponent("test.db"))
    var task = Task(id: nil, name: "TestTask", code: nil, category: "project", archived: false)
    task = try store.upsertTask(task)
    let profilesURL = dir.appendingPathComponent("profiles.yaml")
    // No file at profilesURL → ProfileLoader seeds default profiles ("default", "pomodoro", …)
    let tracker = try Tracker(store: store, profilesURL: profilesURL)
    return (tracker, store, task.id!)
}

// Convenience: create a fresh temp dir for one test.
func makeTmpDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tt-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
