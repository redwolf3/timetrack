import Foundation
import XCTest
@testable import TimeTrackKit

final class ProfileLoaderTests: XCTestCase {

    private func writeProfiles(_ content: String, to dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("profiles.yaml")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testLoadValidMultiProfileFile() throws {
        let dir = try makeTmpDir()
        let yaml = """
        profiles:
          - name: alpha
            cycle:
              - id: work
                durationMin: 25
                onArm:
                  sound: Tink
                  color: amber
                  actions: []
          - name: beta
            cycle:
              - id: work
                durationMin: 50
                onArm:
                  sound: Glass
                  color: green_pulse
                  actions: []
        """
        let url = try writeProfiles(yaml, to: dir)

        let profiles = try ProfileLoader.loadAll(from: url)
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].name, "alpha")
        XCTAssertEqual(profiles[1].name, "beta")
    }

    func testDuplicateProfileNameThrows() throws {
        let dir = try makeTmpDir()
        let yaml = """
        profiles:
          - name: default
            cycle:
              - id: work
                durationMin: 25
                onArm:
                  sound: Tink
                  color: amber
                  actions: []
          - name: default
            cycle:
              - id: work
                durationMin: 50
                onArm:
                  sound: Glass
                  color: green_pulse
                  actions: []
        """
        let url = try writeProfiles(yaml, to: dir)

        XCTAssertThrowsError(try ProfileLoader.loadAll(from: url)) { error in
            guard let ve = error as? ProfileLoader.ValidationError else {
                return XCTFail("expected ProfileLoader.ValidationError, got \(error)")
            }
            let desc = ve.description
            XCTAssertTrue(desc.contains("default"), "error must name the duplicate profile: \(desc)")
        }
    }

    // First-run path: no profiles.yaml on disk → seedDefaults writes one, and
    // the seeded literal must itself parse and pass validation. Guards the
    // 60-line seed string against future edits breaking first launch.
    func testMissingFileSeedsDefaultsAndLoads() throws {
        let dir = try makeTmpDir()
        let url = dir.appendingPathComponent("profiles.yaml")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let profiles = try ProfileLoader.loadAll(from: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "seedDefaults must write profiles.yaml on first run")
        XCTAssertGreaterThanOrEqual(profiles.count, 2)

        // Re-loading must not re-seed or diverge.
        let again = try ProfileLoader.loadAll(from: url)
        XCTAssertEqual(again.map(\.name), profiles.map(\.name))
    }

    func testSingleProfileFileLoadsWithoutError() throws {
        let dir = try makeTmpDir()
        let yaml = """
        profiles:
          - name: solo
            cycle:
              - id: work
                durationMin: 30
                onArm:
                  sound: Tink
                  color: amber
                  actions: []
        """
        let url = try writeProfiles(yaml, to: dir)

        let profiles = try ProfileLoader.loadAll(from: url)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].name, "solo")
    }
}
