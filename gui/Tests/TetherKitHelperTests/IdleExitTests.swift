import Foundation
import XCTest
import TetherKitIPC
@testable import TetherKitHelper

private final class IdleSession: HelperSession {
    private let lock = NSLock()
    private var value = SessionStatus.idle
    func start() throws { set(.starting) }
    func stop() { set(.stopped) }
    func drainNotices() -> [String] { [] }
    func status() -> SessionStatus { lock.withLock { value } }
    func set(_ state: RunState) { lock.withLock { value.runState = state } }
}

final class IdleExitTests: XCTestCase {
    private func start(_ service: HelperService, replacing: Bool = false) {
        let accepted = expectation(description: "连接受理")
        service.start(configuration: .init(), replacing: replacing) { message, _ in
            XCTAssertNil(message)
            accepted.fulfill()
        }
        wait(for: [accepted], timeout: 2)
    }

    func testDisconnectedHelperExitsAfterReplyAndCleanup() {
        let session = IdleSession()
        let service = HelperService(makeSession: { _ in session })
        let exited = expectation(description: "断开后退出")
        service.enableIdleExit(publish: { _ in }, exit: { exited.fulfill() })
        start(service)
        let stopped = expectation(description: "断开回复")
        service.stop { message, _ in
            XCTAssertNil(message)
            XCTAssertEqual(session.status().runState, .stopped)
            stopped.fulfill()
        }
        wait(for: [stopped, exited], timeout: 3, enforceOrder: true)
        service.shutdown()
    }

    func testActiveSessionDoesNotExitWithoutAppPolling() {
        let service = HelperService(makeSession: { _ in IdleSession() })
        let exited = expectation(description: "活动会话禁止退出")
        exited.isInverted = true
        service.enableIdleExit(publish: { _ in }, exit: { exited.fulfill() })
        start(service)
        wait(for: [exited], timeout: 2.2)
        service.shutdown()
    }

    func testDeviceFailurePublishesOriginalFailureBeforeExiting() {
        let session = IdleSession()
        let service = HelperService(makeSession: { _ in session })
        let failed = expectation(description: "失败状态落盘回调")
        failed.assertForOverFulfill = false
        let exited = expectation(description: "失败清理后退出")
        service.enableIdleExit(publish: { status in
            if status.runState == .failed { failed.fulfill() }
        }, exit: { exited.fulfill() })
        start(service)
        session.set(.failed)
        wait(for: [failed, exited], timeout: 4, enforceOrder: true)
        service.shutdown()
    }

    func testAtomicReplacementDoesNotExitBetweenSessions() {
        let service = HelperService(makeSession: { _ in IdleSession() })
        let exited = expectation(description: "切换中禁止退出")
        exited.isInverted = true
        service.enableIdleExit(publish: { _ in }, exit: { exited.fulfill() })
        start(service)
        start(service, replacing: true)
        XCTAssertEqual(service.snapshot().runState, .starting)
        wait(for: [exited], timeout: 2.2)
        service.shutdown()
    }
}
