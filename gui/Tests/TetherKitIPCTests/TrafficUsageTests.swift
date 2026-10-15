import XCTest
@testable import TetherKitIPC

final class TrafficUsageTests: XCTestCase {
    func testDailyTotalsReconnectAndIndependentDevices() {
        let ledger = UsageLedger(records: [])
        ledger.begin(deviceKey: "phone-a")
        XCTAssertEqual(ledger.sample(rx: 100, tx: 20, day: "2026-10-15")?.total, 120)
        XCTAssertEqual(ledger.sample(rx: 150, tx: 30, day: "2026-10-15")?.total, 180)
        ledger.begin(deviceKey: "phone-a")
        XCTAssertEqual(ledger.sample(rx: 10, tx: 2, day: "2026-10-15")?.total, 192)
        ledger.begin(deviceKey: "phone-b")
        XCTAssertEqual(ledger.sample(rx: 7, tx: 3, day: "2026-10-15")?.total, 10)
        XCTAssertEqual(ledger.records.count, 2)
    }

    func testMidnightOnlyAddsNewBytesAndClockReturningDoesNotOverwrite() {
        let ledger = UsageLedger(records: [])
        ledger.begin(deviceKey: "phone")
        ledger.sample(rx: 100, tx: 20, day: "2026-10-15")
        XCTAssertTrue(ledger.needsDayFlush("2026-10-16"))
        XCTAssertEqual(ledger.sample(rx: 110, tx: 22, day: "2026-10-16")?.total, 12)
        XCTAssertEqual(ledger.sample(rx: 120, tx: 24, day: "2026-10-15")?.total, 132)
    }

    func testSaveFrequencyIdleAndFinalFlush() throws {
        let ledger = UsageLedger(records: [])
        var saves = 0
        let write: ([DailyUsage]) -> Void = { _ in saves += 1 }
        ledger.begin(deviceKey: "phone")
        try ledger.saveIfNeeded(now: 0, write: write)
        XCTAssertEqual(saves, 0)
        ledger.sample(rx: 10, tx: 0, day: "2026-10-15")
        try ledger.saveIfNeeded(now: 1, write: write)
        ledger.sample(rx: 20, tx: 0, day: "2026-10-15")
        try ledger.saveIfNeeded(now: 30, write: write)
        XCTAssertEqual(saves, 1)
        try ledger.saveIfNeeded(now: 61, write: write)
        XCTAssertEqual(saves, 2)
        try ledger.saveIfNeeded(now: 122, write: write)
        XCTAssertEqual(saves, 2)
        ledger.sample(rx: 25, tx: 0, day: "2026-10-15")
        try ledger.saveIfNeeded(now: 123, force: true, write: write)
        XCTAssertEqual(saves, 3)
        let restored = UsageLedger(records: ledger.records)
        restored.begin(deviceKey: "phone")
        XCTAssertEqual(restored.sample(rx: 5, tx: 0, day: "2026-10-15")?.total, 30)
    }

    func testUnknownIdentityDoesNotMergeAndDeviceKeySurvivesReplug() {
        var phone = DeviceDescriptor(vendorID: 1, productID: 2, busNumber: 0,
                                    deviceAddress: 1, manufacturer: "", product: "", serial: "abc",
                                    summary: "", usedAndroidQuirk: false)
        let key = TrafficUsage.key(for: phone)
        phone.deviceAddress = 7
        XCTAssertEqual(key, TrafficUsage.key(for: phone))
        phone.serial = "different"
        XCTAssertNotEqual(key, TrafficUsage.key(for: phone))
        phone.serial = ""
        XCTAssertNil(TrafficUsage.key(for: phone))
        let ledger = UsageLedger(records: [])
        ledger.begin(deviceKey: nil)
        XCTAssertNil(ledger.sample(rx: 100, tx: 100, day: "2026-10-15"))
        XCTAssertTrue(ledger.records.isEmpty)
    }
}
