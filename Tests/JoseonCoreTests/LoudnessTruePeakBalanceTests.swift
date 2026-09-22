import Foundation
import XCTest
@testable import JoseonCore

/// Defect 10 (critic round 4): the meters showed live true peak L −5.2 dBTP against
/// R −13.8 dBTP on `TestSignals.demoBlock`, while the sub-bass balance read centre, the
/// hold ticks were equal and R had the higher RMS. The kick is mono, so the two channels
/// must read within a few dB of each other.
///
/// The old ballistics restarted the hold timer only when a peak *exceeded* the displayed
/// value. Every later hit of the demo kick lands a hair below the loudest hit so far, so
/// the timer never restarted: the display fell 20 dB/s down to the material between the
/// kicks and re-latched only when a kick finally passed it again. That saw-tooth ran at
/// about 2 s per channel and on a different phase per channel, because the all-time
/// maxima of L and R happen at different moments. Measured over 40 s of the demo signal,
/// read every 0.5 s, the worst |L − R| was 11.03 dB with dips to −15.5 dBTP on one
/// channel at a time; both numbers the critic saw (L −5.2 / R −13.8, and L −13.7 / R
/// −5.1 the round before) appear in that trace.
///
/// `PeakHoldBallistics` holds the largest level of the last 1.5 s instead, which has no
/// order-of-arrival state. The same trace now peaks at 1.67 dB, which is the difference
/// of the channels' own sample peaks.
final class LoudnessTruePeakBalanceTests: XCTestCase {

    private let rate = 48_000.0
    private let blockFrames = 800
    /// The hold window `PeakHoldBallistics` covers, worst case.
    private var holdWindowSeconds: Double {
        LoudnessMeter.truePeakHoldSeconds * Double(PeakHoldBallistics.slots) / Double(PeakHoldBallistics.slots - 1)
    }

    /// Feed `seconds` of a signal in capture-sized blocks, reading every 0.5 s.
    /// `body` gets the reading and the per-channel sample peak over the hold window.
    private func sweepDemo(
        seconds: Double,
        mono: Bool,
        body: (_ time: Double, _ reading: LoudnessReading, _ samplePeakLeftDB: Double, _ samplePeakRightDB: Double) -> Void
    ) {
        let meter = LoudnessMeter()
        let readEvery = Int((0.5 * rate).rounded()) / blockFrames * blockFrames
        // Per-block sample peaks, so the window maximum matches what the meter held.
        let blocksInWindow = max(1, Int((holdWindowSeconds * rate / Double(blockFrames)).rounded(.up)))
        var historyL = [Float](), historyR = [Float]()
        var position = 0
        var sinceRead = 0

        while position < Int(seconds * rate) {
            let s = TestSignals.demoBlock(startSample: position, count: blockFrames, sampleRate: rate)
            let left = s.left
            let right = mono ? s.left : s.right
            var peakL: Float = 0, peakR: Float = 0
            for v in left { peakL = max(peakL, abs(v)) }
            for v in right { peakR = max(peakR, abs(v)) }
            historyL.append(peakL); historyR.append(peakR)
            if historyL.count > blocksInWindow { historyL.removeFirst(); historyR.removeFirst() }

            left.withUnsafeBufferPointer { lb in
                right.withUnsafeBufferPointer { rb in
                    meter.process(left: lb.baseAddress!, right: rb.baseAddress!, count: blockFrames, sampleRate: rate)
                }
            }
            position += blockFrames
            sinceRead += blockFrames
            if sinceRead >= readEvery {
                sinceRead = 0
                body(Double(position) / rate,
                     meter.read(),
                     20 * log10(Double(max(historyL.max() ?? 0, 1e-9))),
                     20 * log10(Double(max(historyR.max() ?? 0, 1e-9))))
            }
        }
    }

    /// A mono signal must read the same true peak on both channels, held and max.
    func testMonoSignalReadsTheSameTruePeakOnBothChannels() {
        var reads = 0
        sweepDemo(seconds: 40, mono: true) { time, r, _, _ in
            reads += 1
            XCTAssertEqual(Double(r.truePeakLeftDBTP), Double(r.truePeakRightDBTP), accuracy: 0.01,
                           String(format: "held true peak L/R at t=%.2f s", time))
            // The max since reset is one number for the pair, so it can never sit under
            // either channel's held value.
            XCTAssertGreaterThanOrEqual(Double(r.truePeakMaxDBTP), Double(max(r.truePeakLeftDBTP, r.truePeakRightDBTP)) - 0.01,
                                        String(format: "max true peak at t=%.2f s", time))
        }
        XCTAssertEqual(reads, 80)
    }

    /// A mono sine, the simplest case: both channels and the max agree exactly.
    func testMonoSineReadsTheSameTruePeakOnBothChannels() {
        let meter = LoudnessMeter()
        let tone = LoudnessTestSupport.sine(hz: 997, dBFS: -6, sampleRate: rate, seconds: 4)
        var fed = 0
        tone.withUnsafeBufferPointer { b in
            while fed < tone.count {
                let n = min(blockFrames, tone.count - fed)
                meter.process(left: b.baseAddress! + fed, right: b.baseAddress! + fed, count: n, sampleRate: rate)
                fed += n
                let r = meter.read()
                XCTAssertEqual(Double(r.truePeakLeftDBTP), Double(r.truePeakRightDBTP), accuracy: 0.01,
                               "held true peak L/R after \(fed) frames")
            }
        }
    }

    /// On the demo signal the held true peaks may only differ by as much as the channels'
    /// own sample peaks over the same window differ, plus 0.5 dB of interpolator headroom.
    func testDemoSignalChannelsTrackTheirOwnSamplePeaks() {
        var worstDifference = 0.0
        var worstMargin = -Double.greatestFiniteMagnitude
        var worstTime = 0.0
        var lowest = 0.0

        sweepDemo(seconds: 40, mono: false) { time, r, spL, spR in
            let difference = abs(Double(r.truePeakLeftDBTP) - Double(r.truePeakRightDBTP))
            let allowed = abs(spL - spR) + 0.5
            XCTAssertLessThan(difference, allowed, String(
                format: "t=%.2f s: TP L %.2f R %.2f (Δ %.2f) but sample peaks L %.2f R %.2f (Δ %.2f)",
                time, r.truePeakLeftDBTP, r.truePeakRightDBTP, difference, spL, spR, abs(spL - spR)))
            if difference > worstDifference { worstDifference = difference; worstTime = time }
            worstMargin = max(worstMargin, difference - allowed)
            lowest = min(lowest, Double(min(r.truePeakLeftDBTP, r.truePeakRightDBTP)))
        }

        // The mono kick dominates: neither channel may dip into the chord-only level.
        XCTAssertGreaterThan(lowest, -9.0, "lowest held true peak over 40 s of the demo signal")
        print(String(format: "demo held true peak: worst |L−R| = %.2f dB at t=%.2f s, worst margin %.2f dB, lowest read %.2f dBTP",
                     worstDifference, worstTime, worstMargin, lowest))
    }

    /// The sliding-maximum hold must not swallow the fall: a peak that stops really does
    /// decay, and a repeating peak really does hold.
    func testRepeatingPeakHoldsWhileAStoppedPeakFalls() {
        let meter = LoudnessMeter()
        // A -6 dBFS click every 0.25 s for 6 s, then silence.
        var signal = [Float](repeating: 0, count: Int(6 * rate))
        let click = LoudnessTestSupport.amplitude(dBFS: -6)
        var i = 0
        while i < signal.count { signal[i] = click; signal[i + 1] = -click; i += Int(0.25 * rate) }
        LoudnessTestSupport.feedMono(meter, signal, sampleRate: rate, blockFrames: blockFrames)
        // Every click is identical, so the display must still stand on the peak: this is
        // the regression. The old ballistics had fallen about 10 dB by now.
        let repeating = meter.read()
        XCTAssertEqual(repeating.truePeakLeftDBTP, repeating.truePeakMaxDBTP, accuracy: 0.01,
                       "a repeating click holds the display at the peak")
        XCTAssertEqual(repeating.truePeakRightDBTP, repeating.truePeakMaxDBTP, accuracy: 0.01,
                       "…on both channels")
        XCTAssertGreaterThan(repeating.truePeakLeftDBTP, -6.5, "the click itself is a -6 dBFS step pair")

        LoudnessTestSupport.feedMono(meter, [Float](repeating: 0, count: Int(2 * rate)), sampleRate: rate, blockFrames: blockFrames)
        let stopped = meter.read()
        XCTAssertLessThan(stopped.truePeakLeftDBTP, -10.0, "true peak falls once the clicks stop")
        XCTAssertEqual(stopped.truePeakLeftDBTP, stopped.truePeakRightDBTP, accuracy: 0.01, "fall is symmetric")
        XCTAssertEqual(stopped.truePeakMaxDBTP, repeating.truePeakMaxDBTP, accuracy: 0.01,
                       "the max since reset never falls")
    }
}
