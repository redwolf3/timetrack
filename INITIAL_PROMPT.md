# TimeTrack — Build Plan (INITIAL_PROMPT)

This file drives the build. Execute **one phase per session**, stop at the gate,
open a PR (cloud) or commit for review (local). Do not run ahead. `DESIGN.md` is
the authority on behavior; `CLAUDE.md` is the authority on conventions and
invariants. When this prompt and your instinct disagree, re-read DESIGN.md and
ask rather than guess.

## Environment split — READ FIRST

- **Cloud sessions run on Linux.** They can build and test `TimeTrackKit` and
  `timetrack-cli`, run the XCTest suite, and write SwiftUI code as text — but
  they **cannot compile `TimeTrackApp`** (needs AppKit/macOS) and **cannot test
  idle detection** (needs a live macOS session).
- **Local Claude Code (on the Mac) handles anything that must compile against
  Xcode/AppKit or exercise a real session.**

Each phase is tagged **[CLOUD-SAFE]** or **[MACOS-REQUIRED]**. Cloud sessions
must stop at the first MACOS-REQUIRED phase.

## State of the scaffold

The repo ships with a partial skeleton under `Sources/`. It is **shape, not
finished code** — it expresses the data model and algorithms but has NOT been
compiled. Treat compiler errors as expected starting work, not as surprises.
The one known structural task is called out in Phase 1.

---

## Phase 1 — TimeTrackKit core compiles & tests green  [CLOUD-SAFE]

**Goal:** `swift build` and `swift test` succeed on Linux for the kit.

The blocker, stated plainly (see the NOTE atop `Tracker.swift`): `Tracker`
currently depends on Combine/SwiftUI (`@Published`, `ObservableObject`) and calls
`Sounds.play` (NSSound). None of that compiles on Linux. **Decouple it:**

1. Replace `@Published`/`ObservableObject` with a framework-free observation
   mechanism — an `AsyncStream<TrackerState>` the app subscribes to, plus plain
   getters. No Combine, no SwiftUI in the kit.
2. Replace every `Sounds.play(name)` with an **emitted effect**. The kit decides
   *what* should happen (`.playSound("Glass")`, `.postNotification`, `.setIcon(…)`)
   and surfaces it; the app performs the side effect. Define an `Effect` enum and
   an effect stream/callback. The kit must contain zero side-effecting UI calls.
3. Verify `Store`, `Profile`, `IdleMonitor`, `IdleSource` compile. Fix the
   `IdleSegment.Kind`/access-level mismatches the migration likely introduced
   (some types were made `public` but their members were not).

**Gate:** kit builds on Linux, no Apple-UI imports anywhere in `TimeTrackKit`.
PR with green `swift build`.

## Phase 2 — State-machine & idle tests  [CLOUD-SAFE]

Flesh out `Tests/TimeTrackKitTests` (a starter is provided). Cover, using
`FakeIdleSource` (no real session needed):

- Phase ARM never auto-advances; ack advances; extend re-arms with new deadline.
- Switch during ARMED = implicit ack then switch.
- Stop mid-cycle resets the cycle.
- Idle below `wiggleRoomMin` produces no episode.
- Idle ≥ threshold opens an episode with idleStart = now − idleSeconds.
- Two-segment split: in-phase + overrun; collapse to single overrun when the
  phase was already armed at idle start; single in-phase when return precedes
  the boundary.
- Strict in-window break: break-phase in-phase segment auto-resolves, emits NO
  `idle_resolve`.
- Escalation is presence-gated: rungs advance only on active-seconds; pause when
  idle; never a modal.

**Gate:** `swift test` green on Linux, meaningful coverage of the above. PR.

## Phase 3 — Reconcile, registry & report tests  [CLOUD-SAFE]

Test the reconcile spine in `Store`:

- Known Tasks registry: add (provisional when no key), promote (propagates to
  existing binds — bind references the registry id, not a key string), retire.
- Two-condition gate: `reconciledReport` throws `.unbound` for ad-hoc-with-time
  and `.provisional` for bound-but-keyless; passes only when both clear.
- Idle reattribution math: a resolved segment subtracts from the original task
  and adds to the chosen target; discard subtracts from all; midnight-straddling
  segment clamps per day. Verify totals across a multi-day window.

**Gate:** green. PR. **This is the last fully cloud-verifiable phase.**

## Phase 4 — timetrack-cli  [CLOUD-SAFE to write, MACOS to fully verify]

Thin client over `TimeTrackKit`: `start <known-id|--adhoc "name">`, `stop`,
`switch`, `status`, `report [--from --to]`, `known list|add|promote|retire`,
`reconcile`. Opens the same `events.db` (WAL mode; see CLAUDE.md on the
two-process caveat). Cloud can build/test logic; final DB-concurrency behavior
verified locally.

**Gate:** builds, logic tested. PR.

## Phase 5 — TimeTrackApp menu bar  [MACOS-REQUIRED]

Local Claude Code only. `MenuBarExtra` root; popover with the Known Tasks fast
path + ad-hoc add; icon state machine (neutral/tracking/armed/break/over) driven
by the kit's `Effect` stream; subscribe to `TrackerState`. Provide the real
`IdleSource` here: `CGEventSourceSecondsSinceLastEventType(.combinedSessionState,
CGEventType(rawValue: ~0)!)` — this is the code removed from the kit; it lives in
the app and is injected into `IdleMonitor`. Wire `Sounds.play` as the handler for
`.playSound` effects.

**Gate:** builds in Xcode, runs, idle detection works in a real session.

## Phase 6 — Notifications, login-item, polish  [MACOS-REQUIRED]

`UserNotifications` for the escalation ceiling; `SMAppService` login-item;
the reconcile gate screen (two failure modes shown distinctly); prep mode UI
(populate/promote/retire Known Tasks). Local only.

**Gate:** end-to-end usable.

## Phase 7 — tools/jira-sync  [CLOUD-SAFE]

Separate small tool (Go or Swift; see DESIGN.md). Hits
`POST /rest/api/3/search/jql` (NOT the removed `/rest/api/3/search`), paginates
via `nextPageToken`, JQL `assignee = currentUser() AND statusCategory != Done`,
fields `key,summary,status`, writes `jira_cache.json` per the DESIGN contract.
Token from keychain/env, never committed. The app/CLI only ever READ the cache.

**Gate:** produces a valid cache file against the documented contract. PR.

---

## Rules for every phase

- Append-only event log is sacred: never UPDATE/DELETE events; corrections are
  new events. (CLAUDE.md.)
- No business logic in SwiftUI views — all of it in `TimeTrackKit`.
- Stop at the gate. One phase, one PR. Wait for review.
- If a phase reveals a DESIGN.md gap, note it in the PR and ask — do not invent
  behavior, especially around the reconcile gate or idle segmentation.
