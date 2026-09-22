import XCTest
@testable import JoseonCore

/// Round 4: the flanks of tonal peaks. The round 3 seam tests masked out everything next to a
/// tonal peak, which is exactly where the round 3 defect lived, so these tests look *at* the
/// flanks. Nothing is excluded between 100 Hz and 5 kHz.
///
/// The bar, for every pair of adjacent display bins:
///
/// - outside the main lobe of a tone: `|delta| <= 3 dB`;
/// - inside the main lobe: the curve rises monotonically to the peak and falls monotonically
///   from it, and it follows `noise + Hann main lobe` of the analyzer's resolution bandwidth
///   at that frequency. A true Hann lobe is steeper than 3 dB per display bin (9.4 dB between
///   1.0 and 1.5 FFT bins off centre, and that is one display bin at 392 Hz), so a flat
///   3 dB limit on the flank itself would force the analyzer to draw a lobe wider than the
///   one it measured. The flank is held to the lobe it must have instead;
/// - no prominent local maximum that is not a partial of the signal (the round 3 "walls" were
///   false tones three FFT bins either side of every real one);
/// - away from the lobes the curve with tones equals the curve of the same noise without
///   tones, so there is no shelf between neighbouring tones.
final class SpectrumWallsTests: XCTestCase {

    // MARK: Helpers

    static func run(_ analyzer: SpectrumAnalyzer, seconds: Double, rate: Double = 48_000,
                    readAt: [Double] = [],
                    signal: (Int, Int) -> (left: [Float], right: [Float])) -> [SpectrumReading] {
        let block = Int(rate / 60)
        var out = [SpectrumReading]()
        var pending = readAt.sorted()
        var reading = analyzer.read().spectrum
        let total = Int(seconds * 60)
        for k in 0..<total {
            let s = signal(k * block, block)
            analyzer.process(left: s.left, right: s.right, count: block, sampleRate: rate)
            reading = analyzer.read().spectrum
            let t = Double((k + 1) * block) / rate
            while let next = pending.first, t >= next { out.append(reading); pending.removeFirst() }
        }
        out.append(reading)
        return out
    }

    static func dump(_ name: String, _ r: SpectrumReading, from: Float, to: Float, extra: [Float]? = nil) {
        var s = "\n== \(name) ==\n"
        for (i, f) in r.frequencies.enumerated() where f >= from && f <= to {
            s += String(format: "%4d %7.1f Hz  mid %7.2f  d %+6.2f", i, f, r.mid[i], i > 0 ? r.mid[i] - r.mid[i - 1] : 0)
            if let extra { s += String(format: "  ref %7.2f", extra[i]) }
            s += "\n"
        }
        print(s)
    }

    private static func smoothstepOctaves(_ f: Float, centre: Float, halfWidth: Float) -> Float {
        let t = (log2(f / centre) + halfWidth) / (2 * halfWidth)
        let c = min(max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }

    /// Bin width of the lobe a tone is drawn with at 48 kHz: the FFT's own (1.46, 5.86, 23.4 Hz),
    /// moving from one to the next across the half-octave crossfades at 200 Hz and 2 kHz.
    /// An independent copy on purpose: the test must not take the width from the code under test.
    static func toneBinHz(_ f: Float) -> Float {
        let dl = log2(Float(48_000.0 / 32_768)), dm = log2(Float(48_000.0 / 8_192)), dh = log2(Float(48_000.0 / 2_048))
        let sLow = smoothstepOctaves(f, centre: 200, halfWidth: 0.5)
        let sHigh = smoothstepOctaves(f, centre: 2_000, halfWidth: 0.5)
        return exp2((1 - sLow) * dl + sLow * (1 - sHigh) * dm + sHigh * dh)
    }

    static func lobeWidths(_ f: Float) -> (lo: Float, hi: Float) {
        let w = toneBinHz(f)
        return (w, w)
    }

    /// Hann main lobe in power, `u` in bins off centre. Zero outside the main lobe.
    static func hannLobePower(_ u: Float) -> Float {
        let a = abs(u)
        guard a < 2 else { return 0 }
        if a < 1e-4 { return 1 }
        if abs(a - 1) < 1e-4 { return 0.25 }
        let h = sin(Float.pi * a) / (Float.pi * a) / (1 - a * a)
        return h * h
    }

    struct Tone { var hz: Float; var levelDB: Float }

    /// `noise + sum of lobes`, in dB, with the lobe taken at the point of the display bin's span
    /// nearest to the tone (the display keeps the highest point inside a bin).
    static func expected(_ frequencies: [Float], noiseDB: [Float], tones: [Tone], wide: Bool) -> [Float] {
        let halfStep = sqrt(frequencies[1] / frequencies[0])
        return frequencies.enumerated().map { i, f in
            var p = pow(10, noiseDB[i] / 10)
            for t in tones {
                let w = lobeWidths(t.hz)
                let width = wide ? w.hi : w.lo
                let lo = f / halfStep, hi = f * halfStep
                let d: Float = t.hz < lo ? lo - t.hz : (t.hz > hi ? t.hz - hi : 0)
                p += pow(10, t.levelDB / 10) * hannLobePower(d / width)
            }
            return 10 * log10(max(p, 1e-30))
        }
    }

    static func inLobe(_ f: Float, _ tones: [Float], binRatio: Float) -> Float? {
        for t in tones {
            let reach = 2 * lobeWidths(t).hi
            if f >= (t - reach) / binRatio && f <= (t + reach) * binRatio { return t }
        }
        return nil
    }

    /// The flank rules. Returns human-readable failures.
    static func flankFailures(_ r: SpectrumReading, curve: [Float], tones: [Float], from: Float = 100, to: Float = 5_000) -> [String] {
        var failures = [String]()
        let f = r.frequencies
        let ratio = f[1] / f[0]
        for i in 1..<curve.count where f[i - 1] >= from && f[i] <= to {
            let d = curve[i] - curve[i - 1]
            let a = inLobe(f[i - 1], tones, binRatio: ratio), b = inLobe(f[i], tones, binRatio: ratio)
            if let t = a ?? b, a == nil || b == nil || a == b {
                // On one main lobe, its foot included: monotone towards the peak on the left,
                // away from it on the right.
                let mid = (f[i - 1] * f[i]).squareRoot()
                let slack: Float = 0.5
                // The top of the lobe is one or two display bins wide: no direction there.
                if abs(log2(mid / t)) < log2(ratio) { continue }
                if mid < t, d < -slack { failures.append(String(format: "left flank of %.1f Hz falls %.2f dB at %.1f Hz", t, d, f[i])) }
                if mid > t, d > slack { failures.append(String(format: "right flank of %.1f Hz rises %.2f dB at %.1f Hz", t, d, f[i])) }
            } else if abs(d) > 3 {
                failures.append(String(format: "%.2f dB step outside any lobe at %.1f Hz", d, f[i]))
            }
        }
        return failures
    }

    /// Local maxima that stand `prominence` dB over both sides within `reach` bins.
    static func prominentMaxima(_ r: SpectrumReading, curve: [Float], from: Float, to: Float, prominence: Float = 5, reach: Int = 8) -> [Float] {
        var out = [Float]()
        let f = r.frequencies
        for i in reach..<(curve.count - reach) where f[i] >= from && f[i] <= to {
            guard curve[i] >= curve[i - 1], curve[i] > curve[i + 1] else { continue }
            let left = curve[(i - reach)..<i].min()!, right = curve[(i + 1)...(i + reach)].min()!
            if curve[i] - max(left, right) >= prominence { out.append(f[i]) }
        }
        return out
    }

    private func noisePlusTones(_ tones: [Tone], seconds: Double) -> (with: SpectrumReading, without: SpectrumReading) {
        let rate = 48_000.0
        let count = Int(rate * seconds)
        let nl = TestSignals.pinkNoise(amplitude: 0.04, count: count, seed: 0x5EED)
        let nr = TestSignals.pinkNoise(amplitude: 0.04, count: count, seed: 0xC0FFEE)
        var tl = nl, tr = nr
        for t in tones {
            let s = TestSignals.sine(hz: Double(t.hz), amplitude: pow(10, t.levelDB / 20), sampleRate: rate, seconds: seconds)
            for i in 0..<count { tl[i] += s[i]; tr[i] += s[i] }
        }
        let with = Self.run(SpectrumAnalyzer(), seconds: seconds) { (Array(tl[$0..<($0 + $1)]), Array(tr[$0..<($0 + $1)])) }.last!
        let without = Self.run(SpectrumAnalyzer(), seconds: seconds) { (Array(nl[$0..<($0 + $1)]), Array(nr[$0..<($0 + $1)])) }.last!
        return (with, without)
    }

    private func checkAgainstModel(_ name: String, tones: [Tone], file: StaticString = #filePath, line: UInt = #line) {
        let (with, without) = noisePlusTones(tones, seconds: 4)
        let lo = Self.expected(with.frequencies, noiseDB: without.mid, tones: tones, wide: false)
        let hi = Self.expected(with.frequencies, noiseDB: without.mid, tones: tones, wide: true)
        Self.dump(name, with, from: 300, to: 450, extra: hi)

        var worst: Float = 0, worstHz: Float = 0
        for (i, f) in with.frequencies.enumerated() where f >= 100 && f <= 5_000 {
            let over = with.mid[i] - hi[i], under = lo[i] - with.mid[i]
            let e = max(over, under)
            if e > worst { worst = e; worstHz = f }
        }
        XCTAssertLessThanOrEqual(worst, 3, "\(name): mid is \(worst) dB away from noise + Hann lobe at \(worstHz) Hz", file: file, line: line)

        let failures = Self.flankFailures(with, curve: with.mid, tones: tones.map(\.hz))
        XCTAssertTrue(failures.isEmpty, "\(name): \(failures.prefix(8).joined(separator: "; "))", file: file, line: line)

        let maxima = Self.prominentMaxima(with, curve: with.mid, from: 100, to: 5_000)
        for m in maxima {
            XCTAssertTrue(tones.contains { abs($0.hz / m - 1) < 0.015 }, "\(name): false peak at \(m) Hz", file: file, line: line)
        }
        for t in tones {
            XCTAssertTrue(maxima.contains { abs(t.hz / $0 - 1) < 0.015 }, "\(name): no peak at \(t.hz) Hz", file: file, line: line)
        }
    }

    // MARK: Tests

    /// (a) Pink noise with three tones 25 dB over it, a fifth and an octave apart like the
    /// demo chord's upper partials.
    func testThreeTonesOverPinkNoise() {
        checkAgainstModel("three tones", tones: [Tone(hz: 196, levelDB: -36), Tone(hz: 294, levelDB: -36), Tone(hz: 392, levelDB: -36)])
    }

    /// (c) One tone, so nothing but its own lobe can shape the flank.
    func testOneToneOverPinkNoise() {
        checkAgainstModel("one tone", tones: [Tone(hz: 392, levelDB: -36)])
    }

    /// A loud tone has sidelobes well over the noise. They must not be taken for tones.
    func testLoudToneHasNoFalseNeighbours() {
        checkAgainstModelLoud()
    }

    private func checkAgainstModelLoud() {
        let tones = [Tone(hz: 392, levelDB: -6)]
        let (with, _) = noisePlusTones(tones, seconds: 3)
        let maxima = Self.prominentMaxima(with, curve: with.mid, from: 100, to: 5_000)
        XCTAssertEqual(maxima.count, 1, "maxima at \(maxima)")
        let failures = Self.flankFailures(with, curve: with.mid, tones: [392]).filter { !$0.contains("outside") }
        XCTAssertTrue(failures.isEmpty, failures.prefix(8).joined(separator: "; "))
    }

    /// (b) The demo signal, read where the round 4 render is taken (8 s, chord root 98 Hz)
    /// and in the middle of the chord before it (root 146.83 Hz).
    func testDemoSignalFlanks() {
        let readings = Self.run(SpectrumAnalyzer(), seconds: 8, readAt: [5.5]) { TestSignals.demoBlock(startSample: $0, count: $1) }
        let multiples: [Float] = [1, 1.5, 2, 2.52, 3, 4]
        for (reading, root, name) in [(readings[0], Float(146.83), "demo 5.5 s"), (readings[1], Float(98), "demo 8 s")] {
            let partials = multiples.map { $0 * root } + [3_100]
            if root == 98 { Self.dump(name, reading, from: 280, to: 460) }
            for (curveName, curve) in [("mid", reading.mid), ("left", reading.left), ("right", reading.right)] {
                let failures = Self.flankFailures(reading, curve: curve, tones: partials)
                XCTAssertTrue(failures.isEmpty, "\(name) \(curveName): \(failures.prefix(8).joined(separator: "; "))")
                let maxima = Self.prominentMaxima(reading, curve: curve, from: 100, to: 5_000)
                for m in maxima {
                    XCTAssertTrue(partials.contains { abs($0 / m - 1) < 0.015 }, "\(name) \(curveName): false peak at \(m) Hz")
                }
            }
            // No shelf: the floor between the last two partials is the floor after the last one.
            func median(_ lo: Float, _ hi: Float) -> Float {
                let v = zip(reading.frequencies, reading.mid).filter { $0.0 >= lo && $0.0 <= hi }.map(\.1).sorted()
                return v[v.count / 2]
            }
            let top = 4 * root, below = 3 * root
            let between = median(below * 1.06, top / 1.06), after = median(top * 1.06, top * 1.25)
            XCTAssertEqual(between, after, accuracy: 3, "\(name): floor between the partials \(between) dB, after them \(after) dB")
        }
    }
}

extension SpectrumWallsTests {
    /// The chord of `TestSignals.demoBlock`, so it can be taken out again.
    static func demoChord(startSample: Int, count: Int, rate: Double = 48_000) -> (left: [Float], right: [Float]) {
        var l = [Float](repeating: 0, count: count), r = l
        for i in 0..<count {
            let time = Double(startSample + i) / rate
            let root = [110.0, 130.81, 146.83, 98.0][Int(time / 2) % 4]
            var chord: Float = 0
            for (k, m) in [1.0, 1.5, 2.0, 2.52, 3.0, 4.0].enumerated() { chord += Float(sin(2 * .pi * root * m * time)) * 0.07 / Float(k + 1) }
            let pan = Float(sin(time * 0.7))
            l[i] = chord * (1 - 0.4 * pan)
            r[i] = chord * (1 + 0.4 * pan)
        }
        return (l, r)
    }

    /// The demo signal with and without its chord: away from the partials' lobes the two curves
    /// are the same curve. A floor that is lifted between close partials, or that collapses
    /// after the last one, shows up here as a difference.
    func testDemoFloorIsTheSameWithAndWithoutTheChord() {
        let with = Self.run(SpectrumAnalyzer(), seconds: 8) { TestSignals.demoBlock(startSample: $0, count: $1) }.last!
        let without = Self.run(SpectrumAnalyzer(), seconds: 8) { start, count in
            let d = TestSignals.demoBlock(startSample: start, count: count)
            let c = Self.demoChord(startSample: start, count: count)
            return (zip(d.left, c.left).map { $0 - $1 }, zip(d.right, c.right).map { $0 - $1 })
        }.last!
        Self.dump("demo 8 s, ref = no chord", with, from: 100, to: 290, extra: without.mid)
        let partials = [1, 1.5, 2, 2.52, 3, 4].map { Float($0) * 98 }
        let ratio = with.frequencies[1] / with.frequencies[0]
        var worst: Float = 0, worstHz: Float = 0
        for (i, f) in with.frequencies.enumerated() where f >= 100 && f <= 5_000 {
            if Self.inLobe(f, partials, binRatio: ratio * ratio) != nil { continue }
            let e = abs(with.mid[i] - without.mid[i])
            if e > worst { worst = e; worstHz = f }
        }
        XCTAssertLessThanOrEqual(worst, 3, "floor differs by \(worst) dB at \(worstHz) Hz")
    }
}

extension SpectrumWallsTests {
    /// The two causes of the round 3 picture, checked where they live: in one 8192-point
    /// transform of the demo signal, every partial of the chord is found as a tone (round 3 missed
    /// 147 Hz and 247 Hz in every frame and 196 Hz in half of them, because the next partial sat
    /// inside the noise context), and nothing else near a partial is (round 3 found a false tone
    /// three bins either side of 294 Hz and 392 Hz).
    func testEveryChordPartialIsATone() {
        let n = 1024
        let ratio: Float = 2400
        let step = pow(ratio, 1 / Float(n - 1))
        let freqs = (0..<n).map { 10 * pow(ratio, Float($0) / Float(n - 1)) }
        let w = [Float](repeating: 1, count: n)
        let size = 8192
        let df = Float(48_000.0 / Double(size))
        let res = SpectrumResolution(size: size, hop: 1024, sampleRate: 48_000)!
        res.updateMap(displayBins: n, frequencies: freqs, binRatio: step, weight: w,
                      targetBandwidthHz: { _ in 3 * df }, toneBinHz: { _ in df })
        var t = 7.0
        while t <= 8.0 {
            defer { t += 0.04 }
            // A window that holds a kick onset (every 0.5 s) really is broadband at 150-250 Hz:
            // the partials are 6 dB over it there, not 14, and are rightly not called tones.
            let sinceKick = t.truncatingRemainder(dividingBy: 0.5)
            if sinceKick < Double(size) / 48_000 { continue }
            let end = Int(t * 48_000)
            let s = TestSignals.demoBlock(startSample: end - size, count: size)
            res.transform(historyL: s.left, historyR: s.right, capacity: size, mask: size - 1, end: 0)
            let bins = res.detectedTones.map(\.bin)
            for m in [1.5, 2, 2.52, 3, 4] as [Float] {
                let x = 98 * m / df
                XCTAssertTrue(bins.contains { abs(Float($0) - x) <= 1 }, "t = \(t): no tone at \(98 * m) Hz, found bins \(bins.filter { $0 < 80 })")
                XCTAssertFalse(bins.contains { abs(Float($0) - x) > 1.5 && abs(Float($0) - x) < 6 }, "t = \(t): false tone beside \(98 * m) Hz, found bins \(bins.filter { $0 < 80 })")
            }
        }
    }
}
