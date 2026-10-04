import XCTest
@testable import AgentCore

final class ConfigurationCompatibilityTests: XCTestCase {
    func testOldConfigurationDecodesWithoutPIVField() throws {
        let json = #"{"authorizationKey":"~/.ssh/id_yubikey","authorizationIdentity":"agent-control","codeRoot":"~/code"}"#
        let cfg = try JSONDecoder().decode(AgentConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.authorizationKey, "~/.ssh/id_yubikey")
        XCTAssertEqual(cfg.authorizationIdentity, "agent-control")
        XCTAssertEqual(cfg.codeRoot, "~/code")
        XCTAssertNil(cfg.pivCertificateSHA256)
    }
}
