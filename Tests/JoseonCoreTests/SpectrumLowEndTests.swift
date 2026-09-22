import XCTest
@testable import JoseonCore

/// Round 4, the 20-27 Hz shelf. The question was whether the flat part of the demo render below
/// 27 Hz is drawn by the analyzer (first usable bin, interpolation anchor, DC leakage) or is in
/// the signal. These tests compare the curve with the continuous spectrum of the same window,
/// computed directly, and check that DC does not leak into the audible range.
final class SpectrumLowEndTests: XCTestCase {

    /// Power of the Hann-windowed signal at an arbitrary frequency, calibrated like the analyzer
    /// (a full-scale sine reads 1.0 when its main lobe is summed).
    static func windowedPower(_ x: [Float], hz: Double, rate: Double) -> Double {
        let n = x.count
        var re = 0.0, im = 0.0, sumSquares = 0.0
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))
            let p = 2 * Double.pi * hz * Double(i) / rate
            re += Double(x[i]) * w * cos(p)
            im -= Double(x[i]) * w * sin(p)
            sumSquares += w * w
        }
        return 4 * (re * re + im * im) / (Double(n) * sumSquares)
    }

    static func lowResolution(bins n: Int = 1024) -> (SpectrumResolution, [Float]) {
        let ratio: Float = 2400
        let step = pow(ratio, 1 / Float(n - 1))
        let freqs = (0..<n).map { 10 * pow(ratio, Float($0) / Float(n - 1)) }
        let size = 32_768
        let df = Float(48_000.0 / Double(size))
        let res = SpectrumResolution(size: size, hop: size / 6, sampleRate: 48_000)!
        let weight = freqs.map { $0 < 300 ? Float(1) : 0 }
        res.updateMap(displayBins: n, frequencies: freqs, binRatio: step, weight: weight,
                      targetBandwidthHz: { _ in 3 * df }, toneBinHz: { _ in df })
        return (res, freqs)
    }

    func testDemoCurveBelow40HzIsTheSpectrumOfTheWindow() {
        let (res, freqs) = Self.lowResolution()
        let size = res.size
        let df = 48_000.0 / Double(size)
        var log = "\n== demo, low FFT, one frame vs direct spectrum ==\n"
        var worst = 0.0
        for endSeconds in [7.3, 7.6, 8.0] {
            let end = Int(endSeconds * 48_000)
            let s = TestSignals.demoBlock(startSample: end - size, count: size)
            res.transform(historyL: s.left, historyR: s.right, capacity: size, mask: size - 1, end: 0)
            let mid = zip(s.left, s.right).map { ($0 + $1) / 2 }
            for (i, f) in freqs.enumerated() where f >= 20 && f <= 40 && i % 4 == 0 {
                // The noise curve is a 3-bin power sum: the same sum on the continuous spectrum.
                let reference = 10 * log10((-1...1).reduce(0.0) { $0 + Self.windowedPower(mid, hz: Double(f) + Double($1) * df, rate: 48_000) })
                let shown = Double(res.displayDB.p[SpectrumResolution.chMid * freqs.count + i])
                log += String(format: "t %.1f  %5.1f Hz  shown %7.2f  spectrum %7.2f\n", endSeconds, f, shown, reference)
                worst = max(worst, abs(shown - reference))
            }
        }
        print(log)
        XCTAssertLessThanOrEqual(worst, 3.0, "curve and spectrum differ by \(worst) dB between 20 and 40 Hz")
    }

    /// A DC offset of 0.01 (-40 dBFS, far over the noise) must not show anywhere in the plot. A
    /// periodic Hann window puts DC into bins 0 and 1 only (1.46 Hz at 48 kHz) and its sidelobes
    /// are exact zeros at every other bin, so no DC blocker is needed in front of the long FFT;
    /// this test is what would say otherwise.
    func testDCOffsetDoesNotLiftTheLowEnd() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let count = Int(rate * 3)
            let noise = TestSignals.pinkNoise(amplitude: 0.02, count: count, seed: 0xD0C)
            let offset = noise.map { $0 + 0.01 }
            func curve(_ x: [Float]) -> SpectrumReading {
                let analyzer = SpectrumAnalyzer()
                var i = 0
                x.withUnsafeBufferPointer { p in
                    while i < x.count {
                        let n = min(800, x.count - i)
                        analyzer.process(left: p.baseAddress! + i, right: p.baseAddress! + i, count: n, sampleRate: rate)
                        i += n
                    }
                }
                return analyzer.read().spectrum
            }
            let clean = curve(noise), dirty = curve(offset)
            var worst: Float = 0, worstHz: Float = 0
            for (i, f) in clean.frequencies.enumerated() where f >= 10 {
                for (a, b) in [(clean.mid[i], dirty.mid[i]), (clean.left[i], dirty.left[i])] {
                    if abs(a - b) > worst { worst = abs(a - b); worstHz = f }
                }
            }
            XCTAssertLessThanOrEqual(worst, 0.5, "DC moved the curve by \(worst) dB at \(worstHz) Hz, rate \(rate)")
        }
    }

    /// The long-term line counts time per display bin, from the moment the FFT that feeds the bin
    /// has data. With one clock for all bins, the bins under 40 Hz - fed only by the 32768-point
    /// FFT, which has nothing for its first 0.8 s - averaged the floor over that time, and the
    /// long-term line of a steady 30 Hz sine read about 5 dB under the live line after 1.12 s.
    func testLongTermLineMatchesTheLiveLineForASteadyThirtyHertzSine() {
        let rate = 48_000.0
        let x = TestSignals.sine(hz: 30, amplitude: Float(pow(10, -12.0 / 20)), sampleRate: rate, seconds: 1.12)
        let analyzer = SpectrumAnalyzer()
        x.withUnsafeBufferPointer { p in
            var i = 0
            while i < x.count {
                let n = min(800, x.count - i)
                analyzer.process(left: p.baseAddress! + i, right: p.baseAddress! + i, count: n, sampleRate: rate)
                i += n
            }
        }
        let reading = analyzer.read().spectrum
        func peak(_ curve: [Float]) -> Float {
            zip(reading.frequencies, curve).filter { abs(log2($0.0 / 30)) <= 0.05 }.map(\.1).max()!
        }
        let live = peak(reading.mid), average = peak(reading.average)
        print(String(format: "30 Hz sine at -12 dBFS after 1.12 s: live %.2f dB, long-term %.2f dB, difference %.2f dB", live, average, average - live))
        XCTAssertEqual(live, -12, accuracy: 1.0, "the live line reads the sine")
        XCTAssertEqual(average, live, accuracy: 0.5, "the long-term line of a steady tone is the live line")

        // A bin that has no measured time yet reads the floor, not a number.
        let early = SpectrumAnalyzer()
        x.withUnsafeBufferPointer { p in early.process(left: p.baseAddress!, right: p.baseAddress!, count: 800, sampleRate: rate) }
        let first = early.read().spectrum
        for (f, v) in zip(first.frequencies, first.average) where f < 40 {
            XCTAssertEqual(v, SpectrumReading.floorDB, accuracy: 0.01, "\(f) Hz before the long FFT has data")
        }
    }

    /// The shelf the round 3 render showed from 20 to 27 Hz is the kick drum of the demo signal:
    /// a decaying sine exp(-a t) sin(w t) has a flat spectrum below its resonance, 20 log10(2a / w)
    /// under the peak, which is -18.5 dB for a = 18 /s and w = 2 pi 48 Hz. Checked on the kick
    /// alone, against that closed form.
    func testKickAloneHasItsPlateauBelowResonance() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let block = 800
        for k in 0..<(60 * 4) {
            var x = [Float](repeating: 0, count: block)
            for i in 0..<block {
                let beat = (Double(k * block + i) / rate).truncatingRemainder(dividingBy: 0.5)
                x[i] = Float(exp(-beat * 18) * sin(2 * .pi * 48 * beat)) * 0.5
            }
            analyzer.process(left: x, right: x, count: block, sampleRate: rate)
            _ = analyzer.read()
        }
        let reading = analyzer.read().spectrum
        let average = reading.average
        func level(_ hz: Float) -> Float {
            let i = reading.frequencies.firstIndex { $0 >= hz }!
            return average[i]
        }
        let peak = zip(reading.frequencies, average).filter { $0.0 > 30 && $0.0 < 70 }.map(\.1).max()!
        let expected = 20 * log10(Float(2 * 18 / (2 * Double.pi * 48)))
        for hz in [20, 22, 24] as [Float] {
            XCTAssertEqual(level(hz) - peak, expected, accuracy: 4, "\(hz) Hz sits \(level(hz) - peak) dB under the kick's peak, closed form \(expected) dB")
        }
    }
}
