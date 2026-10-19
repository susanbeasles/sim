import Foundation
import AgentCore

struct Runtime {
    let paths: AgentPaths
    let service: WorkspaceService
    let bridge: GitBridge
    let vault: VaultService
    let runner: ProcessRunner

    init() throws {
        paths = AgentPaths()
        runner = ProcessRunner()
        service = try WorkspaceService(paths: paths, runner: runner)
        bridge = try GitBridge(paths: paths, runner: runner)
        vault = try VaultService(paths: paths, workspaceService: service, runner: runner)
    }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self { case .usage(let s): return s }
    }
}

struct ParsedOptions {
    var options: [String: [String]] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []
    var remainder: [String] = []

    func one(_ names: String...) -> String? {
        for n in names { if let value = options[n]?.last { return value } }
        return nil
    }
    func many(_ name: String) -> [String] { options[name] ?? [] }
    func has(_ names: String...) -> Bool { names.contains { flags.contains($0) } }
}

struct SimpleParser {
    static func parse(_ args: [String], valueOptions: Set<String>, repeatable: Set<String> = [], stopAtFirstPositional: Bool = false) throws -> ParsedOptions {
        var out = ParsedOptions()
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--" {
                out.remainder = Array(args.dropFirst(i + 1)); break
            }
            if arg.hasPrefix("-") {
                if let eq = arg.firstIndex(of: "=") {
                    let key = String(arg[..<eq]); let value = String(arg[arg.index(after: eq)...])
                    guard valueOptions.contains(key) else { throw CLIError.usage("unknown option: \(key)") }
                    out.options[key, default: []].append(value); i += 1; continue
                }
                if valueOptions.contains(arg) {
                    guard i + 1 < args.count else { throw CLIError.usage("missing value for \(arg)") }
                    out.options[arg, default: []].append(args[i + 1]); i += 2; continue
                }
                out.flags.insert(arg); i += 1; continue
            }
            if stopAtFirstPositional {
                out.positionals.append(arg)
                out.remainder = Array(args.dropFirst(i + 1)); break
            }
            out.positionals.append(arg); i += 1
        }
        return out
    }
}

struct MergeOptions {
    let workspace: String?
    let selected: Set<String>?
    let mine: Bool
    let theirs: Bool

    init(_ args: [String]) throws {
        let p = try SimpleParser.parse(args, valueOptions: [])
        guard p.positionals.count <= 1,
              p.flags.isSubset(of: ["--mine", "--theirs"]),
              !(p.has("--mine") && p.has("--theirs")),
              !args.contains("--") || !p.remainder.isEmpty,
              !p.remainder.contains("") else {
            throw CLIError.usage("usage: sim git merge [NAME] [--mine|--theirs] [-- PATH ...]; paths require -- and a nonempty selection")
        }
        workspace = p.positionals.first
        selected = p.remainder.isEmpty ? nil : Set(p.remainder)
        mine = p.has("--mine")
        theirs = p.has("--theirs")
    }
}

struct AgentCLI {
    static let version = "0.2.0"

    static func run(_ args: [String]) async throws -> Int32 {
        guard let command = args.first else { printHelp(); return 0 }
        let rest = Array(args.dropFirst())
        switch command {
        case "fleet", "remote": return try await FleetCLI.run(rest)
        case "-h", "--help", "help": printHelp(); return 0
        case "claude", "cc": return try await vendor(.claude, args: rest)
        case "codex", "gpt": return try await vendor(.codex, args: rest)
        case "create": return try await create(rest)
        case "stake", "pew": return try await stake(rest)
        case "image", "images": return try await image(rest)
        case "key": return try await key(rest)
        case "up": return try await up(rest)
        case "down": return try await down(rest)
        case "reset": return try await reset(rest)
        case "save": return try await save(rest)
        case "rm": return try await remove(rest)
        case "shell": return try await shell(rest)
        case "status": return try await status(rest)
        case "ls": return try await list(rest)
        case "use": return try await use(rest)
        case "diff": return try await diff(rest)
        case "review": return try await review(rest)
        case "git": return try await git(rest)
        case "net": return try await net(rest)
        case "worker": return try await worker(rest)
        case "audit": return try await audit(rest)
        case "logs": return try await logs(rest)
        case "config": return try await config(rest)
        case "doctor": return try await doctor(rest)
        case "version", "--version": return try await versionCommand(rest)
        default: throw CLIError.usage("unknown command: \(command)\nRun 'agent help'.")
        }
    }

    private static func vendor(_ vendor: Vendor, args: [String]) async throws -> Int32 {
        var forwarded = args
        var explicitWorker: String?
        if forwarded.count >= 2, forwarded[0] == "--worker" {
            explicitWorker = forwarded[1]
            forwarded.removeFirst(2)
        } else if let first = forwarded.first, first.hasPrefix("--worker=") {
            explicitWorker = String(first.dropFirst("--worker=".count))
            forwarded.removeFirst()
        }
        let rt = try Runtime()
        let ws = try await rt.service.ensureInteractiveWorkspace(vendor: vendor)
        let worker = explicitWorker ?? ws.workers.first(where: { $0.vendor == vendor && $0.primary })?.name ?? vendor.rawValue
        return try await rt.service.runVendor(ws, vendor: vendor, worker: worker, args: forwarded)
    }

    private static func create(_ args: [String]) async throws -> Int32 {
        let p = try SimpleParser.parse(args, valueOptions: ["-r","--repo","-b","--branch","--state","-v","--vendor","-n","--name","--context","--cpus","--memory","--audit","-i","--image"])
        let cpus = p.one("--cpus").flatMap(Int.init)
        let rt = try Runtime()

        if let imageRaw = p.one("-i", "--image") {
            if p.one("-b", "--branch") != nil || p.one("--state") != nil || !p.many("--context").isEmpty {
                throw CLIError.usage("--image restores the exact staked filesystem; do not combine it with --branch, --state, or --context")
            }
            let selector = try ImageSelector(imageRaw)
            let audit = try p.one("--audit").map { raw -> AuditLevel in
                guard let value = AuditLevel(rawValue: raw) else { throw CLIError.usage("--audit must be full or control") }
                return value
            }
            let ws = try await rt.vault.restore(
                repoInput: p.one("-r", "--repo"),
                selector: selector,
                name: p.one("-n", "--name"),
                cpus: cpus,
                memory: p.one("--memory"),
                auditLevel: audit,
                makeActive: !p.has("--no-use")
            )
            if let requestedVendor = p.one("-v", "--vendor") {
                let vendor = try Vendor(cliValue: requestedVendor)
                guard vendor == ws.vendor else {
                    throw CLIError.usage("image was staked for \(ws.vendor.rawValue); cross-vendor restore is intentionally not implicit")
                }
            }
            print("created \(ws.name)\nsandbox  \(ws.sandboxName)\ntarget   \(ws.targetPath)\norigin   generation \(ws.originGeneration ?? -1) / \(ws.originStakeID?.uuidString ?? "unknown")")
            return 0
        }

        guard let vendorRaw = p.one("-v","--vendor") else { throw CLIError.usage("agent create requires --vendor claude|cc|codex|gpt unless --image is used") }
        let vendor = try Vendor(cliValue: vendorRaw)
        guard let state = SourceState(rawValue: p.one("--state") ?? "clean") else { throw CLIError.usage("--state must be clean or local") }
        guard let audit = AuditLevel(rawValue: p.one("--audit") ?? "full") else { throw CLIError.usage("--audit must be full or control") }
        let ws = try await rt.service.create(
            repoInput: p.one("-r","--repo"), branch: p.one("-b","--branch"), state: state, vendor: vendor,
            name: p.one("-n","--name"), contexts: p.many("--context"), cpus: cpus, memory: p.one("--memory"),
            auditLevel: audit, makeActive: !p.has("--no-use")
        )
        print("created \(ws.name)\nsandbox  \(ws.sandboxName)\ntarget   \(ws.targetPath)\nbaseline \(ws.baselineTemplate)")
        return 0
    }

    private static func stake(_ args: [String]) async throws -> Int32 {
        let p = try SimpleParser.parse(args, valueOptions: ["-t", "--tag"])
        guard let tag = p.one("-t", "--tag") else { throw CLIError.usage("usage: agent stake [WORKSPACE] -t TAG") }
        let rt = try Runtime()
        let ws = try await rt.service.resolveWorkspace(p.positionals.first)
        let record = try await rt.vault.stake(workspace: ws, tag: tag)
        print("STAKED")
        print("repo       \(record.manifest.repoName)")
        print("generation \(record.manifest.generation)")
        print("tag        \(record.manifest.tag)")
        print("stake      \(record.manifest.id.uuidString)")
        print("manifest   sha256:\(record.manifestSHA256)")
        print("object     sha256:\(record.manifest.artifact.ciphertextSHA256)")
        return 0
    }

    private static func image(_ args: [String]) async throws -> Int32 {
        guard let sub = args.first else { throw CLIError.usage("usage: agent image ls|verify ...") }
        let rest = Array(args.dropFirst())
        let rt = try Runtime()
        switch sub {
        case "ls", "list":
            let p = try SimpleParser.parse(rest, valueOptions: ["-r", "--repo"])
            let repoName: String?
            if let input = p.one("-r", "--repo") {
                repoName = URL(fileURLWithPath: try rt.service.resolver.resolve(input)).lastPathComponent
            } else if p.has("--all") {
                repoName = nil
            } else {
                repoName = try? URL(fileURLWithPath: rt.service.resolver.resolve(nil)).lastPathComponent
            }
            let records = try await rt.vault.records(repoName: repoName)
            if records.isEmpty { print("no staked images"); return 0 }
            for r in records {
                print("\(r.manifest.repoName)\t\(r.manifest.generation)\t\(r.manifest.tag)\t\(r.manifest.id.uuidString.lowercased())\tsha256:\(r.manifest.artifact.ciphertextSHA256)")
            }
            return 0
        case "verify":
            let p = try SimpleParser.parse(rest, valueOptions: ["-r", "--repo"])
            guard let raw = p.positionals.first else { throw CLIError.usage("usage: agent image verify IMAGE [-r REPO] [--deep]") }
            let repo = try rt.service.resolver.resolve(p.one("-r", "--repo"))
            let record = try await rt.vault.vaultStore.resolve(repoPath: repo, selector: ImageSelector(raw))
            try await rt.vault.verify(record: record, deep: p.has("--deep"))
            print("verified generation \(record.manifest.generation) \(record.manifest.id.uuidString)")
            return 0
        default:
            throw CLIError.usage("unknown image command: \(sub)")
        }
    }

    private static func key(_ args: [String]) async throws -> Int32 {
        guard args == ["identities"] || args == ["ls"] else { throw CLIError.usage("usage: agent key identities") }
        let identities = try HardwareVaultCrypto().identities()
        if identities.isEmpty { print("no Keychain/PIV identities found"); return 0 }
        for item in identities {
            let compatibility = item.rsaOAEPCompatible ? "vault-ok" : "incompatible"
            print("\(item.certificateSHA256)\t\(compatibility)\t\(item.keyType) \(item.keyBits)\t\(item.tokenID)\t\(item.subject)")
        }
        return 0
    }

    private static func up(_ args: [String]) async throws -> Int32 {
        let p = try SimpleParser.parse(args, valueOptions: [])
        let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(p.positionals.first)
        try await rt.service.start(ws); print("up \(ws.name)")
        if p.has("-a","--attach") {
            let worker = ws.workers.first(where: { $0.primary })?.name ?? ws.vendor.rawValue
            return try await rt.service.runVendor(ws, vendor: ws.vendor, worker: worker, args: [])
        }
        return 0
    }

    private static func down(_ args: [String]) async throws -> Int32 {
        let p = try SimpleParser.parse(args, valueOptions: []); let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(p.positionals.first)
        try await rt.service.stop(ws); print("down \(ws.name)"); return 0
    }

    private static func reset(_ args: [String]) async throws -> Int32 {
        let p = try SimpleParser.parse(args, valueOptions: ["--saved"]); let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(p.positionals.first)
        if !p.has("-f","--force") {
            print("reset \(ws.name)? type RESET \(ws.name): ", terminator: "")
            guard readLine() == "RESET \(ws.name)" else { throw CLIError.usage("cancelled") }
        }
        try await rt.service.reset(ws, template: p.one("--saved")); print("reset \(ws.name)"); return 0
    }

    private static func save(_ args: [String]) async throws -> Int32 {
        let p = try SimpleParser.parse(args, valueOptions: ["-n","--name"])
        guard let tag = p.one("-n","--name") else { throw CLIError.usage("agent save requires --name TEMPLATE") }
        let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(p.positionals.first); try await rt.service.save(ws, as: tag); print("saved \(tag)"); return 0
    }

    private static func remove(_ args: [String]) async throws -> Int32 {
        let p = try SimpleParser.parse(args, valueOptions: []); let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(p.positionals.first)
        if !p.has("-f","--force") {
            print("remove \(ws.name)? type REMOVE \(ws.name): ", terminator: "")
            guard readLine() == "REMOVE \(ws.name)" else { throw CLIError.usage("cancelled") }
        }
        try await rt.service.remove(ws); print("removed \(ws.name)"); return 0
    }

    private static func shell(_ args: [String]) async throws -> Int32 {
        let p = try SimpleParser.parse(args, valueOptions: []); let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(p.positionals.first)
        return try await rt.service.shell(ws)
    }

    private static func status(_ args: [String]) async throws -> Int32 {
        let p = try SimpleParser.parse(args, valueOptions: []); let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(p.positionals.first)
        var lines = "name      \(ws.name)\nvendor    \(ws.vendor.rawValue)\nrepo      \(ws.repoPath)\nbranch    \(ws.branch)\nstate     \(ws.sourceState.rawValue)\nsandbox   \(ws.sandboxName)\ntarget    \(ws.targetPath)\naudit     \(ws.auditLevel.rawValue)\nworkers   \(ws.workers.map(\.name).joined(separator: ", "))"
        if let generation = ws.originGeneration, let stake = ws.originStakeID { lines += "\norigin    image \(generation) / \(stake.uuidString)" }
        print(lines)
        return 0
    }

    private static func list(_ args: [String]) async throws -> Int32 {
        guard args.isEmpty else { throw CLIError.usage("usage: agent ls") }
        let rt = try Runtime(); let active = try await rt.service.store.active()
        for ws in try await rt.service.store.list() { print("\(ws.name == active ? "*" : " ") \(ws.name)\t\(ws.vendor.rawValue)\t\(ws.repoPath)") }
        return 0
    }

    private static func use(_ args: [String]) async throws -> Int32 {
        guard args.count == 1 else { throw CLIError.usage("usage: agent use NAME") }
        let rt = try Runtime(); try await rt.service.store.setActive(args[0]); print("using \(args[0])"); return 0
    }

    private static func diff(_ args: [String]) async throws -> Int32 {
        let split = splitNameAndPaths(args); let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(split.name)
        print(try await rt.bridge.diff(ws, paths: split.paths), terminator: ""); return 0
    }

    private static func review(_ args: [String]) async throws -> Int32 {
        let name = args.first; let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(name); let text = try await rt.bridge.diff(ws)
        let pager = ProcessInfo.processInfo.environment["PAGER"] ?? "/usr/bin/less"
        if FileManager.default.isExecutableFile(atPath: pager) {
            let process = Process(); process.executableURL = URL(fileURLWithPath: pager); process.arguments = ["-R"]
            let pipe = Pipe(); process.standardInput = pipe; process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.standardError
            try process.run(); try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8)); try pipe.fileHandleForWriting.close(); process.waitUntilExit(); return process.terminationStatus
        }
        print(text, terminator: ""); return 0
    }

    private static func git(_ args: [String]) async throws -> Int32 {
        guard let sub = args.first else { throw CLIError.usage("usage: agent git merge|commit|pull ...") }
        let rest = Array(args.dropFirst())
        switch sub {
        case "merge":
            let p = try MergeOptions(rest)
            let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(p.workspace)
            if p.mine { print("kept host state; nothing changed"); return 0 }
            if p.theirs { try await rt.bridge.takeTheirs(ws, selected: p.selected, authorize: true); print("applied agent versions"); return 0 }
            let conflicts = try await rt.bridge.merge(ws, selected: p.selected, authorize: true)
            if conflicts.isEmpty { print("merged cleanly"); return 0 }
            print("conflicts:\n" + conflicts.map { "  \($0)" }.joined(separator: "\n")); return 1
        case "commit":
            let p = try SimpleParser.parse(rest, valueOptions: ["-m","--message"])
            guard let message = p.one("-m","--message") else { throw CLIError.usage("agent git commit requires -m MESSAGE") }
            let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(p.positionals.first); try await rt.bridge.commit(ws, message: message); print("committed agent candidate"); return 0
        case "pull":
            throw CLIError.usage("agent git pull is intentionally reserved in v0.2.0; host→sandbox sync will be 3-way, not a hidden overwrite")
        default: throw CLIError.usage("unknown agent git command: \(sub)")
        }
    }

    private static func net(_ args: [String]) async throws -> Int32 {
        guard let sub = args.first else { throw CLIError.usage("usage: agent net allow|deny|log ...") }
        let rest = Array(args.dropFirst())
        switch sub {
        case "allow":
            guard rest.count >= 1 else { throw CLIError.usage("usage: agent net allow [NAME] DESTINATION") }
            let rt = try Runtime(); let name = rest.count >= 2 ? rest[0] : nil; let destination = rest.last!; let ws = try await rt.service.resolveWorkspace(name)
            let cfg = try await rt.service.store.loadConfiguration()
            let manifest = "operation=network.allow\nworkspace=\(ws.id.uuidString)\nsandbox=\(ws.sandboxName)\ndestination=\(destination)\nnonce=\(UUID().uuidString)\n"
            try AuthorizationGate(runner: rt.runner, configuration: cfg).authorize(operation: "network allow \(destination)", manifest: manifest)
            try rt.service.sbx.allowNetwork(name: ws.sandboxName, destination: destination); _ = try await rt.service.audit.append(workspace: ws.name, kind: "network.allow", detail: destination); print("allowed \(destination)"); return 0
        case "deny":
            guard rest.count >= 1 else { throw CLIError.usage("usage: agent net deny [NAME] DESTINATION") }
            let rt = try Runtime(); let name = rest.count >= 2 ? rest[0] : nil; let destination = rest.last!; let ws = try await rt.service.resolveWorkspace(name)
            try rt.service.sbx.denyNetwork(name: ws.sandboxName, destination: destination); _ = try await rt.service.audit.append(workspace: ws.name, kind: "network.deny", detail: destination); print("denied \(destination)"); return 0
        case "log":
            let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(rest.first); print(try rt.service.sbx.networkLog(name: ws.sandboxName), terminator: ""); return 0
        default: throw CLIError.usage("unknown agent net command: \(sub)")
        }
    }

    private static func worker(_ args: [String]) async throws -> Int32 {
        guard let sub = args.first else { throw CLIError.usage("usage: agent worker add|ls|rm ...") }
        let rest = Array(args.dropFirst())
        switch sub {
        case "add":
            let p = try SimpleParser.parse(rest, valueOptions: ["-v","--vendor","-n","--name"])
            guard let v = p.one("-v","--vendor"), let n = p.one("-n","--name") else { throw CLIError.usage("agent worker add requires --vendor and --name") }
            let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(p.positionals.first); _ = try await rt.service.addWorker(ws, vendor: try Vendor(cliValue: v), name: n); print("added \(n)"); return 0
        case "ls":
            let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(rest.first); for w in ws.workers { print("\(w.primary ? "*" : " ") \(w.name)\t\(w.vendor.rawValue)") }; return 0
        case "rm":
            guard let workerName = rest.last else { throw CLIError.usage("usage: agent worker rm [WORKSPACE] WORKER") }
            let workspaceName = rest.count >= 2 ? rest[0] : nil; let rt = try Runtime(); let ws = try await rt.service.resolveWorkspace(workspaceName); _ = try await rt.service.removeWorker(ws, name: workerName); print("removed \(workerName)"); return 0
        default: throw CLIError.usage("unknown agent worker command: \(sub)")
        }
    }

    private static func audit(_ args: [String]) async throws -> Int32 {
        guard let sub = args.first else { throw CLIError.usage("usage: agent audit verify|tail|sessions|transcript|actions|export ...") }
        let rest = Array(args.dropFirst()); let rt = try Runtime()
        switch sub {
        case "verify":
            let head = try await rt.service.audit.verify(); print("host-ledger \(head?.digest ?? "empty")")
            if let name = rest.first { let ws = try await rt.service.resolveWorkspace(name); let guest = try rt.service.sbx.exec(name: ws.sandboxName, user: "root", command: ["/usr/local/libexec/agent-guest/audit-verify"]); print("guest-ledger \(guest.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))") }
            return 0
        case "tail":
            let p = try SimpleParser.parse(rest, valueOptions: ["-n","--count"]); let count = Int(p.one("-n","--count") ?? "20") ?? 20; let events = try await rt.service.audit.loadAll(); for e in events.suffix(max(0,count)) { print("\(e.sequence)\t\(e.kind)\t\(e.workspace ?? "-")\t\(e.detail)") }; return 0
        case "sessions":
            let p = try SimpleParser.parse(rest, valueOptions: ["--worker"]); let ws = try await rt.service.resolveWorkspace(p.positionals.first); let worker = p.one("--worker")
            let root = worker.map { "/var/lib/agent-audit/sessions/\($0)" } ?? "/var/lib/agent-audit/sessions"
            let cmd = "test -d \(shellQuote(root)) && find \(shellQuote(root)) -mindepth \(worker == nil ? 2 : 1) -maxdepth \(worker == nil ? 2 : 1) -type d -print | sort || true"
            let out = try rt.service.sbx.exec(name: ws.sandboxName, user: "root", command: ["sh","-lc",cmd]); print(out.stdoutString, terminator: ""); return 0
        case "transcript":
            return try await auditTranscript(rest, runtime: rt, followOverride: nil)
        case "actions":
            let p = try SimpleParser.parse(rest, valueOptions: ["--worker","--session","-n","--count","--grep"]); let ws = try await rt.service.resolveWorkspace(p.positionals.first); let worker = p.one("--worker") ?? primaryWorker(ws); let session = p.one("--session"); let count = max(1, Int(p.one("-n","--count") ?? "200") ?? 200); let grep = p.one("--grep")
            let dir = guestSessionSelector(worker: worker, session: session)
            var cmd = "d=\(dir); test -n \"$d\" || { echo 'no audited session' >&2; exit 1; }; set -- \"$d\"/trace.*; [ -e \"$1\" ] || { echo 'no syscall trace for session' >&2; exit 1; }; cat \"$d\"/trace.*"
            if let grep { cmd += " | { grep -F -- \(shellQuote(grep)) || true; }" }
            cmd += " | tail -n \(count)"
            let out = try rt.service.sbx.exec(name: ws.sandboxName, user: "root", command: ["sh","-lc",cmd]); print(out.stdoutString, terminator: ""); return 0
        case "export":
            let p = try SimpleParser.parse(rest, valueOptions: ["-o","--output"]); guard let output = p.one("-o","--output") else { throw CLIError.usage("agent audit export requires --output DIR") }; let ws = try await rt.service.resolveWorkspace(p.positionals.first); let out = NSString(string: output).expandingTildeInPath; try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true); try rt.service.sbx.copyFrom(sandbox: ws.sandboxName, sandboxPath: "/var/lib/agent-audit", local: out); print(out); return 0
        default: throw CLIError.usage("unknown agent audit command: \(sub)")
        }
    }

    private static func logs(_ args: [String]) async throws -> Int32 {
        let rt = try Runtime()
        return try await auditTranscript(args, runtime: rt, followOverride: nil)
    }

    private static func auditTranscript(_ args: [String], runtime rt: Runtime, followOverride: Bool?) async throws -> Int32 {
        let p = try SimpleParser.parse(args, valueOptions: ["--worker","--session","-n","--count"]); let ws = try await rt.service.resolveWorkspace(p.positionals.first); let worker = p.one("--worker") ?? primaryWorker(ws); let session = p.one("--session"); let count = max(1, Int(p.one("-n","--count") ?? "200") ?? 200); let follow = followOverride ?? p.has("-f","--follow")
        let dir = guestSessionSelector(worker: worker, session: session)
        let cmd = "d=\(dir); test -n \"$d\" || { echo 'no audited session' >&2; exit 1; }; test -f \"$d/pty.out\" || { echo 'session has no PTY output' >&2; exit 1; }; tail -n \(count) \(follow ? "-f " : "")\"$d/pty.out\""
        if follow { return try rt.service.sbx.interactiveExec(name: ws.sandboxName, user: "root", command: ["sh","-lc",cmd]) }
        let out = try rt.service.sbx.exec(name: ws.sandboxName, user: "root", command: ["sh","-lc",cmd]); print(out.stdoutString, terminator: ""); return 0
    }

    private static func primaryWorker(_ ws: WorkspaceRecord) -> String {
        ws.workers.first(where: { $0.primary })?.name ?? ws.vendor.rawValue
    }

    private static func guestSessionSelector(worker: String, session: String?) -> String {
        let root = "/var/lib/agent-audit/sessions/\(worker)"
        if let session { return shellQuote(root + "/" + session) }
        return "$(ls -1dt \(shellQuote(root))/* 2>/dev/null | head -n1)"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func config(_ args: [String]) async throws -> Int32 {
        guard let sub = args.first else { throw CLIError.usage("usage: agent config auth-key|piv-cert|show ...") }; let rest = Array(args.dropFirst()); let rt = try Runtime()
        switch sub {
        case "auth-key":
            guard rest.count == 1 else { throw CLIError.usage("usage: agent config auth-key PATH") }
            var cfg = try await rt.service.store.loadConfiguration(); cfg.authorizationKey = rest[0]
            let fingerprint = try AuthorizationGate(runner: rt.runner, configuration: cfg).configuredFingerprint()
            if BuildIdentity.releaseBuild && AuthorizationGate.normalizeSSHFingerprint(fingerprint) != AuthorizationGate.normalizeSSHFingerprint(BuildIdentity.expectedAuthorizationKeySHA256) {
                throw AgentError.trustFailure("that authorization key does not match the fingerprint pinned into this signed build")
            }
            try await rt.service.store.saveConfiguration(cfg); print("authorization key: \(rest[0])\nfingerprint: \(fingerprint)"); return 0
        case "piv-cert":
            guard rest.count == 1 else { throw CLIError.usage("usage: agent config piv-cert CERT_SHA256") }
            let normalized = HardwareVaultCrypto.normalizeFingerprint(rest[0])
            guard normalized.count == 64 else { throw CLIError.usage("PIV certificate fingerprint must be SHA-256") }
            let identities = try HardwareVaultCrypto().identities()
            guard let identity = identities.first(where: { $0.certificateSHA256 == normalized }) else {
                throw AgentError.notFound("no connected hardware-backed Keychain/PIV identity matches \(normalized)")
            }
            guard identity.rsaOAEPCompatible else {
                throw AgentError.unsupported("that hardware identity cannot perform the RSA-OAEP-SHA256 vault unwrap required by agent")
            }
            var cfg = try await rt.service.store.loadConfiguration(); cfg.pivCertificateSHA256 = normalized; try await rt.service.store.saveConfiguration(cfg)
            print("PIV certificate: \(normalized)"); return 0
        case "show":
            let cfg = try await rt.service.store.loadConfiguration()
            print("authorizationKey \(cfg.authorizationKey ?? "<unset>")\npivCertificate  \(cfg.pivCertificateSHA256 ?? "<unset>")\ncodeRoot         \(cfg.codeRoot)")
            return 0
        default: throw CLIError.usage("unknown config command: \(sub)")
        }
    }

    private static func doctor(_ args: [String]) async throws -> Int32 {
        guard args.isEmpty else { throw CLIError.usage("usage: agent doctor") }; let rt = try Runtime(); try TrustGate.requireValidSelf(); print("✓ self trust gate"); print("✓ sbx \(try rt.service.sbx.version())"); let cfg = try await rt.service.store.loadConfiguration();
        if cfg.authorizationKey == nil { print("! authorization key unset") } else { let fp = try AuthorizationGate(runner: rt.runner, configuration: cfg).configuredFingerprint(); print("✓ authorization key \(fp)") }
        if let piv = cfg.pivCertificateSHA256 { let ids = try HardwareVaultCrypto().identities(); print(ids.contains(where: { $0.certificateSHA256 == piv }) ? "✓ PIV vault identity \(piv)" : "! configured PIV vault identity is not currently available") } else { print("! PIV vault identity unset") }
        let head = try await rt.service.audit.verify(); print("✓ host audit \(head?.digest ?? "empty")")
        if let active = try await rt.service.store.active(), let ws = try? await rt.service.store.load(active) { let tools = try rt.service.sbx.exec(name: ws.sandboxName, user: "root", command: ["sh","-lc","for x in script strace setpriv unshare flock; do command -v \"$x\" >/dev/null && echo \"$x=ok\" || echo \"$x=missing\"; done"]); print(tools.stdoutString, terminator: "") }
        return 0
    }

    private static func versionCommand(_ args: [String]) async throws -> Int32 {
        guard args.isEmpty else { throw CLIError.usage("usage: agent version") }; let rt = try Runtime(); print("agent \(version)\nbundle \(BuildIdentity.bundleIdentifier)\nteam   \(BuildIdentity.expectedTeamID)\nauth   \(BuildIdentity.expectedAuthorizationKeySHA256)\nsbx    \(try rt.service.sbx.version())"); return 0
    }

    private static func splitNameAndPaths(_ args: [String]) -> (name: String?, paths: [String]) {
        if let idx = args.firstIndex(of: "--") { let before = Array(args[..<idx]); return (before.first, Array(args.dropFirst(idx + 1))) }
        return (args.first, [])
    }

    static func printHelp() {
        print("""
        agent - signed controller for isolated Claude Code / Codex sandboxes

        Day to day:
          agent claude [ARGS...]       open Claude Code in current repo sandbox
          agent codex  [ARGS...]       open Codex in current repo sandbox

        Lifecycle:
          agent create -v cc|gpt [-r REPO] [--state clean|local] [--context REPO]...
          agent create --repo REPO -i IMAGE       restore signed staked image
          agent stake [NAME] -t TAG               freeze/export/encrypt/sign image
          agent image ls [-r REPO|--all]
          agent image verify IMAGE [-r REPO] [--deep]
          agent up [NAME] [-a]
          agent down [NAME]
          agent reset [NAME] [--saved TEMPLATE] [-f]
          agent save [NAME] --name TEMPLATE
          agent rm [NAME] [-f]
          agent shell [NAME]

        Inspect:
          agent status [NAME]
          agent ls
          agent use NAME
          agent diff [NAME] [-- PATH...]
          agent review [NAME]

        Host boundary:
          agent git merge [NAME] [--theirs|--mine] [-- PATH...]
          agent git commit [NAME] -m MESSAGE
          agent git pull [NAME] [origin]      (reserved)

        Workers / audit / network:
          agent worker add [NAME] -v cc|gpt -n WORKER
          agent worker ls [NAME]
          agent worker rm [NAME] WORKER
          agent logs [NAME] [--worker WORKER] [-n COUNT] [-f]
          agent audit verify [NAME]
          agent audit tail [-n COUNT]
          agent audit sessions [NAME] [--worker WORKER]
          agent audit transcript [NAME] [--worker WORKER] [--session ID] [-n COUNT] [-f]
          agent audit actions [NAME] [--worker WORKER] [--session ID] [-n COUNT] [--grep TEXT]
          agent audit export [NAME] -o DIR
          agent net allow [NAME] DESTINATION
          agent net deny [NAME] DESTINATION
          agent net log [NAME]

        Configuration:
          agent key identities
          agent config auth-key ~/.ssh/id_yubikey
          agent config piv-cert CERT_SHA256
          agent config show
          agent doctor
          agent version
        """)
    }
}
