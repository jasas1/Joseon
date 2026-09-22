import XCTest
@testable import JoseonCore

final class StereoAnalyzerSanitizeTests: XCTestCase {
    func testNonFiniteSampleDoesNotPoisonTheAccumulators() {
        let analyzer = StereoAnalyzer()
        let reference = StereoAnalyzer()
        var left = TestSignals.sine(hz: 300, amplitude: 0.5, sampleRate: 48_000, seconds: 0.5)
        var right = left
        reference.process(left: left, right: right, count: left.count, sampleRate: 48_000)
        let expected = reference.read()

        left[10] = .nan
        right[5000] = .infinity
        left[12_000] = -.infinity
        right[12_000] = .nan
        analyzer.process(left: left, right: right, count: left.count, sampleRate: 48_000)
        XCTAssertGreaterThanOrEqual(analyzer.sanitizedChunkCount, 1)
        let reading = analyzer.read()
        XCTAssertEqual(reading.correlation, expected.correlation, accuracy: 0.02)
        XCTAssertEqual(reading.balance, expected.balance, accuracy: 0.02)
        XCTAssertTrue(reading.scopePoints.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertTrue(reading.bandCorrelation.allSatisfy { $0.isFinite })

        // No reset: a later anti-phase signal reads -1, so nothing is stuck.
        let tone = TestSignals.sine(hz: 300, amplitude: 0.5, sampleRate: 48_000, seconds: 2.0)
        let inverted = tone.map { -$0 }
        analyzer.process(left: tone, right: inverted, count: tone.count, sampleRate: 48_000)
        XCTAssertEqual(analyzer.read().correlation, -1, accuracy: 0.02)
        XCTAssertGreaterThan(analyzer.read().width, 1)
    }

    func testCleanInputIsNeverSanitized() {
        let analyzer = StereoAnalyzer()
        let noise = TestSignals.sine(hz: 1000, amplitude: 1.0, sampleRate: 96_000, seconds: 1.0)
        analyzer.process(left: noise, right: noise, count: noise.count, sampleRate: 96_000)
        XCTAssertEqual(analyzer.sanitizedChunkCount, 0)
    }
}
