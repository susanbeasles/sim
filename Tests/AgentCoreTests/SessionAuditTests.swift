import XCTest
@testable import AgentCore

private final class SessionRunner: ProcessRunning, @unchecked Sendable {
    let after: String
    let status: Int32
    private let requireRefresh: Bool
    private var refreshed = false
    private let lock = NSLock()
    private var session: String?

    init(after: String, status: Int32 = 0, requireRefresh: Bool = false) {
        self.after = after
        self.status = status
        self.requireRefresh = requireRefresh
    }

    func capture(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> ProcessResult {
        lock.lock()
        defer { lock.unlock() }
        if arguments.contains(where: { $0.contains("install -d -m 0700") && $0.contains("/usr/local/libexec/agent-guest/audit-verify") }) {
            refreshed = true
        }
        if arguments.contains("/usr/local/libexec/agent-guest/audit-verify") {
            if requireRefresh && !refreshed {
                // A pre-upgrade guest ignores new options and returns only HEAD.
                return ProcessResult(status: 0, stdout: Data(String(repeating: "a", count: 64).utf8), stderr: Data())
            }
            if arguments.contains("--snapshot") {
                return ProcessResult(status: 0, stdout: Data("2 \(String(repeating: "a", count: 64))\n".utf8), stderr: Data())
            }
            let expected = ["--session", "worker", session ?? "missing", "2", String(repeating: "a", count: 64)]
            guard Array(arguments.suffix(5)) == expected else {
                throw AgentError.unsafe("verification was not bound to the launched session and prior head")
            }
            return ProcessResult(status: status, stdout: Data(after.utf8), stderr: Data("verification failed".utf8))
        }
        // Existing unchecked HEAD read returns a valid-looking but stale digest.
        let output = arguments.contains(where: { $0.contains("cat /var/lib/agent-audit/HEAD") }) ? String(repeating: "a", count: 64) : ""
        return ProcessResult(status: 0, stdout: Data(output.utf8), stderr: Data())
    }

    func interactive(_ executable: String, _ arguments: [String], environment: [String: String]?) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if let index = arguments.firstIndex(of: "--session"), arguments.count > index + 3 {
            guard UUID(uuidString: arguments[index + 1]) != nil,
                  arguments[index + 2] == "2", arguments[index + 3] == String(repeating: "a", count: 64) else {
                throw AgentError.unsafe("launch was not bound to the host snapshot")
            }
            session = arguments[index + 1]
        }
        return 7
    }
}

final class SessionAuditTests: XCTestCase {
    private func fixture(after: String, status: Int32 = 0, requireRefresh: Bool = false, _ body: (WorkspaceService, WorkspaceRecord, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(stateRoot: root, configRoot: root.appendingPathComponent("config"))
        let service = try WorkspaceService(paths: paths, runner: SessionRunner(after: after, status: status, requireRefresh: requireRefresh))
        let workspace = WorkspaceRecord(name: "test", sandboxName: "test", repoPath: "/repo", repoName: "repo", vendor: .claude, branch: "main", sourceState: .clean, sandboxHome: "/home/agent", targetPath: "/repo", baselineTemplate: "baseline")
        try await body(service, workspace, paths.audit.appendingPathComponent("control.jsonl"))
    }

    func testFullAuditRejectsStaleOrMalformedHeads() async throws {
        for after in ["2 \(String(repeating: "a", count: 64))", "4 \(String(repeating: "a", count: 64))", "3 \(String(repeating: "b", count: 64))", "", "4 invalid"] {
            try await fixture(after: after) { service, workspace, ledger in
                do {
                    _ = try await service.runVendor(workspace, vendor: .claude, worker: "worker", args: [])
                    XCTFail("full audit accepted invalid evidence: \(after)")
                } catch { }
                let events = try String(contentsOf: ledger, encoding: .utf8)
                XCTAssertFalse(events.contains("session.end"))
                XCTAssertTrue(events.contains("session.audit.failed"))
            }
        }
    }

    func testFullAuditRequiresSuccessfulGuestVerification() async throws {
        try await fixture(after: "4 \(String(repeating: "b", count: 64))", status: 2) { service, workspace, ledger in
            do {
                _ = try await service.runVendor(workspace, vendor: .claude, worker: "worker", args: [])
                XCTFail("failed verification must fail the host operation")
            } catch { }
            let events = try String(contentsOf: ledger, encoding: .utf8)
            XCTAssertFalse(events.contains("session.end"))
        }
    }

    func testVerifiedCompletionPreservesVendorExitCode() async throws {
        try await fixture(after: "4 \(String(repeating: "b", count: 64))") { service, workspace, ledger in
            let code = try await service.runVendor(workspace, vendor: .claude, worker: "worker", args: [])
            XCTAssertEqual(code, 7)
            let events = try String(contentsOf: ledger, encoding: .utf8)
            XCTAssertTrue(events.contains("session.end"))
            XCTAssertTrue(events.contains("guestAuditSequence=4"))
            XCTAssertTrue(events.contains("guestSession="))
        }
    }

    func testExistingWorkspaceRefreshesHelpersBeforeVerification() async throws {
        try await fixture(after: "4 \(String(repeating: "b", count: 64))", requireRefresh: true) { service, workspace, ledger in
            let code = try await service.runVendor(workspace, vendor: .claude, worker: "worker", args: [])
            XCTAssertEqual(code, 7)
            XCTAssertTrue(try String(contentsOf: ledger, encoding: .utf8).contains("session.end"))
        }
    }
}
