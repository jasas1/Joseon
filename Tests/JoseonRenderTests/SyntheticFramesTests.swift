import XCTest
import JoseonCore
@testable import JoseonRender

final class SyntheticFramesTests: XCTestCase {
    func testFramesAreConsistentAndDeterministic() {
        var o = SyntheticFrames.Options()
        o.includeHeadphone = true
        let a = SyntheticFrames.sequence(count: 240, options: o), b = SyntheticFrames.sequence(count: 240, options: o)
        let f = a[239]
        let n = f.spectrum.frequencies.count
        XCTAssertEqual(n, 1024)
        for arr in [f.spectrum.left, f.spectrum.right, f.spectrum.mid, f.spectrum.side, f.spectrum.peakHold, f.spectrum.average] {
            XCTAssertEqual(arr.count, n)
            XCTAssertTrue(arr.allSatisfy { $0.isFinite && $0 >= -120 && $0 <= 6 })
        }
        XCTAssertEqual(f.spectrum.mid, b[239].spectrum.mid)
        XCTAssertGreaterThan(f.hostTime, a[238].hostTime)
        XCTAssertFalse(f.peak.noteName.isEmpty)
        XCTAssertTrue((-40 ... -5).contains(f.loudness.integratedLUFS), "\(f.loudness.integratedLUFS)")
        XCTAssertLessThanOrEqual(f.loudness.truePeakMaxDBTP, 0)
        XCTAssertEqual(f.stereo.scopePoints.count, 1024)
        XCTAssertTrue(f.stereo.scopePoints.allSatisfy { abs($0.x) <= 1 && abs($0.y) <= 1 })
        XCTAssertTrue((0.2 ... 0.95).contains(f.stereo.correlation), "a wide mix, not mono: \(f.stereo.correlation)")
        XCTAssertEqual(f.stereo.bandCorrelation.count, 8)
        XCTAssertEqual(f.headphone?.responseDB.count, n)
        for i in 0..<n { XCTAssertGreaterThanOrEqual(f.spectrum.peakHold[i], f.spectrum.mid[i] - 0.001) }
    }

    func testHotOptionClips() {
        var o = SyntheticFrames.Options()
        o.hot = true
        let f = SyntheticFrames.sequence(count: 300, options: o)[299]
        XCTAssertGreaterThan(f.loudness.truePeakMaxDBTP, 0)
        XCTAssertGreaterThan(f.loudness.clipCount, 0)
    }
}
