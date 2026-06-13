import Foundation
import Yams

// Ingests tasks.yaml into the tasks table.
//
// tasks.yaml is one of three task sources (DESIGN.md "Task sources").
// It is the hand-edited durable source for overhead, recurring projects, and
// any task the user wants to name before they start tracking. The picker merges
// all sources deduped by code; ingest only writes/updates rows — it never
// removes rows absent from the file, because those may have originated from
// ad-hoc capture or jira_cache.json.
//
// This type is a platform-agnostic utility in TimeTrackKit. No AppKit, no UI.
public enum TasksLoader {

    // Thrown when the yaml file fails business-rule validation, or when the
    // DB state makes an entry's identity ambiguous (the tasks table has no
    // UNIQUE constraint on code or name, so duplicates can pre-exist).
    // Descriptive messages name the offending value so the user can fix it.
    public enum ValidationError: Error, CustomStringConvertible {
        case emptyName
        case duplicateCode(String)
        case duplicateCodelessName(String)
        case reservedCategory(String)   // "break" is synthetic; user tasks must not claim it
        case unknownCategory(String)
        case ambiguousCode(String, ids: [Int64])
        case ambiguousCodelessName(String, ids: [Int64])

        public var description: String {
            switch self {
            case .emptyName:
                return "tasks.yaml: task name must not be empty"
            case .duplicateCode(let code):
                return "tasks.yaml: duplicate code '\(code)' — each code must appear at most once"
            case .duplicateCodelessName(let name):
                return "tasks.yaml: duplicate name '\(name)' among entries that have no code"
            case .reservedCategory(let name):
                return "tasks.yaml: task '\(name)' uses category 'break', which is reserved for the synthetic break task"
            case .unknownCategory(let cat):
                return "tasks.yaml: unknown category '\(cat)' — must be one of: project, overhead, meeting"
            case .ambiguousCode(let code, let ids):
                return "tasks.yaml: code '\(code)' matches multiple existing tasks (ids \(ids.map(String.init).joined(separator: ", "))) — archive or merge the duplicates, then re-run"
            case .ambiguousCodelessName(let name, let ids):
                return "tasks.yaml: name '\(name)' matches multiple existing code-less tasks (ids \(ids.map(String.init).joined(separator: ", "))) — archive or merge the duplicates, then re-run"
            }
        }
    }

    // Valid user-visible categories. "break" is excluded: it belongs to the
    // synthetic task managed by Store.ensureBreakTask and must never be claimed
    // by yaml-sourced tasks.
    private static let validCategories: Set<String> = ["project", "overhead", "meeting"]

    // Ingest yaml at `url` into the store's tasks table.
    //
    // Returns the number of rows that were inserted or updated (0 if the file
    // is absent or the file's state already matches the DB). File absence is a
    // silent no-op — tasks.yaml is optional; the app runs fine without it.
    //
    // Identity rules:
    //   - Entry with a non-nil code: matched to an existing row by code.
    //   - Entry without a code:      matched to an existing row by exact name
    //                                among code-less rows.
    //
    // On match: update name + category from yaml; preserve id and archived flag.
    //           Count the row only if something actually changed.
    // No match: insert with archived = false.
    //
    // Rows absent from the yaml are left untouched — yaml is one source among
    // several; removing a task from the file must not archive DB rows.
    //
    // Known limitation: adding a `code` to a yaml entry that previously had
    // none creates a NEW coded row; the old code-less row (and its time) stays
    // behind under the same name. Identity is the code when present, the name
    // only among code-less rows — there is no cross-promotion, because guessing
    // a name↔code merge could silently reattribute logged time. Reconcile the
    // old row's time via the normal bind flow and archive it manually.
    //
    // The synthetic break task (category == "break") is never modified.
    @discardableResult
    public static func ingest(from url: URL, into store: Store) throws -> Int {
        // Missing file → silent no-op (absence of optional sources is fine per DESIGN.md).
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }

        let yaml = try String(contentsOf: url, encoding: .utf8)
        let entries = try parse(yaml: yaml)

        // Read all existing tasks (including archived) so we can match and update.
        let existing = try store.tasks(includeArchived: true)

        var insertedOrUpdated = 0
        for entry in entries {
            if let code = entry.code {
                // Code-keyed entry: identity is the code. The tasks table has no
                // UNIQUE constraint on code, so pre-existing duplicates would make
                // "which row do I update" arbitrary — fail loudly instead of
                // silently picking one (no heuristic ever decides; see CLAUDE.md).
                let matches = existing.filter { $0.code == code && $0.category != "break" }
                guard matches.count <= 1 else {
                    throw ValidationError.ambiguousCode(code, ids: matches.compactMap(\.id))
                }
                if let row = matches.first {
                    // Update if name or category differs.
                    if row.name != entry.name || row.category != entry.category {
                        var updated = row
                        updated.name = entry.name
                        updated.category = entry.category
                        _ = try store.upsertTask(updated)
                        insertedOrUpdated += 1
                    }
                } else {
                    // New row.
                    let task = Task(id: nil, name: entry.name, code: code,
                                   category: entry.category, archived: false)
                    _ = try store.upsertTask(task)
                    insertedOrUpdated += 1
                }
            } else {
                // Code-less entry: identity is the exact name among code-less rows.
                // Same ambiguity guard as the code-keyed branch: duplicate names
                // can pre-exist (no UNIQUE constraint), and updating an arbitrary
                // one would silently reattribute the yaml edit.
                let matches = existing.filter {
                    $0.code == nil && $0.category != "break" && $0.name == entry.name
                }
                guard matches.count <= 1 else {
                    throw ValidationError.ambiguousCodelessName(entry.name, ids: matches.compactMap(\.id))
                }
                if let row = matches.first {
                    if row.category != entry.category {
                        var updated = row
                        updated.category = entry.category
                        _ = try store.upsertTask(updated)
                        insertedOrUpdated += 1
                    }
                } else {
                    let task = Task(id: nil, name: entry.name, code: nil,
                                   category: entry.category, archived: false)
                    _ = try store.upsertTask(task)
                    insertedOrUpdated += 1
                }
            }
        }
        return insertedOrUpdated
    }

    // MARK: - YAML parsing

    // Internal decoded representation before validation.
    private struct RawEntry: Codable {
        let name: String
        let code: String?
        let category: String?
    }

    private struct Wrapper: Codable {
        let tasks: [RawEntry]
    }

    // Validated, trimmed entry ready for DB upsert.
    private struct Entry {
        let name: String
        let code: String?   // nil if absent or whitespace-only after trim
        let category: String
    }

    private static func parse(yaml: String) throws -> [Entry] {
        let decoder = YAMLDecoder()
        let wrapper = try decoder.decode(Wrapper.self, from: yaml)

        var seenCodes: Set<String> = []
        var seenCodelessNames: Set<String> = []
        var entries: [Entry] = []

        for raw in wrapper.tasks {
            // Trim all fields with .whitespacesAndNewlines (.whitespaces alone
            // misses newlines, which quoted YAML scalars can carry): a
            // newline-only name must fail emptyName, and "project " must not
            // fail as an unknown category.
            let name = raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ValidationError.emptyName }

            let code: String? = raw.code.flatMap {
                let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            // Whitespace-only category is treated as absent, same as code.
            let category: String = raw.category.flatMap {
                let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            } ?? "project"

            // Category validation: reject "break" before the generic unknown check
            // so the error message is maximally informative.
            if category == "break" { throw ValidationError.reservedCategory(name) }
            guard validCategories.contains(category) else {
                throw ValidationError.unknownCategory(category)
            }

            // Duplicate detection (within the file).
            if let c = code {
                if seenCodes.contains(c) { throw ValidationError.duplicateCode(c) }
                seenCodes.insert(c)
            } else {
                if seenCodelessNames.contains(name) { throw ValidationError.duplicateCodelessName(name) }
                seenCodelessNames.insert(name)
            }

            entries.append(Entry(name: name, code: code, category: category))
        }

        return entries
    }
}
