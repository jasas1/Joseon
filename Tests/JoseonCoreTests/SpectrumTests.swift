import XCTest
@testable import JoseonCore

/// Accuracy tests for `SpectrumAnalyzer`.
///
/// Every test drives the analyzer the way the engine does: 800-frame blocks through
/// `process`, then one `read`. Signals come from `TestSignals`, never from disk.
final class SpectrumTests: XCTestCase {

    // MARK: - Helpers

    /// Feed a stereo signal in 800-frame blocks (the engine's block size at 60 Hz / 48 kHz).
    private func feed(_ analyzer: SpectrumAnalyzer, left: [Float], right: [Float], sampleRate: Double, block: Int = 800) {
        precondition(left.count == right.count)
        var i = 0
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                while i < left.count {
                    let n = min(block, left.count - i)
                    analyzer.process(left: l.baseAddress! + i, right: r.baseAddress! + i, count: n, sampleRate: sampleRate)
                    i += n
                }
            }
        }
    }

    /// Feed the same signal to both channels.
    private func feedMono(_ analyzer: SpectrumAnalyzer, _ signal: [Float], sampleRate: Double, block: Int = 800) {
        feed(analyzer, left: signal, right: signal, sampleRate: sampleRate, block: block)
    }

    private func nearestBin(_ frequencies: [Float], _ hz: Float) -> Int {
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (i, f) in frequencies.enumerated() {
            let d = abs(log2(f / hz))
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    /// Highest value of `mid` inside a half-octave window around `hz`. Robust to the
    /// display grid landing between two bins.
    private func peakNear(_ reading: SpectrumReading, _ hz: Float, octaves: Float = 0.08) -> Float {
        var best = SpectrumReading.floorDB
        for (i, f) in reading.frequencies.enumerated() where abs(log2(f / hz)) <= octaves {
            best = max(best, reading.mid[i])
        }
        return best
    }

    private func sine(_ hz: Double, _ dbfs: Float, _ sampleRate: Double, _ seconds: Double) -> [Float] {
        TestSignals.sine(hz: hz, amplitude: pow(10, dbfs / 20), sampleRate: sampleRate, seconds: seconds)
    }

    // MARK: - 1. Calibration

    func testMinusSixSineReadsMinusSixAtEveryRate() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let analyzer = SpectrumAnalyzer()
            feedMono(analyzer, sine(1_000, -6, rate, 2.0), sampleRate: rate)
            let reading = analyzer.read().spectrum
            let bin = nearestBin(reading.frequencies, 1_000)
            XCTAssertEqual(reading.mid[bin], -6, accuracy: 0.3, "1 kHz -6 dBFS at \(rate) Hz")
            XCTAssertEqual(reading.left[bin], -6, accuracy: 0.3, "left at \(rate) Hz")
            XCTAssertEqual(reading.right[bin], -6, accuracy: 0.3, "right at \(rate) Hz")
        }
    }

    /// A full-scale sine must read 0 dBFS at any frequency and any FFT size, which means
    /// all three resolutions and both crossfade regions.
    func testFullScaleSineReadsZeroAtEveryFrequency() {
        let rate = 48_000.0
        for hz in [30.0, 55.0, 120.0, 200.0, 440.0, 1_000.0, 2_000.0, 3_150.0, 6_300.0, 12_000.0, 18_000.0] {
            let analyzer = SpectrumAnalyzer()
            feedMono(analyzer, sine(hz, 0, rate, 2.0), sampleRate: rate)
            let reading = analyzer.read().spectrum
            XCTAssertEqual(peakNear(reading, Float(hz)), 0, accuracy: 0.3, "\(hz) Hz full scale")
        }
    }

    /// Non-bin-centred frequencies are the scalloping worst case. Sweep a decade at
    /// irregular steps and hold the same 0.3 dB bar.
    func testCalibrationHoldsOffBinCentre() {
        let rate = 48_000.0
        for hz in stride(from: 997.0, through: 1_100.0, by: 7.3) {
            let analyzer = SpectrumAnalyzer()
            feedMono(analyzer, sine(hz, -12, rate, 1.5), sampleRate: rate)
            XCTAssertEqual(peakNear(analyzer.read().spectrum, Float(hz)), -12, accuracy: 0.3, "\(hz) Hz")
        }
    }

    // MARK: - 2. Resolution

    func testThirtyAndFortyHertzResolveWithADip() {
        let rate = 48_000.0
        let a = sine(30, -6, rate, 2.0)
        let b = sine(40, -6, rate, 2.0)
        let mixed = zip(a, b).map { $0 + $1 }
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, mixed, sampleRate: rate)
        let reading = analyzer.read().spectrum

        let peak30 = peakNear(reading, 30, octaves: 0.05)
        let peak40 = peakNear(reading, 40, octaves: 0.05)
        XCTAssertEqual(peak30, -6, accuracy: 1.0)
        XCTAssertEqual(peak40, -6, accuracy: 1.0)

        // Lowest point strictly between the two tones.
        var dip = Float.greatestFiniteMagnitude
        for (i, f) in reading.frequencies.enumerated() where f > 31 && f < 39 {
            dip = min(dip, reading.mid[i])
        }
        XCTAssertLessThanOrEqual(dip, min(peak30, peak40) - 6, "dip between 30 and 40 Hz was only \(min(peak30, peak40) - dip) dB")
    }

    func testFifteenKilohertzLocatedWithinOnePercent() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, sine(15_000, -3, rate, 2.0), sampleRate: rate)
        let (spectrum, peak, _) = analyzer.read()

        XCTAssertEqual(peak.frequencyHz, 15_000, accuracy: 150, "peak readout")

        // The display curve has to put the maximum there too.
        var argmax = 0
        for i in 1..<spectrum.mid.count where spectrum.mid[i] > spectrum.mid[argmax] { argmax = i }
        XCTAssertEqual(spectrum.frequencies[argmax], 15_000, accuracy: 150, "display maximum")
    }

    // MARK: - 2b. Tone shape

    /// Width in octaves of the region around the maximum that stays within `drop` dB of it,
    /// and the longest run of display bins that equal the maximum.
    private func peakShape(_ values: [Float], _ frequencies: [Float], drop: Float = 3) -> (octaves: Float, level: Float, hz: Float, topRun: Int) {
        let top = values.indices.max { values[$0] < values[$1] }!
        var lo = top, hi = top
        while lo > 0, values[lo - 1] > values[top] - drop { lo -= 1 }
        while hi < values.count - 1, values[hi + 1] > values[top] - drop { hi += 1 }
        var run = 0, longest = 0
        for i in lo...hi {
            if values[i] == values[top] { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        // Bin edges, not centres: one display bin already has a width.
        let step = log2(frequencies[1] / frequencies[0])
        return (log2(frequencies[hi] / frequencies[lo]) + step, values[top], frequencies[top], longest)
    }

    /// A lone tone is a pointed peak of the right height, not a flat-topped table as wide as
    /// the power sum. 1 kHz sits inside the bandwidth ramp, where the sum is widest.
    func testLoneToneIsAPointedPeak() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, sine(1_000, -6, rate, 2.0), sampleRate: rate)
        let reading = analyzer.read().spectrum
        for (name, curve) in [("mid", reading.mid), ("left", reading.left), ("peak hold", reading.peakHold)] {
            let shape = peakShape(curve, reading.frequencies)
            XCTAssertEqual(shape.level, -6, accuracy: 0.3, name)
            XCTAssertEqual(shape.hz, 1_000, accuracy: 8, name)
            XCTAssertLessThan(shape.octaves, 1.0 / 24, "\(name): -3 dB width was 1/\(1 / shape.octaves) octave")
            XCTAssertLessThan(shape.topRun, 3, "\(name): flat top of \(shape.topRun) display bins")
        }
        // The skirt falls fast: 1/6 octave away the curve is far below the tone.
        let away = reading.mid[nearestBin(reading.frequencies, 1_000 * pow(2, 1.0 / 6))]
        XCTAssertLessThan(away, -6 - 40)
    }

    /// The same at the frequencies where the round 1 render showed tables: low resolution, low/mid
    /// crossfade, both bandwidth ramps. On-bin and off-bin tones, with a noise floor under them.
    func testTonesOverNoiseStayPointedAtEveryResolution() {
        let rate = 48_000.0
        for hz in [55.0, 98.0, 146.83, 220.0, 440.0, 1_000.0, 2_500.0, 6_200.0] {
            let analyzer = SpectrumAnalyzer()
            let tone = sine(hz, -12, rate, 2.0)
            let noise = TestSignals.pinkNoise(amplitude: 0.01, count: tone.count)
            feedMono(analyzer, zip(tone, noise).map { $0 + $1 }, sampleRate: rate)
            let reading = analyzer.read().spectrum
            let shape = peakShape(reading.mid, reading.frequencies)
            XCTAssertEqual(shape.level, -12, accuracy: 0.4, "\(hz) Hz")
            XCTAssertEqual(Double(shape.hz), hz, accuracy: hz * 0.02, "\(hz) Hz")
            XCTAssertLessThan(shape.octaves, hz < 80 ? 1.0 / 12 : 1.0 / 20, "\(hz) Hz: -3 dB width was 1/\(1 / shape.octaves) octave")
            XCTAssertLessThan(shape.topRun, 3, "\(hz) Hz")
        }
    }

    // MARK: - 3. Low-end smoothness

    /// Below ~100 Hz a 1024-bin log grid is much finer than the FFT grid. The curve must
    /// be interpolated, not a staircase of repeated FFT-bin values.
    func testLowEndHasNoStairSteps() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, TestSignals.pinkNoise(amplitude: 0.5, count: Int(rate * 2)), sampleRate: rate)
        let reading = analyzer.read().spectrum

        var run = 1
        var longestRun = 1
        var previous = Float.nan
        for (i, f) in reading.frequencies.enumerated() where f >= 20 && f <= 120 {
            let v = reading.mid[i]
            if v == previous { run += 1; longestRun = max(longestRun, run) } else { run = 1 }
            previous = v
        }
        XCTAssertLessThanOrEqual(longestRun, 2, "found a plateau of \(longestRun) identical display bins below 120 Hz")
    }

    // MARK: - 4. Note readout

    func testNoteNames() {
        let rate = 48_000.0
        for (hz, name) in [(415.30, "G#4"), (440.0, "A4"), (261.6256, "C4"), (1_760.0, "A6")] {
            let analyzer = SpectrumAnalyzer()
            feedMono(analyzer, sine(hz, -6, rate, 2.0), sampleRate: rate)
            let peak = analyzer.read().peak
            XCTAssertEqual(peak.noteName, name, "\(hz) Hz")
            XCTAssertEqual(peak.cents, 0, accuracy: 3, "\(hz) Hz cents")
        }
    }

    func testNoteIsBlankWhenThePeakDoesNotStandOut() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, TestSignals.whiteNoise(amplitude: 0.3, count: Int(rate * 2)), sampleRate: rate)
        XCTAssertEqual(analyzer.read().peak.noteName, "", "white noise has no note")
    }

    // MARK: - 5. Silence

    func testSilenceReadsFloorAndNoNote() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, [Float](repeating: 0, count: Int(rate * 2)), sampleRate: rate)
        let (spectrum, peak, bands) = analyzer.read()

        for value in spectrum.mid { XCTAssertEqual(value, SpectrumReading.floorDB) }
        for value in spectrum.left { XCTAssertEqual(value, SpectrumReading.floorDB) }
        for value in spectrum.right { XCTAssertEqual(value, SpectrumReading.floorDB) }
        for value in spectrum.side { XCTAssertEqual(value, SpectrumReading.floorDB) }
        for value in spectrum.peakHold { XCTAssertEqual(value, SpectrumReading.floorDB) }
        for value in spectrum.average { XCTAssertEqual(value, SpectrumReading.floorDB) }
        XCTAssertEqual(peak.noteName, "")
        XCTAssertEqual(peak.levelDB, SpectrumReading.floorDB)
        for value in bands.values { XCTAssertEqual(value, SpectrumReading.floorDB, accuracy: 0.001) }
    }

    // MARK: - 6. Peak hold

    func testPeakHoldDecaysAtTheSetRate() {
        let rate = 48_000.0
        var settings = SpectrumSettings()
        settings.peakDecayDBPerSecond = 12
        settings.releaseSeconds = 0.0001      // collapse the live curve so only the hold is left
        let analyzer = SpectrumAnalyzer(settings: settings)

        feedMono(analyzer, sine(1_000, -6, rate, 2.0), sampleRate: rate)
        let bin = nearestBin(analyzer.read().spectrum.frequencies, 1_000)
        let start = analyzer.read().spectrum.peakHold[bin]
        XCTAssertEqual(start, -6, accuracy: 0.3)

        // 1.5 s of silence: the hold should have fallen 12 dB/s * 1.5 s = 18 dB.
        let seconds = 1.5
        feedMono(analyzer, [Float](repeating: 0, count: Int(rate * seconds)), sampleRate: rate)
        let after = analyzer.read().spectrum.peakHold[bin]
        XCTAssertEqual(after, start - Float(12 * seconds), accuracy: 0.5)
    }

    // MARK: - 7. Tilt

    func testTiltPivotsAtOneKilohertz() {
        let rate = 48_000.0
        let noise = TestSignals.pinkNoise(amplitude: 0.5, count: Int(rate * 2))

        let flat = SpectrumAnalyzer()
        feedMono(flat, noise, sampleRate: rate)
        let flatReading = flat.read().spectrum

        var tilted = SpectrumSettings()
        tilted.tiltDBPerOctave = 4.5
        let sloped = SpectrumAnalyzer(settings: tilted)
        feedMono(sloped, noise, sampleRate: rate)
        let slopedReading = sloped.read().spectrum

        let low = nearestBin(flatReading.frequencies, 100)
        let high = nearestBin(flatReading.frequencies, 10_000)
        let expectedLow = 4.5 * log2(flatReading.frequencies[low] / 1_000)
        let expectedHigh = 4.5 * log2(flatReading.frequencies[high] / 1_000)

        XCTAssertEqual(slopedReading.mid[low] - flatReading.mid[low], expectedLow, accuracy: 0.05)
        XCTAssertEqual(slopedReading.mid[high] - flatReading.mid[high], expectedHigh, accuracy: 0.05)
        // 100 Hz and 10 kHz are three and a third octaves either side of the pivot.
        XCTAssertEqual(expectedHigh - expectedLow, 29.9, accuracy: 0.2)

        let pivot = nearestBin(flatReading.frequencies, 1_000)
        XCTAssertEqual(slopedReading.mid[pivot], flatReading.mid[pivot], accuracy: 0.05)
    }

    // MARK: - 8. Band energy

    func testBandEnergyPlacesTonesInTheRightBand() {
        let rate = 48_000.0

        let bass = SpectrumAnalyzer()
        feedMono(bass, sine(100, 0, rate, 2.0), sampleRate: rate)
        let bassBands = bass.read().bands
        XCTAssertEqual(bassBands.bass, 0, accuracy: 0.3)
        XCTAssertEqual(bassBands.values.firstIndex(of: bassBands.values.max()!), 1, "100 Hz belongs to bass")
        XCTAssertLessThan(bassBands.subBass, bassBands.bass - 40)
        XCTAssertLessThan(bassBands.lowMid, bassBands.bass - 40)

        let presence = SpectrumAnalyzer()
        feedMono(presence, sine(5_000, 0, rate, 2.0), sampleRate: rate)
        let presenceBands = presence.read().bands
        XCTAssertEqual(presenceBands.presence, 0, accuracy: 0.3)
        XCTAssertEqual(presenceBands.values.firstIndex(of: presenceBands.values.max()!), 5, "5 kHz belongs to presence")
        XCTAssertLessThan(presenceBands.upperMid, presenceBands.presence - 40)
        XCTAssertLessThan(presenceBands.brilliance, presenceBands.presence - 40)
    }

    // MARK: - 9. Channels

    func testLeftOnlySignalGivesEqualMidAndSideAndSilentRight() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let tone = sine(1_000, 0, rate, 2.0)
        feed(analyzer, left: tone, right: [Float](repeating: 0, count: tone.count), sampleRate: rate)
        let reading = analyzer.read().spectrum
        let bin = nearestBin(reading.frequencies, 1_000)

        XCTAssertEqual(reading.left[bin], 0, accuracy: 0.3)
        XCTAssertEqual(reading.right[bin], SpectrumReading.floorDB, "right channel is silent")
        XCTAssertEqual(reading.mid[bin], reading.side[bin], accuracy: 0.01, "mid and side match for a one-sided signal")
        XCTAssertEqual(reading.mid[bin], -6, accuracy: 0.3, "mid is half the amplitude of left")
    }

    // MARK: - 10. Reconfiguration

    func testSampleRateChangeReconfiguresCleanly() {
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, sine(1_000, -6, 48_000, 2.0), sampleRate: 48_000)
        XCTAssertEqual(analyzer.read().spectrum.mid[nearestBin(analyzer.read().spectrum.frequencies, 1_000)], -6, accuracy: 0.3)

        feedMono(analyzer, sine(1_000, -6, 96_000, 2.0), sampleRate: 96_000)
        let after = analyzer.read().spectrum
        XCTAssertEqual(after.mid[nearestBin(after.frequencies, 1_000)], -6, accuracy: 0.3, "after switching to 96 kHz")

        feedMono(analyzer, sine(3_000, -10, 44_100, 2.0), sampleRate: 44_100)
        let back = analyzer.read().spectrum
        XCTAssertEqual(peakNear(back, 3_000), -10, accuracy: 0.3, "after switching to 44.1 kHz")
    }

    func testDisplayGridFollowsSettings() {
        var settings = SpectrumSettings()
        settings.displayBins = 256
        settings.minHz = 20
        settings.maxHz = 20_000
        let analyzer = SpectrumAnalyzer(settings: settings)
        feedMono(analyzer, sine(1_000, -6, 48_000, 1.5), sampleRate: 48_000)
        let reading = analyzer.read().spectrum

        XCTAssertEqual(reading.frequencies.count, 256)
        XCTAssertEqual(reading.left.count, 256)
        XCTAssertEqual(reading.right.count, 256)
        XCTAssertEqual(reading.mid.count, 256)
        XCTAssertEqual(reading.side.count, 256)
        XCTAssertEqual(reading.peakHold.count, 256)
        XCTAssertEqual(reading.average.count, 256)
        XCTAssertEqual(reading.frequencies.first!, 20, accuracy: 0.01)
        XCTAssertEqual(reading.frequencies.last!, 20_000, accuracy: 0.5)
        XCTAssertEqual(reading.mid[nearestBin(reading.frequencies, 1_000)], -6, accuracy: 0.3)
    }

    func testHighSampleRatesKeepTheSameWindowDurations() {
        for rate in [88_200.0, 176_400.0, 192_000.0] {
            let analyzer = SpectrumAnalyzer()
            feedMono(analyzer, sine(1_000, -6, rate, 2.0), sampleRate: rate, block: 3_200)
            let reading = analyzer.read().spectrum
            XCTAssertEqual(reading.mid[nearestBin(reading.frequencies, 1_000)], -6, accuracy: 0.3, "1 kHz at \(rate) Hz")
            // Above Nyquist there is nothing to show.
            for (i, f) in reading.frequencies.enumerated() where f > Float(rate / 2) {
                XCTAssertEqual(reading.mid[i], SpectrumReading.floorDB)
            }
        }
    }

    func testSettingsCanChangeWhileRunning() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, sine(1_000, -6, rate, 2.0), sampleRate: rate)
        XCTAssertEqual(analyzer.read().spectrum.frequencies.count, 1_024)

        let flat = analyzer.read().spectrum
        analyzer.settings.tiltDBPerOctave = 3
        let tilted = analyzer.read().spectrum
        let bin = nearestBin(tilted.frequencies, 4_000)
        XCTAssertEqual(tilted.mid[bin] - flat.mid[bin], 6, accuracy: 0.05, "tilt takes effect without a restart")
        XCTAssertEqual(tilted.mid[nearestBin(tilted.frequencies, 1_000)], -6, accuracy: 0.3, "the pivot does not move")

        analyzer.settings.displayBins = 512
        analyzer.settings.tiltDBPerOctave = 0
        feedMono(analyzer, sine(1_000, -6, rate, 2.0), sampleRate: rate)
        let regridded = analyzer.read().spectrum
        XCTAssertEqual(regridded.frequencies.count, 512)
        XCTAssertEqual(regridded.mid[nearestBin(regridded.frequencies, 1_000)], -6, accuracy: 0.3)
    }

    // MARK: - 11. Average and reset

    func testAverageTracksTheLongTermLevelAndResetClearsIt() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, sine(1_000, -6, rate, 3.0), sampleRate: rate)
        var reading = analyzer.read().spectrum
        let bin = nearestBin(reading.frequencies, 1_000)
        // The first ~0.7 s is FFT warm-up at the floor, so the power average sits below the
        // live value but well above the floor.
        XCTAssertGreaterThan(reading.average[bin], -12)
        XCTAssertLessThanOrEqual(reading.average[bin], reading.mid[bin] + 0.1)

        analyzer.reset()
        XCTAssertEqual(analyzer.read().spectrum.average[bin], SpectrumReading.floorDB, "reset clears the average")

        // After the reset the tone is already steady, so the average converges on it.
        feedMono(analyzer, sine(1_000, -6, rate, 3.0), sampleRate: rate)
        reading = analyzer.read().spectrum
        XCTAssertEqual(reading.average[bin], -6, accuracy: 0.3)
    }

    // MARK: - 12. Crossfade

    /// A seam is a discontinuity. The crossfade has to make the switch of FFT size
    /// invisible: no step between neighbouring display bins that is worse than the normal
    /// bin-to-bin variation of the same noise elsewhere.
    ///
    /// The curve does gain slope across each crossover, because the coarser FFT collects
    /// noise over a wider bandwidth. That is inherent to a tone-calibrated multi-resolution
    /// display and is documented as a known limit; it is measured here, not asserted away.
    func testNoStepAtTheCrossoverFrequencies() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, TestSignals.pinkNoise(amplitude: 0.5, count: Int(rate * 4)), sampleRate: rate)
        let reading = analyzer.read().spectrum

        let control = maxStep(reading, around: 700, octaves: 0.5)   // pure mid resolution
        for crossover in [Float(200), Float(2_000)] {
            let step = maxStep(reading, around: crossover, octaves: 0.15)
            XCTAssertLessThanOrEqual(step, control, "step at \(crossover) Hz was \(step) dB, control \(control) dB")

            let below = mean(reading, around: crossover, from: -0.75, to: -0.55)
            let above = mean(reading, around: crossover, from: 0.55, to: 0.75)
            print("crossover \(crossover) Hz: \(below) dB -> \(above) dB over 1.3 octaves (pink noise)")
        }
    }

    /// White noise has a flat true spectrum, so the displayed curve shows exactly the
    /// analyzer's own bandwidth against frequency: flat inside a resolution, rising where
    /// the analysis bandwidth widens. The rise must be spread out, never concentrated into
    /// a bump at a crossover.
    func testWhiteNoiseCurveRisesGentlyAndNeverDips() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, TestSignals.whiteNoise(amplitude: 0.5, count: Int(rate * 6)), sampleRate: rate)
        let reading = analyzer.read().spectrum

        // Read the long-term power average, not the live curve: one noise frame per display
        // bin scatters by a couple of dB, which would swamp the slope being measured.
        let probes: [Float] = [25, 50, 100, 200, 400, 800, 1_600, 3_200, 6_400, 12_800]
        let levels = probes.map { hz -> Float in
            var sum: Float = 0
            var count = 0
            for (i, f) in reading.frequencies.enumerated() where abs(log2(f / hz)) <= 0.25 {
                sum += reading.average[i]
                count += 1
            }
            return sum / Float(count)
        }
        for i in 1..<levels.count {
            let slope = levels[i] - levels[i - 1]
            XCTAssertGreaterThan(slope, -1.0, "dip after \(probes[i - 1]) Hz")
            XCTAssertLessThan(slope, 3.5, "bandwidth bump at \(probes[i]) Hz")
        }
        // Two 4x bandwidth steps between the three FFT sizes: about 12 dB end to end.
        XCTAssertEqual(levels.last! - levels.first!, 12, accuracy: 3)
    }

    private func maxStep(_ reading: SpectrumReading, around hz: Float, octaves: Float) -> Float {
        var worst: Float = 0
        for i in 1..<reading.frequencies.count where abs(log2(reading.frequencies[i] / hz)) <= octaves {
            worst = max(worst, abs(reading.mid[i] - reading.mid[i - 1]))
        }
        return worst
    }

    private func mean(_ reading: SpectrumReading, around hz: Float, from: Float, to: Float) -> Float {
        var sum: Float = 0
        var count = 0
        for (i, f) in reading.frequencies.enumerated() {
            let octaves = log2(f / hz)
            if octaves >= from && octaves <= to { sum += reading.mid[i]; count += 1 }
        }
        return count > 0 ? sum / Float(count) : SpectrumReading.floorDB
    }

    // MARK: - 13. Release

    func testAttackIsInstantAndReleaseIsSlower() {
        let rate = 48_000.0
        var settings = SpectrumSettings()
        settings.releaseSeconds = 0.25
        let analyzer = SpectrumAnalyzer(settings: settings)

        feedMono(analyzer, sine(1_000, -6, rate, 2.0), sampleRate: rate)
        var reading = analyzer.read().spectrum
        let bin = nearestBin(reading.frequencies, 1_000)
        XCTAssertEqual(reading.mid[bin], -6, accuracy: 0.3, "attack reaches the level at once")

        // One time constant of silence closes ~63% of the gap towards the floor.
        feedMono(analyzer, [Float](repeating: 0, count: Int(rate * 0.25)), sampleRate: rate)
        reading = analyzer.read().spectrum
        XCTAssertLessThan(reading.mid[bin], -6)
        XCTAssertGreaterThan(reading.mid[bin], SpectrumReading.floorDB, "release is not instant")
    }
}
