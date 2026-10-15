import Foundation
import XCTest
import TetherKitIPC
@testable import TetherKitHelper

private final class MemorySession: HelperSession {
    private let lock = NSLock()
    private var snapshot = SessionStatus.idle
    func start() throws { set(.starting) }
    func stop() { set(.stopped) }
    func drainNotices() -> [String] { [] }
    func status() -> SessionStatus { lock.withLock { snapshot } }
    func set(_ state: RunState) {
        lock.withLock {
            snapshot.runState = state
            snapshot.systemInterface = state == .running ? "feth123" : ""
        }
    }
}

final class ConnectionTests: XCTestCase {
    private func start(_ service: HelperService) {
        let accepted = expectation(description: "请求受理")
        service.start(configuration: .init()) { message, _ in
            XCTAssertNil(message)
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 2)
    }

    func testWaitsForInterfaceAndAppliesOnceWithoutStatusPolling() {
        let session = MemorySession()
        let applied = expectation(description: "自动配网")
        applied.assertForOverFulfill = true
        let service = HelperService(makeSession: { _ in session }, applyConfiguration: { config, name in
            XCTAssertEqual(session.status().runState, .running)
            XCTAssertEqual(config, .dhcp)
            XCTAssertEqual(name, "feth123")
            applied.fulfill()
        }, queryConfiguration: { _ in
            var state = NetworkState.empty
            state.hasAddress = true
            state.address = "192.168.42.2"
            return state
        })
        start(service)
        session.set(.running)
        wait(for: [applied], timeout: 2)
        service.shutdown()
    }

    func testDisconnectBeforeInterfaceReadyCancelsOldAttempt() {
        let session = MemorySession()
        let unexpected = expectation(description: "禁止迟到配网")
        unexpected.isInverted = true
        let service = HelperService(makeSession: { _ in session }, applyConfiguration: { _, _ in
            unexpected.fulfill()
        })
        start(service)
        let stopped = expectation(description: "断开")
        service.stop { message, _ in XCTAssertNil(message); stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        session.set(.running)
        wait(for: [unexpected], timeout: 0.3)
    }

    func testCannotConfigureUnownedInterface() {
        let session = MemorySession()
        let service = HelperService(makeSession: { _ in session })
        start(service)
        session.set(.running)
        let rejected = expectation(description: "拒绝其他网卡")
        service.applyOwnedNetwork(interface: "en0", configuration: .dhcp) { message, _ in
            XCTAssertNotNil(message)
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 2)
        service.shutdown()
    }

    func testConfigurationFailureKeepsRetryAvailable() {
        let session = MemorySession()
        let failed = expectation(description: "配网失败")
        let service = HelperService(makeSession: { _ in session }, applyConfiguration: { _, _ in
            failed.fulfill()
            throw NSError(domain: "DHCP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "DHCP timeout"])
        })
        start(service)
        session.set(.running)
        wait(for: [failed], timeout: 2)
        // 状态查询排在配网结果写入之后。
        let ready = expectation(description: "错误阶段可回读")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            service.sessionStatus { data, _ in
                let status = try? JSONDecoder().decode(SessionStatus.self, from: data!)
                XCTAssertEqual(status?.networkPhase, .failed)
                XCTAssertEqual(status?.networkMessage, "DHCP timeout")
                XCTAssertNil(status?.appliedConfiguration)
                ready.fulfill()
            }
        }
        wait(for: [ready], timeout: 2)
        service.shutdown()
    }
    func testSlowHandshakeHasBoundedTimeout() {
        let session = MemorySession()
        let service = HelperService(interfaceTimeout: 0, makeSession: { _ in session })
        start(service)
        let timedOut = expectation(description: "连接有界超时")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            service.sessionStatus { data, _ in
                let status = try? JSONDecoder().decode(SessionStatus.self, from: data!)
                XCTAssertEqual(status?.networkPhase, .failed)
                XCTAssertFalse(status?.networkMessage.isEmpty ?? true)
                timedOut.fulfill()
            }
        }
        wait(for: [timedOut], timeout: 2)
        service.shutdown()
    }

    func testRepeatedStartDoesNotReplaceActiveAttempt() {
        let session = MemorySession()
        let service = HelperService(makeSession: { _ in session })
        start(service)
        let rejected = expectation(description: "拒绝重复连接")
        service.start(configuration: .init()) { message, _ in
            XCTAssertNotNil(message)
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 2)
        service.shutdown()
    }

    func testReconnectInvalidatesOldReadinessCallback() {
        let first = MemorySession()
        let second = MemorySession()
        var count = 0
        let applied = expectation(description: "仅新会话配网")
        applied.assertForOverFulfill = true
        let service = HelperService(makeSession: { _ in
            count += 1
            return count == 1 ? first : second
        }, applyConfiguration: { _, _ in
            XCTAssertEqual(second.status().runState, .running)
            applied.fulfill()
        }, queryConfiguration: { _ in
            var state = NetworkState.empty
            state.hasAddress = true
            return state
        })
        start(service)
        first.set(.failed)
        start(service)
        first.set(.running)
        second.set(.running)
        wait(for: [applied], timeout: 2)
        service.shutdown()
    }

    func testAddressFailureCanBeRetriedWithoutRestartingSession() {
        let session = MemorySession()
        var count = 0
        let failed = expectation(description: "自动配网失败")
        let service = HelperService(makeSession: { _ in session }, applyConfiguration: { _, _ in
            count += 1
            if count == 1 {
                failed.fulfill()
                throw NSError(domain: "DHCP", code: 1)
            }
        }, queryConfiguration: { _ in
            var state = NetworkState.empty
            state.hasAddress = true
            return state
        })
        start(service)
        session.set(.running)
        wait(for: [failed], timeout: 2)
        let retried = expectation(description: "原会话重试成功")
        service.applyOwnedNetwork(interface: "feth123", configuration: .dhcp) { message, _ in
            XCTAssertNil(message)
            retried.fulfill()
        }
        wait(for: [retried], timeout: 2)
        XCTAssertEqual(session.status().runState, .running)
        XCTAssertEqual(count, 2)
        service.shutdown()
    }

}
