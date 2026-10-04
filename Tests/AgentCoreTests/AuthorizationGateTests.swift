import XCTest
@testable import AgentCore

private struct AuthFakeRunner: ProcessRunning {
    func capture(_ executable: String, _ arguments: [String], environment: [String : String]?) throws -> ProcessResult {
        ProcessResult(status: 0, stdout: Data("256 SHA256:hardwarefingerprint key (ED25519-SK)\n".utf8), stderr: Data())
    }
    func interactive(_ executable: String, _ arguments: [String], environment: [String : String]?) throws -> Int32 { 0 }
}

final class AuthorizationGateTests: XCTestCase {
    func testRejectsSoftwareSSHKeyType() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pub = root.appendingPathComponent("id_test.pub")
        try Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA test\n".utf8).write(to: pub)
        let cfg = AgentConfiguration(authorizationKey: pub.path)
        let gate = AuthorizationGate(runner: AuthFakeRunner(), configuration: cfg)
        XCTAssertThrowsError(try gate.configuredFingerprint())
    }

    func testAcceptsFIDOHardwareSSHKeyType() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pub = root.appendingPathComponent("id_test.pub")
        try Data("sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA test\n".utf8).write(to: pub)
        let cfg = AgentConfiguration(authorizationKey: pub.path)
        let gate = AuthorizationGate(runner: AuthFakeRunner(), configuration: cfg)
        XCTAssertEqual(try gate.configuredFingerprint(), "SHA256:hardwarefingerprint")
    }
}
