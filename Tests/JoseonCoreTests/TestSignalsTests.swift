import XCTest
@testable import JoseonCore

final class TestSignalsTests: XCTestCase {
    func testDemoBlockIsAPureFunctionOfTheSamplePosition() {
        let whole = TestSignals.demoBlock(startSample: 0, count: 2_000)
        let first = TestSignals.demoBlock(startSample: 0, count: 800)
        let second = TestSignals.demoBlock(startTime: 800.0 / 48_000, count: 1_200)
        XCTAssertEqual(whole.left, first.left + second.left)
        XCTAssertEqual(whole.right, first.right + second.right)
        XCTAssertNotEqual(whole.left, whole.right)
        let peak = (whole.left + whole.right).map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.05)
        XCTAssertLessThan(peak, 1.0)
        // The table wraps without a fault, far into the signal.
        XCTAssertEqual(TestSignals.demoBlock(startSample: 48_000 * 3_600, count: 480).left.count, 480)
    }
}
