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

## Report-layer time normalisation (post-MVP, design partially locked)

Raw event data is never modified. Normalisation is applied only at report
generation time, in three ordered passes:

1. **Per-interval drop/floor.** For each contiguous interval on a task:
   - < 30 s → **dropped** entirely (does not count toward aggregate).
     The switch is still visible in the raw diagnostic report.
   - ≥ 30 s → **rounded up** to 1 minute minimum.
   Rationale: sub-30-second switches are accidental taps; ≥30 s carries real
   context-switching cost worth crediting.

2. **Per-task cumulative rounding.** After summing all surviving intervals for a
   task, round **up** to the nearest 15 minutes.
   Example: 25 m → 30 m, 31 m → 45 m.

3. **Sub-15-minute aggregate prompt (implementation detail TBD).** At the
   end-of-day / next-day reporting boundary, any task whose post-rounding total
   is still < 15 minutes (i.e. it only accumulated small surviving chunks) is
   surfaced to the user with three options:
   - **Record as 15 min** — credit the full minimum billable unit.
   - **Drop** — discard all time for this task from the day's report.
   - **Roll into aggregate** — merge into a configurable catch-all bucket
     (e.g. "miscellaneous / overhead").
   The prompt fires once per affected task per day. Exact UI and trigger
   mechanism to be decided at implementation time.

All thresholds (30 s drop floor, 1 min credit floor, 15 min rounding quantum)
are report-time parameters — configurable per invocation, not baked into events.
`reconciledReport` will gain `dropBelowSec: Int`, `minIntervalMin: Int`, and
`roundToMin: Int` parameters. The raw `report(day:)` diagnostic mode applies no
normalisation and shows all intervals including sub-30-second ones.

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
- **Quit / Restart menu items.** Standard macOS menu-bar affordances; Phase 6.
- **History / recording review pop-up.** In-app view of today's and recent
  intervals; Phase 6. Raw data is always accessible via `timetrack report` and
  directly via the SQLite DB at `~/Library/Application Support/timetrack/events.db`.
- **JIRA sync UI + daily reminders.** Phase 7 delivers the `jira-sync` CLI tool
  that writes `jira_cache.json`. Phase 8 (planned) adds: in-app Known Task
  promotion from the JIRA cache, a start-of-day sync prompt, an end-of-day
  summary with time-recording confirmation, and a once-per-day reminder
  notification to log time against JIRAs. The app never writes to JIRA directly —
  it surfaces the data and the user confirms.
