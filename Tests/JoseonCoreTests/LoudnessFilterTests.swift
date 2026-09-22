import XCTest
@testable import JoseonCore

/// Unit checks for the two pieces of DSP behind `LoudnessMeter`: the K-weighting
/// filter and the true-peak interpolator.
final class LoudnessFilterTests: XCTestCase {

    // MARK: - K-weighting

    /// The derivation must reproduce the table printed in ITU-R BS.1770-4 at
    /// 48 kHz. If it does not, the per-rate coefficients are wrong everywhere.
    func testKWeightingMatchesBS1770TableAt48k() {
        let shelf = KWeighting.shelf(sampleRate: 48_000)
        XCTAssertEqual(shelf.b0, 1.53512485958697, accuracy: 1e-12)
        XCTAssertEqual(shelf.b1, -2.69169618940638, accuracy: 1e-12)
        XCTAssertEqual(shelf.b2, 1.19839281085285, accuracy: 1e-12)
        XCTAssertEqual(shelf.a1, -1.69065929318241, accuracy: 1e-12)
        XCTAssertEqual(shelf.a2, 0.73248077421585, accuracy: 1e-12)

        let highPass = KWeighting.highPass(sampleRate: 48_000)
        XCTAssertEqual(highPass.b0, 1.0, accuracy: 1e-15)
        XCTAssertEqual(highPass.b1, -2.0, accuracy: 1e-15)
        XCTAssertEqual(highPass.b2, 1.0, accuracy: 1e-15)
        XCTAssertEqual(highPass.a1, -1.99004745483398, accuracy: 1e-11)
        XCTAssertEqual(highPass.a2, 0.99007225036621, accuracy: 1e-11)
    }

    /// The +0.691 dB of K-weighting gain at 1 kHz is what cancels the -0.691
    /// offset, so a -23 dBFS tone reads -23 LUFS. It must hold at every rate.
    func testKWeightingGainAtOneKilohertz() {
        for rate in [44_100.0, 48_000.0, 88_200.0, 96_000.0, 192_000.0] {
            var filter = KWeightingFilter()
            filter.configure(sampleRate: rate)
            let gainDB = 20 * log10(filter.magnitude(atHz: 1000, sampleRate: rate))
            XCTAssertEqual(gainDB, 0.691, accuracy: 0.03, "K gain at 1 kHz, \(Int(rate)) Hz")
        }
    }

    /// Shape checks: the RLB stage cuts the deep bass, the shelf lifts the top.
    func testKWeightingShape() {
        var filter = KWeightingFilter()
        filter.configure(sampleRate: 48_000)
        let at20 = 20 * log10(filter.magnitude(atHz: 20, sampleRate: 48_000))
        let at100 = 20 * log10(filter.magnitude(atHz: 100, sampleRate: 48_000))
        let at1k = 20 * log10(filter.magnitude(atHz: 1000, sampleRate: 48_000))
        let at10k = 20 * log10(filter.magnitude(atHz: 10_000, sampleRate: 48_000))
        XCTAssertLessThan(at20, -10)
        XCTAssertLessThan(at100, at1k)
        XCTAssertGreaterThan(at10k, at1k + 3)
        XCTAssertEqual(at100, -0.6, accuracy: 0.6)
    }

    func testKWeightingIsStableOverLongRuns() {
        var filter = KWeightingFilter()
        filter.configure(sampleRate: 48_000)
        // A 60 s DC offset is the worst case for the high-pass: the output must
        // decay to zero and stay finite.
        var last = 0.0
        for _ in 0..<(48_000 * 60) { last = filter.step(1.0) }
        XCTAssertTrue(last.isFinite)
        XCTAssertEqual(last, 0, accuracy: 1e-6)
    }

    // MARK: - True peak interpolator

    func testOversamplingFactorPerSampleRate() {
        XCTAssertEqual(TruePeakDetector.factor(forSampleRate: 44_100), 4)
        XCTAssertEqual(TruePeakDetector.factor(forSampleRate: 48_000), 4)
        XCTAssertEqual(TruePeakDetector.factor(forSampleRate: 96_000), 4)
        XCTAssertEqual(TruePeakDetector.factor(forSampleRate: 176_400), 2)
        XCTAssertEqual(TruePeakDetector.factor(forSampleRate: 192_000), 2)
        XCTAssertEqual(TruePeakDetector.factor(forSampleRate: 384_000), 1)
        XCTAssertEqual(TruePeakDetector.factor(forSampleRate: 768_000), 1)
    }

    /// Phase 0 is an exact unit impulse, so the true peak can never read below
    /// the sample peak, and every branch has unity gain at DC.
    func testPolyphaseBranchProperties() {
        for factor in [2, 4] {
            let detector = TruePeakDetector()
            detector.configure(factor: factor)
            let phase0 = detector.phaseCoefficients(0)
            XCTAssertEqual(phase0.reduce(0, +), 1.0, accuracy: 1e-6, "phase 0 DC gain, factor \(factor)")
            XCTAssertEqual(phase0.filter { $0 != 0 }.count, 1, "phase 0 is not an impulse, factor \(factor)")
            for p in 1..<factor {
                let taps = detector.phaseCoefficients(p)
                XCTAssertEqual(taps.count, TruePeakDetector.tapsPerPhase)
                XCTAssertEqual(taps.reduce(0, +), 1.0, accuracy: 1e-5, "phase \(p) DC gain, factor \(factor)")
            }
        }
    }

    /// The meter feeds whole blocks; the tests feed single samples. Both paths
    /// must give the same answer.
    func testBlockAndSampleDetectionAgree() {
        let noise = TestSignals.whiteNoise(amplitude: 0.9, count: 5_000)
        let bySample = TruePeakDetector()
        let byBlock = TruePeakDetector()
        var sampleWise: Float = 0
        for v in noise { sampleWise = max(sampleWise, bySample.push(v)) }
        var blockWise: Float = 0
        noise.withUnsafeBufferPointer { b in
            guard let p = b.baseAddress else { return }
            var i = 0
            while i < noise.count {
                let n = min(333, noise.count - i)
                blockWise = max(blockWise, byBlock.maxAbs(p + i, count: n))
                i += n
            }
        }
        XCTAssertEqual(blockWise, sampleWise, accuracy: 1e-6)
    }

    func testDetectorNeverReadsBelowSamplePeak() {
        let detector = TruePeakDetector()
        detector.configure(factor: 4)
        let noise = TestSignals.whiteNoise(amplitude: 0.8, count: 20_000)
        var truePeak: Float = 0
        for v in noise { truePeak = max(truePeak, detector.push(v)) }
        let samplePeak = noise.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertGreaterThanOrEqual(truePeak, samplePeak - 1e-6)
        // Band-limited noise really does overshoot between samples.
        XCTAssertGreaterThan(truePeak, samplePeak)
    }

    /// A full-scale sine has a true peak of exactly 0 dBTP at any frequency.
    /// 4x oversampling can under-read near Nyquist (the grid is 1/8 sample
    /// coarse) but must never over-read.
    func testDetectorAccuracyAcrossFrequency() {
        let rate = 48_000.0
        for fraction in [0.01, 0.05, 0.1, 0.2, 0.25, 0.3, 0.35, 0.4] {
            for phase in stride(from: 0.0, to: Double.pi, by: Double.pi / 8) {
                let detector = TruePeakDetector()
                detector.configure(factor: 4)
                let signal = TestSignals.sine(hz: fraction * rate, amplitude: 1.0, sampleRate: rate, seconds: 0.05, phase: phase)
                var peak: Float = 0
                for (i, v) in signal.enumerated() {
                    let p = detector.push(v)
                    if i >= TruePeakDetector.tapsPerPhase { peak = max(peak, p) }
                }
                let dbtp = 20 * log10(Double(peak))
                XCTAssertLessThanOrEqual(dbtp, 0.02, "over-read at \(fraction) fs, phase \(phase): \(dbtp) dBTP")
                XCTAssertGreaterThan(dbtp, -0.5, "under-read at \(fraction) fs, phase \(phase): \(dbtp) dBTP")
            }
        }
    }

    func testDetectorReconstructsQuarterRatePeakExactly() {
        let detector = TruePeakDetector()
        detector.configure(factor: 4)
        let signal = TestSignals.sine(hz: 12_000, amplitude: 1.0, sampleRate: 48_000, seconds: 0.05, phase: .pi / 4)
        var peak: Float = 0
        for (i, v) in signal.enumerated() {
            let p = detector.push(v)
            if i >= TruePeakDetector.tapsPerPhase { peak = max(peak, p) }
        }
        XCTAssertEqual(20 * log10(Double(peak)), 0.0, accuracy: 0.05)
    }

    // MARK: - Histogram

    func testHistogramGatingAndPercentiles() {
        var histogram = LoudnessHistogram()
        func add(_ lufs: Double, times: Int) {
            let power = pow(10.0, (lufs - LoudnessMeter.loudnessOffset) / 10.0)
            for _ in 0..<times { histogram.add(loudness: lufs, power: power) }
        }
        add(-20, times: 100)
        add(-30, times: 100)
        add(-80, times: 50)   // below the absolute gate: must be ignored

        XCTAssertEqual(histogram.totalCount, 200)
        let low = histogram.percentile(0.10, aboveLUFS: -70)
        let high = histogram.percentile(0.95, aboveLUFS: -70)
        XCTAssertEqual(low ?? .nan, -30, accuracy: LoudnessHistogram.binWidth)
        XCTAssertEqual(high ?? .nan, -20, accuracy: LoudnessHistogram.binWidth)

        let gated = histogram.gated(aboveLUFS: -25)
        XCTAssertEqual(gated.count, 100)
    }

    func testEmptyHistogramIsSafe() {
        let histogram = LoudnessHistogram()
        XCTAssertEqual(histogram.totalCount, 0)
        XCTAssertNil(histogram.percentile(0.5, aboveLUFS: -70))
        XCTAssertEqual(histogram.gated(aboveLUFS: -70).count, 0)
    }
}
