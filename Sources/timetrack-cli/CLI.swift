import Foundation
import TimeTrackKit

// MARK: - Error type

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case notFound(String)
    case message(String)

    var description: String {
        switch self {
        case .usage(let s):    return "usage: \(s)"
        case .notFound(let s): return "not found: \(s)"
        case .message(let s):  return s
        }
    }
}

// MARK: - Data directory

// Platform-specific location for events.db and profiles.yaml.
func defaultDataDir() -> URL {
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

enum CLI {
    static func run(args: [String]) throws {
        let dataDir = defaultDataDir()
        let store = try Store(url: dataDir.appendingPathComponent("events.db"))

        guard let command = args.first else {
            printHelp()
            return
        }

        let rest = Array(args.dropFirst())
        switch command {
        case "start":      try cmdStart(rest, store: store)
        case "stop":       try cmdStop(store: store)
        case "switch":     try cmdSwitch(rest, store: store)
        case "status":     try cmdStatus(store: store)
        case "report":     try cmdReport(rest, store: store)
        case "known":      try cmdKnown(rest, store: store)
        case "reconcile":  try cmdReconcile(rest, store: store)
        case "help", "--help", "-h":
            printHelp()
        default:
            throw CLIError.usage("unknown command '\(command)'. Run 'timetrack help'.")
        }
    }
}

// MARK: - start

private func cmdStart(_ args: [String], store: Store) throws {
    guard let nameOrId = args.first else {
        throw CLIError.usage("timetrack start <task-name-or-id>")
    }
    let task = try resolveOrCreateTask(nameOrId, store: store)
    guard let taskId = task.id else { throw CLIError.message("failed to obtain task id") }

    // Stop any active tracking before starting fresh.
    switch try store.currentStatus() {
    case .tracking(let cur, _), .armed(let cur, _, _):
        try appendStop(prevTaskId: cur.id, store: store)
    case .idle:
        break
    }

    try appendStart(taskId: taskId, store: store)
    print("Started tracking: \(task.name)")
}

// MARK: - stop

private func cmdStop(store: Store) throws {
    switch try store.currentStatus() {
    case .idle:
        print("Not currently tracking.")
    case .tracking(let task, let since), .armed(let task, _, let since):
        try appendStop(prevTaskId: task.id, store: store)
        let elapsed = Int(Date().timeIntervalSince(since))
        print("Stopped tracking: \(task.name) (\(formatDuration(elapsed)) elapsed)")
    }
}

// MARK: - switch

private func cmdSwitch(_ args: [String], store: Store) throws {
    guard let nameOrId = args.first else {
        throw CLIError.usage("timetrack switch <task-name-or-id>")
    }
    let task = try resolveOrCreateTask(nameOrId, store: store)
    guard let taskId = task.id else { throw CLIError.message("failed to obtain task id") }

    switch try store.currentStatus() {
    case .idle:
        try appendStart(taskId: taskId, store: store)
        print("Started tracking: \(task.name)")
    case .tracking(let prev, _), .armed(let prev, _, _):
        guard let prevId = prev.id else { return }
        if prevId == taskId {
            print("Already tracking: \(task.name)")
            return
        }
        try store.append(Event(
            id: nil, ts: 0, type: EventType.switch.rawValue,
            taskId: taskId, prevTaskId: prevId,
            phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))
        print("Switched to: \(task.name)")
    }
}

// MARK: - status

private func cmdStatus(store: Store) throws {
    switch try store.currentStatus() {
    case .idle:
        print("Idle")
    case .tracking(let task, let since):
        let elapsed = Int(Date().timeIntervalSince(since))
        print("Tracking: \(task.name)  (\(formatDuration(elapsed)))")
    case .armed(let task, let phase, let since):
        let elapsed = Int(Date().timeIntervalSince(since))
        print("Armed: \(task.name)  [phase: \(phase), \(formatDuration(elapsed)) elapsed — awaiting ack]")
    }
}

// MARK: - report

private func cmdReport(_ args: [String], store: Store) throws {
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

    let cal = Calendar.current
    var day = cal.startOfDay(for: from)
    let end = cal.startOfDay(for: to)
    let multiDay = from != to

    while day <= end {
        let rows = try store.report(day: day).filter { $0.totalSeconds > 0 }
        if multiDay {
            print(formatDate(day))
            if rows.isEmpty {
                print("  (no activity)")
            } else {
                for r in rows {
                    print("  \(r.task.name.padRight(30)) \(formatDuration(r.totalSeconds))")
                }
                let total = rows.reduce(0) { $0 + $1.totalSeconds }
                print("  Total: \(formatDuration(total))")
            }
            print("")
        } else {
            if rows.isEmpty {
                print("No activity today.")
            } else {
                for r in rows {
                    print("  \(r.task.name.padRight(30)) \(formatDuration(r.totalSeconds))")
                }
                let total = rows.reduce(0) { $0 + $1.totalSeconds }
                print("Total: \(formatDuration(total))")
            }
        }
        day = cal.date(byAdding: .day, value: 1, to: day)!
    }
}

// MARK: - known

private func cmdKnown(_ args: [String], store: Store) throws {
    guard let sub = args.first else {
        throw CLIError.usage("timetrack known <list|add|promote|retire>")
    }
    let rest = Array(args.dropFirst())
    switch sub {
    case "list":    try cmdKnownList(store: store)
    case "add":     try cmdKnownAdd(rest, store: store)
    case "promote": try cmdKnownPromote(rest, store: store)
    case "retire":  try cmdKnownRetire(rest, store: store)
    default:
        throw CLIError.usage("unknown known subcommand '\(sub)'")
    }
}

private func cmdKnownList(store: Store) throws {
    let tasks = try store.knownTasks(activeOnly: false)
    if tasks.isEmpty {
        print("No known tasks.")
        return
    }
    print("ID".padRight(6) + "Key".padRight(16) + "Description".padRight(42) + "Status")
    print(String(repeating: "-", count: 72))
    for k in tasks {
        let idStr = k.id.map(String.init) ?? "?"
        let key = k.jiraKey ?? "(none)"
        let status = k.retired ? "retired" : (k.provisional ? "provisional" : "active")
        let desc = String(k.description.prefix(40))
        print(idStr.padRight(6) + key.padRight(16) + desc.padRight(42) + status)
    }
}

private func cmdKnownAdd(_ args: [String], store: Store) throws {
    if args.first == "--provisional" {
        let description = args.dropFirst().joined(separator: " ")
        guard !description.isEmpty else {
            throw CLIError.usage("timetrack known add --provisional <description>")
        }
        let k = try store.addKnownTask(jiraKey: nil, description: description)
        print("Added provisional known task #\(k.id.map(String.init) ?? "?"): \(k.description)")
    } else if args.count >= 2 {
        let jiraKey = args[0]
        let description = args.dropFirst().joined(separator: " ")
        let k = try store.addKnownTask(jiraKey: jiraKey, description: description)
        print("Added known task #\(k.id.map(String.init) ?? "?"): [\(jiraKey)] \(k.description)")
    } else {
        throw CLIError.usage(
            "timetrack known add <jira-key> <description>\n" +
            "       timetrack known add --provisional <description>")
    }
}

private func cmdKnownPromote(_ args: [String], store: Store) throws {
    guard args.count >= 2, let id = Int64(args[0]) else {
        throw CLIError.usage("timetrack known promote <id> <jira-key>")
    }
    try store.promoteKnownTask(id: id, jiraKey: args[1])
    print("Promoted known task #\(id) → \(args[1])")
}

private func cmdKnownRetire(_ args: [String], store: Store) throws {
    guard let idStr = args.first, let id = Int64(idStr) else {
        throw CLIError.usage("timetrack known retire <id>")
    }
    try store.retireKnownTask(id: id)
    print("Retired known task #\(id).")
}

// MARK: - reconcile

private func cmdReconcile(_ args: [String], store: Store) throws {
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

    do {
        let rows = try store.reconciledReport(from: from, to: to)
        if rows.isEmpty {
            print("Nothing reportable for \(formatDate(from))–\(formatDate(to)).")
            return
        }
        print("Reconciled report (\(formatDate(from))–\(formatDate(to))):")
        for row in rows {
            print("  \(row.jiraKey.padRight(18)) \(formatDuration(row.totalSeconds))")
        }
        let total = rows.reduce(0) { $0 + $1.totalSeconds }
        print("  Total: \(formatDuration(total))")
    } catch Store.ReconcileError.unbound(let tasks) {
        print("Unreconciled tasks (\(formatDate(from))–\(formatDate(to))):")
        for t in tasks {
            print("  \(t.task.name.padRight(30)) \(formatDuration(t.totalSeconds))  [no binding]")
        }
        print("\nBind each task to a known task, then re-run reconcile.")
        print("(Known task management: timetrack known list / add / promote)")
    } catch Store.ReconcileError.provisional(let known) {
        print("Provisional known tasks with time must be promoted first:")
        for k in known {
            let idStr = k.id.map(String.init) ?? "?"
            print("  #\(idStr)  \(k.description)")
        }
        print("\nPromote with: timetrack known promote <id> <jira-key>")
    }
}

// MARK: - Helpers

private func resolveOrCreateTask(_ nameOrId: String, store: Store) throws -> Task {
    // Try as an integer task ID first.
    if let id = Int64(nameOrId) {
        let all = try store.tasks(includeArchived: true)
        if let found = all.first(where: { $0.id == id }) { return found }
        throw CLIError.notFound("task with id \(id)")
    }
    // Case-insensitive name lookup among active tasks.
    let all = try store.tasks()
    if let found = all.first(where: { $0.name.lowercased() == nameOrId.lowercased() }) {
        return found
    }
    // No match — create a new ad-hoc task.
    var t = Task(id: nil, name: nameOrId, code: nil, category: "project", archived: false)
    t = try store.upsertTask(t)
    print("Created new task: \(nameOrId)")
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
func formatDuration(_ seconds: Int) -> String {
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

private func parseDate(_ string: String) -> Date? {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    return df.date(from: string)
}

private func printHelp() {
    print("""
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
    """)
}

// MARK: - String utilities

extension String {
    func padRight(_ width: Int) -> String {
        guard count < width else { return self }
        return self + String(repeating: " ", count: width - count)
    }
}
