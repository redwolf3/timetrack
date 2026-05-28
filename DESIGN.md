# TimeTrack — Design & Decisions

Menu-bar time tracker. Loose capture, strict reconciliation. Append-only event
log; all corrections (idle reattribution, reconcile bindings) are overlay events
applied at report time, never mutations.

## Core principles

1. **Capture is loose, reporting is strict.** All day you track against whatever
   — ad-hoc names, overhead, half-formed tasks — with zero friction. Before a
   submittable report, every loose task with time must bind to a JIRA key.
2. **Append-only.** Nothing is ever UPDATEd or DELETEd. Mistakes are fixed by
   appending correction events. The DB is diff-able and recoverable.
3. **Never auto-advance.** Phase boundaries ARM and wait for acknowledgment.
4. **Presence-gated, flow-protecting.** The tool never nags into an empty room
   and never breaks genuine flow; it escalates only when you're present with an
   unresolved decision after returning from idle.

## State machine

```
IDLE → start → TRACKING(task, phase, deadline)
TRACKING → switch → TRACKING(task', same phase)
TRACKING → stop → IDLE (resets cycle)
TRACKING → timer expires → ARMED (accrual continues; sound; icon change)
ARMED → ack → TRACKING(next phase)
ARMED → extend(N) → TRACKING(same phase, deadline += N)
ARMED → switch → implicit ack, then switch
ARMED → stop → IDLE (resets cycle)
```

Idle is orthogonal, fires from TRACKING or ARMED.

## Idle model (locked)

- Idle below `wiggleRoomMin` (default 5) ignored entirely.
- Idle ≥ `idleThresholdMin` (default 5) opens an episode. Idle-start recorded as
  `now − idleSeconds`, not detection time.
- Cycle **freezes at the first unacked armed boundary** while idle — no phantom
  phases, no break time you never took.
- On return, the episode splits into **two segments**:
  - `inPhase`  [idleStart, armBoundary] — idle within the phase you were in
  - `overrun`  [armBoundary, return]    — past the unacked boundary
  - If the phase was **already armed** when idle began, `inPhase` collapses and
    the whole episode is one `overrun` segment.
- **Strict in-window break rule:** if the frozen phase was a break, `inPhase`
  auto-resolves to break (no prompt, no idle_resolve event — the base walk
  already attributed it to break).
- Each non-auto segment goes to **limbo** (un-attributed) and **forces a
  decision**. Per-segment classification: keep on task / break / move to… /
  discard. Each emits its own `idle_resolve` over a disjoint interval.

## Escalation (locked)

Presence-gated: rungs advance on cumulative **active-seconds since return**, not
wall clock. Pauses when input stops; resumes when you sit back down. You cannot
wait it out by leaving.

- **flowArm curve** (decision pending but you never went idle — true flow):
  capped at icon + sound. No notifications. Protect flow.
- **idleReturn curve** (returned from idle, unresolved segments): full ramp →
  color/sound → assertive sound → notification → notification re-posting on a
  cadence. Ceiling is persistent notification, **never** a focus-steal modal.

Idle gaps escalate harder than phase arms because an unresolved gap corrupts the
timesheet, whereas ignoring a phase arm is a valid "leave me in flow" choice.

## Reconciliation (locked)

- Tasks are **fluid until reconciled.** An ad-hoc task can become a real task
  mid-processing; its time follows the conversion.
- **`reconcile_bind`** event maps a loose task → JIRA key, with
  `bindKind ∈ {existing, new, overhead}` (metadata for visibility only).
  Last-write-wins; re-binding allowed.
- **Two report modes:**
  - `report(day:)` — raw, shows loose tasks as tracked. Diagnostic.
  - `reconciledReport(from:to:)` — applies bindings, rolls loose time into JIRA
    keys. **Throws if any task is unreconciled** (the gate).
- **Overhead is explicit, per task, every time.** Every sprint has an overhead
  JIRA, but nothing is ever auto-bound to it. The user presses "report as
  overhead" per task and supplies the current sprint's overhead key at reconcile
  time. No silent catch-all.
- **Unreconciled tasks never auto-archive.** They are debt, not clutter.
  Reconciled tasks become archive-eligible.

## Task sources

Picker merges, deduped by `code` (JIRA key wins):
1. `tasks.yaml` — hand-edited durable tasks (overhead, recurring projects).
2. Ad-hoc — `[+ New task…]`, written to DB, immediately selectable.
3. `jira_cache.json` — written by the morning cron (see below). v1 reads if
   present; absence is fine.

## JIRA integration (post-MVP; contract fixed now)

Direct REST + launchd cron, **not** MCP (once-a-day read doesn't justify an MCP
runtime). Tracker only ever reads `jira_cache.json` — one-way dependency, tracker
never knows JIRA exists.

- Endpoint: `POST /rest/api/3/search/jql`
  (legacy `/rest/api/3/search` is removed from Jira Cloud — do not use).
- Pagination: `nextPageToken` (not `startAt`).
- JQL: `assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC`
- Fields: `key,summary,status` only (keep payloads small / rate-limit friendly).
- Auth: API token in `Authorization` header. Token lives outside the repo
  (keychain or env for the cron), never in tracker config.
- Output contract: `jira_cache.json` = `[{ "key": "...", "summary": "...",
  "status": "..." }]`. The current sprint overhead JIRA is just another row.

## Deferred backlog (post-MVP)

- **Interval-level bind / split / re-assign.** v1 is task-level: one loose task →
  one JIRA. Splitting a single task's intervals across multiple JIRAs after the
  fact reuses the existing `rangeStart/rangeEnd` fields on a bind event — additive,
  no rework.
- **Finer idle sub-segmentation.** Breaking a break-idle or armed-overrun into
  multiple sub-segments for post-hoc recording, beyond the two-segment model.
  Also additive (more `idle_resolve` events over sub-intervals).
- **Window-report caching.** `unreconciled`/`reconciledReport` re-derive per-day
  across the window; fine for sprint length, wasteful for quarters. Add a
  materialized daily-total cache if windows grow large.
- **Manual history correction UI.** The append-a-correction-event capability
  exists in the schema; no UI in MVP (manual SQL only).
- **DevMux task-switch feed.** Optional one-way DevMux → tracker socket/ndjson
  so active coding session auto-switches the tracked task. Tracker stays
  standalone; DevMux writes events if it wants to.
- **Screenshot recall** — explicitly rejected for v1 (data-exfiltration risk on a
  work machine). Window-title history via idle/event log covers recall instead.
