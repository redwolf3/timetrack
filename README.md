# TimeTrack

Minimalist macOS menu-bar time tracker. Append-only event log, configurable
phase profiles (default check-in / Pomodoro / custom), ARMED-and-wait at every
phase boundary.

## Build

Requires Xcode 15+ and macOS 14+ (for `MenuBarExtra`).

`swift build` only produces a bare `TimeTrackApp` executable — there is no
`.app` bundle on disk. A bare executable has no bundle identifier, which
disables system notifications and launch-at-login. Use the bundling script to
wrap it in a real, ad-hoc-signed `TimeTrack.app`:

```sh
./tools/make-app.sh           # → .build/bundle/TimeTrack.app
./tools/make-app.sh install   # also copies it to /Applications
```

To iterate during development you can run the executable directly with
`swift run TimeTrackApp`, or open `Package.swift` in Xcode and Run. Run that
way the binary may have no bundle identifier, in which case system
notifications are skipped (the app guards on a non-nil bundle id). Use the
`.app` when you want notifications to work reliably.

Gatekeeper: a locally built app is not quarantined, so it opens without a
right-click → Open dance. The bundle is ad-hoc signed for local use only — it
is **not** notarized, so it is not meant for redistribution.

Launch-at-login is not yet automated (tracked as #21). For now add it manually:
System Settings → General → Login Items → **+** → select TimeTrack.

## Data location

```
~/Library/Application Support/timetrack/
  events.db          SQLite, append-only event log + task table
  profiles.yaml      User-editable phase profiles
  tasks.yaml         User-editable task list (mirrored to DB on change)
  known_tasks.yaml   User-editable Known Tasks registry — the reconcile spine
```

`known_tasks.yaml` bulk-defines the valid reconciliation targets (the JIRA keys
time can be bound to). Each entry is a `description` plus an optional `jiraKey`;
omit the key for a provisional entry. On load it upserts idempotently: keyed
entries are matched by `jiraKey`, keyless ones by `description`; adding a key to
a description that already exists provisionally **promotes** it (append-only —
existing bindings follow automatically). Entries removed from the file are left
in place; retiring is an explicit `timetrack known retire`.

```yaml
known_tasks:
  - jiraKey: PROJ-123
    description: Build the widget
  - description: Misc unsorted work    # provisional — no key yet
```

`events.db` is the source of truth. YAML files are convenience for editing.

## Architecture

Five files, ~500 lines:

- `App.swift`         MenuBarExtra root, popover, hotkey
- `Tracker.swift`     State machine. The interesting file.
- `Store.swift`       GRDB wrapper. Schema, append, report queries.
- `Profile.swift`     YAML decode + cycle iterator + ARMED logic
- `Sounds.swift`      NSSound wrappers

## State model

```
IDLE                       no active task
  └─ start(task) ─────────► TRACKING

TRACKING(task, phase, t0)  timer running, accruing to task
  ├─ switch(task') ───────► TRACKING(task', same phase, t0)  [logs 'switch']
  ├─ stop() ──────────────► IDLE  [resets cycle]
  └─ phase timer expires ─► ARMED(task, phase, next_phase)
                            [logs 'phase_arm', plays sound, icon changes,
                             accrual continues against task]

ARMED(task, phase, next)
  ├─ ack() ───────────────► TRACKING(maybe_break_task, next_phase, now)
  │                         [logs 'phase_advance']
  ├─ extend(N) ───────────► TRACKING(task, phase, t0)  [deadline += N]
  │                         [logs 'phase_extend']
  ├─ switch(task') ───────► implicit ack, then switch
  └─ stop() ──────────────► IDLE  [resets cycle]
```

## Event types

```
start            begin tracking a task
stop             stop all tracking (resets cycle counter)
switch           task change while tracking
phase_arm        timer reached duration, awaiting ack
phase_advance    user acknowledged, moved to next phase
phase_extend     +N min added to current phase
profile_change   active profile changed
interruption     user-logged note, no state change
```

## Reporting

Time on task = sum of intervals between consecutive events where `task_id` was
active. Computed at query time, never stored. See `Store.report(day:)`.

Edits to history: append a correction event, never UPDATE/DELETE. Not exposed
in v1 UI; manual SQL only.
