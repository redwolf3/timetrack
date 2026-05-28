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
}

public struct Task: Codable, FetchableRecord, PersistableRecord, Identifiable {
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
}

// The Known Tasks registry — the curated spine. Maintained during iteration
// prep. The ONLY valid reconciliation target. Provisional entries may exist
// without a real jiraKey (loose-until-reconciled, one level up); they block the
// final report until promoted. "Overhead" is not a property here — time is
// overhead purely by virtue of being bound to the overhead JIRA, which is an
// ordinary registry entry.
public struct KnownTask: Codable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: Int64?
    public var jiraKey: String?        // nil iff provisional
    public var description: String
    public var provisional: Bool
    public var retired: Bool           // carried out of the active list between iterations
    public var createdTs: Int64

    public static let databaseTableName = "known_tasks"

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

    public static let databaseTableName = "events"

    public init(id: Int64?, ts: Int64, type: String,
                taskId: Int64?, prevTaskId: Int64?,
                phaseId: String?, profileName: String?,
                extendMin: Int?, comment: String?,
                rangeStart: Int64? = nil, rangeEnd: Int64? = nil,
                knownTaskId: Int64? = nil, jiraKey: String? = nil) {
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

    public func breakTaskId() throws -> Int64 {
        try dbQueue.read { db in
            try Task.filter(Column("category") == "break")
                .fetchOne(db)?.id ?? -1
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
                .order(Column("ts").desc)
                .fetchOne(db)

            let today = try Event
                .filter(Column("ts") >= startMs && Column("ts") < endMs)
                .order(Column("ts"))
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
             .none:               return current
        }
    }

    // MARK: - Known Tasks registry (prep)
    //
    // The curated spine. The only valid reconciliation target. Provisional
    // entries have no jiraKey yet and block the final report until promoted.

    public func knownTasks(activeOnly: Bool = true) throws -> [KnownTask] {
        try dbQueue.read { db in
            var req = KnownTask.all()
            if activeOnly { req = req.filter(Column("retired") == false) }
            return try req.order(Column("createdTs").desc).fetchAll(db)
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

    // Promote a provisional entry by attaching its real JIRA key. Because binds
    // reference the registry id (not the key), every prior binding to this entry
    // now resolves to the real key automatically — no re-binding.
    public func promoteKnownTask(id: Int64, jiraKey: String) throws {
        try dbQueue.write { db in
            if var k = try KnownTask.fetchOne(db, key: id) {
                k.jiraKey = jiraKey
                k.provisional = false
                try k.update(db)
            }
        }
    }

    public func retireKnownTask(id: Int64) throws {
        try dbQueue.write { db in
            if var k = try KnownTask.fetchOne(db, key: id) {
                k.retired = true
                try k.update(db)
            }
        }
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
}
