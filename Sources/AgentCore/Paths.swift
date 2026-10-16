import Foundation

public struct AgentPaths: Sendable {
    public let stateRoot: URL
    public let configRoot: URL

    public init(
        stateRoot: URL? = nil,
        configRoot: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        if let stateRoot {
            self.stateRoot = stateRoot
        } else if let override = environment["AGENT_STATE_ROOT"] {
            self.stateRoot = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        } else {
            self.stateRoot = URL(fileURLWithPath: "/usr/local/var/agent")
        }

        if let configRoot {
            self.configRoot = configRoot
        } else if let override = environment["AGENT_CONFIG_ROOT"] {
            self.configRoot = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        } else {
            self.configRoot = URL(fileURLWithPath: "/usr/local/etc/agent")
        }
    }

    public var workspaces: URL { stateRoot.appendingPathComponent("workspaces", isDirectory: true) }
    public var audit: URL { stateRoot.appendingPathComponent("audit", isDirectory: true) }
    public var vault: URL { stateRoot.appendingPathComponent("vault", isDirectory: true) }
    public var vaultObjects: URL { vault.appendingPathComponent("objects", isDirectory: true) }
    public var vaultManifests: URL { vault.appendingPathComponent("manifests", isDirectory: true) }
    public var vaultSignatures: URL { vault.appendingPathComponent("signatures", isDirectory: true) }
    public var vaultIndex: URL { vault.appendingPathComponent("index.json") }
    public var activeFile: URL { stateRoot.appendingPathComponent("active") }
    public var configFile: URL { configRoot.appendingPathComponent("config.json") }

    public func workspace(_ name: String) -> URL {
        workspaces.appendingPathComponent(name, isDirectory: true)
    }

    public func ensureBaseDirectories() throws {
        let fm = FileManager.default
        for url in [stateRoot, workspaces, audit, vault, vaultObjects, vaultManifests, vaultSignatures, configRoot] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
        }
    }
}
