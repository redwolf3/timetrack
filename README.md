# TimeTrack

Minimalist macOS menu-bar time tracker. Append-only event log, configurable
phase profiles (default check-in / Pomodoro / custom), ARMED-and-wait at every
phase boundary.

## Build

Requires Xcode 15+ and macOS 14+ (for `MenuBarExtra`).

```sh
swift build -c release
cp -R .build/release/TimeTrack.app /Applications/
```

Or open `Package.swift` in Xcode and Run.

First launch: drag to `/Applications` so launch-at-login works cleanly. No
notarization in v1 — right-click → Open the first time to bypass Gatekeeper.

## Data location

```
~/Library/Application Support/TimeTrack/
  events.db          SQLite, append-only event log + task table
  profiles.yaml      User-editable phase profiles
  tasks.yaml         User-editable task list (mirrored to DB on change)
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
