import Foundation

/// Local vault metadata store.
///
/// `index.json` is deliberately treated as a cache, never as authority. Image
/// discovery is rebuilt from the immutable-per-stake manifest/signature files so
/// deleting or editing an index entry cannot silently redirect generation/tag
/// resolution. Cryptographic authority still comes from AuthorizationGate
/// verifying the manifest signature before restore.
public actor VaultStore {
    public nonisolated let paths: AgentPaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: AgentPaths = AgentPaths()) throws {
        self.paths = paths
        try paths.ensureBaseDirectories()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func canonicalManifestData(_ manifest: StakeManifest) throws -> Data {
        try encoder.encode(manifest)
    }

    public func nextGeneration(repoPath: String) throws -> Int {
        let records = try loadRecords().filter { $0.manifest.repoPathHint == repoPath }
        return (records.map { $0.manifest.generation }.max() ?? -1) + 1
    }

    public func latest(repoPath: String) throws -> StakeRecord? {
        try loadRecords()
            .filter { $0.manifest.repoPathHint == repoPath }
            .max { lhs, rhs in lhs.manifest.generation < rhs.manifest.generation }
    }

    public func resolve(repoPath: String, selector: ImageSelector) throws -> StakeRecord {
        let records = try loadRecords().filter { $0.manifest.repoPathHint == repoPath }
        let match: StakeRecord?
        switch selector {
        case .generation(let generation):
            let matches = records.filter { $0.manifest.generation == generation }
            guard matches.count <= 1 else { throw AgentError.trustFailure("multiple manifests claim generation \(generation) for \(repoPath)") }
            match = matches.first
        case .tag(let tag):
            let matches = records.filter { $0.manifest.tag == tag }
            guard matches.count <= 1 else { throw AgentError.trustFailure("multiple signed-image records claim immutable tag '\(tag)' for \(repoPath)") }
            match = matches.first
        case .id(let id):
            let matches = records.filter { $0.manifest.id == id }
            guard matches.count <= 1 else { throw AgentError.trustFailure("multiple manifests claim stake id \(id.uuidString)") }
            match = matches.first
        }
        guard let match else { throw AgentError.notFound("no staked image for \(repoPath) matching \(selectorDescription(selector))") }
        return match
    }

    public func record(id: UUID) throws -> StakeRecord {
        let matches = try loadRecords().filter { $0.manifest.id == id }
        guard matches.count <= 1 else { throw AgentError.trustFailure("multiple manifests claim stake id \(id.uuidString)") }
        guard let record = matches.first else { throw AgentError.notFound("stake manifest not found: \(id.uuidString)") }
        return record
    }

    public func list(repoName: String? = nil) throws -> [StakeRecord] {
        try loadRecords()
            .filter { repoName == nil || $0.manifest.repoName == repoName }
            .sorted {
                if $0.manifest.repoName != $1.manifest.repoName { return $0.manifest.repoName < $1.manifest.repoName }
                return $0.manifest.generation < $1.manifest.generation
            }
    }

    public func commit(manifest: StakeManifest, manifestData: Data, signature: Data) throws -> StakeRecord {
        let existing = try loadRecords()
        guard !existing.contains(where: { $0.manifest.id == manifest.id }) else {
            throw AgentError.unsafe("stake ID already exists: \(manifest.id)")
        }
        guard !existing.contains(where: { $0.manifest.repoPathHint == manifest.repoPathHint && $0.manifest.generation == manifest.generation }) else {
            throw AgentError.unsafe("generation \(manifest.generation) already exists for \(manifest.repoName)")
        }
        guard !existing.contains(where: { $0.manifest.repoPathHint == manifest.repoPathHint && $0.manifest.tag == manifest.tag }) else {
            throw AgentError.unsafe("stake tag '\(manifest.tag)' already exists for \(manifest.repoName); tags are immutable names")
        }

        let id = manifest.id.uuidString.lowercased()
        let manifestName = "\(id).json"
        let signatureName = "\(id).sig"
        let manifestURL = paths.vaultManifests.appendingPathComponent(manifestName)
        let signatureURL = paths.vaultSignatures.appendingPathComponent(signatureName)
        guard !FileManager.default.fileExists(atPath: manifestURL.path), !FileManager.default.fileExists(atPath: signatureURL.path) else {
            throw AgentError.unsafe("stake ID already exists on disk: \(manifest.id)")
        }

        let digest = Digest.sha256(manifestData)
        let record = StakeRecord(
            manifest: manifest,
            manifestSHA256: digest,
            signatureFile: signatureName,
            manifestFile: manifestName,
            createdAt: manifest.createdAt
        )

        try atomicWrite(manifestData, to: manifestURL, mode: 0o600)
        do {
            try atomicWrite(signature, to: signatureURL, mode: 0o600)
            try writeIndex(existing + [record])
            return record
        } catch {
            try? FileManager.default.removeItem(at: manifestURL)
            try? FileManager.default.removeItem(at: signatureURL)
            throw error
        }
    }

    public func manifestBytes(for record: StakeRecord) throws -> Data {
        let url = paths.vaultManifests.appendingPathComponent(record.manifestFile)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AgentError.notFound("manifest missing: \(record.manifestFile)") }
        let data = try Data(contentsOf: url)
        guard Digest.sha256(data) == record.manifestSHA256 else {
            throw AgentError.trustFailure("manifest changed after resolution for stake \(record.manifest.id)")
        }
        return data
    }

    public func signatureBytes(for record: StakeRecord) throws -> Data {
        let url = paths.vaultSignatures.appendingPathComponent(record.signatureFile)
        guard FileManager.default.fileExists(atPath: url.path) else { throw AgentError.notFound("signature missing: \(record.signatureFile)") }
        return try Data(contentsOf: url)
    }

    public func objectURL(for manifest: StakeManifest) -> URL {
        paths.vault.appendingPathComponent(manifest.artifact.objectKey)
    }

    public func objectURL(forDigest digest: String) -> URL {
        paths.vaultObjects.appendingPathComponent("sha256-\(digest).agtvault")
    }

    private func loadRecords() throws -> [StakeRecord] {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(
            at: paths.vaultManifests,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var records: [StakeRecord] = []
        records.reserveCapacity(urls.count)
        for url in urls {
            let data = try Data(contentsOf: url)
            let manifest: StakeManifest
            do {
                manifest = try decoder.decode(StakeManifest.self, from: data)
            } catch {
                throw AgentError.trustFailure("could not decode stake manifest \(url.lastPathComponent): \(error)")
            }
            let expectedName = "\(manifest.id.uuidString.lowercased()).json"
            guard url.lastPathComponent == expectedName else {
                throw AgentError.trustFailure("manifest filename does not match its signed stake id: \(url.lastPathComponent)")
            }
            let signatureName = "\(manifest.id.uuidString.lowercased()).sig"
            let signatureURL = paths.vaultSignatures.appendingPathComponent(signatureName)
            guard fm.fileExists(atPath: signatureURL.path) else {
                throw AgentError.trustFailure("stake manifest has no matching signature: \(url.lastPathComponent)")
            }
            records.append(StakeRecord(
                manifest: manifest,
                manifestSHA256: Digest.sha256(data),
                signatureFile: signatureName,
                manifestFile: url.lastPathComponent,
                createdAt: manifest.createdAt
            ))
        }

        try validateUniqueness(records)
        try validateIndexCache(records)
        return records
    }

    private func validateUniqueness(_ records: [StakeRecord]) throws {
        var ids = Set<UUID>()
        var generations = Set<String>()
        var tags = Set<String>()
        for record in records {
            guard ids.insert(record.manifest.id).inserted else {
                throw AgentError.trustFailure("duplicate stake id in manifest store: \(record.manifest.id)")
            }
            let generationKey = "\(record.manifest.repoPathHint)\u{0}\(record.manifest.generation)"
            guard generations.insert(generationKey).inserted else {
                throw AgentError.trustFailure("duplicate generation \(record.manifest.generation) for \(record.manifest.repoName)")
            }
            let tagKey = "\(record.manifest.repoPathHint)\u{0}\(record.manifest.tag)"
            guard tags.insert(tagKey).inserted else {
                throw AgentError.trustFailure("duplicate immutable tag '\(record.manifest.tag)' for \(record.manifest.repoName)")
            }
        }
    }

    /// The index accelerates human inspection only. Missing entries are allowed;
    /// any entry that is present must agree with the manifest-derived record.
    private func validateIndexCache(_ authoritative: [StakeRecord]) throws {
        guard FileManager.default.fileExists(atPath: paths.vaultIndex.path) else { return }
        let cached: [StakeRecord]
        do {
            cached = try decoder.decode([StakeRecord].self, from: Data(contentsOf: paths.vaultIndex))
        } catch {
            throw AgentError.trustFailure("vault index cache is malformed: \(error)")
        }
        let byID = Dictionary(uniqueKeysWithValues: authoritative.map { ($0.manifest.id, $0) })
        for entry in cached {
            guard let actual = byID[entry.manifest.id] else {
                throw AgentError.trustFailure("vault index references a stake manifest that does not exist: \(entry.manifest.id)")
            }
            guard entry.manifestSHA256 == actual.manifestSHA256,
                  entry.manifest.repoName == actual.manifest.repoName,
                  entry.manifest.repoPathHint == actual.manifest.repoPathHint,
                  entry.manifest.generation == actual.manifest.generation,
                  entry.manifest.tag == actual.manifest.tag,
                  entry.manifestFile == actual.manifestFile,
                  entry.signatureFile == actual.signatureFile else {
                throw AgentError.trustFailure("vault index disagrees with manifest-derived record for stake \(entry.manifest.id)")
            }
        }
    }

    private func writeIndex(_ records: [StakeRecord]) throws {
        let sorted = records.sorted {
            if $0.manifest.repoName != $1.manifest.repoName { return $0.manifest.repoName < $1.manifest.repoName }
            return $0.manifest.generation < $1.manifest.generation
        }
        try atomicWrite(try encoder.encode(sorted), to: paths.vaultIndex, mode: 0o600)
    }

    private func atomicWrite(_ data: Data, to url: URL, mode: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        #if canImport(Darwin)
        _ = chmod(tmp.path, mode_t(mode))
        #elseif canImport(Glibc)
        _ = Glibc.chmod(tmp.path, mode_t(mode))
        #endif
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    private func selectorDescription(_ selector: ImageSelector) -> String {
        switch selector {
        case .generation(let n): return "generation \(n)"
        case .tag(let tag): return "tag '\(tag)'"
        case .id(let id): return "stake \(id.uuidString)"
        }
    }
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
