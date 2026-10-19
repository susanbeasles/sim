import Foundation
import XCTest
@testable import sim

final class MergeTests: XCTestCase {
    func testSelectionKeepsPathsLiteralAndDefaultsToAllOnlyWhenOmitted() throws {
        let all = try MergeOptions(["WS", "--theirs"])
        XCTAssertEqual(all.workspace, "WS")
        XCTAssertNil(all.selected)
        XCTAssertTrue(all.theirs)
        let selection = try MergeOptions(["--theirs", "WS", "--", "src/a.ts", "--mine", "a b.txt", "src/a.ts"])
        XCTAssertEqual(selection.selected, ["src/a.ts", "--mine", "a b.txt"])
        XCTAssertFalse(selection.mine)
        XCTAssertNil(try MergeOptions(["--", "a.txt"]).workspace)
        XCTAssertNil(try MergeOptions([]).selected)
    }

    func testRejectsAmbiguousSelectionBeforeOpeningWorkspace() throws {
        let cases = [
            ["WS", "--theirs", "src/a.ts"],
            ["WS", "src/a.ts", "--", "src/b.ts"],
            ["WS", "--theirs", "--"],
            ["--"],
            ["WS", "--thiers"],
            ["WS", "--mine", "--theirs"],
            ["WS", "--", ""],
        ]
        var directory = Bundle(for: Self.self).bundleURL
        while directory.path != "/", !FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("sim").path) {
            directory.deleteLastPathComponent()
        }
        let executable = directory.appendingPathComponent("sim")
        for args in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let process = Process()
            process.executableURL = executable
            process.arguments = ["git", "merge"] + args
            process.environment = ProcessInfo.processInfo.environment.merging([
                "AGENT_STATE_ROOT": root.appendingPathComponent("state").path,
                "AGENT_CONFIG_ROOT": root.appendingPathComponent("config").path,
            ]) { _, value in value }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 64, "\(args): \(text)")
            XCTAssertTrue(text.contains("usage: sim git merge"), "\(args): \(text)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "invalid syntax touched state: \(args)")
        }
    }
}
