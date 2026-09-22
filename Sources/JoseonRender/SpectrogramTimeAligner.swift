import Accelerate
import Foundation

/// Timing of the multi-resolution spectrum, mirrored from `JoseonCore/Spectrum/SpectrumAnalyzer.swift`
/// (the constants there are private): three FFT windows of 32768 / 8192 / 2048 samples at 48 kHz, scaled to other
/// rates by the nearest power of two, hops of size / 8, size / 8 and size / 4, blended with a smoothstep in log
/// frequency over half an octave either side of 200 Hz and 2 kHz. Keep in step with the analyzer.
struct SpectrumTiming {
    static let lowSizeAt48k = 32_768.0, midSizeAt48k = 8_192.0, highSizeAt48k = 2_048.0
    static let lowMidHz: Float = 200, midHighHz: Float = 2_000, crossfadeOctaves: Float = 0.5

    /// Window length in seconds: low, mid, high.
    var window: (Double, Double, Double)
    /// Seconds between transforms: low, mid, high.
    var hop: (Double, Double, Double)

    init(sampleRate: Double) {
        let rate = sampleRate > 1000 ? sampleRate : 48_000
        func size(_ at48k: Double, _ lo: Double, _ hi: Double) -> Double {
            min(max(pow(2, (log2(at48k * rate / 48_000)).rounded()), lo), hi)
        }
        let l = size(Self.lowSizeAt48k, 4_096, 131_072), m = size(Self.midSizeAt48k, 1_024, 32_768), h = size(Self.highSizeAt48k, 256, 8_192)
        window = (l / rate, m / rate, h / rate)
        hop = (l / 8 / rate, m / 8 / rate, h / 4 / rate)
    }

    /// Blend weights of the three resolutions at a frequency: the analyzer's crossfade.
    static func weights(atHz f: Float) -> (low: Float, mid: Float, high: Float) {
        func step(_ centre: Float) -> Float {
            let t = (log2(max(f, 1e-3) / centre) + crossfadeOctaves) / (2 * crossfadeOctaves)
            let c = min(max(t, 0), 1)
            return c * c * (3 - 2 * c)
        }
        let wl = 1 - step(lowMidHz), wh = step(midHighHz)
        return (wl, max(1 - wl - wh, 0), wh)
    }

    /// Seconds from the middle of the analysis window to the moment a frame shows it, without display interpolation:
    /// half the window plus half a hop (a frame holds the newest transform, which is half a hop old on average).
    func centerLag(atHz f: Float) -> Double {
        let w = Self.weights(atHz: f)
        return Double(w.low) * (window.0 + hop.0) / 2 + Double(w.mid) * (window.1 + hop.1) / 2 + Double(w.high) * (window.2 + hop.2) / 2
    }

    func hop(atHz f: Float) -> Double {
        let w = Self.weights(atHz: f)
        return Double(w.low) * hop.0 + Double(w.mid) * hop.1 + Double(w.high) * hop.2
    }
}

/// Puts the bands of the spectrogram on one time axis.
///
/// The live spectrum is instant: every band shows its newest transform. The window of the lows is 0.68 s long, the window
/// of the highs 0.04 s, so the same click reaches the highs about 0.3 s before it reaches the lows. The spectrogram
/// delays the short-window rows so that every row of a column has the same window CENTER time. The delay follows the
/// analyzer's crossfade, so there is no seam at the band borders.
///
/// The second job is interpolation in time: a band that updates every 85 ms is a staircase in the 60 Hz frame stream.
/// Each row is averaged (in dB) over one hop of its band, which is exactly a linear interpolation between transforms.
///
/// Storage: a short ring of running time integrals per row (Double). A box average over any interval is then two
/// lookups per row, whatever the frame rate.
final class SpectrogramTimeAligner {
    let rows: Int
    private let capacity: Int
    private let prefix: UnsafeMutablePointer<Double>     // capacity * rows: integral of the row value up to the frame's time
    private let last: UnsafeMutablePointer<Float>        // newest values
    private var times: [Double]
    private var first = 0, count = 0
    private var rowLag: [Double] = []
    private var rowHop: [Double] = []
    private var key: (Float, Float, Double) = (0, 0, 0)
    /// Half the time between frames: a frame's picture stands until the next frame, so it is this old on average.
    var frameHold: Double = 1.0 / 120.0
    private var rowBox: [Double] = [], rowEnd: [Double] = []
    private var runs: [(start: Int, count: Int)] = []
    private let scratchA: UnsafeMutablePointer<Double>, scratchB: UnsafeMutablePointer<Double>
    private var boxFor = -1.0

    init(rows: Int, capacity: Int = 96) {
        self.rows = rows
        self.capacity = capacity
        prefix = .allocate(capacity: capacity * rows); prefix.initialize(repeating: 0, count: capacity * rows)
        last = .allocate(capacity: rows); last.initialize(repeating: 0, count: rows)
        scratchA = .allocate(capacity: rows); scratchA.initialize(repeating: 0, count: rows)
        scratchB = .allocate(capacity: rows); scratchB.initialize(repeating: 0, count: rows)
        times = [Double](repeating: 0, count: capacity)
    }

    deinit { prefix.deallocate(); last.deallocate(); scratchA.deallocate(); scratchB.deallocate() }

    /// Rows are uniform on a log axis from `minHz` to `maxHz`.
    func configure(minHz: Float, maxHz: Float, sampleRate: Double) {
        guard key != (minHz, maxHz, sampleRate) || rowLag.isEmpty else { return }
        key = (minHz, maxHz, sampleRate)
        let timing = SpectrumTiming(sampleRate: sampleRate)
        rowLag = (0..<rows).map { timing.centerLag(atHz: minHz * pow(maxHz / minHz, Float($0) / Float(max(rows - 1, 1)))) }
        rowHop = (0..<rows).map { timing.hop(atHz: minHz * pow(maxHz / minHz, Float($0) / Float(max(rows - 1, 1)))) }
        boxFor = -1
    }

    /// One lag and one hop for every row: a single FFT resolution (`SpectrumLayer`). `lag` = seconds from the middle of the
    /// analysis window to the moment a frame shows it, `hop` = seconds between two transforms.
    func configureUniform(lag: Double, hop: Double) {
        guard rowLag.count != rows || rowLag[0] != lag || rowHop[0] != hop || key != (-1, -1, -1) else { return }
        key = (-1, -1, -1)
        rowLag = [Double](repeating: lag, count: rows)
        rowHop = [Double](repeating: hop, count: rows)
        boxFor = -1
    }

    func reset() { first = 0; count = 0; firstTime = nil }

    /// Time of the first frame since the last reset. Nil when there was none.
    private(set) var firstTime: Double?

    /// The earliest column time that `compose` can build from real frames only (no clamping to the oldest frame in any row).
    func earliestCenter(minBox: Double) -> Double? {
        guard let oldest = firstTime, !rowLag.isEmpty else { return nil }
        var least = Double.infinity
        for r in stride(from: 0, to: min(rows, rowLag.count, rowHop.count), by: 16) { least = min(least, rowLag[r] - max(rowHop[r], minBox) / 2) }
        if let l = rowLag.last, let h = rowHop.last { least = min(least, l - max(h, minBox) / 2) }
        return oldest - least - frameHold
    }

    /// Seconds between the newest frame and the newest column that can be composed.
    func latency(minBox: Double) -> Double {
        var m = 0.0
        for r in stride(from: 0, to: min(rows, rowLag.count, rowHop.count), by: 16) { m = max(m, rowLag[r] + max(rowHop[r], minBox) / 2) }
        if let l = rowLag.last, let h = rowHop.last { m = max(m, l + max(h, minBox) / 2) }
        return m + frameHold
    }

    /// Delay of a row against the slowest row, in seconds (for tests and the cursor readout).
    func delay(row: Int, minBox: Double) -> Double {
        guard row >= 0, row < rowLag.count, row < rowHop.count else { return 0 }
        return latency(minBox: minBox) - frameHold - (rowLag[row] + max(rowHop[row], minBox) / 2)
    }

    /// Adds a frame: `values` are the row levels (0...1 of the dB range) at `time`. Times must rise.
    func push(_ values: UnsafePointer<Float>, time: Double) {
        if count > 0 {
            let newest = times[(first + count - 1) % capacity]
            if time <= newest || time - newest > 0.5 { reset() }
        }
        if count == 0 { firstTime = time }
        let slot: Int
        if count == capacity { slot = first; first = (first + 1) % capacity } else { slot = (first + count) % capacity; count += 1 }
        let dst = prefix + slot * rows
        if count == 1 {
            dst.update(repeating: 0, count: rows)
        } else {
            let prevSlot = (slot + capacity - 1) % capacity
            let src = prefix + prevSlot * rows
            let dt = time - times[prevSlot]
            // dst = src + last * dt
            vDSP_vspdp(last, 1, dst, 1, vDSP_Length(rows))
            var step = dt
            vDSP_vsmulD(dst, 1, &step, dst, 1, vDSP_Length(rows))
            vDSP_vaddD(dst, 1, src, 1, dst, 1, vDSP_Length(rows))
        }
        times[slot] = time
        last.update(from: values, count: rows)
    }

    /// Time of the newest frame.
    var newestTime: Double { count > 0 ? times[(first + count - 1) % capacity] : 0 }

    /// Writes the column whose window centers lie at `centerTime`. `minBox`: shortest averaging time (a column or a frame).
    /// Call only with `centerTime <= newestTime - latency(minBox:)`; later times clamp to the newest frame.
    func compose(centerTime: Double, minBox: Double, into out: UnsafeMutablePointer<Float>) {
        guard count >= 2, !rowLag.isEmpty else { for r in 0..<rows { out[r] = 0 }; return }
        if boxFor != minBox {
            boxFor = minBox
            // Half-millisecond steps (a column is 17 ms or more): neighbour rows share their times, so the cursors hit.
            rowBox = rowHop.map { (max($0, minBox) * 2000).rounded() / 2000 }
            rowEnd = zip(rowLag, rowBox).map { (($0 + $1 / 2) * 2000).rounded() / 2000 }
            runs.removeAll()
            var start = 0
            for r in 1...rows where r == rows || rowBox[r] != rowBox[start] || rowEnd[r] != rowEnd[start] {
                runs.append((start, r - start))
                start = r
            }
        }
        let rows = self.rows, prefix = self.prefix, hold = frameHold
        // Rows with the same two times form a run (the delay is constant outside the crossfades): one frame lookup per
        // run, and long runs go through vDSP.
        var from = Cursor(), to = Cursor()
        times.withUnsafeBufferPointer { times in
            for run in runs {
                let r0 = run.start, n = run.count
                let box = rowBox[r0]
                let end = centerTime + rowEnd[r0] + hold
                locate(&from, end - box, times)
                locate(&to, end, times)
                if n >= 16 {
                    let vn = vDSP_Length(n)
                    var wa = from.flat ? 0 : from.w, wb = to.flat ? 0 : to.w
                    // a = p0 + (p1 - p0) * w, b alike, out = (b - a) / box
                    vDSP_vintbD(prefix + from.s0 + r0, 1, prefix + (from.flat ? from.s0 : from.s1) + r0, 1, &wa, scratchA, 1, vn)
                    vDSP_vintbD(prefix + to.s0 + r0, 1, prefix + (to.flat ? to.s0 : to.s1) + r0, 1, &wb, scratchB, 1, vn)
                    vDSP_vsubD(scratchA, 1, scratchB, 1, scratchB, 1, vn)
                    var inv = 1 / box
                    vDSP_vsmulD(scratchB, 1, &inv, scratchB, 1, vn)
                    vDSP_vdpsp(scratchB, 1, out + r0, 1, vn)
                } else {
                    for r in r0..<(r0 + n) {
                        let p0 = prefix[from.s0 + r], q0 = prefix[to.s0 + r]
                        let a = from.flat ? p0 : p0 + (prefix[from.s1 + r] - p0) * from.w
                        let b = to.flat ? q0 : q0 + (prefix[to.s1 + r] - q0) * to.w
                        out[r] = Float((b - a) / box)
                    }
                }
            }
        }
    }

    /// Where a time falls in the ring: offsets of the two frames around it and the weight of the second.
    private struct Cursor {
        var asked = -Double.infinity
        var s0 = 0, s1 = 0
        var w = 0.0
        /// The time is at or outside an end of the ring: only `s0` counts.
        var flat = true
    }

    private func locate(_ c: inout Cursor, _ asked: Double, _ times: UnsafeBufferPointer<Double>) {
        c.asked = asked
        let n = count, cap = capacity, f0 = first
        let newest = times[(f0 + n - 1) % cap], oldest = times[f0]
        let t = min(asked, newest)
        if t <= oldest { c.flat = true; c.s0 = f0 * rows; return }
        // A guess from the mean frame step, then a short walk.
        let meanStep = max((newest - oldest) / Double(n - 1), 1e-4)
        var k = min(max(n - 1 - Int((newest - t) / meanStep), 0), n - 1)
        while k < n - 1, times[(f0 + k + 1) % cap] <= t { k += 1 }
        while k > 0, times[(f0 + k) % cap] > t { k -= 1 }
        if k >= n - 1 { c.flat = true; c.s0 = ((f0 + n - 1) % cap) * rows; return }
        let a = (f0 + k) % cap, b = (f0 + k + 1) % cap
        c.flat = false
        c.s0 = a * rows; c.s1 = b * rows
        c.w = (t - times[a]) / max(times[b] - times[a], 1e-9)
    }
}
