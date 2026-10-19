import Foundation
import XCTest
@testable import AgentCore

private final class ChangingExportRunner: ProcessRunning, @unchecked Sendable {
    let archives: [Data]
    var exports = 0
    init(archives: [Data]) { self.archives = archives }
    func capture(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> ProcessResult {
        if executable == "/usr/local/bin/sbx" {
            XCTAssertEqual(arguments.first, "exec")
            let bytes = archives[min(exports, archives.count - 1)]
            exports += 1
            return ProcessResult(status: 0, stdout: bytes, stderr: Data())
        }
        return try ProcessRunner().capture(executable, arguments, environment: environment)
    }
    func interactive(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> Int32 {
        XCTFail("no hardware ceremony or interactive command is allowed in this fixture")
        return 1
    }
}

@MainActor
final class CommitSnapshotTests: XCTestCase {
    func testCommitRequestsAuthorizationForOnlyOneGuestExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("host")
        let paths = AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config"))
        let baseline = paths.workspace("WS").appendingPathComponent("baseline/repo")
        for directory in [host, baseline] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("baseline\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
        }
        let process = ProcessRunner()
        _ = try process.checked("/usr/bin/git", ["-C", host.path, "init", "-q"])
        _ = try process.checked("/usr/bin/git", ["-C", host.path, "add", "-A"])
        _ = try process.checked("/usr/bin/git", ["-C", host.path, "-c", "user.name=Test", "-c", "user.email=test@invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "baseline"])
        var archives: [Data] = []
        for index in 0..<2 {
            let directory = root.appendingPathComponent("candidate-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data((index == 0 ? "first candidate\n" : "second candidate\r\n").utf8).write(to: directory.appendingPathComponent("file.txt"))
            var names = ["file.txt"]
            if index == 1 {
                try Data("* text\n".utf8).write(to: directory.appendingPathComponent(".gitattributes"))
                names.append(".gitattributes")
            }
            let archive = root.appendingPathComponent("candidate-\(index).tar")
            _ = try process.checked("/usr/bin/tar", ["--format=ustar", "-cf", archive.path, "-C", directory.path] + names)
            archives.append(try Data(contentsOf: archive))
        }
        let runner = ChangingExportRunner(archives: archives)
        let bridge = try GitBridge(paths: paths, runner: runner)
        let workspace = WorkspaceRecord(name: "WS", sandboxName: "test", repoPath: host.path, repoName: "repo", vendor: .codex, branch: "main", sourceState: .clean, sandboxHome: "/home/agent", targetPath: "/repo", baselineTemplate: "test")
        do {
            try await bridge.commit(workspace, message: "candidate")
            XCTFail("fixture has no configured authorization key")
        } catch AgentError.authorizationRequired { }
        XCTAssertEqual(runner.exports, 1, "preflight and authorization must consume the same guest snapshot")
        XCTAssertEqual(try Data(contentsOf: host.appendingPathComponent("file.txt")), Data("baseline\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.appendingPathComponent(".gitattributes").path))
    }

    func testStagedVerificationRejectsNormalizedBytesAndIncorrectMode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = ProcessRunner()
        func git(_ arguments: [String]) throws {
            _ = try process.checked("/usr/bin/git", ["-C", root.path] + arguments)
        }
        try git(["init", "-q"])
        let raw = Data("authorized\r\n".utf8)
        try Data("* text\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        try raw.write(to: root.appendingPathComponent("file.txt"))
        try git(["add", "file.txt"])
        let bridge = try GitBridge(paths: AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config")))
        do {
            try await bridge.verifyStagedObject(repo: root.path, path: "file.txt", data: raw)
            XCTFail("normalized staged bytes must not match the raw authorization")
        } catch AgentError.unsafe { }
        try Data("* -text\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        try raw.write(to: root.appendingPathComponent("file.txt"))
        try git(["add", "file.txt"])
        try await bridge.verifyStagedObject(repo: root.path, path: "file.txt", data: raw)
        do {
            try await bridge.verifyStagedObject(repo: root.path, path: "file.txt", data: raw, mode: 0o755)
            XCTFail("incorrect executable mode must be rejected")
        } catch AgentError.unsafe { }
    }
}
