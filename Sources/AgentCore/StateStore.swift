import Foundation

public actor StateStore {
    nonisolated public let paths: AgentPaths
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(paths: AgentPaths = AgentPaths()) throws {
        self.paths = paths
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try paths.ensureBaseDirectories()
    }

    public func save(_ workspace: WorkspaceRecord) throws {
        let dir = paths.workspace(workspace.name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
        let data = try encoder.encode(workspace)
        try atomicWrite(data, to: dir.appendingPathComponent("workspace.json"), mode: 0o600)
    }

    public func load(_ name: String) throws -> WorkspaceRecord {
        let url = paths.workspace(name).appendingPathComponent("workspace.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentError.notFound("unknown workspace: \(name)")
        }
        return try decoder.decode(WorkspaceRecord.self, from: Data(contentsOf: url))
    }

    public func list() throws -> [WorkspaceRecord] {
        guard FileManager.default.fileExists(atPath: paths.workspaces.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.workspaces.path)
        return try names.compactMap { name in
            let url = paths.workspace(name).appendingPathComponent("workspace.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try decoder.decode(WorkspaceRecord.self, from: Data(contentsOf: url))
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func remove(_ name: String) throws {
        let dir = paths.workspace(name)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        if (try? active()) == name {
            try? FileManager.default.removeItem(at: paths.activeFile)
        }
    }

    public func setActive(_ name: String) throws {
        _ = try load(name)
        try atomicWrite(Data((name + "\n").utf8), to: paths.activeFile, mode: 0o600)
    }

    public func active() throws -> String? {
        guard FileManager.default.fileExists(atPath: paths.activeFile.path) else { return nil }
        return try String(contentsOf: paths.activeFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func loadConfiguration() throws -> AgentConfiguration {
        guard FileManager.default.fileExists(atPath: paths.configFile.path) else { return AgentConfiguration() }
        return try decoder.decode(AgentConfiguration.self, from: Data(contentsOf: paths.configFile))
    }

    public func saveConfiguration(_ config: AgentConfiguration) throws {
        try FileManager.default.createDirectory(at: paths.configRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
        try atomicWrite(try encoder.encode(config), to: paths.configFile, mode: 0o600)
    }

    private func atomicWrite(_ data: Data, to url: URL, mode: Int) throws {
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
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
