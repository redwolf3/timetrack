import XCTest
@testable import TimeTrackKit

// Tests run on the main thread (XCTest synchronous runner).
// MainActor.assumeIsolated lets us call @MainActor-isolated IdleMonitor methods
// without async overhead while keeping the compiler's isolation rules satisfied.
final class IdleMonitorTests: XCTestCase {

    // MARK: - Episode opening

    // Idle below the effective threshold (max of idleThresholdMin, wiggleRoomMin)
    // must not open an episode.  Here wiggleRoomMin (5 min) > idleThresholdMin
    // (3 min) so the effective threshold is 300 s; 240 s is below it.
    func testIdleBelowEffectiveThresholdProducesNoEpisode() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        // effective threshold = max(3 min, 5 min) = 300 s
        let profile = makeTestProfile(idleThresholdMin: 3, wiggleRoomMin: 5)

        let sig = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 240, now: fixedEpoch, profile: profile)
        }

        XCTAssertEqual(sig, .none)
        MainActor.assumeIsolated { XCTAssertNil(monitor.episode) }
    }

    func testIdleAtThresholdOpensEpisode() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile(idleThresholdMin: 5, wiggleRoomMin: 2)  // effective = 300 s

        let sig = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 300, now: fixedEpoch, profile: profile)
        }

        if case .idleDetected = sig {} else { XCTFail("Expected .idleDetected, got \(sig)") }
        MainActor.assumeIsolated { XCTAssertNotNil(monitor.episode) }
    }

    // The episode's idleStart must equal `now − idleSeconds`, not detection time.
    func testIdleStartIsNowMinusIdleSeconds() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()

        let idleSec: TimeInterval = 600   // 10 min
        let now = fixedEpoch
        let expectedStart = now.addingTimeInterval(-idleSec)

        let sig = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: idleSec, now: now, profile: profile)
        }

        if case let .idleDetected(start) = sig {
            XCTAssertEqual(start, expectedStart)
        } else {
            XCTFail("Expected .idleDetected, got \(sig)")
        }
    }

    // MARK: - Segment building

    // Two-segment split: inPhase [idleStart, boundary] + overrun [boundary, return].
    // Condition: boundary exists AND boundary > idleStart AND boundary < returnTime.
    func testTwoSegmentSplitWhenBoundaryCrossedDuringIdle() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()

        let t0          = fixedEpoch
        let armBoundary = t0.addingTimeInterval(120)    // arm at t0 + 2 min
        let detectNow   = t0.addingTimeInterval(300)    // detected: idleSec=300, idleStart=t0
        let returnNow   = t0.addingTimeInterval(301)

        // Tick 1: open episode
        let sig1 = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 300, now: detectNow,
                        profile: profile, armBoundary: armBoundary)
        }
        if case let .idleDetected(start) = sig1 {
            XCTAssertEqual(start, t0)
        } else {
            XCTFail("Expected .idleDetected, got \(sig1)"); return
        }

        // Tick 2: user returns
        let sig2 = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 0, now: returnNow,
                        profile: profile, armBoundary: armBoundary)
        }
        guard case let .returned(segs) = sig2 else {
            XCTFail("Expected .returned, got \(sig2)"); return
        }

        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].kind, .inPhase)
        XCTAssertEqual(segs[0].start, t0)
        XCTAssertEqual(segs[0].end,   armBoundary)
        XCTAssertEqual(segs[1].kind,  .overrun)
        XCTAssertEqual(segs[1].start, armBoundary)
        XCTAssertEqual(segs[1].end,   returnNow)
    }

    // Single overrun when armBoundary == nil (phase was already armed at idle start).
    func testCollapseToSingleOverrunWhenAlreadyArmed() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()

        let t0        = fixedEpoch
        let detectNow = t0.addingTimeInterval(300)
        let returnNow = t0.addingTimeInterval(301)

        let _ = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 300, now: detectNow,
                        profile: profile, armBoundary: nil)
        }
        let sig = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 0, now: returnNow,
                        profile: profile, armBoundary: nil)
        }
        guard case let .returned(segs) = sig else {
            XCTFail("Expected .returned, got \(sig)"); return
        }

        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].kind,  .overrun)
        XCTAssertEqual(segs[0].start, t0)
        XCTAssertEqual(segs[0].end,   returnNow)
    }

    // Single inPhase when the user returns before the arm boundary.
    func testCollapseToSingleInPhaseWhenReturnBeforeBoundary() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()

        let t0          = fixedEpoch
        let armBoundary = t0.addingTimeInterval(1000)   // boundary is far in the future
        let detectNow   = t0.addingTimeInterval(300)
        let returnNow   = t0.addingTimeInterval(301)

        let _ = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 300, now: detectNow,
                        profile: profile, armBoundary: armBoundary)
        }
        let sig = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 0, now: returnNow,
                        profile: profile, armBoundary: armBoundary)
        }
        guard case let .returned(segs) = sig else {
            XCTFail("Expected .returned, got \(sig)"); return
        }

        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].kind, .inPhase)
        XCTAssertEqual(segs[0].start, t0)
        XCTAssertEqual(segs[0].end,   returnNow)
    }

    // During a break phase, the inPhase segment accrues to the break task and
    // needs no user correction.  It must be pre-resolved and excluded from the
    // returned segment list so no idle_resolve event is emitted.
    func testBreakPhaseInPhaseAutoResolvesWithoutIdleResolveEvent() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()

        let t0          = fixedEpoch
        let armBoundary = t0.addingTimeInterval(120)
        let detectNow   = t0.addingTimeInterval(300)
        let returnNow   = t0.addingTimeInterval(301)

        let _ = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 300, now: detectNow,
                        profile: profile, armBoundary: armBoundary, isBreakPhase: true)
        }
        let sig = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 0, now: returnNow,
                        profile: profile, armBoundary: armBoundary, isBreakPhase: true)
        }
        guard case let .returned(unresolved) = sig else {
            XCTFail("Expected .returned, got \(sig)"); return
        }

        // Only the overrun needs user action; inPhase is silently resolved.
        XCTAssertEqual(unresolved.count, 1, "inPhase during break must not appear in the prompt")
        XCTAssertEqual(unresolved[0].kind, .overrun)

        // Verify the raw episode holds both segments, with inPhase already resolved.
        let allSegs = MainActor.assumeIsolated { monitor.episode?.segments ?? [] }
        XCTAssertEqual(allSegs.count, 2)
        XCTAssertTrue(allSegs[0].resolved,  "inPhase in break phase must be auto-resolved")
        XCTAssertFalse(allSegs[1].resolved, "overrun must require explicit user resolution")
    }

    // MARK: - Escalation (presence-gated)

    // Escalation counter must not advance during idle ticks (idleSec >= 5).
    // Rung 1 (afterActiveSec=30) must not fire if the user has only been active
    // for 1 second since return.
    func testEscalationCounterPausesWhenUserIsIdle() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()

        var now = fixedEpoch

        // Open episode.
        let _ = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 300, now: now, profile: profile)
        }
        // Return.
        now = now.addingTimeInterval(1)
        let _ = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 0, now: now, profile: profile)
        }

        // First active tick → rung 0 (afterActiveSec=0).
        now = now.addingTimeInterval(1)
        let sig = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 0, now: now, profile: profile)
        }
        if case let .escalate(rung) = sig { XCTAssertEqual(rung.afterActiveSec, 0) }
        else { XCTFail("Expected rung 0 escalation, got \(sig)"); return }

        // 50 inactive ticks — counter must stay at 1; rung 1 must not fire.
        for i in 0..<50 {
            now = now.addingTimeInterval(1)
            let s = MainActor.assumeIsolated {
                monitorTick(monitor, source: source, idleSec: 60, now: now, profile: profile)
            }
            if case let .escalate(r) = s, r.afterActiveSec > 0 {
                XCTFail("Higher rung fired on inactive tick \(i) — counter should be frozen"); return
            }
        }

        let counter = MainActor.assumeIsolated { monitor.episode?.activeSecondsSinceReturn ?? -1 }
        XCTAssertEqual(counter, 1.0,
                       "activeSecondsSinceReturn must not advance during idle ticks")
    }

    // After 30 total active seconds since return, rung 1 (afterActiveSec=30) fires.
    // Idle ticks interspersed between the active runs do not count toward the 30.
    func testEscalationRung1FiresAfter30ActiveSeconds() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()

        var now = fixedEpoch

        // Open episode + return.
        let _ = MainActor.assumeIsolated { monitorTick(monitor, source: source, idleSec: 300, now: now, profile: profile) }
        now = now.addingTimeInterval(1)
        let _ = MainActor.assumeIsolated { monitorTick(monitor, source: source, idleSec: 0, now: now, profile: profile) }

        var rung1Fired = false

        // Pattern: 15 active, 10 idle, 15 active = 30 active total.
        func runActive(_ n: Int) {
            for _ in 0..<n {
                now = now.addingTimeInterval(1)
                let s = MainActor.assumeIsolated {
                    monitorTick(monitor, source: source, idleSec: 0, now: now, profile: profile)
                }
                if case let .escalate(r) = s, r.afterActiveSec == 30 { rung1Fired = true }
            }
        }
        func runInactive(_ n: Int) {
            for _ in 0..<n {
                now = now.addingTimeInterval(1)
                let _ = MainActor.assumeIsolated {
                    monitorTick(monitor, source: source, idleSec: 60, now: now, profile: profile)
                }
            }
        }

        runActive(15)
        runInactive(10)
        runActive(15)

        XCTAssertTrue(rung1Fired, "Rung 1 (afterActiveSec=30) must fire after 30 cumulative active seconds")
    }
}
