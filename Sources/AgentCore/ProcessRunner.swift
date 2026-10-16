import Foundation

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
    public init() {}

    public func capture(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
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
