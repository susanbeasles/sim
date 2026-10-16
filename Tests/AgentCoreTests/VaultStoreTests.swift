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

        let next = try await store.nextGeneration(repoName: "triggr_api")
        let byGeneration = try await store.resolve(repoName: "triggr_api", selector: .generation(0))
        let byTag = try await store.resolve(repoName: "triggr_api", selector: .tag("root baseline"))
        let byID = try await store.resolve(repoName: "triggr_api", selector: .id(manifest.id))
        XCTAssertEqual(next, 1)
        XCTAssertEqual(byGeneration.manifest.id, manifest.id)
        XCTAssertEqual(byTag.manifest.id, manifest.id)
        XCTAssertEqual(byID.manifest.id, manifest.id)

        let manifestURL = paths.vaultManifests.appendingPathComponent(record.manifestFile)
        var bytes = try Data(contentsOf: manifestURL)
        bytes.append(0x20)
        try bytes.write(to: manifestURL)
        do {
            _ = try await store.resolve(repoName: "triggr_api", selector: .generation(0))
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
        let resolved = try await store.resolve(repoName: "triggr_api", selector: .generation(0))
        XCTAssertEqual(resolved.manifest.id, manifest.id)
    }
}
