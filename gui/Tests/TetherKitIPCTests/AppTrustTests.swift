import XCTest
@testable import TetherKitIPC

final class AppTrustTests: XCTestCase {
    func testTrustRecordRoundTripAndRequirement() throws {
        let hash = String(repeating: "a1", count: 20)
        let trust = AppTrust(userID: 501, codeHash: hash)
        let decoded = try JSONDecoder().decode(AppTrust.self, from: JSONEncoder().encode(trust))
        XCTAssertTrue(decoded.isValid)
        XCTAssertEqual(decoded.requirement, "cdhash H\"\(hash)\"")
    }

    func testMalformedIdentityCannotBecomeRequirement() {
        for hash in ["", "abcd", String(repeating: "g", count: 40),
                     String(repeating: "a", count: 39) + "\""] {
            XCTAssertNil(AppTrust(userID: 501, codeHash: hash).requirement)
        }
        XCTAssertNil(AppTrust(userID: 0, codeHash: String(repeating: "a", count: 40)).requirement)
    }

    func testUnsignedOrMissingAppCannotBeEnrolled() {
        XCTAssertThrowsError(try AppTrust.hash(of: URL(fileURLWithPath: "/nonexistent/TetherKit.app")))
    }
}
