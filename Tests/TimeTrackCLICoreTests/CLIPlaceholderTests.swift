import XCTest
@testable import TimeTrackCLICore

/// Placeholder so the target compiles; subsequent agents fill in real coverage.
///
/// How to write real tests against the core (documented here for the next agent):
///   1. Make a unique temp dir:
///        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
///                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
///        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
///        defer { try? FileManager.default.removeItem(at: dir) }
///   2. Capture output and invoke a command with explicit argv + injected dir:
///        let out = CapturingOutput()
///        try CLI.run(arguments: ["status"], dataDir: dir, out: out)
///        XCTAssertEqual(out.lines, ["Idle"])
///   3. Assert error behavior (the shell maps these thrown errors to exit 1):
///        XCTAssertThrowsError(try CLI.run(arguments: ["bogus"], dataDir: dir, out: out)) {
///            guard case CLIError.usage = $0 else { return XCTFail("expected .usage") }
///        }
final class CLIPlaceholderTests: XCTestCase {
    func testFormatDurationIsImportable() {
        // Sanity that the public surface is reachable from the test target.
        XCTAssertEqual(formatDuration(0), "0s")
        XCTAssertEqual(formatDuration(90), "1m 30s")
        XCTAssertEqual(formatDuration(3600), "1h")
    }
}
