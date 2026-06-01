import Foundation
import TimeTrackKit

// MARK: - Error type

public enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case notFound(String)
    case message(String)

    public var description: String {
        switch self {
        case .usage(let s):    return "usage: \(s)"
        case .notFound(let s): return "not found: \(s)"
        case .message(let s):  return s
        }
    }
}

// MARK: - Output sink
//
// The core never writes to stdout directly. main.swift injects a sink that
// writes to standard output; tests inject a collecting sink to capture lines.
// This keeps the library platform-agnostic and deterministic under test while
// preserving the executable's identical observable behavior (one line per call,
// terminated by a newline — exactly what print(_:) does).
public protocol CLIOutput {
    func write(_ line: String)
}

/// Default sink used by the executable: behaves exactly like `print`.
public struct StandardOutput: CLIOutput {
    public init() {}
    public func write(_ line: String) { print(line) }
}

/// Collects emitted lines for inspection in tests.
public final class CapturingOutput: CLIOutput {
    public private(set) var lines: [String] = []
    public init() {}
    public func write(_ line: String) { lines.append(line) }
    /// Joined with newlines and a trailing newline, matching what a sequence of
    /// `print` calls would have produced on stdout.
    public var text: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Data directory

// Platform-specific location for events.db and profiles.yaml.
// Can be overridden via TIMETRACK_DATA_DIR environment variable (useful for
// testing and alternative installations).
public func defaultDataDir() -> URL {
    if let override = ProcessInfo.processInfo.environment["TIMETRACK_DATA_DIR"] {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    #if os(macOS)
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("timetrack", isDirectory: true)
    #else
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".local/share/timetrack", isDirectory: true)
    #endif
}

// MARK: - Top-level dispatch

public enum CLI {
    /// Testable entry point. Pass explicit `arguments` (already stripped of the
    /// executable name, as `CommandLine.arguments.dropFirst()` would be), an
    /// optional `dataDir` (a temp directory under test; nil falls back to
    /// `defaultDataDir()`, which honors TIMETRACK_DATA_DIR), and an output sink
    /// (`StandardOutput()` for the executable, `CapturingOutput()` for tests).
    ///
    /// Returns normally on success and throws `CLIError` on a usage/lookup
    /// failure. It never calls `exit()` — main.swift owns process exit codes.
    public static func run(
        arguments: [String],
        dataDir: URL? = nil,
        out: CLIOutput = StandardOutput()
    ) throws {
        let dir = dataDir ?? defaultDataDir()
        let store = try Store(url: dir.appendingPathComponent("events.db"))

        guard let command = arguments.first else {
            printHelp(out)
            return
        }

        let rest = Array(arguments.dropFirst())
        switch command {
        case "start":      try cmdStart(rest, store: store, dataDir: dir, out: out)
        case "stop":       try cmdStop(store: store, out: out)
        case "switch":     try cmdSwitch(rest, store: store, dataDir: dir, out: out)
        case "status":     try cmdStatus(store: store, out: out)
        case "report":     try cmdReport(rest, store: store, out: out)
        case "known":      try cmdKnown(rest, store: store, out: out)
        case "reconcile":  try cmdReconcile(rest, store: store, out: out)
        case "bind":       try cmdBind(rest, store: store, out: out)
        case "help", "--help", "-h":
            printHelp(out)
        default:
            throw CLIError.usage("unknown command '\(command)'. Run 'timetrack help'.")
        }
    }

    /// Convenience used by the executable shell: build the standard argv-derived
    /// argument list (without the executable name) and run against the default
    /// data dir with stdout. Kept here so main.swift stays a one-liner.
    public static func run(args: [String]) throws {
        try run(arguments: args, dataDir: nil, out: StandardOutput())
    }
}

// MARK: - start

private func cmdStart(_ args: [String], store: Store, dataDir: URL, out: CLIOutput) throws {
    guard let nameOrId = args.first else {
        throw CLIError.usage("timetrack start <task-name-or-id>")
    }
    let task = try resolveOrCreateTask(nameOrId, store: store, out: out)
    guard let taskId = task.id else { throw CLIError.message("failed to obtain task id") }

    // Stop any active tracking before starting fresh.
    switch try store.currentStatus() {
    case .tracking(let cur, _), .armed(let cur, _, _):
        try appendStop(prevTaskId: cur.id, store: store)
    case .idle:
        break
    }

    try appendStart(taskId: taskId, store: store)
    out.write("Started tracking: \(task.name)")
}

// MARK: - stop

private func cmdStop(store: Store, out: CLIOutput) throws {
    switch try store.currentStatus() {
    case .idle:
        out.write("Not currently tracking.")
    case .tracking(let task, let since), .armed(let task, _, let since):
        try appendStop(prevTaskId: task.id, store: store)
        let elapsed = Int(Date().timeIntervalSince(since))
        out.write("Stopped tracking: \(task.name) (\(formatDuration(elapsed)) elapsed)")
    }
}

// MARK: - switch

private func cmdSwitch(_ args: [String], store: Store, dataDir: URL, out: CLIOutput) throws {
    guard let nameOrId = args.first else {
        throw CLIError.usage("timetrack switch <task-name-or-id>")
    }
    let task = try resolveOrCreateTask(nameOrId, store: store, out: out)
    guard let taskId = task.id else { throw CLIError.message("failed to obtain task id") }

    switch try store.currentStatus() {
    case .idle:
        try appendStart(taskId: taskId, store: store)
        out.write("Started tracking: \(task.name)")

    case .tracking(let prev, _):
        guard let prevId = prev.id else { return }
        if prevId == taskId {
            out.write("Already tracking: \(task.name)")
            return
        }
        // TRACKING → switch → same phase: a bare switch, no phase change.
        try store.append(Event(
            id: nil, ts: 0, type: EventType.switch.rawValue,
            taskId: taskId, prevTaskId: prevId,
            phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))
        out.write("Switched to: \(task.name)")

    case .armed(let prev, let armedPhaseId, _):
        // DESIGN.md: "ARMED → switch → implicit ack, then switch". The canonical
        // machine (Tracker.switchTo) advances the phase first (appending a
        // phase_advance) THEN switches off the advanced accrual task. A bare
        // switch here would skip the implicit ack and desync the log's phase/
        // cycle position from the machine. The kit owns ALL the phase math now:
        // it reads the nextPhaseId recorded on the latest phase_arm (which
        // captured the long-cycle override, e.g. long_break) and emits the same
        // two-event sequence. The CLI only loads the profile and hands it over —
        // no next-phase computation in the CLI (invariant 3: logic in the kit).
        guard let prevId = prev.id else { return }
        if prevId == taskId {
            out.write("Already tracking: \(task.name)")
            return
        }

        let profileName = try store.currentProfileName() ?? "default"
        let profiles = try ProfileLoader.loadAll(
            from: dataDir.appendingPathComponent("profiles.yaml"))
        guard let profile = profiles.first(where: { $0.name == profileName }) else {
            throw CLIError.message("profile '\(profileName)' not found; cannot advance phase")
        }

        // Kit performs the implicit-ack phase_advance + the switch, matching
        // Tracker.switchTo's event sequence exactly (business logic stays in the
        // kit). It resolves the next phase from the recorded nextPhaseId, with a
        // legacy fallback to the (now override-aware) profile cycle.
        try store.switchFromArmed(
            armedTaskId: prevId, armedPhaseId: armedPhaseId,
            targetTaskId: taskId, profile: profile, comment: nil)
        out.write("Acknowledged armed phase and switched to: \(task.name)")
    }
}

// MARK: - status

private func cmdStatus(store: Store, out: CLIOutput) throws {
    switch try store.currentStatus() {
    case .idle:
        out.write("Idle")
    case .tracking(let task, let since):
        let elapsed = Int(Date().timeIntervalSince(since))
        out.write("Tracking: \(task.name)  (\(formatDuration(elapsed)))")
    case .armed(let task, let phase, let since):
        let elapsed = Int(Date().timeIntervalSince(since))
        out.write("Armed: \(task.name)  [phase: \(phase), \(formatDuration(elapsed)) elapsed — awaiting ack]")
    }
}

// MARK: - report

private func cmdReport(_ args: [String], store: Store, out: CLIOutput) throws {
    var from = Calendar.current.startOfDay(for: Date())
    var to = from

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--from":
            i += 1
            guard i < args.count else { throw CLIError.usage("--from requires YYYY-MM-DD") }
            guard let d = parseDate(args[i]) else { throw CLIError.usage("invalid date: \(args[i])") }
            from = d
        case "--to":
            i += 1
            guard i < args.count else { throw CLIError.usage("--to requires YYYY-MM-DD") }
            guard let d = parseDate(args[i]) else { throw CLIError.usage("invalid date: \(args[i])") }
            to = d
        default:
            throw CLIError.usage("timetrack report [--from YYYY-MM-DD] [--to YYYY-MM-DD]")
        }
        i += 1
    }

    guard to >= from else {
        throw CLIError.usage("--to (\(formatDate(to))) is before --from (\(formatDate(from)))")
    }

    let cal = Calendar.current
    var day = cal.startOfDay(for: from)
    let end = cal.startOfDay(for: to)
    let multiDay = from != to

    while day <= end {
        let rows = try store.report(day: day).filter { $0.totalSeconds > 0 }
        if multiDay {
            out.write(formatDate(day))
            if rows.isEmpty {
                out.write("  (no activity)")
            } else {
                for r in rows {
                    out.write("  \(r.task.name.padRight(30)) \(formatDuration(r.totalSeconds))")
                }
                let total = rows.reduce(0) { $0 + $1.totalSeconds }
                out.write("  Total: \(formatDuration(total))")
            }
            out.write("")
        } else {
            if rows.isEmpty {
                out.write("No activity today.")
            } else {
                for r in rows {
                    out.write("  \(r.task.name.padRight(30)) \(formatDuration(r.totalSeconds))")
                }
                let total = rows.reduce(0) { $0 + $1.totalSeconds }
                out.write("Total: \(formatDuration(total))")
            }
        }
        day = cal.date(byAdding: .day, value: 1, to: day)!
    }
}

// MARK: - known

private func cmdKnown(_ args: [String], store: Store, out: CLIOutput) throws {
    guard let sub = args.first else {
        throw CLIError.usage("timetrack known <list|add|promote|retire>")
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "list":    try cmdKnownList(store: store, out: out)
    case "add":     try cmdKnownAdd(rest, store: store, out: out)
    case "promote": try cmdKnownPromote(rest, store: store, out: out)
    case "retire":  try cmdKnownRetire(rest, store: store, out: out)
    default:
        throw CLIError.usage("unknown known subcommand '\(sub)'")
    }
}

private func cmdKnownList(store: Store, out: CLIOutput) throws {
    let tasks = try store.knownTasks(activeOnly: false)
    if tasks.isEmpty {
        out.write("No known tasks.")
        return
    }
    out.write("ID".padRight(6) + "Key".padRight(16) + "Description".padRight(42) + "Status")
    out.write(String(repeating: "-", count: 72))
    for k in tasks {
        let idStr = k.id.map(String.init) ?? "?"
        let key = k.jiraKey ?? "(none)"
        let status = k.retired ? "retired" : (k.provisional ? "provisional" : "active")
        let desc = String(k.description.prefix(40))
        out.write(idStr.padRight(6) + key.padRight(16) + desc.padRight(42) + status)
    }
}

private func cmdKnownAdd(_ args: [String], store: Store, out: CLIOutput) throws {
    if args.first == "--provisional" {
        let description = args.dropFirst().joined(separator: " ")
        guard !description.isEmpty else {
            throw CLIError.usage("timetrack known add --provisional <description>")
        }
        let k = try store.addKnownTask(jiraKey: nil, description: description)
        out.write("Added provisional known task #\(k.id.map(String.init) ?? "?"): \(k.description)")
    } else if args.count >= 2 {
        let jiraKey = args[0]
        let description = args.dropFirst().joined(separator: " ")
        let k = try store.addKnownTask(jiraKey: jiraKey, description: description)
        out.write("Added known task #\(k.id.map(String.init) ?? "?"): [\(jiraKey)] \(k.description)")
    } else {
        throw CLIError.usage(
            "timetrack known add <jira-key> <description>\n" +
            "       timetrack known add --provisional <description>")
    }
}

private func cmdKnownPromote(_ args: [String], store: Store, out: CLIOutput) throws {
    guard args.count >= 2, let id = Int64(args[0]) else {
        throw CLIError.usage("timetrack known promote <id> <jira-key>")
    }
    let found = try store.promoteKnownTask(id: id, jiraKey: args[1])
    guard found else { throw CLIError.notFound("known task #\(id)") }
    out.write("Promoted known task #\(id) → \(args[1])")
}

private func cmdKnownRetire(_ args: [String], store: Store, out: CLIOutput) throws {
    guard let idStr = args.first, let id = Int64(idStr) else {
        throw CLIError.usage("timetrack known retire <id>")
    }
    let found = try store.retireKnownTask(id: id)
    guard found else { throw CLIError.notFound("known task #\(id)") }
    out.write("Retired known task #\(id).")
}

// MARK: - reconcile

private func cmdReconcile(_ args: [String], store: Store, out: CLIOutput) throws {
    var from = Calendar.current.startOfDay(for: Date())
    var to = from

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--from":
            i += 1
            guard i < args.count else { throw CLIError.usage("--from requires YYYY-MM-DD") }
            guard let d = parseDate(args[i]) else { throw CLIError.usage("invalid date: \(args[i])") }
            from = d
        case "--to":
            i += 1
            guard i < args.count else { throw CLIError.usage("--to requires YYYY-MM-DD") }
            guard let d = parseDate(args[i]) else { throw CLIError.usage("invalid date: \(args[i])") }
            to = d
        default:
            throw CLIError.usage("timetrack reconcile [--from YYYY-MM-DD] [--to YYYY-MM-DD]")
        }
        i += 1
    }

    guard to >= from else {
        throw CLIError.usage("--to (\(formatDate(to))) is before --from (\(formatDate(from)))")
    }

    do {
        let rows = try store.reconciledReport(from: from, to: to)
        if rows.isEmpty {
            out.write("Nothing reportable for \(formatDate(from))–\(formatDate(to)).")
            return
        }
        out.write("Reconciled report (\(formatDate(from))–\(formatDate(to))):")
        for row in rows {
            out.write("  \(row.jiraKey.padRight(18)) \(formatDuration(row.totalSeconds))")
        }
        let total = rows.reduce(0) { $0 + $1.totalSeconds }
        out.write("  Total: \(formatDuration(total))")
    } catch Store.ReconcileError.unbound(let tasks) {
        out.write("Unreconciled tasks (\(formatDate(from))–\(formatDate(to))):")
        for t in tasks {
            out.write("  \(t.task.name.padRight(30)) \(formatDuration(t.totalSeconds))  [no binding]")
        }
        out.write("\nBind each task to a known task, then re-run reconcile:")
        out.write("  timetrack bind <capture-task-name-or-id> <known-task-id>")
        out.write("(List known tasks: timetrack known list. For overhead, bind to the")
        out.write(" overhead JIRA's known-task id — no special flag.)")
    } catch Store.ReconcileError.provisional(let known) {
        out.write("Provisional known tasks with time must be promoted first:")
        for k in known {
            let idStr = k.id.map(String.init) ?? "?"
            out.write("  #\(idStr)  \(k.description)")
        }
        out.write("\nPromote with: timetrack known promote <id> <jira-key>")
    }
}

// MARK: - bind
//
// Clears the reconcile gate for one capture task by binding it to a Known Task.
// This is the ONLY way time becomes reportable (invariant 4): nothing is
// auto-bound. The bind target is the Known Task REGISTRY ID — never a raw JIRA
// key (invariant 5) — so promoting a provisional entry propagates without
// re-binding. Append-only: store.bind appends a reconcile_bind event; nothing
// is mutated. Overhead needs no special path — bind to the overhead JIRA's
// Known Task id and its time is overhead by virtue of the target.

private func cmdBind(_ args: [String], store: Store, out: CLIOutput) throws {
    guard args.count >= 2 else {
        throw CLIError.usage(
            "timetrack bind <capture-task-name-or-id> <known-task-id>\n" +
            "       (for overhead, use the overhead JIRA's known-task id — no special flag)")
    }
    let captureRef = args[0]
    guard let knownId = Int64(args[1]) else {
        throw CLIError.usage("known-task-id must be numeric (see 'timetrack known list')")
    }

    // Resolve the capture task without creating one: binding a non-existent
    // task would be meaningless and could mask a typo.
    // resolveTask uses userTasks(), so system tasks (category == "break") are
    // already excluded. The guard below is a belt-and-suspenders defense in case
    // a future caller path bypasses resolveTask.
    let captureTask = try resolveTask(captureRef, store: store)
    guard captureTask.category != "break" else {
        throw CLIError.notFound("capture task '\(captureRef)'")
    }
    guard let captureId = captureTask.id else {
        throw CLIError.message("capture task '\(captureRef)' has no id")
    }

    // Resolve the Known Task by registry id (include retired so an explicit
    // bind to a carried-out entry still works — the kit decides reportability).
    let known = try store.knownTasks(activeOnly: false)
    guard let target = known.first(where: { $0.id == knownId }) else {
        throw CLIError.notFound("known task #\(knownId) (see 'timetrack known list')")
    }

    // Pass the REGISTRY ID as the target, never a key string (invariant 5).
    try store.bind(taskId: captureId, knownTaskId: knownId, comment: nil)

    let keyDesc = target.jiraKey.map { "[\($0)] " } ?? "(provisional) "
    out.write("Bound '\(captureTask.name)' → known task #\(knownId) \(keyDesc)\(target.description)")
    if target.provisional {
        out.write("Note: this known task is still provisional and will block the reconciled report")
        out.write("      until promoted: timetrack known promote \(knownId) <jira-key>")
    }
}

// MARK: - Helpers

// Resolve an existing capture task by numeric id or (case-insensitive) name.
// Unlike resolveOrCreateTask, this never creates a task — used by bind where
// inventing a task would be wrong.
//
// Uses userTasks() so that system/synthetic tasks (category == "break") are
// invisible to the caller: a reference to the synthetic break task by id or
// name returns notFound rather than silently succeeding and causing time loss.
private func resolveTask(_ nameOrId: String, store: Store) throws -> Task {
    let userAll = try store.userTasks(includeArchived: true)
    if let id = Int64(nameOrId) {
        // Numeric: if the id exists but is a system task it must not be reachable.
        // Check user-visible set only; an id that only exists in system tasks is
        // treated as notFound here (same result, different cause).
        if let found = userAll.first(where: { $0.id == id }) { return found }
        // Numeric id not in user set — could be unknown or a system task; either
        // way it's not resolvable here. Fall through to name lookup to support
        // purely-numeric task names, but if the numeric string matches a name it
        // must also be a user task (guaranteed by userAll).
    }
    if let found = userAll.first(where: { $0.name.lowercased() == nameOrId.lowercased() }) {
        return found
    }
    throw CLIError.notFound("capture task '\(nameOrId)'")
}

private func resolveOrCreateTask(_ nameOrId: String, store: Store, out: CLIOutput) throws -> Task {
    // Try as an integer task ID first.
    // Uses userTasks() to exclude system/synthetic tasks (category == "break").
    // If the integer id exists but is a system task, throw notFound — do NOT
    // fall through and create a task named "1" or similar, which would be
    // confusing. A system task is unreachable by id, period.
    if let id = Int64(nameOrId) {
        let allById = try store.userTasks(includeArchived: true)
        if let found = allById.first(where: { $0.id == id }) { return found }
        // Check if this id is in the FULL task set (including system). If so,
        // it was excluded because it's a system task — surface notFound rather
        // than silently creating a task named after the id.
        let allFull = try store.tasks(includeArchived: true)
        if allFull.contains(where: { $0.id == id }) {
            throw CLIError.notFound("task id \(id) is a system task and cannot be started")
        }
        // Unknown numeric id: fall through to name lookup so purely-numeric task
        // names (e.g. "911") are reachable by name rather than throwing here.
    }

    // Case-insensitive name lookup across user tasks (including archived) so that
    // starting a task whose archived twin exists reuses it rather than silently
    // creating a duplicate that would pollute reconcile.
    // System tasks (category == "break") are excluded — a name collision with a
    // system task falls through to the auto-create path, producing a new ordinary
    // user task rather than reusing the synthetic one.
    let allByName = try store.userTasks(includeArchived: true)
    if let found = allByName.first(where: { $0.name.lowercased() == nameOrId.lowercased() }) {
        if found.archived {
            // Reactivate the archived task instead of creating a duplicate.
            var reactivated = found
            reactivated.archived = false
            let saved = try store.upsertTask(reactivated)
            out.write("Reactivated archived task: \(saved.name)")
            return saved
        }
        return found
    }

    // No match anywhere — create a new ad-hoc task.
    var t = Task(id: nil, name: nameOrId, code: nil, category: "project", archived: false)
    t = try store.upsertTask(t)
    out.write("Created new task: \(nameOrId)")
    return t
}

private func appendStart(taskId: Int64, store: Store) throws {
    try store.append(Event(
        id: nil, ts: 0, type: EventType.start.rawValue,
        taskId: taskId, prevTaskId: nil,
        phaseId: nil, profileName: nil,
        extendMin: nil, comment: nil))
}

private func appendStop(prevTaskId: Int64?, store: Store) throws {
    try store.append(Event(
        id: nil, ts: 0, type: EventType.stop.rawValue,
        taskId: nil, prevTaskId: prevTaskId,
        phaseId: nil, profileName: nil,
        extendMin: nil, comment: nil))
}

// MARK: - Formatting

// Formats a duration in seconds as a human-readable string (e.g. "1h 23m", "45m", "30s").
public func formatDuration(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    let s = seconds % 60
    if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
    if m > 0 { return s > 0 ? "\(m)m \(s)s" : "\(m)m" }
    return "\(s)s"
}

private func formatDate(_ date: Date) -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    return df.string(from: date)
}

public func parseDate(_ string: String) -> Date? {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    return df.date(from: string)
}

private func printHelp(_ out: CLIOutput) {
    out.write("""
    timetrack — CLI time tracker

    Commands:
      start <task-name-or-id>                Start tracking a task
      stop                                   Stop tracking
      switch <task-name-or-id>               Switch task (or start if idle)
      status                                 Show current tracking state
      report [--from YYYY-MM-DD] [--to YYYY-MM-DD]
                                             Daily totals (default: today)
      known list                             List known tasks (all)
      known add <jira-key> <description>     Add known task with JIRA key
      known add --provisional <description>  Add provisional known task
      known promote <id> <jira-key>          Promote provisional → real
      known retire <id>                      Retire a known task
      reconcile [--from YYYY-MM-DD] [--to YYYY-MM-DD]
                                             Show unreconciled tasks or produce
                                             a reconciled JIRA report
      bind <capture-task-name-or-id> <known-task-id>
                                             Bind a capture task to a known task
                                             so its time becomes reportable. For
                                             overhead, bind to the overhead
                                             JIRA's known-task id (no special
                                             flag).
    """)
}

// MARK: - String utilities

extension String {
    func padRight(_ width: Int) -> String {
        guard count < width else { return self }
        return self + String(repeating: " ", count: width - count)
    }
}
