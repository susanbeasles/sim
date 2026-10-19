import Foundation
import XCTest
import Darwin
@testable import AgentCore

// Only sandbox transport is replaced; tar, Git, selection and host writes are real.
private struct ExportRunner: ProcessRunning {
    let archive: URL

    func capture(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> ProcessResult {
        if executable == "/usr/local/bin/sbx" {
            XCTAssertEqual(arguments.first, "exec")
            return ProcessResult(status: 0, stdout: try Data(contentsOf: archive), stderr: Data())
        }
        // Temporary review repositories must not inherit the operator's signer.
        let isolated = (environment ?? ProcessInfo.processInfo.environment).merging([
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        ]) { _, value in value }
        return try ProcessRunner().capture(executable, arguments, environment: isolated)
    }

    func interactive(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> Int32 {
        XCTFail("unexpected interactive process")
        return 1
    }
}

@MainActor
final class GitSelectionTests: XCTestCase {
    func testSelectedImportsLeaveOtherCandidateFilesUntouched() async throws {
        for theirs in [false, true] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            if theirs {
                try await fixture.bridge.takeTheirs(fixture.workspace, selected: ["a.txt"], authorize: false)
            } else {
                let conflicts = try await fixture.bridge.merge(fixture.workspace, selected: ["a.txt"], authorize: false)
                XCTAssertTrue(conflicts.isEmpty)
            }
            XCTAssertEqual(try String(contentsOf: fixture.host.appendingPathComponent("a.txt"), encoding: .utf8), "candidate\n")
            XCTAssertEqual(try String(contentsOf: fixture.host.appendingPathComponent("b.txt"), encoding: .utf8), "baseline\n")
        }
    }

    func testDeleteVersusModeChangePreservesHostAndReportsConflict() async throws {
        for candidateDeletes in [true, false] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let candidate = fixture.root.appendingPathComponent("candidate")
            let hostFile = fixture.host.appendingPathComponent("a.txt")
            let candidateFile = candidate.appendingPathComponent("a.txt")
            if candidateDeletes {
                try FileManager.default.removeItem(at: candidateFile)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hostFile.path)
            } else {
                try Data("baseline\n".utf8).write(to: candidateFile)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidateFile.path)
                try FileManager.default.removeItem(at: hostFile)
            }
            _ = try ProcessRunner().checked("/usr/bin/tar", ["--format=ustar", "-cf", fixture.root.appendingPathComponent("candidate.tar").path, "-C", candidate.path] + (candidateDeletes ? ["b.txt"] : ["a.txt", "b.txt"]))
            let conflicts = try await fixture.bridge.merge(fixture.workspace, selected: ["a.txt"], authorize: false)
            XCTAssertEqual(conflicts, ["a.txt"])
            if candidateDeletes {
                XCTAssertEqual(try Data(contentsOf: hostFile), Data("baseline\n".utf8))
                let permissions = try FileManager.default.attributesOfItem(atPath: hostFile.path)[.posixPermissions] as? NSNumber
                XCTAssertEqual(permissions?.intValue, 0o755)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: hostFile.path))
            }
        }
    }

    func testAuthorizationShowsResolvedSelectionBeforeRequestingKey() async throws {
        for theirs in [false, true] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let output = Pipe()
            fflush(nil)
            let saved = dup(STDOUT_FILENO)
            XCTAssertGreaterThanOrEqual(saved, 0)
            dup2(output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
            do {
                if theirs {
                    try await fixture.bridge.takeTheirs(fixture.workspace, selected: ["a.txt"])
                } else {
                    _ = try await fixture.bridge.merge(fixture.workspace, selected: ["a.txt"])
                }
                XCTFail("fixture has no authorization key")
            } catch AgentError.authorizationRequired { }
            catch {
                fflush(nil)
                dup2(saved, STDOUT_FILENO)
                close(saved)
                throw error
            }
            fflush(nil)
            dup2(saved, STDOUT_FILENO)
            close(saved)
            try output.fileHandleForWriting.close()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertTrue(text.contains("\"a.txt\""), text)
            XCTAssertFalse(text.contains("\"b.txt\""), text)
            XCTAssertTrue(text.contains("pathsSHA256=18b7cb099a9ea3f50ba899b5ba81e0d377a5f3b16f8f6eeb8b3e58cd4692b993"), text)
            XCTAssertEqual(try String(contentsOf: fixture.host.appendingPathComponent("a.txt"), encoding: .utf8), "baseline\n")
        }
    }

    private func fixture() throws -> (root: URL, host: URL, bridge: GitBridge, workspace: WorkspaceRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = root.appendingPathComponent("host")
        let candidate = root.appendingPathComponent("candidate")
        let paths = AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config"))
        let baseline = paths.workspace("WS").appendingPathComponent("baseline/repo")
        for directory in [host, candidate, baseline] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["a.txt", "b.txt"] {
                try Data((directory == candidate ? "candidate\n" : "baseline\n").utf8).write(to: directory.appendingPathComponent(name))
            }
        }
        let runner = ProcessRunner()
        _ = try runner.checked("/usr/bin/git", ["-C", host.path, "init", "-q"])
        _ = try runner.checked("/usr/bin/git", ["-C", host.path, "add", "-A"])
        _ = try runner.checked("/usr/bin/git", ["-C", host.path, "-c", "user.name=Test", "-c", "user.email=test@invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "baseline"])
        let archive = root.appendingPathComponent("candidate.tar")
        _ = try runner.checked("/usr/bin/tar", ["--format=ustar", "-cf", archive.path, "-C", candidate.path, "a.txt", "b.txt"])
        let bridge = try GitBridge(paths: paths, runner: ExportRunner(archive: archive))
        let workspace = WorkspaceRecord(name: "WS", sandboxName: "test", repoPath: host.path, repoName: "repo", vendor: .codex, branch: "main", sourceState: .clean, sandboxHome: "/home/agent", targetPath: "/repo", baselineTemplate: "test")
        return (root, host, bridge, workspace)
    }
}
