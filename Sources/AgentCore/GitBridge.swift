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
        // info/attributes has precedence over every candidate .gitattributes.
        // Bind the patch to raw imported bytes, never clean/encoding/EOL output.
        let info = export.appendingPathComponent("review.git/info", isDirectory: true)
        try fm.createDirectory(at: info, withIntermediateDirectories: true)
        try Data("* -text -ident -filter -working-tree-encoding\n".utf8)
            .write(to: info.appendingPathComponent("attributes"))
        _ = try reviewGit(review, ["config", "user.name", "agent-review"])
        _ = try reviewGit(review, ["config", "user.email", "agent-review@invalid"])
        _ = try reviewGit(review, ["add", "-A"])
        _ = try reviewGit(review, ["commit", "-q", "--allow-empty", "-m", "BASELINE"])
        _ = try runner.checked("/usr/bin/rsync", ["-a", "--delete", result.path + "/", review.path + "/"])
        _ = try reviewGit(review, ["add", "-A"])

        let patch = try reviewGit(review, ["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv"])
        let patchURL = export.appendingPathComponent("candidate.patch")
        try patch.stdout.write(to: patchURL)
        _ = try await audit.append(workspace: workspace.name, kind: "review.export", detail: "patchSHA256=\(try Digest.sha256(file: patchURL))", payload: patch.stdout)
        complete = true
        return patchURL
    }

    public func diff(_ workspace: WorkspaceRecord, paths: [String] = []) async throws -> String {
        _ = try await prepareReview(workspace)
        let review = store.paths.workspace(workspace.name).appendingPathComponent("export/review")
        var args = ["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv"]
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
        let prepared = try await prepareImport(workspace, selected: selected)
        try await takeTheirsPrepared(workspace, prepared: prepared, authorize: authorize)
    }

    private struct PreparedImport {
        let paths: [ChangedPath]
        let imports: [ReviewImport]
        let patchURL: URL
        let digest: String
        let head: String
    }

    private func prepareImport(_ workspace: WorkspaceRecord, selected: Set<String>? = nil) async throws -> PreparedImport {
        _ = try await prepareReview(workspace)
        let paths = try await changedPaths(workspace).filter { selected == nil || selected!.contains($0.path) }
        let exportRoot = store.paths.workspace(workspace.name).appendingPathComponent("export")
        let patchURL = exportRoot.appendingPathComponent("candidate.patch")
        let digest = try Digest.sha256(file: patchURL)
        let imports = try captureImports(review: exportRoot.appendingPathComponent("review"), changes: paths, patchDigest: digest)
        return PreparedImport(paths: paths, imports: imports, patchURL: patchURL, digest: digest, head: try currentHead(workspace.repoPath))
    }

    private func takeTheirsPrepared(_ workspace: WorkspaceRecord, prepared: PreparedImport, authorize: Bool) async throws {
        let paths = prepared.paths, imports = prepared.imports
        let patchURL = prepared.patchURL, patchDigest = prepared.digest, headBefore = prepared.head
        let host = try ScopedTree(URL(fileURLWithPath: workspace.repoPath))
        if authorize {
            let config = try await store.loadConfiguration()
            let manifest = transactionManifest(operation: "git.merge.theirs", workspace: workspace, patchDigest: patchDigest, importBinding: ReviewImport.binding(imports), hostHead: headBefore, paths: paths.map(\.path))
            showSelection(paths)
            try AuthorizationGate(runner: runner, configuration: config).authorize(operation: "git merge --theirs", manifest: manifest)
            let headAfterAuthorization = try currentHead(workspace.repoPath)
            let patchAfterAuthorization = try Digest.sha256(file: patchURL)
            guard headBefore == headAfterAuthorization, patchDigest == patchAfterAuthorization else {
                throw AgentError.unsafe("transaction changed after authorization; nothing applied")
            }
        }

        for item in imports {
            if let candidate = item.candidate { try host.write(candidate, at: item.change.path) }
            else { try host.remove(item.change.path) }
        }
        _ = try await audit.append(workspace: workspace.name, kind: "host.import.theirs", detail: "paths=\(paths.count) patchSHA256=\(patchDigest)")
    }

    public func merge(_ workspace: WorkspaceRecord, selected: Set<String>? = nil, authorize: Bool = true) async throws -> [String] {
        _ = try await prepareReview(workspace)
        let all = try await changedPaths(workspace).filter { selected == nil || selected!.contains($0.path) }
        let exportRoot = store.paths.workspace(workspace.name).appendingPathComponent("export")
        let patchURL = exportRoot.appendingPathComponent("candidate.patch")
        let patchDigest = try Digest.sha256(file: patchURL)
        let imports = try captureImports(review: exportRoot.appendingPathComponent("review"), changes: all, patchDigest: patchDigest)
        let host = try ScopedTree(URL(fileURLWithPath: workspace.repoPath))
        let headBefore = try currentHead(workspace.repoPath)
        if authorize {
            let config = try await store.loadConfiguration()
            let manifest = transactionManifest(operation: "git.merge", workspace: workspace, patchDigest: patchDigest, importBinding: ReviewImport.binding(imports), hostHead: headBefore, paths: all.map(\.path))
            showSelection(all)
            try AuthorizationGate(runner: runner, configuration: config).authorize(operation: "git merge", manifest: manifest)
            let headAfterAuthorization = try currentHead(workspace.repoPath)
            let patchAfterAuthorization = try Digest.sha256(file: patchURL)
            guard headBefore == headAfterAuthorization, patchDigest == patchAfterAuthorization else {
                throw AgentError.unsafe("transaction changed after authorization; nothing applied")
            }
        }

        var conflicts: [String] = []
        for item in imports {
            let change = item.change
            let base = item.baseline, theirs = item.candidate
            let ours = try host.read(change.path)
            if ours == base {
                if let theirs { try host.write(theirs, at: change.path) }
                else { try host.remove(change.path) }
                continue
            }
            if theirs == base || ours == theirs { continue }

            // An unresolved deletion is a delete/modify conflict, including
            // mode-only changes. Missing files are not empty merge inputs.
            if base != nil && (ours == nil || theirs == nil) {
                conflicts.append(change.path)
                continue
            }

            // merge-file sees private byte snapshots, never paths through the host
            // worktree or mutable export/result. Destination writes remain anchored.
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agent-merge-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temp) }
            let o = temp.appendingPathComponent("ours"), b = temp.appendingPathComponent("base"), t = temp.appendingPathComponent("theirs")
            try (ours?.bytes ?? Data()).write(to: o)
            try (base?.bytes ?? Data()).write(to: b)
            try (theirs?.bytes ?? Data()).write(to: t)
            let r = try runner.capture("/usr/bin/git", ["merge-file", "-p", "--diff3", "-L", "OURS:\(change.path)", "-L", "BASE:\(change.path)", "-L", "AGENT:\(change.path)", o.path, b.path, t.path])
            if r.status >= 0 && r.status <= 1 {
                let mode = (ours?.mode == base?.mode ? theirs?.mode : ours?.mode) ?? ours?.mode ?? 0o644
                try host.write(ReviewFile(bytes: r.stdout, mode: mode), at: change.path)
                if r.status == 1 { conflicts.append(change.path) }
            } else {
                conflicts.append(change.path)
            }
        }
        _ = try await audit.append(workspace: workspace.name, kind: "host.import.merge", detail: "paths=\(all.count) conflicts=\(conflicts.count) patchSHA256=\(patchDigest)")
        return conflicts
    }

    public func commit(_ workspace: WorkspaceRecord, message: String) async throws {
        let dirty = try hostGit(workspace.repoPath, ["status", "--porcelain"]).stdoutString
        guard dirty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.unsafe("agent git commit requires a clean host working tree; use agent git merge instead")
        }
        let prepared = try await prepareImport(workspace)
        let changes = prepared.paths
        guard !changes.contains(where: { $0.path.split(separator: "/").last?.lowercased() == ".gitattributes" }) else {
            throw AgentError.unsafe("protected commit refuses candidate Git conversion rules")
        }
        let attributes = try hostGit(workspace.repoPath, ["check-attr", "--all", "-z", "--"] + changes.map(\.path)).stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard attributes.count % 3 == 0 else { throw AgentError.unsafe("malformed Git attribute response") }
        for i in stride(from: 0, to: attributes.count, by: 3) {
            if ["filter", "working-tree-encoding", "ident", "text", "eol", "crlf"].contains(attributes[i + 1]),
               !["unset", "unspecified"].contains(attributes[i + 2]) {
                throw AgentError.unsafe("protected commit refuses working-tree conversion attributes")
            }
        }
        try await takeTheirsPrepared(workspace, prepared: prepared, authorize: true)
        for c in changes {
            _ = try hostGit(workspace.repoPath, ["add", "-A", "--", c.path])
        }
        let stagedPaths = try hostGit(workspace.repoPath, ["diff", "--cached", "--name-only", "-z", "--no-renames", "--no-ext-diff", "--no-textconv"]).stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard Set(stagedPaths) == Set(changes.map(\.path)) else {
            throw AgentError.unsafe("staged paths differ from the authorized candidate")
        }
        for item in prepared.imports {
            try verifyStagedObject(repo: workspace.repoPath, path: item.change.path, data: item.candidate?.bytes, mode: item.candidate?.mode ?? 0o644)
        }
        guard try currentHead(workspace.repoPath) == prepared.head else {
            throw AgentError.unsafe("host parent changed before protected commit")
        }
        try commit(repo: workspace.repoPath, message: message)
        _ = try await audit.append(workspace: workspace.name, kind: "host.git.commit", detail: message)
    }

    func verifyStagedObject(repo: String, path: String, data: Data?, mode: Int32 = 0o644) throws {
        let staged = try hostGit(repo, ["ls-files", "--stage", "-z", "--", path]).stdout
        guard let data else {
            guard staged.isEmpty, try ScopedTree(URL(fileURLWithPath: repo)).read(path) == nil else {
                throw AgentError.unsafe("deleted authorized path remains in the index or host")
            }
            return
        }
        let entries = staged.split(separator: 0)
        guard entries.count == 1,
              let tab = entries[0].firstIndex(of: 9) else {
            throw AgentError.unsafe("authorized candidate has no unique staged object")
        }
        guard String(decoding: entries[0][entries[0].index(after: tab)...], as: UTF8.self) == path else {
            throw AgentError.unsafe("staged path differs from authorization")
        }
        let fields = String(decoding: entries[0][..<tab], as: UTF8.self).split(separator: " ").map(String.init)
        guard fields.count == 3, fields[0] == (mode & 0o111 == 0 ? "100644" : "100755"), fields[2] == "0" else {
            throw AgentError.unsafe("staged candidate mode or merge stage differs from authorization")
        }
        let blob = try hostGit(repo, ["cat-file", "blob", fields[1]]).stdout
        guard blob == data, try ScopedTree(URL(fileURLWithPath: repo)).read(path) == ReviewFile(bytes: data, mode: mode) else {
            throw AgentError.unsafe("staged or host raw bytes differ from the authorized candidate")
        }
    }

    func commit(repo: String, message: String) throws {
        // Imported hooks are candidate code, not controller-authorized automation.
        // Override discovery for this invocation, including post-commit hooks.
        _ = try hostGit(repo, ["commit", "-m", message])
    }

    func hostGit(_ repo: String, _ arguments: [String]) throws -> ProcessResult {
        // Keep normal signing configuration. Authorization never permits filter
        // commands, including filters activated by imported .gitattributes.
        let options = ["--literal-pathspecs", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-C", repo]
        let names = try runner.checked("/usr/bin/git", options + ["config", "--null", "--list", "--includes", "--name-only"]).stdoutString
        guard !names.split(separator: "\0").contains(where: { $0.lowercased().hasPrefix("filter.") }) else {
            throw AgentError.unsafe("host import refuses repositories with configured Git filters")
        }
        return try runner.checked("/usr/bin/git", options + arguments)
    }

    func captureImports(review: URL, changes: [ChangedPath], patchDigest: String) throws -> [ReviewImport] {
        func checkPatch() throws {
            let current = try reviewGit(review, ["diff", "--cached", "--binary", "--no-ext-diff", "--no-textconv"]).stdout
            guard Digest.sha256(current) == patchDigest else {
                throw AgentError.unsafe("review index changed before authorization")
            }
        }
        var candidateBytes = 0, baselineBytes = 0
        func read(_ path: String, baseline: Bool) throws -> ReviewFile {
            _ = try ReviewBudget().components(path)
            let args = baseline ? ["ls-tree", "-z", "HEAD", "--", path] : ["ls-files", "--stage", "-z", "--", path]
            let entry = try reviewGit(review, args).stdout
            let entries = entry.split(separator: 0)
            let mode = String(decoding: entry.prefix(6), as: UTF8.self)
            guard entries.count == 1, (mode == "100644" || mode == "100755"),
                  entry.suffix(path.utf8.count + 2) == Data(("\t" + path + "\0").utf8) else {
                throw AgentError.unsafe("review index contains an unsupported or ambiguous file")
            }
            let bytes = try reviewGit(review, ["show", "--no-textconv", (baseline ? "HEAD:" : ":") + path]).stdout
            if baseline { try ReviewBudget().charge(bytes.count, total: &baselineBytes) }
            else { try ReviewBudget().charge(bytes.count, total: &candidateBytes) }
            return ReviewFile(bytes: bytes, mode: mode == "100755" ? 0o755 : 0o644)
        }
        try checkPatch()
        let captured = try changes.map { change in
            let candidate: ReviewFile?
            let baseline: ReviewFile?
            if change.status == .deleted { candidate = nil }
            else { candidate = try read(change.path, baseline: false) }
            if change.status == .added { baseline = nil }
            else { baseline = try read(change.path, baseline: true) }
            return ReviewImport(change: change, candidate: candidate, baseline: baseline)
        }
        try checkPatch()
        return captured
    }

    // Synthetic review repositories must not run host filters or hooks: these
    // can amplify even a bounded candidate. Host commit preserves signing settings.
    private func reviewGit(_ review: URL, _ arguments: [String]) throws -> ProcessResult {
        // Candidate files are copied only into the worktree. Keep controller
        // metadata in a sibling directory and never discover it through .git.
        let metadata = review.deletingLastPathComponent().appendingPathComponent("review.git")
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_ATTR_NOSYSTEM"] = "1"
        return try runner.checked("/usr/bin/git", ["--literal-pathspecs", "-C", review.path, "--git-dir=" + metadata.path, "--work-tree=" + review.path, "-c", "core.hooksPath=/dev/null", "-c", "init.templateDir=", "-c", "core.attributesFile=/dev/null"] + arguments, environment: environment)
    }

    private func currentHead(_ repo: String) throws -> String {
        try hostGit(repo, ["rev-parse", "HEAD"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showSelection(_ changes: [ChangedPath]) {
        let paths = changes.map(\.path).sorted()
        print("Resolved paths (\(paths.count)):")
        for path in paths { print("  \(path.debugDescription)") }
        print("pathsSHA256=\(Digest.sha256(paths.joined(separator: "\\n")))")
    }

    private func transactionManifest(operation: String, workspace: WorkspaceRecord, patchDigest: String, importBinding: String, hostHead: String, paths: [String]) -> String {
        [
            "operation=\(operation)",
            "workspace=\(workspace.id.uuidString)",
            "sandbox=\(workspace.sandboxName)",
            "repo=\(workspace.repoPath)",
            "hostHead=\(hostHead)",
            "candidateSHA256=\(patchDigest)",
            "rawImportSHA256=\(importBinding)",
            "pathsSHA256=\(Digest.sha256(paths.sorted().joined(separator: "\\n")))",
            "nonce=\(UUID().uuidString)",
            "time=\(ISO8601DateFormatter().string(from: Date()))",
        ].joined(separator: "\n") + "\n"
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
