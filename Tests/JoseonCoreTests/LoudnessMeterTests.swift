import XCTest
@testable import JoseonCore

/// EBU Tech 3341 / 3342 style conformance for `LoudnessMeter`.
final class LoudnessMeterTests: XCTestCase {

    private let support = LoudnessTestSupport.self

    /// An unoptimised build runs the DSP loops about 40x slower, so the timing
    /// tests do fewer passes there. Only the release numbers mean anything.
    #if DEBUG
    static let performanceIterations = 20
    static let budgetIterations = 300
    #else
    static let performanceIterations = 100
    static let budgetIterations = 2000
    #endif

    // MARK: - Tech 3341 cases 1 and 2: steady tone

    func testSteadyToneReadsMinus23() {
        let meter = LoudnessMeter()
        let tone = support.sine(hz: 1000, dBFS: -23, sampleRate: 48_000, seconds: 20)
        support.feedMono(meter, tone, sampleRate: 48_000)
        let r = meter.read()
        assertClose(r.integratedLUFS, -23.0, 0.1, "integrated")
        assertClose(r.momentaryLUFS, -23.0, 0.1, "momentary")
        assertClose(r.shortTermLUFS, -23.0, 0.1, "short-term")
        assertClose(r.momentaryMaxLUFS, -23.0, 0.1, "momentary max")
        assertClose(r.shortTermMaxLUFS, -23.0, 0.1, "short-term max")
        XCTAssertEqual(r.measuredSeconds, 20.0, accuracy: 0.01)
    }

    func testSteadyToneReadsMinus33() {
        let meter = LoudnessMeter()
        let tone = support.sine(hz: 1000, dBFS: -33, sampleRate: 48_000, seconds: 20)
        support.feedMono(meter, tone, sampleRate: 48_000)
        let r = meter.read()
        assertClose(r.integratedLUFS, -33.0, 0.1, "integrated")
        assertClose(r.momentaryLUFS, -33.0, 0.1, "momentary")
        assertClose(r.shortTermLUFS, -33.0, 0.1, "short-term")
    }

    /// K-weighting is derived per rate, so the same tone must read the same at
    /// every rate. A 48 kHz coefficient table would fail this.
    func testSteadyToneAcrossSampleRates() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let meter = LoudnessMeter()
            let tone = support.sine(hz: 1000, dBFS: -23, sampleRate: rate, seconds: 20)
            support.feedMono(meter, tone, sampleRate: rate)
            let r = meter.read()
            assertClose(r.integratedLUFS, -23.0, 0.1, "integrated at \(Int(rate)) Hz")
            assertClose(r.momentaryLUFS, -23.0, 0.1, "momentary at \(Int(rate)) Hz")
            assertClose(r.shortTermLUFS, -23.0, 0.1, "short-term at \(Int(rate)) Hz")
        }
    }

    // MARK: - Tech 3341 case 3: relative gate

    func testRelativeGateRejectsQuietSections() {
        let meter = LoudnessMeter()
        let signal = support.steppedSine(hz: 1000, sampleRate: 48_000, segments: [
            (dBFS: -36, seconds: 10),
            (dBFS: -23, seconds: 60),
            (dBFS: -36, seconds: 10),
        ])
        support.feedMono(meter, signal, sampleRate: 48_000)
        let r = meter.read()
        assertClose(r.integratedLUFS, -23.0, 0.1, "gated integrated")
    }

    /// Everything below the absolute gate must vanish from the integrated value.
    func testAbsoluteGateRejectsVeryQuietSections() {
        let meter = LoudnessMeter()
        let signal = support.steppedSine(hz: 1000, sampleRate: 48_000, segments: [
            (dBFS: -80, seconds: 10),
            (dBFS: -23, seconds: 10),
        ])
        support.feedMono(meter, signal, sampleRate: 48_000)
        assertClose(meter.read().integratedLUFS, -23.0, 0.1, "integrated with sub-gate lead-in")
    }

    // MARK: - Tech 3342: loudness range

    func testLoudnessRangeOfTenLU() {
        let meter = LoudnessMeter()
        let signal = support.steppedSine(hz: 1000, sampleRate: 48_000, segments: [
            (dBFS: -20, seconds: 20),
            (dBFS: -30, seconds: 20),
        ])
        support.feedMono(meter, signal, sampleRate: 48_000)
        assertClose(meter.read().loudnessRangeLU, 10.0, 1.0, "loudness range")
    }

    func testLoudnessRangeOfSteadyToneIsNearZero() {
        let meter = LoudnessMeter()
        support.feedMono(meter, support.sine(hz: 1000, dBFS: -23, sampleRate: 48_000, seconds: 8), sampleRate: 48_000)
        assertClose(meter.read().loudnessRangeLU, 0.0, 0.2, "loudness range of a steady tone")
    }

    // MARK: - True peak

    /// A sine at fs/4 with 45 degrees of phase has sample peaks at -3 dBFS but a
    /// true peak of exactly 0 dBTP. This is the classic inter-sample case.
    func testTruePeakOfQuarterRateSine() {
        let rate = 48_000.0
        let signal = TestSignals.sine(hz: rate / 4, amplitude: 1.0, sampleRate: rate, seconds: 2, phase: .pi / 4)
        var samplePeak: Float = 0
        for v in signal { samplePeak = max(samplePeak, abs(v)) }
        assertClose(Float(20 * log10(Double(samplePeak))), -3.0103, 0.01, "sample peak of the test signal")

        let meter = LoudnessMeter()
        LoudnessTestSupport.feedMono(meter, signal, sampleRate: rate)
        let r = meter.read()
        assertClose(r.truePeakMaxDBTP, 0.0, 0.3, "true peak max")
        assertClose(r.truePeakLeftDBTP, 0.0, 0.3, "true peak left")
        assertClose(r.truePeakRightDBTP, 0.0, 0.3, "true peak right")
    }

    func testTruePeakOfMinusSixSine() {
        let meter = LoudnessMeter()
        let tone = support.sine(hz: 1000, dBFS: -6, sampleRate: 48_000, seconds: 2)
        support.feedMono(meter, tone, sampleRate: 48_000)
        let r = meter.read()
        assertClose(r.truePeakMaxDBTP, -6.0, 0.2, "true peak max")
        assertClose(r.truePeakLeftDBTP, -6.0, 0.2, "true peak left")
    }

    /// Tech 3341 also expects the display to fall back after the hold time.
    func testTruePeakDisplayHoldsThenFalls() {
        let rate = 48_000.0
        let meter = LoudnessMeter()
        support.feedMono(meter, support.sine(hz: 1000, dBFS: -6, sampleRate: rate, seconds: 1), sampleRate: rate)
        let afterTone = meter.read()
        assertClose(afterTone.truePeakLeftDBTP, -6.0, 0.2, "true peak before silence")

        // 1.0 s of silence: still inside the 1.5 s hold.
        support.feedMono(meter, [Float](repeating: 0, count: Int(rate)), sampleRate: rate)
        let held = meter.read()
        assertClose(held.truePeakLeftDBTP, -6.0, 0.2, "true peak during hold")

        // 1.0 s more: 0.5 s past the hold, so about 10 dB of fall.
        support.feedMono(meter, [Float](repeating: 0, count: Int(rate)), sampleRate: rate)
        let fallen = meter.read()
        assertClose(fallen.truePeakLeftDBTP, -16.0, 1.0, "true peak after 0.5 s of fall")
        // The max since reset never moves.
        assertClose(fallen.truePeakMaxDBTP, -6.0, 0.2, "true peak max is unaffected by the fall")
    }

    // MARK: - Clipping

    func testClipCountCountsRunsOfThreeOrMore() {
        var left = [Float](repeating: 0, count: 2000)
        // A run of 3, a run of 5, a run of 2 (too short), a negative run of 3.
        for i in 100..<103 { left[i] = 1.0 }
        for i in 300..<305 { left[i] = 1.0 }
        for i in 500..<502 { left[i] = 1.0 }
        for i in 700..<703 { left[i] = -1.0 }
        let right = [Float](repeating: 0, count: 2000)

        let meter = LoudnessMeter()
        LoudnessTestSupport.feed(meter, left: left, right: right, sampleRate: 48_000, blockFrames: 128)
        XCTAssertEqual(meter.read().clipCount, 3)
    }

    func testClipCountOnHardClippedSine() {
        let rate = 48_000.0
        let cycles = 100
        let seconds = Double(cycles) / 1000.0
        let raw = TestSignals.sine(hz: 1000, amplitude: 2.0, sampleRate: rate, seconds: seconds)
        let clipped = raw.map { max(-1.0, min(1.0, $0)) }

        let meter = LoudnessMeter()
        LoudnessTestSupport.feedMono(meter, clipped, sampleRate: rate)
        let count = meter.read().clipCount
        // Two flat tops per cycle per channel, stereo: about 4 per cycle.
        XCTAssertGreaterThanOrEqual(count, 4 * cycles - 4)
        XCTAssertLessThanOrEqual(count, 4 * cycles + 4)

        // The unclipped source of the same tone must report nothing.
        let clean = LoudnessMeter()
        LoudnessTestSupport.feedMono(clean, LoudnessTestSupport.sine(hz: 1000, dBFS: -1, sampleRate: rate, seconds: seconds), sampleRate: rate)
        XCTAssertEqual(clean.read().clipCount, 0)
    }

    // MARK: - Silence

    func testSilenceGivesFiniteFloors() {
        let meter = LoudnessMeter()
        let quiet = [Float](repeating: 0, count: 48_000 * 4)
        LoudnessTestSupport.feedMono(meter, quiet, sampleRate: 48_000)
        let r = meter.read()
        for (label, value) in [
            ("momentary", r.momentaryLUFS), ("short-term", r.shortTermLUFS), ("integrated", r.integratedLUFS),
            ("momentary max", r.momentaryMaxLUFS), ("short-term max", r.shortTermMaxLUFS),
            ("range", r.loudnessRangeLU),
            ("true peak L", r.truePeakLeftDBTP), ("true peak R", r.truePeakRightDBTP),
            ("true peak max", r.truePeakMaxDBTP),
            ("rms L", r.rmsLeftDB), ("rms R", r.rmsRightDB),
            ("plr", r.plrDB), ("psr", r.psrDB),
        ] {
            XCTAssertTrue(value.isFinite, "\(label) is \(value)")
        }
        XCTAssertEqual(r.momentaryLUFS, LoudnessReading.silenceLUFS)
        XCTAssertEqual(r.shortTermLUFS, LoudnessReading.silenceLUFS)
        XCTAssertEqual(r.integratedLUFS, LoudnessReading.silenceLUFS)
        XCTAssertEqual(r.truePeakMaxDBTP, -120)
        XCTAssertEqual(r.rmsLeftDB, -120)
        XCTAssertEqual(r.loudnessRangeLU, 0)
        XCTAssertEqual(r.plrDB, 0)
        XCTAssertEqual(r.psrDB, 0)
        XCTAssertEqual(r.clipCount, 0)
        XCTAssertEqual(r.measuredSeconds, 4.0, accuracy: 0.01)
    }

    // MARK: - RMS, PLR, PSR

    func testRMSOverThreeHundredMilliseconds() {
        let meter = LoudnessMeter()
        // -12 dBFS peak sine: RMS is 3.01 dB below the peak.
        let left = support.sine(hz: 1000, dBFS: -12, sampleRate: 48_000, seconds: 2)
        let right = support.sine(hz: 1000, dBFS: -18, sampleRate: 48_000, seconds: 2)
        LoudnessTestSupport.feed(meter, left: left, right: right, sampleRate: 48_000)
        let r = meter.read()
        assertClose(r.rmsLeftDB, -15.01, 0.1, "rms left")
        assertClose(r.rmsRightDB, -21.01, 0.1, "rms right")
    }

    func testPLRAndPSR() {
        let meter = LoudnessMeter()
        let tone = support.sine(hz: 1000, dBFS: -23, sampleRate: 48_000, seconds: 8)
        support.feedMono(meter, tone, sampleRate: 48_000)
        let r = meter.read()
        // True peak of a -23 dBFS sine is -23 dBTP; integrated reads -23 LUFS.
        assertClose(r.truePeakMaxDBTP, -23.0, 0.2, "true peak max")
        assertClose(r.plrDB, Double(r.truePeakMaxDBTP - r.integratedLUFS), 0.001, "plr identity")
        assertClose(r.plrDB, 0.0, 0.3, "plr of a steady sine")
        assertClose(r.psrDB, 0.0, 0.3, "psr of a steady sine")
    }

    // MARK: - Reset and rate changes

    func testResetClearsIntegratedAndMaxValues() {
        let meter = LoudnessMeter()
        support.feedMono(meter, support.sine(hz: 1000, dBFS: -10, sampleRate: 48_000, seconds: 4), sampleRate: 48_000)
        let before = meter.read()
        XCTAssertGreaterThan(before.integratedLUFS, -20)
        XCTAssertGreaterThan(before.truePeakMaxDBTP, -20)
        XCTAssertGreaterThan(before.measuredSeconds, 3)

        meter.reset()
        let after = meter.read()
        XCTAssertEqual(after.integratedLUFS, LoudnessReading.silenceLUFS)
        XCTAssertEqual(after.momentaryLUFS, LoudnessReading.silenceLUFS)
        XCTAssertEqual(after.shortTermLUFS, LoudnessReading.silenceLUFS)
        XCTAssertEqual(after.momentaryMaxLUFS, LoudnessReading.silenceLUFS)
        XCTAssertEqual(after.shortTermMaxLUFS, LoudnessReading.silenceLUFS)
        XCTAssertEqual(after.truePeakMaxDBTP, -120)
        XCTAssertEqual(after.truePeakLeftDBTP, -120)
        XCTAssertEqual(after.loudnessRangeLU, 0)
        XCTAssertEqual(after.clipCount, 0)
        XCTAssertEqual(after.measuredSeconds, 0)
        XCTAssertEqual(after.plrDB, 0)
    }

    /// A device switch changes the rate mid-measurement. Filters and windows
    /// reconfigure, and the tone still measures the same.
    func testSampleRateChangeReconfigures() {
        let meter = LoudnessMeter()
        support.feedMono(meter, support.sine(hz: 1000, dBFS: -23, sampleRate: 48_000, seconds: 6), sampleRate: 48_000)
        support.feedMono(meter, support.sine(hz: 1000, dBFS: -23, sampleRate: 96_000, seconds: 6), sampleRate: 96_000)
        let r = meter.read()
        assertClose(r.momentaryLUFS, -23.0, 0.1, "momentary after the rate change")
        assertClose(r.shortTermLUFS, -23.0, 0.1, "short-term after the rate change")
        assertClose(r.integratedLUFS, -23.0, 0.1, "integrated across the rate change")
        XCTAssertEqual(r.measuredSeconds, 12.0, accuracy: 0.01)
    }

    /// The meter must not care how the host chops the stream into blocks.
    func testResultIsIndependentOfBlockSize() {
        var values: [Float] = []
        for blockFrames in [37, 512, 800, 4801] {
            let meter = LoudnessMeter()
            let tone = support.sine(hz: 1000, dBFS: -23, sampleRate: 48_000, seconds: 4)
            LoudnessTestSupport.feedMono(meter, tone, sampleRate: 48_000, blockFrames: blockFrames)
            values.append(meter.read().integratedLUFS)
        }
        for v in values { assertClose(v, Double(values[0]), 0.01, "integrated by block size") }
    }

    // MARK: - Budget

    func testProcessPerformance() {
        let rate = 48_000.0
        let frames = 800
        let signal = TestSignals.pinkNoise(amplitude: 0.5, count: frames)
        let meter = LoudnessMeter()
        // Warm up: builds the filters and touches every buffer.
        LoudnessTestSupport.feedMono(meter, signal, sampleRate: rate, blockFrames: frames)

        measure {
            signal.withUnsafeBufferPointer { b in
                guard let p = b.baseAddress else { return }
                for _ in 0..<Self.performanceIterations {
                    meter.process(left: p, right: p, count: frames, sampleRate: rate)
                }
            }
        }
    }

    /// Hours of listening must cost the same memory as one second: the gated
    /// measures live in fixed-size histograms, never in a growing list.
    func testHistogramMemoryIsConstant() {
        var histogram = LoudnessHistogram()
        for i in 0..<200_000 {
            let lufs = -40.0 + Double(i % 300) * 0.1
            histogram.add(loudness: lufs, power: pow(10.0, (lufs - LoudnessMeter.loudnessOffset) / 10.0))
        }
        XCTAssertEqual(histogram.totalCount, 200_000)
        XCTAssertEqual(histogram.counts.count, LoudnessHistogram.binCount)
        XCTAssertEqual(histogram.powers.count, LoudnessHistogram.binCount)
    }

    /// The hard budget: 800 stereo frames in under 0.5 ms on average.
    /// Only meaningful in an optimised build, so debug gets a loose sanity bound.
    func testProcessMeetsTimeBudget() {
        let rate = 48_000.0
        let frames = 800
        let signal = TestSignals.pinkNoise(amplitude: 0.5, count: frames)
        let meter = LoudnessMeter()
        LoudnessTestSupport.feedMono(meter, signal, sampleRate: rate, blockFrames: frames)

        let iterations = Self.budgetIterations
        let elapsed: Double = signal.withUnsafeBufferPointer { b in
            guard let p = b.baseAddress else { return .infinity }
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                meter.process(left: p, right: p, count: frames, sampleRate: rate)
            }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(iterations)
        }

        #if DEBUG
        let budget = 20.0
        #else
        let budget = 0.5
        #endif
        XCTAssertLessThan(elapsed, budget, "process of \(frames) stereo frames averaged \(elapsed) ms")
    }
}
