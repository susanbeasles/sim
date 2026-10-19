import XCTest
@testable import AgentCore

final class TemplateExportBudgetTests: XCTestCase {
    func testRejectsUnknownOversizedSharedAndFullFilesystems() throws {
        let root = URL(fileURLWithPath: "/bounded-export")
        let state = URL(fileURLWithPath: "/state")
        for mode in 0..<7 {
            let budget = TemplateExportBudget(attributes: { url in
                if mode == 0 { return [:] }
                return [
                    .systemSize: NSNumber(value: mode == 1 ? UInt64.max : mode == 2 ? 0 : UInt64(TemplateExportBudget.maximumBytes)),
                    .systemFreeSize: NSNumber(value: mode == 3 ? 0 : TemplateExportBudget.minimumFreeBytes),
                    .systemNumber: NSNumber(value: mode == 6 ? (url == URL(fileURLWithPath: "/") ? 1 : 2) : (mode == 4 || url != root ? 1 : 2))
                ]
            })
            if mode == 5 { XCTAssertNoThrow(try budget.checkDestination(root, stateRoot: state)) }
            else { XCTAssertThrowsError(try budget.checkDestination(root, stateRoot: state)) }
        }
    }

    func testRejectsLinkedAndOversizedArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("archive")
        try Data([1]).write(to: file)
        XCTAssertNoThrow(try TemplateExportBudget().checkArchive(file))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try TemplateExportBudget().checkArchive(link))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(TemplateExportBudget.maximumBytes) + 1)
        try handle.close()
        XCTAssertThrowsError(try TemplateExportBudget().checkArchive(file))
    }
}
