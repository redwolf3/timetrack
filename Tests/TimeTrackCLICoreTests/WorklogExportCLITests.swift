import XCTest
import Foundation
@testable import TimeTrackCLICore
import TimeTrackKit

// Coverage for `timetrack export worklog` (issue #59 Phase B,
// docs/interchange-format.md §5 + §6). Follows the makeTempDir()/runCLI()
// idiom established in KnownTaskImportExportTests.swift; duplicated here for
// the same reason that file gives for duplicating it from CLICoreTests.swift.

// MARK: - Test helpers

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cli-worklog-io-test-\(UUID().uuidString)", isDirectory: true)
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

// A fixed past date, formatted the way --from/--to expect (yyyy-MM-dd), so
// fixtures never straddle "now" and an interval is never clipped by closeTs.
private func pastDateString(daysAgo: Int) -> String {
    let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Calendar.current.startOfDay(for: Date()))!
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    return df.string(from: day)
}

private func appendBlock(_ store: Store, taskId: Int64, startMs: Int64, durationSec: Int) throws {
    let endMs = startMs + Int64(durationSec) * 1_000
    try store.append(Event(
        id: nil, ts: startMs, type: EventType.start.rawValue,
        taskId: taskId, prevTaskId: nil,
        phaseId: nil, profileName: nil, extendMin: nil, comment: nil))
    try store.append(Event(
        id: nil, ts: endMs, type: EventType.stop.rawValue,
        taskId: nil, prevTaskId: taskId,
        phaseId: nil, profileName: nil, extendMin: nil, comment: nil))
}

private func baseMs(_ dateString: String) -> Int64 {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = TimeZone.current
    let day = df.date(from: dateString)!
    return Int64(day.timeIntervalSince1970 * 1_000) + 9 * 3_600_000
}

final class WorklogExportCLITests: XCTestCase {

    func testExportWorklogRequiresFromAndTo() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["export", "worklog"], dataDir: dir)) { error in
            guard case CLIError.usage = error else {
                XCTFail("expected usage error, got \(error)"); return
            }
        }
    }

    func testExportWorklogEmptyWindowSucceedsWithEmptyRecords() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let day = pastDateString(daysAgo: 5)

        let out = try runCLI(["export", "worklog", "--from", day, "--to", day], dataDir: dir)
        XCTAssertTrue(out.text.contains("\"format\": \"timetrack.worklog\""))
        XCTAssertTrue(out.text.contains("\"records\": []"))
        XCTAssertEqual(out.errorLines, [], "no diagnostics for a clean, empty window")
    }

    func testExportWorklogExitsGateOnUnboundTime() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let day = pastDateString(daysAgo: 5)

        let store = try openStore(dir)
        var t = Task(id: nil, name: "Stray", code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        try appendBlock(store, taskId: t.id!, startMs: baseMs(day), durationSec: 300)

        let out = CapturingOutput()
        XCTAssertThrowsError(
            try CLI.run(arguments: ["export", "worklog", "--from", day, "--to", day], dataDir: dir, out: out)
        ) { error in
            guard case CLIError.reconcileGate = error else {
                XCTFail("expected .reconcileGate for exit code 2, got \(error)"); return
            }
        }
        XCTAssertTrue(out.errorLines.contains { $0.contains("Unreconciled tasks") })
        XCTAssertTrue(out.lines.isEmpty, "no payload on stdout when the gate fails")
    }

    func testExportWorklogIncludeUnreconciledEmitsWarningAndPayload() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let day = pastDateString(daysAgo: 5)

        let store = try openStore(dir)
        var t = Task(id: nil, name: "Stray", code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        try appendBlock(store, taskId: t.id!, startMs: baseMs(day), durationSec: 300)

        let out = try runCLI(
            ["export", "worklog", "--from", day, "--to", day, "--include-unreconciled"], dataDir: dir)
        XCTAssertTrue(out.errorLines.contains { $0.contains("unreconciled record") })
        XCTAssertTrue(out.text.contains("\"status\": \"unbound\""))
        XCTAssertTrue(out.text.contains("\"jira_key\": null"))
    }

    func testExportWorklogJSONPayloadShape() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let day = pastDateString(daysAgo: 5)

        let store = try openStore(dir)
        var t = Task(id: nil, name: "Widget", code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        let kt = try store.addKnownTask(jiraKey: "PROJ-1", description: "Widget work")
        try store.bind(taskId: t.id!, knownTaskId: kt.id!, comment: nil)
        try appendBlock(store, taskId: t.id!, startMs: baseMs(day), durationSec: 1_500)

        let out = try runCLI(["export", "worklog", "--from", day, "--to", day], dataDir: dir)
        XCTAssertTrue(out.text.contains("\"jira_key\": \"PROJ-1\""))
        XCTAssertTrue(out.text.contains("\"status\": \"reconciled\""))
        XCTAssertTrue(out.text.contains("\"seconds\": 1500"))
        XCTAssertTrue(out.text.contains("\"capture_tasks\": [\"Widget\"]"))
        XCTAssertTrue(out.text.contains("\"window\""), "worklog envelope includes window, unlike known_task")
        XCTAssertTrue(out.text.contains("\"normalisation\""))
        XCTAssertEqual(out.errorLines, [])
    }

    func testExportWorklogCSVHeaderAndRow() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let day = pastDateString(daysAgo: 5)

        let store = try openStore(dir)
        var t = Task(id: nil, name: "Widget", code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        let kt = try store.addKnownTask(jiraKey: "PROJ-1", description: "Widget work")
        try store.bind(taskId: t.id!, knownTaskId: kt.id!, comment: nil)
        try appendBlock(store, taskId: t.id!, startMs: baseMs(day), durationSec: 300)

        let out = try runCLI(["export", "worklog", "--from", day, "--to", day, "--format", "csv"], dataDir: dir)
        let lines = out.text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.first, "date,started,ended,seconds,raw_seconds,jira_key,known_task_id,description,capture_tasks,status")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("PROJ-1"))
        XCTAssertTrue(lines[1].contains(",300,300,"))
        XCTAssertTrue(lines[1].hasSuffix("reconciled"))
    }

    func testExportWorklogByIntervalGrain() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let day = pastDateString(daysAgo: 5)

        let store = try openStore(dir)
        var t = Task(id: nil, name: "Widget", code: nil, category: "project", archived: false)
        t = try store.upsertTask(t)
        let kt = try store.addKnownTask(jiraKey: "PROJ-1", description: "Widget work")
        try store.bind(taskId: t.id!, knownTaskId: kt.id!, comment: nil)
        try appendBlock(store, taskId: t.id!, startMs: baseMs(day), durationSec: 90)

        let out = try runCLI(
            ["export", "worklog", "--from", day, "--to", day, "--by", "interval"], dataDir: dir)
        XCTAssertTrue(out.text.contains("\"ended\":"))
        XCTAssertFalse(out.text.contains("\"ended\": null"), "ended is populated at interval grain")
    }
}
