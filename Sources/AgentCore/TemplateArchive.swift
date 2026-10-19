import Foundation

/// Inspects exported image bytes on the host. No guest code is executed and no
/// archive paths are extracted into the host filesystem.
struct TemplateArchive {
    private struct Entry {
        let name: String
        let type: String
        let size: Int64
        let linked: Bool
    }

    private struct Image: Decodable {
        let Config: String
        let Layers: [String]
    }

    private let forbidden = [
        ".aws/credentials", ".config/gcloud/application_default_credentials.json",
        ".config/rclone/rclone.conf", ".netrc", ".npmrc", ".codex/auth.json",
        ".claude/.credentials.json"
    ]

    /// Returns the digest to bind the checked export to the encryption input.
    @discardableResult
    func preflight(_ archive: URL) throws -> String {
        let digest = try Digest.sha256(file: archive)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        let outer = try entries(archive, temp: temp)
        guard outer.values.allSatisfy({ ($0.type == "file" || $0.type == "dir") && !$0.linked }) else { throw unsafe() }
        var layers = Set<String>()
        if outer["manifest.json"] != nil {
            let images = try JSONDecoder().decode([Image].self, from: read("manifest.json", in: archive, entries: outer, temp: temp))
            guard !images.isEmpty else { throw unsafe() }
            for image in images {
                guard outer[image.Config]?.type == "file", !image.Layers.isEmpty else { throw unsafe() }
                layers.formUnion(image.Layers)
            }
        }
        if outer["index.json"] != nil {
            var visited = Set<String>()
            func visit(_ data: Data, depth: Int) throws {
                guard depth < 16, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw unsafe() }
                // Indexes and image manifests are disjoint shapes. Selecting one
                // branch from a mixed object would leave the other uninspected.
                guard !(object.keys.contains("manifests") && object.keys.contains("layers")) else { throw unsafe() }
                if let manifests = object["manifests"] as? [[String: Any]], !manifests.isEmpty {
                    for descriptor in manifests {
                        guard let hash = descriptor["digest"] as? String else { throw unsafe() }
                        let path = try blob(hash)
                        if visited.insert(path).inserted {
                            let file = try copy(path, in: archive, entries: outer, temp: temp)
                            guard try Digest.sha256(file: file) == String(hash.dropFirst(7)) else { throw unsafe() }
                            try visit(try metadata(file), depth: depth + 1)
                        }
                    }
                } else if let descriptors = object["layers"] as? [[String: Any]], !descriptors.isEmpty {
                    for descriptor in descriptors {
                        guard let hash = descriptor["digest"] as? String,
                              let media = descriptor["mediaType"] as? String,
                              ["application/vnd.oci.image.layer.v1.tar", "application/vnd.oci.image.layer.v1.tar+gzip",
                               "application/vnd.oci.image.layer.v1.tar+zstd", "application/vnd.docker.image.rootfs.diff.tar",
                               "application/vnd.docker.image.rootfs.diff.tar.gzip"].contains(media) else { throw unsafe() }
                        layers.insert(try blob(hash))
                    }
                } else { throw unsafe() }
            }
            try visit(read("index.json", in: archive, entries: outer, temp: temp), depth: 0)
        }
        guard !layers.isEmpty, layers.count <= 512 else { throw unsafe() }
        var homes = Set<String>()
        var exports: [(URL, [String: Entry])] = []
        for path in layers.sorted() {
            let file = try copy(path, in: archive, entries: outer, temp: temp)
            if path.hasPrefix("blobs/sha256/") {
                guard try Digest.sha256(file: file) == String(path.dropFirst(13)) else { throw unsafe() }
            }
            let contents = try entries(file, temp: temp)
            if contents["etc/passwd"] != nil {
                let data = try read("etc/passwd", in: file, entries: contents, temp: temp)
                guard let passwd = String(data: data, encoding: .utf8) else { throw unsafe() }
                for line in passwd.split(separator: "\n") {
                    let fields = line.split(separator: ":", omittingEmptySubsequences: false)
                    if fields.first == "agent" {
                        guard fields.count == 7, fields[5].hasPrefix("/"), fields[5] != "/" else { throw unsafe() }
                        let home = try normalized(String(fields[5].dropFirst()))
                        guard !home.isEmpty else { throw unsafe() }
                        homes.insert(home)
                    }
                }
            }
            exports.append((file, contents))
        }
        guard !homes.isEmpty else { throw unsafe() }
        for (_, contents) in exports {
            for home in homes {
                let paths = forbidden.map { home + "/" + $0 }
                let directories = paths + [home + "/.ssh", "etc/passwd"]
                for (path, entry) in contents {
                    // Never follow links, including any ancestor of a guarded path.
                    if directories.contains(where: { $0 == path || $0.hasPrefix(path + "/") }),
                       (entry.type != "dir" || entry.linked), !paths.contains(path), path != "etc/passwd" {
                        throw unsafe()
                    }
                    if path == "etc/passwd", entry.type != "file" || entry.linked { throw unsafe() }
                    let ssh = home + "/.ssh/"
                    let key = path.hasPrefix(ssh) ? String(path.dropFirst(ssh.count)) : ""
                    let guarded = paths.contains(path) || (!key.contains("/") && key.hasPrefix("id_") && !key.hasSuffix(".pub"))
                    if guarded, entry.type != "file" || entry.linked || entry.size > 0 {
                        throw AgentError.unsafe("refusing to stake an export containing credential-looking files or links")
                    }
                }
            }
        }
        guard try Digest.sha256(file: archive) == digest else { throw unsafe() }
        return digest
    }

    private func blob(_ digest: String) throws -> String {
        guard digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw unsafe() }
        return "blobs/sha256/" + digest.dropFirst(7)
    }

    private func unsafe() -> AgentError {
        .unsafe("could not safely inspect the exported template; stake refused")
    }

    private func normalized(_ raw: String) throws -> String {
        var path = raw
        while path.hasPrefix("./") { path.removeFirst(2) }
        if path.hasSuffix("/") { path.removeLast() }
        if path == "." || (path.isEmpty && raw == "./") { return "" }
        guard !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw unsafe() }
        return path
    }

    private func entries(_ archive: URL, temp: URL) throws -> [String: Entry] {
        let listing = try tar(["-tf", archive.path], temp: temp)
        let names = try String(decoding: metadata(listing, limit: 64 * 1024 * 1024), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        var originals: [String: String] = [:]
        let verbose = try tar(["-tvf", archive.path], temp: temp)
        let types = String(decoding: try metadata(verbose, limit: 64 * 1024 * 1024), as: UTF8.self).split(separator: "\n")
        guard types.count == names.count else { throw unsafe() }
        var links = Set<String>()
        for (index, name) in names.enumerated() {
            let path = try normalized(name)
            guard originals.updateValue(name, forKey: path) == nil else { throw unsafe() }
            if types[index].first == "h" || types[index].first == "l" { links.insert(path) }
        }
        // Tar stores the first hard-link name as a regular file. Mark both ends
        // so a guarded path cannot evade the no-follow rule by appearing first.
        for line in types where line.first == "h" {
            guard let range = line.range(of: " link to ", options: .backwards) else { throw unsafe() }
            let target = try normalized(String(line[range.upperBound...]))
            guard originals[target] != nil else { throw unsafe() }
            links.insert(target)
        }
        let index = try tar(["-cf", "-", "--format", "mtree", "--options", "!all,type,size,link", "@" + archive.path], temp: temp)
        let lines = String(decoding: try metadata(index, limit: 64 * 1024 * 1024), as: UTF8.self).split(separator: "\n")
        guard lines.first == "#mtree" else { throw unsafe() }
        var result: [String: Entry] = [:]
        for line in lines.dropFirst() {
            let fields = line.split(separator: " ")
            guard fields.count >= 2 else { throw unsafe() }
            // libarchive mtree uses octal escapes for whitespace and special bytes.
            let raw = Array(fields[0].utf8)
            var decoded: [UInt8] = []
            var cursor = 0
            while cursor < raw.count {
                if raw[cursor] == 92 {
                    guard cursor + 3 < raw.count,
                          let byte = UInt8(String(decoding: raw[(cursor + 1)...(cursor + 3)], as: UTF8.self), radix: 8) else { throw unsafe() }
                    decoded.append(byte)
                    cursor += 4
                } else { decoded.append(raw[cursor]); cursor += 1 }
            }
            guard let name = String(bytes: decoded, encoding: .utf8) else { throw unsafe() }
            // libarchive spells the root entry '/.' in mtree output.
            let path = try normalized(name == "/." ? "." : name)
            guard let original = originals[path], result[path] == nil else { throw unsafe() }
            let attributes = fields.dropFirst().map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
            guard attributes.allSatisfy({ $0.count == 2 }) else { throw unsafe() }
            let types = attributes.filter { $0[0] == "type" }
            guard types.count == 1 else { throw unsafe() }
            let type = types[0][1]
            let sizes = attributes.filter { $0[0] == "size" }
            let parsedSize = sizes.first.flatMap { Int64($0[1]) }
            guard type != "file" || (sizes.count == 1 && parsedSize != nil && parsedSize! >= 0) else { throw unsafe() }
            let size = parsedSize ?? 0
            result[path] = Entry(name: original, type: type, size: size, linked: links.contains(path))
        }
        guard result.count == originals.count else { throw unsafe() }
        return result
    }

    private func read(_ path: String, in archive: URL, entries: [String: Entry], temp: URL) throws -> Data {
        guard let entry = entries[path], entry.size <= 1024 * 1024 else { throw unsafe() }
        return try metadata(copy(path, in: archive, entries: entries, temp: temp))
    }

    private func copy(_ path: String, in archive: URL, entries: [String: Entry], temp: URL) throws -> URL {
        guard let entry = entries[path], entry.type == "file", !entry.linked,
              !entry.name.contains(where: { "*?[]\\".contains($0) }) else { throw unsafe() }
        return try tar(["-xOf", archive.path, "--", entry.name], temp: temp)
    }

    private func metadata(_ file: URL, limit: Int = 1024 * 1024) throws -> Data {
        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard bytes <= limit else { throw unsafe() }
        return try Data(contentsOf: file)
    }

    private func tar(_ arguments: [String], temp: URL) throws -> URL {
        let output = temp.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw unsafe() }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        #if os(macOS)
        let tarPath = "/usr/bin/tar"
        #else
        // GNU tar does not implement mtree or @archive. Never silently use it.
        let tarPath = "/usr/bin/bsdtar"
        #endif
        guard FileManager.default.isExecutableFile(atPath: tarPath) else {
            throw AgentError.unsafe("template inspection requires the host libarchive bsdtar executable at \(tarPath)")
        }
        process.executableURL = URL(fileURLWithPath: tarPath)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        // Host tar configuration must not alter the archive interpretation.
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw unsafe() }
        return output
    }
}
