import XCTest
import Foundation
@testable import TimeTrackCLICore
import TimeTrackKit

// Coverage for `timetrack export known` / `timetrack import known`
// (issue #59 Phase A, docs/interchange-format.md §4 + §6). Follows the
// makeTempDir()/runCLI() idiom established in CLICoreTests.swift; duplicated
// here (rather than shared) because those helpers are file-private there —
// consistent with how that file is already structured.

// MARK: - Test helpers

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cli-known-io-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
private func runCLI(_ arguments: [String], dataDir: URL) throws -> CapturingOutput {
    let out = CapturingOutput()
    try CLI.run(arguments: arguments, dataDir: dataDir, out: out)
    return out
}

private func openStore(_ dataDir: URL) throws -> Store {
    try Store(url: dataDir.appendingPathComponent("events.db"))
}

/// Replaces the JSON envelope's `"generated": "..."` timestamp with a fixed
/// placeholder so two exports produced at different instants can be compared
/// for the byte-identical-modulo-`generated` guarantee (§4.2). No-op (returns
/// input unchanged) for CSV, which has no envelope/generated field at all.
private func stripGenerated(_ text: String) -> String {
    guard let range = text.range(of: #""generated": "[^"]*""#, options: .regularExpression) else {
        return text
    }
    return text.replacingCharacters(in: range, with: "\"generated\": \"REDACTED\"")
}

/// Splits a CSV payload into physical rows. `CapturingOutput.lines` is one entry
/// per `write()` call — the codec emits the whole payload in a single write — so
/// row-level assertions must split the text itself. Physical (not logical) rows:
/// adequate only for fixtures whose fields contain no embedded newline.
private func csvRows(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

/// Writes `content` to a new file named `name` inside `dir` and returns its URL.
private func writeFile(_ content: String, named name: String, in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// Last line of captured stderr, where the diff summary always lands (§6.1:
/// `import known` has no stdout payload of its own, so its whole diff —
/// per-record lines and this summary — is diagnostic output on stderr).
private func summaryLine(_ out: CapturingOutput) -> String {
    out.errorLines.last ?? ""
}

/// `KnownTask` (Sources/TimeTrackKit/Store.swift) is not `Equatable` — it's a
/// GRDB record, not a value type meant for comparison. This mirrors its fields
/// into something comparable, purely so tests can assert "the store didn't
/// change" via a snapshot diff.
private struct KnownTaskSnapshot: Equatable {
    let id: Int64?
    let jiraKey: String?
    let description: String
    let provisional: Bool
    let retired: Bool
    let createdTs: Int64
}

private func snapshot(_ tasks: [KnownTask]) -> [KnownTaskSnapshot] {
    tasks.map {
        KnownTaskSnapshot(id: $0.id, jiraKey: $0.jiraKey, description: $0.description,
                          provisional: $0.provisional, retired: $0.retired, createdTs: $0.createdTs)
    }
}

// MARK: - Round-trip

final class KnownTaskExportImportRoundTripTests: XCTestCase {

    func testJSONRoundTripReportsZeroChanges() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try runCLI(["known", "add", "PROJ-1", "Build the widget"], dataDir: dir)
        _ = try runCLI(["known", "add", "--provisional", "Misc unsorted work"], dataDir: dir)

        let exportOut = try runCLI(["export", "known", "--format", "json"], dataDir: dir)
        let file = try writeFile(exportOut.text, named: "a.json", in: dir)

        let dryRun = try runCLI(["import", "known", file.path, "--dry-run"], dataDir: dir)
        XCTAssertEqual(summaryLine(dryRun), "would apply: 0 insert(s), 0 promotion(s), 0 description update(s), 2 no-op(s)")

        let applied = try runCLI(["import", "known", file.path], dataDir: dir)
        XCTAssertEqual(summaryLine(applied), "applied: 0 insert(s), 0 promotion(s), 0 description update(s), 2 no-op(s)")
    }

    func testCSVRoundTripReportsZeroChanges() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try runCLI(["known", "add", "PROJ-1", "Build the widget"], dataDir: dir)
        _ = try runCLI(["known", "add", "--provisional", "Misc unsorted work"], dataDir: dir)

        let exportOut = try runCLI(["export", "known", "--format", "csv"], dataDir: dir)
        let file = try writeFile(exportOut.text, named: "a.csv", in: dir)

        let dryRun = try runCLI(["import", "known", file.path, "--dry-run"], dataDir: dir)
        XCTAssertEqual(summaryLine(dryRun), "would apply: 0 insert(s), 0 promotion(s), 0 description update(s), 2 no-op(s)")

        let applied = try runCLI(["import", "known", file.path], dataDir: dir)
        XCTAssertEqual(summaryLine(applied), "applied: 0 insert(s), 0 promotion(s), 0 description update(s), 2 no-op(s)")
    }

    // export -> import -> export must be byte-identical modulo `generated` (§4.2).
    func testJSONExportImportExportIsByteIdenticalModuloGenerated() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try runCLI(["known", "add", "PROJ-1", "Build the widget"], dataDir: dir)
        _ = try runCLI(["known", "add", "--provisional", "Misc unsorted work"], dataDir: dir)

        let export1 = try runCLI(["export", "known", "--format", "json"], dataDir: dir)
        let file = try writeFile(export1.text, named: "a.json", in: dir)
        _ = try runCLI(["import", "known", file.path], dataDir: dir) // zero changes, but exercises the full path
        let export2 = try runCLI(["export", "known", "--format", "json"], dataDir: dir)

        XCTAssertEqual(stripGenerated(export1.text), stripGenerated(export2.text))
    }

    func testCSVExportImportExportIsByteIdentical() throws {
        // CSV has no envelope/`generated` field (§3.1: window/envelope metadata
        // is JSON-only), so this must be identical with no stripping at all.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try runCLI(["known", "add", "PROJ-1", "Build the widget"], dataDir: dir)
        _ = try runCLI(["known", "add", "--provisional", "Misc unsorted work"], dataDir: dir)

        let export1 = try runCLI(["export", "known", "--format", "csv"], dataDir: dir)
        let file = try writeFile(export1.text, named: "a.csv", in: dir)
        _ = try runCLI(["import", "known", file.path], dataDir: dir)
        let export2 = try runCLI(["export", "known", "--format", "csv"], dataDir: dir)

        XCTAssertEqual(export1.text, export2.text)
    }

    // JSON-import and CSV-import of equivalent data must produce equivalent
    // registry state (same descriptions/keys/provisional-ness, in the same
    // record order since both decode from the same underlying export).
    func testJSONAndCSVImportProduceEquivalentStoreState() throws {
        let sourceDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        _ = try runCLI(["known", "add", "PROJ-1", "Build the widget"], dataDir: sourceDir)
        _ = try runCLI(["known", "add", "--provisional", "Misc unsorted work"], dataDir: sourceDir)
        _ = try runCLI(["known", "add", "PROJ-2", "Ops work"], dataDir: sourceDir)

        let jsonExport = try runCLI(["export", "known", "--format", "json"], dataDir: sourceDir)
        let csvExport = try runCLI(["export", "known", "--format", "csv"], dataDir: sourceDir)

        let jsonDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: jsonDir) }
        let jsonFile = try writeFile(jsonExport.text, named: "a.json", in: jsonDir)
        _ = try runCLI(["import", "known", jsonFile.path], dataDir: jsonDir)

        let csvDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: csvDir) }
        let csvFile = try writeFile(csvExport.text, named: "a.csv", in: csvDir)
        _ = try runCLI(["import", "known", csvFile.path], dataDir: csvDir)

        let fromJSON = try openStore(jsonDir).knownTasks(activeOnly: false)
        let fromCSV = try openStore(csvDir).knownTasks(activeOnly: false)

        XCTAssertEqual(fromJSON.count, fromCSV.count)
        for (a, b) in zip(fromJSON, fromCSV) {
            XCTAssertEqual(a.jiraKey, b.jiraKey)
            XCTAssertEqual(a.description, b.description)
            XCTAssertEqual(a.provisional, b.provisional)
            XCTAssertEqual(a.retired, b.retired)
        }
    }
}

// MARK: - --include-retired

final class KnownTaskExportRetiredTests: XCTestCase {

    func testDefaultExportExcludesRetired() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try runCLI(["known", "add", "PROJ-1", "Active work"], dataDir: dir)
        _ = try runCLI(["known", "add", "PROJ-2", "Carried out work"], dataDir: dir)
        _ = try runCLI(["known", "retire", "2"], dataDir: dir)

        let csv = try runCLI(["export", "known", "--format", "csv"], dataDir: dir)
        XCTAssertFalse(csv.text.contains("Carried out work"), "retired row must be excluded by default:\n\(csv.text)")
        XCTAssertTrue(csv.text.contains("Active work"))
    }

    func testIncludeRetiredIncludesRetiredRows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try runCLI(["known", "add", "PROJ-1", "Active work"], dataDir: dir)
        _ = try runCLI(["known", "add", "PROJ-2", "Carried out work"], dataDir: dir)
        _ = try runCLI(["known", "retire", "2"], dataDir: dir)

        let csv = try runCLI(["export", "known", "--format", "csv", "--include-retired"], dataDir: dir)
        XCTAssertTrue(csv.text.contains("Carried out work"), "retired row must appear with --include-retired:\n\(csv.text)")

        // retired column must read true for that row. Note CapturingOutput.lines
        // is one entry per write() call, not per newline — the codec emits the
        // whole payload in a single write, so split the text itself.
        let retiredLine = csvRows(csv.text).first(where: { $0.contains("Carried out work") })
        XCTAssertNotNil(retiredLine)
        let fields = retiredLine?.split(separator: ",", omittingEmptySubsequences: false).map(String.init) ?? []
        XCTAssertEqual(fields.count, 6, "expected 6 CSV columns, got \(fields)")
        if fields.count == 6 {
            XCTAssertEqual(fields[4], "true")
        }
    }
}

// MARK: - CSV quoting / null-empty equivalence

final class KnownTaskCSVEscapingTests: XCTestCase {

    // A description containing a comma, a double quote, and a newline must
    // survive an export -> import round trip unchanged (§3.2 RFC 4180 quoting).
    func testDescriptionWithCommaQuoteAndNewlineRoundTrips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tricky = "Fix \"quoted\" bug, please\nurgent"
        _ = try runCLI(["known", "add", "PROJ-9", tricky], dataDir: dir)

        let csv = try runCLI(["export", "known", "--format", "csv"], dataDir: dir)
        let file = try writeFile(csv.text, named: "tricky.csv", in: dir)

        let importDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: importDir) }
        _ = try runCLI(["import", "known", file.path], dataDir: importDir)

        let tasks = try openStore(importDir).knownTasks(activeOnly: false)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.description, tricky)
    }

    // JSON null and CSV empty cell must be equivalent: a provisional row
    // (no jiraKey) exports as JSON null / empty CSV cell and re-imports as
    // provisional either way (§3).
    func testProvisionalRowExportsAsNullOrEmptyAndReimportsProvisional() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try runCLI(["known", "add", "--provisional", "Needs a key"], dataDir: dir)

        let json = try runCLI(["export", "known", "--format", "json"], dataDir: dir)
        XCTAssertTrue(json.text.contains("\"jira_key\": null,"), "expected JSON null for provisional jira_key:\n\(json.text)")

        let csv = try runCLI(["export", "known", "--format", "csv"], dataDir: dir)
        let dataLine = csvRows(csv.text).first(where: { $0.contains("Needs a key") })
        XCTAssertNotNil(dataLine)
        let fields = dataLine?.split(separator: ",", omittingEmptySubsequences: false).map(String.init) ?? []
        XCTAssertEqual(fields.count, 6, "expected 6 CSV columns, got \(fields)")
        if fields.count == 6 {
            XCTAssertEqual(fields[1], "", "expected empty jira_key cell for provisional row")
        }

        let jsonImportDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: jsonImportDir) }
        let jsonFile = try writeFile(json.text, named: "a.json", in: jsonImportDir)
        _ = try runCLI(["import", "known", jsonFile.path], dataDir: jsonImportDir)
        let jsonTasks = try openStore(jsonImportDir).knownTasks(activeOnly: false)
        XCTAssertEqual(jsonTasks.first?.provisional, true)
        XCTAssertNil(jsonTasks.first?.jiraKey)

        let csvImportDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: csvImportDir) }
        let csvFile = try writeFile(csv.text, named: "a.csv", in: csvImportDir)
        _ = try runCLI(["import", "known", csvFile.path], dataDir: csvImportDir)
        let csvTasks = try openStore(csvImportDir).knownTasks(activeOnly: false)
        XCTAssertEqual(csvTasks.first?.provisional, true)
        XCTAssertNil(csvTasks.first?.jiraKey)
    }

    // Whitespace-only jira_key normalises to null/provisional (§3).
    func testWhitespaceOnlyJiraKeyNormalisesToProvisional() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = """
        { "format": "timetrack.known_task", "version": 1, "generated": "2026-01-01T00:00:00Z",
          "records": [ { "id": null, "jira_key": "   ", "description": "Whitespace key", "provisional": false, "retired": false, "created": "2026-01-01T00:00:00Z" } ] }
        """
        let file = try writeFile(json, named: "ws.json", in: dir)
        _ = try runCLI(["import", "known", file.path], dataDir: dir)

        let tasks = try openStore(dir).knownTasks(activeOnly: false)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertNil(tasks.first?.jiraKey)
        XCTAssertTrue(tasks.first?.provisional ?? false)
    }
}

// MARK: - Malformed input

final class KnownTaskMalformedInputTests: XCTestCase {

    private func assertRejectedWithoutMutation(_ fileContent: String, named name: String) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try runCLI(["known", "add", "PROJ-1", "Pre-existing"], dataDir: dir)
        let before = try openStore(dir).knownTasks(activeOnly: false)

        let file = try writeFile(fileContent, named: name, in: dir)
        XCTAssertThrowsError(try runCLI(["import", "known", file.path], dataDir: dir))

        let after = try openStore(dir).knownTasks(activeOnly: false)
        XCTAssertEqual(snapshot(before), snapshot(after), "a rejected import must not mutate the store")
    }

    func testMalformedJSONIsRejected() throws {
        try assertRejectedWithoutMutation("{not valid json", named: "bad.json")
    }

    func testUnknownFormatIsRejected() throws {
        let content = #"{"format":"timetrack.worklog","version":1,"generated":"2026-01-01T00:00:00Z","records":[]}"#
        try assertRejectedWithoutMutation(content, named: "badformat.json")
    }

    func testVersionGreaterThanSupportedIsRejected() throws {
        let content = #"{"format":"timetrack.known_task","version":2,"generated":"2026-01-01T00:00:00Z","records":[]}"#
        try assertRejectedWithoutMutation(content, named: "badversion.json")
    }

    // Versions are 1-based (§3.1 reads a bare top-level array as v1), so 0 and
    // negatives are malformed rather than "newer than this build". Previously the
    // envelope check was `version <= supportedVersion` only, which let them
    // through and imported the records.
    func testVersionBelowOneIsRejected() throws {
        let zero = #"{"format":"timetrack.known_task","version":0,"records":[{"description":"V zero"}]}"#
        try assertRejectedWithoutMutation(zero, named: "v0.json")

        let negative = #"{"format":"timetrack.known_task","version":-1,"records":[{"description":"V neg"}]}"#
        try assertRejectedWithoutMutation(negative, named: "vneg.json")
    }

    // §4.1 types jira_key as `string | null`. A number or bool must be REJECTED,
    // not read as absent — silently importing it as provisional would drop the
    // user's key and leave a row that looks deliberately provisional.
    func testNonStringJiraKeyIsRejected() throws {
        let numeric = #"{"format":"timetrack.known_task","version":1,"records":[{"description":"Numeric key","jira_key":12345}]}"#
        try assertRejectedWithoutMutation(numeric, named: "numkey.json")

        let boolean = #"{"format":"timetrack.known_task","version":1,"records":[{"description":"Bool key","jira_key":true}]}"#
        try assertRejectedWithoutMutation(boolean, named: "boolkey.json")
    }

    // An explicit JSON null, by contrast, is valid and means provisional (§3).
    func testExplicitNullJiraKeyIsAcceptedAsProvisional() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let content = #"{"format":"timetrack.known_task","version":1,"records":[{"description":"Explicit null","jira_key":null}]}"#
        let file = try writeFile(content, named: "null.json", in: dir)
        _ = try runCLI(["import", "known", file.path], dataDir: dir)

        let tasks = try openStore(dir).knownTasks(activeOnly: false)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertTrue(tasks[0].provisional)
        XCTAssertNil(tasks[0].jiraKey)
    }

    func testMismatchedCSVHeaderIsRejected() throws {
        try assertRejectedWithoutMutation("a,b,c\n1,2,3\n", named: "bad.csv")
    }

    func testMissingFileIsRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["import", "known", dir.appendingPathComponent("nope.json").path], dataDir: dir)) { err in
            guard case CLIError.notFound = err else {
                return XCTFail("expected CLIError.notFound, got \(err)")
            }
        }
    }

    // Contrast with KnownTasksLoader.ingest(from:) for known_tasks.yaml, where a
    // missing file is a deliberate silent no-op (it's an optional startup
    // source). `import known FILE` names a file the user explicitly asked for,
    // so a missing one must be a hard error, not swallowed.
    func testMissingFileDoesNotSilentlyNoOp() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["import", "known", "/nonexistent/path/nope.csv"], dataDir: dir))
    }
}

// MARK: - --dry-run

final class KnownTaskDryRunTests: XCTestCase {

    // One import producing all four documented categories in a single pass:
    // an insert, a promotion, a description update, and a no-op.
    private func seedAndBuildInput(_ dir: URL) throws -> URL {
        _ = try runCLI(["known", "add", "PROJ-1", "A"], dataDir: dir)           // -> description update target
        _ = try runCLI(["known", "add", "--provisional", "B"], dataDir: dir)    // -> promotion target
        _ = try runCLI(["known", "add", "--provisional", "D"], dataDir: dir)    // -> no-op target

        let json = """
        { "format": "timetrack.known_task", "version": 1, "generated": "2026-01-01T00:00:00Z",
          "records": [
            { "id": null, "jira_key": "PROJ-1", "description": "A2", "provisional": false, "retired": false, "created": "2026-01-01T00:00:00Z" },
            { "id": null, "jira_key": "PROJ-2", "description": "B", "provisional": false, "retired": false, "created": "2026-01-01T00:00:00Z" },
            { "id": null, "jira_key": "PROJ-3", "description": "C", "provisional": false, "retired": false, "created": "2026-01-01T00:00:00Z" },
            { "id": null, "jira_key": null, "description": "D", "provisional": true, "retired": false, "created": "2026-01-01T00:00:00Z" }
          ] }
        """
        return try writeFile(json, named: "mixed.json", in: dir)
    }

    func testDryRunChangesNothingAndReportsAllFourCategories() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try seedAndBuildInput(dir)

        let before = try openStore(dir).knownTasks(activeOnly: false)
        let out = try runCLI(["import", "known", file.path, "--dry-run"], dataDir: dir)
        let after = try openStore(dir).knownTasks(activeOnly: false)

        XCTAssertEqual(snapshot(before), snapshot(after), "--dry-run must not mutate the store")
        XCTAssertEqual(summaryLine(out), "would apply: 1 insert(s), 1 promotion(s), 1 description update(s), 1 no-op(s)")

        // The entire diff is diagnostic (§6.1) — import known has no stdout
        // payload of its own — so it must all be on stderr, none on stdout.
        XCTAssertEqual(out.lines, [], "import known must never write to stdout")
        let text = out.errorText
        XCTAssertTrue(text.contains("insert:"), text)
        XCTAssertTrue(text.contains("promote:"), text)
        XCTAssertTrue(text.contains("update:"), text)
        XCTAssertTrue(text.contains("no-op:"), text)

        // Caveat from KnownTasksLoader: a promote/update whose match is a
        // same-pass synthesized insert can carry a negative placeholder id.
        // None of that must ever reach the user as a literal negative number.
        for line in out.errorLines {
            XCTAssertFalse(line.contains("#-"), "must never print a negative placeholder id: \(line)")
        }
    }

    func testRealRunAppliesAndReportsSameCounts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try seedAndBuildInput(dir)

        let out = try runCLI(["import", "known", file.path], dataDir: dir)
        XCTAssertEqual(summaryLine(out), "applied: 1 insert(s), 1 promotion(s), 1 description update(s), 1 no-op(s)")

        let after = try openStore(dir).knownTasks(activeOnly: false)
        XCTAssertTrue(after.contains(where: { $0.description == "A2" && $0.jiraKey == "PROJ-1" }))
        XCTAssertTrue(after.contains(where: { $0.description == "B" && $0.jiraKey == "PROJ-2" }))
        XCTAssertTrue(after.contains(where: { $0.description == "C" && $0.jiraKey == "PROJ-3" }))
        XCTAssertTrue(after.contains(where: { $0.description == "D" && $0.provisional }))
    }

    // Not passing --dry-run applies changes; the CLI does not default to
    // dry-run (§6.2).
    func testOmittingDryRunAppliesByDefault() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try runCLI(["known", "add", "--provisional", "Solo"], dataDir: dir)

        let json = #"[ { "description": "New one", "jira_key": "PROJ-5" } ]"#
        let file = try writeFile(json, named: "solo.json", in: dir)
        _ = try runCLI(["import", "known", file.path], dataDir: dir)

        let after = try openStore(dir).knownTasks(activeOnly: false)
        XCTAssertTrue(after.contains(where: { $0.jiraKey == "PROJ-5" && $0.description == "New one" }))
    }
}

// MARK: - --out FILE and stdout/stderr separation

final class KnownTaskOutFileAndStreamTests: XCTestCase {

    func testOutFileWritesPayloadAndKeepsStdoutClean() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try runCLI(["known", "add", "PROJ-1", "Build the widget"], dataDir: dir)

        let outPath = dir.appendingPathComponent("export.json").path
        let out = try runCLI(["export", "known", "--format", "json", "--out", outPath], dataDir: dir)

        XCTAssertEqual(out.lines, [], "stdout must stay clean when --out is given")
        XCTAssertEqual(out.errorLines, [], "export known has no diagnostics to emit in the success path")

        let written = try String(contentsOf: URL(fileURLWithPath: outPath), encoding: .utf8)
        XCTAssertTrue(written.contains("Build the widget"))
        XCTAssertTrue(written.hasSuffix("\n"), "file must end with exactly one trailing newline")
        XCTAssertFalse(written.hasSuffix("\n\n"), "file must not be double-newline-terminated")
    }

    // Diagnostics (e.g. the extra-trailing-CSV-column warning, §3.2) land on
    // stderr, never mixed into the stdout payload/diff.
    func testWarningsLandOnStderrNotStdout() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let csv = "id,jira_key,description,provisional,retired,created,extra\n" +
                  "1,PROJ-1,desc,false,false,2026-01-01T00:00:00Z,ignored\n"
        let file = try writeFile(csv, named: "extra.csv", in: dir)

        let out = try runCLI(["import", "known", file.path, "--dry-run"], dataDir: dir)
        XCTAssertFalse(out.text.contains("extra trailing"), "warning text must not appear on stdout:\n\(out.text)")
        XCTAssertTrue(out.errorText.contains("extra trailing"), "warning must appear on stderr:\n\(out.errorText)")
    }

    // §6.1: "All diagnostics go to stderr; only payload goes to stdout." import
    // known has no stdout payload at all, so its diff — insert/promote/update/
    // no-op lines plus the summary — must land entirely on stderr. Checked with
    // real, non-empty diff content (not just the zero-change case) both with
    // and without --dry-run, since the two paths render through the same
    // printKnownTaskDiff and either could regress independently.
    func testImportKnownDiffNeverWritesToStdoutWithDryRun() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = #"[ { "description": "New one", "jira_key": "PROJ-5" } ]"#
        let file = try writeFile(json, named: "solo.json", in: dir)

        let out = try runCLI(["import", "known", file.path, "--dry-run"], dataDir: dir)
        XCTAssertEqual(out.lines, [], "import known --dry-run must never write to stdout")
        XCTAssertTrue(out.errorText.contains("insert:"), out.errorText)
    }

    func testImportKnownDiffNeverWritesToStdoutWithoutDryRun() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let json = #"[ { "description": "New one", "jira_key": "PROJ-5" } ]"#
        let file = try writeFile(json, named: "solo.json", in: dir)

        let out = try runCLI(["import", "known", file.path], dataDir: dir)
        XCTAssertEqual(out.lines, [], "import known must never write to stdout")
        XCTAssertTrue(out.errorText.contains("insert:"), out.errorText)
    }
}

// MARK: - CSV blank lines (§3.2)

final class KnownTaskCSVBlankLineTests: XCTestCase {

    private let csvHeader = "id,jira_key,description,provisional,retired,created"

    // A file ending in a second line terminator (\n\n) must not be treated as
    // a malformed one-column row naming a row number the user can't see.
    func testTrailingBlankLineIsSkippedNotRejected() throws {
        let csv = csvHeader + "\n" +
                  "1,PROJ-1,First,false,false,2026-01-01T00:00:00Z\n" +
                  "\n"
        let (entries, warnings) = try KnownTaskCodec.decode(text: csv, format: .csv)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.description, "First")
    }

    // A blank line between two data rows must likewise be skipped, and must
    // not disturb the rows around it.
    func testInteriorBlankLinesAreSkipped() throws {
        let csv = csvHeader + "\n" +
                  "1,PROJ-1,First,false,false,2026-01-01T00:00:00Z\n" +
                  "\n" +
                  "\n" +
                  "2,PROJ-2,Second,false,false,2026-01-01T00:00:00Z\n"
        let (entries, _) = try KnownTaskCodec.decode(text: csv, format: .csv)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.description), ["First", "Second"])
    }

    // Contrast case: a row with the RIGHT column count where every cell
    // happens to be blank is real (malformed) data, not an absent line, and
    // must still fail validation for an empty description rather than being
    // silently dropped alongside true blank lines.
    func testRowWithCorrectColumnCountAndAllEmptyCellsStillFailsValidation() throws {
        let csv = csvHeader + "\n" + ",,,,,\n"
        XCTAssertThrowsError(try KnownTaskCodec.decode(text: csv, format: .csv)) { error in
            guard case KnownTaskCodec.CodecError.malformedCSV(let msg) = error else {
                return XCTFail("expected .malformedCSV, got \(error)")
            }
            XCTAssertTrue(msg.contains("empty description"), msg)
        }
    }
}

// MARK: - §3.1 bare top-level array / §6.1 format sniff fallback

final class KnownTaskSpecCoverageTests: XCTestCase {

    // §3.1: "A bare top-level array is also accepted as a convenience for
    // hand-written input, and is interpreted as version 1 of whichever type
    // the command implies." Exercised directly against the codec so it is
    // covered independently of any one CLI path that happens to use it.
    func testBareTopLevelJSONArrayAcceptedAsImpliedV1() throws {
        let json = #"""
        [
          { "description": "Build the widget", "jira_key": "PROJ-1" },
          { "description": "Misc unsorted work" }
        ]
        """#
        let (entries, warnings) = try KnownTaskCodec.decode(text: json, format: .json)
        XCTAssertEqual(warnings, [])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].description, "Build the widget")
        XCTAssertEqual(entries[0].jiraKey, "PROJ-1")
        XCTAssertEqual(entries[1].description, "Misc unsorted work")
        XCTAssertNil(entries[1].jiraKey)
    }

    // §6.1: "auto" sniffs by extension first, then by the first non-whitespace
    // byte. A `.txt` file has no trusted extension, so the fallback must
    // decide: `{`/`[` first sniffs as JSON, anything else as CSV.
    func testFormatSniffFallsThroughToFirstByteForUntrustedExtension() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let jsonLikeTxt = #"[ { "description": "From txt as JSON", "jira_key": "PROJ-7" } ]"#
        let jsonFile = try writeFile(jsonLikeTxt, named: "a.txt", in: dir)
        _ = try runCLI(["import", "known", jsonFile.path], dataDir: dir)
        let afterJSON = try openStore(dir).knownTasks(activeOnly: false)
        XCTAssertTrue(afterJSON.contains { $0.description == "From txt as JSON" && $0.jiraKey == "PROJ-7" },
                      "a .txt file starting with '[' must sniff as JSON")

        let csvDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: csvDir) }
        let csvLikeTxt = "id,jira_key,description,provisional,retired,created\n" +
                         "1,PROJ-8,From txt as CSV,false,false,2026-01-01T00:00:00Z\n"
        let csvFile = try writeFile(csvLikeTxt, named: "b.txt", in: csvDir)
        _ = try runCLI(["import", "known", csvFile.path], dataDir: csvDir)
        let afterCSV = try openStore(csvDir).knownTasks(activeOnly: false)
        XCTAssertTrue(afterCSV.contains { $0.description == "From txt as CSV" && $0.jiraKey == "PROJ-8" },
                      "a .txt file not starting with '{' or '[' must sniff as CSV")
    }
}
