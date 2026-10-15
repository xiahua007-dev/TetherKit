import XCTest
import TetherKitIPC
@testable import TetherKitHelper

private final class UsageSession: HelperSession {
    private var value = SessionStatus.idle
    func start() throws { value.runState = .starting }
    func stop() {
        value.runState = .stopped
        // 模拟停机完成后最后一批计数，不能只在 stop 之前采样。
        value.rxBytes = 1234
        value.txBytes = 56
    }
    func status() -> SessionStatus { value }
    func drainNotices() -> [String] { [] }
}

final class UsageLifecycleTests: XCTestCase {
    func testStopSavesFinalCountersBeforeReplyWithoutUIOrTimer() {
        let session = UsageSession()
        var saved: [DailyUsage] = []
        let service = HelperService(writeUsage: { saved = $0 }, makeSession: { _ in session })
        var configuration = SessionConfiguration()
        let phone = DeviceDescriptor(vendorID: 1, productID: 2, busNumber: 0, deviceAddress: 1,
                                     manufacturer: "", product: "", serial: UUID().uuidString,
                                     summary: "", usedAndroidQuirk: false)
        configuration.usageDevice = phone
        let started = expectation(description: "连接受理")
        service.start(configuration: configuration) { message, _ in
            XCTAssertNil(message)
            started.fulfill()
        }
        wait(for: [started], timeout: 2)
        let stopped = expectation(description: "最终用量保存后回复")
        service.stop { message, _ in
            XCTAssertNil(message)
            let entry = saved.first { $0.deviceKey == TrafficUsage.key(for: phone) }
            XCTAssertEqual(entry?.downloaded, 1234)
            XCTAssertEqual(entry?.uploaded, 56)
            XCTAssertEqual(service.snapshot().todayUsage, entry)
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 2)
        service.shutdown()
    }
}
