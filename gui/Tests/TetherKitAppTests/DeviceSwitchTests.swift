import XCTest
import TetherKitIPC
@testable import TetherKitApp

@MainActor
final class DeviceHelper: HelperConnection {
    var devices: [DeviceDescriptor] = []
    var operations: [String] = []
    var configurations: [SessionConfiguration] = []
    var listFails = false
    var stopFails = false
    var startFails = false
    var onStop: (() -> Void)?
    var installed: HelperInstallation?
    var presence = HelperObservation(isRunning: false, lastStatus: nil)
    var presenceReads = 0
    var currentStatus = SessionStatus.idle
    func installation() async throws -> HelperInstallation? { installed }
    func observation() async -> HelperObservation { presenceReads += 1; return presence }
    func switchSession(authorization: Data, configuration: SessionConfiguration) async throws {
        try await stopSession(authorization: authorization)
        try await startSession(authorization: authorization, configuration: configuration)
    }
    enum Failure: Error { case simulated }
    func listDevices() async throws -> [DeviceDescriptor] {
        operations.append("list")
        if listFails { throw Failure.simulated }
        return devices
    }
    func stopSession(authorization: Data) async throws {
        operations.append("stop")
        if stopFails { throw Failure.simulated }
        currentStatus = .idle
        onStop?()
    }
    func startSession(authorization: Data, configuration: SessionConfiguration) async throws {
        operations.append("start")
        if startFails { throw Failure.simulated }
        configurations.append(configuration)
    }
    func helperVersion() async throws -> String { throw Failure.simulated }
    func environment() async throws -> EnvironmentReport { throw Failure.simulated }
    func sessionStatus() async throws -> SessionStatus { currentStatus }
    func queryNetwork(interface: String) async throws -> NetworkState { throw Failure.simulated }
    func drainFeed() async throws -> HelperFeed { throw Failure.simulated }
    func setLanguage(_ language: Language) async {}
    func applyNetwork(authorization: Data, interface: String,
                      configuration: NetworkConfiguration) async throws { throw Failure.simulated }
}

final class DeviceSwitchTests: XCTestCase {
    private func device(_ address: UInt8) -> DeviceDescriptor {
        .init(vendorID: 1, productID: 2, busNumber: 1, deviceAddress: address,
              manufacturer: "", product: "Phone \(address)", serial: "", summary: "Device \(address)",
              usedAndroidQuirk: false)
    }

    @MainActor private func connectedModel(_ client: DeviceHelper) async -> AppModel {
        let model = AppModel(client: client)
        var status = SessionStatus.idle
        status.runState = .running
        status.connectionID = UUID()
        status.deviceDescription = device(1).summary
        model.apply(status: status)
        client.currentStatus = status
        client.presence = .init(isRunning: true, lastStatus: status)
        await model.refreshDevices()
        return model
    }

    @MainActor func testRefreshDiscoversNewDeviceWithoutTouchingConnection() async {
        let client = DeviceHelper()
        client.devices = [device(2), device(1)]
        let model = await connectedModel(client)
        XCTAssertEqual(model.devices.count, 2)
        XCTAssertEqual(model.selectedDevice?.id, device(1).id)
        XCTAssertFalse(model.canSwitchDevice)
        XCTAssertEqual(model.status.runState, .running)
        XCTAssertEqual(client.operations, ["list"])
        model.selectedDeviceID = device(2).id
        XCTAssertTrue(model.canSwitchDevice)
        XCTAssertEqual(client.operations, ["list"])
    }

    @MainActor func testSwitchStopsThenStartsFixedTargetAndNetworkSnapshot() async {
        let client = DeviceHelper()
        client.devices = [device(1), device(2)]
        let model = await connectedModel(client)
        model.networkConfiguration = .dhcp
        model.selectedDeviceID = device(2).id
        client.onStop = {
            model.selectedDeviceID = self.device(1).id
            model.networkConfiguration = .init(mode: .manual, address: "invalid")
        }
        await model.switchDevice()
        XCTAssertEqual(client.operations, ["list", "list", "stop", "start"])
        XCTAssertEqual(client.configurations.first?.deviceAddress, 2)
        XCTAssertEqual(client.configurations.first?.vendorID, 1)
        XCTAssertEqual(client.configurations.first?.networkConfiguration, .dhcp)
        XCTAssertEqual(model.selectedDeviceID, device(2).id)
        XCTAssertEqual(model.status.runState, .starting)
        await model.switchDevice()
        XCTAssertEqual(client.operations, ["list", "list", "stop", "start"])
    }

    @MainActor func testMissingTargetKeepsExistingConnection() async {
        let client = DeviceHelper()
        client.devices = [device(1), device(2)]
        let model = await connectedModel(client)
        model.selectedDeviceID = device(2).id
        client.devices = [device(1)]
        await model.switchDevice()
        XCTAssertEqual(client.operations, ["list", "list"])
        XCTAssertEqual(model.status.runState, .running)
        XCTAssertNotNil(model.alertMessage)
    }

    @MainActor func testStopFailureNeverStartsAnotherDevice() async {
        let client = DeviceHelper()
        client.devices = [device(1), device(2)]
        let model = await connectedModel(client)
        model.selectedDeviceID = device(2).id
        client.stopFails = true
        await model.switchDevice()
        XCTAssertEqual(client.operations, ["list", "list", "stop"])
        XCTAssertEqual(model.status.runState, .running)
        XCTAssertNotNil(model.alertMessage)
    }

    @MainActor func testInvalidNetworkDraftDoesNotInterruptConnection() async {
        let client = DeviceHelper()
        client.devices = [device(1), device(2)]
        let model = await connectedModel(client)
        model.selectedDeviceID = device(2).id
        model.networkConfiguration = .init(mode: .manual, address: "invalid")
        await model.switchDevice()
        XCTAssertEqual(client.operations, ["list"])
        XCTAssertEqual(model.status.runState, .running)
    }

    @MainActor func testRefreshFailureKeepsPreviousListAndReportsError() async {
        let client = DeviceHelper()
        client.devices = [device(1), device(2)]
        let model = await connectedModel(client)
        model.selectedDeviceID = device(2).id
        client.listFails = true
        await model.refreshDevices()
        XCTAssertEqual(model.devices.count, 2)
        XCTAssertEqual(model.selectedDeviceID, device(2).id)
        XCTAssertNotNil(model.alertMessage)
        XCTAssertFalse(model.isRefreshingDevices)
    }
    @MainActor func testStartFailureDoesNotClaimOldConnectionStillRuns() async {
        let client = DeviceHelper()
        client.devices = [device(1), device(2)]
        let model = await connectedModel(client)
        model.selectedDeviceID = device(2).id
        client.startFails = true
        await model.switchDevice()
        XCTAssertEqual(client.operations, ["list", "list", "stop", "start"])
        XCTAssertEqual(model.status.runState, .idle)
        XCTAssertNotNil(model.alertMessage)
        XCTAssertFalse(model.isBusy)
    }

    @MainActor func testFreshHelperCannotErasePreviouslyReadDeviceName() async {
        let client = DeviceHelper()
        var known = device(1)
        known.manufacturer = "HONOR"
        known.serial = "serial"
        client.devices = [known]
        let model = await connectedModel(client)
        var unnamed = known
        unnamed.manufacturer = ""
        unnamed.product = ""
        unnamed.serial = ""
        client.devices = [unnamed]
        await model.refreshDevices()
        XCTAssertEqual(model.devices.first?.product, known.product)
        XCTAssertEqual(model.devices.first?.manufacturer, known.manufacturer)
        XCTAssertEqual(model.devices.first?.serial, known.serial)
        // 设备确实离场后，不将旧名称带给重用地址的新设备。
        client.devices = []
        await model.refreshDevices()
        client.devices = [unnamed]
        await model.refreshDevices()
        XCTAssertEqual(model.devices.first?.product, "")
    }

}
