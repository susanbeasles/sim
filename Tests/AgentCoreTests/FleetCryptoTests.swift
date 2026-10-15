import XCTest
@testable import AgentCore

final class FleetCryptoTests: XCTestCase {
    func testFleetKeyUnwrapRejectsInvalidCertificateIdentity() {
        XCTAssertThrowsError(try HardwareVaultCrypto().unwrapDataKey(
            wrapped: Data([1, 2, 3]),
            recipientCertificateSHA256: "not-a-hardware-identity"
        ))
    }
}
