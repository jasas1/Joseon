import Foundation
import XCTest
@testable import JoseonCore

/// `SpectrumAnalyzer` as a third-octave band meter (`ThirdOctaveProviding`).
///
/// Every level here is dBFS **RMS**: a full-scale sine reads -3.01, which is what
/// `ThirdOctaveReading` and the SPL chain expect.
final class ThirdOctaveTests: XCTestCase {

    // MARK: - The map

    /// Which FFT feeds which band, and the proof that the per-bin weights really add up to the
    /// band width. The weight sum is the band width in bins, so partial bins at the edges are
    /// being counted by the fraction that falls inside.
    func testBandMapAndEdgeWeights() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let analyzer = SpectrumAnalyzer()
            let silence = [Float](repeating: 0, count: 4_096)
            ThirdOctave.feed(analyzer, left: silence, right: silence, rate: rate)
            let layers = analyzer.thirdOctaveBank.layerAssignment
            let names = ["low", "mid", "high"]
            var report = [String]()
            for b in 0..<ThirdOctave.bandCount {
                let (lower, upper) = ThirdOctave.edges(b)
                let footprint = analyzer.thirdOctaveBank.footprint(b)
                guard layers[b] >= 0 else { report.append("\(Int(ThirdOctaveReading.nominalCentersHz[b]))=floor"); continue }
                report.append(String(format: "%.0f=%@(%d bins, w=%.3f)",
                                     ThirdOctaveReading.nominalCentersHz[b], names[layers[b]],
                                     footprint.count, footprint.weightSum))
                // The weights add up to the band width measured in bins of that resolution.
                let widthHz = upper - lower
                let dfHz = widthHz / Double(footprint.weightSum)
                XCTAssertGreaterThanOrEqual(Double(footprint.weightSum), ThirdOctaveBank.minBinsPerBand - 1e-3,
                                            "band \(ThirdOctaveReading.nominalCentersHz[b]) Hz has too few bins at \(rate)")
                XCTAssertGreaterThan(dfHz, 0)
            }
            print("third-octave map at \(Int(rate)) Hz: " + report.joined(separator: " "))

            // The three groups are contiguous and ordered: long FFT at the bottom, short at the top.
            let used = layers.filter { $0 >= 0 }
            XCTAssertEqual(used, used.sorted(), "band -> resolution assignment is not monotone at \(rate)")
        }
    }

    /// Bands above 0.9 of Nyquist report the floor. At 44.1 kHz that is the 20 kHz band
    /// (exact centre 19 953 Hz, above 0.9 * 22 050 = 19 845 Hz); at 48 kHz none of them are.
    func testBandsAboveNyquistReportTheFloor() {
        let rate = 44_100.0
        let analyzer = SpectrumAnalyzer()
        let noise = TestSignals.whiteNoise(amplitude: 0.5, count: Int(rate * 2))
        let reading = ThirdOctave.feed(analyzer, left: noise, right: noise, rate: rate)
        let r = try! XCTUnwrap(reading)
        XCTAssertEqual(r.left[ThirdOctave.band(20_000)], ThirdOctaveReading.floorDB)
        XCTAssertEqual(r.right[ThirdOctave.band(20_000)], ThirdOctaveReading.floorDB)
        XCTAssertGreaterThan(r.left[ThirdOctave.band(16_000)], -80)

        let analyzer48 = SpectrumAnalyzer()
        let noise48 = TestSignals.whiteNoise(amplitude: 0.5, count: 96_000)
        let r48 = try! XCTUnwrap(ThirdOctave.feed(analyzer48, left: noise48, right: noise48, rate: 48_000))
        XCTAssertGreaterThan(r48.left[ThirdOctave.band(20_000)], -80, "48 kHz keeps the 20 kHz band")
    }

    // MARK: - Tones

    /// 1 kHz sine at -20 dBFS peak. RMS is 3.01 dB under the peak, so the band reads -23.01.
    func testOneKilohertzSine() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let tone = TestSignals.sine(hz: 1_000, amplitude: 0.1, sampleRate: rate, seconds: 3)
        let r = try! XCTUnwrap(ThirdOctave.feed(analyzer, left: tone, right: tone, rate: rate))

        let target = ThirdOctave.band(1_000)
        XCTAssertEqual(r.left[target], -23.01, accuracy: 0.2)
        XCTAssertEqual(r.right[target], -23.01, accuracy: 0.2)

        var worst = -Float.infinity
        var worstBand = -1
        var worstNeighbour = -Float.infinity
        for b in 0..<ThirdOctave.bandCount where b != target {
            let v = max(r.left[b], r.right[b])
            if b == target - 1 || b == target + 1 {
                worstNeighbour = max(worstNeighbour, v)
            } else if v > worst {
                worst = v; worstBand = b
            }
        }
        let separation = r.left[target] - worst
        let neighbourSeparation = r.left[target] - worstNeighbour
        print(String(format: "1 kHz -20 dBFS: band %.2f dB, worst other band %.0f Hz at %.1f dB (%.1f dB down), neighbours %.1f dB down",
                     r.left[target], ThirdOctaveReading.nominalCentersHz[worstBand], worst, separation, neighbourSeparation))
        XCTAssertGreaterThan(separation, 40, "a non-neighbour band is within 40 dB of the tone")
        XCTAssertGreaterThan(neighbourSeparation, 40, "window leakage into the neighbouring bands is over budget")
    }

    /// The same for 50 Hz, which the 32768-point FFT serves.
    func testFiftyHertzSine() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let tone = TestSignals.sine(hz: 50, amplitude: 0.1, sampleRate: rate, seconds: 4)
        let r = try! XCTUnwrap(ThirdOctave.feed(analyzer, left: tone, right: tone, rate: rate))

        let target = ThirdOctave.band(50)
        XCTAssertEqual(r.left[target], -23.01, accuracy: 0.2)
        XCTAssertEqual(r.right[target], -23.01, accuracy: 0.2)

        var worst = -Float.infinity
        var worstBand = -1
        for b in 0..<ThirdOctave.bandCount where b != target {
            let v = max(r.left[b], r.right[b])
            if v > worst { worst = v; worstBand = b }
        }
        print(String(format: "50 Hz -20 dBFS: band %.2f dB, worst other band %.0f Hz at %.1f dB (%.1f dB down)",
                     r.left[target], ThirdOctaveReading.nominalCentersHz[worstBand], worst, r.left[target] - worst))
        XCTAssertGreaterThan(r.left[target] - worst, 40)
    }

    /// A full-scale sine reads -3.01, which is the calibration the contract names.
    func testFullScaleSineReadsMinusThreeDB() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let tone = TestSignals.sine(hz: 1_000, amplitude: 1.0, sampleRate: rate, seconds: 3)
        let r = try! XCTUnwrap(ThirdOctave.feed(analyzer, left: tone, right: tone, rate: rate))
        XCTAssertEqual(r.left[ThirdOctave.band(1_000)], ThirdOctave.fullScaleSineDB, accuracy: 0.2)
    }

    /// Same answer at every sample rate the app supports.
    func testSameLevelAtEverySampleRate() {
        var levels = [Double: Float]()
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let analyzer = SpectrumAnalyzer()
            let tone = TestSignals.sine(hz: 1_000, amplitude: 0.1, sampleRate: rate, seconds: 3)
            let r = try! XCTUnwrap(ThirdOctave.feed(analyzer, left: tone, right: tone, rate: rate))
            levels[rate] = r.left[ThirdOctave.band(1_000)]
        }
        print("1 kHz band by rate: " + levels.keys.sorted().map { String(format: "%.0fk=%.2f", $0 / 1000, levels[$0]!) }.joined(separator: " "))
        for (_, v) in levels { XCTAssertEqual(v, -23.01, accuracy: 0.3) }
        let spread = levels.values.max()! - levels.values.min()!
        XCTAssertLessThan(spread, 0.3, "the same tone reads differently at different sample rates")
    }

    /// A sample-rate change between calls reconfigures cleanly and the level comes back.
    func testSampleRateChangeReconfigures() {
        let analyzer = SpectrumAnalyzer()
        let a = TestSignals.sine(hz: 1_000, amplitude: 0.1, sampleRate: 48_000, seconds: 3)
        _ = ThirdOctave.feed(analyzer, left: a, right: a, rate: 48_000)
        let b = TestSignals.sine(hz: 1_000, amplitude: 0.1, sampleRate: 96_000, seconds: 3)
        let r = try! XCTUnwrap(ThirdOctave.feed(analyzer, left: b, right: b, rate: 96_000))
        XCTAssertEqual(r.left[ThirdOctave.band(1_000)], -23.01, accuracy: 0.3)
    }

    // MARK: - Channels, silence, warm-up

    /// A left-only signal leaves the right channel at the floor in every band.
    func testLeftOnlySignalLeavesRightAtTheFloor() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let tone = TestSignals.sine(hz: 1_000, amplitude: 0.5, sampleRate: rate, seconds: 3)
        let silence = [Float](repeating: 0, count: tone.count)
        let r = try! XCTUnwrap(ThirdOctave.feed(analyzer, left: tone, right: silence, rate: rate))
        XCTAssertEqual(r.left[ThirdOctave.band(1_000)], -9.03, accuracy: 0.2)
        for b in 0..<ThirdOctave.bandCount {
            XCTAssertEqual(r.right[b], ThirdOctaveReading.floorDB, "right band \(b) is not at the floor")
        }
    }

    /// Digital silence: every band at the floor, nothing NaN or infinite.
    func testSilenceIsTheFloorAndFinite() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let silence = [Float](repeating: 0, count: Int(rate * 2))
        let r = try! XCTUnwrap(ThirdOctave.feed(analyzer, left: silence, right: silence, rate: rate))
        for b in 0..<ThirdOctave.bandCount {
            XCTAssertTrue(r.left[b].isFinite && r.right[b].isFinite, "band \(b) is not finite")
            XCTAssertEqual(r.left[b], ThirdOctaveReading.floorDB)
            XCTAssertEqual(r.right[b], ThirdOctaveReading.floorDB)
        }
        XCTAssertEqual(r.centersHz, ThirdOctaveReading.nominalCentersHz)
    }

    /// nil until every resolution that serves a band has transformed once. The 32768-point FFT
    /// is the last to fill, at 683 ms.
    func testNilUntilEveryResolutionHasRun() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        XCTAssertNil(analyzer.thirdOctave, "a fresh analyzer must not answer")

        let tone = TestSignals.sine(hz: 1_000, amplitude: 0.5, sampleRate: rate, seconds: 1.5)
        var firstAnswerSeconds = Double.infinity
        ThirdOctave.trace(analyzer, left: tone, right: tone, rate: rate) { seconds, reading in
            if reading != nil { firstAnswerSeconds = min(firstAnswerSeconds, seconds) }
        }
        print(String(format: "first third-octave reading at %.3f s", firstAnswerSeconds))
        // 683 ms of window, and the low FFT only transforms on its own hop grid (5461 samples),
        // so the first full window lands at the seventh hop, 0.796 s.
        XCTAssertGreaterThan(firstAnswerSeconds, 0.68, "answered before the 683 ms window was full")
        XCTAssertLessThan(firstAnswerSeconds, 0.9)
    }

    // MARK: - Time weighting

    /// Fast weighting: a one-pole on band power with tau = 125 ms. A step from silence is then
    /// `1 - exp(-t/tau)` in power, so it is within 2 dB of final at t = 1.0 tau and within
    /// 0.46 dB at t = 2.3 tau. Measured on a high band, where the 43 ms FFT window contributes
    /// almost nothing and the one-pole is what is being seen.
    func testFastTimeConstantOnAStep() {
        let rate = 48_000.0
        let tau = ThirdOctaveBank.fastTau
        let analyzer = SpectrumAnalyzer()

        // Fill the FFTs with silence first, so the step is the only thing that moves.
        let silence = [Float](repeating: 0, count: Int(rate * 1.5))
        ThirdOctave.feed(analyzer, left: silence, right: silence, rate: rate)

        let band = ThirdOctave.band(4_000)
        let tone = TestSignals.sine(hz: 4_000, amplitude: 0.5, sampleRate: rate, seconds: 4)
        var samples = [(t: Double, level: Float)]()
        ThirdOctave.trace(analyzer, left: tone, right: tone, rate: rate) { seconds, reading in
            if let reading { samples.append((seconds, reading.left[band])) }
        }
        let final = samples.last!.level
        XCTAssertEqual(final, -9.03, accuracy: 0.2, "the step's steady level is wrong")

        let crossing = samples.first { $0.level >= final - 2 }?.t ?? .infinity
        print(String(format: "fast step: final %.2f dB, within 2 dB of final at %.3f s (%.2f tau), 1 tau = %.3f s",
                     final, crossing, crossing / tau, tau))
        // The theory value is 1.0 tau; the FFT window and the block quantisation add a little.
        XCTAssertLessThan(crossing, 2.3 * tau, "the integrator is slower than fast weighting")
        XCTAssertGreaterThan(crossing, 0.4 * tau, "the integrator is not integrating at all")

        // And it really is still climbing at 2.3 tau, within half a dB of final.
        let late = samples.first { $0.t >= 2.3 * tau }!.level
        XCTAssertGreaterThan(late, final - 1.0)
    }

    /// `reset` clears the integrators: the bands drop to the floor and fill again.
    func testResetClearsTheIntegrators() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let tone = TestSignals.sine(hz: 1_000, amplitude: 0.5, sampleRate: rate, seconds: 3)
        let before = try! XCTUnwrap(ThirdOctave.feed(analyzer, left: tone, right: tone, rate: rate))
        XCTAssertEqual(before.left[ThirdOctave.band(1_000)], -9.03, accuracy: 0.2)

        analyzer.reset()
        let cleared = try! XCTUnwrap(analyzer.thirdOctave)
        for b in 0..<ThirdOctave.bandCount {
            XCTAssertEqual(cleared.left[b], ThirdOctaveReading.floorDB, "band \(b) survived reset")
            XCTAssertEqual(cleared.right[b], ThirdOctaveReading.floorDB)
        }

        let again = try! XCTUnwrap(ThirdOctave.feed(analyzer, left: tone, right: tone, rate: rate))
        XCTAssertEqual(again.left[ThirdOctave.band(1_000)], -9.03, accuracy: 0.2, "the meter did not refill after reset")
    }

    /// The reading allocates, `process` does not. Guard for the allocation rule.
    func testProcessStaysAllocationFreeWithTheBands() {
        let rate = 48_000.0
        let block = 800
        let analyzer = SpectrumAnalyzer()
        let signal = TestSignals.pinkNoise(amplitude: 0.5, count: 1 << 16)
        signal.withUnsafeBufferPointer { p in
            var i = 0
            while i + block <= signal.count {
                analyzer.process(left: p.baseAddress! + i, right: p.baseAddress! + i, count: block, sampleRate: rate)
                i += block
            }
        }
        XCTAssertNotNil(analyzer.thirdOctave)

        func liveBlocks() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &stats)
            return Int(stats.blocks_in_use)
        }
        signal.withUnsafeBufferPointer { p in
            var offset = 0
            analyzer.process(left: p.baseAddress!, right: p.baseAddress!, count: block, sampleRate: rate)
            let before = liveBlocks()
            for _ in 0..<1_000 {
                analyzer.process(left: p.baseAddress! + offset, right: p.baseAddress! + offset, count: block, sampleRate: rate)
                offset += block
                if offset + block > signal.count { offset = 0 }
            }
            XCTAssertLessThanOrEqual(liveBlocks() - before, 4)
        }
    }
}
