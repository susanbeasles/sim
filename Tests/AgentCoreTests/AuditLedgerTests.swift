import XCTest
@testable import AgentCore

final class AuditLedgerTests: XCTestCase {
    func testHashChainVerifiesAndDetectsTampering() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("audit.jsonl")
        let ledger = AuditLedger(file: file)
        _ = try await ledger.append(workspace: "x", kind: "one", detail: "alpha")
        let last = try await ledger.append(workspace: "x", kind: "two", detail: "beta")
        let verified = try await ledger.verify()
        XCTAssertEqual(verified?.digest, last.digest)

        var bytes = try Data(contentsOf: file)
        let needle = Data("alpha".utf8)
        if let range = bytes.range(of: needle) {
            bytes.replaceSubrange(range, with: Data("ALPHA".utf8))
            try bytes.write(to: file)
        } else {
            XCTFail("fixture did not contain expected payload")
        }
        do {
            _ = try await ledger.verify()
            XCTFail("tampered ledger should fail")
        } catch { }
    }
}
