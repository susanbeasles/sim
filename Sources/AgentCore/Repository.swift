import Foundation

public struct RepositoryResolver: Sendable {
    public let runner: ProcessRunning
    public let home: String

    public init(runner: ProcessRunning = ProcessRunner(), home: String = NSHomeDirectory()) {
        self.runner = runner
        self.home = home
    }

    public func resolve(_ input: String?, cwd: String = FileManager.default.currentDirectoryPath) throws -> String {
        let candidate: String
        if let input, !input.isEmpty {
            if input.hasPrefix("/") {
                candidate = input
            } else if input == "." || input.contains("/") {
                candidate = URL(fileURLWithPath: cwd).appendingPathComponent(input).standardizedFileURL.path
            } else {
                candidate = URL(fileURLWithPath: home).appendingPathComponent("code").appendingPathComponent(input).path
            }
        } else {
            candidate = cwd
        }
        let canonical = URL(fileURLWithPath: candidate).standardizedFileURL.path
        let result = try runner.checked("/usr/bin/git", ["-C", canonical, "rev-parse", "--show-toplevel"])
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func currentBranch(repo: String) throws -> String {
        let r = try runner.checked("/usr/bin/git", ["-C", repo, "branch", "--show-current"])
        let branch = r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.isEmpty {
            let head = try runner.checked("/usr/bin/git", ["-C", repo, "rev-parse", "HEAD"])
            return head.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return branch
    }

    public func head(repo: String) throws -> String {
        try runner.checked("/usr/bin/git", ["-C", repo, "rev-parse", "HEAD"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct SnapshotBuilder: Sendable {
    public let runner: ProcessRunning

    public init(runner: ProcessRunning = ProcessRunner()) { self.runner = runner }

    public func build(repo: String, branch: String, state: SourceState, destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])

        switch state {
        case .clean:
            let tar = destination.deletingLastPathComponent().appendingPathComponent(".baseline-\(UUID().uuidString).tar")
            defer { try? fm.removeItem(at: tar) }
            _ = try runner.checked("/usr/bin/git", ["-C", repo, "archive", "--format=tar", "-o", tar.path, branch])
            _ = try runner.checked("/usr/bin/tar", ["-xf", tar.path, "-C", destination.path])
        case .local:
            let list = try runner.checked("/usr/bin/git", ["-C", repo, "ls-files", "-z", "-c", "-o", "--exclude-standard"]).stdout
            for raw in list.split(separator: 0) {
                let rel = String(decoding: raw, as: UTF8.self)
                guard isSafeRelative(rel) else { throw AgentError.unsafe("unsafe repository path: \(rel)") }
                if isProtected(rel) { continue }
                let src = URL(fileURLWithPath: repo).appendingPathComponent(rel)
                let dst = destination.appendingPathComponent(rel)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let values = try src.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    let target = try fm.destinationOfSymbolicLink(atPath: src.path)
                    try fm.createSymbolicLink(atPath: dst.path, withDestinationPath: target)
                } else {
                    try fm.copyItem(at: src, to: dst)
                }
            }
        }
    }

    private func isSafeRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && path != ".git" && !path.hasPrefix(".git/") && !path.split(separator: "/").contains("..")
    }

    private func isProtected(_ path: String) -> Bool {
        let base = URL(fileURLWithPath: path).lastPathComponent
        if base == ".env" || base.hasPrefix(".env.") || base == ".npmrc" { return true }
        if path == ".ssh" || path.hasPrefix(".ssh/") || path.contains("/.ssh/") { return true }
        if path == ".aws" || path.hasPrefix(".aws/") || path.contains("/.aws/") { return true }
        if path == ".idea" || path.hasPrefix(".idea/") || path.contains("/.idea/") { return true }
        return ["pem", "key", "p12", "pfx"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}
