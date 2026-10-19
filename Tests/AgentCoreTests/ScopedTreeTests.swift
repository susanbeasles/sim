import XCTest
@testable import AgentCore

final class ScopedTreeTests: XCTestCase {
    func testRejectsIntermediateHostSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("host"), outside = root.appendingPathComponent("outside")
        for url in [host, outside] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(at: host.appendingPathComponent("parent"), withDestinationURL: outside)
        let tree = try ScopedTree(host)
        XCTAssertThrowsError(try tree.read("parent/file"))
        XCTAssertThrowsError(try tree.write(ReviewFile(bytes: Data("candidate".utf8), mode: 0o644), at: "parent/file"))
        XCTAssertThrowsError(try tree.remove("parent/file"))
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("file")), Data("outside".utf8))
    }

    func testCapturedBytesAndModeAreBoundAndIndependentOfLaterDiskMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tree = try ScopedTree(root)
        let original = ReviewFile(bytes: Data("authorized\r\n".utf8), mode: 0o755)
        try tree.write(original, at: "file")
        let captured = try XCTUnwrap(tree.read("file"))
        try tree.write(ReviewFile(bytes: Data("changed\n".utf8), mode: 0o644), at: "file")
        XCTAssertEqual(captured, original)
        let change = ChangedPath(status: .modified, path: "file")
        let binding = ReviewImport.binding([ReviewImport(change: change, candidate: captured, baseline: nil)])
        for altered in [ReviewFile(bytes: Data("authorized\n".utf8), mode: 0o755), ReviewFile(bytes: captured.bytes, mode: 0o644)] {
            XCTAssertNotEqual(binding, ReviewImport.binding([ReviewImport(change: change, candidate: altered, baseline: nil)]))
        }
    }
}
