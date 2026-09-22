import XCTest
import JoseonCore
@testable import JoseonRender

/// Critic r2 defect 3: the bands of the spectrogram were out of time (bass about 0.4 s after the highs).
/// A train of broadband noise bursts plus a steady tone goes through the real analyzers, then through the spectrogram's
/// history. Every band must show a burst in the same column.
final class SpectrogramAlignmentTests: XCTestCase {
    static let burstPeriod = 1.0

    /// 10 ms bursts of white noise once per second, in both channels, and a quiet 15 kHz tone.
    static func burstFrames(seconds: Double) -> [AnalysisFrame] {
        let engine = AnalysisEngine()
        let rate = 48_000.0
        engine.streamInfo = StreamInfo(sampleRate: rate, channelCount: 2, deviceName: "Burst test", bitDepth: 32, activeSources: [])
        let block = Int(rate / 60)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func noise() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: state >> 33)) / Float(Int32.max) * 2
        }
        var frames: [AnalysisFrame] = []
        var l = [Float](repeating: 0, count: block)
        for k in 0..<Int(seconds * 60) {
            for i in 0..<block {
                let n = k * block + i
                let t = Double(n) / rate
                let inBurst = t.truncatingRemainder(dividingBy: burstPeriod) < 0.010 && t > 0.5
                l[i] = (inBurst ? noise() * 0.45 : 0) + Float(sin(2 * .pi * 15_000 * t)) * 0.01
            }
            var f = engine.processNow(left: l, right: l, count: block, sampleRate: rate)
            f.hostTime = Double(k + 1) / 60       // the frame exists when its block has ended
            frames.append(f)
        }
        return frames
    }

    func testABurstLandsInTheSameColumnFromFortyHertzToTenKilohertz() throws {
        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let r = try XCTUnwrap(PanelRenderer.make(kind: .spectrogram, ctx: ctx, theme: Theme()) as? SpectrogramRenderer)
        r.setLayout(size: CGSize(width: 1200, height: 600), scale: 2)
        let seconds = 12.0
        for f in Self.burstFrames(seconds: seconds) { r.ingest(f) }
        let columnSeconds = r.historySeconds / Double(SpectrogramRenderer.columns)

        // Newest column = the panel's clock minus the latency. The clock starts one frame before the first host time.
        let probes: [Float] = [40, 63, 100, 160, 230, 320, 500, 1000, 1600, 2300, 4000, 6300, 10_000]
        var rowsOut: [String] = []
        var means: [Double] = []
        for hz in probes {
            var positions: [Double] = []
            for burst in 3..<10 {
                // Burst center time 0.005 s after the second. Search +-0.3 s around the expected column.
                let newestTime = r.newestColumnTime
                let expectedBack = (newestTime - (Double(burst) + 0.005)) / columnSeconds
                var best = -Float.infinity, bestBack = 0
                var series: [Int: Float] = [:]
                for back in Int(expectedBack - 20)...Int(expectedBack + 20) {
                    // Mean over a third of an octave around the probe: one noise burst is ragged from bin to bin.
                    var sum: Float = 0, n: Float = 0
                    for k in -4...4 {
                        if let v = r.historyLevel(columnsBack: back, hz: hz * pow(2, Float(k) / 24)) { sum += v; n += 1 }
                    }
                    guard n > 0 else { continue }
                    series[back] = sum / n
                    if sum / n > best { best = sum / n; bestBack = back }
                }
                // The moment the hill reaches its top. (Not the middle of the hill: the analyzer's 0.25 s release holds the
                // falling side up, more so for the long window.) The oldest column within 0.1 dB of the maximum.
                for (back, v) in series where v > best - 0.1 { bestBack = max(bestBack, back) }
                positions.append(Double(bestBack) - expectedBack)
            }
            let mean = positions.reduce(0, +) / Double(positions.count)
            means.append(mean)
            rowsOut.append(String(format: "%6.0f Hz: %+.2f columns (bursts %@)", hz, -mean, positions.map { String(format: "%+.1f", -$0) }.joined(separator: " ")))
        }
        print("ALIGN columns late against the true burst time (1 column = \(Int(columnSeconds * 1000)) ms):\n" + rowsOut.joined(separator: "\n"))
        // Outside the analyzer's crossfades (141-283 Hz, 1.4-2.8 kHz) a row comes from one FFT: +-1 column.
        // Inside, the analyzer blends two FFTs with different windows in dB, so one burst makes a short spike and a long hill.
        // One delay cannot center both: the blended delay keeps each within 0.2 s and leaves no step at the borders.
        for (hz, m) in zip(probes, means) {
            let w = SpectrumTiming.weights(atHz: hz)
            let blended = max(w.low, w.mid, w.high) < 0.999
            XCTAssertEqual(m, 0, accuracy: blended ? 12 : 1.0, "\(hz) Hz: a burst sits at its true time")
        }
        let pure = zip(probes, means).filter { max(SpectrumTiming.weights(atHz: $0.0).low, SpectrumTiming.weights(atHz: $0.0).mid, SpectrumTiming.weights(atHz: $0.0).high) >= 0.999 }.map { $0.1 }
        XCTAssertLessThanOrEqual(pure.max()! - pure.min()!, 2.0, "all single-FFT bands within +-1 column of each other")
    }

    /// The delay law is continuous: no step between neighbour rows anywhere (the old picture had a seam near 230 Hz).
    func testRowDelaysHaveNoSeam() {
        let a = SpectrogramTimeAligner(rows: 1024)
        a.configure(minHz: 20, maxHz: 20_000, sampleRate: 48_000)
        var biggest = 0.0
        for r in 1..<1024 { biggest = max(biggest, abs(a.delay(row: r, minBox: 1.0 / 60) - a.delay(row: r - 1, minBox: 1.0 / 60))) }
        XCTAssertLessThan(biggest, 0.006, "largest delay step between two rows, seconds (a third of a column)")
        XCTAssertEqual(a.delay(row: 0, minBox: 1.0 / 60), 0, accuracy: 1e-9, "the lows are the slowest: no delay")
        XCTAssertEqual(a.delay(row: 1023, minBox: 1.0 / 60), (0.6827 + 0.0853) / 2 + 0.0853 / 2 - (0.0427 + 0.0107) / 2 - 1.0 / 120, accuracy: 0.002)
    }
}
