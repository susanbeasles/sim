import Foundation

public struct SBXClient: Sendable {
    public let runner: ProcessRunning
    public let executable: String

    public init(runner: ProcessRunning = ProcessRunner(), executable: String = "/usr/local/bin/sbx") {
        self.runner = runner
        self.executable = executable
    }

    public func version() throws -> String {
        try runner.checked(executable, ["version"]).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func create(name: String, vendor: Vendor, cpus: Int? = nil, memory: String? = nil, template: String? = nil) throws {
        var args = ["create", "--name", name, "--skills", "off"]
        if let cpus { args += ["--cpus", String(cpus)] }
        if let memory { args += ["--memory", memory] }
        if let template { args += ["--template", template] }
        args += [vendor.sbxAgent]
        _ = try runner.checked(executable, args)
    }

    public func remove(name: String) throws {
        _ = try runner.checked(executable, ["rm", "--force", name])
    }

    public func stop(name: String) throws {
        _ = try runner.checked(executable, ["stop", name])
    }

    public func start(name: String) throws {
        _ = try runner.checked(executable, ["exec", name, "true"])
    }

    public func isRunning(name: String) throws -> Bool {
        let result = try runner.checked(executable, ["ls"])
        for line in result.stdoutString.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 3 else { continue }
            if String(fields[0]) == name {
                return String(fields[2]).lowercased() == "running"
            }
        }
        throw AgentError.notFound("sandbox not found: \(name)")
    }

    public func save(name: String, tag: String, output: String? = nil) throws {
        var args = ["template", "save", name, tag]
        if let output { args += ["--output", output] }
        _ = try runner.checked(executable, args)
    }

    public func loadTemplate(file: String) throws {
        _ = try runner.checked(executable, ["template", "load", file])
    }

    public func removeTemplate(_ tag: String) throws {
        _ = try runner.checked(executable, ["template", "rm", "--force", tag])
    }

    public func templateExists(_ tag: String) throws -> Bool {
        let result = try runner.checked(executable, ["template", "ls", "--quiet"])
        return result.stdoutString.split(whereSeparator: { $0.isWhitespace }).contains { String($0) == tag }
    }

    public func execUnchecked(name: String, user: String? = nil, workdir: String? = nil, command: [String]) throws -> ProcessResult {
        var args = ["exec"]
        if let user { args += ["--user", user] }
        if let workdir { args += ["--workdir", workdir] }
        args.append(name)
        args += command
        return try runner.capture(executable, args)
    }

    public func exec(name: String, user: String? = nil, workdir: String? = nil, command: [String]) throws -> ProcessResult {
        var args = ["exec"]
        if let user { args += ["--user", user] }
        if let workdir { args += ["--workdir", workdir] }
        args.append(name)
        args += command
        return try runner.checked(executable, args)
    }

    public func interactiveExec(name: String, user: String? = nil, workdir: String? = nil, command: [String]) throws -> Int32 {
        var args = ["exec", "-it"]
        if let user { args += ["--user", user] }
        if let workdir { args += ["--workdir", workdir] }
        args.append(name)
        args += command
        return try runner.interactive(executable, args, environment: nil)
    }

    public func copy(local: String, sandbox: String, sandboxPath: String) throws {
        _ = try runner.checked(executable, ["cp", local, "\(sandbox):\(sandboxPath)"])
    }

    public func copyFrom(sandbox: String, sandboxPath: String, local: String) throws {
        _ = try runner.checked(executable, ["cp", "\(sandbox):\(sandboxPath)", local])
    }

    public func allowNetwork(name: String, destination: String) throws {
        _ = try runner.checked(executable, ["policy", "allow", "network", "--sandbox", name, destination])
    }

    public func denyNetwork(name: String, destination: String) throws {
        _ = try runner.checked(executable, ["policy", "deny", "network", "--sandbox", name, destination])
    }

    public func removeNetwork(name: String, destination: String) throws {
        _ = try runner.checked(executable, ["policy", "rm", "network", "--sandbox", name, "--resource", destination])
    }

    public func networkLog(name: String) throws -> String {
        try runner.checked(executable, ["policy", "log", name]).stdoutString
    }
}
