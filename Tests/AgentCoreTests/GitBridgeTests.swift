import XCTest
@testable import AgentCore

final class GitBridgeTests: XCTestCase {
    func testHostGitRefusesFiltersWithoutWeakeningSigning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = ProcessRunner()
        func git(_ args: [String]) throws -> String {
            try runner.checked("/usr/bin/git", ["-C", root.path] + args).stdoutString
        }
        _ = try git(["init", "-q"])
        try Data("candidate".utf8).write(to: root.appendingPathComponent("file"))
        try Data("file filter=unsafe\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        _ = try git(["add", "-A"])
        _ = try git(["config", "filter.unsafe.clean", "touch filter-executed; cat"])
        _ = try git(["config", "commit.gpgsign", "true"])
        let bridge = try GitBridge(paths: AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config")))
        for arguments in [["status", "--porcelain"], ["add", "-A"], ["commit", "-m", "candidate"]] {
            do {
                _ = try await bridge.hostGit(root.path, arguments)
                XCTFail("host filter configuration must fail before execution")
            } catch {
                XCTAssertTrue(String(describing: error).contains("configured Git filters"))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("filter-executed").path))
        XCTAssertEqual(try git(["config", "commit.gpgsign"]).trimmingCharacters(in: .whitespacesAndNewlines), "true")
    }

    func testCommitDoesNotExecuteTrackedHooks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = ProcessRunner()
        func git(_ args: [String]) throws -> String {
            try runner.checked("/usr/bin/git", ["-C", root.path] + args).stdoutString
        }
        _ = try git(["init", "-q"])
        _ = try git(["config", "user.name", "Test"])
        _ = try git(["config", "user.email", "test@invalid"])
        _ = try git(["config", "commit.gpgsign", "false"])
        _ = try git(["config", "core.hooksPath", ".githooks"])
        let hooks = root.appendingPathComponent(".githooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        for hook in ["pre-commit", "prepare-commit-msg", "commit-msg", "post-commit"] {
            let file = hooks.appendingPathComponent(hook)
            try Data("#!/bin/sh\ntouch hook-executed\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        _ = try git(["add", "-A"])
        let bridge = try GitBridge(paths: AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config")))
        try await bridge.commit(repo: root.path, message: "candidate")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("hook-executed").path))
        XCTAssertEqual(try git(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines), "candidate")
        XCTAssertEqual(try git(["config", "core.hooksPath"]).trimmingCharacters(in: .whitespacesAndNewlines), ".githooks")
    }
}
