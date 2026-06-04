import Foundation
import GRDB

// Event log is append-only. Corrections happen by appending new events,
// never UPDATE/DELETE. This makes the file diff-able and recoverable.
public enum EventType: String, Codable {
    case start
    case stop
    case `switch`
    case phaseArm     = "phase_arm"
    case phaseAdvance = "phase_advance"
    case phaseExtend  = "phase_extend"
    case profileChange = "profile_change"
    case interruption
    case idleGap      = "idle_gap"      // marks idle-start, taskId = original
    case idleResolve  = "idle_resolve"  // classifies one segment's interval
    case reconcileBind = "reconcile_bind" // binds a loose task to a JIRA key
    // Append-only history for the known_tasks registry. knownTaskId references
    // the known_tasks row; jiraKey carries the new key for promote events.
    case knownTaskPromote = "known_task_promote"  // assigns real jiraKey, clears provisional
    case knownTaskRetire  = "known_task_retire"   // marks the entry as retired
}

public struct Task: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public var id: Int64?
    public var name: String
    public var code: String?           // JIRA key, ticket id
    public var category: String        // "project" | "overhead" | "meeting" | "break"
    public var archived: Bool

    public static let databaseTableName = "tasks"

    public init(id: Int64?, name: String, code: String?, category: String, archived: Bool) {
        self.id = id
        self.name = name
        self.code = code
        self.category = category
        self.archived = archived
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// The Known Tasks registry — the curated spine. Maintained during iteration
// prep. The ONLY valid reconciliation target. Provisional entries may exist
// without a real jiraKey (loose-until-reconciled, one level up); they block the
// final report until promoted. "Overhead" is not a property here — time is
// overhead purely by virtue of being bound to the overhead JIRA, which is an
// ordinary registry entry.
public struct KnownTask: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    public var id: Int64?
    public var jiraKey: String?        // nil iff provisional
    public var description: String
    public var provisional: Bool
    public var retired: Bool           // carried out of the active list between iterations
    public var createdTs: Int64

    public static let databaseTableName = "known_tasks"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(id: Int64?, jiraKey: String?, description: String,
                provisional: Bool, retired: Bool, createdTs: Int64) {
        self.id = id
        self.jiraKey = jiraKey
        self.description = description
        self.provisional = provisional
        self.retired = retired
        self.createdTs = createdTs
    }
}

public struct Event: Codable, FetchableRecord, PersistableRecord {
    public var id: Int64?
    public var ts: Int64               // unix epoch millis
    public var type: String            // EventType.rawValue
    public var taskId: Int64?
    public var prevTaskId: Int64?
    public var phaseId: String?        // phase id from profile when relevant
    public var profileName: String?
    public var extendMin: Int?         // for phase_extend
    public var comment: String?
    // For idle_resolve: the segment interval being reattributed and its target.
    // rangeStart/rangeEnd are epoch millis; taskId holds the chosen target
    // (null = discard). Disjoint per segment, so reattributions never overlap.
    public var rangeStart: Int64? = nil
    public var rangeEnd: Int64? = nil
    // For reconcile_bind: the registry entry this loose task maps to. The JIRA
    // key is resolved THROUGH the registry at report time, so promoting a
    // provisional Known Task propagates to every binding without re-binding.
    // There is no "kind" — the bind target (which Known Task) is the whole story;
    // time is overhead iff bound to the overhead JIRA.
    public var knownTaskId: Int64? = nil
    public var jiraKey: String? = nil   // unused for binds; kept for future raw-key paths
    // For phase_arm ONLY: the phase id that advance() WOULD transition into from
    // this armed boundary — i.e. the live CycleIterator's peekNext (including the
    // long-cycle override, e.g. long_break, or the wrap-back-to-work). Recorded at
    // arm time so the stateless CLI can read the exact next phase instead of
    // recomputing it (it has no live iterator to reproduce cycle-number state).
    // nil on every other event type.
    public var nextPhaseId: String? = nil

    public static let databaseTableName = "events"

    public init(id: Int64?, ts: Int64, type: String,
                taskId: Int64?, prevTaskId: Int64?,
                phaseId: String?, profileName: String?,
                extendMin: Int?, comment: String?,
                rangeStart: Int64? = nil, rangeEnd: Int64? = nil,
                knownTaskId: Int64? = nil, jiraKey: String? = nil,
                nextPhaseId: String? = nil) {
        self.id = id
        self.ts = ts
        self.type = type
        self.taskId = taskId
        self.prevTaskId = prevTaskId
        self.phaseId = phaseId
        self.profileName = profileName
        self.extendMin = extendMin
        self.comment = comment
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.knownTaskId = knownTaskId
        self.jiraKey = jiraKey
        self.nextPhaseId = nextPhaseId
    }
}

public final class Store {
    private let dbQueue: DatabaseQueue

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        var config = Configuration()
        config.foreignKeysEnabled = true
        // WAL journal: enables safe CROSS-PROCESS sharing (CLI + app) alongside
        // the busy-timeout — SQLite serializes in-process; WAL lets a concurrent
        // reader (app) and writer (CLI) proceed without one blocking the other.
        // Must be set on Configuration BEFORE opening the DatabaseQueue; SQLite
        // forbids switching journal_mode inside a transaction (which write{} uses).
        config.journalMode = .wal
        // Wait up to 5 s on busy — allows the CLI and app to share the DB safely.
        config.busyMode = .timeout(5)
        self.dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        try migrate()
        try ensureBreakTask()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "tasks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("code", .text)
                t.column("category", .text).notNull().defaults(to: "project")
                t.column("archived", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .integer).notNull().indexed()
                t.column("type", .text).notNull()
                t.column("taskId", .integer).references("tasks")
                t.column("prevTaskId", .integer).references("tasks")
                t.column("phaseId", .text)
                t.column("profileName", .text)
                t.column("extendMin", .integer)
                t.column("comment", .text)
                t.column("rangeStart", .integer)
                t.column("rangeEnd", .integer)
                t.column("jiraKey", .text)
            }
        }

        migrator.registerMigration("v2_known_tasks") { db in
            try db.create(table: "known_tasks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("jiraKey", .text)          // nil iff provisional
                t.column("description", .text).notNull()
                t.column("provisional", .boolean).notNull().defaults(to: false)
                t.column("retired", .boolean).notNull().defaults(to: false)
                t.column("createdTs", .integer).notNull()
            }
            try db.alter(table: "events") { t in
                t.add(column: "knownTaskId", .integer).references("known_tasks")
            }
        }

        // Records, on each phase_arm, the phase advance() would transition into,
        // so the stateless CLI reads it instead of recomputing. NULLABLE add via a
        // NEW migration step — existing DBs upgrade cleanly (no row mutation).
        migrator.registerMigration("v3_event_next_phase") { db in
            try db.alter(table: "events") { t in
                t.add(column: "nextPhaseId", .text)
            }
        }

        // Append-only history for the known_tasks registry.
        // promoteKnownTask and retireKnownTask previously called k.update(db),
        // overwriting known_tasks rows in place. From this migration onward, those
        // operations append known_task_promote / known_task_retire events to the
        // events table instead. knownTasks() reads the base known_tasks row and
        // overlays the most-recent promote/retire event for each entry, so the
        // full change history is preserved and recoverable.
        //
        // No schema change needed: the events table already carries knownTaskId
        // and jiraKey columns (added in v2_known_tasks). The new event types
        // (known_task_promote, known_task_retire) are purely application-level
        // string constants stored in the existing `type` column.
        //
        // Existing DBs: rows in known_tasks may already carry in-place updates
        // (written before this migration). Those rows are the correct baseline;
        // new events extend from that state without any data loss.
        migrator.registerMigration("v4_known_task_history") { _ in }

        try migrator.migrate(dbQueue)
    }

    // Synthetic task for break accrual. Always present.
    private func ensureBreakTask() throws {
        try dbQueue.write { db in
            let count = try Task.filter(Column("category") == "break").fetchCount(db)
            if count == 0 {
                var t = Task(id: nil, name: "Break",
                             code: nil, category: "break", archived: false)
                try t.insert(db)
            }
        }
    }

    // Returns the id of the synthetic break task, or -1 if none exists.
    // -1 is never a valid SQLite rowid and signals "no break row found" to callers
    // that cannot throw (e.g. tick()). If ensureBreakTask() was called in init
    // this path is unreachable in practice; the -1 sentinel guards against external
    // DB mutation. Callers MUST treat -1 as "break row missing" and not pass it as
    // a taskId FK, since -1 has no matching row in the tasks table.
    public func breakTaskId() throws -> Int64 {
        try dbQueue.read { db in
            try Task.filter(Column("category") == "break")
                .fetchOne(db)?.id ?? -1
        }
    }

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

    // MARK: - Tasks

    public func tasks(includeArchived: Bool = false) throws -> [Task] {
        try dbQueue.read { db in
            var req = Task.order(Column("name"))
            if !includeArchived {
                req = req.filter(Column("archived") == false)
            }
            return try req.fetchAll(db)
        }
    }

    // Tasks that a user may reference by name or id — excludes synthetic/system
    // categories (currently only "break"). This is the single chokepoint for
    // "which tasks are user-reachable via CLI resolvers": `start`, `switch`, and
    // `bind` must use this, never the unfiltered `tasks()`, so the internal break
    // task cannot be reached by accident and cause silent time loss.
    //
    // The internal break machinery (ensureBreakTask, breakTaskId, phase_advance,
    // report, reconcile) continues to call tasks()/breakTaskId() directly —
    // only user-facing CLI resolution is restricted here.
    public func userTasks(includeArchived: Bool = false) throws -> [Task] {
        try dbQueue.read { db in
            var req = Task.filter(Column("category") != "break")
                         .order(Column("name"))
            if !includeArchived {
                req = req.filter(Column("archived") == false)
            }
            return try req.fetchAll(db)
        }
    }

    public func upsertTask(_ task: Task) throws -> Task {
        try dbQueue.write { db in
            var t = task
            try t.save(db)
            return t
        }
    }

    // MARK: - Events

    @discardableResult
    public func append(_ event: Event) throws -> Event {
        try dbQueue.write { db in
            var e = event
            if e.ts == 0 { e.ts = Int64(Date().timeIntervalSince1970 * 1000) }
            try e.insert(db)
            return e
        }
    }

    // Returns all events in insertion order.  Internal visibility so @testable
    // import can use it in unit tests without exposing the raw DatabaseQueue.
    func readAllEventsInternal() throws -> [Event] {
        try dbQueue.read { db in
            try Event.order(Column("ts").asc, Column("id").asc).fetchAll(db)
        }
    }

    // Raised when a switch-from-ARMED cannot determine the next phase: the arm
    // event recorded no resolvable nextPhaseId AND the armed phase id is absent
    // from the profile's base cycle (so even the legacy fallback fails).
    public enum SwitchFromArmedError: Error, CustomStringConvertible {
        case unresolvableNextPhase(armedPhaseId: String, profileName: String)

        public var description: String {
            switch self {
            case let .unresolvableNextPhase(phase, profile):
                return "armed phase '\(phase)' not found in profile '\(profile)'; cannot advance"
            }
        }
    }

    // MARK: - Shared accrual-task decision
    //
    // SINGLE source of truth for "which task accrues during the next phase",
    // shared by Tracker.advance() (in-process) and switchFromArmed (stateless
    // CLI) so the two can NEVER diverge. Mirrors Tracker.advance()'s exact behavior:
    //   - break phase (accrueAs == "break")  -> the synthetic break task
    //   - returning from break (accrueAs == nil) -> previousWorkTaskId ?? carried
    //   - otherwise (a named work phase)      -> the carried task
    // `carriedTaskId` is the task active at the armed boundary (advance: the armed
    // taskId; switchFromArmed: armedTaskId). `previousWorkTaskId` is the resumed
    // work task when leaving a break; both callers now implement the real DB lookup.
    public func accrualTaskId(forNextPhase nextPhase: Phase,
                              carriedTaskId: Int64,
                              previousWorkTaskId: Int64?) throws -> Int64 {
        if nextPhase.accrueAs == "break" {
            return try breakTaskId()
        }
        if nextPhase.accrueAs == nil {
            // Returning from break: resume the prior work task, else carry on.
            return previousWorkTaskId ?? carriedTaskId
        }
        return carriedTaskId
    }

    // MARK: - Switch from ARMED (canonical implicit-ack)
    //
    // DESIGN.md state machine: "ARMED → switch → implicit ack, then switch".
    // Tracker.switchTo performs this in-process by calling advance() (which
    // appends a phase_advance) and THEN appending the switch off the advanced
    // accrual task. The stateless CLI has no live CycleIterator, so it reads the
    // exact next phase recorded on the latest phase_arm event (nextPhaseId) and
    // resolves it against the loaded profile (base cycle OR longCycleOverride),
    // then emits the SAME two-event sequence, keeping the log faithful to the
    // machine — including the long-cycle override (e.g. long_break) that
    // Profile.phaseAfter alone cannot reproduce.
    //
    // Legacy fallback: phase_arm events written before nextPhaseId existed carry
    // nil; for those we fall back to Profile.phaseAfter (now override-aware), so
    // even a legacy long_break arm advances sanely instead of hard-erroring.
    //
    // The accrual task is decided by the shared accrualTaskId() helper so it can
    // never drift from Tracker.advance().
    //
    // Append-only: two new events, no mutation.
    public func switchFromArmed(armedTaskId: Int64,
                                armedPhaseId: String,
                                targetTaskId: Int64,
                                profile: Profile,
                                comment: String? = nil) throws {
        // Read the next phase recorded at arm time. nextPhaseId is set ONLY on
        // phase_arm events, so we look at the most recent one.
        let recordedNextId = try dbQueue.read { db in
            try Event
                .filter(Column("type") == EventType.phaseArm.rawValue)
                .order(Column("ts").desc, Column("id").desc)
                .fetchOne(db)?
                .nextPhaseId
        }

        let nextPhase: Phase
        if let nextId = recordedNextId,
           let resolved = resolvePhase(id: nextId, in: profile) {
            // Authoritative path: the arm event told us exactly where advance()
            // would go, including the long-cycle override (e.g. long_break).
            nextPhase = resolved
        } else if let fallback = profile.phaseAfter(currentPhaseId: armedPhaseId) {
            // Legacy fallback: arm event predates nextPhaseId (nil) — or recorded
            // an id we can't resolve. phaseAfter is now override-aware so an
            // override phase (e.g. long_break) resolves to cycle[0] rather than
            // hard-erroring.
            nextPhase = fallback
        } else {
            // No recorded next phase AND no base-cycle successor — the armed
            // phase id isn't in this profile at all. Surface explicitly rather
            // than silently no-op'ing.
            throw SwitchFromArmedError.unresolvableNextPhase(
                armedPhaseId: armedPhaseId, profileName: profile.name)
        }

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

        // 1) Implicit ack: phase_advance onto the next phase's accrual task.
        try append(Event(
            id: nil, ts: 0, type: EventType.phaseAdvance.rawValue,
            taskId: accrualTaskId, prevTaskId: armedTaskId,
            phaseId: nextPhase.id, profileName: profile.name,
            extendMin: nil, comment: comment))

        // 2) The switch itself, off the just-advanced accrual task. Its
        // prevTaskId must be the advanced accrual task (a valid FK) — never the
        // armed task — so reconstruction sees: armed → advance → switch.
        try append(Event(
            id: nil, ts: 0, type: EventType.switch.rawValue,
            taskId: targetTaskId, prevTaskId: accrualTaskId,
            phaseId: nextPhase.id, profileName: profile.name,
            extendMin: nil, comment: comment))
    }

    // Resolve a phase id to its Phase by searching the profile's BASE cycle and
    // its longCycleOverride. The override is essential: a phase like long_break
    // exists ONLY in longCycleOverride for the pomodoro profile, so a base-cycle
    // search alone would miss it and force a hard error on switch-from-ARMED.
    private func resolvePhase(id: String, in profile: Profile) -> Phase? {
        if let p = profile.cycle.first(where: { $0.id == id }) { return p }
        if let p = profile.longCycleOverride?.first(where: { $0.id == id }) { return p }
        return nil
    }

    // MARK: - Reporting

    public struct DayRow {
        public let task: Task
        public let totalSeconds: Int
    }

    // Time on each task for a given day, computed from event intervals.
    // Algorithm: walk events in order, accumulate (next.ts - this.ts) against
    // this.taskId whenever this is a tracking event (start/switch/phase_advance
    // into a non-break phase). Stop events close the interval. Day boundaries
    // are open intervals carried forward/back as needed.
    public func report(day: Date) throws -> [DayRow] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
        let startMs = Int64(dayStart.timeIntervalSince1970 * 1000)
        let endMs = Int64(dayEnd.timeIntervalSince1970 * 1000)

        return try dbQueue.read { db in
            // Pull events from day-start onward, plus the immediately preceding
            // event (to know what was active at midnight).
            let prior = try Event
                .filter(Column("ts") < startMs)
                .order(Column("ts").desc, Column("id").desc)
                .fetchOne(db)

            let today = try Event
                .filter(Column("ts") >= startMs && Column("ts") < endMs)
                .order(Column("ts").asc, Column("id").asc)
                .fetchAll(db)

            var totals: [Int64: Int] = [:]   // taskId -> seconds
            var activeTask: Int64? = activeTaskFromPrior(prior)
            var lastTs: Int64 = startMs

            for e in today {
                if let active = activeTask {
                    totals[active, default: 0] += Int((e.ts - lastTs) / 1000)
                }
                activeTask = nextActiveTask(after: e, current: activeTask)
                lastTs = e.ts
            }
            // Close the final open interval at end-of-day or now, whichever is earlier.
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let closeTs = min(endMs, nowMs)
            if let active = activeTask, closeTs > lastTs {
                totals[active, default: 0] += Int((closeTs - lastTs) / 1000)
            }

            // --- Second pass: idle_resolve reattribution ---
            // The walk above counted each idle interval against whatever task was
            // active at idle-start (that's what the event stream said). Now correct
            // it: for each resolved segment, SUBTRACT its interval from the original
            // task and ADD it to the chosen target. Segments are disjoint, so these
            // corrections never double-count.
            //
            // Interval math, stated explicitly to avoid the off-by-one trap:
            //   - We subtract from `prevTaskId` (the task the walk attributed it to)
            //   - We add to `taskId` (the chosen target; null = discard, add to nothing)
            //   - We clamp [rangeStart, rangeEnd] to [startMs, closeTs] so a segment
            //     spanning midnight only affects the portion inside this day.
            let resolves = try Event
                .filter(Column("type") == EventType.idleResolve.rawValue)
                .filter(Column("rangeEnd") >= startMs && Column("rangeStart") < endMs)
                .fetchAll(db)

            for r in resolves {
                guard let rs = r.rangeStart, let re = r.rangeEnd else { continue }
                let clampedStart = max(rs, startMs)
                let clampedEnd = min(re, closeTs)
                guard clampedEnd > clampedStart else { continue }
                let secs = Int((clampedEnd - clampedStart) / 1000)

                // Subtract from where the walk put it (prevTaskId = original task).
                if let orig = r.prevTaskId {
                    totals[orig, default: 0] -= secs
                    if totals[orig]! <= 0 { totals[orig] = max(0, totals[orig]!) }
                }
                // Add to chosen target. taskId nil = discard (goes nowhere).
                if let target = r.taskId {
                    totals[target, default: 0] += secs
                }
            }

            // Resolve task ids to Task records.
            var rows: [DayRow] = []
            for (tid, secs) in totals {
                if let t = try Task.fetchOne(db, key: tid) {
                    rows.append(DayRow(task: t, totalSeconds: secs))
                }
            }
            return rows.sorted { $0.totalSeconds > $1.totalSeconds }
        }
    }

    private func activeTaskFromPrior(_ prior: Event?) -> Int64? {
        guard let p = prior, p.type != EventType.stop.rawValue else { return nil }
        return p.taskId
    }

    private func nextActiveTask(after e: Event, current: Int64?) -> Int64? {
        switch EventType(rawValue: e.type) {
        case .start, .switch:     return e.taskId
        case .phaseAdvance:       return e.taskId    // may be break task
        case .stop:               return nil
        case .phaseArm,
             .phaseExtend,
             .interruption,
             .profileChange,
             .idleGap,
             .idleResolve,
             .reconcileBind,
             .knownTaskPromote,
             .knownTaskRetire,
             .none:               return current
        }
    }

    // MARK: - Known Tasks registry (prep)
    //
    // The curated spine. The only valid reconciliation target. Provisional
    // entries have no jiraKey yet and block the final report until promoted.

    public func knownTasks(activeOnly: Bool = true) throws -> [KnownTask] {
        try dbQueue.read { db in
            // Fetch all base rows; history events will overlay them below.
            var rows = try KnownTask.order(Column("createdTs").desc).fetchAll(db)

            // Collect the most-recent promote/retire event per known_tasks id.
            // Last-write-wins: events are ordered ascending by ts/id so later
            // entries overwrite earlier ones in the dictionary.
            let historyTypes = [
                EventType.knownTaskPromote.rawValue,
                EventType.knownTaskRetire.rawValue,
            ]
            let historyEvents = try Event
                .filter(historyTypes.contains(Column("type")))
                .filter(Column("knownTaskId") != nil)
                .order(Column("ts").asc, Column("id").asc)
                .fetchAll(db)

            // Track promote and retire independently so both overlays apply
            // regardless of order. A single last-write-wins map would drop the
            // promote data when retire is the most-recent event.
            var latestPromote: [Int64: Event] = [:]
            var latestRetire: [Int64: Event] = [:]
            for e in historyEvents {
                guard let ktid = e.knownTaskId else { continue }
                switch EventType(rawValue: e.type) {
                case .knownTaskPromote: latestPromote[ktid] = e
                case .knownTaskRetire:  latestRetire[ktid] = e
                default: break
                }
            }

            // Overlay history onto each base row.
            rows = rows.map { base in
                guard let kid = base.id else { return base }
                var updated = base
                if let promote = latestPromote[kid] {
                    updated.jiraKey = promote.jiraKey ?? base.jiraKey
                    updated.provisional = false
                }
                if latestRetire[kid] != nil {
                    updated.retired = true
                }
                return updated
            }

            if activeOnly { rows = rows.filter { !$0.retired } }
            return rows
        }
    }

    @discardableResult
    public func addKnownTask(jiraKey: String?, description: String) throws -> KnownTask {
        try dbQueue.write { db in
            var k = KnownTask(
                id: nil, jiraKey: jiraKey, description: description,
                provisional: (jiraKey == nil),
                retired: false,
                createdTs: Int64(Date().timeIntervalSince1970 * 1000))
            try k.insert(db)
            return k
        }
    }

    // Promote a provisional entry by attaching its real JIRA key. Append-only:
    // writes a known_task_promote event; the known_tasks row is never mutated.
    // Because binds reference the registry id (not the key), every prior binding
    // to this entry now resolves to the real key automatically — no re-binding.
    // The promote event's jiraKey field carries the new key; knownTaskId links
    // it to the registry entry. knownTasks() overlays this event at read time.
    @discardableResult
    public func promoteKnownTask(id: Int64, jiraKey: String) throws -> Bool {
        let exists = try dbQueue.read { db in
            try KnownTask.fetchOne(db, key: id) != nil
        }
        guard exists else { return false }
        try append(Event(
            id: nil, ts: 0, type: EventType.knownTaskPromote.rawValue,
            taskId: nil, prevTaskId: nil,
            phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil,
            rangeStart: nil, rangeEnd: nil,
            knownTaskId: id, jiraKey: jiraKey))
        return true
    }

    // Retire a known_tasks entry by appending a known_task_retire event.
    // Append-only: the known_tasks row is never mutated. knownTasks() overlays
    // this event so the entry is excluded from active lists at read time.
    @discardableResult
    public func retireKnownTask(id: Int64) throws -> Bool {
        let exists = try dbQueue.read { db in
            try KnownTask.fetchOne(db, key: id) != nil
        }
        guard exists else { return false }
        try append(Event(
            id: nil, ts: 0, type: EventType.knownTaskRetire.rawValue,
            taskId: nil, prevTaskId: nil,
            phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil,
            rangeStart: nil, rangeEnd: nil,
            knownTaskId: id, jiraKey: nil))
        return true
    }

    // MARK: - Reconciliation
    //
    // Capture is loose; reporting is strict. Before a reconciled (submittable)
    // report, every ad-hoc capture task with time must be bound to a Known Task,
    // and no Known Task with reported time may still be provisional. Bindings are
    // append-only overlays referencing the registry — never raw key strings, so
    // promotion propagates without re-binding.

    public struct UnreconciledTask {
        public let task: Task
        public let totalSeconds: Int
    }

    // Most recent registry binding per capture task (last write wins).
    public func bindings() throws -> [Int64: Int64] {   // captureTaskId -> knownTaskId
        try dbQueue.read { db in
            let binds = try Event
                .filter(Column("type") == EventType.reconcileBind.rawValue)
                .order(Column("ts"))
                .fetchAll(db)
            var map: [Int64: Int64] = [:]
            for b in binds {
                if let tid = b.taskId, let ktid = b.knownTaskId { map[tid] = ktid }
            }
            return map
        }
    }

    public func bind(taskId: Int64, knownTaskId: Int64, comment: String?) throws {
        try append(Event(
            id: nil, ts: 0, type: EventType.reconcileBind.rawValue,
            taskId: taskId, prevTaskId: nil,
            phaseId: nil, profileName: nil,
            extendMin: nil, comment: comment,
            rangeStart: nil, rangeEnd: nil,
            knownTaskId: knownTaskId, jiraKey: nil))
    }

    private func windowSeconds(from: Date, to: Date) throws -> [Int64: Int] {
        var perTask: [Int64: Int] = [:]
        var day = Calendar.current.startOfDay(for: from)
        let end = Calendar.current.startOfDay(for: to)
        while day <= end {
            for row in try report(day: day) {
                if let id = row.task.id { perTask[id, default: 0] += row.totalSeconds }
            }
            day = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        }
        return perTask
    }

    // Ad-hoc capture tasks with time that aren't bound to a Known Task.
    // No heuristic: a task counts as reconciled ONLY via an explicit bind.
    public func unreconciled(from: Date, to: Date) throws -> [UnreconciledTask] {
        let binds = try bindings()
        let perTask = try windowSeconds(from: from, to: to)
        return try dbQueue.read { db in
            var out: [UnreconciledTask] = []
            for (tid, secs) in perTask where secs > 0 {
                guard let t = try Task.fetchOne(db, key: tid) else { continue }
                if t.category == "break" { continue }     // breaks never reported
                if binds[tid] != nil { continue }          // explicitly bound
                out.append(UnreconciledTask(task: t, totalSeconds: secs))
            }
            return out.sorted { $0.totalSeconds > $1.totalSeconds }
        }
    }

    // Second gate condition: Known Tasks that have reported time (via bindings)
    // but are still provisional (no real JIRA key).
    public func provisionalWithTime(from: Date, to: Date) throws -> [KnownTask] {
        let binds = try bindings()
        let perTask = try windowSeconds(from: from, to: to)
        // Sum bound seconds per Known Task.
        var perKnown: [Int64: Int] = [:]
        for (tid, secs) in perTask {
            if let ktid = binds[tid] { perKnown[ktid, default: 0] += secs }
        }
        return try dbQueue.read { db in
            var out: [KnownTask] = []
            for (ktid, secs) in perKnown where secs > 0 {
                if let k = try KnownTask.fetchOne(db, key: ktid), k.provisional {
                    out.append(k)
                }
            }
            return out
        }
    }

    public struct ReconciledRow {
        public let jiraKey: String
        public let totalSeconds: Int
    }

    // Two distinct failure modes, surfaced separately so the UI can show them
    // differently: unbound ad-hoc tasks vs. provisional-with-time Known Tasks.
    public enum ReconcileError: Error {
        case unbound([UnreconciledTask])
        case provisional([KnownTask])
    }

    public func reconciledReport(from: Date, to: Date) throws -> [ReconciledRow] {
        let unbound = try unreconciled(from: from, to: to)
        guard unbound.isEmpty else { throw ReconcileError.unbound(unbound) }
        let provisional = try provisionalWithTime(from: from, to: to)
        guard provisional.isEmpty else { throw ReconcileError.provisional(provisional) }

        let binds = try bindings()
        let perTask = try windowSeconds(from: from, to: to)
        return try dbQueue.read { db in
            var byKey: [String: Int] = [:]
            for (tid, secs) in perTask where secs > 0 {
                guard let t = try Task.fetchOne(db, key: tid),
                      t.category != "break",
                      let ktid = binds[tid],
                      let k = try KnownTask.fetchOne(db, key: ktid),
                      let key = k.jiraKey   // guaranteed non-nil: gate passed
                else { continue }
                byKey[key, default: 0] += secs
            }
            return byKey.map { ReconciledRow(jiraKey: $0.key, totalSeconds: $0.value) }
                .sorted { $0.totalSeconds > $1.totalSeconds }
        }
    }

    // MARK: - Current status (for CLI)
    //
    // Reconstructs the in-flight tracking state from the event log without
    // needing in-memory Tracker state. The CLI starts fresh on each invocation
    // so it can't rely on an in-memory state machine.

    public enum TrackingStatus {
        case idle
        case tracking(task: Task, since: Date)
        case armed(task: Task, phase: String, since: Date)
    }

    public func currentStatus() throws -> TrackingStatus {
        // Only these event types change what's being tracked or whether we're tracking.
        let stateTypes = [
            EventType.start.rawValue,
            EventType.stop.rawValue,
            EventType.switch.rawValue,
            EventType.phaseAdvance.rawValue,
            EventType.phaseExtend.rawValue,
            EventType.phaseArm.rawValue,
        ]
        return try dbQueue.read { db in
            guard let last = try Event
                .filter(stateTypes.contains(Column("type")))
                .order(Column("ts").desc, Column("id").desc)
                .fetchOne(db)
            else { return .idle }

            switch EventType(rawValue: last.type) {
            case .stop, .none:
                return .idle
            case .phaseArm:
                guard let tid = last.taskId,
                      let task = try Task.fetchOne(db, key: tid) else { return .idle }
                let since = try taskStartDate(for: tid, db: db)
                return .armed(task: task, phase: last.phaseId ?? "work", since: since)
            case .phaseAdvance:
                // A phase_advance sets a new active task (often a break task that has no
                // start/switch row). Derive 'since' from the phase_advance event's own ts
                // — that is the moment the phase began. taskStartDate() would find no
                // start/switch for the break task and fall back to now(), giving a
                // misleading 0s elapsed.
                guard let tid = last.taskId,
                      let task = try Task.fetchOne(db, key: tid) else { return .idle }
                let since = Date(timeIntervalSince1970: Double(last.ts) / 1000.0)
                return .tracking(task: task, since: since)
            default:
                guard let tid = last.taskId,
                      let task = try Task.fetchOne(db, key: tid) else { return .idle }
                let since = try taskStartDate(for: tid, db: db)
                return .tracking(task: task, since: since)
            }
        }
    }

    // The profile in effect, read from the event log: the most recent event
    // carrying a non-nil profileName. start/phase_arm/phase_advance all stamp it
    // (and profile_change explicitly). Returns nil if nothing in the log names a
    // profile (legacy/CLI-only rows), letting the caller fall back to "default".
    // The stateless CLI uses this to load the right profile for switch-from-ARMED.
    public func currentProfileName() throws -> String? {
        try dbQueue.read { db in
            try Event
                .filter(Column("profileName") != nil)
                .order(Column("ts").desc, Column("id").desc)
                .fetchOne(db)?
                .profileName
        }
    }

    // Most recent start or switch that established the given task as active.
    // Used to compute elapsed time in status display.
    private func taskStartDate(for taskId: Int64, db: Database) throws -> Date {
        let startTypes = [EventType.start.rawValue, EventType.switch.rawValue]
        let e = try Event
            .filter(startTypes.contains(Column("type")))
            .filter(Column("taskId") == taskId)
            .order(Column("ts").desc, Column("id").desc)
            .fetchOne(db)
        let ms = e?.ts ?? Int64(Date().timeIntervalSince1970 * 1000)
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }
}
