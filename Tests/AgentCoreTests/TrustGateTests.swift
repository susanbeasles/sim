#if os(macOS)
import Foundation
import XCTest

final class TrustGateTests: XCTestCase {
    func testRejectsSpoofedExecutableIdentity() throws {
        let app = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        guard let bundle = Bundle(url: app), let identifier = bundle.bundleIdentifier,
              let executable = bundle.executableURL else {
            throw XCTSkip("Requires an installed Developer ID signed ChatGPT.app")
        }
        let signature = try run("/usr/bin/codesign", ["-d", "--verbose=4", app.path])
        guard let team = signature.output.split(separator: "\n")
            .first(where: { $0.hasPrefix("TeamIdentifier=") })?
            .dropFirst("TeamIdentifier=".count), team != "not set" else {
            throw XCTSkip("Requires an installed app with a Team ID")
        }
        let requirement = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        let verification = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=\(requirement)", app.path])
        XCTAssertEqual(verification.status, 0, verification.output)
        guard verification.status == 0 else { return }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("main.swift")
        try """
        import Foundation
        enum BuildIdentity {
            static let releaseBuild = true
            static let expectedTeamID = \(String(team).debugDescription)
            static let bundleIdentifier = \(identifier.debugDescription)
        }
        enum AgentError: Error { case trustFailure(String) }
        do {
            try TrustGate.requireValidSelf()
            print("TRUSTED")
        } catch {
            print("REJECTED: \\(error)")
            exit(64)
        }
        """.write(to: fixture, atomically: true, encoding: .utf8)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCore/TrustGate.swift")
        let binary = root.appendingPathComponent("fixture")
        let compilation = try run("/usr/bin/xcrun", ["swiftc", source.path, fixture.path, "-o", binary.path])
        XCTAssertEqual(compilation.status, 0, compilation.output)
        guard compilation.status == 0 else { return }

        let launch = try run("/bin/zsh", ["-c", "exec -a \"$1\" \"$2\"", "trust-test", executable.path, binary.path])
        XCTAssertEqual(launch.status, 64, launch.output)
        XCTAssertTrue(launch.output.contains("running agent signature/identity verification failed"), launch.output)
        XCTAssertFalse(launch.output.contains("TRUSTED"), launch.output)
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
#endif
