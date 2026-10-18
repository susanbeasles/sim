import XCTest
@testable import AgentCore

final class ReviewArchiveTests: XCTestCase {
    private var budget: ReviewBudget {
        var value = ReviewBudget()
        value.fileBytes = 8
        value.totalBytes = 12
        value.files = 4
        value.depth = 3
        value.freeBytes = 0
        return value
    }

    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    // Hand-built USTAR fixture; expectations do not use the reader under test.
    private func entry(_ name: String, _ bytes: [UInt8] = [], type: UInt8 = 48, size: Int? = nil, mode: Int = 0o644) -> Data {
        var header = Data(repeating: 0, count: 512)
        func field(_ start: Int, _ text: String) { header.replaceSubrange(start..<(start + text.utf8.count), with: text.utf8) }
        field(0, name)
        field(100, String(format: "%07o", mode))
        field(124, String(format: "%011o", size ?? bytes.count))
        header[156] = type
        field(257, "ustar")
        header.replaceSubrange(148..<156, with: repeatElement(UInt8(32), count: 8))
        let checksum = header.reduce(0) { $0 + Int($1) }
        field(148, String(format: "%06o", checksum) + "\0 ")
        var out = header + Data(bytes)
        out.append(Data(repeating: 0, count: (512 - bytes.count % 512) % 512))
        return out
    }

    private func archive(_ entries: Data) -> Data { entries + Data(repeating: 0, count: 1024) }

    func testExtractsBinaryAndExecutableWithImplicitParents() throws {
        let target = root()
        defer { try? FileManager.default.removeItem(at: target) }
        try ReviewArchive(budget: budget).extract(archive(entry("dir/tool", [0, 255, 10], mode: 0o755)), to: target)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("dir/tool")), Data([0, 255, 10]))
        let attrs = try FileManager.default.attributesOfItem(atPath: target.appendingPathComponent("dir/tool").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testRejectsEachResourceLimitBeforeWriting() throws {
        let cases = [
            entry("large", size: 9),
            entry("a", [1,2,3,4,5,6,7,8]) + entry("b", [1,2,3,4,5]),
            entry("a") + entry("b") + entry("c") + entry("d") + entry("e"),
            entry("a/b/c/d"),
            entry("a/b/c") + entry("d/e")
        ]
        for bytes in cases {
            let target = root()
            XCTAssertThrowsError(try ReviewArchive(budget: budget).extract(archive(bytes), to: target))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testRejectsTraversalLinksSparseAndSpecialFiles() throws {
        let cases = [entry("../outside"), entry("/absolute"), entry("a/../../outside"), entry(".git/config"), entry(".g\u{200c}it/config"), entry(".GIT./config"), entry(".git /config"),
                     entry("x", type: 49), entry("x", type: 50), entry("x", type: 51), entry("x", type: 54), entry("x", type: 83)]
        for bytes in cases {
            let target = root()
            XCTAssertThrowsError(try ReviewArchive(budget: budget).extract(archive(bytes), to: target))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testRejectsCollisionsAndFileAncestors() throws {
        for bytes in [entry("file") + entry("FILE"), entry("dir") + entry("dir/child"), entry("a/b") + entry("a")] {
            let target = root()
            XCTAssertThrowsError(try ReviewArchive(budget: budget).extract(archive(bytes), to: target))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testRejectsMalformedAndInterruptedArchive() throws {
        var corrupt = entry("file", [1])
        corrupt[0] ^= 1
        for bytes in [archive(corrupt), entry("file", size: 2), Data(repeating: 0, count: 512), Data()] {
            let target = root()
            XCTAssertThrowsError(try ReviewArchive(budget: budget).extract(bytes, to: target))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testRemovesPartialExtractionWhenSpaceIsInsufficient() throws {
        let target = root()
        var limits = budget
        limits.freeBytes = 1 << 60
        XCTAssertThrowsError(try ReviewArchive(budget: limits).extract(archive(entry("file", [1])), to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testBoundsLogicalSizeOfSparseBaseline() throws {
        let target = root()
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let file = target.appendingPathComponent("sparse")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1024 * 1024 * 1024)
        try handle.close()
        XCTAssertThrowsError(try budget.validate(tree: target))
    }
    func testRejectsInvalidUTF8PathWithoutRenamingIt() throws {
        var bytes = entry("x")
        bytes[0] = 255
        bytes.replaceSubrange(148..<156, with: repeatElement(UInt8(32), count: 8))
        let checksum = bytes.prefix(512).reduce(0) { $0 + Int($1) }
        bytes.replaceSubrange(148..<156, with: (String(format: "%06o", checksum) + "\0 ").utf8)
        let target = root()
        defer { try? FileManager.default.removeItem(at: target) }
        XCTAssertThrowsError(try ReviewArchive(budget: budget).extract(archive(bytes), to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testRefusesExistingDestinationWithoutChangingIt() throws {
        let target = root()
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("existing"))
        XCTAssertThrowsError(try ReviewArchive(budget: budget).extract(archive(entry("new")), to: target))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("existing"), encoding: .utf8), "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("new").path))
    }

}
