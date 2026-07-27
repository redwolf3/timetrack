import Foundation

// State machine. Three states, transitions logged as events.
public enum TrackerState: Equatable {
    case idle
    case tracking(taskId: Int64, phase: Phase, deadline: Date)
    case armed(taskId: Int64, phase: Phase, nextPhase: Phase, armedAt: Date)

    public static func == (l: TrackerState, r: TrackerState) -> Bool {
        switch (l, r) {
        case (.idle, .idle): return true
        case let (.tracking(a, p, d), .tracking(a2, p2, d2)):
            return a == a2 && p.id == p2.id && d == d2
        case let (.armed(a, p, n, t), .armed(a2, p2, n2, t2)):
            return a == a2 && p.id == p2.id && n.id == n2.id && t == t2
        default: return false
        }
    }
}

@MainActor
public final class Tracker {
    // Plain getters for observable properties. The app reads these synchronously;
    // state changes are also pushed onto stateStream so views can react without
    // polling. The other properties change less often — the app can refresh them
    // alongside a state-stream event or via tick-driven mechanisms in Phase 5.
    public private(set) var state: TrackerState = .idle {
        didSet { stateContinuation.yield(state) }
    }
    public private(set) var activeTask: Task?
    public private(set) var profileName: String = "default"
    public private(set) var tasks: [Task] = []
    public private(set) var profiles: [Profile] = []
    public private(set) var todaySeconds: [Int64: Int] = [:]  // taskId -> sec

    // Idle segments awaiting an explicit user classification. Observable state
    // rather than an Effect: this is a list to RENDER (and to keep rendering
    // until the user decides), not a fire-and-forget side effect like a sound.
    // Aggregated across every outstanding episode, in time order — see
    // refreshPendingIdleSegments() for the single write site.
    public private(set) var pendingIdleSegments: [IdleSegment] = []

    // Whether .toBreak is a resolution the store can actually honour. False when
    // the registry has no synthetic break row (Store's -1 sentinel), in which case
    // resolveIdleSegment(.toBreak) no-ops — so the app must not offer the choice.
    public var canClassifyAsBreak: Bool { breakTaskIdOrNil != nil }

    // The synthetic break task's id, or nil for Store's "-1 = no break row"
    // sentinel. Private: callers say what they MEAN (.toBreak) and let the kit
    // resolve it, so no "break" category literal or -1 sentinel leaks outward.
    private var breakTaskIdOrNil: Int64? {
        let id = (try? store.breakTaskId()) ?? -1
        return id == -1 ? nil : id
    }

    // The wall-clock time when the current tracking phase actually began.
    // Reset on start(), advance(), and extend() — any event that starts a new
    // phase interval. NOT reset on switchTo() when a task switch preserves the
    // same phase (same deadline), so elapsed time is continuous across task
    // switches within a phase. AppState reads this directly instead of
    // reverse-engineering it from deadline - durationMin, which breaks after
    // extend() because extend sets deadline = now + extendMin (not
    // now + durationMin).
    public private(set) var phaseStartedAt: Date = Date()

    // Position of the current phase within the active cycle, as (1-based index,
    // total phases in the cycle), or nil when idle. Reflects the long-cycle
    // override. The app uses this for the "Work 2/4" cycle indicator; the
    // CycleIterator itself stays private to the kit.
    //
    // Gated on state, NOT on iterator != nil: stop() resets the iterator but
    // keeps it, and setProfile() rebuilds it even while idle, so the iterator is
    // non-nil between sessions. Only state is authoritative for "idle".
    public var cyclePosition: (index: Int, count: Int)? {
        if case .idle = state { return nil }
        return iterator?.cyclePosition
    }

    // Observation seam, replacing Combine. Single-subscriber AsyncStreams: the
    // app awaits them. The kit decides what should happen (a state transition,
    // a sound to play); the app performs any side effect.
    //
    // TODO (PR#1, Phase 5): These streams are single-consumer — each element is
    // delivered to exactly one iterator.  If multiple views ever need state, replace
    // with a broadcast primitive (e.g. AsyncBroadcastSequence or a Subject wrapper).
    //
    // stateStream uses bufferingNewest(1): rapid transitions coalesce — the
    // subscriber always sees the latest state, never an intermediate one.  The
    // synchronous `state` getter is the authoritative current value; stateStream
    // is for push-notification only.  Subscribers should read `tracker.state` once
    // on attach and then listen to the stream for deltas.
    public let stateStream: AsyncStream<TrackerState>
    // effectStream uses bufferingNewest(8): effects (sounds, icon changes) are
    // best-effort.  If the app is too slow to drain them, older ones are dropped
    // rather than growing the buffer without bound.
    // TODO (PR#1, Phase 5): revisit if effects must be lossless (e.g. audit log).
    public let effectStream: AsyncStream<Effect>
    // nonisolated(unsafe): deinit is always nonisolated (SE-0371 / Swift 5.10).
    // Accessing @MainActor-isolated stored properties from deinit is a compile
    // error, so we mark the three properties needed for cleanup as
    // nonisolated(unsafe).  This is safe: deinit only runs after all strong
    // references are released, so there is no concurrent actor access.
    nonisolated(unsafe) private let stateContinuation: AsyncStream<TrackerState>.Continuation
    nonisolated(unsafe) private let effectContinuation: AsyncStream<Effect>.Continuation

    private let store: Store
    private var iterator: CycleIterator?
    private var profile: Profile? { profiles.first(where: { $0.name == profileName }) }
    nonisolated(unsafe) private var tickTimer: Timer?
    private var idleMonitor: IdleMonitor

    // idleSource defaults to FakeIdleSource (always-zero) so all existing tests
    // compile and pass unchanged. Pass SystemIdleSource() from the app target
    // to enable real macOS idle detection.
    public init(store: Store, profilesURL: URL, idleSource: IdleSource = FakeIdleSource()) throws {
        // Wire the streams BEFORE any state mutation (didSet must have a live
        // continuation to yield to).
        var stateCont: AsyncStream<TrackerState>.Continuation!
        self.stateStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { stateCont = $0 }
        self.stateContinuation = stateCont

        var effectCont: AsyncStream<Effect>.Continuation!
        self.effectStream = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { effectCont = $0 }
        self.effectContinuation = effectCont

        self.store = store
        self.idleMonitor = IdleMonitor(source: idleSource)
        self.profiles = try ProfileLoader.loadAll(from: profilesURL)
        self.tasks = try store.tasks()
        startTickLoop()
    }

    deinit {
        tickTimer?.invalidate()
        stateContinuation.finish()
        effectContinuation.finish()
    }

    // 1Hz tick: checks for phase expiry, refreshes today's totals.
    private func startTickLoop() {
        // TODO (PR#1, Phase 5): Timer.scheduledTimer requires an active RunLoop and
        // MainActor.assumeIsolated will precondition-fail if the RunLoop fires on a
        // non-main thread (possible on Linux where Foundation's RunLoop is
        // Dispatch-backed but not necessarily the main-actor executor).
        // Fix: replace with a Task { while !Task.isCancelled { try await clock.sleep(for: .seconds(1)); tick(at: Date()) } }.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(at: Date()) }
        }
    }

    // Test seam, mirroring tick(at:)'s test-only visibility: stops the 1 Hz Timer
    // so a test can drive tick(at:) on a fully synthetic clock. Without this, a
    // test that suspends (awaiting effectStream) lets the RunLoop fire real ticks
    // stamped Date(), interleaving them with the synthetic ones and making
    // exact-count assertions about escalation flaky.
    func disableTickLoopForTesting() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // Drives one tick.  Production path: called by the 1Hz Timer with Date().
    // Test path: call tick(at:) with a synthetic date to exercise phase expiry
    // without waiting for wall-clock time (the Timer never fires in tests).
    func tick(at now: Date = Date()) {
        // Phase-expiry check (always runs regardless of idle state).
        if case let .tracking(taskId, phase, deadline) = state, now >= deadline {
            armPhase(taskId: taskId, phase: phase, at: now)
        }

        // Idle detection. Only meaningful when a task is active; idleMonitor
        // is a no-op when idleSource always returns 0 (FakeIdleSource default).
        if let prof = profile {
            let taskId = currentTaskId()
            let phaseId: String
            let isBreakPhase: Bool
            let armBoundary: Date?
            let phaseArmedAt: Date?   // non-nil only while .armed; drives flowArm

            switch state {
            case .idle:
                phaseId = ""
                isBreakPhase = false
                armBoundary = nil
                phaseArmedAt = nil
            case let .tracking(_, phase, deadline):
                phaseId = phase.id
                isBreakPhase = phase.accrueAs == "break"
                armBoundary = deadline
                phaseArmedAt = nil
            case let .armed(_, phase, _, armedAt):
                phaseId = phase.id
                isBreakPhase = phase.accrueAs == "break"
                // armedAt IS the freeze boundary — the instant the cycle stopped
                // at the unacked arm. Whether it SPLITS the episode depends on
                // whether it falls inside [idleStart, return], and that is
                // buildSegments' decision, not ours. Passing nil here (the old
                // behaviour) asserted "the whole episode is overrun", which is
                // only true when the phase was already armed before idle began —
                // and it silently broke the strict in-window break rule for an
                // episode that armed mid-way, prompting the user to classify
                // break time DESIGN.md says must auto-resolve.
                armBoundary = armedAt
                phaseArmedAt = armedAt
            }

            // Detect the -1 "no break row" sentinel explicitly: if breakTaskId()
            // throws (DB error) OR returns -1 (no break row), use -1 as breakId.
            // Passing -1 to IdleMonitor is safe: it is not a valid tasks.id FK,
            // so auto-resolved break-inPhase segments won't reference a real row.
            // Using 0 (old fallback) was wrong because 0 could hypothetically be
            // a valid rowid on a non-standard SQLite build, and is inconsistent
            // with breakTaskId()'s own nil-row sentinel. If the break row is truly
            // absent, idle segment creation is degraded but not FK-corrupt.
            let rawBreakId = (try? store.breakTaskId()) ?? -1
            let breakId: Int64 = (rawBreakId == -1) ? -1 : rawBreakId
            let signal = idleMonitor.tick(
                now: now,
                profile: prof,
                currentTaskId: taskId,
                currentPhaseId: phaseId,
                isBreakPhase: isBreakPhase,
                armBoundary: armBoundary,
                breakTaskId: breakId,
                phaseArmedAt: phaseArmedAt)

            switch signal {
            case .none:
                break
            case let .idleDetected(start):
                // Phase clock freezes; no state transition needed — the segment
                // model tracks idle separately. Mark the episode's opening in the
                // log so the gap is visible even if the app dies before the user
                // classifies it.
                //
                // ts is IDLE-START (now − idleSeconds), not detection time — the
                // locked invariant. Store.append only auto-stamps when ts == 0, so
                // a real timestamp is honoured verbatim. Back-dating is safe:
                // idle_gap is a timeline no-op in Store.nextActiveTask, so it can
                // never reorder the accrual walk.
                //
                // try? (unlike the do/catch on idle_resolve below) is deliberate:
                // idle_gap is purely informational, so losing one to a transient
                // write failure cannot corrupt a report — the episode is still
                // tracked in memory and its segments will still be classified.
                // Losing an idle_resolve would lose the correction itself, which
                // is why that path refuses to mark the segment resolved.
                if let taskId {
                    try? store.append(Event(
                        id: nil,
                        ts: Int64(start.timeIntervalSince1970 * 1000),
                        type: EventType.idleGap.rawValue,
                        taskId: taskId, prevTaskId: nil,
                        phaseId: phaseId.isEmpty ? nil : phaseId,
                        profileName: profileName,
                        extendMin: nil, comment: nil))
                }
            case .returned:
                // Segments now legitimately persist UNRESOLVED until the user
                // classifies them (resolveIdleSegment). Nothing is auto-credited:
                // silently keeping idle time on the task that happened to be active
                // is exactly the bug this path used to have.
                //
                // Escalation gating on `fullyResolved` is therefore honest — the
                // ramp nags precisely while a real decision is outstanding, and it
                // is presence-gated + rung-shaped, so an unresolved segment produces
                // a bounded ladder of cues, not one per tick.
                break
            case let .escalate(rung):
                // Surface the escalation effect so the app can play a sound.
                // rung.sound is optional (rungs may be notification-only).
                if let soundName = rung.sound {
                    effectContinuation.yield(.playSound(soundName))
                }
                // Ramp the menu-bar icon colour. For flowArm this is the visible
                // half of its icon+sound cap; for idleReturn it tracks the ramp's
                // severity. IdleMonitor already stripped notify on flowArm rungs,
                // so the notify branch below can never fire for flowArm.
                effectContinuation.yield(.setIconColor(rung.color))
                // Per DESIGN.md: escalation ceiling is a persistent notification,
                // never a focus-steal modal. Emit .postNotification when the rung
                // requests it. The app posts via UNUserNotificationCenter; same
                // notification id replaces the previous one, so it's persistent
                // without stacking.
                if rung.notify {
                    effectContinuation.yield(.postNotification(
                        title: "TimeTrack: Idle time unclassified",
                        body: "Return to TimeTrack to classify your idle time."))
                }
            }
        }

        refreshPendingIdleSegments()
        refreshToday()
    }

    // Single write site for pendingIdleSegments. The episodes are the source of
    // truth; this only mirrors them so the app never reaches into IdleMonitor.
    private func refreshPendingIdleSegments() {
        pendingIdleSegments = idleMonitor.pendingSegments
    }

    // Classify one pending idle segment.
    //
    // There is deliberately no fallback: an id that is unknown, already resolved,
    // or belonged to an episode stop() discarded before it returned is a NO-OP.
    // That guard is what stops a resolve racing a stop() from resurrecting a dead
    // episode and writing an idle_resolve with the wrong task/phase/interval.
    public func resolveIdleSegment(_ id: UUID, as resolution: IdleResolution) {
        guard let seg = idleMonitor.pendingSegments.first(where: { $0.id == id })
        else { return }

        // Exhaustive — a new IdleResolution case must be handled here, not
        // silently defaulted into some other classification.
        let target: Int64?
        switch resolution {
        case .keepOnOriginal:
            // Writes a resolve that nets to zero in the report. That is the point:
            // "I checked, it really was this task" is a decision worth recording
            // in the append-only log, and it clears the escalation.
            target = seg.originalTaskId
        case .toBreak:
            // No break row ⇒ no-op rather than an idle_resolve carrying the -1
            // sentinel, which would violate the events.taskId foreign key (the
            // throw would be swallowed and the segment silently lost). The app
            // gates the choice on canClassifyAsBreak; this is the kit's backstop.
            guard let breakId = breakTaskIdOrNil else { return }
            target = breakId
        case let .moveTo(taskId):
            target = taskId
        case .discard:
            target = nil
        }

        // Append FIRST, and only mark the segment resolved if the write actually
        // landed. If persistence fails the segment must stay pending so escalation
        // keeps nagging — marking it resolved on a failed write would silently lose
        // the user's correction and leave the time miscredited forever.
        do {
            _ = try store.append(Event(
                id: nil, ts: 0, type: EventType.idleResolve.rawValue,
                // taskId = the chosen target (nil = discard); prevTaskId = the task
                // the base timeline walk attributed this interval to. Store.report's
                // second pass subtracts from prevTaskId and adds to taskId.
                taskId: target, prevTaskId: seg.originalTaskId,
                phaseId: seg.phaseId, profileName: profileName,
                extendMin: nil, comment: nil,
                rangeStart: Int64(seg.start.timeIntervalSince1970 * 1000),
                rangeEnd: Int64(seg.end.timeIntervalSince1970 * 1000)))
        } catch {
            return
        }

        idleMonitor.resolveSegment(id)
        refreshPendingIdleSegments()
    }

    private func refreshToday() {
        if let rows = try? store.report(day: Date()) {
            var map: [Int64: Int] = [:]
            for r in rows { if let id = r.task.id { map[id] = r.totalSeconds } }
            todaySeconds = map
        }
    }

    // MARK: - Transitions

    public func start(taskId: Int64) {
        guard let prof = profile else { return }
        // Stop any existing tracking first (logs stop, resets cycle).
        if case .idle = state {} else { stop() }

        if iterator == nil { iterator = CycleIterator(profile: prof) }
        iterator?.reset()
        let phase = iterator!.currentPhase
        let deadline = Date().addingTimeInterval(Double(phase.durationMin * 60))

        try? store.append(Event(
            id: nil, ts: 0, type: EventType.start.rawValue,
            taskId: taskId, prevTaskId: nil,
            phaseId: phase.id, profileName: prof.name,
            extendMin: nil, comment: nil))

        phaseStartedAt = Date()
        state = .tracking(taskId: taskId, phase: phase, deadline: deadline)
        activeTask = tasks.first(where: { $0.id == taskId })
    }

    public func switchTo(taskId: Int64, comment: String? = nil) {
        switch state {
        case .idle:
            start(taskId: taskId)
        case let .tracking(prev, phase, deadline):
            try? store.append(Event(
                id: nil, ts: 0, type: EventType.switch.rawValue,
                taskId: taskId, prevTaskId: prev,
                phaseId: phase.id, profileName: profileName,
                extendMin: nil, comment: comment))
            state = .tracking(taskId: taskId, phase: phase, deadline: deadline)
            activeTask = tasks.first(where: { $0.id == taskId })
        case .armed:
            // Switch during ARMED = implicit ack, advance phase, then switch.
            advance()
            // After advance() state is .tracking on next phase's accrual target.
            // Use that target as prevTaskId so the switch event's FK is valid
            // (advance picks breakTaskId for break phases, the carried work task
            // otherwise). A -1 sentinel would violate the events.prevTaskId FK
            // and the throw would be swallowed by try?.
            if case let .tracking(prev, phase, deadline) = state {
                try? store.append(Event(
                    id: nil, ts: 0, type: EventType.switch.rawValue,
                    taskId: taskId, prevTaskId: prev,
                    phaseId: phase.id, profileName: profileName,
                    extendMin: nil, comment: comment))
                state = .tracking(taskId: taskId, phase: phase, deadline: deadline)
                activeTask = tasks.first(where: { $0.id == taskId })
            }
        }
    }

    public func stop() {
        if case .idle = state { return }
        try? store.append(Event(
            id: nil, ts: 0, type: EventType.stop.rawValue,
            taskId: nil, prevTaskId: currentTaskId(),
            phaseId: nil, profileName: profileName,
            extendMin: nil, comment: nil))
        // Discard only the still-OPEN idle episode: it has no return time, so its
        // extent is unknown and it is definitionally unclassifiable once the
        // session ends. Episodes the user has already returned from survive the
        // stop with their unresolved segments intact — their ranges and original
        // task are fully determined, so dropping them would silently bill that
        // idle time to the original task and make Stop an escape hatch from the
        // escalation ramp.
        idleMonitor.discardOpenEpisode()
        refreshPendingIdleSegments()
        iterator?.reset()
        state = .idle
        activeTask = nil
    }

    // Called from tick() when timer expires. Logs phase_arm, emits the sound
    // effect for the app to play, accrual continues against current task.
    //
    // `now` is the TICK's clock, not Date(). armedAt is no longer just flowArm
    // ramp bookkeeping — it is the freeze boundary IdleMonitor splits an idle
    // episode on, so it must agree with the clock the rest of the tick uses.
    // (In production they are the same value; the tick is called with Date().)
    private func armPhase(taskId: Int64, phase: Phase, at now: Date) {
        guard let iter = iterator else { return }
        // peekNext() is exactly what advance() transitions into from here: both
        // resolve through the same phasesForCurrentCycle()/wrap logic, so this is
        // the long-cycle override phase (e.g. long_break) or the wrap-back-to-work
        // when applicable. Record it on the arm event so the stateless CLI can read
        // the next phase without reconstructing the iterator's cycle-number state.
        let nextPhase = iter.peekNext()

        try? store.append(Event(
            id: nil, ts: 0, type: EventType.phaseArm.rawValue,
            taskId: taskId, prevTaskId: nil,
            phaseId: phase.id, profileName: profileName,
            extendMin: nil, comment: nil,
            nextPhaseId: nextPhase.id))

        effectContinuation.yield(.playSound(phase.onArm.sound))
        state = .armed(taskId: taskId, phase: phase, nextPhase: nextPhase, armedAt: now)
    }

    public func advance(comment: String? = nil) {
        guard case let .armed(taskId, armedPhase, _, _) = state,
              let iter = iterator else { return }

        _ = iter.advance()
        let newPhase = iter.currentPhase
        let deadline = Date().addingTimeInterval(Double(newPhase.durationMin * 60))

        // The resume question only exists when LEAVING a break phase: the carried
        // task is often the synthetic break task, and carrying it into a work
        // phase would silently drop time. Guard here so ordinary work→work
        // advances never pay for the event-log walk.
        let prev: Int64? = (armedPhase.accrueAs == "break")
            ? (try? store.previousWorkTaskId(leavingBreak: armedPhase, asOf: Date()))
            : nil

        // Determine the task that accrues during the next phase via the SHARED
        // kit helper, so this can never diverge from Store.switchFromArmed (the
        // stateless CLI path). The helper's break branch reads breakTaskId() (it
        // throws); preserve advance()'s historic try?-with-fallback-to-taskId so
        // a read failure degrades to the carried task, never a crash.
        let nextTaskId: Int64 = (try? store.accrualTaskId(
            forNextPhase: newPhase,
            carriedTaskId: taskId,
            previousWorkTaskId: prev)) ?? taskId

        try? store.append(Event(
            id: nil, ts: 0, type: EventType.phaseAdvance.rawValue,
            taskId: nextTaskId, prevTaskId: taskId,
            phaseId: newPhase.id, profileName: profileName,
            extendMin: nil, comment: comment))

        phaseStartedAt = Date()
        state = .tracking(taskId: nextTaskId, phase: newPhase, deadline: deadline)
        activeTask = tasks.first(where: { $0.id == nextTaskId })
    }

    // The phases of the current effective cycle, i.e. the valid manual-skip
    // targets (#25). Empty while idle. The app builds its "Skip to ▸" menu from
    // this; the CycleIterator stays private to the kit.
    public var jumpTargets: [Phase] {
        if case .idle = state { return [] }
        return iterator?.jumpTargetPhases ?? []
    }

    // Manual phase skip (#25): end the current phase early and jump to a specific
    // phase — any phase in the current effective cycle, or an override-only phase
    // forced early (e.g. long_break before its Nth cycle; the iterator then resets
    // the long-cycle counter so the early break counts). Allowed from .tracking
    // AND .armed; a no-op while idle, for a target in neither the cycle nor the
    // override, or for the phase already running (see guard below). Append-only:
    // logs a phase_skip carrying the target phase id. Mirrors advance() for
    // accrual (shared accrualTaskId + break-resume) so a manual jump can never
    // diverge from a natural advance.
    public func jumpToPhase(_ phaseId: String, comment: String? = nil) {
        let currentTaskId: Int64
        let leavingPhase: Phase
        switch state {
        case .idle:
            return
        case let .tracking(tid, phase, _):
            currentTaskId = tid; leavingPhase = phase
        case let .armed(tid, phase, _, _):
            currentTaskId = tid; leavingPhase = phase
        }
        // Jumping to the phase we're already in is a no-op, not a restart. The UI
        // filters the current phase out of its menu, but the kit must not rely on
        // that: a stale caller would otherwise reset the deadline and pollute the
        // append-only log with a do-nothing phase_skip. "Restart current phase"
        // is a distinct feature if ever wanted — not this API's job.
        if leavingPhase.id == phaseId { return }
        guard let iter = iterator else { return }

        // Validate + move the iterator. An out-of-cycle target throws → no-op,
        // leaving state untouched (the UI only ever offers valid targets).
        guard let newPhase = try? iter.jumpTo(phaseId: phaseId) else { return }

        let deadline = Date().addingTimeInterval(Double(newPhase.durationMin * 60))

        // Resume target exists only when LEAVING a break: the carried task is
        // often the synthetic break task, and carrying it into a work phase would
        // silently drop time. Same guard as advance().
        let prev: Int64? = (leavingPhase.accrueAs == "break")
            ? (try? store.previousWorkTaskId(leavingBreak: leavingPhase, asOf: Date()))
            : nil

        let nextTaskId: Int64 = (try? store.accrualTaskId(
            forNextPhase: newPhase,
            carriedTaskId: currentTaskId,
            previousWorkTaskId: prev)) ?? currentTaskId

        try? store.append(Event(
            id: nil, ts: 0, type: EventType.phaseSkip.rawValue,
            taskId: nextTaskId, prevTaskId: currentTaskId,
            phaseId: newPhase.id, profileName: profileName,
            extendMin: nil, comment: comment))

        phaseStartedAt = Date()
        state = .tracking(taskId: nextTaskId, phase: newPhase, deadline: deadline)
        activeTask = tasks.first(where: { $0.id == nextTaskId })
    }

    public func extend(minutes: Int, comment: String? = nil) {
        guard case let .armed(taskId, phase, _, _) = state else { return }
        let deadline = Date().addingTimeInterval(Double(minutes * 60))

        try? store.append(Event(
            id: nil, ts: 0, type: EventType.phaseExtend.rawValue,
            taskId: taskId, prevTaskId: nil,
            phaseId: phase.id, profileName: profileName,
            extendMin: minutes, comment: comment))

        // Return to tracking with new deadline; the re-armed phase will
        // recompute nextPhase when it next arms.
        // Reset phaseStartedAt so elapsed starts from zero — the user just
        // granted a fresh N-minute extension from now, not from the original
        // phase start. Without this, AppState.updatePublished would compute
        // phaseStart = deadline - durationMin = (now + extendMin) - durationMin,
        // which is in the past by (durationMin - extendMin) minutes, causing an
        // instant large elapsedSeconds jump on the timer display.
        phaseStartedAt = Date()
        state = .tracking(taskId: taskId, phase: phase, deadline: deadline)
    }

    public func setProfile(_ name: String) {
        guard profiles.contains(where: { $0.name == name }), name != profileName else { return }
        try? store.append(Event(
            id: nil, ts: 0, type: EventType.profileChange.rawValue,
            taskId: nil, prevTaskId: nil,
            phaseId: nil, profileName: name,
            extendMin: nil, comment: nil))
        profileName = name
        // Mid-cycle profile change resets the iterator. Could be smarter
        // (carry the elapsed time forward), but reset is more predictable.
        if let p = profile { iterator = CycleIterator(profile: p); iterator?.reset() }
        // If we're tracking, restart the current phase on the new profile.
        if case let .tracking(taskId, _, _) = state {
            stop()
            start(taskId: taskId)
        }
    }

    public func logInterruption(comment: String) {
        try? store.append(Event(
            id: nil, ts: 0, type: EventType.interruption.rawValue,
            taskId: currentTaskId(), prevTaskId: nil,
            phaseId: nil, profileName: profileName,
            extendMin: nil, comment: comment))
    }

    @discardableResult
    public func addTask(name: String, code: String?, category: String = "project") throws -> Task {
        let t = Task(id: nil, name: name, code: code, category: category, archived: false)
        let inserted = try store.upsertTask(t)
        self.tasks = try store.tasks()
        return inserted
    }

    // MARK: - Helpers

    private func currentTaskId() -> Int64? {
        switch state {
        case .idle: return nil
        case let .tracking(id, _, _): return id
        case let .armed(id, _, _, _): return id
        }
    }

}
