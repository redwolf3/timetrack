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

    public private(set) var episode: IdleEpisode?
    private var wasIdle = false
    private var lastTickActive = true

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
                     breakTaskId: Int64) -> Signal {

        let idleSec = source.idleSeconds()
        let threshold = Double((profile.idleThresholdMin ?? 5) * 60)
        let wiggle = Double((profile.wiggleRoomMin ?? 5) * 60)
        let effectiveThreshold = max(threshold, wiggle)
        let nowIdle = idleSec >= effectiveThreshold

        // --- Episode open ---
        if nowIdle && episode == nil, let taskId = currentTaskId {
            // Idle began at now - idleSec, not now.
            let start = now.addingTimeInterval(-idleSec)
            episode = IdleEpisode(idleStart: start)
            wasIdle = true
            return .idleDetected(start: start)
        }

        // --- Still idle, no episode change ---
        if nowIdle { return .none }

        // --- Return detected (was idle, now active) ---
        if wasIdle, let ep = episode, ep.returnTime == nil,
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
            return .returned(segments: ep.unresolvedSegments)
        }

        // --- Escalation while present with unresolved segments ---
        if let ep = episode, !ep.fullyResolved, ep.returnTime != nil {
            // Presence gate: only accumulate active time when input is recent.
            let recentlyActive = idleSec < 5
            if recentlyActive { ep.activeSecondsSinceReturn += 1 }

            let curve = (profile.escalation ?? .default).idleReturn
            // Find highest rung whose threshold we've crossed.
            var targetRung = -1
            for (i, rung) in curve.enumerated() where
                ep.activeSecondsSinceReturn >= Double(rung.afterActiveSec) {
                targetRung = i
            }
            if targetRung > ep.lastRungFired {
                ep.lastRungFired = targetRung
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

        return .none
    }

    // Discard any in-flight episode and reset idle state. Call this from
    // Tracker.stop() so a stale episode opened during one session cannot bleed into
    // the next. Once the session ends there is no task to attribute the idle time to,
    // so the episode is definitionally unresolvable and must be discarded.
    public func reset() {
        episode = nil
        wasIdle = false
    }

    public func resolveSegment(_ id: UUID) {
        guard let ep = episode else { return }
        if let idx = ep.segments.firstIndex(where: { $0.id == id }) {
            ep.segments[idx].resolved = true
        }
        if ep.fullyResolved { episode = nil }   // episode done, escalation stops
    }

    // Two-segment split per locked design.
    private func buildSegments(episode ep: IdleEpisode,
                               now: Date,
                               armBoundary: Date?,
                               taskId: Int64,
                               phaseId: String,
                               isBreakPhase: Bool,
                               breakTaskId: Int64) -> [IdleSegment] {
        var segs: [IdleSegment] = []

        // armBoundary nil => phase was already armed when idle began =>
        // whole episode is overrun, inPhase collapses.
        let boundary = armBoundary

        if let b = boundary, b > ep.idleStart, b < now {
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
            // No boundary crossed (returned before arm) OR already armed.
            // Single segment covering the whole idle.
            let kind: IdleSegment.Kind = (boundary == nil) ? .overrun : .inPhase
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
