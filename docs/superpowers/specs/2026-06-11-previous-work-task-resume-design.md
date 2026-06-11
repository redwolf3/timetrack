# Spec — `previousWorkTaskId`: resume the prior work task when leaving a break

- **Date:** 2026-06-11
- **Status:** Approved (design); ready for implementation plan
- **Branch:** `feature/…` (TBD at commit time — one squashed commit before PR, per repo workflow)
- **Scope:** Kit-level only. Implements the `previousWorkTaskId` stub. The Phase 5
  menu-bar app (wiring the dead `IdleMonitor`, real `IdleSource`, `MenuBarExtra`)
  is explicitly **out of scope** for this iteration.
- **Design references:** DESIGN.md (idle/accrual model), CLAUDE.md (append-only
  event log, reconcile gate, two-process caveat, idle/escalation invariants).

## 0. Baseline update (2026-06-11, post-rebase onto `4daf0a7`)

After this spec was approved, the Phase 5 menu-bar app PR (#4, merged 2026-06-03,
commit `4daf0a7`) landed an **unconditional** version of break-resume:
`Store.mostRecentWorkTaskId(excludingBreakTaskId:limit:)` (newest-first query over
the last 50 `start`/`switch`/`phase_advance` events, excluding the break task id),
called from both `Tracker.previousWorkTaskId()` (now a delegating wrapper, no longer
a nil stub) and `switchFromArmed` (inline `prevWorkId` closure). Both call sites are
wired; the basic wart (§1) is fixed on `main`.

**What this spec still changes**, relative to that baseline:
1. **Staleness guard (§3.2)** — the merged version resumes no matter how long the
   break ran. This was an explicit user decision and is absent.
2. **`stop` clears resume (§3.1/§5)** — the merged query ignores `stop` events, so
   it would resume a task from *before* a stopped session. The spec's walk treats
   `stop` as clearing the timeline.
3. **Gating on leaving-break (§4.2)** — the merged version computes the lookup on
   every advance; the spec computes it only when the phase being left is a break
   (`accrueAs == "break"`), which is the only boundary where a resume target is
   meaningful.
4. **Single source of truth (§4)** — the lookup currently exists twice (a Tracker
   wrapper + an inline closure in `switchFromArmed`), duplicating breakId guards.
   The spec's `previousWorkTaskId(leavingBreak:asOf:staleFactor:)` replaces
   `mostRecentWorkTaskId` (which has no other callers and no direct tests) and both
   duplicated lookups.
5. **Tests** — the merged implementation has no direct unit tests; §8 adds them.

The semantics in §3 are unchanged and remain authoritative. References below to
"the stub" describe the pre-`4daf0a7` baseline this spec was originally written
against; the implementation plan targets the rebased baseline.

## 1. Problem

When the cycle advances **out of a break phase back into work** (the next phase
has `accrueAs == nil`), `Store.accrualTaskId(...)` decides the accrual target as
`previousWorkTaskId ?? carriedTaskId`. Two facts combine into a bug:

- `previousWorkTaskId()` is a **nil-returning stub** (`Tracker.swift:296`), and
  `Store.switchFromArmed()` hardcodes `previousWorkTaskId: nil` (`Store.swift:383`).
- The **carried task when leaving a break is the break task itself**:
  `Tracker.armPhase` sets `state = .armed(taskId: breakTask, …)` when a break
  phase expires (`Tracker.swift:206`), so `carriedTaskId == breakTaskId`.

Therefore the first work phase after a break **accrues to the synthetic break
task** until the user manually switches — time that is silently dropped from
reports (break time is never reported). The stub's own comment documents this:
*"the first break→work transition will accrue to break task until user manually
switches."*

Implementing `previousWorkTaskId` is exactly the fix: identify the work task the
user was on before the break and resume it automatically.

## 2. Goals / Non-goals

**Goals**
- Auto-resume the correct work task when leaving a break, in **both** the
  in-process path (`Tracker.advance()`) and the stateless CLI path
  (`Store.switchFromArmed()`), computed from a **single source of truth** so the
  two can never diverge (per the existing `accrualTaskId` contract).
- Guard against resuming a **stale** task after an unusually long break.
- Honor the append-only event-log invariant: the resume target is **derived from
  events at advance time**, never stored as mutable state and never via UPDATE/DELETE.

**Non-goals (deferred)**
- The Phase 5 menu-bar app and any UI prompt for the stale case.
- A dedicated "needs-task" tracker state.
- A CLI `ack`/`advance` command (none exists today; the CLI only crosses an armed
  boundary via `switch`, which always carries an explicit target).
- Making `staleFactor` a per-`Profile` YAML knob (kept a kit constant for now).
- Bounding the event walk for performance (read-all is fine at MVP scale; noted as
  a follow-up).

## 3. Semantics (decided)

### 3.1 Which task resumes — "most-recent non-break task"
Walking the event log backward from the armed boundary, resume the **most recent
task whose category is not `break`**.

- Normal cycle `work(A) → break → work`: resumes **A**.
- Mid-break switch to a real task `work(A) → break → switch(B) → …`: resumes **B**
  (an explicit switch is never overridden).

This is strictly safer than "the task active at break-start": it never silently
discards a deliberate mid-break switch.

### 3.2 Staleness guard — relative to break length
Suppress auto-resume (return `nil`) when the break ran much longer than intended:

```
stale  ⇔  (now − breakRunStartTs)  >  staleFactor × breakPhase.durationMin
```

- `breakRunStartTs` = the timestamp of the `phase_advance` that entered the break
  run we are now leaving (i.e. when the user stopped working).
- `breakPhase.durationMin` = the nominal length of that break phase.
- `staleFactor` = **2.0** (a documented kit constant; see §6).

**Why anchor to break-start, not the work event's timestamp:** the most recent
*work* event is the work-phase entry, which in a normal pomodoro is ~25 min old by
the time the break ends. Anchoring staleness there would falsely flag *every*
normal cycle as stale. `now − breakRunStartTs` measures the **actual break length
vs. its nominal length** — precisely "did this break run too long" — which is what
the idle freeze-at-boundary model produces when the user walks away (the break
phase arms at its deadline and the cycle freezes; on return, `now − breakStart`
reflects the full absence).

### 3.3 Stale / no-resume fallback behavior
When the method returns `nil` (stale, no prior work task, or a stopped session),
`accrualTaskId` falls back to `carriedTaskId`, which when leaving a break is the
**break task**. Consequence: the work phase accrues to the break task until the
user picks a task. Because break time is excluded from reports, this **never
mis-attributes time to a wrong real task** — it costs only a few seconds of
unreported time until the user chooses. A UI prompt / "needs-task" state is
deferred to the Phase 5 app. This matches the pre-existing documented fallback;
the staleness guard's contribution is to *not guess* rather than to force a
mechanism the kit does not yet have.

## 4. Architecture (Approach A — shared Store query)

A single new **read-only** method on `Store` is the source of truth, called by
both advance paths. No schema change; no new event types; no mutation.

```swift
// Store.swift — purely append-only-safe (read only).
// Returns the work task to resume when leaving `breakPhase` back into work, or
// nil when there is nothing sane to resume (no prior work task, the session was
// stopped, or the break ran too long — see §3). Single source of truth shared by
// Tracker.advance() and Store.switchFromArmed() so the two can never diverge.
func previousWorkTaskId(leavingBreak breakPhase: Phase,
                        asOf now: Date,
                        staleFactor: Double = breakResumeStaleFactor) throws -> Int64?
```

Rejected alternatives:
- **B — materialize the resume target on the `phase_arm` event** (like
  `nextPhaseId`): adds a column + migration for a value already derivable, and
  staleness still needs runtime `now`-vs-break-start, so it doesn't remove runtime
  logic. Net schema cost without payoff.
- **C — in-memory `lastWorkTaskId` in Tracker + separate CLI recompute**: two
  implementations = divergence risk; violates the `accrualTaskId` "NEVER diverge"
  contract and the CLAUDE.md two-process caveat.

### 4.1 Algorithm
Reuse the existing `nextActiveTask(after:current:)` (`Store.swift:513`) so the
resume walk stays consistent with `report()` — notably `idle_gap`/`idle_resolve`
are no-ops for the active-task timeline, and `stop` clears it.

Forward-walk all events in `(ts asc, id asc)` order, tracking the active task and
the moment the trailing break run began:

```
let breakId = try breakTaskId()
var active: Int64? = nil
var resumeCandidate: Int64? = nil   // most-recent non-break active task
var breakRunStartTs: Int64? = nil   // ts the trailing break run began

for e in events {
    let next = nextActiveTask(after: e, current: active)
    if next != active {
        if next == breakId {
            if active != breakId { breakRunStartTs = e.ts }   // entering a break run
        } else if next != nil {
            resumeCandidate = next                            // on a non-break work task
            breakRunStartTs = nil
        } else {                                              // stop → session ended
            resumeCandidate = nil
            breakRunStartTs = nil
        }
        active = next
    }
}

// Trailing state determines the answer:
if active != breakId {
    return active            // already on a (non-break) work task, or nil if stopped
                             // — covers work→work advances and mid-break switch to a real task
}
// active == break: we are leaving a break run.
guard let resume = resumeCandidate, let bs = breakRunStartTs else { return nil }
let elapsedMs = Int64(now.timeIntervalSince1970 * 1000) - bs
let thresholdMs = staleFactor * Double(breakPhase.durationMin) * 60_000
return Double(elapsedMs) > thresholdMs ? nil : resume
```

Notes:
- "Break task" is identified via `breakTaskId()` (exactly one row, category
  `break`, ensured at init) — consistent with the rest of the kit.
- The method is called at the armed boundary **before** the work-phase
  `phase_advance` is appended, so the trailing active task is the break task in the
  normal case.

### 4.2 Wiring

**`Tracker.advance()`** (`Tracker.swift:209`): bind the armed (break) phase from the
state, compute `prev` only when actually leaving a break, and pass it in. Delete
the private nil stub `previousWorkTaskId()`.

```swift
guard case let .armed(taskId, armedPhase, _, _) = state, let iter = iterator else { return }
…
let prev: Int64? = (armedPhase.accrueAs == "break")
    ? (try? store.previousWorkTaskId(leavingBreak: armedPhase, asOf: Date()))
    : nil
let nextTaskId: Int64 = (try? store.accrualTaskId(
    forNextPhase: newPhase, carriedTaskId: taskId, previousWorkTaskId: prev)) ?? taskId
```
(The historic `try?`-with-fallback-to-`taskId` is preserved.)

**`Store.switchFromArmed()`** (`Store.swift:343`): after resolving `nextPhase`,
resolve the armed (leaving) phase too and compute `prev` identically, replacing the
hardcoded `nil` at line 383:

```swift
let leavingPhase = resolvePhase(id: armedPhaseId, in: profile)
let prev: Int64? = (leavingPhase?.accrueAs == "break")
    ? try previousWorkTaskId(leavingBreak: leavingPhase!, asOf: Date())
    : nil
let accrual = try accrualTaskId(forNextPhase: nextPhase, carriedTaskId: armedTaskId,
                                previousWorkTaskId: prev)
```

**`accrualTaskId` signature is unchanged.** The three existing `accrualTaskId` unit
tests (`PhaseAdvanceTests.swift:262/282/301`) remain valid as-is.

## 5. Edge cases

| Case | Behavior |
|---|---|
| Normal `work(A) → break → ack` | Resume **A**; report attributes the work phase to A. |
| Mid-break switch `… → break → switch(B) → ack` | Trailing active is B (non-break) → resume **B**. |
| Stale (break ran > 2× nominal) | Return `nil` → accrue to break until user picks (§3.3). |
| Idle during break | `idle_gap`/`idle_resolve` are no-ops in the walk; `now − breakStart` reflects the full absence → typically resolves to stale. Consistent with the freeze-at-boundary idle model. |
| `long_break` override phase | A break phase like any other; staleness uses its own `durationMin` (15/20). |
| Stopped session before the break | `stop` clears `resumeCandidate` → `nil`. |
| No prior work task (started in break) | `resumeCandidate == nil` → `nil`. |
| `work → work` advance (default profile) | Guarded off (leaving phase isn't a break) → `prev = nil`; or, if called, trailing active is the work task → returns it (= carried, no-op). |
| Profile change mid-break | Staleness uses the break phase actually entered (resolvable in both paths); resume still walks the log. No special-casing for MVP. |

## 6. Configuration

`breakResumeStaleFactor: Double = 2.0` — a single documented constant in
`TimeTrackKit`. Chosen over a fixed-minutes knob (the user's "relative to break
length" decision) and over an absolute config field, to keep the threshold
self-scaling per profile with no new YAML surface. Promotable to a `Profile`
optional field later if needed. `now` is an injected parameter (mirrors
`tick(at:)`) so staleness is deterministically testable.

## 7. Invariant compliance (CLAUDE.md)

- **Append-only:** the feature is a pure read query; it appends/updates/deletes
  nothing. The corrected accrual target flows into the *new* `phase_advance` event
  that `advance()`/`switchFromArmed()` already append.
- **Platform-agnostic kit:** no Apple-UI imports; pure Swift + GRDB read.
- **No business logic in views:** logic lives in the kit.
- **Reconcile gate untouched:** resume only selects an accrual *task*; it makes no
  reconcile/binding decision and does not auto-bind anything.
- **Idle invariants untouched:** the walk treats idle events as no-ops, matching
  `report()`; no change to segmentation or escalation.

## 8. Testing strategy

TDD: write failing tests first, then implement.

**Unit — `Store.previousWorkTaskId(leavingBreak:asOf:staleFactor:)`** (new test
file, e.g. `PreviousWorkTaskTests.swift`, using existing helpers `makeStore`,
`makeTask`, `appendEvent`):
1. Normal resume: log `work(A) → break`; `asOf` within threshold → returns A.
2. Stale: same log; `asOf` beyond `2 × break.durationMin` → `nil`.
3. Boundary: `asOf` exactly at threshold and just over/under (off-by-one guard).
4. Mid-break switch: `work(A) → break → switch(B)` → returns B (not stale).
5. Stopped session: trailing `stop` → `nil`.
6. No prior work task → `nil`.
7. `long_break` override duration drives the threshold correctly.

**Integration — `Tracker.advance()`** (work→break profile; drive arming with
`tick(at:)`):
8. Drive `start(A) → tick(arm) → advance` into break, then `tick(arm) → advance`
   out of break (within threshold of real time) → assert resulting active task ==
   A and `report()` attributes the work-phase interval to A (the wart is fixed).

The **stale fallback** is not exercised through `advance()` (which uses real
`Date()` and would require injecting a clock); it is covered authoritatively by the
unit tests above (#2/#3, injected `asOf`). `advance()`/`switchFromArmed()` keep
their `Date()` call — staleness is a property of the `Store` method under test.

**Parity — `advance()` vs `switchFromArmed()`:**
9. Given an identical event log at an armed break boundary, assert both paths
   select the same accrual task for the implicit `phase_advance` (the
   "never diverge" guarantee).

**Regression:** the three existing `accrualTaskId` tests stay green unchanged;
run the full `swift test` suite (do not infer green from inspection — per
`[[tests-must-actually-compile]]`).

## 9. File-by-file changes

- `Sources/TimeTrackKit/Store.swift`
  - Add `breakResumeStaleFactor` constant.
  - Add `previousWorkTaskId(leavingBreak:asOf:staleFactor:)`.
  - `switchFromArmed`: compute and pass `prev` (replace hardcoded `nil`).
- `Sources/TimeTrackKit/Tracker.swift`
  - `advance()`: bind armed phase, compute `prev`, pass into `accrualTaskId`.
  - Remove the private nil-stub `previousWorkTaskId()`.
- `Tests/TimeTrackKitTests/PreviousWorkTaskTests.swift` (new) — unit + parity.
- `Tests/TimeTrackKitTests/PhaseAdvanceTests.swift` — add the `advance()`
  integration tests; update the now-stale comment at ~line 281 that references the
  "nil stub" (the stub is gone). Existing `accrualTaskId` assertions unchanged.

## 10. Open follow-ups (not in this iteration)
- Bound the event walk (e.g. since the last `stop`) if logs grow large.
- Surface the stale / no-resume case in the Phase 5 app (prompt to pick a task).
- Consider promoting `staleFactor` to a `Profile` field if per-profile tuning is wanted.
- Consider a CLI `ack` command that benefits from this resume logic.
