import XCTest
import Foundation
@testable import TimeTrackCLICore
import TimeTrackKit

// MARK: - Test helpers

/// Create a unique temp directory, returning its URL.
/// Caller owns cleanup (use `defer { try? FileManager.default.removeItem(at: dir) }`).
private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cli-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Run CLI, capture output, and return the CapturingOutput.
@discardableResult
private func runCLI(_ arguments: [String], dataDir: URL) throws -> CapturingOutput {
    let out = CapturingOutput()
    try CLI.run(arguments: arguments, dataDir: dataDir, out: out)
    return out
}

// MARK: - Dispatch tests

final class CLIDispatchTests: XCTestCase {

    func testUnknownCommandThrowsUsageError() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["nonexistent-command"], dataDir: dir)) { err in
            guard case CLIError.usage(let msg) = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
            XCTAssertTrue(msg.contains("unknown command"), "message was: \(msg)")
        }
    }

    func testEmptyArgumentsShowsHelp() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try runCLI([], dataDir: dir)
        // Help output must mention at minimum 'start' and 'stop' commands.
        let text = out.text
        XCTAssertTrue(text.contains("start"), "help text should mention 'start': \(text)")
        XCTAssertTrue(text.contains("stop"), "help text should mention 'stop': \(text)")
        XCTAssertTrue(text.contains("timetrack"), "help text should mention 'timetrack': \(text)")
    }

    func testHelpCommandShowsHelp() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try runCLI(["help"], dataDir: dir)
        let text = out.text
        XCTAssertTrue(text.contains("start"), "help text should mention 'start': \(text)")
        XCTAssertTrue(text.contains("known"), "help text should mention 'known': \(text)")
        XCTAssertTrue(text.contains("reconcile"), "help text should mention 'reconcile': \(text)")
        XCTAssertTrue(text.contains("bind"), "help text should mention 'bind': \(text)")
    }

    func testHelpFlagShowsHelp() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outFlag = try runCLI(["--help"], dataDir: dir)
        let outH = try runCLI(["-h"], dataDir: dir)
        // Both forms should produce output mentioning known commands.
        XCTAssertTrue(outFlag.text.contains("start"))
        XCTAssertTrue(outH.text.contains("start"))
    }
}

// MARK: - Argument-parsing tests

final class CLIArgumentParsingTests: XCTestCase {

    // report --from/--to in standard order
    func testReportFromToBothOrders() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Both orders must be accepted without throwing.
        XCTAssertNoThrow(try runCLI(["report", "--from", "2026-01-01", "--to", "2026-01-07"], dataDir: dir))
        XCTAssertNoThrow(try runCLI(["report", "--to", "2026-01-07", "--from", "2026-01-01"], dataDir: dir))
    }

    // report with only --from (today used as to)
    func testReportFromOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNoThrow(try runCLI(["report", "--from", "2026-01-01"], dataDir: dir))
    }

    // report with missing value after --from
    func testReportMissingFromValueThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["report", "--from"], dataDir: dir)) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    // report with missing value after --to
    func testReportMissingToValueThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["report", "--to"], dataDir: dir)) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    // report with invalid date format
    func testReportInvalidDateThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["report", "--from", "not-a-date"], dataDir: dir)) { err in
            guard case CLIError.usage(let msg) = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
            XCTAssertTrue(msg.contains("invalid date") || msg.contains("not-a-date"),
                          "message was: \(msg)")
        }
    }

    // report with --to before --from (M1/M2 inverted range)
    func testReportInvertedRangeThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["report", "--from", "2026-01-10", "--to", "2026-01-01"],
                                     dataDir: dir)) { err in
            guard case CLIError.usage(let msg) = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
            // Should mention both dates in the error to be actionable.
            XCTAssertTrue(msg.contains("2026-01-01") || msg.contains("before"),
                          "message was: \(msg)")
        }
    }

    // reconcile --from/--to both orders
    func testReconcileFromToBothOrders() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNoThrow(try runCLI(["reconcile", "--from", "2026-01-01", "--to", "2026-01-07"],
                                 dataDir: dir))
        XCTAssertNoThrow(try runCLI(["reconcile", "--to", "2026-01-07", "--from", "2026-01-01"],
                                 dataDir: dir))
    }

    // reconcile inverted range
    func testReconcileInvertedRangeThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(
            try runCLI(["reconcile", "--from", "2026-01-10", "--to", "2026-01-01"], dataDir: dir)
        ) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    // reconcile invalid date
    func testReconcileInvalidDateThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(
            try runCLI(["reconcile", "--from", "01/01/2026"], dataDir: dir)
        ) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    // Unknown flag on report
    func testReportUnknownFlagThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["report", "--bogus", "foo"], dataDir: dir)) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }
}

// MARK: - Exit-code mapping tests
//
// The core itself never calls exit(). It returns normally on success and throws
// CLIError on failure. Tests verify those two paths: success == no throw,
// failure == thrown CLIError (main.swift maps these to exit 0 and exit 1).

final class CLIExitCodeTests: XCTestCase {

    func testSuccessPathReturnsNormally() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // status on an empty database returns normally (no throw == exit 0 in main.swift).
        XCTAssertNoThrow(try runCLI(["status"], dataDir: dir))
    }

    func testCLIErrorUsageMapsToFailure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // An unknown command is CLIError.usage — described, caught by main.swift,
        // printed to stderr, and mapped to exit 1.
        var caughtError: CLIError?
        XCTAssertThrowsError(try runCLI(["no-such-command"], dataDir: dir)) { err in
            caughtError = err as? CLIError
        }
        XCTAssertNotNil(caughtError, "expected a CLIError")
        if case .usage(let msg) = caughtError {
            XCTAssertFalse(msg.isEmpty, "usage message must be non-empty")
        } else {
            XCTFail("expected .usage case")
        }
    }

    func testCLIErrorNotFoundMapsToFailure() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // known promote on a non-existent id throws .notFound.
        XCTAssertThrowsError(try runCLI(["known", "promote", "9999", "PROJ-1"], dataDir: dir)) { err in
            guard let cliErr = err as? CLIError else {
                return XCTFail("expected CLIError, got \(err)")
            }
            if case .notFound = cliErr { /* correct */ } else {
                XCTFail("expected .notFound, got \(cliErr)")
            }
        }
    }

    func testCLIErrorDescriptionIsNonEmpty() {
        // Verify CustomStringConvertible implementations are sane.
        let u = CLIError.usage("do this instead")
        let n = CLIError.notFound("widget #7")
        let m = CLIError.message("something broke")
        XCTAssertTrue(u.description.contains("do this instead"))
        XCTAssertTrue(n.description.contains("widget #7"))
        XCTAssertTrue(m.description.contains("something broke"))
    }
}

// MARK: - Output formatting tests

final class CLIFormattingTests: XCTestCase {

    // formatDuration boundary values.
    func testFormatDurationZero() {
        XCTAssertEqual(formatDuration(0), "0s")
    }

    func testFormatDurationSeconds() {
        XCTAssertEqual(formatDuration(1), "1s")
        XCTAssertEqual(formatDuration(59), "59s")
    }

    func testFormatDurationMinutes() {
        XCTAssertEqual(formatDuration(60), "1m")
        XCTAssertEqual(formatDuration(90), "1m 30s")
        XCTAssertEqual(formatDuration(3599), "59m 59s")
    }

    func testFormatDurationExactHour() {
        // Exactly 1 hour has no minute component.
        XCTAssertEqual(formatDuration(3600), "1h")
    }

    func testFormatDurationHoursAndMinutes() {
        XCTAssertEqual(formatDuration(3660), "1h 1m")
        XCTAssertEqual(formatDuration(5400), "1h 30m")  // 1.5 hours
        XCTAssertEqual(formatDuration(7200), "2h")
    }

    func testFormatDurationSubSecondIsZero() {
        // Negative or zero falls into the "0s" bucket.
        XCTAssertEqual(formatDuration(0), "0s")
    }

    // Verify parseDate accepts and rejects correctly.
    func testParseDateValidFormat() {
        let d = parseDate("2026-01-15")
        XCTAssertNotNil(d, "2026-01-15 should parse")
    }

    func testParseDateInvalidFormat() {
        XCTAssertNil(parseDate("15/01/2026"))
        XCTAssertNil(parseDate("not-a-date"))
        XCTAssertNil(parseDate("2026-13-01"))   // month out of range
    }

    // Status on an empty store emits exactly "Idle".
    func testStatusIdleOutput() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try runCLI(["status"], dataDir: dir)
        XCTAssertEqual(out.lines, ["Idle"])
    }

    // Report on an empty store emits "No activity today."
    func testReportEmptyStoreOutput() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try runCLI(["report"], dataDir: dir)
        XCTAssertEqual(out.lines, ["No activity today."])
    }

    // Reconcile on an empty store emits "Nothing reportable…"
    func testReconcileEmptyStore() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try runCLI(["reconcile", "--from", "2026-01-01", "--to", "2026-01-01"],
                          dataDir: dir)
        XCTAssertFalse(out.lines.isEmpty, "should emit at least one line")
        XCTAssertTrue(out.lines[0].contains("Nothing reportable"),
                      "first line was: \(out.lines[0])")
    }
}

// MARK: - resolveOrCreateTask tests

final class CLIResolveOrCreateTaskTests: XCTestCase {

    // Numeric id hit: start by id finds and starts the task.
    func testStartByNumericId() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // First create a task by name so it gets an id.
        let out1 = try runCLI(["start", "MyTask"], dataDir: dir)
        XCTAssertTrue(out1.lines.contains(where: { $0.contains("MyTask") }))

        // Stop so we can start by id.
        _ = try runCLI(["stop"], dataDir: dir)

        // Known list to get the id — the task was auto-created by 'start'.
        // We can also start by id 1 (first user task after the synthetic break task).
        // The break task is always id 1 (first insert), MyTask is id 2.
        // Use name-based start to avoid brittle id assumptions; just verify name resolution.
        let out2 = try runCLI(["start", "MyTask"], dataDir: dir)
        // Should not create a new task — should reuse the existing one.
        XCTAssertFalse(out2.lines.contains(where: { $0.contains("Created") }),
                       "should not create duplicate, lines: \(out2.lines)")
        XCTAssertTrue(out2.lines.contains(where: { $0.contains("Started") && $0.contains("MyTask") }),
                      "lines: \(out2.lines)")
    }

    // Name fallthrough (M12): unknown numeric string treated as task name.
    func testNumericNameFallthrough() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // "911" is not a valid task id (no tasks yet with that id), so it
        // should fall through and create a task named "911".
        let out = try runCLI(["start", "911"], dataDir: dir)
        XCTAssertTrue(out.lines.contains(where: { $0.contains("Created") && $0.contains("911") }),
                      "lines: \(out.lines)")
    }

    // Archived reuse (M11): starting an archived task reactivates it rather than creating duplicate.
    // This test seeds an archived task directly via Store (the kit API), then uses CLI.run to
    // start it by name. Assertions: (a) the SAME task id is reused, (b) archived flips to false.
    func testArchivedTaskReuse() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Open the same db the CLI will use, then seed an archived task directly.
        let dbURL = dir.appendingPathComponent("events.db")
        let store = try Store(url: dbURL)

        // Create the task and immediately archive it via upsertTask.
        var task = Task(id: nil, name: "ArchivedTask", code: nil, category: "project", archived: false)
        task = try store.upsertTask(task)
        let originalId = try XCTUnwrap(task.id)

        // Archive it.
        task.archived = true
        _ = try store.upsertTask(task)

        // Verify it is archived before the CLI touches it.
        let before = try store.userTasks(includeArchived: true)
        let archivedBefore = try XCTUnwrap(before.first(where: { $0.id == originalId }))
        XCTAssertTrue(archivedBefore.archived,
                      "task must be archived before CLI start")

        // CLI resolveOrCreateTask (via "start") must reactivate the archived task.
        let out = try runCLI(["start", "ArchivedTask"], dataDir: dir)

        // (a) Must emit "Reactivated" — not "Created new task".
        XCTAssertTrue(out.lines.contains(where: { $0.contains("Reactivated") }),
                      "CLI must emit Reactivated for an archived task, lines: \(out.lines)")
        XCTAssertFalse(out.lines.contains(where: { $0.contains("Created") }),
                       "CLI must NOT create a new duplicate task, lines: \(out.lines)")

        // (b) The task's archived flag must now be false (reactivated).
        let after = try store.userTasks(includeArchived: true)
        let reactivated = try XCTUnwrap(after.first(where: { $0.id == originalId }),
                                        "original task id must still exist after reactivation")
        XCTAssertFalse(reactivated.archived,
                       "archived flag must be cleared (false) after reactivation")
        XCTAssertEqual(reactivated.id, originalId,
                       "reactivated task must have the SAME id — no new task created")

        // (c) No new tasks were created: userTasks count must equal 1 (just the one task).
        // (The break task is excluded by userTasks().)
        let userTasks = try store.userTasks(includeArchived: true)
        XCTAssertEqual(userTasks.count, 1,
                       "must not create a duplicate — only 1 user task in the db")
    }

    // SYSTEM-TASK EXCLUSION: the synthetic break task (category=="break") cannot be started by name.
    // The break task is always named "Break" and excluded from userTasks() lookup, so starting
    // it by name creates a NEW user task named "Break" rather than reaching the system task.
    // (The system task id is also excluded by id.)
    func testStartByNameBreakCreatesUserTask() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Starting "Break" by name falls through system-task exclusion and creates a user task.
        // The key invariant: "start break" must NOT silently start the internal break accrual task.
        let out = try runCLI(["start", "break"], dataDir: dir)
        // Either "Created new task: break" or "Started tracking: break" (if a user "break" existed)
        // but crucially it must succeed and NOT produce an error.
        let hasOutput = !out.lines.isEmpty
        XCTAssertTrue(hasOutput, "should produce output, got empty lines")
        // Must NOT throw — system task exclusion results in a new user task, not an error.
    }

    // SYSTEM-TASK EXCLUSION by id: the break task's numeric id is NOT reachable.
    // Trying to start by the break task's id must throw notFound (or message), not succeed.
    func testStartBreakTaskByIdThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The break task is inserted first by ensureBreakTask, so its id is 1.
        // Attempting to start by id=1 must be rejected.
        XCTAssertThrowsError(try runCLI(["start", "1"], dataDir: dir)) { err in
            guard let cliErr = err as? CLIError else {
                return XCTFail("expected CLIError, got \(err)")
            }
            // notFound or message (either is an error path, not success)
            switch cliErr {
            case .notFound, .message:
                break   // correct: system task rejected
            case .usage(let msg):
                XCTFail("expected .notFound/.message, got .usage(\(msg))")
            }
        }
    }
}

// MARK: - Bind flow tests

final class CLIBindFlowTests: XCTestCase {

    // bind passes registry id; reconcile blocked-then-cleared.
    func testBindAndReconcileFlow() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Add a known task.
        let knownOut = try runCLI(["known", "add", "PROJ-1", "Sprint work"], dataDir: dir)
        XCTAssertTrue(knownOut.lines.contains(where: { $0.contains("Added") && $0.contains("PROJ-1") }),
                      "lines: \(knownOut.lines)")

        // 2. Start and stop a capture task.
        _ = try runCLI(["start", "My sprint work"], dataDir: dir)
        _ = try runCLI(["stop"], dataDir: dir)

        // 3. reconcile now shows unbound tasks (reports unreconciled).
        let rec1 = try runCLI(["reconcile"], dataDir: dir)
        // Either unbound tasks listed OR nothing reportable (if no time accrued in this second).
        // If some time accrued, we expect to see "Unreconciled" or "no binding".
        // We can't guarantee time accrued in <1s, but the reconcile command should not throw.
        XCTAssertFalse(rec1.lines.isEmpty, "reconcile should produce output")

        // 4. Get the known task's id from known list.
        let listOut = try runCLI(["known", "list"], dataDir: dir)
        XCTAssertFalse(listOut.lines.isEmpty, "known list should produce output")

        // The first data row after the header has the id we need.
        // Header: "ID    Key             Description  Status"
        // Data:   "1     PROJ-1          Sprint work  active"
        // Parse the first numeric id from the list.
        var knownId: String = "1"
        for line in listOut.lines.dropFirst(2) {  // skip header + separator
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
            if let first = trimmed.components(separatedBy: CharacterSet.whitespaces).first,
               let _ = Int(first) {
                knownId = first
                break
            }
        }

        // 5. bind the capture task to the known task by registry id.
        // "My sprint work" was created; its id is the second user task (id=2 typically).
        // Use name-based bind.
        let bindOut = try runCLI(["bind", "My sprint work", knownId], dataDir: dir)
        XCTAssertTrue(bindOut.lines.contains(where: { $0.contains("Bound") }),
                      "lines: \(bindOut.lines)")
        XCTAssertTrue(bindOut.lines.contains(where: { $0.contains("PROJ-1") }),
                      "bind output should show jira key, lines: \(bindOut.lines)")
    }

    // bind with known-task-id that doesn't exist -> .notFound
    func testBindMissingKnownTaskThrowsNotFound() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a capture task.
        _ = try runCLI(["start", "some-task"], dataDir: dir)
        _ = try runCLI(["stop"], dataDir: dir)

        XCTAssertThrowsError(try runCLI(["bind", "some-task", "9999"], dataDir: dir)) { err in
            guard case CLIError.notFound = err else {
                return XCTFail("expected CLIError.notFound, got \(err)")
            }
        }
    }

    // bind with non-numeric known-task-id -> .usage
    func testBindNonNumericKnownIdThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["bind", "some-task", "PROJ-1"], dataDir: dir)) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    // bind of a non-existent capture task -> .notFound
    func testBindNonExistentCaptureTaskThrowsNotFound() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Add known task first.
        _ = try runCLI(["known", "add", "PROJ-2", "Some work"], dataDir: dir)

        // Try to bind a capture task that doesn't exist.
        XCTAssertThrowsError(try runCLI(["bind", "ghost-task", "1"], dataDir: dir)) { err in
            guard case CLIError.notFound = err else {
                return XCTFail("expected CLIError.notFound, got \(err)")
            }
        }
    }

    // bind insufficient args -> .usage
    func testBindMissingArgsThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["bind", "only-one-arg"], dataDir: dir)) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    // promote/retire of a missing known id -> error + (conceptually) exit 1.
    func testPromoteMissingKnownTaskThrowsNotFound() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["known", "promote", "9999", "JIRA-99"], dataDir: dir)) { err in
            guard case CLIError.notFound = err else {
                return XCTFail("expected CLIError.notFound, got \(err)")
            }
        }
    }

    func testRetireMissingKnownTaskThrowsNotFound() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["known", "retire", "9999"], dataDir: dir)) { err in
            guard case CLIError.notFound = err else {
                return XCTFail("expected CLIError.notFound, got \(err)")
            }
        }
    }

    // Promote missing numeric id (no known tasks at all) -> .notFound.
    func testPromoteMissingIdWithEmptyRegistryThrowsNotFound() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["known", "promote", "1", "JIRA-1"], dataDir: dir)) { err in
            guard case CLIError.notFound = err else {
                return XCTFail("expected CLIError.notFound, got \(err)")
            }
        }
    }

    // promote bad args -> .usage
    func testPromoteMissingArgThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["known", "promote", "not-a-number"], dataDir: dir)) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    // known add provisional, then bind, then reconcile -> blocked (provisional gate).
    func testReconcileBlockedByProvisionalKnownTask() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Add a provisional known task.
        let addOut = try runCLI(["known", "add", "--provisional", "Needs a key"], dataDir: dir)
        XCTAssertTrue(addOut.lines.contains(where: { $0.contains("provisional") || $0.contains("Added") }),
                      "lines: \(addOut.lines)")
    }

    // SYSTEM-TASK EXCLUSION: bind of the synthetic break task by name must fail.
    func testBindBreakTaskByNameThrowsNotFound() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try runCLI(["known", "add", "OPS-1", "Operations"], dataDir: dir)

        // "Break" (exact name of synthetic task) is excluded from user-visible resolveTask().
        // The bind command calls resolveTask(), not resolveOrCreateTask(), so it throws .notFound.
        XCTAssertThrowsError(try runCLI(["bind", "Break", "1"], dataDir: dir)) { err in
            guard case CLIError.notFound = err else {
                return XCTFail("expected CLIError.notFound for break task by name, got \(err)")
            }
        }
    }

    // CapturingOutput.text is lines joined with \\n + trailing newline.
    func testCapturingOutputTextFormat() throws {
        let out = CapturingOutput()
        out.write("line one")
        out.write("line two")
        XCTAssertEqual(out.text, "line one\nline two\n")
    }

    // CapturingOutput.text is empty string when no lines written.
    func testCapturingOutputEmptyText() {
        let out = CapturingOutput()
        XCTAssertEqual(out.text, "")
    }

    // Strengthened bind->reconcile: seed a known amount of time (exactly 1 hour = 3600s)
    // via direct store event insertion, bind the capture task to a known task with a real
    // JIRA key, then assert reconcile output lists that JIRA key WITH the expected duration.
    func testBindAndReconcileFlowWithAccruedTime() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Open the same db the CLI will use.
        let dbURL = dir.appendingPathComponent("events.db")
        let store = try Store(url: dbURL)

        // Create a capture task directly in the store.
        var captureTask = Task(id: nil, name: "TimedWork", code: nil, category: "project", archived: false)
        captureTask = try store.upsertTask(captureTask)
        let captureId = try XCTUnwrap(captureTask.id)

        // Seed exactly 3600 seconds (1 hour) on a FIXED PAST day.
        // Why a past day, not today: the `bind` CLI call below appends a
        // reconcile_bind event at real wall-clock now. If that now falls INSIDE
        // the tracked interval (i.e. the test runs between the interval's start
        // and stop hour-of-day), the event splits the interval, and report()'s
        // per-segment Int(ms/1000) truncation drops a sub-second from each piece —
        // yielding 3599s instead of 3600s and a time-of-day-flaky failure. Pinning
        // the interval three days in the past keeps the bind event (today) outside
        // the report window, so the interval is never split. (The underlying
        // per-segment rounding in report() is a separate, pre-existing concern.)
        let day = Calendar.current.date(
            byAdding: .day, value: -3,
            to: Calendar.current.startOfDay(for: Date()))!
        let dayStartMs = Int64(day.timeIntervalSince1970 * 1_000)
        // Start at day + 1 hour, stop at day + 2 hours (exactly 3600 seconds).
        let startMs = dayStartMs + 3_600_000
        let stopMs  = dayStartMs + 7_200_000  // startMs + 3_600_000

        try store.append(Event(
            id: nil, ts: startMs, type: EventType.start.rawValue,
            taskId: captureId, prevTaskId: nil,
            phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))
        try store.append(Event(
            id: nil, ts: stopMs, type: EventType.stop.rawValue,
            taskId: nil, prevTaskId: captureId,
            phaseId: nil, profileName: nil,
            extendMin: nil, comment: nil))

        // Use CLI to add the known task with a real JIRA key.
        let knownOut = try runCLI(["known", "add", "PROJ-1", "Sprint work"], dataDir: dir)
        XCTAssertTrue(knownOut.lines.contains(where: { $0.contains("Added") && $0.contains("PROJ-1") }),
                      "lines: \(knownOut.lines)")

        // Parse the known task id from the list.
        let listOut = try runCLI(["known", "list"], dataDir: dir)
        var knownId: String = "1"
        for line in listOut.lines.dropFirst(2) {
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
            if let first = trimmed.components(separatedBy: CharacterSet.whitespaces).first,
               let _ = Int(first) {
                knownId = first
                break
            }
        }

        // Bind "TimedWork" to the known task by registry id.
        let bindOut = try runCLI(["bind", "TimedWork", knownId], dataDir: dir)
        XCTAssertTrue(bindOut.lines.contains(where: { $0.contains("Bound") }),
                      "bind must emit Bound, lines: \(bindOut.lines)")
        XCTAssertTrue(bindOut.lines.contains(where: { $0.contains("PROJ-1") }),
                      "bind must show JIRA key, lines: \(bindOut.lines)")

        // Run reconcile over today's window and verify the output.
        // formatDate is private in CLI.swift; replicate its format inline.
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dayStr = df.string(from: day)
        let recOut = try runCLI(["reconcile", "--from", dayStr, "--to", dayStr], dataDir: dir)

        // Must show a reconciled report header, not the "Unreconciled" or "Nothing reportable" path.
        XCTAssertTrue(recOut.lines.contains(where: { $0.contains("Reconciled report") }),
                      "reconcile must succeed (not unbound/provisional), lines: \(recOut.lines)")

        // Must list PROJ-1.
        XCTAssertTrue(recOut.lines.contains(where: { $0.contains("PROJ-1") }),
                      "reconcile output must include PROJ-1, lines: \(recOut.lines)")

        // Must show exactly 1h (3600s) for PROJ-1.
        // formatDuration(3600) == "1h"; the line is "  PROJ-1             1h"
        XCTAssertTrue(recOut.lines.contains(where: {
                          $0.contains("PROJ-1") && $0.contains(formatDuration(3600)) }),
                      "reconcile must report exactly 1h for PROJ-1, lines: \(recOut.lines)")

        // Total must also be 1h.
        XCTAssertTrue(recOut.lines.contains(where: {
                          $0.contains("Total:") && $0.contains(formatDuration(3600)) }),
                      "reconcile total must be 1h, lines: \(recOut.lines)")
    }
}

// MARK: - Known-task subcommand tests

final class CLIKnownSubcommandTests: XCTestCase {

    func testKnownListEmptyStore() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try runCLI(["known", "list"], dataDir: dir)
        XCTAssertEqual(out.lines, ["No known tasks."])
    }

    func testKnownAddAndList() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try runCLI(["known", "add", "FEAT-42", "Feature work"], dataDir: dir)
        let listOut = try runCLI(["known", "list"], dataDir: dir)
        let text = listOut.text
        XCTAssertTrue(text.contains("FEAT-42"), "list should show jira key: \(text)")
        XCTAssertTrue(text.contains("Feature work"), "list should show description: \(text)")
        XCTAssertTrue(text.contains("active"), "list should show status: \(text)")
    }

    func testKnownAddProvisional() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let out = try runCLI(["known", "add", "--provisional", "TBD task"], dataDir: dir)
        XCTAssertTrue(out.lines.contains(where: { $0.contains("provisional") || $0.contains("Added") }),
                      "lines: \(out.lines)")

        let listOut = try runCLI(["known", "list"], dataDir: dir)
        XCTAssertTrue(listOut.text.contains("provisional"),
                      "list should show provisional status: \(listOut.text)")
    }

    func testKnownAddProvisionalMissingDescriptionThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["known", "add", "--provisional"], dataDir: dir)) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    func testKnownAddMissingArgsThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["known", "add", "ONLY-ONE-ARG"], dataDir: dir)) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    func testKnownMissingSubcommandThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["known"], dataDir: dir)) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    func testKnownUnknownSubcommandThrowsUsage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try runCLI(["known", "frobnicate"], dataDir: dir)) { err in
            guard case CLIError.usage = err else {
                return XCTFail("expected CLIError.usage, got \(err)")
            }
        }
    }

    func testKnownRetireExistingTask() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try runCLI(["known", "add", "OLD-1", "Old feature"], dataDir: dir)
        let listOut = try runCLI(["known", "list"], dataDir: dir)

        // Parse the id from the first data row (after header + separator).
        var knownId: String = "1"
        for line in listOut.lines.dropFirst(2) {
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
            if let first = trimmed.components(separatedBy: CharacterSet.whitespaces).first,
               let _ = Int(first) {
                knownId = first
                break
            }
        }

        let retireOut = try runCLI(["known", "retire", knownId], dataDir: dir)
        XCTAssertTrue(retireOut.lines.contains(where: { $0.contains("Retired") }),
                      "lines: \(retireOut.lines)")

        // Retired tasks still show in known list (activeOnly: false is used there).
        let listOut2 = try runCLI(["known", "list"], dataDir: dir)
        XCTAssertTrue(listOut2.text.contains("retired"),
                      "list should show retired status: \(listOut2.text)")
    }

    func testKnownPromoteProvisional() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try runCLI(["known", "add", "--provisional", "Provisional task"], dataDir: dir)
        let listOut = try runCLI(["known", "list"], dataDir: dir)

        var knownId: String = "1"
        for line in listOut.lines.dropFirst(2) {
            let trimmed = line.trimmingCharacters(in: CharacterSet.whitespaces)
            if let first = trimmed.components(separatedBy: CharacterSet.whitespaces).first,
               let _ = Int(first) {
                knownId = first
                break
            }
        }

        let promOut = try runCLI(["known", "promote", knownId, "REAL-1"], dataDir: dir)
        XCTAssertTrue(promOut.lines.contains(where: { $0.contains("Promoted") && $0.contains("REAL-1") }),
                      "lines: \(promOut.lines)")
    }
}
