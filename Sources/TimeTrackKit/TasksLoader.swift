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

    // Thrown when the yaml file fails business-rule validation.
    // Descriptive messages name the offending value so the user can fix the file.
    public enum ValidationError: Error, CustomStringConvertible {
        case emptyName
        case duplicateCode(String)
        case duplicateCodelessName(String)
        case reservedCategory(String)   // "break" is synthetic; user tasks must not claim it
        case unknownCategory(String)

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
                // Code-keyed entry: identity is the code.
                if let row = existing.first(where: { $0.code == code && $0.category != "break" }) {
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
                let codelessExisting = existing.filter { $0.code == nil && $0.category != "break" }
                if let row = codelessExisting.first(where: { $0.name == entry.name }) {
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
            let name = raw.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw ValidationError.emptyName }

            let code: String? = raw.code.flatMap {
                let t = $0.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : t
            }
            let category = raw.category ?? "project"

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
