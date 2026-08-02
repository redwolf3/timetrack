import Foundation
import Yams

// Ingests known-task records into the known_tasks registry — the reconcile spine.
//
// The Known Tasks registry is the curated set of valid reconciliation targets
// (DESIGN.md "Reconcile gate"). Until now it was populated only via the CLI
// (`known add` / `promote` / `retire`). This loader lets the user bulk-define
// the valid-JIRA spine from a hand-edited file, before jira-sync lands or for
// non-JIRA setups. The file is one source among several (CLI, future jira-sync,
// JSON/CSV import per docs/interchange-format.md §4.2), so ingest only
// inserts/promotes — it never retires rows absent from the input.
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

    // Public intermediate representation, shared by every source (YAML today;
    // JSON/CSV importers per docs/interchange-format.md §4.2 decode into this
    // same type and hand off to the same `ingest(entries:...)` seam below — no
    // second upsert implementation). `RawEntry`/`Wrapper` are the Yams Codable
    // shims for YAML specifically and stay private; this is the format-neutral
    // shape everything else operates on.
    public struct KnownTaskEntry: Equatable {
        public let description: String
        public let jiraKey: String?   // nil means provisional (absent or whitespace-only after trim)

        // Normalising here rather than in each decoder makes the invariant hold
        // by construction: this is a public seam, so a direct caller gets the
        // same treatment a JSON/CSV/YAML record does. Without it a whitespace-only
        // jiraKey would be persisted as a real key, contradicting the field
        // comment above and docs/interchange-format.md §3, which treats a
        // whitespace-only jira_key as absent.
        public init(description: String, jiraKey: String?) {
            self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedKey = jiraKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.jiraKey = (trimmedKey?.isEmpty ?? true) ? nil : trimmedKey
        }
    }

    // Thrown when an input fails business-rule validation, or when the registry
    // state makes an entry's identity ambiguous (known_tasks has no UNIQUE
    // constraint on jiraKey, so duplicates can pre-exist via the CLI). Messages
    // name the offending value AND the source file, so the user fixes the right
    // one — a source parameter rather than a hardcoded filename, since this is
    // now shared by YAML, JSON, and CSV imports (docs/interchange-format.md §4.2).
    public enum ValidationError: Error, CustomStringConvertible {
        case emptyDescription(source: String)
        case duplicateJiraKey(String, source: String)
        case duplicateProvisionalDescription(String, source: String)
        case ambiguousJiraKey(String, ids: [Int64], source: String)
        case ambiguousProvisionalDescription(String, ids: [Int64], source: String)

        public var description: String {
            switch self {
            case .emptyDescription(let source):
                return "\(source): description must not be empty"
            case .duplicateJiraKey(let key, let source):
                return "\(source): duplicate jiraKey '\(key)' — each key must appear at most once"
            case .duplicateProvisionalDescription(let desc, let source):
                return "\(source): duplicate description '\(desc)' among provisional entries (those with no jiraKey)"
            case .ambiguousJiraKey(let key, let ids, let source):
                return "\(source): jiraKey '\(key)' matches multiple registry entries (ids \(ids.map(String.init).joined(separator: ", "))) — retire or merge the duplicates, then re-run"
            case .ambiguousProvisionalDescription(let desc, let ids, let source):
                return "\(source): description '\(desc)' matches multiple provisional registry entries (ids \(ids.map(String.init).joined(separator: ", "))) — promote or retire the duplicates, then re-run"
            }
        }
    }

    // Structured account of what an ingest did (or, under dryRun, would do) to
    // the registry — one Change per input entry, in input order. Replaces a bare
    // Int total so `--dry-run` (docs/interchange-format.md §4.2) can render the
    // four categories the spec names instead of a single opaque count.
    public struct IngestResult: Equatable {
        // Identifies the registry row a promote/descriptionUpdate/noOp targets.
        // Under `dryRun`, the matched row may be one this same input would
        // insert rather than a row that already exists in the store — e.g. a
        // keyed entry promoting a provisional row a keyless entry earlier in the
        // SAME file would create (§4.2 rule 9's snapshot sync makes that row
        // visible to later entries even though it is not yet real). `.pending`
        // names that case explicitly instead of overloading `Int64`'s sign, so a
        // consumer can never mistake a placeholder for a real, look-up-able id.
        public enum TargetRow: Equatable {
            case existing(Int64)   // a row already in the registry
            case pending           // a row an earlier entry in this same input would create
        }

        public enum Outcome: Equatable {
            case insert
            case promote(target: TargetRow)
            case descriptionUpdate(target: TargetRow, previous: String)
            case noOp(target: TargetRow)
        }

        public struct Change: Equatable {
            public let entry: KnownTaskEntry
            public let outcome: Outcome
        }

        public let changes: [Change]

        // Reproduces the pre-refactor `Int` return: inserts + promotions +
        // description updates. noOps are deliberately excluded — that was the
        // original semantics ("0 if the file is absent or its state already
        // matches the registry").
        public var changeCount: Int {
            changes.reduce(0) { count, change in
                switch change.outcome {
                case .insert, .promote, .descriptionUpdate:
                    return count + 1
                case .noOp:
                    return count
                }
            }
        }
    }

    // Ingest yaml at `url` into the store's known_tasks registry.
    //
    // Returns the number of registry changes (inserts + promotes + description
    // updates); 0 if the file is absent or its state already matches the
    // registry. File absence is a silent no-op — known_tasks.yaml is optional.
    //
    // Thin wrapper over the shared seam: parse YAML into [KnownTaskEntry], then
    // delegate to `ingest(entries:into:sourceName:)` using the file's last path
    // component as the source name for error messages.
    @discardableResult
    public static func ingest(from url: URL, into store: Store) throws -> Int {
        // Missing file → silent no-op (absence of optional sources is fine per DESIGN.md).
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }

        let yaml = try String(contentsOf: url, encoding: .utf8)
        let entries = try parse(yaml: yaml)
        let result = try ingest(entries: entries, into: store, sourceName: url.lastPathComponent)
        return result.changeCount
    }

    // The shared upsert seam (docs/interchange-format.md §4.2): every source —
    // YAML today, JSON/CSV importers later — decodes to [KnownTaskEntry] and
    // calls this. There is exactly one upsert implementation; format-specific
    // code never touches the registry directly.
    //
    // Identity rules (per entry):
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
    // Entries absent from the input are left untouched: the file is one source
    // among several, so removing a line must not retire a registry entry.
    //
    // `dryRun: true` performs zero writes (no addKnownTask / promoteKnownTask /
    // updateKnownTaskDescription calls) but returns exactly the `changes` a real
    // run would produce, by synthesising local rows with negative placeholder
    // ids (real rowids are always positive, so these can never collide) and
    // folding them into the same in-pass snapshot sync a real run uses — see the
    // note on `existing` below. A dry run followed by a real run over the same
    // input therefore yields identical `changes`.
    public static func ingest(
        entries: [KnownTaskEntry],
        into store: Store,
        sourceName: String,
        dryRun: Bool = false
    ) throws -> IngestResult {
        try validateWithinFile(entries, sourceName: sourceName)

        // Effective registry (overlay applied), including retired, so matching
        // sees current jiraKey/provisional state and never re-inserts a promoted
        // or retired entry.
        let initialExisting = try store.knownTasks(activeOnly: false)

        // Both ambiguity errors (rule 7) are properties of PRE-EXISTING registry
        // duplicates (known_tasks has no UNIQUE constraint on jiraKey, so these
        // can only arise via the CLI, never from anything this pass inserts —
        // validateWithinFile above already rejects a jiraKey or provisional
        // description repeated within the file itself). That means both
        // conditions are fully decidable from `initialExisting` alone, before any
        // entry is applied. Scanning for them up front — rather than discovering
        // one three entries into the loop, after those three are already written
        // — means ingest either applies the whole input or writes nothing; a
        // partial apply followed by an error used to leave the registry in a
        // state matching neither the old file nor the new one, with no report of
        // what landed.
        try checkAmbiguity(entries, existing: initialExisting, sourceName: sourceName)

        // Within-pass consistency: `existing` is kept in sync with every promote,
        // insert, and description update performed in the loop — under dryRun
        // via synthesised rows rather than store calls, but the same sync. Without
        // this, later entries in the same input would match against stale state
        // and produce incorrect outcomes — e.g. a provisional promoted earlier in
        // the pass would still appear provisional to a subsequent keyless entry
        // for the same description, causing a spurious re-insert on the next
        // ingest (idempotency broken); or two keyed entries with the same
        // description would each match the same provisional row and emit two
        // promote events for the same registry id (double-promote). This is also
        // why two identical entries in one dryRun input report insert-then-noOp,
        // not insert-twice.
        var existing = initialExisting

        // Placeholder ids for dryRun-synthesised rows. Real rowids are always
        // positive (SQLite AUTOINCREMENT-style rowid), so negative values can
        // never collide with a genuine registry id within this pass. This stays
        // an internal bookkeeping detail — it is how `existing` tracks and
        // mutates a not-yet-real row (rule 9's snapshot sync), but it never
        // leaks past this function: every id handed to a `Change` goes through
        // `targetRow(for:)` below, which turns the sign back into an explicit
        // `TargetRow` case.
        var nextSyntheticId: Int64 = -1
        func synthesizedRow(jiraKey: String?, description: String, provisional: Bool) -> KnownTask {
            defer { nextSyntheticId -= 1 }
            return KnownTask(id: nextSyntheticId, jiraKey: jiraKey, description: description,
                              provisional: provisional, retired: false, createdTs: 0)
        }
        // A negative id names a row synthesised earlier in THIS pass (dryRun
        // only) rather than one that exists in the store.
        func targetRow(for id: Int64) -> IngestResult.TargetRow {
            id > 0 ? .existing(id) : .pending
        }

        var changes: [IngestResult.Change] = []

        for entry in entries {
            if let jiraKey = entry.jiraKey {
                // 1. Match by jiraKey. No UNIQUE constraint exists, so pre-existing
                //    duplicates make "which row" arbitrary — fail loudly rather
                //    than silently pick one (no heuristic ever decides; CLAUDE.md).
                //    checkAmbiguity already rejected this case before the first
                //    write; the guard stays as a backstop in case that invariant
                //    is ever weakened, not as the primary defense.
                let keyMatches = existing.filter { $0.jiraKey == jiraKey }
                guard keyMatches.count <= 1 else {
                    throw ValidationError.ambiguousJiraKey(jiraKey, ids: keyMatches.compactMap(\.id), source: sourceName)
                }
                if let row = keyMatches.first {
                    // Fetched registry rows, and rows this loop synthesises under
                    // dryRun, always carry a non-nil id — the force-unwrap below
                    // documents that invariant rather than defending against it.
                    if row.description != entry.description {
                        let id = row.id!
                        if !dryRun {
                            _ = try store.updateKnownTaskDescription(id: id, description: entry.description)
                        }
                        // Keep snapshot in sync: update this element's description so
                        // a later entry matching by description sees the new value.
                        if let idx = existing.firstIndex(where: { $0.id == id }) {
                            existing[idx].description = entry.description
                        }
                        changes.append(.init(entry: entry, outcome: .descriptionUpdate(target: targetRow(for: id), previous: row.description)))
                    } else {
                        changes.append(.init(entry: entry, outcome: .noOp(target: targetRow(for: row.id!))))
                    }
                    continue
                }

                // 2. No key match — see if a provisional entry with this exact
                //    description should be promoted to the real key. (Backstop
                //    guard — see the note on case 1's ambiguousJiraKey above.)
                let provMatches = existing.filter { $0.provisional && $0.description == entry.description }
                guard provMatches.count <= 1 else {
                    throw ValidationError.ambiguousProvisionalDescription(entry.description, ids: provMatches.compactMap(\.id), source: sourceName)
                }
                if let row = provMatches.first {
                    let id = row.id!
                    // Append-only promote; the base row is never mutated.
                    if !dryRun {
                        _ = try store.promoteKnownTask(id: id, jiraKey: jiraKey)
                    }
                    // Keep snapshot in sync: mark the row non-provisional with its
                    // new key so subsequent entries don't re-match the same provisional
                    // and attempt a second promote on the same registry id.
                    if let idx = existing.firstIndex(where: { $0.id == id }) {
                        existing[idx].jiraKey = jiraKey
                        existing[idx].provisional = false
                    }
                    changes.append(.init(entry: entry, outcome: .promote(target: targetRow(for: id))))
                    continue
                }

                // 3. Brand new keyed entry.
                let inserted = dryRun
                    ? synthesizedRow(jiraKey: jiraKey, description: entry.description, provisional: false)
                    : try store.addKnownTask(jiraKey: jiraKey, description: entry.description)
                // Keep snapshot in sync so later entries can match by key.
                existing.append(inserted)
                changes.append(.init(entry: entry, outcome: .insert))
            } else {
                // Provisional entry: identity is the description among provisional
                // entries. Same ambiguity guard as above.
                let provMatches = existing.filter { $0.provisional && $0.description == entry.description }
                guard provMatches.count <= 1 else {
                    throw ValidationError.ambiguousProvisionalDescription(entry.description, ids: provMatches.compactMap(\.id), source: sourceName)
                }
                if let row = provMatches.first {
                    changes.append(.init(entry: entry, outcome: .noOp(target: targetRow(for: row.id!))))
                    continue
                }
                let inserted = dryRun
                    ? synthesizedRow(jiraKey: nil, description: entry.description, provisional: true)
                    : try store.addKnownTask(jiraKey: nil, description: entry.description)
                // Keep snapshot in sync so a later provisional entry with the same
                // description is correctly recognised as already present.
                existing.append(inserted)
                changes.append(.init(entry: entry, outcome: .insert))
            }
        }
        return IngestResult(changes: changes)
    }

    // Rule 7 pre-scan (docs/interchange-format.md §4.2): mirrors the matching
    // branches of the loop above — for each entry, the same keyMatches/
    // provMatches lookups it would perform — but reads only `existing`, the
    // registry snapshot as fetched, before this input has changed anything.
    // That is sound because both ambiguity conditions are pre-existing
    // registry state: validateWithinFile already forbids two entries in ONE
    // file from sharing a jiraKey or (within the provisional namespace) a
    // description, so nothing this pass inserts or promotes can ever be the
    // second half of a duplicate — every duplicate pair this scan can find was
    // already sitting in the registry (via `known add`/etc., which enforces no
    // uniqueness) before ingest ran.
    private static func checkAmbiguity(_ entries: [KnownTaskEntry], existing: [KnownTask], sourceName: String) throws {
        for entry in entries {
            if let jiraKey = entry.jiraKey {
                let keyMatches = existing.filter { $0.jiraKey == jiraKey }
                guard keyMatches.count <= 1 else {
                    throw ValidationError.ambiguousJiraKey(jiraKey, ids: keyMatches.compactMap(\.id), source: sourceName)
                }
                // A direct key match takes this entry down the update-in-place
                // path in the real loop, which never consults provMatches — so
                // only check provisional-description ambiguity when there is no
                // key match, matching the loop's own branching exactly.
                guard keyMatches.isEmpty else { continue }
                let provMatches = existing.filter { $0.provisional && $0.description == entry.description }
                guard provMatches.count <= 1 else {
                    throw ValidationError.ambiguousProvisionalDescription(entry.description, ids: provMatches.compactMap(\.id), source: sourceName)
                }
            } else {
                let provMatches = existing.filter { $0.provisional && $0.description == entry.description }
                guard provMatches.count <= 1 else {
                    throw ValidationError.ambiguousProvisionalDescription(entry.description, ids: provMatches.compactMap(\.id), source: sourceName)
                }
            }
        }
    }

    // Within-file validation (docs/interchange-format.md §4.2 rule 8): empty or
    // whitespace-only description; a jiraKey repeated within the file; a
    // description repeated among provisional entries in the file. Runs against
    // the shared [KnownTaskEntry] representation so JSON/CSV imports get it for
    // free — this used to live inside the YAML-specific `parse`.
    private static func validateWithinFile(_ entries: [KnownTaskEntry], sourceName: String) throws {
        var seenKeys: Set<String> = []
        var seenProvisionalDescriptions: Set<String> = []

        for entry in entries {
            // Trimmed here so a whitespace-only description is rejected
            // regardless of which reader produced the entry (§4.2 rule 8) — the
            // public ingest(entries:...) seam is shared by every source, and not
            // every caller trims before constructing a KnownTaskEntry the way the
            // YAML/JSON/CSV decoders each already do independently.
            guard !entry.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.emptyDescription(source: sourceName)
            }

            // Duplicate detection within the file. Keyed and provisional entries
            // are deduped in separate namespaces, mirroring TasksLoader (code vs
            // code-less name): the same description may appear once keyed and once
            // provisional without colliding.
            if let key = entry.jiraKey {
                if seenKeys.contains(key) { throw ValidationError.duplicateJiraKey(key, source: sourceName) }
                seenKeys.insert(key)
            } else {
                if seenProvisionalDescriptions.contains(entry.description) {
                    throw ValidationError.duplicateProvisionalDescription(entry.description, source: sourceName)
                }
                seenProvisionalDescriptions.insert(entry.description)
            }
        }
    }

    // MARK: - YAML parsing

    // Internal decoded representation before trimming — the Yams Codable shim.
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

    // Decodes yaml into the shared [KnownTaskEntry] representation. Trimming and
    // the whitespace-only-jiraKey-means-provisional fold live in
    // KnownTaskEntry.init, so this is pure decode. Deliberately does NOT run
    // business-rule validation — that is `validateWithinFile`, shared by every
    // source via `ingest(entries:...)`.
    // Private, matching TasksLoader.parse: this is a Yams-specific implementation
    // detail of ingest(from:), not part of the kit's contract. The format-neutral
    // seam callers are meant to use is ingest(entries:into:sourceName:) — making
    // this public would commit TimeTrackKit to a YAML decoding API nothing asked
    // for, which is harder to withdraw later than to add.
    private static func parse(yaml: String) throws -> [KnownTaskEntry] {
        let decoder = YAMLDecoder()
        let wrapper = try decoder.decode(Wrapper.self, from: yaml)
        return wrapper.knownTasks.map { KnownTaskEntry(description: $0.description, jiraKey: $0.jiraKey) }
    }
}
