import XCTest
import TetherKitIPC
@testable import TetherKitApp

final class NetworkPreferencesTests: XCTestCase {
    @MainActor func testOnlySuccessfulValidConfigurationSurvivesRestart() {
        let suite = "TetherKitTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(networkDefaults: defaults)
        XCTAssertEqual(model.networkConfiguration, .dhcp)
        let valid = NetworkConfiguration(mode: .manual, address: "192.168.42.2",
                                         router: "192.168.42.1")
        model.rememberNetworkConfiguration(valid)
        model.networkConfiguration = valid
        model.networkConfiguration.address = "invalid"
        XCTAssertEqual(AppModel(networkDefaults: defaults).networkConfiguration, valid)
        model.rememberNetworkConfiguration(model.networkConfiguration)
        model.rememberNetworkConfiguration(.init(mode: .none))
        XCTAssertEqual(AppModel(networkDefaults: defaults).networkConfiguration, valid)
    }

    @MainActor func testHelperSuccessPersistsSnapshotInsteadOfEditedDraft() {
        let suite = "TetherKitTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(networkDefaults: defaults)
        model.networkConfiguration = .init(mode: .manual, address: "invalid")
        var status = SessionStatus.idle
        status.connectionID = UUID()
        status.networkPhase = .ready
        let successful = NetworkConfiguration(mode: .manual, address: "192.168.42.2")
        status.appliedConfiguration = successful
        model.apply(status: status)
        XCTAssertEqual(model.networkConfiguration.address, "invalid")
        XCTAssertEqual(AppModel(networkDefaults: defaults).networkConfiguration, successful)
    }
    @MainActor func testHelperSavedConfigurationRestoresAfterOfflineSuccess() {
        let suite = "TetherKitTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(networkDefaults: defaults)
        let saved = NetworkConfiguration(mode: .manual, address: "192.168.42.2")
        var status = SessionStatus.idle
        status.savedConfiguration = saved
        model.apply(status: status)
        XCTAssertEqual(model.networkConfiguration, saved)
        XCTAssertEqual(AppModel(networkDefaults: defaults).networkConfiguration, saved)
    }

}
