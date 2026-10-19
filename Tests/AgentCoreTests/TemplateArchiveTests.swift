import XCTest
@testable import AgentCore

private final class StakeRunner: ProcessRunning, @unchecked Sendable {
    let archive: URL
    private let lock = NSLock()
    private var calls: [String] = []
    init(archive: URL) { self.archive = archive }
    var events: [String] { lock.withLock { calls } }
    func capture(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> ProcessResult {
        try lock.withLock {
            var output = ""
            if executable == "/usr/bin/ssh-keygen" { output = "256 SHA256:fixture fixture (ED25519-SK)\n" }
            else if arguments == ["ls"] { output = "demo codex running\n" }
            else if arguments.first == "exec" {
                calls.append(arguments.last == "true" ? "restart" : "exec")
                if arguments.last?.contains(".aws/credentials") == true { calls.append("live-check") }
            } else if arguments.first == "stop" { calls.append("stop") }
            else if arguments.starts(with: ["template", "save"]) {
                calls.append("save")
                // On the old path fail before real hardware crypto can be reached.
                if calls.contains("live-check") { throw AgentError.invalidArgument("live check raced the export") }
                try FileManager.default.copyItem(at: archive, to: URL(fileURLWithPath: arguments.last!))
            } else if arguments.starts(with: ["template", "rm"]) { calls.append("remove") }
            else if arguments == ["template", "ls", "--quiet"] { output = "" }
            else { throw AgentError.invalidArgument("unexpected test command") }
            return ProcessResult(status: 0, stdout: Data(output.utf8), stderr: Data())
        }
    }
    func interactive(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> Int32 {
        throw AgentError.invalidArgument("unexpected interactive command")
    }
}

final class TemplateArchiveTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void, check: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layer = root.appendingPathComponent("rootfs")
        let image = root.appendingPathComponent("image")
        try FileManager.default.createDirectory(at: layer.appendingPathComponent("etc"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        try Data("agent:x:1000:1000::/home/agent:/bin/sh\n".utf8).write(to: layer.appendingPathComponent("etc/passwd"))
        try body(layer)
        _ = try ProcessRunner().checked("/usr/bin/tar", ["-cf", image.appendingPathComponent("layer.tar").path, "-C", layer.path, "."])
        try Data(#"[{"Config":"config.json","Layers":["layer.tar"]}]"#.utf8).write(to: image.appendingPathComponent("manifest.json"))
        try Data("{}".utf8).write(to: image.appendingPathComponent("config.json"))
        let archive = root.appendingPathComponent("template.tar")
        _ = try ProcessRunner().checked("/usr/bin/tar", ["-cf", archive.path, "-C", image.path, "."])
        try check(archive)
    }

    private func write(_ path: String, in root: URL, text: String = "fixture") throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func testCleanExportPassesWithoutGuestExecution() throws {
        try fixture({ try self.write("home/agent/.ssh/id_ed25519.pub", in: $0) }) {
            XCTAssertEqual(try TemplateArchive().preflight($0), try Digest.sha256(file: $0))
        }
    }

    func testCredentialWrittenAfterLiveCheckIsRejectedFromExport() throws {
        // The live check would see no file; the exported later state contains it.
        try fixture({ root in
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("home/agent/.aws/credentials").path))
            try self.write("home/agent/.aws/credentials", in: root)
        }) { XCTAssertThrowsError(try TemplateArchive().preflight($0)) }
    }

    func testPrivateKeyIsRejected() throws {
        try fixture({ try self.write("home/agent/.ssh/id_ed25519", in: $0) }) {
            XCTAssertThrowsError(try TemplateArchive().preflight($0))
        }
    }

    func testEmptyCredentialFileIsAllowed() throws {
        try fixture({ try self.write("home/agent/.netrc", in: $0, text: "") }) {
            try TemplateArchive().preflight($0)
        }
    }

    func testCredentialSymlinkIsRejectedWithoutFollowingIt() throws {
        try fixture({ root in
            try self.write("home/agent/content", in: root)
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("home/agent/.netrc").path, withDestinationPath: "content")
        }) { XCTAssertThrowsError(try TemplateArchive().preflight($0)) }
    }

    func testEmptyHardLinkedCredentialIsRejected() throws {
        try fixture({ root in
            try self.write("home/agent/content", in: root, text: "")
            try FileManager.default.linkItem(at: root.appendingPathComponent("home/agent/content"), to: root.appendingPathComponent("home/agent/.netrc"))
        }) { XCTAssertThrowsError(try TemplateArchive().preflight($0)) }
    }

    func testDeletedCredentialInEarlierLayerIsStillRejected() throws {
        try fixture({ try self.write("home/agent/.aws/credentials", in: $0) }) { archive in
            let root = archive.deletingLastPathComponent()
            let image = root.appendingPathComponent("image")
            let deletion = root.appendingPathComponent("deletion")
            try self.write("home/agent/.aws/.wh.credentials", in: deletion, text: "")
            _ = try ProcessRunner().checked("/usr/bin/tar", ["-cf", image.appendingPathComponent("deletion.tar").path, "-C", deletion.path, "."])
            try Data(#"[{"Config":"config.json","Layers":["layer.tar","deletion.tar"]}]"#.utf8).write(to: image.appendingPathComponent("manifest.json"))
            _ = try ProcessRunner().checked("/usr/bin/tar", ["-cf", archive.path, "-C", image.path, "."])
            XCTAssertThrowsError(try TemplateArchive().preflight(archive))
        }
    }

    func testOCIExportIsInspectedAndLayerDigestIsVerified() throws {
        try fixture({ _ in }) { archive in
            let root = archive.deletingLastPathComponent()
            let image = root.appendingPathComponent("image")
            let layer = image.appendingPathComponent("layer.tar")
            let digest = try Digest.sha256(file: layer)
            let path = "blobs/sha256/" + digest
            try FileManager.default.createDirectory(at: image.appendingPathComponent("blobs/sha256"), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: layer, to: image.appendingPathComponent(path))
            let manifest: [String: Any] = ["schemaVersion": 2, "layers": [["digest": "sha256:" + digest, "mediaType": "application/vnd.oci.image.layer.v1.tar"]]]
            let data = try JSONSerialization.data(withJSONObject: manifest)
            let manifestDigest = Digest.sha256(data)
            try data.write(to: image.appendingPathComponent("blobs/sha256/" + manifestDigest))
            let index: [String: Any] = ["schemaVersion": 2, "manifests": [["digest": "sha256:" + manifestDigest, "mediaType": "application/vnd.oci.image.manifest.v1+json"]]]
            try JSONSerialization.data(withJSONObject: index).write(to: image.appendingPathComponent("index.json"))
            try FileManager.default.removeItem(at: image.appendingPathComponent("manifest.json"))
            _ = try ProcessRunner().checked("/usr/bin/tar", ["-cf", archive.path, "-C", image.path, "."])
            try TemplateArchive().preflight(archive)
            // A clean decoy manifest must not hide an index's own layer field.
            // Reject field presence even when the mixed field is malformed/empty.
            let mixedValues: [Any] = [manifest["layers"]!, [[String: Any]](), "invalid", NSNull()]
            for mixedLayers in mixedValues {
                var mixed = index
                mixed["layers"] = mixedLayers
                try JSONSerialization.data(withJSONObject: mixed).write(to: image.appendingPathComponent("index.json"))
                _ = try ProcessRunner().checked("/usr/bin/tar", ["-cf", archive.path, "-C", image.path, "."])
                XCTAssertThrowsError(try TemplateArchive().preflight(archive))
            }
            try JSONSerialization.data(withJSONObject: index).write(to: image.appendingPathComponent("index.json"))
            // A valid tar at the wrong content-addressed path must fail closed.
            try Data("tampered".utf8).write(to: image.appendingPathComponent(path))
            _ = try ProcessRunner().checked("/usr/bin/tar", ["-cf", archive.path, "-C", image.path, "."])
            XCTAssertThrowsError(try TemplateArchive().preflight(archive))
        }
    }

    func testDuplicateArchivePathsFailClosed() throws {
        try fixture({ _ in }) { archive in
            let image = archive.deletingLastPathComponent().appendingPathComponent("image")
            _ = try ProcessRunner().checked("/usr/bin/tar", ["-cf", archive.path, "-C", image.path, "manifest.json", "manifest.json", "config.json", "layer.tar"])
            XCTAssertThrowsError(try TemplateArchive().preflight(archive))
        }
    }

    func testLinkedCredentialDirectoryIsRejected() throws {
        try fixture({ root in
            try self.write("home/agent/content/credentials", in: root)
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("home/agent/.aws").path, withDestinationPath: "content")
        }) { XCTAssertThrowsError(try TemplateArchive().preflight($0)) }
    }

    func testCustomAgentHomeIsInspected() throws {
        try fixture({ root in
            try self.write("etc/passwd", in: root, text: "agent:x:1000:1000::/srv/user:/bin/sh\n")
            try self.write("srv/user/.codex/auth.json", in: root)
        }) { XCTAssertThrowsError(try TemplateArchive().preflight($0)) }
    }

    func testMissingAgentAccountFailsClosed() throws {
        try fixture({ try self.write("etc/passwd", in: $0, text: "root:x:0:0::/root:/bin/sh\n") }) {
            XCTAssertThrowsError(try TemplateArchive().preflight($0))
        }
    }

    func testMalformedExportFailsClosed() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not an image".utf8).write(to: file)
        XCTAssertThrowsError(try TemplateArchive().preflight(file))
    }

    func testStakeRejectsRacedExportAndCleansUpBeforeResuming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("fixture.tar")
        try fixture({ try self.write("home/agent/.aws/credentials", in: $0) }) {
            try FileManager.default.copyItem(at: $0, to: archive)
        }
        let runner = StakeRunner(archive: archive)
        let paths = AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config"))
        let workspace = try WorkspaceService(paths: paths, runner: runner)
        let pub = root.appendingPathComponent("fixture.pub")
        try Data("sk-ssh-ed25519@openssh.com fixture\n".utf8).write(to: pub)
        try await workspace.store.saveConfiguration(AgentConfiguration(authorizationKey: pub.path, pivCertificateSHA256: "fixture"))
        let vault = try VaultService(paths: paths, workspaceService: workspace, runner: runner)
        let record = WorkspaceRecord(
            name: "demo", sandboxName: "demo", repoPath: "/tmp/demo", repoName: "demo",
            vendor: .codex, branch: "main", sourceState: .clean, sandboxHome: "/home/agent",
            targetPath: "/home/agent/code/demo", baselineTemplate: "baseline/demo"
        )
        do {
            _ = try await vault.stake(workspace: record, tag: "raced")
            XCTFail("credential-bearing export must not be encrypted or signed")
        } catch AgentError.unsafe { }
        catch { XCTFail("expected archive rejection, got \(error)") }
        let events = runner.events
        XCTAssertFalse(events.contains("live-check"))
        XCTAssertEqual(Array(events.suffix(3)), ["save", "remove", "restart"])
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "stop")), try XCTUnwrap(events.firstIndex(of: "save")))
        let stakes = try await vault.vaultStore.nextGeneration(repoPath: "/tmp/demo")
        XCTAssertEqual(stakes, 0)
    }
}
