import Foundation

/// Admission checks for an already provisioned bounded export filesystem.
/// This does not provision volumes or claim to limit SBX's internal storage.
struct TemplateExportBudget: Sendable {
    static let maximumBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let minimumFreeBytes: Int64 = 1024 * 1024 * 1024
    var attributes: @Sendable (URL) throws -> [FileAttributeKey: Any] = {
        try FileManager.default.attributesOfFileSystem(forPath: $0.path)
    }

    func checkDestination(_ directory: URL, stateRoot: URL) throws {
        let destination = try attributes(directory)
        let system = try attributes(URL(fileURLWithPath: "/"))
        let state = try attributes(stateRoot)
        guard let capacity = destination[.systemSize] as? NSNumber,
              let free = destination[.systemFreeSize] as? NSNumber,
              let device = destination[.systemNumber] as? NSNumber,
              let systemDevice = system[.systemNumber] as? NSNumber,
              let stateDevice = state[.systemNumber] as? NSNumber,
              capacity.int64Value > 0, capacity.int64Value <= Self.maximumBytes,
              free.int64Value >= Self.minimumFreeBytes, free.int64Value <= capacity.int64Value,
              device != systemDevice, device != stateDevice else {
            throw AgentError.unsafe("stake requires a dedicated temporary filesystem with an enforced capacity of at most 8 GiB, separate from system and state storage, and at least 1 GiB available; export refused")
        }
    }

    func checkArchive(_ archive: URL) throws {
        let values = try archive.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes > 0, Int64(bytes) <= Self.maximumBytes else {
            throw AgentError.unsafe("export is not a bounded regular archive")
        }
    }
}
