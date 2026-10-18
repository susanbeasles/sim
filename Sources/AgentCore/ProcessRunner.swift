import Foundation
import Darwin

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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        guard limit > 0, timeout > 0, timeout.isFinite else {
            throw AgentError.invalidArgument("process limits must be positive and finite")
        }
        try process.run()
        // The parent must not keep a writer open while waiting for EOF.
        try out.fileHandleForWriting.close()
        try err.fileHandleForWriting.close()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }
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
        while !ended.allSatisfy({ $0 }) || process.isRunning {
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
            if !progress { usleep(1_000) }
        }
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, stdout: streams[0], stderr: streams[1])
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
