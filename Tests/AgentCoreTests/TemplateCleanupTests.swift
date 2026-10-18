import XCTest
@testable import AgentCore

private final class TemplateRunner: ProcessRunning, @unchecked Sendable {
    var present = false
    var failSave = false
    var failRemoval = false
    var retain = false
    var failListing = false
    func capture(_ executable: String, _ args: [String], environment: [String: String]?) throws -> ProcessResult {
        var status: Int32 = 0
        var output = ""
        switch Array(args.prefix(2)) {
        case ["template", "save"]: present = true; if failSave { status = 1 }
        case ["template", "rm"]:
            XCTAssertEqual(args, ["template", "rm", "--force", "stake:test"])
            if failRemoval { status = 1 } else if !retain { present = false }
        case ["template", "ls"]:
            if failListing { status = 1 }
            output = present ? "stake:test\n" : ""
        default: XCTFail("unexpected command")
        }
        return ProcessResult(status: status, stdout: Data(output.utf8), stderr: Data())
    }
    func interactive(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> Int32 { 0 }
}

final class TemplateCleanupTests: XCTestCase {
    func testRemovesTemplateOnSuccess() throws {
        let runner = TemplateRunner()
        let value = try SBXClient(runner: runner).withTemplate(name: "sandbox", tag: "stake:test", output: "/tmp/export") {
            XCTAssertTrue(runner.present)
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertFalse(runner.present)
    }
    func testRemovesTemplateOnFailure() throws {
        for failSave in [false, true] {
            let runner = TemplateRunner()
            runner.failSave = failSave
            XCTAssertThrowsError(try SBXClient(runner: runner).withTemplate(name: "sandbox", tag: "stake:test", output: "/tmp/export") {
                if failSave { XCTFail("must not encrypt a failed export") }
                throw AgentError.trustFailure("encryption failed")
            })
            XCTAssertFalse(runner.present)
        }
    }
    func testCleanupFailureIdentifiesRecoveryTagAndOriginalError() throws {
        for mode in 0..<3 {
            let runner = TemplateRunner()
            runner.failRemoval = mode == 0
            runner.retain = mode == 1
            runner.failListing = mode == 2
            XCTAssertThrowsError(try SBXClient(runner: runner).withTemplate(name: "sandbox", tag: "stake:test", output: "/tmp/export") {
                throw AgentError.trustFailure("encryption failed")
            }) {
                let message = String(describing: $0)
                XCTAssertTrue(message.contains("stake:test"))
                XCTAssertTrue(message.contains("encryption failed"))
                XCTAssertTrue(message.contains("plaintext"))
            }
        }
    }
}

private final class StakeRunner: ProcessRunning, @unchecked Sendable {
    var template: String?
    var saved = false
    func capture(_ executable: String, _ args: [String], environment: [String: String]?) throws -> ProcessResult {
        var output = ""
        if executable == "/usr/bin/ssh-keygen" {
            output = "256 SHA256:test key (ED25519-SK)\n"
        } else if args == ["ls"] {
            output = "demo codex stopped\n"
        } else if args.starts(with: ["template", "save"]) {
            template = args[3]
            saved = true
        } else if args.starts(with: ["template", "rm", "--force"]) {
            XCTAssertEqual(args.last, template)
            template = nil
        } else if args == ["template", "ls", "--quiet"] {
            output = template ?? ""
        } else if args.first != "exec" && args != ["stop", "demo"] {
            XCTFail("unexpected stake command: \(args)")
        }
        return ProcessResult(status: 0, stdout: Data(output.utf8), stderr: Data())
    }
    func interactive(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> Int32 { 0 }
}

extension TemplateCleanupTests {
    func testStakeRemovesTemplateWhenPIVIdentityIsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config"))
        let runner = StakeRunner()
        let workspaceService = try WorkspaceService(paths: paths, runner: runner)
        let pub = root.appendingPathComponent("test.pub")
        try Data("sk-ssh-ed25519@openssh.com test\n".utf8).write(to: pub)
        try await workspaceService.store.saveConfiguration(AgentConfiguration(
            authorizationKey: pub.path, pivCertificateSHA256: "unavailable-test-certificate"
        ))
        let vault = try VaultService(paths: paths, workspaceService: workspaceService, runner: runner)
        let workspace = WorkspaceRecord(
            name: "demo", sandboxName: "demo", repoPath: "/tmp/demo", repoName: "demo",
            vendor: .codex, branch: "main", sourceState: .clean, sandboxHome: "/home/agent",
            targetPath: "/home/agent/code/demo", baselineTemplate: "baseline:demo"
        )
        do {
            _ = try await vault.stake(workspace: workspace, tag: "test")
            XCTFail("missing PIV identity must fail")
        } catch {
            XCTAssertTrue(runner.saved, "must reach the post-save failure path")
            XCTAssertNil(runner.template, "failed stake must leave no plaintext template")
        }
    }
}
