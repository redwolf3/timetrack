import XCTest
import Foundation
@testable import TimeTrackCLICore
import TimeTrackKit

// CLI-surface tests for `timetrack export worklog` (docs/interchange-format.md
// §5/§6) — argument parsing, the reconcile-gate-to-exit-code-2 mapping, the
// --include-unreconciled downgrade to a stderr warning, and JSON/CSV payload
// shape. The underlying algorithm (Store.worklog) is covered exhaustively by
// Tests/TimeTrackKitTests/WorklogExportTests.swift; these tests stay focused
// on what only the CLI layer owns.

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cli-worklog-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
private func runCLI(_ arguments: [String], dataDir: URL) throws -> CapturingOutput {
    let out = CapturingOutput()
    try CLI.run(arguments: arguments, dataDir: dataDir, out: out)
    return out
}

// A fixed past day (3 days ago) so sliceTimeline's closeTs = endOfDay and a
// fixture seeded at startOfDay+9h is never clamped by "now" — same rationale
// as the Store-level worklog/reconcile fixtures.
private func pastDay() -> Date {
    let today = Calendar.current.startOfDay(for: Date())
    return Calendar.current.date(byAdding: .day, value: -3, to: today)!
}

private func isoDay(_ date: Date) -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    return df.string(from: date)
}

// Seeds one hour of tracked time on a fresh ad-hoc "Loose" project task,
// starting 9h into `pastDay()`, via direct Store access to the same
// events.db the CLI commands below operate on. Returns the task.
@discardableResult
private func seedUnboundHour(dataDir: URL) throws -> Task {
    let store = try Store(url: dataDir.appendingPathComponent("events.db"))
    var t = Task(id: nil, name: "Loose", code: nil, category: "project", archived: false)
    t = try store.upsertTask(t)
    let startMs = Int64(pastDay().timeIntervalSince1970 * 1_000) + 9 * 3_600_000
    try store.append(Event(id: nil, ts: startMs, type: EventType.start.rawValue,
        taskId: t.id!, prevTaskId: nil, phaseId: nil, profileName: nil, extendMin: nil, comment: nil))
    try store.append(Event(id: nil, ts: startMs + 3_600_000, type: EventType.stop.rawValue,
        taskId: nil, prevTaskId: t.id!, phaseId: nil, profileName: nil, extendMin: nil, comment: nil))
    return t
}

// Seeds one hour of tracked time bound to a real, non-provisional Known Task.
private func seedReconciledHour(dataDir: URL, jiraKey: String, description: String) throws {
    let store = try Store(url: dataDir.appendingPathComponent("events.db"))
    var t = Task(id: nil, name: "Widget", code: nil, category: "project", archived: false)
    t = try store.upsertTask(t)
    let kt = try store.addKnownTask(jiraKey: jiraKey, description: description)
    try store.bind(taskId: t.id!, knownTaskId: kt.id!, comment: nil)
    let startMs = Int64(pastDay().timeIntervalSince1970 * 1_000) + 9 * 3_600_000
    try store.append(Event(id: nil, ts: startMs, type: EventType.start.rawValue,
        taskId: t.id!, prevTaskId: nil, phaseId: nil, profileName: nil, extendMin: nil, comment: nil))
    try store.append(Event(id: nil, ts: startMs + 1_500_000, type: EventType.stop.rawValue,
        taskId: nil, prevTaskId: t.id!, phaseId: nil, profileName: nil, extendMin: nil, comment: nil))
}

// MARK: - Argument parsing

final class ExportWorklogArgumentTests: XCTestCase {

    func testMissingFromAndToThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["export", "worklog"], dataDir: dir)) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    func testToBeforeFromThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(
            ["export", "worklog", "--from", "2026-01-10", "--to", "2026-01-01"], dataDir: dir)
        ) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    func testUnknownFormatThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(
            ["export", "worklog", "--from", "2026-01-01", "--to", "2026-01-01", "--format", "xml"],
            dataDir: dir)
        ) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    func testUnknownGrainThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(
            ["export", "worklog", "--from", "2026-01-01", "--to", "2026-01-01", "--by", "month"],
            dataDir: dir)
        ) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    func testUnimplementedExportSubcommandsThrowUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        for sub in ["known", "events"] {
            XCTAssertThrowsError(try runCLI(["export", sub], dataDir: dir)) { err in
                guard case CLIError.usage = err else {
                    return XCTFail("expected CLIError.usage for 'export \(sub)', got \(err)")
                }
            }
        }
    }
}

// MARK: - Reconcile gate

final class ExportWorklogGateTests: XCTestCase {

    // Default (no --include-unreconciled): unbound time blocks export and the
    // failure must be reported via CLIError.gateFailed, which main.swift maps
    // to exit code 2 (docs/interchange-format.md §6.4) — not the generic exit 1.
    func testUnboundTimeThrowsGateFailedNamingTheTask() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = try seedUnboundHour(dataDir: dir)
        let day = isoDay(pastDay())

        XCTAssertThrowsError(try runCLI(
            ["export", "worklog", "--from", day, "--to", day], dataDir: dir)
        ) { err in
            guard case CLIError.gateFailed(let message) = err else {
                return XCTFail("expected CLIError.gateFailed, got \(err)")
            }
            XCTAssertTrue(message.contains(task.name), "gate message should name the offending task: \(message)")
            XCTAssertTrue(message.contains("bind"), "gate message should point at the fix: \(message)")
        }
    }

    func testProvisionalTimeThrowsGateFailedNamingTheKnownTask() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(url: dir.appendingPathComponent("events.db"))
        var t = Task(id: nil, name: "WIP", code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        let kt = try store.addKnownTask(jiraKey: nil, description: "WIP entry")
        try store.bind(taskId: t.id!, knownTaskId: kt.id!, comment: nil)
        let startMs = Int64(pastDay().timeIntervalSince1970 * 1_000) + 9 * 3_600_000
        try store.append(Event(id: nil, ts: startMs, type: EventType.start.rawValue,
            taskId: t.id!, prevTaskId: nil, phaseId: nil, profileName: nil, extendMin: nil, comment: nil))
        try store.append(Event(id: nil, ts: startMs + 600_000, type: EventType.stop.rawValue,
            taskId: nil, prevTaskId: t.id!, phaseId: nil, profileName: nil, extendMin: nil, comment: nil))
        let day = isoDay(pastDay())

        XCTAssertThrowsError(try runCLI(
            ["export", "worklog", "--from", day, "--to", day], dataDir: dir)
        ) { err in
            guard case CLIError.gateFailed(let message) = err else {
                return XCTFail("expected CLIError.gateFailed, got \(err)")
            }
            XCTAssertTrue(message.contains("WIP entry"), "gate message should name the provisional known task: \(message)")
            XCTAssertTrue(message.contains("promote"), "gate message should point at the fix: \(message)")
        }
    }

    // --include-unreconciled downgrades the gate to a stderr warning: the
    // export still succeeds (exit 0), payload still reaches stdout, and the
    // warning must land on stderr — never mixed into the machine-readable
    // stdout payload (§5.3, §6.1).
    func testIncludeUnreconciledSucceedsWithWarningOnStderr() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = try seedUnboundHour(dataDir: dir)
        let day = isoDay(pastDay())

        let out = try runCLI(
            ["export", "worklog", "--from", day, "--to", day, "--include-unreconciled"], dataDir: dir)

        XCTAssertTrue(out.text.contains("\"timetrack.worklog\""), "stdout should carry the JSON payload: \(out.text)")
        XCTAssertTrue(out.text.contains("\"unbound\""), "unreconciled records must be emitted with status unbound")
        // The task name IS legitimate payload data here (capture_tasks), so the
        // no-leak check has to target the diagnostic phrasing, not the name.
        XCTAssertFalse(out.text.contains("no binding"), "diagnostics must not leak into the stdout payload: \(out.text)")
        XCTAssertTrue(out.errorText.contains(task.name), "the offending task must be named on stderr: \(out.errorText)")
        XCTAssertTrue(out.errorText.contains("no binding"), "the stderr warning should carry the gate diagnostic: \(out.errorText)")
    }
}

// MARK: - Payload shape

final class ExportWorklogPayloadTests: XCTestCase {

    func testJSONPayloadForReconciledTime() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedReconciledHour(dataDir: dir, jiraKey: "PROJ-1", description: "Build the widget")
        let day = isoDay(pastDay())

        let out = try runCLI(["export", "worklog", "--from", day, "--to", day], dataDir: dir)
        let text = out.text

        XCTAssertTrue(text.contains("\"format\": \"timetrack.worklog\""))
        XCTAssertTrue(text.contains("\"version\": 1"))
        XCTAssertTrue(text.contains("\"jira_key\": \"PROJ-1\""))
        XCTAssertTrue(text.contains("\"description\": \"Build the widget\""))
        XCTAssertTrue(text.contains("\"status\": \"reconciled\""))
        XCTAssertTrue(text.contains("\"seconds\": 1500"))
        XCTAssertTrue(text.contains("\"capture_tasks\": [\"Widget\"]"))
        XCTAssertTrue(text.contains("\"window\": { \"from\": \"\(day)\", \"to\": \"\(day)\" }"))
        XCTAssertTrue(out.errorText.isEmpty, "a clean reconciled export has nothing to warn about")
    }

    func testCSVPayloadForReconciledTime() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedReconciledHour(dataDir: dir, jiraKey: "PROJ-1", description: "Build the widget")
        let day = isoDay(pastDay())

        let out = try runCLI(
            ["export", "worklog", "--from", day, "--to", day, "--format", "csv"], dataDir: dir)
        let lines = out.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        XCTAssertEqual(lines.first, "date,started,ended,seconds,raw_seconds,jira_key,known_task_id,description,capture_tasks,status")
        XCTAssertTrue(lines[1].hasPrefix("\(day),"), "row should start with the local date: \(lines[1])")
        XCTAssertTrue(lines[1].contains(",1500,1500,PROJ-1,"), "row should carry seconds, raw_seconds, jira_key: \(lines[1])")
        XCTAssertTrue(lines[1].hasSuffix("Build the widget,Widget,reconciled"), "row should end with description, capture_tasks, status: \(lines[1])")
    }

    func testByIntervalGrainFlag() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedReconciledHour(dataDir: dir, jiraKey: "PROJ-1", description: "Build the widget")
        let day = isoDay(pastDay())

        let out = try runCLI(
            ["export", "worklog", "--from", day, "--to", day, "--by", "interval"], dataDir: dir)
        // At --by interval, raw_seconds always equals seconds (no normalisation).
        XCTAssertTrue(out.text.contains("\"seconds\": 1500, \"raw_seconds\": 1500"))
        XCTAssertTrue(out.text.contains("\"ended\": \""), "interval grain populates ended with a real timestamp, not null")
    }

    // --out writes the payload to a file, atomically, and stdout carries
    // nothing (§6.1: --out defaults to stdout; when given, the file gets the
    // payload instead).
    func testOutFlagWritesFileAndStdoutStaysEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedReconciledHour(dataDir: dir, jiraKey: "PROJ-1", description: "Build the widget")
        let day = isoDay(pastDay())
        let outFile = dir.appendingPathComponent("worklog.json")

        let out = try runCLI(
            ["export", "worklog", "--from", day, "--to", day, "--out", outFile.path], dataDir: dir)

        XCTAssertTrue(out.text.isEmpty, "payload must go to the file, not stdout, when --out is given")
        let written = try String(contentsOf: outFile, encoding: .utf8)
        XCTAssertTrue(written.contains("\"jira_key\": \"PROJ-1\""))
        XCTAssertTrue(written.hasSuffix("\n"), "the file gets exactly one trailing newline")
    }

    func testNormalisationEnvelopeRecordsTheParametersUsed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedReconciledHour(dataDir: dir, jiraKey: "PROJ-1", description: "Build the widget")
        let day = isoDay(pastDay())

        let out = try runCLI(
            ["export", "worklog", "--from", day, "--to", day,
             "--drop-below-sec", "30", "--min-interval-min", "1", "--round-to-min", "15"],
            dataDir: dir)

        XCTAssertTrue(out.text.contains("\"normalisation\": { \"drop_below_sec\": 30, \"min_interval_min\": 1, \"round_to_min\": 15, \"aggregate_key\": null }"))
        // 1500s rounds up to the next 15-minute quantum (1800s).
        XCTAssertTrue(out.text.contains("\"seconds\": 1800, \"raw_seconds\": 1500"))
    }
}

// MARK: - `capture_tasks` list encoding (§3.2)

final class WorklogCaptureTasksEncodingTests: XCTestCase {

    func testPlainNamesJoinWithSemicolon() {
        XCTAssertEqual(WorklogCodec.encodeCaptureTasks(["widget spike", "widget"]), "widget spike;widget")
    }

    func testSemicolonInNameIsBackslashEscaped() {
        XCTAssertEqual(WorklogCodec.encodeCaptureTasks(["a;b", "c"]), "a\\;b;c")
    }

    func testBackslashInNameIsBackslashEscaped() {
        XCTAssertEqual(WorklogCodec.encodeCaptureTasks(["a\\b"]), "a\\\\b")
    }

    func testBothEscapesRoundTripUnambiguously() {
        // A literal "\;" must encode differently from a literal ";" — both
        // escapes are required or the encoding is not lossless (§3.2).
        let literalSemicolon = WorklogCodec.encodeCaptureTasks(["a;b"])
        let literalBackslashSemicolon = WorklogCodec.encodeCaptureTasks(["a\\;b"])
        XCTAssertNotEqual(literalSemicolon, literalBackslashSemicolon)
    }
}
