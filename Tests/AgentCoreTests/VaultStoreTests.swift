import XCTest
@testable import AgentCore

final class VaultStoreTests: XCTestCase {
    private func fixture(id: UUID = UUID(), generation: Int = 0, tag: String = "root baseline") -> StakeManifest {
        StakeManifest(
            id: id,
            generation: generation,
            tag: tag,
            repoName: "triggr_api",
            repoPathHint: "/Users/test/code/triggr_api",
            branch: "main",
            vendor: .claude,
            sandboxName: "triggr-api-claude",
            templateTag: "agent-stake/triggr_api:g\(generation)-deadbeef",
            sbxVersion: "0.45.0",
            parentStakeID: nil,
            parentManifestSHA256: nil,
            hostAuditHead: "hosthead",
            guestAuditHead: "guesthead",
            artifact: VaultArtifactDescriptor(
                objectKey: "objects/sha256-abc.agtvault",
                ciphertextSHA256: "abc",
                plaintextSHA256: "def",
                plaintextBytes: 100,
                ciphertextBytes: 140,
                chunkBytes: 8 * 1024 * 1024
            ),
            keyWrap: VaultKeyWrap(recipientCertificateSHA256: String(repeating: "a", count: 64), wrappedKeyBase64: "AA==")
        )
    }

    func testCommitResolveAndTamperDetection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config"))
        let store = try VaultStore(paths: paths)
        let manifest = fixture()
        let data = try await store.canonicalManifestData(manifest)
        let record = try await store.commit(manifest: manifest, manifestData: data, signature: Data("sig".utf8))

        let next = try await store.nextGeneration(repoPath: "/Users/test/code/triggr_api")
        let byGeneration = try await store.resolve(repoPath: "/Users/test/code/triggr_api", selector: .generation(0))
        let byTag = try await store.resolve(repoPath: "/Users/test/code/triggr_api", selector: .tag("root baseline"))
        let byID = try await store.resolve(repoPath: "/Users/test/code/triggr_api", selector: .id(manifest.id))
        XCTAssertEqual(next, 1)
        XCTAssertEqual(byGeneration.manifest.id, manifest.id)
        XCTAssertEqual(byTag.manifest.id, manifest.id)
        XCTAssertEqual(byID.manifest.id, manifest.id)

        let manifestURL = paths.vaultManifests.appendingPathComponent(record.manifestFile)
        var bytes = try Data(contentsOf: manifestURL)
        bytes.append(0x20)
        try bytes.write(to: manifestURL)
        do {
            _ = try await store.resolve(repoPath: "/Users/test/code/triggr_api", selector: .generation(0))
            XCTFail("tampered manifest should fail")
        } catch { }
    }

    func testDuplicateGenerationRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config"))
        let store = try VaultStore(paths: paths)
        let first = fixture(generation: 0)
        let firstData = try await store.canonicalManifestData(first)
        _ = try await store.commit(manifest: first, manifestData: firstData, signature: Data("sig".utf8))
        let second = fixture(generation: 0, tag: "other")
        let secondData = try await store.canonicalManifestData(second)
        do {
            _ = try await store.commit(manifest: second, manifestData: secondData, signature: Data("sig".utf8))
            XCTFail("duplicate generation should fail")
        } catch { }
    }
}

extension VaultStoreTests {
    func testDuplicateTagRejectedBecauseTagsAreImmutableNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config"))
        let store = try VaultStore(paths: paths)
        let first = fixture(generation: 0, tag: "root baseline")
        _ = try await store.commit(manifest: first, manifestData: await store.canonicalManifestData(first), signature: Data("sig".utf8))
        let second = fixture(generation: 1, tag: "root baseline")
        do {
            _ = try await store.commit(manifest: second, manifestData: await store.canonicalManifestData(second), signature: Data("sig".utf8))
            XCTFail("duplicate immutable tag should fail")
        } catch { }
    }

    func testIndexDeletionDoesNotHideSignedManifestRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config"))
        let store = try VaultStore(paths: paths)
        let manifest = fixture()
        _ = try await store.commit(manifest: manifest, manifestData: await store.canonicalManifestData(manifest), signature: Data("sig".utf8))
        try FileManager.default.removeItem(at: paths.vaultIndex)
        let resolved = try await store.resolve(repoPath: "/Users/test/code/triggr_api", selector: .generation(0))
        XCTAssertEqual(resolved.manifest.id, manifest.id)
    }
}

extension VaultStoreTests {
    func testSameNamedRepositoriesHaveIndependentStakes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config"))
        let store = try VaultStore(paths: paths)
        let runner = ProcessRunner()
        let resolver = RepositoryResolver(runner: runner)
        let firstURL = root.appendingPathComponent("first/triggr_api")
        let secondURL = root.appendingPathComponent("second/triggr_api")
        for url in [firstURL, secondURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            _ = try runner.checked("/usr/bin/git", ["init", url.path])
        }
        var first = fixture()
        first.repoPathHint = try resolver.resolve(firstURL.path)
        var second = fixture()
        second.repoPathHint = try resolver.resolve(secondURL.path)
        _ = try await store.commit(manifest: first, manifestData: await store.canonicalManifestData(first), signature: Data("sig".utf8))
        for selector in [ImageSelector.generation(0), .tag(first.tag), .id(first.id)] {
            do {
                _ = try await store.resolve(repoPath: second.repoPathHint, selector: selector)
                XCTFail("another same-named repository must not select this stake")
            } catch AgentError.notFound { }
        }
        let nextBeforeStake = try await store.nextGeneration(repoPath: second.repoPathHint)
        let headBeforeStake = try await store.latest(repoPath: second.repoPathHint)
        XCTAssertEqual(nextBeforeStake, 0)
        XCTAssertNil(headBeforeStake)
        _ = try await store.commit(manifest: second, manifestData: await store.canonicalManifestData(second), signature: Data("sig".utf8))
        for manifest in [first, second] {
            for selector in [ImageSelector.generation(0), .tag(manifest.tag), .id(manifest.id)] {
                let record = try await store.resolve(repoPath: manifest.repoPathHint, selector: selector)
                XCTAssertEqual(record.manifest.id, manifest.id)
            }
            let next = try await store.nextGeneration(repoPath: manifest.repoPathHint)
            let head = try await store.latest(repoPath: manifest.repoPathHint)
            XCTAssertEqual(next, 1)
            XCTAssertEqual(head?.manifest.id, manifest.id)
        }
        let moved = root.appendingPathComponent("moved/triggr_api")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: firstURL, to: moved)
        let movedPath = try resolver.resolve(moved.path)
        do {
            _ = try await store.resolve(repoPath: movedPath, selector: .id(first.id))
            XCTFail("a moved repository must not silently rebind a signed stake")
        } catch AgentError.notFound { }
    }

    func testRestoreRejectsSameNameAtDifferentPathBeforeSandboxAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config"))
        let store = try VaultStore(paths: paths)
        let manifest = fixture()
        let record = try await store.commit(manifest: manifest, manifestData: store.canonicalManifestData(manifest), signature: Data("sig".utf8))
        let service = try WorkspaceService(paths: paths, runner: BindingRunner())
        let vault = try VaultService(paths: paths, workspaceService: service, runner: BindingRunner())
        for selector in [ImageSelector.generation(0), .tag(manifest.tag), .id(manifest.id)] {
            do {
                _ = try await vault.restore(repoInput: "/Users/other/code/triggr_api", selector: selector, name: nil, cpus: nil, memory: nil, auditLevel: nil)
                XCTFail("restore must reject the wrong repository before authorization or decryption")
            } catch AgentError.notFound { }
        }
        do {
            _ = try await service.createFromStake(repoInput: "/Users/other/code/triggr_api", record: record, decryptedTemplate: root.appendingPathComponent("missing.tar"), name: nil, cpus: nil, memory: nil, auditLevel: nil)
            XCTFail("a same-named repository must not restore this stake")
        } catch AgentError.unsafe(let message) {
            XCTAssertTrue(message.contains("repository path"), message)
        }
    }
}

private struct BindingRunner: ProcessRunning {
    func capture(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> ProcessResult {
        guard executable == "/usr/bin/git", arguments == ["-C", "/Users/other/code/triggr_api", "rev-parse", "--show-toplevel"] else {
            throw AgentError.malformed("unexpected process access before repository binding")
        }
        return ProcessResult(status: 0, stdout: Data("/Users/other/code/triggr_api\n".utf8), stderr: Data())
    }
    func interactive(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> Int32 {
        throw AgentError.malformed("unexpected interactive process")
    }
}
