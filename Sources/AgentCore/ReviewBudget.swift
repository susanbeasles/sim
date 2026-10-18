import Foundation

/// Host-owned limits. Guest metadata never selects or relaxes these values.
struct ReviewBudget: Sendable {
    var totalBytes = 32 * 1024 * 1024
    var fileBytes = 16 * 1024 * 1024
    var files = 10_000
    var depth = 32
    var freeBytes: Int64 = 1024 * 1024 * 1024
    static let archiveBytes = 64 * 1024 * 1024

    func checkSpace(at root: URL) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: root.path)
        guard let free = attributes[.systemFreeSize] as? NSNumber,
              free.int64Value >= freeBytes + Int64(totalBytes) * 12 else {
            throw AgentError.unsafe("review requires more free disk space")
        }
    }

    func validate(tree root: URL) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var failure: Error?
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
            failure = error
            return false
        }) else { throw AgentError.unsafe("cannot inspect review baseline") }
        var total = 0
        var count = 0
        for case let item as URL in items {
            count += 1
            guard count <= files else { throw AgentError.unsafe("review file count limit exceeded") }
            let relative = String(item.path.dropFirst(root.path.count + 1))
            _ = try components(relative)
            let values = try item.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw AgentError.unsafe("review does not accept links") }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize else {
                throw AgentError.unsafe("review does not accept special files")
            }
            try charge(size, total: &total)
        }
        if let failure { throw failure }
    }

    func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= depth, path.utf8.count <= 1024,
              parts.allSatisfy({ safe($0) }) else {
            throw AgentError.unsafe("unsafe or excessive review path")
        }
        return parts
    }

    private func safe(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != "..",
              !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        // Reserve metadata aliases as well as the literal name, including names
        // interpreted specially on case-insensitive or HFS/NTFS filesystems.
        var name = component.lowercased()
        while name.hasSuffix(".") || name.hasSuffix(" ") { name.removeLast() }
        return name != ".git"
    }

    func charge(_ size: Int, total: inout Int) throws {
        guard size >= 0, size <= fileBytes, size <= totalBytes - total else {
            throw AgentError.unsafe("review byte limit exceeded")
        }
        total += size
    }
}

