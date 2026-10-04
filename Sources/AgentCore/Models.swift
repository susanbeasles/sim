import Foundation

public enum Vendor: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public init(cliValue: String) throws {
        switch cliValue.lowercased() {
        case "claude", "cc": self = .claude
        case "codex", "gpt": self = .codex
        default: throw AgentError.invalidArgument("unknown vendor: \(cliValue)")
        }
    }

    public var executable: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    public var sbxAgent: String { executable }
}

public enum SourceState: String, Codable, CaseIterable, Sendable {
    case clean
    case local
}

public enum AuditLevel: String, Codable, CaseIterable, Sendable {
    case full
    case control
}

public struct WorkerRecord: Codable, Hashable, Sendable {
    public var name: String
    public var vendor: Vendor
    public var createdAt: Date
    public var primary: Bool

    public init(name: String, vendor: Vendor, createdAt: Date = Date(), primary: Bool = false) {
        self.name = name
        self.vendor = vendor
        self.createdAt = createdAt
        self.primary = primary
    }
}

public struct WorkspaceRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var sandboxName: String
    public var repoPath: String
    public var repoName: String
    public var vendor: Vendor
    public var branch: String
    public var sourceState: SourceState
    public var createdAt: Date
    public var sandboxHome: String
    public var targetPath: String
    public var baselineTemplate: String
    public var contextRepos: [String]
    public var workers: [WorkerRecord]
    public var auditLevel: AuditLevel
    public var cpus: Int?
    public var memory: String?
    public var originStakeID: UUID?
    public var originGeneration: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        sandboxName: String,
        repoPath: String,
        repoName: String,
        vendor: Vendor,
        branch: String,
        sourceState: SourceState,
        createdAt: Date = Date(),
        sandboxHome: String,
        targetPath: String,
        baselineTemplate: String,
        contextRepos: [String] = [],
        workers: [WorkerRecord] = [],
        auditLevel: AuditLevel = .full,
        cpus: Int? = nil,
        memory: String? = nil,
        originStakeID: UUID? = nil,
        originGeneration: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.sandboxName = sandboxName
        self.repoPath = repoPath
        self.repoName = repoName
        self.vendor = vendor
        self.branch = branch
        self.sourceState = sourceState
        self.createdAt = createdAt
        self.sandboxHome = sandboxHome
        self.targetPath = targetPath
        self.baselineTemplate = baselineTemplate
        self.contextRepos = contextRepos
        self.workers = workers
        self.auditLevel = auditLevel
        self.cpus = cpus
        self.memory = memory
        self.originStakeID = originStakeID
        self.originGeneration = originGeneration
    }
}

public struct AgentConfiguration: Codable, Sendable {
    public var authorizationKey: String?
    public var authorizationIdentity: String
    public var codeRoot: String
    public var pivCertificateSHA256: String?

    public init(
        authorizationKey: String? = nil,
        authorizationIdentity: String = "agent-control",
        codeRoot: String = "~/code",
        pivCertificateSHA256: String? = nil
    ) {
        self.authorizationKey = authorizationKey
        self.authorizationIdentity = authorizationIdentity
        self.codeRoot = codeRoot
        self.pivCertificateSHA256 = pivCertificateSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case authorizationKey
        case authorizationIdentity
        case codeRoot
        case pivCertificateSHA256
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authorizationKey = try c.decodeIfPresent(String.self, forKey: .authorizationKey)
        authorizationIdentity = try c.decodeIfPresent(String.self, forKey: .authorizationIdentity) ?? "agent-control"
        codeRoot = try c.decodeIfPresent(String.self, forKey: .codeRoot) ?? "~/code"
        pivCertificateSHA256 = try c.decodeIfPresent(String.self, forKey: .pivCertificateSHA256)
    }
}

public struct VaultArtifactDescriptor: Codable, Hashable, Sendable {
    public var objectKey: String
    public var ciphertextSHA256: String
    public var plaintextSHA256: String
    public var plaintextBytes: UInt64
    public var ciphertextBytes: UInt64
    public var format: String
    public var chunkBytes: Int

    public init(
        objectKey: String,
        ciphertextSHA256: String,
        plaintextSHA256: String,
        plaintextBytes: UInt64,
        ciphertextBytes: UInt64,
        format: String = "agent-vault-aes-gcm-chunks-v1",
        chunkBytes: Int
    ) {
        self.objectKey = objectKey
        self.ciphertextSHA256 = ciphertextSHA256
        self.plaintextSHA256 = plaintextSHA256
        self.plaintextBytes = plaintextBytes
        self.ciphertextBytes = ciphertextBytes
        self.format = format
        self.chunkBytes = chunkBytes
    }
}

public struct VaultKeyWrap: Codable, Hashable, Sendable {
    public var algorithm: String
    public var recipientCertificateSHA256: String
    public var wrappedKeyBase64: String

    public init(
        algorithm: String = "rsa-oaep-sha256",
        recipientCertificateSHA256: String,
        wrappedKeyBase64: String
    ) {
        self.algorithm = algorithm
        self.recipientCertificateSHA256 = recipientCertificateSHA256
        self.wrappedKeyBase64 = wrappedKeyBase64
    }
}

public struct StakeManifest: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var generation: Int
    public var tag: String
    public var createdAt: Date
    public var repoName: String
    public var repoPathHint: String
    public var branch: String
    public var vendor: Vendor
    public var sandboxName: String
    public var templateTag: String
    public var sbxVersion: String
    public var contextRepos: [String]
    public var auditLevel: AuditLevel
    public var parentStakeID: UUID?
    public var parentManifestSHA256: String?
    public var hostAuditHead: String?
    public var guestAuditHead: String?
    public var artifact: VaultArtifactDescriptor
    public var keyWrap: VaultKeyWrap

    public init(
        schemaVersion: Int = 1,
        id: UUID,
        generation: Int,
        tag: String,
        createdAt: Date = Date(),
        repoName: String,
        repoPathHint: String,
        branch: String,
        vendor: Vendor,
        sandboxName: String,
        templateTag: String,
        sbxVersion: String,
        contextRepos: [String] = [],
        auditLevel: AuditLevel = .full,
        parentStakeID: UUID?,
        parentManifestSHA256: String?,
        hostAuditHead: String?,
        guestAuditHead: String?,
        artifact: VaultArtifactDescriptor,
        keyWrap: VaultKeyWrap
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.generation = generation
        self.tag = tag
        self.createdAt = createdAt
        self.repoName = repoName
        self.repoPathHint = repoPathHint
        self.branch = branch
        self.vendor = vendor
        self.sandboxName = sandboxName
        self.templateTag = templateTag
        self.sbxVersion = sbxVersion
        self.contextRepos = contextRepos
        self.auditLevel = auditLevel
        self.parentStakeID = parentStakeID
        self.parentManifestSHA256 = parentManifestSHA256
        self.hostAuditHead = hostAuditHead
        self.guestAuditHead = guestAuditHead
        self.artifact = artifact
        self.keyWrap = keyWrap
    }
}

public struct StakeRecord: Codable, Hashable, Sendable {
    public var manifest: StakeManifest
    public var manifestSHA256: String
    public var signatureFile: String
    public var manifestFile: String
    public var createdAt: Date

    public init(
        manifest: StakeManifest,
        manifestSHA256: String,
        signatureFile: String,
        manifestFile: String,
        createdAt: Date = Date()
    ) {
        self.manifest = manifest
        self.manifestSHA256 = manifestSHA256
        self.signatureFile = signatureFile
        self.manifestFile = manifestFile
        self.createdAt = createdAt
    }
}

public enum ImageSelector: Hashable, Sendable {
    case generation(Int)
    case tag(String)
    case id(UUID)

    public init(_ raw: String) throws {
        if let n = Int(raw), n >= 0 {
            self = .generation(n)
        } else if let id = UUID(uuidString: raw) {
            self = .id(id)
        } else if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .tag(raw)
        } else {
            throw AgentError.invalidArgument("image selector cannot be empty")
        }
    }
}

public enum AgentError: Error, CustomStringConvertible, Sendable {
    case invalidArgument(String)
    case notFound(String)
    case unsafe(String)
    case unsupported(String)
    case processFailed(command: String, code: Int32, stderr: String)
    case malformed(String)
    case authorizationRequired(String)
    case trustFailure(String)

    public var description: String {
        switch self {
        case .invalidArgument(let s): return s
        case .notFound(let s): return s
        case .unsafe(let s): return s
        case .unsupported(let s): return s
        case .processFailed(let command, let code, let stderr):
            return "command failed (\(code)): \(command)\n\(stderr)"
        case .malformed(let s): return s
        case .authorizationRequired(let s): return s
        case .trustFailure(let s): return s
        }
    }
}
