import Foundation
import XCTest
@testable import JoseonCore

/// Defect 12 (critic round 4), analyzer side: the placement view's sub-30 Hz blob wanders
/// to R 0.2 on the demo signal while the spectrum shows L ≥ R down there. Nothing in the
/// contract changes; this test pins the number the analyzer actually reports, so the
/// wander is known to be a render-side confidence problem and not a measurement.
///
/// The demo signal's only content below 60 Hz is the kick, which is mono, plus the pink
/// noise bed, which is the same table read at two offsets and so has no systematic side.
final class StereoDemoBalanceTests: XCTestCase {

    func testSubBassBandBalanceOnTheDemoSignalIsCentred() {
        let rate = 48_000.0
        let block = 800
        let subBass = 0                              // BandEnergy.edgesHz = [20, 60, …]
        let analyzer = StereoAnalyzer()
        var position = 0
        var worst: Float = 0
        var worstTime = 0.0
        var sum = 0.0
        var reads = 0

        while position < Int(40 * rate) {
            let s = TestSignals.demoBlock(startSample: position, count: block, sampleRate: rate)
            s.left.withUnsafeBufferPointer { lb in
                s.right.withUnsafeBufferPointer { rb in
                    analyzer.process(left: lb.baseAddress!, right: rb.baseAddress!, count: block, sampleRate: rate)
                }
            }
            position += block
            // Skip the first second: the band filters and the 300 ms window are still settling.
            let time = Double(position) / rate
            guard time >= 1 else { continue }
            let reading = analyzer.read()
            XCTAssertTrue(reading.bandActive[subBass], String(format: "sub-bass band went inactive at t=%.2f s", time))
            let balance = reading.bandBalance[subBass]
            if abs(balance) > abs(worst) { worst = balance; worstTime = time }
            sum += Double(balance)
            reads += 1
        }

        XCTAssertGreaterThan(reads, 2_000)
        let mean = sum / Double(reads)
        print(String(format: "demo sub-bass bandBalance over %d reads: mean %+.4f, worst %+.4f at t=%.2f s",
                     reads, mean, worst, worstTime))
        XCTAssertLessThan(abs(worst), 0.05, String(format: "worst sub-bass balance %+.4f at t=%.2f s", worst, worstTime))
        XCTAssertLessThan(abs(mean), 0.01, String(format: "mean sub-bass balance %+.4f", mean))
    }
}
