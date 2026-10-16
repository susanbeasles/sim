import XCTest
@testable import AgentCore

final class DigestTests: XCTestCase {
    func testSHA256KnownVector() {
        XCTAssertEqual(
            Digest.sha256("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testStreamingFileDigestMatchesInMemoryDigest() throws {
        var data = Data()
        for i in 0..<(2 * 1024 * 1024 + 137) { data.append(UInt8(truncatingIfNeeded: i &* 31)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        XCTAssertEqual(try Digest.sha256(file: url, chunkBytes: 8191), Digest.sha256(data))
    }
}
