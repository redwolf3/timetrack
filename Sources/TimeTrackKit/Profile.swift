import Foundation
import Yams

// A phase is one segment of a profile's cycle. Phases never auto-advance;
// when their timer expires they ARM and wait for user acknowledgment.
public struct Phase: Codable {
    public let id: String                 // "work", "short_break", "long_break"
    public let durationMin: Int
    public let accrueAs: String?          // nil = accrue to current task; "break" = synthetic
    public let onArm: ArmConfig
}

public struct ArmConfig: Codable {
    public let sound: String              // NSSound name: "Glass", "Tink", etc.
    public let color: String              // icon color: "green_pulse", "amber", "red"
    public let actions: [ArmAction]
}

// Actions available to the user when a phase is ARMED. Two kinds:
//   advance_to: jump to the named phase (logs phase_advance)
//   extend_min: add N minutes to the current phase (logs phase_extend)
//   extend_prompt: open a custom-minutes dialog
public struct ArmAction: Codable {
    public let label: String
    public let advanceTo: String?
    public let extendMin: Int?
    public let extendPrompt: Bool?
}

public struct Profile: Codable {
    public let name: String
    public let cycle: [Phase]
    public let longCycleEvery: Int?       // nil = no long cycle
    public let longCycleOverride: [Phase]? // replaces final phase of cycle on Nth iteration

    // Idle detection. Idle below wiggleRoomMin is ignored entirely (bathroom,
    // coffee). Idle at/above idleThresholdMin opens a gap requiring classification.
    public let idleThresholdMin: Int?     // default 5 if nil
    public let wiggleRoomMin: Int?        // default 5 if nil; sub-threshold idle ignored

    // Escalation. Two curves: flowArm (decision pending but user never went
    // idle — protect flow, cap gently) and idleReturn (user returned from idle
    // with unresolved segments — ramp hard). Both presence-gated: rungs only
    // advance on detected activity-seconds since the trigger, never on wall clock.
    public let escalation: EscalationConfig?

    // The phase that follows `currentPhaseId` when advancing the cycle once,
    // i.e. the destination of an ARMED → advance/ack. This mirrors what a fresh
    // CycleIterator would return from advance() when its index sits on
    // currentPhaseId on a NON-long cycle: it walks the base `cycle` and wraps to
    // the first phase. Returns nil only if currentPhaseId isn't in the cycle.
    //
    // Why base-cycle only: the long-cycle override (every Nth iteration) depends
    // on the iterator's running cycle-number, which is in-memory state the
    // stateless CLI cannot reconstruct from the event log without replaying the
    // whole stream. The common, non-Nth case is exactly the base cycle, so the
    // CLI uses this to emit a canonical phase_advance for switch-from-ARMED.
    // (The in-process app keeps the live CycleIterator and is unaffected.)
    //
    // Override-aware fallback: this is now the LEGACY path for switch-from-ARMED
    // (when an arm event predates nextPhaseId). If currentPhaseId is an OVERRIDE
    // phase (present in longCycleOverride but not in `cycle`, e.g. long_break),
    // the only sensible single-step successor is the start of the next cycle —
    // cycle[0] — since the override always sits at the cycle's tail. Without this
    // a legacy long_break arm would return nil and hard-error.
    public func phaseAfter(currentPhaseId: String) -> Phase? {
        guard let idx = cycle.firstIndex(where: { $0.id == currentPhaseId }) else {
            // Not in the base cycle. If it's an override phase, the cycle wraps
            // back to its first phase; otherwise it's truly unknown.
            if let override = longCycleOverride,
               override.contains(where: { $0.id == currentPhaseId }) {
                return cycle.first
            }
            return nil
        }
        let nextIdx = (idx + 1) % cycle.count
        return cycle[nextIdx]
    }
}

public struct EscalationConfig: Codable {
    public let flowArm: [EscalationRung]      // capped: icon/sound only, no notifications
    public let idleReturn: [EscalationRung]   // full ramp: ... → persistent notification

    public static let `default` = EscalationConfig(
        flowArm: [
            EscalationRung(afterActiveSec: 0,   sound: "Tink",  color: "amber",      notify: false, repeatNotifySec: nil),
            EscalationRung(afterActiveSec: 120, sound: "Tink",  color: "amber_pulse", notify: false, repeatNotifySec: nil)
            // caps here — flow is protected, no notification rung
        ],
        idleReturn: [
            EscalationRung(afterActiveSec: 0,   sound: "Glass", color: "red",        notify: false, repeatNotifySec: nil),
            EscalationRung(afterActiveSec: 30,  sound: "Glass", color: "red_pulse",  notify: false, repeatNotifySec: nil),
            EscalationRung(afterActiveSec: 90,  sound: "Hero",  color: "red_pulse",  notify: true,  repeatNotifySec: nil),
            EscalationRung(afterActiveSec: 180, sound: "Hero",  color: "red_pulse",  notify: true,  repeatNotifySec: 60)
            // ceiling: notification re-posts every 60s while active + unresolved
        ])
}

// A rung fires once cumulative active-seconds-since-trigger crosses afterActiveSec.
// repeatNotifySec (if set) re-posts the notification on that cadence while still
// active and unresolved — this is the permanent ceiling, never a modal.
public struct EscalationRung: Codable, Equatable {
    public let afterActiveSec: Int
    public let sound: String?
    public let color: String
    public let notify: Bool
    public let repeatNotifySec: Int?
}

// Iterator over a profile's phases. Tracks cycle count for long-break override.
// Stateful, owned by Tracker. Reset() on stop().
final class CycleIterator {
    private let profile: Profile
    private var index: Int = 0
    private var cycleNumber: Int = 1   // 1-indexed; increments after returning to phase 0

    init(profile: Profile) { self.profile = profile }

    var currentPhase: Phase {
        let phases = phasesForCurrentCycle()
        return phases[index]
    }

    // Non-mutating: returns what advance() would return without changing state.
    func peekNext() -> Phase {
        let phases = phasesForCurrentCycle()
        let nextIndex = (index + 1) % phases.count
        // If we'd wrap, the next cycle might use the override; check that.
        if nextIndex == 0 {
            let nextCycle = cycleNumber + 1
            if let every = profile.longCycleEvery,
               let override = profile.longCycleOverride,
               nextCycle % every == 0 {
                var nextPhases = Array(profile.cycle.dropLast())
                nextPhases.append(contentsOf: override)
                return nextPhases[0]
            }
            return profile.cycle[0]
        }
        return phases[nextIndex]
    }

    // Advance to the next phase. Returns the new current phase.
    func advance() -> Phase {
        let phases = phasesForCurrentCycle()
        index += 1
        if index >= phases.count {
            index = 0
            cycleNumber += 1
        }
        return currentPhase
    }

    func reset() {
        index = 0
        cycleNumber = 1
    }

    // If this is the Nth cycle and an override exists, substitute its phases.
    // Otherwise return the standard cycle.
    private func phasesForCurrentCycle() -> [Phase] {
        guard let every = profile.longCycleEvery,
              let override = profile.longCycleOverride,
              cycleNumber % every == 0 else {
            return profile.cycle
        }
        // Replace the final phase of the standard cycle with the override phases.
        // This lets pomodoro's 4th break be 15 min instead of 5.
        var phases = Array(profile.cycle.dropLast())
        phases.append(contentsOf: override)
        return phases
    }
}

// Loads profiles.yaml from the app support directory, or seeds defaults.
// Public so the stateless CLI can load the same profile set the app uses when
// it must reconstruct phase math from the event log (e.g. switch-from-ARMED).
public enum ProfileLoader {

    // Thrown when profiles.yaml fails validation. Profile name is the identity
    // used by setProfile(name:) and SwiftUI Picker tags, so duplicates must
    // fail loudly at load — ambiguous resolution is worse than a startup error.
    public enum ValidationError: Error, CustomStringConvertible {
        case duplicateName(String)

        public var description: String {
            switch self {
            case .duplicateName(let name):
                return "profiles.yaml: duplicate profile name '\(name)' — each name must be unique"
            }
        }
    }

    public static func loadAll(from url: URL) throws -> [Profile] {
        if !FileManager.default.fileExists(atPath: url.path) {
            try seedDefaults(to: url)
        }
        let yaml = try String(contentsOf: url, encoding: .utf8)
        struct Wrapper: Codable { let profiles: [Profile] }
        let decoder = YAMLDecoder()
        let profiles = try decoder.decode(Wrapper.self, from: yaml).profiles

        // Detect duplicates. Profile name is the identity key for setProfile
        // and Picker tags; duplicates would render ambiguously or silently pick
        // the wrong profile, so we fail loudly here rather than at first use.
        var seen: Set<String> = []
        for profile in profiles {
            if seen.contains(profile.name) {
                throw ValidationError.duplicateName(profile.name)
            }
            seen.insert(profile.name)
        }

        return profiles
    }

    private static func seedDefaults(to url: URL) throws {
        let defaults = """
        profiles:
          - name: default
            cycle:
              - id: work
                durationMin: 45
                onArm:
                  sound: Tink
                  color: amber
                  actions:
                    - { label: "Acknowledge",   advanceTo: work }
                    - { label: "+15 min",       extendMin: 15 }
                    - { label: "+custom...",    extendPrompt: true }

          - name: pomodoro
            longCycleEvery: 4
            cycle:
              - id: work
                durationMin: 25
                onArm:
                  sound: Glass
                  color: green_pulse
                  actions:
                    - { label: "Start break",   advanceTo: short_break }
                    - { label: "+5 min",        extendMin: 5 }
                    - { label: "+10 min",       extendMin: 10 }
                    - { label: "+custom...",    extendPrompt: true }
              - id: short_break
                durationMin: 5
                accrueAs: break
                onArm:
                  sound: Tink
                  color: amber
                  actions:
                    - { label: "Back to work",  advanceTo: work }
                    - { label: "+5 min more",   extendMin: 5 }
                    - { label: "+custom...",    extendPrompt: true }
            longCycleOverride:
              - id: long_break
                durationMin: 15
                accrueAs: break
                onArm:
                  sound: Tink
                  color: amber
                  actions:
                    - { label: "Back to work",  advanceTo: work }
                    - { label: "+10 min more",  extendMin: 10 }
                    - { label: "+custom...",    extendPrompt: true }

          - name: deep_work
            cycle:
              - id: focus
                durationMin: 90
                onArm:
                  sound: Glass
                  color: green_pulse
                  actions:
                    - { label: "Start break",   advanceTo: long_break }
                    - { label: "+15 min",       extendMin: 15 }
              - id: long_break
                durationMin: 20
                accrueAs: break
                onArm:
                  sound: Tink
                  color: amber
                  actions:
                    - { label: "Back to focus", advanceTo: focus }
                    - { label: "+10 min more",  extendMin: 10 }
        """
        try defaults.write(to: url, atomically: true, encoding: .utf8)
    }
}
