import Foundation
import Yams

// Ingests known_tasks.yaml into the known_tasks registry — the reconcile spine.
//
// The Known Tasks registry is the curated set of valid reconciliation targets
// (DESIGN.md "Reconcile gate"). Until now it was populated only via the CLI
// (`known add` / `promote` / `retire`). This loader lets the user bulk-define
// the valid-JIRA spine from a hand-edited file, before jira-sync lands or for
// non-JIRA setups. The file is one source among several (CLI, future jira-sync),
// so ingest only inserts/promotes — it never retires rows absent from the file.
//
// Append-only invariant (CLAUDE.md): a promote is a *correction applied at
// report time*, not a mutation of history. Attaching a real jiraKey to an entry
// that exists only provisionally therefore goes through Store.promoteKnownTask
// (which appends a known_task_promote event) — the loader never writes jiraKey
// or provisional onto a base row directly. Description, by contrast, is a plain
// label that the overlay never touches, so it is updated in place (mirroring how
// TasksLoader updates a task's name).
//
// This type is a platform-agnostic utility in TimeTrackKit. No AppKit, no UI.
public enum KnownTasksLoader {

    // Thrown when the yaml fails business-rule validation, or when the registry
    // state makes an entry's identity ambiguous (known_tasks has no UNIQUE
    // constraint on jiraKey, so duplicates can pre-exist via the CLI). Messages
    // name the offending value so the user can fix the file or the registry.
    public enum ValidationError: Error, CustomStringConvertible {
        case emptyDescription
        case duplicateJiraKey(String)
        case duplicateProvisionalDescription(String)
        case ambiguousJiraKey(String, ids: [Int64])
        case ambiguousProvisionalDescription(String, ids: [Int64])

        public var description: String {
            switch self {
            case .emptyDescription:
                return "known_tasks.yaml: description must not be empty"
            case .duplicateJiraKey(let key):
                return "known_tasks.yaml: duplicate jiraKey '\(key)' — each key must appear at most once"
            case .duplicateProvisionalDescription(let desc):
                return "known_tasks.yaml: duplicate description '\(desc)' among provisional entries (those with no jiraKey)"
            case .ambiguousJiraKey(let key, let ids):
                return "known_tasks.yaml: jiraKey '\(key)' matches multiple registry entries (ids \(ids.map(String.init).joined(separator: ", "))) — retire or merge the duplicates, then re-run"
            case .ambiguousProvisionalDescription(let desc, let ids):
                return "known_tasks.yaml: description '\(desc)' matches multiple provisional registry entries (ids \(ids.map(String.init).joined(separator: ", "))) — promote or retire the duplicates, then re-run"
            }
        }
    }

    // Ingest yaml at `url` into the store's known_tasks registry.
    //
    // Returns the number of registry changes (inserts + promotes + description
    // updates); 0 if the file is absent or its state already matches the
    // registry. File absence is a silent no-op — known_tasks.yaml is optional.
    //
    // Identity rules (per yaml entry):
    //   - Entry WITH a jiraKey:
    //       1. Match an existing entry by jiraKey → update description if changed.
    //       2. Else match a PROVISIONAL entry by description → promote it
    //          (append-only known_task_promote; the binds, which reference the
    //          registry id, resolve to the new key automatically).
    //       3. Else insert a new keyed (non-provisional) entry.
    //   - Entry WITHOUT a jiraKey (provisional):
    //       Match a provisional entry by description → no-op; else insert.
    //
    // Matching is over the effective registry INCLUDING retired entries (the
    // overlay is applied first). Retired entries are never resurrected by the
    // loader — un-retiring is a deliberate CLI action — but a retired entry's
    // description may still be corrected in place.
    //
    // Entries absent from the yaml are left untouched: the file is one source
    // among several, so removing a line must not retire a registry entry.
    @discardableResult
    public static func ingest(from url: URL, into store: Store) throws -> Int {
        // Missing file → silent no-op (absence of optional sources is fine per DESIGN.md).
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }

        let yaml = try String(contentsOf: url, encoding: .utf8)
        let entries = try parse(yaml: yaml)

        // Effective registry (overlay applied), including retired, so matching
        // sees current jiraKey/provisional state and never re-inserts a promoted
        // or retired entry.
        let existing = try store.knownTasks(activeOnly: false)

        var changes = 0
        for entry in entries {
            if let jiraKey = entry.jiraKey {
                // 1. Match by jiraKey. No UNIQUE constraint exists, so pre-existing
                //    duplicates make "which row" arbitrary — fail loudly rather
                //    than silently pick one (no heuristic ever decides; CLAUDE.md).
                let keyMatches = existing.filter { $0.jiraKey == jiraKey }
                guard keyMatches.count <= 1 else {
                    throw ValidationError.ambiguousJiraKey(jiraKey, ids: keyMatches.compactMap(\.id))
                }
                if let row = keyMatches.first {
                    if row.description != entry.description, let id = row.id {
                        _ = try store.updateKnownTaskDescription(id: id, description: entry.description)
                        changes += 1
                    }
                    continue
                }

                // 2. No key match — see if a provisional entry with this exact
                //    description should be promoted to the real key.
                let provMatches = existing.filter { $0.provisional && $0.description == entry.description }
                guard provMatches.count <= 1 else {
                    throw ValidationError.ambiguousProvisionalDescription(entry.description, ids: provMatches.compactMap(\.id))
                }
                if let row = provMatches.first, let id = row.id {
                    // Append-only promote; the base row is never mutated.
                    _ = try store.promoteKnownTask(id: id, jiraKey: jiraKey)
                    changes += 1
                    continue
                }

                // 3. Brand new keyed entry.
                _ = try store.addKnownTask(jiraKey: jiraKey, description: entry.description)
                changes += 1
            } else {
                // Provisional entry: identity is the description among provisional
                // entries. Same ambiguity guard as above.
                let provMatches = existing.filter { $0.provisional && $0.description == entry.description }
                guard provMatches.count <= 1 else {
                    throw ValidationError.ambiguousProvisionalDescription(entry.description, ids: provMatches.compactMap(\.id))
                }
                if provMatches.first != nil {
                    continue   // already present — nothing to change
                }
                _ = try store.addKnownTask(jiraKey: nil, description: entry.description)
                changes += 1
            }
        }
        return changes
    }

    // MARK: - YAML parsing

    // Internal decoded representation before validation.
    private struct RawEntry: Codable {
        let description: String
        let jiraKey: String?
    }

    private struct Wrapper: Codable {
        let knownTasks: [RawEntry]

        enum CodingKeys: String, CodingKey {
            case knownTasks = "known_tasks"
        }
    }

    // Validated, trimmed entry ready for registry upsert.
    private struct Entry {
        let description: String
        let jiraKey: String?   // nil if absent or whitespace-only after trim
    }

    private static func parse(yaml: String) throws -> [Entry] {
        let decoder = YAMLDecoder()
        let wrapper = try decoder.decode(Wrapper.self, from: yaml)

        var seenKeys: Set<String> = []
        var seenProvisionalDescriptions: Set<String> = []
        var entries: [Entry] = []

        for raw in wrapper.knownTasks {
            // Trim with .whitespacesAndNewlines (.whitespaces alone misses
            // newlines that quoted YAML scalars can carry).
            let description = raw.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else { throw ValidationError.emptyDescription }

            // Whitespace-only jiraKey is treated as absent (provisional). The key
            // is an opaque identifier here — non-JIRA setups are supported, so no
            // format validation beyond non-emptiness.
            let jiraKey: String? = raw.jiraKey.flatMap {
                let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }

            // Duplicate detection within the file. Keyed and provisional entries
            // are deduped in separate namespaces, mirroring TasksLoader (code vs
            // code-less name): the same description may appear once keyed and once
            // provisional without colliding.
            if let key = jiraKey {
                if seenKeys.contains(key) { throw ValidationError.duplicateJiraKey(key) }
                seenKeys.insert(key)
            } else {
                if seenProvisionalDescriptions.contains(description) {
                    throw ValidationError.duplicateProvisionalDescription(description)
                }
                seenProvisionalDescriptions.insert(description)
            }

            entries.append(Entry(description: description, jiraKey: jiraKey))
        }

        return entries
    }
}
