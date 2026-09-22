import XCTest
@testable import JoseonCore

/// Round 3 regression tests: the displayed noise floor is one continuous curve, and the
/// bottom two octaves follow the data instead of sitting on a flat shelf.
///
/// Round 2 saw a hard step near 420 Hz, a dark column near 395 Hz and a kink near 320 Hz.
/// Measurement found three causes, all in `SpectrumResolution`, none of them the FFT
/// crossfade the critic suspected:
///
/// 1. The tonal main lobe was *drawn* over the noise curve with `max` and stopped dead at
///    +-2 bins, so every peak ended in a 6-10 dB vertical step.
/// 2. The bins whose lobe had been removed were filled with the quietest of four context
///    blocks, which reads about 2.5 dB low on noise, so the sliding sum was notched beside
///    every peak: the dark column.
/// 3. The sliding sum's half-width was an integer number of FFT bins, so the displayed noise
///    floor stepped 1.5 dB (5 bins -> 7 bins) wherever the quantiser ticked - at the same
///    frequency for every signal, which is what made it look like an FFT boundary.
///
/// The fixes are a power-domain `noise + tone` curve, an unbiased fill, a fractional
/// bandwidth ramp, a power *mean* instead of a max where a display bin holds several FFT
/// bins, and a constant-Q smoothing of the noise curve only.
final class SpectrumSeamTests: XCTestCase {

    private func feed(_ analyzer: SpectrumAnalyzer, left: [Float], right: [Float], sampleRate: Double) {
        precondition(left.count == right.count)
        var i = 0
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                while i < left.count {
                    let n = min(800, left.count - i)
                    analyzer.process(left: l.baseAddress! + i, right: r.baseAddress! + i, count: n, sampleRate: sampleRate)
                    i += n
                }
            }
        }
    }

    /// Display bins that are part of a tonal peak: within `octaves` of any bin that stands
    /// `overDB` above the median of the curve in a half-octave window around it. The brief's
    /// bar is about the noise floor between the peaks, not about the peaks themselves - a
    /// real tone in a 43 ms window is one FFT bin wide and its skirt is meant to be steep.
    private func tonalMask(_ values: [Float], _ frequencies: [Float], overDB: Float = 6, octaves: Float = 1.0 / 6) -> [Bool] {
        let n = values.count
        var isPeak = [Bool](repeating: false, count: n)
        var lo = 0, hi = 0
        var window = [Float]()
        for i in 0..<n {
            let f = frequencies[i]
            while lo < n, frequencies[lo] < f / pow(2, 0.25) { lo += 1 }
            while hi < n, frequencies[hi] <= f * pow(2, 0.25) { hi += 1 }
            guard hi > lo else { continue }
            window.removeAll(keepingCapacity: true)
            window.append(contentsOf: values[lo..<hi])
            window.sort()
            if values[i] > window[window.count / 2] + overDB { isPeak[i] = true }
        }
        var mask = [Bool](repeating: false, count: n)
        for i in 0..<n where isPeak[i] {
            for j in 0..<n where abs(log2(frequencies[j] / frequencies[i])) <= octaves { mask[j] = true }
        }
        return mask
    }

    private func worstStep(_ values: [Float], _ frequencies: [Float], from: Float, to: Float, mask: [Bool]) -> (dB: Float, hz: Float) {
        var worst: Float = 0
        var at: Float = 0
        for i in 1..<values.count where frequencies[i] >= from && frequencies[i] <= to {
            if mask[i] || mask[i - 1] { continue }
            let step = abs(values[i] - values[i - 1])
            if step > worst { worst = step; at = frequencies[i] }
        }
        return (worst, at)
    }

    // MARK: - 1. No seam

    /// Pink noise alone: every display bin from 100 Hz to 5 kHz is a noise-floor bin, so the
    /// whole range has to be continuous. Both crossovers (200 Hz, 2 kHz) and both bandwidth
    /// ramps are inside it.
    func testNoiseFloorHasNoStepAtAnySampleRate() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let analyzer = SpectrumAnalyzer()
            let l = TestSignals.pinkNoise(amplitude: 0.5, count: Int(rate * 4), seed: 0x5EED)
            let r = TestSignals.pinkNoise(amplitude: 0.5, count: Int(rate * 4), seed: 0xC0FFEE)
            feed(analyzer, left: l, right: r, sampleRate: rate)
            let reading = analyzer.read().spectrum
            for (name, curve) in [("mid", reading.mid), ("left", reading.left), ("right", reading.right)] {
                let mask = tonalMask(curve, reading.frequencies)
                let step = worstStep(curve, reading.frequencies, from: 100, to: 5_000, mask: mask)
                XCTAssertLessThanOrEqual(step.dB, 1.5, "\(name) at \(rate) Hz: \(step.dB) dB step at \(step.hz) Hz")
            }
        }
    }

    /// Pink noise under the demo signal: the same bar, with the demo's partials and their
    /// skirts excluded. This is the signal the round 2 render used.
    func testDemoSignalNoiseFloorHasNoStep() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let analyzer = SpectrumAnalyzer()
            let count = Int(rate * 4)
            let demo = TestSignals.demoBlock(startSample: 0, count: count, sampleRate: rate)
            let nl = TestSignals.pinkNoise(amplitude: 0.05, count: count, seed: 0x5EED)
            let nr = TestSignals.pinkNoise(amplitude: 0.05, count: count, seed: 0xC0FFEE)
            feed(analyzer,
                 left: zip(demo.left, nl).map { $0 + $1 },
                 right: zip(demo.right, nr).map { $0 + $1 },
                 sampleRate: rate)
            let reading = analyzer.read().spectrum
            for (name, curve) in [("mid", reading.mid), ("left", reading.left), ("right", reading.right)] {
                let mask = tonalMask(curve, reading.frequencies)
                let step = worstStep(curve, reading.frequencies, from: 100, to: 5_000, mask: mask)
                XCTAssertLessThanOrEqual(step.dB, 1.5, "\(name) at \(rate) Hz: \(step.dB) dB step at \(step.hz) Hz")
            }
        }
    }

    /// The analysis bandwidth has to be a continuous function of frequency, or the long-term
    /// average - which has no frame-to-frame scatter left in it - shows the ledge. Round 2
    /// stepped 0.6-1.1 dB at 568, 800, 997, 1206 and 1426 Hz, one step per integer tap count.
    func testLongTermAverageIsSmooth() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let l = TestSignals.pinkNoise(amplitude: 0.5, count: Int(rate * 8), seed: 0x11)
        let r = TestSignals.pinkNoise(amplitude: 0.5, count: Int(rate * 8), seed: 0x22)
        feed(analyzer, left: l, right: r, sampleRate: rate)
        let reading = analyzer.read().spectrum
        let mask = [Bool](repeating: false, count: reading.average.count)
        let step = worstStep(reading.average, reading.frequencies, from: 30, to: 15_000, mask: mask)
        XCTAssertLessThanOrEqual(step.dB, 0.8, "average stepped \(step.dB) dB at \(step.hz) Hz")
    }

    // MARK: - 2. The bottom two octaves follow the data

    /// A 30 Hz and a 60 Hz tone. Below the 30 Hz peak the curve has to fall away, not sit on
    /// a shelf: round 2 drew a dead-flat line from 20 to 27 Hz whatever the signal was.
    func testLowEndFollowsATonePair() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let a = TestSignals.sine(hz: 30, amplitude: 0.5, sampleRate: rate, seconds: 3)
        let b = TestSignals.sine(hz: 60, amplitude: 0.25, sampleRate: rate, seconds: 3)
        let mixed = zip(a, b).map { $0 + $1 }
        feed(analyzer, left: mixed, right: mixed, sampleRate: rate)
        let reading = analyzer.read().spectrum

        func value(_ hz: Float) -> Float {
            var best = SpectrumReading.floorDB
            for (i, f) in reading.frequencies.enumerated() where abs(log2(f / hz)) <= 0.02 { best = max(best, reading.mid[i]) }
            return best
        }
        XCTAssertEqual(value(30), -6, accuracy: 0.5, "30 Hz tone")
        XCTAssertEqual(value(60), -12, accuracy: 0.5, "60 Hz tone")

        // 20 Hz is two thirds of an octave below the 30 Hz tone, far outside its main lobe.
        XCTAssertLessThan(value(20), value(30) - 40, "20 Hz sits on the skirt of the 30 Hz tone, not on a shelf")
        // The skirt has to keep falling all the way down, not flatten out.
        XCTAssertLessThan(value(20), value(24) - 5, "curve is flat between 20 and 24 Hz")

        // No plateau: a run of display bins with the same value is the staircase this replaced.
        var run = 1, longest = 1
        for (i, f) in reading.frequencies.enumerated() where f >= 20 && f <= 90 && i > 0 {
            if reading.mid[i] == reading.mid[i - 1] { run += 1; longest = max(longest, run) } else { run = 1 }
        }
        XCTAssertLessThanOrEqual(longest, 3, "plateau of \(longest) identical display bins between 20 and 90 Hz")
    }

    /// Pink noise: the bottom two octaves have to show the FFT's own structure. A 32768-point
    /// window at 48 kHz resolves 1.5 Hz, so 20-40 Hz is 13 independent measurements and the
    /// curve should move by several dB across it. Round 2 summed five bins there - 7.3 Hz, half
    /// an octave at 20 Hz - which flattened all of it away.
    func testLowEndFollowsNoise() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let analyzer = SpectrumAnalyzer()
            let noise = TestSignals.pinkNoise(amplitude: 0.5, count: Int(rate * 3), seed: 0xBEEF)
            feed(analyzer, left: noise, right: noise, sampleRate: rate)
            let reading = analyzer.read().spectrum
            var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
            var run = 1, longest = 1
            var previous = Float.nan
            for (i, f) in reading.frequencies.enumerated() where f >= 20 && f <= 40 {
                lo = min(lo, reading.mid[i]); hi = max(hi, reading.mid[i])
                if reading.mid[i] == previous { run += 1; longest = max(longest, run) } else { run = 1 }
                previous = reading.mid[i]
                _ = i
            }
            XCTAssertGreaterThan(hi - lo, 2.0, "20-40 Hz is flat to within \(hi - lo) dB at \(rate) Hz")
            XCTAssertLessThanOrEqual(longest, 3, "plateau of \(longest) identical display bins at \(rate) Hz")
        }
    }

    /// Below the first usable FFT bin there is no data at all. The curve fades towards the
    /// floor instead of holding the value of bin 1 across the whole range.
    func testBelowTheFirstFFTBinFadesToTheFloor() {
        let rate = 48_000.0
        var settings = SpectrumSettings()
        settings.minHz = 0.2               // the 32768-point window's first bin is 1.46 Hz
        settings.maxHz = 20_000
        let analyzer = SpectrumAnalyzer(settings: settings)
        let noise = TestSignals.pinkNoise(amplitude: 0.5, count: Int(rate * 2))
        feed(analyzer, left: noise, right: noise, sampleRate: rate)
        let reading = analyzer.read().spectrum

        var previous = -Float.greatestFiniteMagnitude
        var rising = 0
        for (i, f) in reading.frequencies.enumerated() where f < 1.4 {
            if reading.mid[i] > previous + 0.001 { rising += 1 }
            previous = reading.mid[i]
            _ = i
        }
        let bottom = reading.mid[0]
        let edge = reading.mid.enumerated().first { reading.frequencies[$0.offset] >= 1.46 }!.element
        XCTAssertLessThan(bottom, edge - 20, "0.2 Hz should be far below the first real bin, not a plateau")
        XCTAssertGreaterThan(rising, 0, "the fade should be monotone upward towards the first real bin")
    }
}
