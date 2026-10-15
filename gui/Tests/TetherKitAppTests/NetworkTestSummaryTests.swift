import XCTest
@testable import TetherKitApp

final class NetworkTestSummaryTests: XCTestCase {
    private func result(_ target: NetworkTestTarget, success: Bool) -> NetworkTestResult {
        .init(id: target, target: target, success: success, latencyMilliseconds: nil,
              statusCode: nil, failureDescription: nil)
    }

    func testAllPassedKeepsOriginalOrderAndHasNoIssues() {
        let results = [result(.gateway, success: true), result(.dns, success: true)]
        let state = NetworkTestState.finished(results)
        XCTAssertEqual(state.failedCount, 0)
        XCTAssertEqual(state.orderedResults, results)
    }

    func testFailuresComeFirstWithoutReorderingWithinGroups() {
        let gateway = result(.gateway, success: true)
        let dns = result(.dns, success: false)
        let https = result(.publicHTTPS, success: true)
        let baidu = result(.baidu, success: false)
        let state = NetworkTestState.finished([gateway, dns, https, baidu])
        XCTAssertEqual(state.failedCount, 2)
        XCTAssertEqual(state.orderedResults, [dns, baidu, gateway, https])
    }
}
