import Foundation

public actor VaultService {
    public nonisolated let workspaceService: WorkspaceService
    public nonisolated let vaultStore: VaultStore
    public nonisolated let crypto: HardwareVaultCrypto
    public nonisolated let audit: AuditLedger
    public nonisolated let runner: ProcessRunning

    public init(
        paths: AgentPaths = AgentPaths(),
        workspaceService: WorkspaceService,
        runner: ProcessRunning = ProcessRunner(),
        crypto: HardwareVaultCrypto = HardwareVaultCrypto()
    ) throws {
        self.workspaceService = workspaceService
        self.vaultStore = try VaultStore(paths: paths)
        self.crypto = crypto
        self.audit = AuditLedger(file: paths.audit.appendingPathComponent("control.jsonl"))
        self.runner = runner
    }

    public func stake(workspace: WorkspaceRecord, tag: String) async throws -> StakeRecord {
        let cleanTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTag.isEmpty else { throw AgentError.invalidArgument("stake tag cannot be empty") }
        let configuration = try await workspaceService.store.loadConfiguration()
        guard let piv = configuration.pivCertificateSHA256, !piv.isEmpty else {
            throw AgentError.authorizationRequired("PIV vault certificate is not configured; run 'agent key identities' then 'agent config piv-cert SHA256'")
        }
        let auth = AuthorizationGate(runner: runner, configuration: configuration)
        _ = try auth.configuredFingerprint()

        let generation = try await vaultStore.nextGeneration(repoName: workspace.repoName)
        let parent = try await vaultStore.latest(repoName: workspace.repoName)
        if let parent {
            try await verifyLineage(record: parent, auth: auth)
            guard generation == parent.manifest.generation + 1 else {
                throw AgentError.trustFailure("next generation does not extend the verified lineage head")
            }
        } else if generation != 0 {
            throw AgentError.trustFailure("vault has no lineage head but next generation is not zero")
        }
        let stakeID = UUID()
        let shortID = stakeID.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let templateTag = "agent-stake/\(sanitizeOCI(workspace.repoName)):g\(generation)-\(shortID)"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-stake-\(stakeID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        let plainTar = temp.appendingPathComponent("template.tar")
        let encryptedPart = temp.appendingPathComponent("template.agtvault")

        let wasRunning = try workspaceService.sbx.isRunning(name: workspace.sandboxName)
        let guestHead = try? workspaceService.sbx.exec(
            name: workspace.sandboxName,
            user: "root",
            command: ["sh", "-lc", "cat /var/lib/agent-audit/HEAD 2>/dev/null || true"]
        ).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        try workspaceService.sbx.stop(name: workspace.sandboxName)
        defer {
            if wasRunning { try? workspaceService.sbx.start(name: workspace.sandboxName) }
        }

        _ = try await audit.append(
            workspace: workspace.name,
            kind: "stake.begin",
            detail: "id=\(stakeID.uuidString) generation=\(generation) tag=\(cleanTag)"
        )

        // Save may create a plaintext template even if export or preflight fails.
        // Clean it up before the earlier defer resumes the original sandbox.
        var removedTemplate = false
        defer {
            if !removedTemplate { try? workspaceService.sbx.removeTemplate(templateTag) }
        }
        try workspaceService.sbx.save(name: workspace.sandboxName, tag: templateTag, output: plainTar.path)
        try workspaceService.sbx.removeTemplate(templateTag)
        removedTemplate = true
        let scannedDigest = try TemplateArchive().preflight(plainTar)
        let cryptoResult = try crypto.encrypt(
            plaintext: plainTar,
            ciphertext: encryptedPart,
            recipientCertificateSHA256: piv
        )
        guard cryptoResult.plaintextSHA256 == scannedDigest else {
            throw AgentError.trustFailure("encrypted template does not match the inspected export")
        }

        let objectURL = await vaultStore.objectURL(forDigest: cryptoResult.ciphertextSHA256)
        var wroteObject = false
        var committedObject = false
        defer {
            if wroteObject && !committedObject {
                try? FileManager.default.removeItem(at: objectURL)
            }
        }
        if FileManager.default.fileExists(atPath: objectURL.path) {
            let existing = try Digest.sha256(file: objectURL)
            guard existing == cryptoResult.ciphertextSHA256 else {
                throw AgentError.trustFailure("existing vault object path has the wrong digest")
            }
        } else {
            try FileManager.default.moveItem(at: encryptedPart, to: objectURL)
            wroteObject = true
            #if canImport(Darwin)
            _ = chmod(objectURL.path, mode_t(0o600))
            #elseif canImport(Glibc)
            _ = Glibc.chmod(objectURL.path, mode_t(0o600))
            #endif
        }

        let hostHead = try await audit.verify()?.digest
        let artifact = VaultArtifactDescriptor(
            objectKey: "objects/\(objectURL.lastPathComponent)",
            ciphertextSHA256: cryptoResult.ciphertextSHA256,
            plaintextSHA256: cryptoResult.plaintextSHA256,
            plaintextBytes: cryptoResult.plaintextBytes,
            ciphertextBytes: cryptoResult.ciphertextBytes,
            chunkBytes: cryptoResult.chunkBytes
        )
        let manifest = StakeManifest(
            id: stakeID,
            generation: generation,
            tag: cleanTag,
            repoName: workspace.repoName,
            repoPathHint: workspace.repoPath,
            branch: workspace.branch,
            vendor: workspace.vendor,
            sandboxName: workspace.sandboxName,
            templateTag: templateTag,
            sbxVersion: try workspaceService.sbx.version(),
            contextRepos: workspace.contextRepos,
            auditLevel: workspace.auditLevel,
            parentStakeID: parent?.manifest.id,
            parentManifestSHA256: parent?.manifestSHA256,
            hostAuditHead: hostHead,
            guestAuditHead: guestHead.flatMap { $0.isEmpty ? nil : $0 },
            artifact: artifact,
            keyWrap: cryptoResult.wrappedKey
        )
        let manifestData = try await vaultStore.canonicalManifestData(manifest)
        let manifestString = String(decoding: manifestData, as: UTF8.self)
        let signature = try auth.sign(operation: "stake \(workspace.repoName) generation \(generation)", manifest: manifestString)
        let record = try await vaultStore.commit(manifest: manifest, manifestData: manifestData, signature: signature)
        committedObject = true
        _ = try await audit.append(
            workspace: workspace.name,
            kind: "stake.commit",
            detail: "id=\(stakeID.uuidString) generation=\(generation) manifestSHA256=\(record.manifestSHA256) objectSHA256=\(artifact.ciphertextSHA256)"
        )
        return record
    }

    public func restore(
        repoInput: String?,
        selector: ImageSelector,
        name: String?,
        cpus: Int?,
        memory: String?,
        auditLevel: AuditLevel?,
        makeActive: Bool = true
    ) async throws -> WorkspaceRecord {
        let repo = try workspaceService.resolver.resolve(repoInput)
        let repoName = URL(fileURLWithPath: repo).lastPathComponent
        let record = try await vaultStore.resolve(repoName: repoName, selector: selector)
        let config = try await workspaceService.store.loadConfiguration()
        let auth = AuthorizationGate(runner: runner, configuration: config)
        try await verifyLineage(record: record, auth: auth)

        let objectURL = await vaultStore.objectURL(for: record.manifest)
        guard FileManager.default.fileExists(atPath: objectURL.path) else {
            throw AgentError.notFound("vault object is not in the local cache: \(objectURL.path); remote R2/GCP retrieval is the next transport layer, not silently emulated")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        let plainTar = temp.appendingPathComponent("template.tar")
        try crypto.decrypt(
            ciphertext: objectURL,
            plaintext: plainTar,
            keyWrap: record.manifest.keyWrap,
            expectedCiphertextSHA256: record.manifest.artifact.ciphertextSHA256,
            expectedPlaintextSHA256: record.manifest.artifact.plaintextSHA256
        )
        let workspace = try await workspaceService.createFromStake(
            repoInput: repo,
            record: record,
            decryptedTemplate: plainTar,
            name: name,
            cpus: cpus,
            memory: memory,
            auditLevel: auditLevel,
            makeActive: makeActive
        )
        _ = try await audit.append(
            workspace: workspace.name,
            kind: "stake.restore",
            detail: "stake=\(record.manifest.id.uuidString) generation=\(record.manifest.generation) objectSHA256=\(record.manifest.artifact.ciphertextSHA256)"
        )
        return workspace
    }

    public func verify(record: StakeRecord, deep: Bool = false) async throws {
        let config = try await workspaceService.store.loadConfiguration()
        let auth = AuthorizationGate(runner: runner, configuration: config)
        try await verifyLineage(record: record, auth: auth)
        let objectURL = await vaultStore.objectURL(for: record.manifest)
        guard FileManager.default.fileExists(atPath: objectURL.path) else { throw AgentError.notFound("vault object missing: \(objectURL.path)") }
        let objectDigest = try Digest.sha256(file: objectURL)
        guard objectDigest == record.manifest.artifact.ciphertextSHA256 else { throw AgentError.trustFailure("vault object digest mismatch") }
        if deep {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-vault-verify-\(UUID().uuidString).tar")
            defer { try? FileManager.default.removeItem(at: temp) }
            try crypto.decrypt(
                ciphertext: objectURL,
                plaintext: temp,
                keyWrap: record.manifest.keyWrap,
                expectedCiphertextSHA256: record.manifest.artifact.ciphertextSHA256,
                expectedPlaintextSHA256: record.manifest.artifact.plaintextSHA256
            )
        }
    }

    public func records(repoName: String? = nil) async throws -> [StakeRecord] {
        try await vaultStore.list(repoName: repoName)
    }

    private func verifyLineage(record: StakeRecord, auth: AuthorizationGate) async throws {
        var current = record
        var seen = Set<UUID>()
        while true {
            guard seen.insert(current.manifest.id).inserted else {
                throw AgentError.trustFailure("stake lineage contains a cycle at \(current.manifest.id)")
            }
            let manifestData = try await vaultStore.manifestBytes(for: current)
            let signature = try await vaultStore.signatureBytes(for: current)
            try auth.verify(manifest: String(decoding: manifestData, as: UTF8.self), signature: signature)

            if current.manifest.generation == 0 {
                guard current.manifest.parentStakeID == nil, current.manifest.parentManifestSHA256 == nil else {
                    throw AgentError.trustFailure("generation zero must be a parentless genesis stake")
                }
                return
            }

            guard let parentID = current.manifest.parentStakeID,
                  let expectedParentDigest = current.manifest.parentManifestSHA256 else {
                throw AgentError.trustFailure("generation \(current.manifest.generation) is missing its signed parent link")
            }
            let parent = try await vaultStore.record(id: parentID)
            guard parent.manifest.repoName == current.manifest.repoName else {
                throw AgentError.trustFailure("stake lineage crosses repositories")
            }
            guard parent.manifest.generation + 1 == current.manifest.generation else {
                throw AgentError.trustFailure("stake lineage generation is not contiguous")
            }
            guard parent.manifestSHA256 == expectedParentDigest else {
                throw AgentError.trustFailure("stake parent manifest digest does not match the signed child link")
            }
            current = parent
        }
    }

    private func sanitizeOCI(_ raw: String) -> String {
        let lowered = raw.lowercased().map { c -> Character in
            if c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." { return c }
            return "-"
        }
        return String(lowered).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
