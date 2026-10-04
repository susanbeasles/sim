import XCTest
@testable import AgentCore

final class StateStoreTests: XCTestCase {
    func testRoundTripAndActiveWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(stateRoot: root.appendingPathComponent("state"), configRoot: root.appendingPathComponent("config"))
        let store = try StateStore(paths: paths)
        let ws = WorkspaceRecord(
            name: "demo-codex", sandboxName: "demo-codex", repoPath: "/tmp/demo", repoName: "demo",
            vendor: .codex, branch: "main", sourceState: .clean, sandboxHome: "/home/agent",
            targetPath: "/home/agent/code/demo", baselineTemplate: "agent-baseline/demo:initial"
        )
        try await store.save(ws)
        try await store.setActive(ws.name)
        let loaded = try await store.load(ws.name)
        let active = try await store.active()
        XCTAssertEqual(loaded.id, ws.id)
        XCTAssertEqual(loaded.name, ws.name)
        XCTAssertEqual(loaded.repoPath, ws.repoPath)
        XCTAssertEqual(loaded.vendor, ws.vendor)
        XCTAssertEqual(active, ws.name)
    }
}
