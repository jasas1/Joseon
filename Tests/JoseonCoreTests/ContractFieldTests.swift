import XCTest
@testable import JoseonCore

/// Round 2 contract fields: who sets them, and when.
final class ContractFieldTests: XCTestCase {
    func testBandActiveMarksOnlyTheBandsWithEnergy() {
        let a = StereoAnalyzer()
        XCTAssertEqual(a.read().bandActive, [Bool](repeating: false, count: 8), "nothing is active before audio")
        let s = TestSignals.sine(hz: 1_000, amplitude: 0.5, sampleRate: 48_000, seconds: 4)
        s.withUnsafeBufferPointer { p in
            var i = 0
            while i < s.count {
                let n = min(800, s.count - i)
                a.process(left: p.baseAddress! + i, right: p.baseAddress! + i, count: n, sampleRate: 48_000)
                i += n
            }
        }
        let r = a.read()
        XCTAssertEqual(r.bandActive.count, 8)
        XCTAssertTrue(r.bandActive[3], "1 kHz is in the mid band")
        XCTAssertFalse(r.bandActive[0], "sub bass is a gated empty band")
        XCTAssertFalse(r.bandActive[7], "air is a gated empty band")
        for band in 0..<8 where !r.bandActive[band] {
            XCTAssertEqual(r.bandCorrelation[band], 0)
            XCTAssertEqual(r.bandBalance[band], 0)
        }
    }

    func testIntegratedIsValidOnlyAfterTheFirstGatedBlock() {
        let meter = LoudnessMeter()
        XCTAssertFalse(meter.read().isIntegratedValid)
        let tone = LoudnessTestSupport.sine(hz: 1_000, dBFS: -20, sampleRate: 48_000, seconds: 1)
        // 300 ms: no whole 400 ms block yet.
        LoudnessTestSupport.feed(meter, left: Array(tone[0..<14_400]), right: Array(tone[0..<14_400]), sampleRate: 48_000)
        XCTAssertFalse(meter.read().isIntegratedValid)
        XCTAssertEqual(meter.read().integratedLUFS, LoudnessReading.silenceLUFS)
        LoudnessTestSupport.feed(meter, left: Array(tone[14_400...]), right: Array(tone[14_400...]), sampleRate: 48_000)
        XCTAssertTrue(meter.read().isIntegratedValid)
        XCTAssertGreaterThan(meter.read().integratedLUFS, -30)
        meter.reset()
        XCTAssertFalse(meter.read().isIntegratedValid)

        // Audio under the absolute gate never makes the integrated value valid.
        let quiet = LoudnessTestSupport.sine(hz: 1_000, dBFS: -90, sampleRate: 48_000, seconds: 2)
        LoudnessTestSupport.feed(meter, left: quiet, right: quiet, sampleRate: 48_000)
        XCTAssertFalse(meter.read().isIntegratedValid)
    }
}
