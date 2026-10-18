import Foundation

public actor WorkspaceService {
    nonisolated public let store: StateStore
    nonisolated public let sbx: SBXClient
    nonisolated public let resolver: RepositoryResolver
    nonisolated public let snapshotter: SnapshotBuilder
    nonisolated public let runner: ProcessRunning
    nonisolated public let audit: AuditLedger

    public init(
        paths: AgentPaths = AgentPaths(),
        runner: ProcessRunning = ProcessRunner()
    ) throws {
        self.runner = runner
        self.store = try StateStore(paths: paths)
        self.sbx = SBXClient(runner: runner)
        self.resolver = RepositoryResolver(runner: runner)
        self.snapshotter = SnapshotBuilder(runner: runner)
        self.audit = AuditLedger(file: paths.audit.appendingPathComponent("control.jsonl"))
    }

    public func resolveWorkspace(_ explicit: String?) async throws -> WorkspaceRecord {
        if let explicit { return try await store.load(explicit) }
        if let active = try await store.active() { return try await store.load(active) }
        throw AgentError.notFound("no active workspace; run agent create or agent use NAME")
    }

    public func create(
        repoInput: String?,
        branch explicitBranch: String?,
        state: SourceState,
        vendor: Vendor,
        name explicitName: String?,
        contexts: [String],
        cpus: Int?,
        memory: String?,
        auditLevel: AuditLevel = .full,
        makeActive: Bool = true
    ) async throws -> WorkspaceRecord {
        let repo = try resolver.resolve(repoInput)
        let currentBranch = try resolver.currentBranch(repo: repo)
        let branch = explicitBranch ?? currentBranch
        if state == .local && branch != currentBranch {
            throw AgentError.invalidArgument("--state local cannot be combined with a different --branch")
        }
        let repoName = URL(fileURLWithPath: repo).lastPathComponent
        let name = sanitizeName(explicitName ?? "\(repoName)-\(vendor.rawValue)")
        if (try await store.list()).contains(where: { $0.name == name }) {
            throw AgentError.invalidArgument("workspace already exists: \(name)")
        }

        let workspaceDir = store.paths.workspace(name)
        let baseline = workspaceDir.appendingPathComponent("baseline", isDirectory: true).appendingPathComponent(repoName, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
        try snapshotter.build(repo: repo, branch: branch, state: state, destination: baseline)
        _ = try await audit.append(workspace: name, kind: "workspace.create.begin", detail: "repo=\(repo) vendor=\(vendor.rawValue) state=\(state.rawValue) branch=\(branch)")

        do {
            try sbx.create(name: name, vendor: vendor, cpus: cpus, memory: memory)
            let home = try sbx.exec(name: name, command: ["sh", "-lc", "printf %s \"$HOME\""]).stdoutString
            let sandboxHome = home.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sandboxHome.isEmpty else { throw AgentError.malformed("sandbox HOME was empty") }
            let codeRoot = "\(sandboxHome)/code"
            let target = "\(codeRoot)/\(repoName)"

            _ = try sbx.exec(name: name, user: "root", command: ["sh", "-lc", "rm -rf \(shellQuote(codeRoot)); mkdir -p \(shellQuote(codeRoot)); chown -R agent:agent \(shellQuote(codeRoot))"])
            try sbx.copy(local: baseline.path, sandbox: name, sandboxPath: codeRoot)

            var resolvedContexts: [String] = []
            for context in contexts {
                let ctx = try resolver.resolve(context)
                let ctxName = URL(fileURLWithPath: ctx).lastPathComponent
                let ctxSnap = workspaceDir.appendingPathComponent("contexts", isDirectory: true).appendingPathComponent(ctxName, isDirectory: true)
                try snapshotter.build(repo: ctx, branch: try resolver.currentBranch(repo: ctx), state: .local, destination: ctxSnap)
                try sbx.copy(local: ctxSnap.path, sandbox: name, sandboxPath: codeRoot)
                _ = try sbx.exec(name: name, user: "root", command: ["sh", "-lc", "chown -R root:root \(shellQuote(codeRoot + "/" + ctxName)) && chmod -R a-w \(shellQuote(codeRoot + "/" + ctxName)) || true"])
                resolvedContexts.append(ctx)
            }

            try installGuestHelpers(workspaceName: name)
            _ = try sbx.exec(name: name, user: "agent", workdir: target, command: ["sh", "-lc", "git init -q && git config user.name agent-sandbox && git config user.email agent@invalid && git add -A && git commit -q --allow-empty -m AGENT_BASELINE"])

            let baselineTemplate = "agent-baseline/\(name):initial"
            try sbx.save(name: name, tag: baselineTemplate)

            let primaryWorker = WorkerRecord(name: vendor.rawValue, vendor: vendor, primary: true)
            let record = WorkspaceRecord(
                name: name,
                sandboxName: name,
                repoPath: repo,
                repoName: repoName,
                vendor: vendor,
                branch: branch,
                sourceState: state,
                sandboxHome: sandboxHome,
                targetPath: target,
                baselineTemplate: baselineTemplate,
                contextRepos: resolvedContexts,
                workers: [primaryWorker],
                auditLevel: auditLevel,
                cpus: cpus,
                memory: memory
            )
            try await store.save(record)
            if makeActive { try await store.setActive(name) }
            _ = try await audit.append(workspace: name, kind: "workspace.create.end", detail: "sandbox=\(name) target=\(target) baseline=\(baselineTemplate)")
            return record
        } catch {
            try? sbx.remove(name: name)
            try? FileManager.default.removeItem(at: workspaceDir)
            throw error
        }
    }

    public func createFromStake(
        repoInput: String?,
        record stake: StakeRecord,
        decryptedTemplate: URL,
        name explicitName: String?,
        cpus: Int?,
        memory: String?,
        auditLevel explicitAuditLevel: AuditLevel?,
        makeActive: Bool = true
    ) async throws -> WorkspaceRecord {
        let manifest = stake.manifest
        let repo = try resolver.resolve(repoInput ?? manifest.repoName)
        let repoName = URL(fileURLWithPath: repo).lastPathComponent
        guard repoName == manifest.repoName else {
            throw AgentError.unsafe("staked image is for repo \(manifest.repoName), not \(repoName)")
        }
        let name = sanitizeName(explicitName ?? "\(repoName)-\(manifest.vendor.rawValue)-i\(manifest.generation)")
        if (try await store.list()).contains(where: { $0.name == name }) {
            throw AgentError.invalidArgument("workspace already exists: \(name)")
        }
        let workspaceDir = store.paths.workspace(name)
        let baseline = workspaceDir.appendingPathComponent("baseline", isDirectory: true).appendingPathComponent(repoName, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
        _ = try await audit.append(workspace: name, kind: "workspace.create.stake.begin", detail: "stake=\(manifest.id.uuidString) generation=\(manifest.generation) repo=\(repo)")

        do {
            // Never trust a pre-existing runtime template with the same human tag.
            // The only bytes allowed to seed this restore are the just-verified,
            // just-decrypted tar supplied by VaultService.
            if try sbx.templateExists(manifest.templateTag) {
                try sbx.removeTemplate(manifest.templateTag)
            }
            try sbx.loadTemplate(file: decryptedTemplate.path)
            guard try sbx.templateExists(manifest.templateTag) else {
                throw AgentError.trustFailure("verified template loaded without its signed tag \(manifest.templateTag)")
            }
            defer { try? sbx.removeTemplate(manifest.templateTag) }

            try sbx.create(name: name, vendor: manifest.vendor, cpus: cpus, memory: memory, template: manifest.templateTag)
            let home = try sbx.exec(name: name, command: ["sh", "-lc", "printf %s \"$HOME\""]).stdoutString
            let sandboxHome = home.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sandboxHome.isEmpty else { throw AgentError.malformed("sandbox HOME was empty") }
            let target = "\(sandboxHome)/code/\(repoName)"
            let targetProbe = try sbx.execUnchecked(name: name, user: "agent", command: ["sh", "-lc", "test -d \(shellQuote(target))"])
            guard targetProbe.status == 0 else {
                throw AgentError.trustFailure("restored image does not contain expected target path \(target)")
            }

            try captureSandboxRepoBaseline(sandboxName: name, targetPath: target, destination: baseline)
            _ = try sbx.exec(name: name, user: "root", command: ["sh", "-lc", "rm -rf /var/lib/agent-audit && install -d -m 0700 -o root -g root /var/lib/agent-audit"])
            try installGuestHelpers(workspaceName: name)
            _ = try sbx.exec(name: name, user: "agent", workdir: target, command: ["sh", "-lc", "rm -rf .git && git init -q && git config user.name agent-sandbox && git config user.email agent@invalid && git add -A && git commit -q --allow-empty -m AGENT_STAKE_BASELINE"])

            let baselineTemplate = "agent-baseline/\(name):stake-\(manifest.generation)"
            try sbx.save(name: name, tag: baselineTemplate)
            let auditLevel = explicitAuditLevel ?? manifest.auditLevel
            let primaryWorker = WorkerRecord(name: manifest.vendor.rawValue, vendor: manifest.vendor, primary: true)
            let record = WorkspaceRecord(
                name: name,
                sandboxName: name,
                repoPath: repo,
                repoName: repoName,
                vendor: manifest.vendor,
                branch: manifest.branch,
                sourceState: .clean,
                sandboxHome: sandboxHome,
                targetPath: target,
                baselineTemplate: baselineTemplate,
                contextRepos: manifest.contextRepos,
                workers: [primaryWorker],
                auditLevel: auditLevel,
                cpus: cpus,
                memory: memory,
                originStakeID: manifest.id,
                originGeneration: manifest.generation
            )
            try await store.save(record)
            if makeActive { try await store.setActive(name) }
            _ = try await audit.append(workspace: name, kind: "workspace.create.stake.end", detail: "stake=\(manifest.id.uuidString) template=\(manifest.templateTag) baseline=\(baselineTemplate)")
            return record
        } catch {
            try? sbx.remove(name: name)
            try? FileManager.default.removeItem(at: workspaceDir)
            throw error
        }
    }

    public func ensureInteractiveWorkspace(vendor: Vendor, cwd: String = FileManager.default.currentDirectoryPath) async throws -> WorkspaceRecord {
        let repo = try resolver.resolve(nil, cwd: cwd)
        let matches = try await store.list().filter { $0.repoPath == repo && $0.vendor == vendor }
        if let active = try await store.active(), let record = matches.first(where: { $0.name == active }) { return record }
        if let record = matches.last {
            try await store.setActive(record.name)
            return record
        }
        return try await create(repoInput: repo, branch: nil, state: .local, vendor: vendor, name: nil, contexts: [], cpus: nil, memory: nil)
    }

    public func start(_ workspace: WorkspaceRecord) async throws {
        _ = try await audit.append(workspace: workspace.name, kind: "workspace.up", detail: workspace.sandboxName)
        try sbx.start(name: workspace.sandboxName)
    }

    public func stop(_ workspace: WorkspaceRecord) async throws {
        _ = try await audit.append(workspace: workspace.name, kind: "workspace.down", detail: workspace.sandboxName)
        try sbx.stop(name: workspace.sandboxName)
    }

    public func reset(_ workspace: WorkspaceRecord, template: String? = nil) async throws {
        let selected = template ?? workspace.baselineTemplate
        try await archiveGuestAudit(workspace, reason: "before-reset")
        _ = try await audit.append(workspace: workspace.name, kind: "workspace.reset.begin", detail: selected)
        try sbx.remove(name: workspace.sandboxName)
        try sbx.create(name: workspace.sandboxName, vendor: workspace.vendor, cpus: workspace.cpus, memory: workspace.memory, template: selected)
        _ = try await audit.append(workspace: workspace.name, kind: "workspace.reset.end", detail: selected)
    }

    public func save(_ workspace: WorkspaceRecord, as tag: String) async throws {
        _ = try await audit.append(workspace: workspace.name, kind: "workspace.save", detail: tag)
        try sbx.save(name: workspace.sandboxName, tag: tag)
    }

    public func runVendor(_ workspace: WorkspaceRecord, vendor: Vendor, worker: String, args: [String]) async throws -> Int32 {
        let exists = try sbx.execUnchecked(name: workspace.sandboxName, command: ["sh", "-lc", "command -v \(shellQuote(vendor.executable)) >/dev/null"])
        guard exists.status == 0 else { throw AgentError.notFound("\(vendor.executable) is not installed in workspace \(workspace.name)") }
        if workspace.auditLevel == .full {
            let probe = "command -v script >/dev/null && command -v strace >/dev/null && command -v setpriv >/dev/null && command -v unshare >/dev/null && command -v flock >/dev/null && uid=$(id -u agent) && gid=$(id -g agent) && setpriv --reuid=$uid --regid=$gid --clear-groups unshare --user --map-root-user --pid --fork --mount-proc -- true"
            let auditTools = try sbx.execUnchecked(name: workspace.sandboxName, user: "root", command: ["sh", "-lc", probe])
            guard auditTools.status == 0 else {
                throw AgentError.unsafe("full audit requires script + strace + setpriv + unshare + flock + working unprivileged user namespaces; agent refused to launch because the observer/fake-root boundary is not available")
            }
        }
        let session = UUID().uuidString.lowercased()
        _ = try await audit.append(workspace: workspace.name, worker: worker, kind: "session.begin", direction: "host->vm", detail: "guestSession=\(session) " + ([vendor.executable] + args).joined(separator: " "))
        do {
            if workspace.auditLevel == .full {
                try installGuestHelpers(workspaceName: workspace.sandboxName)
            }
            let before = workspace.auditLevel == .full ? try guestAudit(workspace, args: ["--snapshot"]) : nil
            var command = ["/usr/local/libexec/agent-guest/session", worker]
            if let before {
                command += ["--session", session, String(before.sequence), before.head]
            }
            let code = try sbx.interactiveExec(
                name: workspace.sandboxName,
                user: "root",
                workdir: workspace.targetPath,
                command: command + [vendor.executable] + args
            )
            let detail: String
            if let before {
                let after = try guestAudit(workspace, args: ["--session", worker, session, String(before.sequence), before.head])
                guard after.sequence == before.sequence + 2, after.head != before.head else {
                    throw AgentError.unsafe("guest audit did not advance through session start and completion")
                }
                detail = "exit=\(code) guestSession=\(session) guestAuditSequence=\(after.sequence) guestAuditHead=\(after.head)"
            } else {
                let head = try? sbx.exec(name: workspace.sandboxName, user: "root", command: ["sh", "-lc", "cat /var/lib/agent-audit/HEAD 2>/dev/null || true"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                detail = "exit=\(code) guestAuditHead=\(head ?? "")"
            }
            _ = try await audit.append(workspace: workspace.name, worker: worker, kind: "session.end", direction: "vm->host", detail: detail)
            return code
        } catch {
            _ = try? await audit.append(workspace: workspace.name, worker: worker, kind: "session.audit.failed", direction: "vm->host", detail: "guestSession=\(session) error=\(error)")
            throw error
        }
    }

    private func guestAudit(_ workspace: WorkspaceRecord, args: [String]) throws -> (sequence: Int, head: String) {
        let output = try sbx.exec(name: workspace.sandboxName, user: "root", command: ["/usr/local/libexec/agent-guest/audit-verify"] + args).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = output.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let sequence = Int(fields[0]), sequence >= 0, sequence <= Int.max - 2,
              String(sequence) == fields[0],
              fields[1].count == 64, fields[1].allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw AgentError.unsafe("guest audit returned a malformed sequence or head")
        }
        return (sequence, String(fields[1]))
    }

    public func shell(_ workspace: WorkspaceRecord) async throws -> Int32 {
        _ = try await audit.append(workspace: workspace.name, kind: "shell.begin", direction: "host->vm", detail: workspace.targetPath)
        let code = try sbx.interactiveExec(name: workspace.sandboxName, user: "agent", workdir: workspace.targetPath, command: ["bash"])
        _ = try await audit.append(workspace: workspace.name, kind: "shell.end", direction: "vm->host", detail: "exit=\(code)")
        return code
    }


    public func archiveGuestAudit(_ workspace: WorkspaceRecord, reason: String) async throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let root = store.paths.audit.appendingPathComponent("guest", isDirectory: true).appendingPathComponent(workspace.name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
        let dest = root.appendingPathComponent("\(stamp)-\(reason)", isDirectory: true)
        do {
            try sbx.copyFrom(sandbox: workspace.sandboxName, sandboxPath: "/var/lib/agent-audit", local: dest.path)
            _ = try await audit.append(workspace: workspace.name, kind: "audit.archive", detail: dest.path)
        } catch {
            _ = try? await audit.append(workspace: workspace.name, kind: "audit.archive.failed", detail: "\(error)")
            throw error
        }
    }

    public func remove(_ workspace: WorkspaceRecord) async throws {
        try await archiveGuestAudit(workspace, reason: "before-remove")
        _ = try await audit.append(workspace: workspace.name, kind: "workspace.remove.begin", detail: workspace.sandboxName)
        try sbx.remove(name: workspace.sandboxName)
        try await store.remove(workspace.name)
        _ = try await audit.append(workspace: workspace.name, kind: "workspace.remove.end", detail: workspace.sandboxName)
    }

    public func addWorker(_ workspace: WorkspaceRecord, vendor: Vendor, name: String) async throws -> WorkspaceRecord {
        _ = try sbx.exec(name: workspace.sandboxName, command: ["sh", "-lc", "command -v \(shellQuote(vendor.executable)) >/dev/null"])
        var updated = workspace
        guard !updated.workers.contains(where: { $0.name == name }) else { throw AgentError.invalidArgument("worker already exists: \(name)") }
        updated.workers.append(WorkerRecord(name: name, vendor: vendor))
        try await store.save(updated)
        _ = try await audit.append(workspace: workspace.name, worker: name, kind: "worker.add", detail: vendor.rawValue)
        return updated
    }

    public func removeWorker(_ workspace: WorkspaceRecord, name: String) async throws -> WorkspaceRecord {
        var updated = workspace
        guard let index = updated.workers.firstIndex(where: { $0.name == name }) else { throw AgentError.notFound("unknown worker: \(name)") }
        guard !updated.workers[index].primary else { throw AgentError.unsafe("cannot remove the primary worker") }
        updated.workers.remove(at: index)
        try await store.save(updated)
        _ = try await audit.append(workspace: workspace.name, worker: name, kind: "worker.remove", detail: "")
        return updated
    }

    private func installGuestHelpers(workspaceName: String) throws {
        let root = "/usr/local/libexec/agent-guest"
        let suffix = UUID().uuidString.lowercased()
        let session = "\(root)/session-\(suffix)"
        let verify = "\(root)/audit-verify-\(suffix)"
        // Stage in the root-only helper directory, never guest-writable /tmp.
        // Rename complete scripts into place and retain all existing evidence.
        let script = """
        set -eu
        install -d -m 0700 /var/lib/agent-audit \(root)
        trap 'rm -f \(session) \(verify)' EXIT
        umask 077
        printf '%s' \(shellQuote(GuestBootstrap.sessionScript)) > \(session)
        printf '%s' \(shellQuote(GuestBootstrap.verifyScript)) > \(verify)
        chmod 0755 \(session) \(verify)
        mv -f \(session) \(root)/session
        mv -f \(verify) \(root)/audit-verify
        """
        _ = try sbx.exec(name: workspaceName, user: "root", command: ["sh", "-lc", script])
    }

    private func captureSandboxRepoBaseline(sandboxName: String, targetPath: String, destination: URL) throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("agent-stake-baseline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let localTar = tempRoot.appendingPathComponent("baseline.tar")
        let remoteTar = "/tmp/agent-stake-baseline-\(UUID().uuidString).tar"
        let remoteList = "/tmp/agent-stake-baseline-\(UUID().uuidString).z"
        let script = "git ls-files -z -c -o --exclude-standard > \(shellQuote(remoteList)) && tar --null --verbatim-files-from -T \(shellQuote(remoteList)) -cf \(shellQuote(remoteTar)) && rm -f \(shellQuote(remoteList))"
        _ = try sbx.exec(name: sandboxName, user: "agent", workdir: targetPath, command: ["sh", "-lc", script])
        try sbx.copyFrom(sandbox: sandboxName, sandboxPath: remoteTar, local: localTar.path)
        _ = try? sbx.exec(name: sandboxName, user: "root", command: ["rm", "-f", remoteTar])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
        _ = try runner.checked("/usr/bin/tar", ["-xf", localTar.path, "-C", destination.path])
    }

    private func sanitizeName(_ raw: String) -> String {
        let lowered = raw.lowercased().map { c -> Character in
            if c.isLetter || c.isNumber || c == "-" { return c }
            return "-"
        }
        var s = String(lowered).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        if s.count < 2 { s += "-agent" }
        return String(s.prefix(63))
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
