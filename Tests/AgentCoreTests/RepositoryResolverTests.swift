import XCTest
@testable import AgentCore

private struct FakeRunner: ProcessRunning {
    let root: String
    func capture(_ executable: String, _ arguments: [String], environment: [String : String]?) throws -> ProcessResult {
        ProcessResult(status: 0, stdout: Data((root + "\n").utf8), stderr: Data())
    }
    func interactive(_ executable: String, _ arguments: [String], environment: [String : String]?) throws -> Int32 { 0 }
}

final class RepositoryResolverTests: XCTestCase {
    func testBareNameResolvesUnderCode() throws {
        let resolver = RepositoryResolver(runner: FakeRunner(root: "/Users/test/code/foo"), home: "/Users/test")
        XCTAssertEqual(try resolver.resolve("foo", cwd: "/tmp"), "/Users/test/code/foo")
    }
}
