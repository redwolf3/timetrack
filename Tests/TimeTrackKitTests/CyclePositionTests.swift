import XCTest
@testable import TimeTrackKit

// Covers the cycle-position accessors added for the phase-progress display (#20):
//   CycleIterator.cyclePosition — 1-based index + phase count, override-aware
//   Tracker.cyclePosition        — public surface: nil when idle, live when tracking
final class CyclePositionTests: XCTestCase {

    private func arm() -> ArmConfig {
        ArmConfig(sound: "Tink", color: "amber", actions: [])
    }

    // Assert a (index, count) tuple in one call (tuples aren't Equatable for XCTAssertEqual).
    private func assertPos(_ pos: (index: Int, count: Int),
                           _ index: Int, _ count: Int,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pos.index, index, "index", file: file, line: line)
        XCTAssertEqual(pos.count, count, "count", file: file, line: line)
    }

    // Plain two-phase cycle, no long-cycle override.
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

    // Override of a DIFFERENT length than the phase it replaces, so the cycle's
    // phase count changes on the long cycle (proves count tracks the active cycle,
    // not profile.cycle.count). Base count 2; on every 2nd cycle, drop the last
    // base phase and append two override phases → count 3.
    private func growingOverrideProfile() -> Profile {
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

    // MARK: - CycleIterator.cyclePosition

    func testCyclePositionAdvancesAndWraps() {
        let it = CycleIterator(profile: twoPhaseProfile())

        XCTAssertEqual(it.currentPhase.id, "work")
        assertPos(it.cyclePosition, 1, 2)

        _ = it.advance()
        XCTAssertEqual(it.currentPhase.id, "short_break")
        assertPos(it.cyclePosition, 2, 2)

        // Wrap back to the start of the next cycle.
        _ = it.advance()
        XCTAssertEqual(it.currentPhase.id, "work")
        assertPos(it.cyclePosition, 1, 2)
    }

    func testCyclePositionReflectsLongCycleOverrideCount() {
        let it = CycleIterator(profile: growingOverrideProfile())

        // Cycle 1 (base): work, short_break → count 2.
        assertPos(it.cyclePosition, 1, 2)
        _ = it.advance()  // short_break
        assertPos(it.cyclePosition, 2, 2)

        // Advance wraps into cycle 2, which uses the override → count 3.
        _ = it.advance()  // work of cycle 2
        XCTAssertEqual(it.currentPhase.id, "work")
        assertPos(it.cyclePosition, 1, 3)
        _ = it.advance()  // short_break
        assertPos(it.cyclePosition, 2, 3)
        _ = it.advance()  // long_break (override tail)
        XCTAssertEqual(it.currentPhase.id, "long_break")
        assertPos(it.cyclePosition, 3, 3)

        // Wrap into cycle 3 (odd → base cycle again) → count back to 2.
        _ = it.advance()
        XCTAssertEqual(it.currentPhase.id, "work")
        assertPos(it.cyclePosition, 1, 2)
    }

    func testResetReturnsToFirstPosition() {
        let it = CycleIterator(profile: twoPhaseProfile())
        _ = it.advance()
        it.reset()
        assertPos(it.cyclePosition, 1, 2)
        XCTAssertEqual(it.currentPhase.id, "work")
    }

    // MARK: - Tracker.cyclePosition (public surface)

    func testTrackerCyclePositionNilWhenIdleThenLiveWhenTracking() throws {
        let dir = try makeTmpDir()
        try MainActor.assumeIsolated {
            let (tracker, _, taskId) = try makeTrackerContext(in: dir)

            // Fresh tracker is idle — no live iterator.
            XCTAssertNil(tracker.cyclePosition,
                "cyclePosition must be nil while idle (no active cycle)")

            tracker.start(taskId: taskId)
            // First phase of the cycle, regardless of the seeded profile's length.
            XCTAssertEqual(tracker.cyclePosition?.index, 1,
                "after start the cycle position is the first phase")
            XCTAssertNotNil(tracker.cyclePosition?.count)
        }
    }
}
