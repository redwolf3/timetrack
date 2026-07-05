import XCTest
@testable import TimeTrackKit

// flowArm escalation (issue #24): the "true flow" case — a phase has ARMED but
// the user never went idle. A presence-gated ramp over the flowArm curve's rungs
// with afterActiveSec > 0, capped at icon + sound (never a notification).
//
// Distinct from idleReturn (covered in IdleMonitorTests): there is NO idle
// episode here. The driver passes phaseArmedAt (the .armed state's armedAt) and
// keeps idleSec small so the user reads as present the whole time.
final class FlowArmEscalationTests: XCTestCase {

    // Tracer bullet: armed + continuously present → the flowArm rung at
    // afterActiveSec=120 (default curve) fires once 120 cumulative active seconds
    // have elapsed since arm, and not before.
    func testFlowArmRungFiresAfterItsActiveSecondThreshold() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()
        let armedAt = fixedEpoch

        var now = armedAt
        var firedAtSecond: Int? = nil

        // Drive 130 present ticks (idleSec=0) while armed.
        for i in 1...130 {
            now = now.addingTimeInterval(1)
            let sig = MainActor.assumeIsolated {
                monitorTick(monitor, source: source, idleSec: 0, now: now,
                            profile: profile, phaseArmedAt: armedAt)
            }
            if case let .escalate(rung) = sig, rung.afterActiveSec == 120 {
                firedAtSecond = i
            }
        }

        XCTAssertEqual(firedAtSecond, 120,
                       "flowArm rung (afterActiveSec=120) must fire exactly at the 120th active second")
    }

    // Rung-0 (afterActiveSec: 0) is subsumed by Tracker's onArm.sound arm cue.
    // It must NEVER fire from the flowArm ramp — otherwise the arm sound doubles.
    func testFlowArmRungZeroNeverFires() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()
        let armedAt = fixedEpoch

        var now = armedAt
        // First 119 active seconds: below the only afterActiveSec>0 rung (120),
        // so nothing should escalate — and rung-0 must not sneak in at second 1.
        for _ in 1...119 {
            now = now.addingTimeInterval(1)
            let sig = MainActor.assumeIsolated {
                monitorTick(monitor, source: source, idleSec: 0, now: now,
                            profile: profile, phaseArmedAt: armedAt)
            }
            if case let .escalate(rung) = sig {
                XCTFail("No flowArm rung should fire before 120 active sec; got afterActiveSec=\(rung.afterActiveSec)")
            }
        }
    }

    // Presence-gated: idle ticks (idleSec >= 5) must not advance the ramp. You
    // cannot wait out flowArm by walking away — only active seconds count.
    func testFlowArmCounterPausesWhenUserIsIdle() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()
        let armedAt = fixedEpoch

        var now = armedAt
        func tick(idleSec: TimeInterval) -> IdleMonitor.Signal {
            now = now.addingTimeInterval(1)
            return MainActor.assumeIsolated {
                monitorTick(monitor, source: source, idleSec: idleSec, now: now,
                            profile: profile, phaseArmedAt: armedAt)
            }
        }

        // 119 active seconds — not yet at the 120 rung.
        for _ in 1...119 { _ = tick(idleSec: 0) }

        // 100 idle ticks — these must NOT count; wall clock now well past 120s
        // since arm, but active-seconds is still only 119.
        for _ in 1...100 {
            if case .escalate = tick(idleSec: 60) {
                XCTFail("flowArm fired on an idle tick — counter must freeze when away")
            }
        }

        // The next single ACTIVE second is the 120th — now the rung fires.
        guard case let .escalate(rung) = tick(idleSec: 0), rung.afterActiveSec == 120 else {
            XCTFail("flowArm rung must fire on the 120th *active* second, regardless of wall clock")
            return
        }
    }

    // Cap at icon + sound (DESIGN.md Escalation): even if a profile misconfigures
    // a flowArm rung with notify: true, the surfaced rung must have notify == false
    // and no repeat cadence — flowArm can never produce a notification.
    func testFlowArmRungNeverSurfacesNotify() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let armedAt = fixedEpoch

        // Profile whose flowArm rung-1 (afterActiveSec=2) wrongly asks to notify.
        let escalation = EscalationConfig(
            flowArm: [
                EscalationRung(afterActiveSec: 0, sound: "Tink", color: "amber",
                               notify: false, repeatNotifySec: nil),
                EscalationRung(afterActiveSec: 2, sound: "Tink", color: "amber_pulse",
                               notify: true, repeatNotifySec: 30)   // forbidden — must be stripped
            ],
            idleReturn: EscalationConfig.default.idleReturn)
        let arm = ArmConfig(sound: "Tink", color: "amber", actions: [])
        let profile = Profile(
            name: "default",
            cycle: [Phase(id: "work", durationMin: 25, accrueAs: nil, onArm: arm)],
            longCycleEvery: nil, longCycleOverride: nil,
            idleThresholdMin: 5, wiggleRoomMin: 2, escalation: escalation)

        var now = armedAt
        var fired: EscalationRung? = nil
        for _ in 1...3 {
            now = now.addingTimeInterval(1)
            let sig = MainActor.assumeIsolated {
                monitorTick(monitor, source: source, idleSec: 0, now: now,
                            profile: profile, phaseArmedAt: armedAt)
            }
            if case let .escalate(r) = sig { fired = r }
        }

        guard let r = fired else { XCTFail("flowArm rung should have fired by 2 active sec"); return }
        XCTAssertFalse(r.notify, "flowArm rung must never surface notify=true")
        XCTAssertNil(r.repeatNotifySec, "flowArm rung must never carry a repeat-notify cadence")
    }

    // flowArm runs only while ARMED. With no arm (phaseArmedAt == nil, e.g. plain
    // .tracking), the ramp must never fire no matter how long the user is present.
    func testNoFlowArmRampWhileTracking() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()

        var now = fixedEpoch
        for _ in 1...200 {
            now = now.addingTimeInterval(1)
            let sig = MainActor.assumeIsolated {
                monitorTick(monitor, source: source, idleSec: 0, now: now,
                            profile: profile, phaseArmedAt: nil)
            }
            if case .escalate = sig {
                XCTFail("flowArm must not ramp while not armed (phaseArmedAt == nil)")
            }
        }
    }

    // A new arm (different armedAt timestamp) restarts the ramp from zero, so the
    // accumulated active-seconds of the previous arm don't carry over.
    func testFlowArmResetsOnNewArm() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()

        var now = fixedEpoch
        let arm1 = fixedEpoch

        // 119 active seconds under the first arm — just shy of the 120 rung.
        for _ in 1...119 {
            now = now.addingTimeInterval(1)
            _ = MainActor.assumeIsolated {
                monitorTick(monitor, source: source, idleSec: 0, now: now,
                            profile: profile, phaseArmedAt: arm1)
            }
        }

        // Re-arm with a distinct timestamp. The ramp resets: 119 more active
        // seconds must still NOT fire (would have, were the counter carried over).
        let arm2 = now.addingTimeInterval(1)
        for _ in 1...119 {
            now = now.addingTimeInterval(1)
            let sig = MainActor.assumeIsolated {
                monitorTick(monitor, source: source, idleSec: 0, now: now,
                            profile: profile, phaseArmedAt: arm2)
            }
            if case .escalate = sig {
                XCTFail("ramp must restart on a new arm — previous arm's active seconds must not carry over")
            }
        }

        // The 120th active second under arm2 fires.
        now = now.addingTimeInterval(1)
        let sig = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 0, now: now,
                        profile: profile, phaseArmedAt: arm2)
        }
        guard case let .escalate(rung) = sig, rung.afterActiveSec == 120 else {
            XCTFail("flowArm rung must fire at 120 active sec into the new arm")
            return
        }
    }

    // Integration: Tracker passes a non-nil phaseArmedAt while .armed and surfaces
    // a fired flowArm rung as icon + sound effects — and NEVER a notification.
    // Uses the seeded "default" profile (no escalation → IdleMonitor's .default
    // flowArm curve, rung at afterActiveSec=120, colour "amber_pulse").
    func testTrackerSurfacesFlowArmAsIconAndSoundNeverNotify() async throws {
        let dir = try makeTmpDir()
        let (tracker, _, taskId) = try await MainActor.run { try makeTrackerContext(in: dir) }
        let stream = await MainActor.run { tracker.effectStream }

        await MainActor.run {
            tracker.start(taskId: taskId)
            // Arm by ticking past the 45-min default deadline. This tick is the
            // first armed tick (flow active-seconds = 1).
            let armDate = Date().addingTimeInterval(60 * 60)
            tracker.tick(at: armDate)
            // 119 more present ticks (FakeIdleSource reports 0 = present) → 120
            // cumulative active seconds while armed, firing the 120 rung.
            for i in 1...119 {
                tracker.tick(at: armDate.addingTimeInterval(Double(i)))
            }
        }

        // Effects buffered (newest 8): arm sound + the rung's sound + setIconColor.
        var collected: [Effect] = []
        for await e in stream {
            collected.append(e)
            if collected.count >= 3 { break }
        }

        XCTAssertTrue(collected.contains(.setIconColor("amber_pulse")),
                      "flowArm must surface the rung colour as a setIconColor effect")
        XCTAssertFalse(
            collected.contains { if case .postNotification = $0 { return true }; return false },
            "flowArm must NEVER post a notification (capped at icon + sound)")
    }
}
