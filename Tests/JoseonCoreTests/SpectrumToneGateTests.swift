import XCTest
@testable import JoseonCore

/// The memory of the tonal gate in `SpectrumResolution.detectTones()`: a quiet steady tone is a
/// tone in every transform, a tone that stops is released within a few transforms, and plain
/// noise holds no tone. Round 8: the gate decided from one transform, and a 3.1 kHz tone 9 dB over
/// pink noise passed in 2% of them, so the spectrogram drew it as dashes.
final class SpectrumToneGateTests: XCTestCase {

    /// One resolution, mapped like the analyzer maps it, fed a signal in 800-frame blocks. Calls
    /// `each` after every transform with its index.
    private static func drive(size: Int, hop: Int, servedHz: ClosedRange<Float>, seconds: Double, signal: (Int) -> (Float, Float), each: (Int, SpectrumResolution) -> Void) {
        let sr = 48_000.0, block = 800
        let res = SpectrumResolution(size: size, hop: hop, sampleRate: sr)!
        let n = 1024
        let ratio: Float = 2400
        let step = pow(ratio, 1 / Float(n - 1))
        let freqs = (0..<n).map { 10 * pow(ratio, Float($0) / Float(n - 1)) }
        let df = Float(sr / Double(size))
        let weight = freqs.map { servedHz.contains($0) ? Float(1) : 0 }
        res.updateMap(displayBins: n, frequencies: freqs, binRatio: step, weight: weight, targetBandwidthHz: { _ in 3 * df }, toneBinHz: { _ in df })
        let cap = 1 << 17
        var hl = [Float](repeating: 0, count: cap), hr = hl
        var written = 0, transforms = 0
        for k in 0..<Int(seconds * sr) / block {
            for i in 0..<block {
                let s = k * block + i
                let (l, r) = signal(s)
                hl[s & (cap - 1)] = l; hr[s & (cap - 1)] = r
            }
            written += block
            if let end = res.dueHop(samplesWritten: written, historyCapacity: cap) {
                hl.withUnsafeBufferPointer { l in hr.withUnsafeBufferPointer { r in
                    res.transform(historyL: l.baseAddress!, historyR: r.baseAddress!, capacity: cap, mask: cap - 1, end: end)
                } }
                each(transforms, res)
                transforms += 1
            }
        }
    }

    private static func tonal(_ res: SpectrumResolution, hz: Float) -> Bool {
        let k = Int((hz / res.df).rounded())
        return res.detectedTones.contains { abs($0.bin - k) <= 1 }
    }

    /// The spectrogram fixture: 3.1 kHz at -56 dBFS over pink noise at 0.04, in the 2048-point FFT
    /// that owns 3.1 kHz. Before the fix: tonal in 2% of transforms. Then the tone stops and the
    /// noise goes on: the tone is released within twelve transforms and does not come back.
    func testAQuietSteadyToneIsAToneInEveryTransformAndIsReleasedWhenItStops() {
        let sr = 48_000.0
        let noiseL = TestSignals.pinkNoise(amplitude: 0.04, count: 1 << 17, seed: 7), noiseR = TestSignals.pinkNoise(amplitude: 0.04, count: 1 << 17, seed: 99)
        let amp = Float(pow(10, -56.0 / 20))
        let stopAt = Int(8 * sr)
        var on = 0, checked = 0, lastOn = -1, backOn = 0, stopTransform = -1
        Self.drive(size: 2048, hop: 768, servedHz: 2_828...24_000, seconds: 11, signal: { s in
            let tone = s < stopAt ? amp * Float(sin(2 * .pi * 3_100 * Double(s) / sr)) : 0
            return (tone + noiseL[s % noiseL.count], tone + noiseR[s % noiseR.count])
        }, each: { t, res in
            let tonal = Self.tonal(res, hz: 3_100)
            if res.hopEnd <= stopAt {
                // The first second is the memory filling; after it the tone is steady.
                if res.hopEnd >= Int(sr) { checked += 1; if tonal { on += 1 } }
            } else {
                if stopTransform < 0 { stopTransform = t }
                if tonal { lastOn = t; if t - stopTransform > 12 { backOn += 1 } }
            }
        })
        print("tone gate: tonal in \(on) of \(checked) transforms; last tonal \(lastOn - stopTransform) transforms after the tone stopped")
        XCTAssertGreaterThan(checked, 400)
        XCTAssertGreaterThanOrEqual(Double(on), Double(checked) * 0.98, "a steady tone is a tone in every transform (was 2%)")
        XCTAssertLessThanOrEqual(lastOn - stopTransform, 12, "a tone that stopped is released within twelve transforms")
        XCTAssertEqual(backOn, 0, "and does not come back on the noise")
    }

    /// Plain pink noise at every resolution: no bin is tonal in three transforms running. The one-
    /// transform gate lets a rare candidate through (under 0.2 per 10 000 candidates), and the memory
    /// may hold it for one more transform while the average is lifted; it must not go on from there.
    func testPinkNoiseHoldsNoTone() {
        let noiseL = TestSignals.pinkNoise(amplitude: 0.04, count: 1 << 17, seed: 7), noiseR = TestSignals.pinkNoise(amplitude: 0.04, count: 1 << 17, seed: 99)
        for (size, hop, served) in [(2_048, 768, Float(2_828)...24_000), (8_192, 1_024, 141...2_828), (32_768, 32_768 / 6, 10...283)] {
            var runs = [Int: Int]()       // bin -> transforms tonal in a row
            var longest = 0, tonalTransforms = 0, transforms = 0
            Self.drive(size: size, hop: hop, servedHz: served, seconds: 8, signal: { s in
                (noiseL[s % noiseL.count], noiseR[s % noiseR.count])
            }, each: { _, res in
                transforms += 1
                let bins = Set(res.detectedTones.map(\.bin))
                tonalTransforms += bins.count
                var next = [Int: Int]()
                for b in bins {
                    let run = ((runs[b - 1] ?? 0) as Int, runs[b] ?? 0, runs[b + 1] ?? 0)
                    next[b] = max(run.0, run.1, run.2) + 1
                    longest = max(longest, next[b]!)
                }
                runs = next
            })
            print("tone gate on pink noise, \(size)-point: \(tonalTransforms) tone-transforms in \(transforms) transforms, longest run \(longest)")
            XCTAssertLessThanOrEqual(longest, 2, "\(size)-point: a false tone held for \(longest) transforms")
            XCTAssertLessThan(Double(tonalTransforms), Double(transforms) * 0.05, "\(size)-point: false tones in \(tonalTransforms) of \(transforms) transforms")
        }
    }
}
