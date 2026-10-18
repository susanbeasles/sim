import Foundation

public struct ChangedPath: Sendable, Hashable {
    public enum Status: String, Sendable { case added = "A", modified = "M", deleted = "D" }
    public let status: Status
    public let path: String
}

public actor GitBridge {
    public let store: StateStore
    public let sbx: SBXClient
    public let runner: ProcessRunning
    public let audit: AuditLedger

    public init(paths: AgentPaths = AgentPaths(), runner: ProcessRunning = ProcessRunner()) throws {
        self.runner = runner
        self.store = try StateStore(paths: paths)
        self.sbx = SBXClient(runner: runner)
        self.audit = AuditLedger(file: paths.audit.appendingPathComponent("control.jsonl"))
    }

    public func prepareReview(_ workspace: WorkspaceRecord) async throws -> URL {
        let ws = store.paths.workspace(workspace.name)
        let export = ws.appendingPathComponent("export", isDirectory: true)
        let result = export.appendingPathComponent("result", isDirectory: true)
        let review = export.appendingPathComponent("review", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: export.path) { try fm.removeItem(at: export) }
        try fm.createDirectory(at: export, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? fm.removeItem(at: export) } }
        let budget = ReviewBudget()
        try budget.checkSpace(at: export)

        let baseline = ws.appendingPathComponent("baseline", isDirectory: true).appendingPathComponent(workspace.repoName, isDirectory: true)
        try budget.validate(tree: baseline)
        // No guest-controlled archive is ever copied to host disk or passed to tar.
        // Non-TTY exec preserves the binary stream; ProcessRunner caps it in transit.
        let script = "git ls-files -z -c -o --exclude-standard | tar --format=ustar --no-recursion --null --verbatim-files-from -T - -cf -"
        let archive = try sbx.exec(name: workspace.sandboxName, user: "agent", workdir: workspace.targetPath,
                                   command: ["bash", "-o", "pipefail", "-c", script])
        try ReviewArchive(budget: budget).extract(archive.stdout, to: result)
        try budget.checkSpace(at: export)
        try fm.createDirectory(at: review, withIntermediateDirectories: true)
        _ = try runner.checked("/usr/bin/rsync", ["-a", baseline.path + "/", review.path + "/"])
        _ = try reviewGit(review, ["init", "-q"])
        _ = try reviewGit(review, ["config", "user.name", "agent-review"])
        _ = try reviewGit(review, ["config", "user.email", "agent-review@invalid"])
        _ = try reviewGit(review, ["add", "-A"])
        _ = try reviewGit(review, ["commit", "-q", "--allow-empty", "-m", "BASELINE"])
        _ = try runner.checked("/usr/bin/rsync", ["-a", "--delete", result.path + "/", review.path + "/"])
        _ = try reviewGit(review, ["add", "-A"])

        let patch = try reviewGit(review, ["diff", "--cached", "--binary", "--no-ext-diff"])
        let patchURL = export.appendingPathComponent("candidate.patch")
        try patch.stdout.write(to: patchURL)
        _ = try await audit.append(workspace: workspace.name, kind: "review.export", detail: "patchSHA256=\(try Digest.sha256(file: patchURL))", payload: patch.stdout)
        complete = true
        return patchURL
    }

    public func diff(_ workspace: WorkspaceRecord, paths: [String] = []) async throws -> String {
        _ = try await prepareReview(workspace)
        let review = store.paths.workspace(workspace.name).appendingPathComponent("export/review")
        var args = ["diff", "--cached", "--binary", "--no-ext-diff"]
        if !paths.isEmpty { args += ["--"] + paths }
        return try reviewGit(review, args).stdoutString
    }

    public func changedPaths(_ workspace: WorkspaceRecord) async throws -> [ChangedPath] {
        let review = store.paths.workspace(workspace.name).appendingPathComponent("export/review")
        if !FileManager.default.fileExists(atPath: review.path) { _ = try await prepareReview(workspace) }
        let raw = try reviewGit(review, ["diff", "--cached", "--name-status", "-z", "--no-renames"]).stdout
        let fields = raw.split(separator: 0)
        var out: [ChangedPath] = []
        var i = 0
        while i + 1 < fields.count {
            let statusString = String(decoding: fields[i], as: UTF8.self)
            let path = String(decoding: fields[i + 1], as: UTF8.self)
            if let first = statusString.first, let status = ChangedPath.Status(rawValue: String(first)) {
                out.append(ChangedPath(status: status, path: path))
            }
            i += 2
        }
        return out
    }

    public func takeTheirs(_ workspace: WorkspaceRecord, selected: Set<String>? = nil, authorize: Bool = true) async throws {
        _ = try await prepareReview(workspace)
        let paths = try await changedPaths(workspace).filter { selected == nil || selected!.contains($0.path) }
        let exportRoot = store.paths.workspace(workspace.name).appendingPathComponent("export")
        let patchURL = exportRoot.appendingPathComponent("candidate.patch")
        let patchDigest = try Digest.sha256(file: patchURL)
        let headBefore = try currentHead(workspace.repoPath)
        if authorize {
            let config = try await store.loadConfiguration()
            let manifest = transactionManifest(operation: "git.merge.theirs", workspace: workspace, patchDigest: patchDigest, hostHead: headBefore, paths: paths.map(\.path))
            try AuthorizationGate(runner: runner, configuration: config).authorize(operation: "git merge --theirs", manifest: manifest)
            let headAfterAuthorization = try currentHead(workspace.repoPath)
            let patchAfterAuthorization = try Digest.sha256(file: patchURL)
            guard headBefore == headAfterAuthorization, patchDigest == patchAfterAuthorization else {
                throw AgentError.unsafe("transaction changed after authorization; nothing applied")
            }
        }

        let result = exportRoot.appendingPathComponent("result")
        for change in paths {
            let host = URL(fileURLWithPath: workspace.repoPath).appendingPathComponent(change.path)
            let theirs = result.appendingPathComponent(change.path)
            switch change.status {
            case .deleted:
                if FileManager.default.fileExists(atPath: host.path) || isSymlink(host) { try FileManager.default.removeItem(at: host) }
            case .added, .modified:
                try copyObject(theirs, to: host)
            }
        }
        _ = try await audit.append(workspace: workspace.name, kind: "host.import.theirs", detail: "paths=\(paths.count) patchSHA256=\(patchDigest)")
    }

    public func merge(_ workspace: WorkspaceRecord, selected: Set<String>? = nil, authorize: Bool = true) async throws -> [String] {
        _ = try await prepareReview(workspace)
        let all = try await changedPaths(workspace).filter { selected == nil || selected!.contains($0.path) }
        let exportRoot = store.paths.workspace(workspace.name).appendingPathComponent("export")
        let patchURL = exportRoot.appendingPathComponent("candidate.patch")
        let patchDigest = try Digest.sha256(file: patchURL)
        let headBefore = try currentHead(workspace.repoPath)
        if authorize {
            let config = try await store.loadConfiguration()
            let manifest = transactionManifest(operation: "git.merge", workspace: workspace, patchDigest: patchDigest, hostHead: headBefore, paths: all.map(\.path))
            try AuthorizationGate(runner: runner, configuration: config).authorize(operation: "git merge", manifest: manifest)
            let headAfterAuthorization = try currentHead(workspace.repoPath)
            let patchAfterAuthorization = try Digest.sha256(file: patchURL)
            guard headBefore == headAfterAuthorization, patchDigest == patchAfterAuthorization else {
                throw AgentError.unsafe("transaction changed after authorization; nothing applied")
            }
        }

        let baseline = store.paths.workspace(workspace.name).appendingPathComponent("baseline/\(workspace.repoName)")
        let result = exportRoot.appendingPathComponent("result")
        var conflicts: [String] = []
        for change in all {
            let base = baseline.appendingPathComponent(change.path)
            let theirs = result.appendingPathComponent(change.path)
            let ours = URL(fileURLWithPath: workspace.repoPath).appendingPathComponent(change.path)
            if objectsEqual(ours, base) {
                if change.status == .deleted {
                    if FileManager.default.fileExists(atPath: ours.path) || isSymlink(ours) { try FileManager.default.removeItem(at: ours) }
                } else { try copyObject(theirs, to: ours) }
                continue
            }
            if objectsEqual(theirs, base) || objectsEqual(ours, theirs) { continue }

            guard isRegularOrMissing(ours), isRegularOrMissing(base), isRegularOrMissing(theirs) else {
                conflicts.append(change.path)
                continue
            }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-merge-\(UUID().uuidString)")
            let empty = temp.appendingPathComponent("empty")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            try Data().write(to: empty)
            defer { try? FileManager.default.removeItem(at: temp) }
            let o = FileManager.default.fileExists(atPath: ours.path) ? ours.path : empty.path
            let b = FileManager.default.fileExists(atPath: base.path) ? base.path : empty.path
            let t = FileManager.default.fileExists(atPath: theirs.path) ? theirs.path : empty.path
            let r = try runner.capture("/usr/bin/git", ["merge-file", "-p", "--diff3", "-L", "OURS:\(change.path)", "-L", "BASE:\(change.path)", "-L", "AGENT:\(change.path)", o, b, t])
            if r.status <= 1 {
                try FileManager.default.createDirectory(at: ours.deletingLastPathComponent(), withIntermediateDirectories: true)
                try r.stdout.write(to: ours)
                if r.status == 1 { conflicts.append(change.path) }
            } else {
                conflicts.append(change.path)
            }
        }
        _ = try await audit.append(workspace: workspace.name, kind: "host.import.merge", detail: "paths=\(all.count) conflicts=\(conflicts.count) patchSHA256=\(patchDigest)")
        return conflicts
    }

    public func commit(_ workspace: WorkspaceRecord, message: String) async throws {
        let dirty = try runner.checked("/usr/bin/git", ["-C", workspace.repoPath, "status", "--porcelain"]).stdoutString
        guard dirty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.unsafe("agent git commit requires a clean host working tree; use agent git merge instead")
        }
        _ = try await prepareReview(workspace)
        let changes = try await changedPaths(workspace)
        try await takeTheirs(workspace, authorize: true)
        for c in changes {
            _ = try runner.checked("/usr/bin/git", ["-C", workspace.repoPath, "add", "-A", "--", c.path])
        }
        _ = try runner.checked("/usr/bin/git", ["-C", workspace.repoPath, "commit", "-m", message])
        _ = try await audit.append(workspace: workspace.name, kind: "host.git.commit", detail: message)
    }

    // Synthetic review repositories must not run host filters or hooks: these
    // can amplify even a bounded candidate. Host import/commit keeps its normal config.
    private func reviewGit(_ review: URL, _ arguments: [String]) throws -> ProcessResult {
        // Candidate files are copied only into the worktree. Keep controller
        // metadata in a sibling directory and never discover it through .git.
        let metadata = review.deletingLastPathComponent().appendingPathComponent("review.git")
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_ATTR_NOSYSTEM"] = "1"
        return try runner.checked("/usr/bin/git", ["-C", review.path, "--git-dir=" + metadata.path, "--work-tree=" + review.path, "-c", "core.hooksPath=/dev/null", "-c", "init.templateDir=", "-c", "core.attributesFile=/dev/null"] + arguments, environment: environment)
    }

    private func currentHead(_ repo: String) throws -> String {
        try runner.checked("/usr/bin/git", ["-C", repo, "rev-parse", "HEAD"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transactionManifest(operation: String, workspace: WorkspaceRecord, patchDigest: String, hostHead: String, paths: [String]) -> String {
        [
            "operation=\(operation)",
            "workspace=\(workspace.id.uuidString)",
            "sandbox=\(workspace.sandboxName)",
            "repo=\(workspace.repoPath)",
            "hostHead=\(hostHead)",
            "candidateSHA256=\(patchDigest)",
            "pathsSHA256=\(Digest.sha256(paths.sorted().joined(separator: "\\n")))",
            "nonce=\(UUID().uuidString)",
            "time=\(ISO8601DateFormatter().string(from: Date()))",
        ].joined(separator: "\n") + "\n"
    }

    private func copyObject(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) || isSymlink(dst) { try fm.removeItem(at: dst) }
        if isSymlink(src) {
            let target = try fm.destinationOfSymbolicLink(atPath: src.path)
            guard !target.hasPrefix("/"), !target.split(separator: "/").contains("..") else {
                throw AgentError.unsafe("refusing unsafe agent symlink: \(dst.path) -> \(target)")
            }
            try fm.createSymbolicLink(atPath: dst.path, withDestinationPath: target)
        } else {
            try fm.copyItem(at: src, to: dst)
        }
    }

    private func objectsEqual(_ a: URL, _ b: URL) -> Bool {
        if isSymlink(a) && isSymlink(b) {
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: a.path)) == (try? FileManager.default.destinationOfSymbolicLink(atPath: b.path))
        }
        guard FileManager.default.fileExists(atPath: a.path), FileManager.default.fileExists(atPath: b.path) else {
            return !FileManager.default.fileExists(atPath: a.path) && !FileManager.default.fileExists(atPath: b.path)
        }
        return (try? Data(contentsOf: a, options: [.mappedIfSafe])) == (try? Data(contentsOf: b, options: [.mappedIfSafe]))
    }

    private func isRegularOrMissing(_ url: URL) -> Bool {
        if !FileManager.default.fileExists(atPath: url.path) && !isSymlink(url) { return true }
        return !isSymlink(url)
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
