import Foundation
import Darwin

/// A deliberately restricted, uncompressed USTAR reader. Unsupported extensions,
/// links and sparse encodings fail closed rather than invoking a general extractor.
struct ReviewArchive {
    private struct Entry {
        let path: String
        let body: Range<Int>
        let directory: Bool
        let executable: Bool
    }
    let budget: ReviewBudget

    func extract(_ data: Data, to root: URL) throws {
        let entries = try inspect(data)
        let fm = FileManager.default
        guard Darwin.mkdir(root.path, 0o700) == 0 else {
            throw AgentError.unsafe("review extraction requires a new private directory")
        }
        var complete = false
        defer { if !complete { try? fm.removeItem(at: root) } }
        let start = ContinuousClock.now
        for entry in entries {
            guard start.duration(to: .now) < .seconds(120) else { throw AgentError.unsafe("review extraction time limit exceeded") }
            try budget.checkSpace(at: root)
            let target = root.appendingPathComponent(entry.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if entry.directory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } else {
                try data.subdata(in: entry.body).write(to: target, options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: entry.executable ? 0o755 : 0o644], ofItemAtPath: target.path)
            }
        }
        complete = true
    }

    private func inspect(_ data: Data) throws -> [Entry] {
        guard data.count <= ReviewBudget.archiveBytes else { throw AgentError.unsafe("review archive byte limit exceeded") }
        var entries: [Entry] = []
        var paths: [String: (spelling: [UInt8], directory: Bool)] = [:]
        var headers = 0
        var total = 0
        var offset = 0
        while offset <= data.count - 512 {
            let header = data.subdata(in: offset..<(offset + 512))
            if header.allSatisfy({ $0 == 0 }) {
                guard data.count - offset >= 1024, data[offset...].allSatisfy({ $0 == 0 }) else {
                    throw AgentError.unsafe("invalid review archive trailer")
                }
                return entries
            }
            headers += 1
            guard headers <= budget.files, (try text(header, 257, 6)) == "ustar" else {
                throw AgentError.unsafe("unsupported or excessive review archive")
            }
            let checksum = header.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) }
            guard try number(header, 148, 8) == checksum else { throw AgentError.unsafe("invalid review archive checksum") }
            let prefix = try text(header, 345, 155)
            var path = (prefix.isEmpty ? "" : prefix + "/") + (try text(header, 0, 100))
            let type = header[156]
            let directory = type == 53
            guard type == 0 || type == 48 || directory else { throw AgentError.unsafe("review does not accept links, sparse or special files") }
            if directory && path.hasSuffix("/") { path.removeLast() }
            let parts = try budget.components(path)
            let size = try number(header, 124, 12)
            guard !directory || size == 0 else { throw AgentError.unsafe("invalid review directory size") }
            try budget.charge(size, total: &total)
            let body = offset + 512
            guard size <= data.count - body else { throw AgentError.unsafe("truncated review archive") }
            for i in parts.indices {
                let spelling = parts[...i].joined(separator: "/")
                let name = spelling.precomposedStringWithCanonicalMapping.lowercased()
                let isDirectory = i < parts.count - 1 || directory
                if let existing = paths[name] {
                    guard existing.directory && isDirectory && existing.spelling == Array(spelling.utf8) else { throw AgentError.unsafe("colliding review paths") }
                } else {
                    paths[name] = (Array(spelling.utf8), isDirectory)
                    guard paths.count <= budget.files else { throw AgentError.unsafe("review file count limit exceeded") }
                }
            }
            entries.append(Entry(path: path, body: body..<(body + size), directory: directory, executable: try number(header, 100, 8) & 0o111 != 0))
            offset = body + ((size + 511) / 512) * 512
        }
        throw AgentError.unsafe("truncated review archive")
    }

    private func text(_ header: Data, _ start: Int, _ count: Int) throws -> String {
        guard let text = String(bytes: header[start..<(start + count)].prefix(while: { $0 != 0 }), encoding: .utf8) else {
            throw AgentError.unsafe("review archive requires UTF-8 paths")
        }
        return text
    }

    private func number(_ header: Data, _ start: Int, _ count: Int) throws -> Int {
        let raw = header[start..<(start + count)]
        guard raw.allSatisfy({ $0 == 0 || $0 == 32 || (48...55).contains($0) }) else {
            throw AgentError.unsafe("unsupported review archive number")
        }
        let digits = String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, let value = Int(digits, radix: 8) else { throw AgentError.unsafe("invalid review archive number") }
        return value
    }
}
