import XCTest
@testable import AgentCore

final class ProcessRunnerTests: XCTestCase {
    func testRejectsOversizedOutput() throws {
        XCTAssertThrowsError(try ProcessRunner().capture("/bin/dd", ["if=/dev/zero", "bs=1048576", "count=70"]))
    }
}

extension ProcessRunnerTests {
    func testDrainsBothStreamsWithoutDeadlock() throws {
        let result = try ProcessRunner(outputBytes: 1024 * 1024, timeout: 2).capture("/bin/sh", ["-c", "dd if=/dev/zero bs=32768 count=4 >&2 & dd if=/dev/zero bs=32768 count=4; wait"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 131072)
        XCTAssertGreaterThanOrEqual(result.stderr.count, 131072)
    }

    func testCombinedStreamsCannotExceedBudget() throws {
        XCTAssertThrowsError(try ProcessRunner(outputBytes: 1024).capture("/bin/sh", ["-c", "printf '%600s' ''; printf '%600s' '' >&2"]))
    }

    func testAcceptsOutputAtLimit() throws {
        let result = try ProcessRunner(outputBytes: 1024).capture("/usr/bin/printf", ["%1024s", ""])
        XCTAssertEqual(result.stdout.count, 1024)
    }

    func testKillsCommandOnTimeout() throws {
        let start = ContinuousClock.now
        XCTAssertThrowsError(try ProcessRunner(timeout: 0.05).capture("/bin/sleep", ["10"]))
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testFailureTerminatesDescendantsEvenAfterLeaderExit() throws {
        for outputFailure in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let marker = root.appendingPathComponent("survived")
            let started = root.appendingPathComponent("started")
            let script = "(sleep 0.5; printf survived > \"$1\") & printf started > \"$2\"; "
                + (outputFailure ? "printf '%1024s' ''; exit 0" : "exit 0")
            let runner = ProcessRunner(outputBytes: outputFailure ? 32 : 1024, timeout: 0.2)
            XCTAssertThrowsError(try runner.capture("/bin/sh", ["-c", script, "fixture", marker.path, started.path]))
            XCTAssertTrue(FileManager.default.fileExists(atPath: started.path), "fixture must launch before capture fails")
            Thread.sleep(forTimeInterval: 0.6)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "descendant continued running after capture failure")
        }
    }
}
