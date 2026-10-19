import Foundation
import ProcessSupport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct ReviewFile: Equatable, Sendable {
    let bytes: Data
    let mode: Int32

    var binding: String { "\(mode):\(Digest.sha256(bytes))" }
}

/// All relative host operations walk from one open repository directory.
/// Never follow destination ancestors or open a writable existing leaf inode.
final class ScopedTree {
    private let descriptor: Int32

    init(_ root: URL) throws {
        let fd = sim_tree_root(root.path)
        guard fd >= 0 else { throw AgentError.unsafe("cannot anchor import directory: errno \(-fd)") }
        descriptor = fd
    }

    deinit { close(descriptor) }

    func read(_ path: String) throws -> ReviewFile? {
        _ = try ReviewBudget().components(path)
        var mode: Int32 = 0
        let fd = sim_tree_read(descriptor, path, &mode)
        if fd == -ENOENT { return nil }
        guard fd >= 0 else { throw AgentError.unsafe("unsafe import source \(path.debugDescription): errno \(-fd)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var bytes = Data()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            guard chunk.count <= ReviewBudget().fileBytes - bytes.count else {
                throw AgentError.unsafe("host merge file exceeds review byte limit")
            }
            bytes.append(chunk)
        }
        return ReviewFile(bytes: bytes, mode: mode)
    }

    func write(_ file: ReviewFile, at path: String) throws {
        _ = try ReviewBudget().components(path)
        let temporary = ".sim-import-" + UUID().uuidString
        let error = file.bytes.withUnsafeBytes { buffer in
            sim_tree_write(descriptor, path, temporary, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, file.mode)
        }
        guard error == 0 else { throw AgentError.unsafe("unsafe import destination \(path.debugDescription): errno \(error)") }
    }

    func remove(_ path: String) throws {
        _ = try ReviewBudget().components(path)
        let error = sim_tree_remove(descriptor, path)
        guard error == 0 else { throw AgentError.unsafe("unsafe import deletion \(path.debugDescription): errno \(error)") }
    }
}

struct ReviewImport: Sendable {
    let change: ChangedPath
    let candidate: ReviewFile?
    let baseline: ReviewFile?

    static func binding(_ imports: [ReviewImport]) -> String {
        let records = imports.map { item in
            [Data(item.change.path.utf8).base64EncodedString(), item.change.status.rawValue,
             item.candidate?.binding ?? "missing", item.baseline?.binding ?? "missing"].joined(separator: ":")
        }.sorted()
        return Digest.sha256(records.joined(separator: "\n"))
    }
}
