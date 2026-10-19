import Foundation
import Darwin
import ProcessSupport

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public protocol ProcessRunning: Sendable {
    func capture(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> ProcessResult
    func interactive(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> Int32
}

public struct ProcessRunner: ProcessRunning, Sendable {
    // Combined stdout/stderr budget, including binary review archives and patches.
    public static let outputBytes = 64 * 1024 * 1024
    private let limit: Int
    private let timeout: TimeInterval

    public init(outputBytes: Int = ProcessRunner.outputBytes, timeout: TimeInterval = 120) {
        self.limit = outputBytes
        self.timeout = timeout
    }

    public func capture(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> ProcessResult {
        let out = Pipe()
        let err = Pipe()
        guard limit > 0, timeout > 0, timeout.isFinite else {
            throw AgentError.invalidArgument("process limits must be positive and finite")
        }
        // posix_spawn creates the child's process group atomically, avoiding a
        // race between exec/exit and a parent-side setpgid call.
        let argumentValues = [executable] + arguments
        let environmentValues = (environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
        guard (argumentValues + environmentValues).allSatisfy({ !$0.utf8.contains(0) }) else {
            throw AgentError.invalidArgument("process arguments and environment cannot contain NUL")
        }
        let argumentsStorage = argumentValues.map { strdup($0) }
        let environmentStorage = environmentValues.map { strdup($0) }
        defer {
            for value in argumentsStorage + environmentStorage { free(value) }
        }
        guard (argumentsStorage + environmentStorage).allSatisfy({ $0 != nil }) else {
            throw AgentError.unsafe("cannot allocate process arguments")
        }
        let argv = argumentsStorage.map { $0.map { UnsafePointer<CChar>($0) } } + [nil]
        let envp = environmentStorage.map { $0.map { UnsafePointer<CChar>($0) } } + [nil]
        var pid: pid_t = 0
        let launch = argv.withUnsafeBufferPointer { argv in
            envp.withUnsafeBufferPointer { envp in
                sim_spawn_group(executable, argv.baseAddress, envp.baseAddress,
                    out.fileHandleForReading.fileDescriptor, out.fileHandleForWriting.fileDescriptor,
                    err.fileHandleForReading.fileDescriptor, err.fileHandleForWriting.fileDescriptor, &pid)
            }
        }
        guard launch == 0 else { throw AgentError.unsafe("cannot launch process: errno=\(launch)") }
        var reaped = false
        var status: Int32 = 0
        defer {
            if !reaped {
                // The unreaped leader reserves the group ID, even if it exited
                // while a descendant retained a pipe. Never target a reused PID.
                _ = sim_kill_group(pid)
                _ = sim_wait_child(pid, 0, &status)
            }
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }
        try out.fileHandleForWriting.close()
        try err.fileHandleForWriting.close()
        let descriptors = [out.fileHandleForReading.fileDescriptor, err.fileHandleForReading.fileDescriptor]
        for fd in descriptors {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw AgentError.unsafe("cannot configure bounded process capture")
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        var streams = [Data(), Data()]
        var ended = [false, false]
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !reaped {
            guard start.duration(to: clock.now) < .seconds(timeout) else {
                throw AgentError.unsafe("process exceeded time limit")
            }
            var progress = false
            for i in 0..<2 where !ended[i] {
                let count = Darwin.read(descriptors[i], &buffer, buffer.count)
                if count > 0 {
                    guard count <= limit - total else {
                        throw AgentError.unsafe("process exceeded output limit")
                    }
                    streams[i].append(contentsOf: buffer.prefix(count))
                    total += count
                    progress = true
                } else if count == 0 {
                    ended[i] = true
                } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    throw AgentError.unsafe("cannot read process output")
                }
            }
            // Do not reap the leader until both pipes end; on failure its PID
            // must remain reserved so group cleanup cannot signal another job.
            if ended.allSatisfy({ $0 }) {
                let waited = sim_wait_child(pid, 1, &status)
                guard waited >= 0 else { throw AgentError.unsafe("cannot reap process: errno=\(-waited)") }
                reaped = waited == 1
            }
            if !progress && !reaped { usleep(1_000) }
        }
        return ProcessResult(status: status, stdout: streams[0], stderr: streams[1])
    }

    public func interactive(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

public extension ProcessRunning {
    func capture(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        try capture(executable, arguments, environment: nil)
    }

    func interactive(_ executable: String, _ arguments: [String]) throws -> Int32 {
        try interactive(executable, arguments, environment: nil)
    }

    func checked(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> ProcessResult {
        let result = try capture(executable, arguments, environment: environment)
        guard result.status == 0 else {
            throw AgentError.processFailed(
                command: ([executable] + arguments).joined(separator: " "),
                code: result.status,
                stderr: result.stderrString
            )
        }
        return result
    }
}
