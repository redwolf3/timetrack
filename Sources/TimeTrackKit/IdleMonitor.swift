import Foundation

// One classifiable segment of an idle episode.
//   .inPhase  = [idleStart, armBoundary] — idle within the phase you were in
//   .overrun  = [armBoundary, return]    — past the unacked boundary
// If the phase was already armed when idle began, inPhase collapses (zero-length)
// and the whole episode is a single overrun segment.
public struct IdleSegment: Identifiable, Equatable {
    public enum Kind: Equatable { case inPhase, overrun }
    public let id = UUID()
    public let kind: Kind
    public let start: Date
    public let end: Date
    public let originalTaskId: Int64       // what was accruing during this segment
    public let phaseId: String
    public let wasBreakPhase: Bool         // strict in-window rule: break inPhase auto-resolves
    public var resolved: Bool = false

    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

// The four classifications DESIGN.md gives an idle segment. Modelled as an enum
// rather than an `Int64?` target because "nil means discard" is a rule that has
// to be re-explained everywhere it travels, and because the four choices are a
// closed set the compiler should enforce at every switch.
//
// Resolving keep/break to a concrete task id is the KIT's job (Tracker), not the
// caller's: the app must not have to know which task the segment came from or
// which row is the synthetic break task.
public enum IdleResolution: Equatable {
    case keepOnOriginal        // leave the time on the task that was accruing
    case toBreak               // reattribute to the synthetic break task
    case moveTo(taskId: Int64) // reattribute to some other task
    case discard               // remove from the original, credit nobody
}

// Tracks a single idle episode from detection through full resolution.
public final class IdleEpisode {
    public let idleStart: Date
    public var returnTime: Date?
    public var segments: [IdleSegment] = []

    // Presence-gated escalation bookkeeping. activeSecondsSinceReturn only
    // accumulates while input is actually detected — pauses if user leaves again.
    public var activeSecondsSinceReturn: TimeInterval = 0
    public var lastRungFired: Int = -1
    public var lastNotifyAt: Date?

    public init(idleStart: Date) { self.idleStart = idleStart }

    public var unresolvedSegments: [IdleSegment] { segments.filter { !$0.resolved } }
    public var fullyResolved: Bool { segments.allSatisfy { $0.resolved } }
}

// Owns idle detection and escalation timing. Called from Tracker's 1Hz tick.
// Tracker provides current state; IdleMonitor decides when to open an episode,
// how to segment it on return, and which escalation rung to fire.
@MainActor
public final class IdleMonitor {
    private let source: IdleSource
    public init(source: IdleSource) { self.source = source }

    // Every episode that still matters, oldest first. An episode leaves this list
    // only when all of its segments are resolved (or when a still-open one is
    // discarded by stop()).
    //
    // Why a LIST and not a single episode: an unresolved episode legitimately
    // stays outstanding for as long as the user ignores the prompt — possibly
    // hours. With a single slot, the next idle window (lunch, a meeting) would
    // find the slot occupied and be silently swallowed, accruing to whatever task
    // was active. That is the very misattribution #61 exists to stop.
    //
    // INVARIANT: at most ONE episode is live (returnTime == nil), and it is always
    // the last one — a new episode only opens when none is live, and episodes are
    // appended in time order. So episodes never overlap in time, which is what
    // makes cross-episode segment disjointness automatic (the two-segments-max
    // rule stays a per-episode property).
    public private(set) var episodes: [IdleEpisode] = []
    private var wasIdle = false
    private var lastTickActive = true

    // The episode currently in progress (user still away), if any.
    private var liveEpisode: IdleEpisode? {
        guard let last = episodes.last, last.returnTime == nil else { return nil }
        return last
    }

    // Every segment still awaiting a user decision, in time order.
    public var pendingSegments: [IdleSegment] {
        episodes.flatMap { $0.unresolvedSegments }
    }

    // Episodes the user has returned from that still owe a decision, oldest first.
    // The oldest owns escalation: it has been nagging longest.
    private var outstandingEpisodes: [IdleEpisode] {
        episodes.filter { $0.returnTime != nil && !$0.fullyResolved }
    }

    // flowArm bookkeeping (issue #24). The "true flow" case: a phase has ARMED
    // but the user never went idle, so there is no IdleEpisode. We ramp the
    // flowArm curve presence-gated, identical gate to idleReturn. Identity of the
    // current arm is its armedAt timestamp: a new arm (different timestamp) resets
    // the ramp. nil = not armed.
    private var flowArmedAt: Date?
    private var flowActiveSeconds: TimeInterval = 0
    private var flowLastRung: Int = -1

    // Returns an action for the Tracker to execute, if any.
    public enum Signal: Equatable {
        case none
        case idleDetected(start: Date)         // crossed threshold; freeze phase
        case returned(segments: [IdleSegment]) // build prompt for these
        case escalate(rung: EscalationRung)    // fire this rung
    }

    // phaseArmedAt: when the current phase armed (nil if still running).
    // armBoundary: when the current phase WILL arm (the freeze point) — nil if
    //   already armed (then whole idle is overrun).
    public func tick(now: Date,
                     profile: Profile,
                     currentTaskId: Int64?,
                     currentPhaseId: String,
                     isBreakPhase: Bool,
                     armBoundary: Date?,
                     breakTaskId: Int64,
                     phaseArmedAt: Date? = nil) -> Signal {

        let idleSec = source.idleSeconds()
        let threshold = Double((profile.idleThresholdMin ?? 5) * 60)
        let wiggle = Double((profile.wiggleRoomMin ?? 5) * 60)
        let effectiveThreshold = max(threshold, wiggle)
        let nowIdle = idleSec >= effectiveThreshold

        // --- Episode open ---
        // Gated on "no LIVE episode", not "no episodes at all": earlier episodes
        // awaiting classification must not block detection of a new idle window.
        if nowIdle, liveEpisode == nil, currentTaskId != nil {
            // Idle began at now - idleSec, not now.
            let start = now.addingTimeInterval(-idleSec)
            episodes.append(IdleEpisode(idleStart: start))
            wasIdle = true
            return .idleDetected(start: start)
        }

        // --- Still idle, no episode change ---
        if nowIdle { return .none }

        // --- Return detected (was idle, now active) ---
        if wasIdle, let ep = liveEpisode,
           let taskId = currentTaskId {
            ep.returnTime = now
            ep.segments = buildSegments(
                episode: ep, now: now,
                armBoundary: armBoundary,
                taskId: taskId,
                phaseId: currentPhaseId,
                isBreakPhase: isBreakPhase,
                breakTaskId: breakTaskId)
            wasIdle = false
            let unresolved = ep.unresolvedSegments
            // Drop the episode when nothing needs a user decision (the only case
            // today: a single break-phase inPhase segment, auto-resolved at build
            // time). resolveSegment() is what normally retires a finished episode,
            // but nobody will ever call it for a segment that was never pending —
            // so without this the episode would leak forever and permanently
            // suppress the flowArm ramp.
            // Emits NO idle_resolve: the base timeline walk already attributed the
            // interval to the break task, so there is nothing to correct.
            if ep.fullyResolved { episodes.removeAll { $0 === ep } }
            return .returned(segments: unresolved)
        }

        // --- Escalation while present with unresolved segments ---
        let outstanding = outstandingEpisodes
        if let ep = outstanding.first {
            // Presence gate: only accumulate active time when input is recent.
            let recentlyActive = idleSec < 5
            // EVERY outstanding episode accrues presence time, not just the one
            // currently escalating. When the oldest is finally resolved the next
            // takes over with the time it has already spent waiting, rather than
            // restarting the ramp from zero and giving the user a free reprieve
            // for each additional unclassified gap.
            if recentlyActive {
                for e in outstanding { e.activeSecondsSinceReturn += 1 }
            }

            let curve = (profile.escalation ?? .default).idleReturn
            // Find highest rung whose threshold we've crossed.
            var targetRung = -1
            for (i, rung) in curve.enumerated() where
                ep.activeSecondsSinceReturn >= Double(rung.afterActiveSec) {
                targetRung = i
            }
            if targetRung > ep.lastRungFired {
                ep.lastRungFired = targetRung
                // Stamp the cue time here too. Without it the ceiling rung
                // double-fires: this branch returns with lastNotifyAt still nil,
                // and one tick later the cadence branch below reads nil as "never
                // notified" and re-fires the same rung a second after the first.
                // The cadence must count from the last cue actually delivered.
                ep.lastNotifyAt = now
                return .escalate(rung: curve[targetRung])
            }
            // Ceiling: repeat notification on cadence.
            if targetRung >= 0, let cadence = curve[targetRung].repeatNotifySec {
                let due = ep.lastNotifyAt.map {
                    now.timeIntervalSince($0) >= Double(cadence)
                } ?? true
                if due && recentlyActive {
                    ep.lastNotifyAt = now
                    return .escalate(rung: curve[targetRung])
                }
            }
        }

        // --- flowArm: presence-gated ramp while ARMED and never-idle (#24) ---
        // Reached only when !nowIdle (the idle branches above return early). Runs
        // only while a phase is armed (phaseArmedAt != nil) AND no idle episode is
        // live — if the user went idle while armed, idleReturn owns escalation and
        // flowArm pauses (its counter simply doesn't advance) until resolution.
        guard let armedAt = phaseArmedAt else {
            // Not armed → drop the ramp entirely. Resetting the counter and rung
            // here (not just the identity) is defensive: the nil→non-nil check
            // below already forces a restart on the next arm, but clearing all
            // three keeps the "no ramp state outside an arm" invariant local
            // instead of depending on that comparison.
            flowArmedAt = nil
            flowActiveSeconds = 0
            flowLastRung = -1
            return .none
        }
        // Any live-or-unresolved episode means idleReturn owns escalation; pause.
        if !episodes.isEmpty { return .none }

        // New arm? Restart the ramp. The armedAt timestamp is the arm's identity.
        if flowArmedAt != armedAt {
            flowArmedAt = armedAt
            flowActiveSeconds = 0
            flowLastRung = -1
        }

        // Same presence gate as idleReturn: accumulate only on recent activity.
        let recentlyActive = idleSec < 5
        if recentlyActive { flowActiveSeconds += 1 }

        // Ramp over flowArm rungs with afterActiveSec > 0 only. Rung-0
        // (afterActiveSec: 0) is subsumed by Tracker's onArm.sound arm cue, so
        // firing it here would double the sound at arm — skip it.
        let flowCurve = (profile.escalation ?? .default).flowArm
        var flowTarget = -1
        for (i, rung) in flowCurve.enumerated() where
            rung.afterActiveSec > 0 && flowActiveSeconds >= Double(rung.afterActiveSec) {
            flowTarget = i
        }
        if flowTarget > flowLastRung {
            flowLastRung = flowTarget
            // Cap at icon + sound: flowArm NEVER notifies (DESIGN.md Escalation).
            // Strip notify/repeat structurally so the generic Tracker handler can
            // never post a notification for a flowArm rung.
            let r = flowCurve[flowTarget]
            return .escalate(rung: EscalationRung(
                afterActiveSec: r.afterActiveSec, sound: r.sound,
                color: r.color, notify: false, repeatNotifySec: nil))
        }

        return .none
    }

    // Discard the STILL-OPEN episode (if any) and reset idle state. Called from
    // Tracker.stop().
    //
    // Only the open one: it has no returnTime, so its end — and therefore its
    // segments — are unknown, making it definitionally unclassifiable once the
    // session ends. Episodes the user has already returned from keep their
    // unresolved segments and stay resolvable after stop: their ranges and
    // originalTaskId are fully determined, so silently dropping them would bill
    // that idle time to the original task, and would make Stop an escape hatch
    // from the escalation ramp.
    public func discardOpenEpisode() {
        episodes.removeAll { $0.returnTime == nil }
        wasIdle = false
    }

    public func resolveSegment(_ id: UUID) {
        for ep in episodes {
            if let idx = ep.segments.firstIndex(where: { $0.id == id }) {
                ep.segments[idx].resolved = true
                break
            }
        }
        // Retire finished episodes so escalation stops and the flowArm ramp can
        // resume. Guarded on returnTime: a LIVE episode has no segments yet, and
        // allSatisfy over an empty list is vacuously true — without the guard we
        // would delete the episode currently in progress.
        episodes.removeAll { $0.returnTime != nil && $0.fullyResolved }
    }

    // Two-segment split per locked design.
    //
    // INVARIANT: this emits AT MOST TWO segments, and they are disjoint and
    // contiguous — [idleStart, boundary] then [boundary, now], sharing the single
    // boundary instant. This is not cosmetic. Each unresolved segment becomes one
    // idle_resolve carrying its [rangeStart, rangeEnd], and Store.sliceTimeline
    // step 4 (Store.swift:975-1000) reattributes by testing each timeline
    // segment's MIDPOINT against those ranges, first match wins. Overlapping
    // ranges would therefore double-attribute (or silently drop) time depending
    // on row order. The two append paths below are what structurally guarantees
    // it: one branch appends exactly two segments meeting at `b`, the other
    // exactly one covering the whole episode. Keep it that way — finer
    // sub-segmentation (#32) must preserve disjointness.
    private func buildSegments(episode ep: IdleEpisode,
                               now: Date,
                               armBoundary: Date?,
                               taskId: Int64,
                               phaseId: String,
                               isBreakPhase: Bool,
                               breakTaskId: Int64) -> [IdleSegment] {
        var segs: [IdleSegment] = []

        // armBoundary is the freeze boundary if the caller knows one: the deadline
        // while .tracking, or armedAt while .armed. nil means "no boundary known",
        // which the collapse branch below treats as already-armed.
        if let b = armBoundary, b > ep.idleStart, b < now {
            // inPhase: [idleStart, boundary]
            var s1 = IdleSegment(
                kind: .inPhase, start: ep.idleStart, end: b,
                originalTaskId: isBreakPhase ? breakTaskId : taskId,
                phaseId: phaseId, wasBreakPhase: isBreakPhase)
            // Strict in-window rule: break-phase inPhase auto-resolves to break.
            // It emits NO idle_resolve event — the base walk already attributed it
            // to the break task (accrueAs == break), so there is nothing to correct.
            // We mark it resolved only to clear it from the prompt/escalation queue.
            if isBreakPhase { s1.resolved = true }
            segs.append(s1)

            // overrun: [boundary, now]
            segs.append(IdleSegment(
                kind: .overrun, start: b, end: now,
                originalTaskId: taskId,   // overrun's "was working?" target
                phaseId: phaseId, wasBreakPhase: isBreakPhase))
        } else {
            // The boundary is outside the episode, so it cannot split it — one
            // segment covering the whole idle. Which kind depends on WHICH side
            // it fell on:
            //   boundary == nil          → no boundary known → overrun
            //   boundary <= idleStart    → already armed before idle began; the
            //                              user was past the boundary the whole
            //                              time → overrun
            //   boundary >= now          → returned before the phase ever armed;
            //                              the idle sat entirely inside the phase
            //                              → inPhase (and auto-resolves on break)
            // Getting the middle case wrong is not cosmetic: labelling it
            // .inPhase would let the break auto-resolve swallow overrun time that
            // the user must actually classify.
            let kind: IdleSegment.Kind =
                (armBoundary.map { $0 <= ep.idleStart } ?? true) ? .overrun : .inPhase
            var s = IdleSegment(
                kind: kind, start: ep.idleStart, end: now,
                originalTaskId: isBreakPhase ? breakTaskId : taskId,
                phaseId: phaseId, wasBreakPhase: isBreakPhase)
            if isBreakPhase && kind == .inPhase { s.resolved = true }
            segs.append(s)
        }
        return segs
    }
}
