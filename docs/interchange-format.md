# TimeTrack interchange format v1

The stable, machine-readable contract for getting data **into** and **out of**
TimeTrack. It exists so that users can build their own import/export machinery —
JIRA worklog uploaders, timesheet bridges, spreadsheet pipelines — without
reading `events.db` directly or screen-scraping CLI output.

`DESIGN.md` owns *what the tool does*. `CLAUDE.md` owns *how the code is
written*. This file owns *the shape of data crossing the boundary*.

---

## 1. Scope

**In scope.** Three record types, each with a JSON and a CSV encoding:

| Type | Direction | What it is |
|---|---|---|
| `known_task` | export + import | The Known Tasks registry — the reconcile spine, the set of valid binding targets |
| `worklog` | export + import | Derived, reconciled time ready to be recorded against real tickets |
| `event` | export only | The raw append-only log, lossless, for archival and debugging |

**Non-goals.**

- This is not a JIRA client. TimeTrack never writes to JIRA. Export produces a
  file; a user-owned tool decides what to do with it. (`DESIGN.md`: *"The app
  never writes to JIRA directly — it surfaces the data and the user confirms."*)
- This does not replace `known_tasks.yaml` / `tasks.yaml` / `profiles.yaml`.
  Those remain the hand-editing surface. This is the programmatic surface.
- `event` import is deliberately excluded. See §7.3.

---

## 2. What is and is not a contract

**Contract** — breaking changes require a version bump:

- JSON field names, types, and null semantics.
- CSV header names and column order.
- CLI exit codes (§6.4).
- The `jira_cache.json` shape, already frozen in `DESIGN.md`:
  `[{ "key": "...", "summary": "...", "status": "..." }]`.

**Not a contract** — may change at any time, do not parse:

- Human-readable CLI output (`timetrack report`, `timetrack status`, and every
  command without `--format`). It is column-padded prose with durations
  formatted as `"1h 23m"`, intended for eyes only.
- The SQLite schema. It is append-only and therefore safe to *read* without
  racing a writer, but it is an implementation detail and will change.
  Prefer `timetrack export events` over `SELECT * FROM events`.

---

## 3. Common conventions

**Encoding.** UTF-8, no BOM. LF line endings.

**Durations** are always integer **seconds**, never a formatted string. A
consumer that needs `"1h 30m"` formats it themselves.

**Timestamps** are ISO-8601 with an explicit UTC offset:
`2026-07-24T09:12:00-05:00`. TimeTrack stores unix epoch **milliseconds**
internally (`Event.ts`); export converts, import accepts either ISO-8601 or a
bare integer epoch-millis.

**Dates** (`date` fields) are `YYYY-MM-DD` in the **local calendar**, matching
the report layer, which slices days with `Calendar.current.startOfDay`. A
worklog row's `date` is the local day the time was worked, not a UTC day.

**Null.** JSON uses `null`. CSV uses the **empty string**. An empty CSV cell and
a JSON `null` mean the same thing. There is no sentinel string (never `"NULL"`,
never `"-"`).

**Booleans.** JSON `true`/`false`. CSV lowercase `true`/`false`.

### 3.1 JSON encoding

A single top-level object with an envelope and a `records` array:

```json
{
  "format": "timetrack.worklog",
  "version": 1,
  "generated": "2026-07-26T18:04:11-05:00",
  "window": { "from": "2026-07-20", "to": "2026-07-26" },
  "records": [ ... ]
}
```

`format` is one of `timetrack.known_task`, `timetrack.worklog`,
`timetrack.event`. `window` is present only for windowed exports (`worklog`,
`event`) and omitted for `known_task`.

On **import**, the envelope is validated: an unknown `format` or a `version`
greater than the running binary supports is a hard error, not a warning. A bare
top-level array is also accepted as a convenience for hand-written input, and is
interpreted as `version: 1` of whichever type the command implies.

### 3.2 CSV encoding

RFC 4180. Comma-delimited, `"` quoting, doubled `""` for a literal quote.

**The header row is the version identifier.** There is no `format_version`
column repeated on every row — that would make the file awkward in awk, pandas,
and Excel, which is the whole reason CSV is offered. The exact header strings
below define v1; a future v2 changes the header. On import, an unrecognised
header set is a hard error naming the mismatched columns.

Columns must appear in the documented order. Extra trailing columns are ignored
with a warning (so a user can annotate an exported file and re-import it).

**List-valued fields** (only `capture_tasks` today) are encoded in CSV as a
single cell of `;`-separated values: `widget spike;widget`. A `;` inside a task
name is escaped as `\;`. In JSON the same field is a real array.

---

## 4. `known_task` — the registry primer

Mirrors the `KnownTask` struct in `Sources/TimeTrackKit/Store.swift`.

### 4.1 Fields

| Field | Type | Notes |
|---|---|---|
| `id` | int \| null | Registry id. Omitted/null on import when creating. Stable across promotion. |
| `jira_key` | string \| null | `null` **iff** provisional. |
| `description` | string | Required. The human label; also the match key for keyless entries. |
| `provisional` | bool | Derived: `jira_key == null`. Exported for clarity; **ignored on import** (the key's presence decides). |
| `retired` | bool | Retired entries are excluded from export unless `--include-retired`. |
| `created` | timestamp | Export only; ignored on import. |

JSON:

```json
{ "format": "timetrack.known_task", "version": 1,
  "generated": "2026-07-26T18:04:11-05:00",
  "records": [
    { "id": 17, "jira_key": "PROJ-123", "description": "Build the widget",
      "provisional": false, "retired": false, "created": "2026-06-02T08:15:00-05:00" },
    { "id": 24, "jira_key": null, "description": "Misc unsorted work",
      "provisional": true, "retired": false, "created": "2026-07-01T09:00:00-05:00" }
  ] }
```

CSV — header row defines v1:

```csv
id,jira_key,description,provisional,retired,created
17,PROJ-123,Build the widget,false,false,2026-06-02T08:15:00-05:00
24,,Misc unsorted work,true,false,2026-07-01T09:00:00-05:00
```

### 4.2 Import semantics

**Import MUST reuse the existing upsert logic in
`Sources/TimeTrackKit/KnownTasksLoader.swift`.** It already implements exactly
the semantics below. A JSON/CSV reader must decode to the same intermediate
representation the YAML reader produces and hand off to the shared upsert. Do
**not** write a second upsert path — that is how the two silently diverge.

**Diagnostics must name the real input file.** Every case of
`KnownTasksLoader.ValidationError` currently hardcodes the prefix
`known_tasks.yaml:` into its message. Reusing the loader as-is would tell a user
importing `sprint-42.csv` that something is wrong with `known_tasks.yaml`, which
is actively misleading — they would go and edit the wrong file. `import known`
must either wrap these errors and re-prefix them with the actual path, or the
loader must be refactored to take the source name as a parameter. The latter is
cleaner and keeps one message set; either is acceptable, but shipping the
hardcoded prefix is not.

Restating the rules the loader enforces, so a reviewer can check the handoff.
Note the two branches are **not** symmetric: description is an identity key only
*among provisional rows*. A description shared with a keyed row does not match.

**Record WITH a `jira_key`:**

1. Match an existing entry **by key** → description updated in place if changed,
   otherwise no-op. (Description is a plain label, not history, so this is the
   one permitted in-place update — it is invisible to the event overlay.)
2. Else match a **provisional** entry by exact description → **promotion**.
   Appends a `known_task_promote` event. Existing bindings follow automatically,
   because bindings reference the registry `id`, never a key string
   (`CLAUDE.md` invariant 5).
3. Else insert a new keyed, non-provisional entry.

**Record WITHOUT a `jira_key`:**

4. Match a **provisional** entry by exact description → no-op. A keyed entry
   with the same description is *not* a match, and the record inserts a new
   provisional row alongside it.
5. Else insert a new provisional entry.

**Both branches:**

6. Entries **absent** from the file are left untouched. Import never retires and
   never deletes. Retiring stays an explicit `timetrack known retire`.
7. Two ambiguity errors, both hard failures naming the conflicting registry ids:
   `ambiguousJiraKey` when a `jira_key` matches multiple registry rows (there is
   no UNIQUE constraint, so duplicates can pre-exist via the CLI), and
   `ambiguousProvisionalDescription` when a description matches multiple
   *provisional* rows. Duplicate descriptions across a keyed and a provisional
   row are **not** ambiguous and must not error.
8. Within-file validation runs before any write, matching the YAML parser: empty
   or whitespace-only `description` is an error; a `jira_key` repeated within the
   file is an error; a description repeated among *provisional* records in the
   file is an error. The same description may appear once keyed and once
   provisional without colliding.
9. Ingest is single-pass over a snapshot that is **kept in sync as it goes** — a
   row promoted earlier in the pass must appear non-provisional to later records,
   or idempotency breaks (a subsequent keyless record for the same description
   would spuriously re-insert). Reusing the loader gets this for free; it is
   called out because it is the specific trap a reimplementation falls into.

**Round-trip guarantee (acceptance criterion).** For any registry state:

```
timetrack export known --format json > a.json
timetrack import known a.json          # must report zero changes
timetrack export known --format json > b.json
diff a.json b.json                     # must be empty modulo `generated`
```

The same must hold for `--format csv`, and exporting as JSON then importing must
be equivalent to exporting as CSV then importing.

---

## 5. `worklog` — reconciled time out

The primary export. One record is one unit of time attributable to one ticket.

### 5.1 Grain

`--by day` (**default**) — one record per `(local calendar day, jira_key)`. This
matches what a JIRA worklog POST wants: a `started` timestamp plus
`timeSpentSeconds`.

`--by key` — one record per `jira_key` across the whole window. `date` is null,
`started` is the first interval in the window.

`--by interval` — one record per contiguous tracked interval, lossless. `seconds`
is the raw interval length; **normalisation is not applied** at this grain (see
§5.4), so `raw_seconds == seconds`. For consumers that want to do their own
aggregation.

### 5.2 Fields

| Field | Type | Notes |
|---|---|---|
| `date` | date \| null | Local calendar day. Null when `--by key`. |
| `started` | timestamp | Start of the first interval in this record. Feeds JIRA's `started`. |
| `ended` | timestamp | End of the last interval. `--by interval` only; null otherwise. |
| `seconds` | int | **Normalised** total — the number to record. See §5.4. |
| `raw_seconds` | int | Pre-normalisation truth, so rounding is auditable. |
| `jira_key` | string \| null | Null **iff** `status != "reconciled"`. |
| `known_task_id` | int \| null | Registry id — the durable binding target. Null if unbound. |
| `description` | string \| null | Registry description at export time. |
| `capture_tasks` | string[] | Capture task names that rolled into this record. Feeds a worklog comment. |
| `status` | enum | `reconciled` \| `unbound` \| `provisional`. See §5.3. |

JSON:

```json
{ "format": "timetrack.worklog", "version": 1,
  "generated": "2026-07-26T18:04:11-05:00",
  "window": { "from": "2026-07-20", "to": "2026-07-26" },
  "records": [
    { "date": "2026-07-24", "started": "2026-07-24T09:12:00-05:00", "ended": null,
      "seconds": 5400, "raw_seconds": 5387,
      "jira_key": "PROJ-123", "known_task_id": 17, "description": "Build the widget",
      "capture_tasks": ["widget spike", "widget"], "status": "reconciled" }
  ] }
```

CSV — header row defines v1:

```csv
date,started,ended,seconds,raw_seconds,jira_key,known_task_id,description,capture_tasks,status
2026-07-24,2026-07-24T09:12:00-05:00,,5400,5387,PROJ-123,17,Build the widget,widget spike;widget,reconciled
```

### 5.3 The reconcile gate

`CLAUDE.md` invariant 4: time is reportable only when bound to a Known Task with
a real JIRA key. Export honours this.

**Default:** if any time in the window is unbound or bound-but-provisional,
`export worklog` writes **no file**, prints the offending tasks to stderr, and
exits **2** (§6.4). This is deliberate — the failure mode to prevent is a user's
uploader silently pushing an incomplete week.

**`--include-unreconciled`:** the gate is downgraded to a stderr warning. All
records are emitted; unreconciled ones carry `jira_key: null` and
`status` of `unbound` or `provisional`. Exit code is **0**. A consumer filters
on `status == "reconciled"` and can report the rest back to the user.

The two failure modes stay distinct end-to-end, matching
`Store.ReconcileError.unbound` / `.provisional` and the way the app's reconcile
panel already surfaces them separately.

Note that the gate in `reconciledReport` runs **before** normalisation and uses
raw window totals — a task does not escape the gate by rounding to zero.

### 5.4 Normalisation

`Store.reconciledReport` takes five knobs: `dropBelowSec`, `minIntervalMin`,
`roundToMin`, `aggregateKey`, and `subFifteenResolutions`. Export must expose the
**first four** rather than hardcode them, because **the CLI and the app currently
disagree**: the app's reconcile panel uses 30s / 1min / 15min / `"MISC"`, and the
CLI passes all zeros. Two different numbers for the same window is unacceptable
in an export contract.

`subFifteenResolutions` is deliberately **not** exposed in v1 — see §5.5.

Requirements:

- Export accepts the four normalisation parameters and applies them to `seconds`.
- `raw_seconds` always reports the pre-normalisation value, so the delta is
  visible without re-running anything.
- The parameters actually used are recorded in the JSON envelope under
  `normalisation`, so an exported file is self-describing:

  ```json
  "normalisation": { "drop_below_sec": 30, "min_interval_min": 1,
                     "round_to_min": 15, "aggregate_key": "MISC" }
  ```

  For CSV, `raw_seconds` alongside `seconds` carries the same information less
  precisely; a consumer needing the exact parameters uses JSON.
- Defaults should come from shared configuration, not per-call-site literals.
  Resolving that divergence may land as its own change; until it does, export
  **must** state its defaults in `--help` and in the envelope.

### 5.5 Sub-15 resolutions are out of scope in v1

`reconciledReport`'s fifth parameter, `subFifteenResolutions`, is a per-key map of
`recordAs15 | drop | rollIntoAggregate`. **Export does not expose it and never
populates it in v1.** Sub-quantum keys are emitted as-is at their raw
post-pass-1 seconds, which is exactly what the existing code does for an
unresolved key — it makes no silent billing decision, and neither does export.

Two reasons, and the second is the important one:

1. A map-valued CLI flag (`--sub-fifteen PROJ-1=drop,PROJ-2=record15`) is a poor
   fit for a knob whose entire purpose is a per-key interactive judgement call.
2. **Export could not reproduce an app-side resolution even if it wanted to.**
   The app's resolutions are session-only state, reset on every
   `refreshReconcile()` and never persisted as events. A report a user finalised
   in the UI yesterday cannot be regenerated today, by export or by anything
   else.

Point 2 is a real limitation of the current implementation, not of this format:
a user who resolves sub-15 keys in the app and then exports will get different
numbers. Persisting resolutions as append-only events would fix it and would let
export apply them automatically with no new flags. That is the right shape, it is
out of scope here, and it is recorded in §9.5.

---

## 6. CLI surface

```
timetrack export worklog --from YYYY-MM-DD --to YYYY-MM-DD
                         [--format json|csv] [--out FILE]
                         [--by day|key|interval]
                         [--include-unreconciled]
                         [--drop-below-sec N] [--min-interval-min N]
                         [--round-to-min N] [--aggregate-key KEY]

timetrack export known   [--format json|csv] [--out FILE] [--include-retired]

timetrack export events  --from YYYY-MM-DD --to YYYY-MM-DD
                         [--format json|ndjson] [--out FILE]

timetrack import known   FILE [--format auto|json|csv] [--dry-run]
timetrack import worklog FILE [--format auto|json|csv] [--dry-run]
```

### 6.1 Conventions

- `--format` defaults to `json`. `auto` on import sniffs by extension, then by
  first non-whitespace byte (`{` or `[` → JSON, else CSV).
- `--out` defaults to stdout, so everything pipes. When `--out` is given, the
  file is written atomically (temp + rename) and **never** partially written on
  a gate failure.
- `--from` / `--to` are inclusive and parsed by the existing `parseDate` helper
  in `Sources/TimeTrackCLICore/CLI.swift`.
- All diagnostics go to **stderr**; only payload goes to stdout.

### 6.2 `--dry-run`

**Both import commands must implement this flag** — it is not optional to build.
Passing it is the user's choice: `import` without `--dry-run` applies changes, as
the synopsis in §6 shows. The CLI does *not* default to dry-run.

With the flag, the command prints the diff that *would* be applied — inserts,
promotions, description updates, no-ops — and changes nothing. This is what lets
a user trust a script they wrote against a real `events.db`, and it should be the
first thing the reference scripts demonstrate.

Note the different default in §8: the *reference scripts* default to dry-run and
require an explicit `--apply`, because they are examples a user runs before
understanding them. The CLI is the primitive and behaves conventionally; the
scripts are the guard rail.

### 6.3 `export events`

Lossless dump of the append-only log: every column of `Event`, snake_cased —
`id`, `ts`, `type`, `task_id`, `prev_task_id`, `phase_id`, `profile_name`,
`extend_min`, `comment`, `range_start`, `range_end`, `jira_key`,
`known_task_id`, `next_phase_id` — plus a resolved `task_name` for readability.

`id` is included because "lossless" has to mean it. It is the autoincrement
primary key: monotonic within one database and therefore usable as a cursor for
incremental export (`--from` the last id you saw). It is **not** portable across
databases and must not be treated as a global identifier — two machines' logs
will reuse the same ids for different events.

JSON or NDJSON only — **no CSV**. Events are sparse and heterogeneous across 14
event types; flattening them to a fixed column set produces a mostly-empty grid
that invites misreading. NDJSON is offered for streaming large windows.

This requires promoting a read path out of the kit; `readAllEventsInternal()` is
currently `internal` and unreachable from `TimeTrackCLICore`.

### 6.4 Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Usage error, unreadable file, malformed input, unknown format/version |
| 2 | Reconcile gate not satisfied (`export worklog` without `--include-unreconciled`) |

Code 2 is a distinct value on purpose: a wrapper script must be able to tell
"you have unbound time" from "your invocation was wrong" without parsing stderr.

Note the current `timetrack reconcile` catches both gate failures and exits **0**.
Aligning it to exit 2 is a behaviour change and should be called out in the PR.

---

## 7. Import semantics and the append-only invariant

`CLAUDE.md` invariant 1: events are never UPDATEd or DELETEd. Import obeys this
without exception.

### 7.1 `import known`

Expressed entirely as existing append-only operations: inserts into
`known_tasks`, and `known_task_promote` events for promotions. Nothing new is
needed. See §4.2.

### 7.2 `import worklog` — requires a new event type

This is the **only part of this spec that changes the schema**, and it needs
care.

Naive approaches that must be rejected:

- *Appending synthetic `start`/`stop` pairs at the backdated timestamps.* These
  interleave with real tracking events and corrupt `sliceTimeline`, which walks
  the log in `ts` order assuming a single coherent timeline.
- *Updating existing events.* Violates invariant 1.

**The correct shape** is a new `manual_entry` event carrying `taskId`,
`rangeStart`, and `rangeEnd`, applied at **report time** — structurally
identical to how `idle_resolve` already reattributes an interval, and reusing
the `rangeStart`/`rangeEnd` columns that `DESIGN.md` earmarked for interval-level
work. Requirements:

- New `EventType.manualEntry = "manual_entry"` in `Store.swift`.
- A migration marking the semantic addition (may be a no-op like
  `v4_known_task_history`).
- `sliceTimeline` and the report walk must fold `manual_entry` intervals in,
  and must define overlap behaviour explicitly: a manual entry overlapping
  tracked time is **an error at import**, not a silent double-count. Overlap is
  checked against both tracked intervals and other manual entries.
- Round-tripping a `--by interval` export through `import worklog` must be a
  detectable no-op (matching entries are skipped, not duplicated). Identity is
  `(task, range_start, range_end)`.

This also delivers backdated/manual time entry, which has no other path today:
`Store.append` accepts an explicit `ts` but nothing exposes it, so forgetting to
start the tracker currently means the time is unrecoverable without hand-written
SQL.

An imported worklog record with a `jira_key` or `known_task_id` also appends the
corresponding `reconcile_bind`, so the entry arrives already bound.

### 7.3 Why no `import events`

Replaying raw events would let an external tool write arbitrary state
transitions into the log, bypassing the state machine that guarantees them
(no phantom phases, two segments max per episode, cycle freezing at the first
unacked boundary). `export events` is for archival and debugging. Restoring a
backup is a file copy of `events.db`, not an import.

---

## 8. Reference scripts

Live in `tools/examples/`. They are **documentation that runs**, not products —
users are expected to fork and modify them.

Constraints:

- **Python 3 standard library only.** `csv` + `json`, no pip install. Python 3
  ships with macOS; this is the most forkable option for users who are not Swift
  developers. Anything requiring dependencies belongs in the user's own repo.
- Every script that mutates anything **defaults to dry-run** and requires an
  explicit `--apply`.
- Credentials come from environment variables, never files, never arguments
  (`CLAUDE.md` §Secrets). Auth is a clearly-marked stub the user fills in.
- Each script has a header comment stating what it demonstrates and what a user
  would realistically change.

| Script | Demonstrates |
|---|---|
| `import-known-tasks.py` | CSV or JSON → `timetrack import known`, including reading the `--dry-run` diff before applying |
| `export-worklog.py` | `timetrack export worklog --format json` → JIRA worklog POST bodies (`started`, `timeSpentSeconds`, `comment` built from `capture_tasks`). Prints payloads by default; `--apply` is a stub. Filters on `status == "reconciled"`. |
| `jira-to-known-tasks.py` | A JIRA search response → the `known_task` format, ready to pipe into `import known` |

The third script is strategically important: it means a user can populate the
registry from JIRA **without** waiting on first-party `tools/jira-sync` (#26).
The `jira_cache.json` contract is already frozen, so a user script can write
that file and the tracker consumes it identically.

---

## 9. Decisions deliberately left open

Flagged so a future implementer raises them rather than silently picking:

1. **Default grain for `export worklog`.** Spec says `--by day` to match JIRA
   worklogs. If real use shows consumers always re-aggregate, `interval` is a
   smaller surface to specify and maintain, and `day` becomes a convenience.
2. **Where normalisation defaults live.** §5.4 requires them to be shared
   between CLI and app, but does not say whether that is a config file, a kit
   constant, or the Settings window (#30). Resolve before implementing §5.4.
3. **Timezone handling for `date`.** Currently local via `Calendar.current`,
   with no override. A user working across timezones, or a team normalising to
   one, may need `--timezone`. Not specified in v1.
4. **Whether `export worklog` should emit break time.** Excluded in v1 —
   the break task is synthetic and never bound. Revisit if anyone wants
   break-inclusive utilisation reports.
5. **Persisting sub-15 resolutions as events.** §5.5 excludes
   `subFifteenResolutions` from v1 partly because app-side resolutions are
   session-only and cannot be reproduced. Appending them as events would make a
   finalised report regenerable, let export apply them with no new flags, and
   remove the app-vs-export divergence. It fits the append-only model cleanly.
   Needs its own issue; it is a prerequisite for export and the app agreeing on
   every window, not just windows with no sub-quantum keys.

---

## 10. Related

- `DESIGN.md` — reconciliation rules, JIRA integration contract, deferred backlog
- `CLAUDE.md` — invariants 1 (append-only), 4 (reconcile gate), 5 (bind by registry id)
- `README.md` — data location, `known_tasks.yaml` format
- `Sources/TimeTrackKit/Store.swift` — `KnownTask`, `Event`, `ReconciledRow`, `ReconcileError`
- `Sources/TimeTrackKit/KnownTasksLoader.swift` — the upsert logic import must reuse
- `Sources/TimeTrackCLICore/CLI.swift` — command dispatch, `parseDate`, `CLIOutput`
