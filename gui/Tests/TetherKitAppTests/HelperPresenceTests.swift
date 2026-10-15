import XCTest
import TetherKitIPC
@testable import TetherKitApp

final class HelperPresenceTests: XCTestCase {
    @MainActor func testInstalledSleepingHelperDoesNotSendXPC() async {
        let client = DeviceHelper()
        client.installed = .init(userID: 501, codeHash: String(repeating: "a", count: 40),
                                 revision: HelperConstants.protocolRevision, version: "0.1.5")
        let model = AppModel(client: client)
        let result = await model.refreshHelperAvailability()
        XCTAssertEqual(result?.isRunning, false)
        XCTAssertTrue(model.helperAvailability.isAvailable)
        XCTAssertFalse(model.helperNeedsTrustRecovery)
        XCTAssertFalse(model.helperIsRunning)
        XCTAssertEqual(client.presenceReads, 1)
        XCTAssertTrue(client.operations.isEmpty)
    }

    @MainActor func testExistingHelperIsDiscoveredWithoutStartingAnother() async {
        let client = DeviceHelper()
        client.installed = .init(userID: 501, codeHash: String(repeating: "a", count: 40),
                                 revision: HelperConstants.protocolRevision, version: "0.1.5")
        var status = SessionStatus.idle
        status.runState = .running
        client.presence = .init(isRunning: true, lastStatus: status)
        let model = AppModel(client: client)
        let result = await model.refreshHelperAvailability()
        XCTAssertTrue(model.helperIsRunning)
        XCTAssertEqual(result?.lastStatus?.runState, .running)
        XCTAssertTrue(client.operations.isEmpty)
    }

    @MainActor func testOldInstallationIsNotWokenForVersionProbe() async {
        let client = DeviceHelper()
        client.installed = .init(userID: 501, codeHash: String(repeating: "a", count: 40),
                                 revision: 4, version: "0.1.5")
        let model = AppModel(client: client)
        let result = await model.refreshHelperAvailability()
        XCTAssertNil(result)
        XCTAssertEqual(model.helperAvailability,
                       .outdated(installed: 4, expected: HelperConstants.protocolRevision))
        XCTAssertEqual(client.presenceReads, 0)
        XCTAssertTrue(client.operations.isEmpty)
    }
}
