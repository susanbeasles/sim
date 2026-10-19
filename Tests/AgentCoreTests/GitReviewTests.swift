import XCTest
@testable import AgentCore

// Replace only VM transport; tar, filesystem, Git and audit remain real.
private struct ArchiveTransport: ProcessRunning {
    let archive: Data
    var process = ProcessRunner()
    func capture(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> ProcessResult {
        if executable == "/usr/local/bin/sbx" {
            return ProcessResult(status: 0, stdout: archive, stderr: Data())
        }
        return try process.capture(executable, arguments, environment: environment)
    }
    func interactive(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> Int32 { 0 }
}

final class GitReviewTests: XCTestCase, @unchecked Sendable {
    private func fixture(at root: URL, bytes: Data, process: ProcessRunner = ProcessRunner(), files: [String: String] = [:]) throws -> (GitBridge, WorkspaceRecord, URL) {
        let guest = root.appendingPathComponent("guest")
        try FileManager.default.createDirectory(at: guest, withIntermediateDirectories: true)
        try bytes.write(to: guest.appendingPathComponent("candidate"))
        for (path, content) in files {
            let target = guest.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: target)
        }
        let archive = try ProcessRunner().checked("/usr/bin/tar", ["--format=ustar", "-cf", "-", "-C", guest.path, "candidate"] + files.keys.sorted()).stdout
        let paths = AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config"))
        let baseline = paths.workspace("test").appendingPathComponent("baseline/repo")
        try FileManager.default.createDirectory(at: baseline, withIntermediateDirectories: true)
        let bridge = try GitBridge(paths: paths, runner: ArchiveTransport(archive: archive, process: process))
        let workspace = WorkspaceRecord(name: "test", sandboxName: "test", repoPath: guest.path, repoName: "repo", vendor: .codex, branch: "main", sourceState: .clean, sandboxHome: "/home/agent", targetPath: "/repo", baselineTemplate: "test")
        return (bridge, workspace, paths.workspace("test").appendingPathComponent("export"))
    }

    func testRejectsOversizedFileAndRemovesExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (bridge, workspace, export) = try fixture(at: root, bytes: Data(repeating: 1, count: 17 * 1024 * 1024))
        do {
            _ = try await bridge.prepareReview(workspace)
            XCTFail("oversized guest file was accepted")
        } catch {
            XCTAssertTrue(String(describing: error).contains("byte limit"), "unexpected error: \(error)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        }
    }

    func testRejectsMetadataAliasesBeforeExecutingCandidateFilter() async throws {
        for alias in [".GIT", ".GiT", "nested/.GIT", ".g\u{200c}it"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let marker = root.appendingPathComponent("executed")
            let config = "[filter \"candidate\"]\n clean = touch '\(marker.path)'\n"
            let (bridge, workspace, export) = try fixture(at: root, bytes: Data("payload".utf8), files: [
                alias + "/config": config,
                ".gitattributes": "candidate filter=candidate\n"
            ])
            do {
                _ = try await bridge.prepareReview(workspace)
                XCTFail("accepted metadata alias: \(alias)")
            } catch {
                XCTAssertTrue(String(describing: error).contains("unsafe"), "unexpected error: \(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        }
    }

    func testProducesPatchWithRealGitAndPreservesCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (bridge, workspace, export) = try fixture(at: root, bytes: Data("hello\n".utf8))
        let patch = try await bridge.prepareReview(workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.appendingPathComponent("review/.git").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.appendingPathComponent("review.git/config").path))
        let text = try String(contentsOf: patch, encoding: .utf8)
        XCTAssertTrue(text.contains("+hello\n"))
        XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("result/candidate")), Data("hello\n".utf8))
        let changes = try await bridge.changedPaths(workspace)
        XCTAssertEqual(changes.map(\.path), ["candidate"])
        XCTAssertEqual(changes.first?.status, .added)
    }

    func testImportSnapshotsComeFromReviewedIndexRatherThanMutableExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let authorized = Data("authorized\r\n".utf8)
        let (bridge, workspace, export) = try fixture(at: root, bytes: authorized)
        let patch = try await bridge.prepareReview(workspace)
        let digest = try Digest.sha256(file: patch)
        let changes = try await bridge.changedPaths(workspace)
        for directory in ["result", "review"] {
            try Data("mutated after review".utf8).write(to: export.appendingPathComponent(directory + "/candidate"))
        }
        let captured = try await bridge.captureImports(review: export.appendingPathComponent("review"), changes: changes, patchDigest: digest)
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.candidate?.bytes, authorized)
        XCTAssertEqual(captured.first?.candidate?.mode, 0o644)
        XCTAssertNil(captured.first?.baseline)
        do {
            _ = try await bridge.captureImports(review: export.appendingPathComponent("review"), changes: changes, patchDigest: String(repeating: "0", count: 64))
            XCTFail("changed patch must be rejected")
        } catch { }
    }

    func testIdentAndEncodingAttributesPreserveExactIndexedBytes() async throws {
        let cases: [(String, Data)] = [
            ("candidate ident\n", Data("$Id: expanded-value $\n".utf8)),
            ("candidate working-tree-encoding=UTF-16\n", Data([0xff, 0xfe, 0x41, 0x00, 0x0a, 0x00]))
        ]
        for (attributes, authorized) in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (bridge, workspace, export) = try fixture(at: root, bytes: authorized, files: [".gitattributes": attributes])
            let patch = try await bridge.prepareReview(workspace)
            let changes = try await bridge.changedPaths(workspace)
            let captured = try await bridge.captureImports(review: export.appendingPathComponent("review"), changes: changes, patchDigest: Digest.sha256(file: patch))
            XCTAssertEqual(captured.first(where: { $0.change.path == "candidate" })?.candidate?.bytes, authorized)
        }
    }

    func testCandidateAttributesCannotHideRawByteChanges() async throws {
        var patches: [Data] = []
        for content in ["authorized\n", "authorized\r\n"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let (bridge, workspace, _) = try fixture(at: root, bytes: Data(content.utf8), files: [
                ".gitattributes": "candidate text eol=lf ident\n"
            ])
            let patch = try await bridge.prepareReview(workspace)
            patches.append(try Data(contentsOf: patch))
        }
        XCTAssertNotEqual(patches[0], patches[1], "authorization must distinguish the bytes import will copy")
    }

    func testRejectsBinaryDiffExpansionAndRemovesExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Deterministic, incompressible binary fixture. Expanded Git patch exceeds 4 KiB.
        var state: UInt32 = 1
        var bytes = Data([0])
        for _ in 0..<8192 {
            state = state &* 1664525 &+ 1013904223
            bytes.append(UInt8(truncatingIfNeeded: state >> 24))
        }
        let (bridge, workspace, export) = try fixture(at: root, bytes: bytes, process: ProcessRunner(outputBytes: 4096))
        do {
            _ = try await bridge.prepareReview(workspace)
            XCTFail("oversized binary diff was accepted")
        } catch {
            XCTAssertTrue(String(describing: error).contains("output limit"), "unexpected error: \(error)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        }
    }
}
