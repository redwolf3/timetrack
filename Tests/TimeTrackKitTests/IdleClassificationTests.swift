import XCTest
@testable import TimeTrackKit

// End-to-end idle classification (#61).
//
// IdleReattributionTests hand-synthesises idle_gap / idle_resolve rows and only
// exercises Store.report's reattribution math. THIS file drives the real
// production path — Tracker.tick + a scripted IdleSource — and asserts that the
// events actually land in the database, because until #61 no production path
// ever wrote one.
//
// Timing conventions used throughout:
//   * makeCtx() disables the tracker's 1 Hz Timer, so EVERY tick in this file is
//     one the test issued, on a synthetic clock. Nothing here depends on wall
//     time passing, which is what lets the escalation test pin an exact cue count
//     instead of a tolerant range.
//   * FakeIdleSource.set(_:) is STICKY (it returns `last` once the script is
//     exhausted), so we set it before each tick rather than scripting a queue —
//     a tick count that drifts can then never desynchronise the readings.
//   * Report-math tests anchor at NOON OF A FIXED PAST DAY (same pattern as
//     PhaseSkipTests / ReconcileGateTests) so report(day:)'s closeTs is the end
//     of that day and nothing is clipped by "now".
final class IdleClassificationTests: XCTestCase {

    // MARK: - Fixtures

    private struct Ctx {
        let store: Store
        let tracker: Tracker
        let source: FakeIdleSource
        let taskA: Int64
    }

    // Tracker + Store + scripted idle source over a temp DB. Uses the seeded
    // "default" profile: one 45-min work phase, no explicit idle thresholds, so
    // the effective idle threshold is max(5, 5) * 60 = 300 s and the escalation
    // curves are EscalationConfig.default.
    @MainActor
    private func makeCtx() throws -> Ctx {
        let dir = try makeTmpDir()
        let store = try Store(url: dir.appendingPathComponent("test.db"))
        var a = Task(id: nil, name: "TaskA", code: nil, category: "project", archived: false)
        a = try store.upsertTask(a)
        let source = FakeIdleSource()
        let tracker = try Tracker(
            store: store,
            profilesURL: dir.appendingPathComponent("profiles.yaml"),
            idleSource: source)
        // Fully synthetic clock: no real Timer tick may interleave with ours.
        tracker.disableTickLoopForTesting()
        return Ctx(store: store, tracker: tracker, source: source, taskA: a.id!)
    }

    private func events(_ store: Store, _ type: EventType) throws -> [Event] {
        try store.readAllEventsInternal().filter { $0.type == type.rawValue }
    }

    private func millis(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }

    // Noon of a day fully in the past — see the file header.
    private func pastNoon(daysAgo: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: Date()))!
        return cal.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
    }

    // MARK: - 1. Episode open appends idle_gap stamped at IDLE-START

    func testEpisodeOpenAppendsIdleGapAtIdleStartNotDetectionTime() throws {
        let ctx = try MainActor.assumeIsolated { try makeCtx() }
        let t0 = Date()
        let detectAt = t0.addingTimeInterval(600)
        // Exactly the expression IdleMonitor uses (now - idleSeconds), so the
        // comparison is bit-identical rather than relying on Date arithmetic
        // associativity.
        let expectedIdleStart = detectAt.addingTimeInterval(-300)

        MainActor.assumeIsolated {
            ctx.tracker.start(taskId: ctx.taskA)
            ctx.source.set(300)                  // == effective threshold
            ctx.tracker.tick(at: detectAt)
            ctx.source.set(0)                    // no phantom episode from a stray tick
        }

        let gaps = try events(ctx.store, .idleGap)
        XCTAssertEqual(gaps.count, 1, "opening an episode must append exactly one idle_gap")
        let gap = gaps[0]
        XCTAssertEqual(gap.ts, millis(expectedIdleStart),
                       "idle_gap.ts must be idle-start (now − idleSeconds)")
        XCTAssertNotEqual(gap.ts, millis(detectAt),
                          "idle_gap.ts must NOT be detection time — locked invariant")
        XCTAssertEqual(millis(detectAt) - gap.ts, 300_000,
                       "idle_gap must be back-dated by exactly idleSeconds")
        XCTAssertEqual(gap.taskId, ctx.taskA, "idle_gap carries the task accruing at idle start")
        XCTAssertEqual(gap.phaseId, "work")
    }

    // MARK: - 2. On return, segments are pending and NOTHING is auto-resolved

    func testReturnLeavesSegmentPendingAndWritesNoIdleResolve() throws {
        let ctx = try MainActor.assumeIsolated { try makeCtx() }
        let t0 = Date()

        let pending: [IdleSegment] = MainActor.assumeIsolated {
            ctx.tracker.start(taskId: ctx.taskA)
            ctx.source.set(300)
            ctx.tracker.tick(at: t0.addingTimeInterval(600))
            ctx.source.set(0)
            ctx.tracker.tick(at: t0.addingTimeInterval(601))
            return ctx.tracker.pendingIdleSegments
        }

        XCTAssertEqual(pending.count, 1, "the returned segment must stay pending for the user")
        XCTAssertEqual(pending[0].originalTaskId, ctx.taskA)
        XCTAssertFalse(pending[0].resolved)
        XCTAssertEqual(try events(ctx.store, .idleResolve).count, 0,
                       "no idle_resolve may be written until the user classifies the segment")
    }

    // MARK: - 2b. Attribution is captured at episode OPEN, not at return

    // The race: the user comes back AND switches task within the same 1 Hz tick,
    // so the return-detecting tick reads the NEW task. Attributing the segment to
    // it would make idle_resolve.prevTaskId name a task that never accrued the
    // interval — the correction would subtract from the wrong task and leave the
    // real one over-credited. The accrual context is therefore frozen on the
    // episode when it opens.
    func testAttributionUsesTheTaskActiveAtIdleStartNotAtReturn() throws {
        let ctx = try MainActor.assumeIsolated { try makeCtx() }
        var b = Task(id: nil, name: "TaskB", code: nil, category: "project", archived: false)
        b = try ctx.store.upsertTask(b)
        let taskB = b.id!

        let pending: [IdleSegment] = MainActor.assumeIsolated {
            ctx.tracker.start(taskId: ctx.taskA)
            ctx.source.set(300)
            ctx.tracker.tick(at: Date().addingTimeInterval(600))   // idle opens on A

            // User returns and immediately switches — both land before the tick
            // that detects the return.
            ctx.tracker.switchTo(taskId: taskB)
            ctx.source.set(0)
            ctx.tracker.tick(at: Date().addingTimeInterval(601))
            return ctx.tracker.pendingIdleSegments
        }

        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].originalTaskId, ctx.taskA,
                       "the segment belongs to the task that was accruing at idle-start")

        MainActor.assumeIsolated {
            ctx.tracker.resolveIdleSegment(pending[0].id, as: .discard)
        }
        let resolves = try events(ctx.store, .idleResolve)
        XCTAssertEqual(resolves.count, 1)
        XCTAssertEqual(resolves[0].prevTaskId, ctx.taskA,
                       "prevTaskId must name the task the base walk credited, not the new one")
    }

    // MARK: - 3. Resolving each segment appends one disjoint idle_resolve and
    //            report(day:) actually moves the seconds

    func testResolvingSegmentsMovesTimeInReport() throws {
        let ctx = try MainActor.assumeIsolated { try makeCtx() }
        var b = Task(id: nil, name: "TaskB", code: nil, category: "project", archived: false)
        b = try ctx.store.upsertTask(b)
        let taskB = b.id!

        // Base timeline on a past day: A active for exactly 2 h. Synthesised
        // directly because tracker.start() necessarily stamps "now"; the events
        // under test (idle_gap / idle_resolve) are still produced by the tracker.
        let day = pastNoon(daysAgo: 3)
        let dayBase = millis(day)
        try ctx.store.append(Event(id: nil, ts: dayBase, type: EventType.start.rawValue,
            taskId: ctx.taskA, prevTaskId: nil, phaseId: "work", profileName: "default",
            extendMin: nil, comment: nil))
        try ctx.store.append(Event(id: nil, ts: dayBase + 7_200_000, type: EventType.stop.rawValue,
            taskId: nil, prevTaskId: ctx.taskA, phaseId: nil, profileName: "default",
            extendMin: nil, comment: nil))

        MainActor.assumeIsolated {
            ctx.tracker.start(taskId: ctx.taskA)

            // Two sequential episodes on that past day → two separate segments.
            for offset in [1000.0, 2000.0] {
                ctx.source.set(300)
                ctx.tracker.tick(at: day.addingTimeInterval(offset))
                ctx.source.set(0)
                ctx.tracker.tick(at: day.addingTimeInterval(offset + 1))
                for seg in ctx.tracker.pendingIdleSegments {
                    ctx.tracker.resolveIdleSegment(seg.id, as: .moveTo(taskId: taskB))
                }
                XCTAssertTrue(ctx.tracker.pendingIdleSegments.isEmpty,
                              "resolving every segment must clear the pending list")
            }
        }

        let resolves = try events(ctx.store, .idleResolve)
        XCTAssertEqual(resolves.count, 2, "exactly one idle_resolve per resolved segment")
        for r in resolves {
            XCTAssertEqual(r.prevTaskId, ctx.taskA,
                           "prevTaskId must be the task the base walk attributed the gap to")
            XCTAssertEqual(r.taskId, taskB)
            XCTAssertNotNil(r.rangeStart)
            XCTAssertNotNil(r.rangeEnd)
        }
        // Disjoint: the earlier range must end no later than the later one starts.
        let ranges = resolves
            .map { ($0.rangeStart!, $0.rangeEnd!) }
            .sorted { $0.0 < $1.0 }
        XCTAssertLessThanOrEqual(ranges[0].1, ranges[1].0,
                                 "resolve ranges must be disjoint — sliceTimeline reattributes by midpoint")

        // Report math, derived from the ranges actually written so the assertion
        // cannot drift on sub-millisecond Date rounding.
        let movedMs = ranges.reduce(Int64(0)) { $0 + ($1.1 - $1.0) }
        XCTAssertGreaterThan(movedMs, 0)
        let rows = try ctx.store.report(day: day)
        let secs = Dictionary(uniqueKeysWithValues: rows.map { ($0.task.id!, $0.totalSeconds) })
        XCTAssertEqual(secs[taskB] ?? 0, Int(movedMs / 1000),
                       "B must gain exactly the resolved intervals")
        XCTAssertEqual(secs[ctx.taskA] ?? 0, Int((7_200_000 - movedMs) / 1000),
                       "A must lose exactly the resolved intervals")
    }

    // MARK: - 4. Discard writes a NULL taskId and credits nobody

    func testDiscardRemovesTimeFromOriginalAndCreditsNobody() throws {
        let ctx = try MainActor.assumeIsolated { try makeCtx() }

        let day = pastNoon(daysAgo: 4)
        let dayBase = millis(day)
        try ctx.store.append(Event(id: nil, ts: dayBase, type: EventType.start.rawValue,
            taskId: ctx.taskA, prevTaskId: nil, phaseId: "work", profileName: "default",
            extendMin: nil, comment: nil))
        try ctx.store.append(Event(id: nil, ts: dayBase + 7_200_000, type: EventType.stop.rawValue,
            taskId: nil, prevTaskId: ctx.taskA, phaseId: nil, profileName: "default",
            extendMin: nil, comment: nil))

        MainActor.assumeIsolated {
            ctx.tracker.start(taskId: ctx.taskA)
            ctx.source.set(300)
            ctx.tracker.tick(at: day.addingTimeInterval(1000))
            ctx.source.set(0)
            ctx.tracker.tick(at: day.addingTimeInterval(1001))
            for seg in ctx.tracker.pendingIdleSegments {
                ctx.tracker.resolveIdleSegment(seg.id, as: .discard)
            }
        }

        let resolves = try events(ctx.store, .idleResolve)
        XCTAssertEqual(resolves.count, 1)
        XCTAssertNil(resolves[0].taskId, "discard must write a NULL taskId")
        XCTAssertEqual(resolves[0].prevTaskId, ctx.taskA)

        let discardedMs = resolves[0].rangeEnd! - resolves[0].rangeStart!
        let rows = try ctx.store.report(day: day)
        let secs = Dictionary(uniqueKeysWithValues: rows.map { ($0.task.id!, $0.totalSeconds) })
        XCTAssertEqual(secs[ctx.taskA] ?? 0, Int((7_200_000 - discardedMs) / 1000),
                       "the discarded interval must be removed from the original task")
        let others = rows.filter { $0.task.id != ctx.taskA }.reduce(0) { $0 + $1.totalSeconds }
        XCTAssertEqual(others, 0, "discarded time must be credited to nobody")
    }

    // MARK: - 5. Break-inPhase auto-resolve unchanged, and the episode CLEARS

    // Two things at once:
    //   (a) DESIGN.md's strict in-window break rule: returning inside a break
    //       phase emits NO idle_resolve and leaves nothing pending (the base walk
    //       already attributed the interval to the break task).
    //   (b) Regression for the never-cleared-episode bug: because that segment is
    //       auto-resolved, nobody ever calls resolveSegment for it, so IdleMonitor
    //       must nil the episode itself. Otherwise `episode == nil` never holds
    //       again and idle detection is dead for the rest of the session.
    func testBreakInPhaseAutoResolvesAndASecondEpisodeCanStillOpen() throws {
        let ctx = try MainActor.assumeIsolated { try makeCtx() }

        try MainActor.assumeIsolated {
            // pomodoro has a 5-min short_break phase with accrueAs: break.
            ctx.tracker.setProfile("pomodoro")
            ctx.tracker.start(taskId: ctx.taskA)
            ctx.tracker.jumpToPhase("short_break")
            guard case let .tracking(_, phase, _) = ctx.tracker.state else {
                return XCTFail("expected to be tracking the break phase")
            }
            XCTAssertEqual(phase.id, "short_break")
            let base = Date()   // break deadline ≈ base + 300 s

            // Episode 1: return before the arm boundary → single inPhase segment.
            ctx.source.set(300)
            ctx.tracker.tick(at: base.addingTimeInterval(250))
            ctx.source.set(0)
            ctx.tracker.tick(at: base.addingTimeInterval(251))

            XCTAssertTrue(ctx.tracker.pendingIdleSegments.isEmpty,
                          "break-phase inPhase must auto-resolve — no prompt")

            // Episode 2 must still be able to open.
            ctx.source.set(300)
            ctx.tracker.tick(at: base.addingTimeInterval(260))
            ctx.source.set(0)
        }

        XCTAssertEqual(try events(ctx.store, .idleResolve).count, 0,
                       "break-phase inPhase must emit NO idle_resolve (base walk already credits break)")
        XCTAssertEqual(try events(ctx.store, .idleGap).count, 2,
                       "idle detection must survive an auto-resolved episode — the second episode opened")
    }

    // MARK: - 5b. A second idle window opens while an earlier prompt is pending

    // The single-episode model swallowed this: with an unresolved episode parked
    // in the slot, every later idle window hit the "still idle → .none" path, so
    // no idle_gap, no segment, and the time accrued silently to the active task —
    // the exact misattribution #61 exists to stop. Ignoring the popover and going
    // to lunch is the LIKELY path, not an edge case.
    func testSecondIdleWindowIsCapturedWhileAnEarlierSegmentIsStillPending() throws {
        let ctx = try MainActor.assumeIsolated { try makeCtx() }
        let t0 = Date()

        let pending: [IdleSegment] = MainActor.assumeIsolated {
            ctx.tracker.start(taskId: ctx.taskA)

            // Episode 1: goes idle, comes back, user ignores the prompt.
            ctx.source.set(300)
            ctx.tracker.tick(at: t0.addingTimeInterval(600))
            ctx.source.set(0)
            ctx.tracker.tick(at: t0.addingTimeInterval(601))
            XCTAssertEqual(ctx.tracker.pendingIdleSegments.count, 1)

            // Episode 2: a second, later idle window — must still be detected.
            ctx.source.set(300)
            ctx.tracker.tick(at: t0.addingTimeInterval(1200))
            ctx.source.set(0)
            ctx.tracker.tick(at: t0.addingTimeInterval(1201))
            return ctx.tracker.pendingIdleSegments
        }

        XCTAssertEqual(try events(ctx.store, .idleGap).count, 2,
                       "the second idle window must append its own idle_gap")
        XCTAssertEqual(pending.count, 2, "both episodes' segments are pending, oldest first")
        // Ordered in time and disjoint across episodes (episodes never overlap).
        XCTAssertEqual(pending[0].start, t0.addingTimeInterval(600).addingTimeInterval(-300))
        XCTAssertEqual(pending[0].end, t0.addingTimeInterval(601))
        XCTAssertEqual(pending[1].start, t0.addingTimeInterval(1200).addingTimeInterval(-300))
        XCTAssertEqual(pending[1].end, t0.addingTimeInterval(1201))
        XCTAssertLessThanOrEqual(pending[0].end, pending[1].start)

        // Each resolves independently; resolving the first leaves the second pending.
        MainActor.assumeIsolated {
            ctx.tracker.resolveIdleSegment(pending[0].id, as: .discard)
            XCTAssertEqual(ctx.tracker.pendingIdleSegments.map(\.id), [pending[1].id],
                           "resolving the older episode must not touch the newer one")
            ctx.tracker.resolveIdleSegment(pending[1].id, as: .discard)
            XCTAssertTrue(ctx.tracker.pendingIdleSegments.isEmpty)
        }
        XCTAssertEqual(try events(ctx.store, .idleResolve).count, 2)
    }

    // MARK: - 6. No escalation storm with a genuinely pending segment

    // The stopgap this issue removes existed because an unresolved segment made
    // the escalation block fire on EVERY 1 Hz tick. With the presence-gated ramp
    // it must instead produce a rung-shaped ladder over the default idleReturn
    // curve — rungs at 0 / 30 / 90 / 180 cumulative active-seconds, then the
    // ceiling repeating on its 60 s cadence.
    //
    // Exact, not a range: a tolerant bound is what hid the ceiling double-fire.
    // Over 300 present ticks after the return the cues land on active-second
    // 1, 30, 90, 180 (the four rungs), then 240 and 300 (two cadence repeats
    // counted from the rung-3 cue) — six, in that order. makeCtx killed the real
    // Timer, so no wall-clock tick can perturb the count.
    func testUnresolvedSegmentProducesExactRungShapedEscalation() async throws {
        let ctx = try await MainActor.run { try makeCtx() }
        let stream = await MainActor.run { ctx.tracker.effectStream }

        // effectStream buffers only the newest 8, so drain concurrently and tick
        // in batches small enough that no batch can overflow the buffer.
        let collector = EffectCollector()
        let drain = _Concurrency.Task {
            for await e in stream { await collector.add(e) }
        }

        let t0 = Date()
        await MainActor.run {
            ctx.tracker.start(taskId: ctx.taskA)
            ctx.source.set(300)
            ctx.tracker.tick(at: t0.addingTimeInterval(600))   // episode opens
            ctx.source.set(0)
            ctx.tracker.tick(at: t0.addingTimeInterval(601))   // return → 1 pending segment
        }

        // 300 present ticks with the segment still unresolved.
        for batch in 0..<10 {
            let first = 602 + batch * 30
            await MainActor.run {
                for i in first ..< (first + 30) {
                    ctx.source.set(0)
                    ctx.tracker.tick(at: t0.addingTimeInterval(Double(i)))
                }
            }
            for _ in 0..<5 { await _Concurrency.Task.yield() }
        }
        for _ in 0..<20 { await _Concurrency.Task.yield() }
        drain.cancel()

        let collected = await collector.all
        let sounds = collected.compactMap { effect -> String? in
            if case let .playSound(name) = effect { return name }
            return nil
        }

        // Glass (rung 0), Glass (30), Hero (90), Hero (180), then two Hero repeats
        // at the 60 s ceiling cadence. 300 ticks, six cues — emphatically not 300.
        XCTAssertEqual(sounds, ["Glass", "Glass", "Hero", "Hero", "Hero", "Hero"],
            "escalation must follow the exact idleReturn ladder, once per rung")
        // Rungs 2 and 3 notify, and each ceiling repeat re-posts: four in total.
        let notifications = collected.filter {
            if case .postNotification = $0 { return true }
            return false
        }
        XCTAssertEqual(notifications.count, 4,
            "the ceiling is a persistent notification re-posted on cadence, never a modal")

        let stillPending = await MainActor.run { ctx.tracker.pendingIdleSegments.count }
        XCTAssertEqual(stillPending, 1, "nothing may auto-resolve the segment behind the user's back")
    }

    // The ceiling rung must not double-fire. Before the fix the rung-advance
    // branch returned without stamping lastNotifyAt, so the cadence branch read
    // nil as "never notified" and re-fired the same rung one tick later. Driven
    // straight at IdleMonitor: no store, no Tracker, no clock but ours.
    func testCeilingRungDoesNotDoubleFireOneTickAfterItsRung() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()

        var now = fixedEpoch
        func tick(idleSec: TimeInterval) -> IdleMonitor.Signal {
            now = now.addingTimeInterval(1)
            return MainActor.assumeIsolated {
                monitorTick(monitor, source: source, idleSec: idleSec, now: now, profile: profile)
            }
        }

        _ = tick(idleSec: 300)   // open episode
        _ = tick(idleSec: 0)     // return

        // Active seconds 1...300. Record the second each cue lands on.
        var firedAt: [Int] = []
        for active in 1...300 {
            if case .escalate = tick(idleSec: 0) { firedAt.append(active) }
        }

        XCTAssertEqual(firedAt, [1, 30, 90, 180, 240, 300],
            "four rungs, then the ceiling on its 60 s cadence — no cue one second after a rung")
    }

    // MARK: - 7. stop() discards only the STILL-OPEN episode

    // AC 7: a resolve naming a segment from an episode that stop() discarded must
    // be a no-op — it must not resurrect the episode. An open episode has no
    // segments yet (they are built on return), so the stale handle a caller could
    // hold is an id the monitor has never heard of; either way, nothing is written.
    func testStopDiscardsStillOpenEpisodeAndLaterResolvesAreNoOps() throws {
        let ctx = try MainActor.assumeIsolated { try makeCtx() }
        let t0 = Date()

        MainActor.assumeIsolated {
            ctx.tracker.start(taskId: ctx.taskA)
            ctx.source.set(300)
            ctx.tracker.tick(at: t0.addingTimeInterval(600))   // episode opens, still away

            ctx.tracker.stop()                                  // stop while still idle

            // The user comes back afterwards: the discarded episode must not
            // resurrect itself and produce segments.
            ctx.source.set(0)
            ctx.tracker.tick(at: t0.addingTimeInterval(601))
            XCTAssertTrue(ctx.tracker.pendingIdleSegments.isEmpty,
                          "an episode with no return time is unclassifiable and is dropped")

            // A resolve for an unknown segment id must do nothing at all.
            ctx.tracker.resolveIdleSegment(UUID(), as: .discard)
        }

        XCTAssertEqual(try events(ctx.store, .idleGap).count, 1,
                       "the gap was still logged — only the in-memory episode is discarded")
        XCTAssertEqual(try events(ctx.store, .idleResolve).count, 0,
                       "no idle_resolve may be written for a discarded or unknown segment")
    }

    // The companion rule: an episode the user already RETURNED from survives the
    // stop. Its range and original task are fully determined, so dropping it would
    // silently bill that idle to the original task — and would make Stop a way to
    // escape the escalation ramp.
    func testReturnedSegmentsSurviveStopAndRemainResolvable() throws {
        let ctx = try MainActor.assumeIsolated { try makeCtx() }
        let t0 = Date()

        let pending: [IdleSegment] = MainActor.assumeIsolated {
            ctx.tracker.start(taskId: ctx.taskA)
            ctx.source.set(300)
            ctx.tracker.tick(at: t0.addingTimeInterval(600))
            ctx.source.set(0)
            ctx.tracker.tick(at: t0.addingTimeInterval(601))    // returned → 1 pending
            XCTAssertEqual(ctx.tracker.pendingIdleSegments.count, 1)

            ctx.tracker.stop()
            return ctx.tracker.pendingIdleSegments
        }

        XCTAssertEqual(pending.count, 1, "returned-but-unresolved segments outlive stop()")

        MainActor.assumeIsolated {
            ctx.tracker.resolveIdleSegment(pending[0].id, as: .discard)
            XCTAssertTrue(ctx.tracker.pendingIdleSegments.isEmpty)
        }

        let resolves = try events(ctx.store, .idleResolve)
        XCTAssertEqual(resolves.count, 1, "the segment is still resolvable after stop")
        XCTAssertNil(resolves[0].taskId)
        XCTAssertEqual(resolves[0].prevTaskId, ctx.taskA)
        XCTAssertEqual(resolves[0].rangeStart, millis(pending[0].start))
        XCTAssertEqual(resolves[0].rangeEnd, millis(pending[0].end))
    }

    // MARK: - 7b. keepOnOriginal records the decision without moving time

    func testKeepOnOriginalWritesANetZeroResolveAndClearsThePrompt() throws {
        let ctx = try MainActor.assumeIsolated { try makeCtx() }
        let t0 = Date()

        MainActor.assumeIsolated {
            ctx.tracker.start(taskId: ctx.taskA)
            ctx.source.set(300)
            ctx.tracker.tick(at: t0.addingTimeInterval(600))
            ctx.source.set(0)
            ctx.tracker.tick(at: t0.addingTimeInterval(601))
            for seg in ctx.tracker.pendingIdleSegments {
                ctx.tracker.resolveIdleSegment(seg.id, as: .keepOnOriginal)
            }
            XCTAssertTrue(ctx.tracker.pendingIdleSegments.isEmpty,
                          "an explicit keep clears the prompt and the escalation")
        }

        let resolves = try events(ctx.store, .idleResolve)
        XCTAssertEqual(resolves.count, 1)
        XCTAssertEqual(resolves[0].taskId, ctx.taskA,
                       "keep resolves to the original task — the kit maps it, not the caller")
        XCTAssertEqual(resolves[0].prevTaskId, ctx.taskA,
                       "prev == target, so the report nets to zero: a recorded no-op decision")
    }

    // MARK: - 7c. .toBreak resolves to the synthetic break task

    func testToBreakResolvesToTheSyntheticBreakTask() throws {
        let ctx = try MainActor.assumeIsolated { try makeCtx() }
        let breakId = try ctx.store.breakTaskId()
        let t0 = Date()

        MainActor.assumeIsolated {
            XCTAssertTrue(ctx.tracker.canClassifyAsBreak,
                          "the store seeds a break task, so the app may offer the choice")
            ctx.tracker.start(taskId: ctx.taskA)
            ctx.source.set(300)
            ctx.tracker.tick(at: t0.addingTimeInterval(600))
            ctx.source.set(0)
            ctx.tracker.tick(at: t0.addingTimeInterval(601))
            for seg in ctx.tracker.pendingIdleSegments {
                ctx.tracker.resolveIdleSegment(seg.id, as: .toBreak)
            }
        }

        let resolves = try events(ctx.store, .idleResolve)
        XCTAssertEqual(resolves.count, 1)
        XCTAssertEqual(resolves[0].taskId, breakId,
                       "the kit maps .toBreak onto the break row; the app never names it")
    }

    // MARK: - 8. An episode spanning an arm boundary splits into exactly two
    //            disjoint, contiguous segments — end to end through Tracker

    // armPhase now stamps armedAt with the TICK's clock, so the boundary is an
    // exact synthetic instant (the arming tick, t0 + 2800) rather than wall-clock
    // "whenever the test happened to run" — the split can be asserted precisely.
    func testEpisodeArmingMidEpisodeSplitsIntoTwoContiguousSegmentsAndTwoResolves() throws {
        let ctx = try MainActor.assumeIsolated { try makeCtx() }
        let t0 = Date()                    // default profile ⇒ deadline ≈ t0 + 45 min
        let armAt = t0.addingTimeInterval(2800)
        let returnAt = t0.addingTimeInterval(2801)
        let idleStart = t0.addingTimeInterval(600).addingTimeInterval(-300)

        let pending: [IdleSegment] = MainActor.assumeIsolated {
            ctx.tracker.start(taskId: ctx.taskA)
            // Episode opens while still .tracking ⇒ boundary is the live deadline.
            ctx.source.set(300)
            ctx.tracker.tick(at: t0.addingTimeInterval(600))
            // Still idle, but this tick crosses the deadline and ARMS the phase.
            ctx.tracker.tick(at: armAt)
            guard case .armed = ctx.tracker.state else {
                XCTFail("the deadline-crossing tick must arm the phase"); return []
            }
            ctx.source.set(0)
            ctx.tracker.tick(at: returnAt)
            return ctx.tracker.pendingIdleSegments
        }

        XCTAssertEqual(pending.count, 2, "an episode spanning the arm boundary splits in two")
        XCTAssertEqual(pending[0].kind, .inPhase)
        XCTAssertEqual(pending[1].kind, .overrun)
        XCTAssertEqual(pending[0].start, idleStart,
                       "segment 1 starts at idle-start, not detection time")
        XCTAssertEqual(pending[0].end, armAt, "segment 1 ends exactly at the arm boundary")
        XCTAssertEqual(pending[1].start, armAt,
                       "segments must be contiguous — they meet exactly at the arm boundary")
        XCTAssertEqual(pending[1].end, returnAt)

        MainActor.assumeIsolated {
            for seg in pending { ctx.tracker.resolveIdleSegment(seg.id, as: .keepOnOriginal) }
            XCTAssertTrue(ctx.tracker.pendingIdleSegments.isEmpty)
        }

        let resolves = try events(ctx.store, .idleResolve)
        XCTAssertEqual(resolves.count, 2, "exactly one idle_resolve per segment")
        let ranges = resolves.map { ($0.rangeStart!, $0.rangeEnd!) }.sorted { $0.0 < $1.0 }
        XCTAssertEqual(ranges[0].1, ranges[1].0,
                       "the two written ranges must be disjoint and contiguous")
        XCTAssertLessThan(ranges[0].0, ranges[0].1)
        XCTAssertLessThan(ranges[1].0, ranges[1].1)
    }

    // MARK: - 8b. Break phase spanning the arm boundary: inPhase auto-resolves,
    //             overrun still prompts

    // This is the case the old `armBoundary = nil` collapsed into a single
    // .overrun: the strict in-window break rule never fired, so the user was
    // prompted to classify break time DESIGN.md says must resolve silently.
    func testBreakEpisodeSpanningArmBoundaryAutoResolvesOnlyTheInPhasePortion() throws {
        let ctx = try MainActor.assumeIsolated { try makeCtx() }
        let breakId = try ctx.store.breakTaskId()
        XCTAssertNotEqual(breakId, -1, "the store seeds a synthetic break task")

        let overrun: IdleSegment? = try MainActor.assumeIsolated { () -> IdleSegment? in
            ctx.tracker.setProfile("pomodoro")
            ctx.tracker.start(taskId: ctx.taskA)
            ctx.tracker.jumpToPhase("short_break")      // 5-min phase, accrueAs: break
            let base = Date()                            // deadline ≈ base + 300 s
            let armAt = base.addingTimeInterval(310)

            ctx.source.set(300)
            ctx.tracker.tick(at: base.addingTimeInterval(10))    // opens while .tracking
            ctx.tracker.tick(at: armAt)                          // crosses deadline → armed
            guard case .armed = ctx.tracker.state else {
                XCTFail("the break phase must arm at its deadline"); return nil
            }
            ctx.source.set(0)
            ctx.tracker.tick(at: base.addingTimeInterval(311))   // return

            let pending = ctx.tracker.pendingIdleSegments
            XCTAssertEqual(pending.count, 1,
                           "only the overrun portion may prompt — inPhase auto-resolves to break")
            XCTAssertEqual(pending.first?.kind, .overrun)
            XCTAssertEqual(pending.first?.start, armAt,
                           "the prompted portion starts where the auto-resolved inPhase ends")
            return pending.first
        }

        XCTAssertEqual(try events(ctx.store, .idleResolve).count, 0,
                       "the auto-resolved break inPhase portion must emit no idle_resolve")

        // The overrun portion is a real decision and writes exactly one resolve.
        guard let overrun else { return }
        MainActor.assumeIsolated {
            ctx.tracker.resolveIdleSegment(overrun.id, as: .moveTo(taskId: ctx.taskA))
        }
        let resolves = try events(ctx.store, .idleResolve)
        XCTAssertEqual(resolves.count, 1, "only the overrun portion is user-resolved")
        XCTAssertEqual(resolves[0].prevTaskId, breakId,
                       "the base walk credited the overrun to the break task")
        XCTAssertEqual(resolves[0].taskId, ctx.taskA)
        XCTAssertEqual(resolves[0].rangeStart, millis(overrun.start))
        XCTAssertEqual(resolves[0].rangeEnd, millis(overrun.end))
    }

    // MARK: - 8c. Already armed BEFORE idle began → a single .overrun segment

    // The boundary is real but sits at/before idleStart, so it cannot split the
    // episode. Mislabelling this .inPhase would let the break auto-resolve swallow
    // overrun time the user must classify.
    func testAlreadyArmedBeforeIdleYieldsSingleOverrunSegment() throws {
        let ctx = try MainActor.assumeIsolated { try makeCtx() }
        let t0 = Date()

        let pending: [IdleSegment] = MainActor.assumeIsolated {
            ctx.tracker.start(taskId: ctx.taskA)
            ctx.source.set(0)
            ctx.tracker.tick(at: t0.addingTimeInterval(2800))   // arms while present
            guard case .armed = ctx.tracker.state else {
                XCTFail("expected the phase to be armed before idle begins"); return []
            }
            // Idle begins strictly AFTER the arm: idleStart = t0 + 2900 > armedAt
            // (t0 + 2800), so the boundary is behind the episode and cannot split it.
            ctx.source.set(300)
            ctx.tracker.tick(at: t0.addingTimeInterval(3200))
            ctx.source.set(0)
            ctx.tracker.tick(at: t0.addingTimeInterval(3201))
            return ctx.tracker.pendingIdleSegments
        }

        XCTAssertEqual(pending.count, 1, "inPhase collapses when the phase was already armed")
        XCTAssertEqual(pending[0].kind, .overrun)
        XCTAssertEqual(pending[0].start, t0.addingTimeInterval(3200).addingTimeInterval(-300))
        XCTAssertEqual(pending[0].end, t0.addingTimeInterval(3201))
    }

    // MARK: - 8d. IdleMonitor-level boundary arithmetic (deterministic)

    // Kept alongside the end-to-end tests above: this one exercises the boundary
    // arithmetic in isolation, with no Tracker state machine or store involved.
    func testMonitorSplitsAtBoundaryIntoTwoDisjointContiguousSegments() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()

        let t0 = fixedEpoch
        let boundary = t0.addingTimeInterval(120)
        let detectAt = t0.addingTimeInterval(300)   // idleSec 300 ⇒ idleStart == t0
        let returnAt = t0.addingTimeInterval(400)

        _ = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 300, now: detectAt,
                        profile: profile, armBoundary: boundary)
        }
        let sig = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 0, now: returnAt,
                        profile: profile, armBoundary: boundary)
        }
        guard case let .returned(segs) = sig else {
            return XCTFail("expected .returned, got \(sig)")
        }

        XCTAssertEqual(segs.count, 2, "two segments max per episode — inPhase + overrun")
        XCTAssertEqual(segs[0].kind, .inPhase)
        XCTAssertEqual(segs[1].kind, .overrun)
        XCTAssertEqual(segs[0].start, t0)
        XCTAssertEqual(segs[0].end, segs[1].start,
                       "segments must be contiguous — they meet exactly at the arm boundary")
        XCTAssertEqual(segs[1].end, returnAt)
        XCTAssertLessThan(segs[0].start, segs[0].end)
        XCTAssertLessThan(segs[1].start, segs[1].end)
    }

    // The new collapse rule, on a fixed clock: a NON-nil boundary at or before
    // idleStart is "already armed", so the single segment is .overrun — and on a
    // break phase it must therefore stay pending rather than auto-resolve.
    func testMonitorCollapsesToOverrunWhenBoundaryPrecedesIdleStart() {
        let source = FakeIdleSource()
        let monitor = MainActor.assumeIsolated { IdleMonitor(source: source) }
        let profile = makeTestProfile()

        let t0 = fixedEpoch
        let boundary = t0.addingTimeInterval(-60)   // armed a minute before idle began
        let detectAt = t0.addingTimeInterval(300)   // idleSec 300 ⇒ idleStart == t0
        let returnAt = t0.addingTimeInterval(400)

        _ = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 300, now: detectAt,
                        profile: profile, armBoundary: boundary, isBreakPhase: true)
        }
        let sig = MainActor.assumeIsolated {
            monitorTick(monitor, source: source, idleSec: 0, now: returnAt,
                        profile: profile, armBoundary: boundary, isBreakPhase: true)
        }
        guard case let .returned(segs) = sig else {
            return XCTFail("expected .returned, got \(sig)")
        }

        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].kind, .overrun,
                       "a boundary at/before idleStart means the whole episode is overrun")
        XCTAssertFalse(segs[0].resolved,
                       "break auto-resolve applies to the inPhase portion only — this must still prompt")
        XCTAssertEqual(segs[0].start, t0)
        XCTAssertEqual(segs[0].end, returnAt)
    }
}

// Collects effects drained off Tracker.effectStream from a background task.
private actor EffectCollector {
    private(set) var all: [Effect] = []
    func add(_ e: Effect) { all.append(e) }
}
