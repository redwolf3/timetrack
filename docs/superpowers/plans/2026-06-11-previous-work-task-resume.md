# previousWorkTaskId Break-Resume Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the break-resume behavior merged in PR #4 up to the approved spec: staleness guard, stop-clears-resume, leaving-break gating, and one shared query as the single source of truth — with full unit/integration/parity tests.

**Architecture:** Baseline is `main` @ `4daf0a7`, which already resumes the most-recent non-break task **unconditionally** via `Store.mostRecentWorkTaskId` (called from a private `Tracker.previousWorkTaskId()` wrapper and an inline closure in `switchFromArmed`; no direct tests). This plan introduces the spec'd `Store.previousWorkTaskId(leavingBreak:asOf:staleFactor:)` (timeline walk reusing `nextActiveTask`, staleness relative to break length, `stop` clears), rewires both call sites to it gated on the leaving phase being a break, and deletes `mostRecentWorkTaskId`. `accrualTaskId`'s signature is unchanged. No schema change; pure append-only reads.

**Tech Stack:** Swift 5.9, GRDB, XCTest. Spec: `docs/superpowers/specs/2026-06-11-previous-work-task-resume-design.md` (§0 documents the baseline delta; §3 semantics are authoritative).

**Branch:** all work on `feature/previous-work-task-resume` (rebased onto `4daf0a7`; spec committed). Iterative commits during development. End-game (handled by the lead, not plan tasks): squash to ONE commit, push, open PR. **Never commit to `main`; never merge the PR — the user reviews all merges.**

---

## Context for a zero-context engineer

- **Why this exists:** when a break phase ends, the "carried" task at the armed boundary is the synthetic break task. `Store.accrualTaskId(...)` resolves the next accrual target as `previousWorkTaskId ?? carriedTaskId`. PR #4 made both paths feed that parameter from `Store.mostRecentWorkTaskId` — which fixed the basic "work time accrues to break" wart but: (1) resumes no matter how long the break ran (spec wants a staleness guard: strict `>` on `2.0 × breakPhase.durationMin`); (2) ignores `stop` events, so it would resume a task from before a stopped session; (3) runs on every boundary, not just break-exits; (4) exists in two duplicated lookups; (5) has zero direct tests.
- **Append-only invariant (CLAUDE.md):** never UPDATE/DELETE events. This feature stays a pure read; the corrected accrual target flows into the `phase_advance` events both paths already append.
- **Key existing pieces** (anchors, not line numbers — read them before coding):
  - `Sources/TimeTrackKit/Store.swift` — `EventType` enum (top of file), `breakTaskId()`, `mostRecentWorkTaskId(excludingBreakTaskId:limit:)` (to be deleted in Task 3), `readAllEventsInternal()`, `accrualTaskId(forNextPhase:carriedTaskId:previousWorkTaskId:)` under `// MARK: - Shared accrual-task decision`, `switchFromArmed(...)` (contains the `let prevWorkId: Int64? = { ... }()` closure to replace), `resolvePhase(id:in:)`, `nextActiveTask(after:current:)` (private; reuse it).
  - `Sources/TimeTrackKit/Tracker.swift` — `advance()` (binds `.armed(taskId, _, _, _)`; the `_` second element is the armed phase you'll need), private `previousWorkTaskId()` delegating wrapper (to be deleted in Task 2), `phaseStartedAt = Date()` line in `advance()` that MUST be preserved.
  - `Tests/TimeTrackKitTests/Helpers.swift` — `makeTmpDir()`, `makeBreakProfile()`, `makeTrackerContext(in:)` (`@MainActor`; call via `MainActor.assumeIsolated`; Tracker init defaults `idleSource: FakeIdleSource()` whose 0-idle makes the idle machinery a no-op in these tests).
  - `Tests/TimeTrackKitTests/PhaseAdvanceTests.swift` — the `appendEvent` helper pattern and three existing `accrualTaskId` tests (must stay green unchanged).
- **Semantics (spec §3):** resume target = most-recent non-break task on the event-log active-task timeline (via `nextActiveTask`, so `idle_gap`/`idle_resolve` are no-ops and `stop` clears); stale ⇔ `(now − breakRunStartTs) > staleFactor × breakPhase.durationMin` (strict >), where `breakRunStartTs` is the ts of the `phase_advance` that entered the trailing break run; on `nil` the caller falls back to the carried (break) task — documented MVP behavior.
- **Two timestamp regimes in tests (IMPORTANT — easy trap):**
  - Unit tests of the new Store method inject `asOf`, so fixed epochs (`t0 = 1_000_000_000` ms ≈ 2001) are fine.
  - `Tracker.advance()` and `switchFromArmed` call it with `asOf: Date()`. Tests driving *those paths* that expect a **resume** must seed event timestamps **near `Date()`**; seeding 2001 epochs makes the break decades long → stale → fallback (which is exactly how the stale-path test works).
- **TDD honesty note:** the baseline already resumes unconditionally, so some integration tests written here PASS before the wiring changes — they are pinning tests. The true red→green deltas are: Task 1's unit tests (new method doesn't exist → compile error) and Task 3's stale test (baseline resumes where spec says fall back). Expected outcomes are stated per step; trust them.
- **Verification baseline:** on the rebased branch, `swift build` succeeds and `swift test` reports **119 tests, 0 failures**. Commands: `swift test` (full), `swift test --filter PreviousWorkTaskTests` (scoped).

---

### Task 1: `Store.previousWorkTaskId` — unit tests + implementation

**Files:**
- Create: `Tests/TimeTrackKitTests/PreviousWorkTaskTests.swift`
- Modify: `Sources/TimeTrackKit/Store.swift` (insert constant + method directly after `accrualTaskId`'s closing brace, before the `// MARK: - Switch from ARMED (canonical implicit-ack)` block). Do NOT touch `mostRecentWorkTaskId` yet — it still has callers until Tasks 2–3.

- [ ] **Step 1: Write the failing unit tests**

Create `Tests/TimeTrackKitTests/PreviousWorkTaskTests.swift` with exactly this content (Tracker/CLI-path tests are appended in later tasks):

```swift
import XCTest
@testable import TimeTrackKit

// Break-resume (previousWorkTaskId) tests.
// Spec: docs/superpowers/specs/2026-06-11-previous-work-task-resume-design.md
//
// Unit tests inject `asOf`, so fixed epochs are fine here. Tests that drive
// Tracker.advance()/Store.switchFromArmed (appended in later plan tasks) use
// real-now-relative timestamps because those paths stale against Date().
final class PreviousWorkTaskTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() throws -> Store {
        let dir = try makeTmpDir()
        return try Store(url: dir.appendingPathComponent("test.db"))
    }

    private func makeTask(_ store: Store, name: String) throws -> Task {
        var t = Task(id: nil, name: name, code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        return t
    }

    @discardableResult
    private func appendEvent(_ store: Store,
                             ts: Int64,
                             type: EventType,
                             taskId: Int64? = nil,
                             prevTaskId: Int64? = nil,
                             phaseId: String? = nil,
                             profileName: String? = nil,
                             nextPhaseId: String? = nil) throws -> Event {
        try store.append(Event(
            id: nil, ts: ts, type: type.rawValue,
            taskId: taskId, prevTaskId: prevTaskId,
            phaseId: phaseId, profileName: profileName,
            extendMin: nil, comment: nil,
            nextPhaseId: nextPhaseId))
    }

    private let arm = ArmConfig(sound: "Tink", color: "amber", actions: [])
    private var breakPhase5: Phase {
        Phase(id: "break", durationMin: 5, accrueAs: "break", onArm: arm)
    }
    private var longBreak15: Phase {
        Phase(id: "long_break", durationMin: 15, accrueAs: "break", onArm: arm)
    }

    // Fixed epoch ms (~2001). Safe ONLY where asOf is injected.
    private let t0: Int64 = 1_000_000_000

    private func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    // Seeds the canonical "work(A) then into break" log. Returns breakStartTs.
    private func seedWorkThenBreak(_ store: Store, a: Int64) throws -> Int64 {
        try appendEvent(store, ts: t0, type: .start, taskId: a, phaseId: "work")
        let breakStart = t0 + 25 * 60_000
        let breakId = try store.breakTaskId()
        try appendEvent(store, ts: breakStart, type: .phaseAdvance,
                        taskId: breakId, prevTaskId: a, phaseId: "break")
        return breakStart
    }

    // MARK: - Unit: resume semantics

    // Normal cycle: work(A) → break, break ran its nominal length → resume A.
    func testResumesPriorWorkTaskAfterNominalBreak() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let breakStart = try seedWorkThenBreak(store, a: a)

        // 5 min into a 5-min break; threshold = 2 × 5 = 10 min.
        let result = try store.previousWorkTaskId(
            leavingBreak: breakPhase5, asOf: date(breakStart + 5 * 60_000))

        XCTAssertEqual(result, a,
            "leaving a nominal-length break must resume the pre-break work task")
    }

    // Stale: break ran past 2× its nominal duration → nil (don't guess).
    func testStaleBreakSuppressesResume() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let breakStart = try seedWorkThenBreak(store, a: a)

        // 11 min into a 5-min break; threshold = 10 min → stale.
        let result = try store.previousWorkTaskId(
            leavingBreak: breakPhase5, asOf: date(breakStart + 11 * 60_000))

        XCTAssertNil(result,
            "a break that ran past staleFactor × durationMin must suppress auto-resume")
    }

    // Boundary: exactly AT the threshold still resumes; strictly past it is stale.
    func testStaleThresholdIsStrictlyGreaterThan() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let breakStart = try seedWorkThenBreak(store, a: a)
        let thresholdMs: Int64 = 10 * 60_000  // 2.0 × 5 min

        XCTAssertEqual(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(breakStart + thresholdMs)),
            a, "elapsed == threshold must still resume (staleness is strict >)")

        XCTAssertNil(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(breakStart + thresholdMs + 1)),
            "elapsed just past the threshold must be stale")
    }

    // Mid-break switch to a real task: the trailing active task is non-break,
    // so it is returned directly — and is never subject to staleness.
    func testMidBreakSwitchWinsOverPreBreakTask() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let b = try makeTask(store, name: "B").id!
        let breakStart = try seedWorkThenBreak(store, a: a)
        let breakId = try store.breakTaskId()
        try appendEvent(store, ts: breakStart + 2 * 60_000, type: .switch,
                        taskId: b, prevTaskId: breakId, phaseId: "break")

        XCTAssertEqual(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(breakStart + 3 * 60_000)),
            b, "an explicit mid-break switch must win over the pre-break task")

        XCTAssertEqual(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(breakStart + 100 * 60_000)),
            b, "already being on a work task is never stale (it IS the carried task)")
    }

    // stop ends the session: resuming across a stop would be a guess → nil.
    // (The merged baseline got this wrong: mostRecentWorkTaskId ignores stop.)
    func testStopClearsResume() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let breakStart = try seedWorkThenBreak(store, a: a)
        try appendEvent(store, ts: breakStart + 60_000, type: .stop, prevTaskId: a)

        XCTAssertNil(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(breakStart + 2 * 60_000)),
            "a stop after the break entry must clear the resume candidate")
    }

    // A break with no prior work task at all → nil.
    func testNoPriorWorkTaskReturnsNil() throws {
        let store = try makeStore()
        let breakId = try store.breakTaskId()
        try appendEvent(store, ts: t0, type: .phaseAdvance,
                        taskId: breakId, phaseId: "break")

        XCTAssertNil(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(t0 + 60_000)),
            "no prior work task in the log means nothing to resume")
    }

    // Empty log → nil (and must not throw).
    func testEmptyLogReturnsNil() throws {
        let store = try makeStore()
        XCTAssertNil(
            try store.previousWorkTaskId(leavingBreak: breakPhase5, asOf: Date()),
            "an empty event log has nothing to resume")
    }

    // Multi-cycle: resume reflects the LATEST work task, not the first.
    func testMultiCycleResumesLatestWorkTask() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let b = try makeTask(store, name: "B").id!
        let breakId = try store.breakTaskId()

        // work(A) → break → work(A resumed) → switch(B) → break (trailing)
        try appendEvent(store, ts: t0, type: .start, taskId: a, phaseId: "work")
        try appendEvent(store, ts: t0 + 25 * 60_000, type: .phaseAdvance,
                        taskId: breakId, prevTaskId: a, phaseId: "break")
        try appendEvent(store, ts: t0 + 30 * 60_000, type: .phaseAdvance,
                        taskId: a, prevTaskId: breakId, phaseId: "work")
        try appendEvent(store, ts: t0 + 40 * 60_000, type: .switch,
                        taskId: b, prevTaskId: a, phaseId: "work")
        let secondBreak = t0 + 55 * 60_000
        try appendEvent(store, ts: secondBreak, type: .phaseAdvance,
                        taskId: breakId, prevTaskId: b, phaseId: "break")

        XCTAssertEqual(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(secondBreak + 4 * 60_000)),
            b, "after multiple cycles the most recent work task (B) must resume")
    }

    // idle_gap / idle_resolve are timeline no-ops: they must neither change the
    // resume candidate nor reset the break-run start used for staleness.
    func testIdleEventsDoNotDisturbResumeOrStaleness() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let breakStart = try seedWorkThenBreak(store, a: a)
        // Idle gap detected during the break, later resolved. Both no-ops here.
        try appendEvent(store, ts: breakStart + 60_000, type: .idleGap, taskId: a)
        try store.append(Event(
            id: nil, ts: breakStart + 3 * 60_000, type: EventType.idleResolve.rawValue,
            taskId: a, prevTaskId: a, phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil,
            rangeStart: breakStart + 60_000, rangeEnd: breakStart + 2 * 60_000))

        XCTAssertEqual(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(breakStart + 5 * 60_000)),
            a, "idle events are no-ops in the active-task walk")

        XCTAssertNil(
            try store.previousWorkTaskId(
                leavingBreak: breakPhase5, asOf: date(breakStart + 11 * 60_000)),
            "staleness must anchor to the break entry, not be reset by idle events")
    }

    // long_break: the threshold scales with the LEAVING phase's own duration.
    func testLongBreakUsesItsOwnDurationForStaleness() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let breakStart = try seedWorkThenBreak(store, a: a)
        let asOf = date(breakStart + 20 * 60_000)  // 20 min into the break

        XCTAssertEqual(
            try store.previousWorkTaskId(leavingBreak: longBreak15, asOf: asOf),
            a, "20 min is within 2 × 15 min for a long break → resume")

        XCTAssertNil(
            try store.previousWorkTaskId(leavingBreak: breakPhase5, asOf: asOf),
            "the same 20 min is past 2 × 5 min for a short break → stale")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PreviousWorkTaskTests 2>&1 | tail -20`
Expected: **compile error** — `value of type 'Store' has no member 'previousWorkTaskId'`. (Compile failure is the red state; the method doesn't exist yet. Note `Tracker.previousWorkTaskId()` is a *private Tracker* method, unrelated.)

- [ ] **Step 3: Implement the constant and method in Store.swift**

In `Sources/TimeTrackKit/Store.swift`, insert immediately **after** the closing brace of `accrualTaskId(...)` and **before** the `// MARK: - Switch from ARMED (canonical implicit-ack)` comment block:

```swift
    // Multiplier on a break phase's nominal durationMin beyond which auto-resume
    // is suppressed: if (now − breakRunStart) > factor × durationMin, the break
    // ran so far past its intended length that silently resuming the old task is
    // more likely wrong than right — return nil and let the user pick. Relative
    // (not an absolute-minutes knob) so it self-scales per profile; promotable to
    // a Profile field if per-profile tuning is ever wanted.
    static let breakResumeStaleFactor: Double = 2.0

    // The work task to resume when advancing OUT of `breakPhase` back into work,
    // or nil when there is nothing sane to resume: no prior work task exists, the
    // session was stopped, or the break ran past staleFactor × durationMin.
    // SINGLE source of truth shared by Tracker.advance() (in-process) and
    // switchFromArmed (stateless CLI) — same never-diverge contract as
    // accrualTaskId above, which consumes this value.
    //
    // Pure read of the append-only log. The walk reuses nextActiveTask() so the
    // active-task timeline can never diverge from report(): idle_gap/idle_resolve
    // are no-ops here too (idle reattribution is a report-time overlay, not a
    // state transition), and stop clears the timeline.
    //
    // `now` is injected (asOf) so staleness is deterministically testable.
    func previousWorkTaskId(leavingBreak breakPhase: Phase,
                            asOf now: Date,
                            staleFactor: Double = Store.breakResumeStaleFactor) throws -> Int64? {
        let breakId = try breakTaskId()
        let events = try readAllEventsInternal()

        var active: Int64? = nil           // active-task timeline, as report() sees it
        var resumeCandidate: Int64? = nil  // most-recent non-break active task
        var breakRunStartTs: Int64? = nil  // ts the trailing break run began

        for e in events {
            let next = nextActiveTask(after: e, current: active)
            guard next != active else { continue }
            if next == breakId {
                // Entering a break run; stamp only the FIRST transition into it.
                if active != breakId { breakRunStartTs = e.ts }
            } else if next != nil {
                // On a real work task: it is the resume candidate, and any
                // earlier break run is no longer "trailing".
                resumeCandidate = next
                breakRunStartTs = nil
            } else {
                // stop: the session ended; resuming across a stop is a guess.
                resumeCandidate = nil
                breakRunStartTs = nil
            }
            active = next
        }

        // Trailing active task isn't the break task: either we're already on a
        // work task (mid-break switch — return it; it equals the carried task,
        // so accrual is unchanged) or the session is stopped/empty (nil).
        if active != breakId { return active }

        guard let resume = resumeCandidate, let breakStart = breakRunStartTs else {
            return nil   // the log starts inside a break; nothing to resume
        }

        // Staleness anchors to the BREAK's start, not the last work event: the
        // last work event is the work-phase entry (~a full work phase old on
        // every normal cycle), which would falsely flag every cycle as stale.
        // (now − breakStart) measures actual break length vs nominal length.
        let elapsedMs = Int64(now.timeIntervalSince1970 * 1000) - breakStart
        let thresholdMs = staleFactor * Double(breakPhase.durationMin) * 60_000
        return Double(elapsedMs) > thresholdMs ? nil : resume
    }
```

Note: `internal` visibility is deliberate — Tracker is in the same module, `switchFromArmed` is a Store method, tests use `@testable import`. (The baseline's `mostRecentWorkTaskId` is `public`, but nothing outside the kit calls it; its replacement doesn't repeat that.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PreviousWorkTaskTests 2>&1 | tail -20`
Expected: all 11 tests PASS.
Then run the FULL suite to confirm no regressions: `swift test 2>&1 | tail -5` → 130 tests (119 + 11), 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Tests/TimeTrackKitTests/PreviousWorkTaskTests.swift Sources/TimeTrackKit/Store.swift
git commit -m "feat(kit): Store.previousWorkTaskId — spec'd break-resume query (staleness, stop-aware)"
```

---

### Task 2: Rewire `Tracker.advance()`; delete the delegating wrapper

**Files:**
- Modify: `Sources/TimeTrackKit/Tracker.swift` — `advance()` body, and delete the private `previousWorkTaskId()` wrapper near the end of the class
- Test: `Tests/TimeTrackKitTests/PreviousWorkTaskTests.swift` (append one test)

- [ ] **Step 1: Write the pinning integration test**

Append inside the `PreviousWorkTaskTests` class (before its closing brace):

```swift
    // MARK: - Integration: Tracker.advance() out of a break

    // start(A) → arm → advance into short_break → arm → advance out: the new
    // tracking task and the appended phase_advance must both be A, not the
    // break task. Event timestamps are real-now (append stamps Date()), so the
    // ~ms-long "break" is never stale. NOTE: this PASSES on the PR#4 baseline
    // too (unconditional resume) — it pins the behavior through the rewiring;
    // the spec-vs-baseline deltas are covered by the Task-1 unit tests and the
    // Task-3 stale test.
    func testAdvanceOutOfBreakResumesPreBreakTask() throws {
        let dir = try makeTmpDir()
        let (tracker, store, taskA) = try MainActor.assumeIsolated {
            try makeTrackerContext(in: dir)
        }

        MainActor.assumeIsolated {
            // Seeded pomodoro profile: work(25) → short_break(5).
            tracker.setProfile("pomodoro")
            tracker.start(taskId: taskA)
            tracker.tick(at: Date().addingTimeInterval(3 * 60 * 60))  // arm work
            tracker.advance()                                          // → short_break
            tracker.tick(at: Date().addingTimeInterval(6 * 60 * 60))  // arm short_break
            tracker.advance()                                          // → work: resume A
        }

        let activeId = MainActor.assumeIsolated { tracker.activeTask?.id }
        XCTAssertEqual(activeId, taskA,
            "advancing out of a break must resume the pre-break work task")

        let events = try store.readAllEventsInternal()
        let last = events[events.count - 1]
        let breakId = try store.breakTaskId()
        XCTAssertEqual(last.type, EventType.phaseAdvance.rawValue)
        XCTAssertEqual(last.taskId, taskA,
            "the phase_advance out of the break must carry the resumed task")
        XCTAssertEqual(last.prevTaskId, breakId,
            "the carried task at a break exit is the synthetic break task")
    }
```

- [ ] **Step 2: Run it — expect PASS (pinning, not red)**

Run: `swift test --filter PreviousWorkTaskTests.testAdvanceOutOfBreakResumesPreBreakTask 2>&1 | tail -8`
Expected: PASS already (the baseline resumes unconditionally). This test exists so the rewiring in Step 3 cannot silently break the working path. Don't skip it.

- [ ] **Step 3: Rewire advance() and delete the wrapper**

In `Sources/TimeTrackKit/Tracker.swift`, the current `advance()` is:

```swift
    public func advance(comment: String? = nil) {
        guard case let .armed(taskId, _, _, _) = state,
              let iter = iterator else { return }

        _ = iter.advance()
        let newPhase = iter.currentPhase
        let deadline = Date().addingTimeInterval(Double(newPhase.durationMin * 60))

        // Determine the task that accrues during the next phase via the SHARED
        // kit helper, so this can never diverge from Store.switchFromArmed (the
        // stateless CLI path). The helper's break branch reads breakTaskId() (it
        // throws); preserve advance()'s historic try?-with-fallback-to-taskId so
        // behavior is byte-identical to before this refactor.
        let nextTaskId: Int64 = (try? store.accrualTaskId(
            forNextPhase: newPhase,
            carriedTaskId: taskId,
            previousWorkTaskId: previousWorkTaskId())) ?? taskId

        try? store.append(Event(
            id: nil, ts: 0, type: EventType.phaseAdvance.rawValue,
            taskId: nextTaskId, prevTaskId: taskId,
            phaseId: newPhase.id, profileName: profileName,
            extendMin: nil, comment: comment))

        phaseStartedAt = Date()
        state = .tracking(taskId: nextTaskId, phase: newPhase, deadline: deadline)
        activeTask = tasks.first(where: { $0.id == nextTaskId })
    }
```

Replace it with (changes: bind `armedPhase` instead of the second `_`; compute `prev` gated on leaving a break; pass `prev`; everything else — including `phaseStartedAt = Date()` — byte-identical):

```swift
    public func advance(comment: String? = nil) {
        guard case let .armed(taskId, armedPhase, _, _) = state,
              let iter = iterator else { return }

        _ = iter.advance()
        let newPhase = iter.currentPhase
        let deadline = Date().addingTimeInterval(Double(newPhase.durationMin * 60))

        // The resume question only exists when LEAVING a break: the carried
        // task is then the synthetic break task, and resuming it into a work
        // phase would silently drop time. Guard here so ordinary work→work
        // advances never pay for the event-log walk.
        let prev: Int64? = (armedPhase.accrueAs == "break")
            ? ((try? store.previousWorkTaskId(leavingBreak: armedPhase, asOf: Date())) ?? nil)
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
```

(`(try? …) ?? nil` flattens the `Int64??` produced by `try?` on an optional-returning throwing call.)

Then **delete entirely** the now-unused private wrapper near the bottom of the class (verbatim, including its comment):

```swift
    // Walk back through recent events to find the most recent non-break taskId.
    // Used by advance() when transitioning from a break phase back to work, so the
    // new work phase accrues against the task the user was on BEFORE the break
    // rather than silently accruing against the break task until the user manually
    // taps a task row.
    //
    // Delegates to Store.mostRecentWorkTaskId() — a single DB query over the last
    // ~50 state-changing events, cheap and bounded. Returns nil only when no prior
    // work task exists in the window (e.g. brand-new session that started with a
    // break), in which case the caller falls back to the carried task id.
    private func previousWorkTaskId() -> Int64? {
        guard let breakId = try? store.breakTaskId(), breakId != -1 else {
            return nil
        }
        return try? store.mostRecentWorkTaskId(excludingBreakTaskId: breakId)
    }
```

- [ ] **Step 4: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: 131 tests, 0 failures (130 + the new pinning test). `TrackerStateMachineTests` must be untouched-green.

- [ ] **Step 5: Commit**

```bash
git add Sources/TimeTrackKit/Tracker.swift Tests/TimeTrackKitTests/PreviousWorkTaskTests.swift
git commit -m "feat(kit): Tracker.advance() uses spec'd resume query, gated on leaving-break"
```

---

### Task 3: Rewire `switchFromArmed`; delete `mostRecentWorkTaskId`; stale + parity tests

**Files:**
- Modify: `Sources/TimeTrackKit/Store.swift` — replace the `prevWorkId` closure inside `switchFromArmed`; delete `mostRecentWorkTaskId`
- Test: `Tests/TimeTrackKitTests/PreviousWorkTaskTests.swift` (append three tests)

- [ ] **Step 1: Write the tests (one red, two pinning)**

Append inside the `PreviousWorkTaskTests` class:

```swift
    // MARK: - CLI path: switchFromArmed off a BREAK boundary

    // Seeds a near-NOW log (switchFromArmed stales against Date()) representing:
    // work(A, 10 min ago) → break (4 min ago) → break phase armed (30 s ago).
    // Returns the break task id. Callers then switch to a target task.
    private func seedArmedBreakBoundaryNearNow(_ store: Store, a: Int64,
                                               profileName: String) throws -> Int64 {
        let breakId = try store.breakTaskId()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try appendEvent(store, ts: nowMs - 10 * 60_000, type: .start,
                        taskId: a, phaseId: "work", profileName: profileName)
        try appendEvent(store, ts: nowMs - 4 * 60_000, type: .phaseAdvance,
                        taskId: breakId, prevTaskId: a, phaseId: "break",
                        profileName: profileName)
        try appendEvent(store, ts: nowMs - 30_000, type: .phaseArm,
                        taskId: breakId, phaseId: "break", profileName: profileName,
                        nextPhaseId: "work")
        return breakId
    }

    // Switch-from-ARMED off a break boundary: the implicit-ack phase_advance
    // must resume A (not stay on the break task), and the switch hangs off A.
    // (Pins baseline-correct behavior through the rewiring.)
    func testSwitchFromArmedOutOfBreakResumesViaPhaseAdvance() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let target = try makeTask(store, name: "Target").id!
        let profile = makeBreakProfile()   // work(25) → break(5)
        let breakId = try seedArmedBreakBoundaryNearNow(store, a: a,
                                                        profileName: profile.name)

        try store.switchFromArmed(armedTaskId: breakId, armedPhaseId: "break",
                                  targetTaskId: target, profile: profile)

        let events = try store.readAllEventsInternal()
        let advanceEv = events[events.count - 2]
        let switchEv  = events[events.count - 1]

        XCTAssertEqual(advanceEv.type, EventType.phaseAdvance.rawValue)
        XCTAssertEqual(advanceEv.taskId, a,
            "the implicit ack out of a break must resume the pre-break task")
        XCTAssertEqual(advanceEv.prevTaskId, breakId,
            "prevTaskId is the carried (break) task at the boundary")
        XCTAssertEqual(switchEv.type, EventType.switch.rawValue)
        XCTAssertEqual(switchEv.taskId, target)
        XCTAssertEqual(switchEv.prevTaskId, a,
            "the switch hangs off the resumed accrual task (valid FK chain)")
    }

    // Stale through the CLI path: the same log shape seeded at a fixed 2001
    // epoch with asOf == Date() is decades stale → resume suppressed → the
    // implicit ack falls back to the carried break task (documented MVP
    // fallback). RED on the PR#4 baseline (it resumes regardless of age).
    func testSwitchFromArmedStaleBreakFallsBackToCarried() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let target = try makeTask(store, name: "Target").id!
        let profile = makeBreakProfile()
        let breakId = try store.breakTaskId()

        try appendEvent(store, ts: t0, type: .start,
                        taskId: a, phaseId: "work", profileName: profile.name)
        try appendEvent(store, ts: t0 + 25 * 60_000, type: .phaseAdvance,
                        taskId: breakId, prevTaskId: a, phaseId: "break",
                        profileName: profile.name)
        try appendEvent(store, ts: t0 + 30 * 60_000, type: .phaseArm,
                        taskId: breakId, phaseId: "break", profileName: profile.name,
                        nextPhaseId: "work")

        try store.switchFromArmed(armedTaskId: breakId, armedPhaseId: "break",
                                  targetTaskId: target, profile: profile)

        let events = try store.readAllEventsInternal()
        let advanceEv = events[events.count - 2]
        let switchEv  = events[events.count - 1]

        XCTAssertEqual(advanceEv.taskId, breakId,
            "a stale break must NOT auto-resume; accrual falls back to carried")
        XCTAssertEqual(switchEv.prevTaskId, breakId,
            "the switch then hangs off the carried break task")
        XCTAssertEqual(switchEv.taskId, target,
            "the explicit switch target is unaffected by staleness")
    }

    // Parity ("never diverge"): on an identical log, the advance()-path
    // computation (previousWorkTaskId + accrualTaskId) and switchFromArmed's
    // appended phase_advance must pick the same accrual task.
    func testAdvancePathAndSwitchFromArmedAgreeOnAccrualTask() throws {
        let store = try makeStore()
        let a = try makeTask(store, name: "A").id!
        let target = try makeTask(store, name: "Target").id!
        let profile = makeBreakProfile()
        let breakId = try seedArmedBreakBoundaryNearNow(store, a: a,
                                                        profileName: profile.name)

        // What Tracker.advance() computes at this boundary:
        let workPhase = Phase(id: "work", durationMin: 25, accrueAs: nil, onArm: arm)
        let prev = try store.previousWorkTaskId(leavingBreak: breakPhase5, asOf: Date())
        let expected = try store.accrualTaskId(forNextPhase: workPhase,
                                               carriedTaskId: breakId,
                                               previousWorkTaskId: prev)

        // What the stateless CLI path actually appends:
        try store.switchFromArmed(armedTaskId: breakId, armedPhaseId: "break",
                                  targetTaskId: target, profile: profile)
        let events = try store.readAllEventsInternal()
        let advanceEv = events[events.count - 2]

        XCTAssertEqual(advanceEv.taskId, expected,
            "advance()-path computation and switchFromArmed must agree (single source of truth)")
        XCTAssertEqual(expected, a, "and on this log the agreed answer is the resumed task A")
    }
```

- [ ] **Step 2: Run them — exactly one must fail**

Run: `swift test --filter PreviousWorkTaskTests 2>&1 | tail -15`
Expected: `testSwitchFromArmedStaleBreakFallsBackToCarried` **FAILS** (the not-yet-rewired `switchFromArmed` still uses the unconditional `mostRecentWorkTaskId` → it resumes `A` where the spec demands the carried break task). The other two new tests PASS (pinning). If anything else fails, stop and investigate before proceeding.

- [ ] **Step 3: Rewire switchFromArmed and delete mostRecentWorkTaskId**

In `Sources/TimeTrackKit/Store.swift`, inside `switchFromArmed`, replace this block:

```swift
        // Look up the prior work task exactly as Tracker.previousWorkTaskId() does,
        // so the CLI path (switchFromArmed) and the in-process path (Tracker.advance)
        // always produce identical phase_advance events. armedTaskId is the break
        // task's id when advancing out of a break phase, so we exclude it to find
        // the most-recent real work task before that break.
        let prevWorkId: Int64? = {
            guard let breakId = try? self.breakTaskId(), breakId != -1 else { return nil }
            return try? self.mostRecentWorkTaskId(excludingBreakTaskId: breakId)
        }()

        let accrualTaskId = try accrualTaskId(
            forNextPhase: nextPhase,
            carriedTaskId: armedTaskId,
            previousWorkTaskId: prevWorkId)
```

with:

```swift
        // Resume target exists only when the boundary LEAVES a break phase.
        // Resolve the armed (leaving) phase the same way nextPhase is resolved;
        // if it can't be resolved (legacy/foreign id), degrade to nil — the
        // shared helper then falls back to the carried task. Mirrors
        // Tracker.advance(), which reads the armed phase from live state.
        let leavingPhase = resolvePhase(id: armedPhaseId, in: profile)
        let previousWorkTaskId: Int64?
        if let leaving = leavingPhase, leaving.accrueAs == "break" {
            previousWorkTaskId = try self.previousWorkTaskId(
                leavingBreak: leaving, asOf: Date())
        } else {
            previousWorkTaskId = nil
        }

        let accrualTaskId = try accrualTaskId(
            forNextPhase: nextPhase,
            carriedTaskId: armedTaskId,
            previousWorkTaskId: previousWorkTaskId)
```

(`self.` disambiguates the method from the local constant, matching the existing `let accrualTaskId = try accrualTaskId(...)` shadowing style.)

Then **delete entirely** the now-caller-free `mostRecentWorkTaskId` (verbatim, including its comment — it sits right after `breakTaskId()`):

```swift
    // Most recent non-break taskId from state-changing events, used by
    // previousWorkTaskId() when advancing from a break phase back to work.
    // Searches the last `limit` events for efficiency — the break→work transition
    // is always preceded by a recent start/switch/phase_advance to a work task.
    // Returns nil if no non-break task is found in the window (first session ever
    // or all recent events were break-task accruals).
    public func mostRecentWorkTaskId(excludingBreakTaskId breakId: Int64,
                                     limit: Int = 50) throws -> Int64? {
        try dbQueue.read { db in
            let workTypes = [
                EventType.start.rawValue,
                EventType.switch.rawValue,
                EventType.phaseAdvance.rawValue,
            ]
            // Walk recent state-changing events newest-first; pick the first
            // whose taskId isn't the break task. Phase-advance into a break phase
            // is skipped because its taskId IS the break task; phase-advance into
            // a work phase has the work task's id.
            let events = try Event
                .filter(workTypes.contains(Column("type")))
                .filter(Column("taskId") != nil)
                .filter(Column("taskId") != breakId)
                .order(Column("ts").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
            return events.first?.taskId
        }
    }
```

Verify nothing still references it: `grep -rn "mostRecentWorkTaskId" Sources/ Tests/` → no matches (the Tracker wrapper was deleted in Task 2).

- [ ] **Step 4: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: 134 tests, 0 failures — including the formerly-red stale test and the four pre-existing `switchFromArmed` tests in `PhaseAdvanceTests` (their boundaries leave non-break phases, so the gating leaves them untouched).

- [ ] **Step 5: Commit**

```bash
git add Sources/TimeTrackKit/Store.swift Tests/TimeTrackKitTests/PreviousWorkTaskTests.swift
git commit -m "feat(kit): switchFromArmed uses spec'd resume query; drop mostRecentWorkTaskId"
```

---

### Task 4: Stale-comment cleanup + final verification

**Files:**
- Modify: `Sources/TimeTrackKit/Store.swift` (accrualTaskId doc comment)
- Modify: `Tests/TimeTrackKitTests/PhaseAdvanceTests.swift` (comment only)

- [ ] **Step 1: Update the accrualTaskId doc comment**

In `Sources/TimeTrackKit/Store.swift`, the comment block above `accrualTaskId` currently ends with:

```swift
    // `carriedTaskId` is the task active at the armed boundary (advance: the armed
    // taskId; switchFromArmed: armedTaskId). `previousWorkTaskId` is the resumed
    // work task when leaving a break; both callers now implement the real DB lookup.
```

Replace those three lines with:

```swift
    // `carriedTaskId` is the task active at the armed boundary (advance: the armed
    // taskId; switchFromArmed: armedTaskId). `previousWorkTaskId` is the resumed
    // work task when leaving a break — both callers compute it via
    // previousWorkTaskId(leavingBreak:asOf:staleFactor:) below; nil when there is
    // nothing sane to resume (no prior work task, stopped session, or stale
    // break), so the fallback is carried.
```

- [ ] **Step 2: Update the stale test comment in PhaseAdvanceTests**

In `Tests/TimeTrackKitTests/PhaseAdvanceTests.swift`, change:

```swift
    // For a work-phase next-phase (accrueAs == nil), must return the carried task
    // when previousWorkTaskId is nil (mirrors advance()'s current nil stub).
```

to:

```swift
    // For a work-phase next-phase (accrueAs == nil), must return the carried task
    // when previousWorkTaskId is nil (the shared no-resume fallback: no prior work
    // task, stopped session, or stale break).
```

- [ ] **Step 3: Sweep for leftover stale references**

Run: `grep -rn "mostRecentWorkTaskId\|nil-returning stub\|nil stub" Sources/ Tests/ DESIGN.md CLAUDE.md`
Expected: no matches in Sources/Tests. If DESIGN.md (PR #4 added a section) mentions `mostRecentWorkTaskId`, update that sentence to name `previousWorkTaskId(leavingBreak:asOf:staleFactor:)` and its staleness rule instead — keep the edit minimal (terminology only, no redesign).

- [ ] **Step 4: Full verification — build + entire test suite**

Run: `swift build 2>&1 | tail -3` → `Build complete!`
Run: `swift test 2>&1 | tail -5` → full suite PASS (134 tests across TimeTrackKitTests + TimeTrackCLICoreTests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "docs(kit): align accrual/resume comments with implemented previousWorkTaskId"
```

---

## Post-implementation (lead/orchestrator responsibilities, not plan tasks)

1. **Code review (agent team):** independent reviewers — (a) correctness & CLAUDE.md invariants (append-only, kit platform-agnostic, reconcile gate untouched, idle invariants), (b) spec conformance (§3 semantics, §5 edge-case table), (c) maintainability. Iterate on objective High/Medium findings only (functionality/maintainability — no nitpicks); re-run `swift test` after each fix round.
2. **Squash:** `git reset --soft main && git commit` → ONE commit (spec + plan + implementation) per the branch workflow.
3. **Push & PR:** push `feature/previous-work-task-resume`, open a PR against `main` with a summary + test evidence. **Do NOT merge — the user reviews every merge to `main`.**
