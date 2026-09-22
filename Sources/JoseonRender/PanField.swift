import Accelerate
import Foundation
import JoseonCore

/// Stereo placement by frequency: where each display bin sits between left and right, and how much light it gets.
///
/// pan = (|R|^2 - |L|^2) / (|R|^2 + |L|^2) from per-bin POWER, smoothed over about 150 ms. A tone in one channel
/// is a dot at the far side; the same level in both is the center. The light follows the bin power; bins under the gate
/// get none. Under about 120 Hz several display bins share one FFT bin of the long window: L and R are interpolated apart,
/// and the pan of one display bin zigzags. There the powers are averaged over the width of an FFT bin first.
///
/// Tones: the skirt of a tone's lobe sinks into the noise, and the noise sits in the center. Bin by bin, a panned tone
/// therefore drew a streak from its true place to the center. A bin that belongs to a tonal peak (a local maximum 8 dB or
/// more over its 1/6-octave surroundings, and the lobe downhill from it) takes ONE pan: that of the peak bin, from the
/// power of the tone alone (the local noise of each channel is subtracted), as a median over about 200 ms. Noise-like bins
/// keep the smoothed-power pan.
final class PanField {
    /// Time constant of the power smoothing, seconds.
    var smoothingSeconds = 0.15
    /// Bins whose smoothed L + R power is under this get no light.
    var gateDB: Float = -70

    private(set) var count = 0
    /// -1 (left) ... +1 (right) per display bin.
    var pan: UnsafePointer<Float> { UnsafePointer(panP) }
    /// 10 log10(L power + R power), smoothed, per display bin.
    var levelDB: UnsafePointer<Float> { UnsafePointer(levelP) }
    /// Half-width of the frequency averaging per bin, in display bins (0 over about 150 Hz).
    private(set) var spread: [Int32] = []

    /// Length of the time median of a tone's pan, seconds.
    var medianSeconds = 0.2
    /// A peak is tonal when it stands this far over the mean level of +-1/6 octave around it.
    var tonalProminenceDB: Float = 8
    /// 1 where the bin belongs to the lobe of a tonal peak (newest update).
    private(set) var tonal: [UInt8] = []
    /// Peak bins of the newest update.
    private(set) var tonalPeaks: [Int] = []
    /// 1 where the bin is the skirt of a tone more than `skirtDropDB` under its peak: it gets no light. The skirt is the
    /// tone's own leakage. Where it sinks into the centered noise its pan lies anywhere between the tone and the center,
    /// which drew a streak from the center to every hard-panned tone. The tone itself is already drawn at its place.
    private(set) var dropped: [UInt8] = []
    var skirtDropDB: Float = 12

    /// Under this frequency the pan is damped toward the center by its confidence (full damping), fading out to `confidenceFadeHz`.
    var confidenceHz: Float = 40
    var confidenceFadeHz: Float = 60
    /// Time constant of the pan statistics behind the confidence, seconds (several analysis windows of the lows).
    var confidenceSeconds = 3.0
    /// Confidence 0...1 per bin (1 over `confidenceFadeHz`), newest update. Two factors:
    /// level: the bin stands over the local floor (the lowest level within half an octave), 3 dB = 0, 12 dB = 1;
    /// coherence: E[p]^2 / E[p^2] of the frame-by-frame pan p over `confidenceSeconds`. L and R that carry the same sound
    /// give the same pan in every frame (ratio 1). Independent noise in L and R gives a pan that wanders around 0 with the
    /// few FFT bins there are under 40 Hz (ratio near 0): that wander is estimation noise, not placement.
    private(set) var confidence: [Float] = []
    private var panMean: [Float] = [], panSquare: [Float] = []
    private var framePowL: [Float] = [], framePowR: [Float] = []
    private var confidenceBins = 0
    private var confidencePrimed = false

    private static let historyLength = 16
    private let panHistory: UnsafeMutablePointer<Float>        // capacity * historyLength: tone pans of peak bins
    private let panStamp: UnsafeMutablePointer<Int32>          // frame number of each entry, 0 = empty
    private var frameNumber: Int32 = 0
    private var medianScratch = [Float](repeating: 0, count: 64)
    private var prefix: [Float] = []
    private var prefixL: [Float] = [], prefixR: [Float] = []
    /// Frame number when a bin was last the peak of a tone (hysteresis), 0 = never.
    private var lastTonal: [Int32] = []
    /// The newest trusted tone pan per bin, and its frame number (0 = none).
    private var lastPan: [Float] = []
    private var lastPanFrame: [Int32] = []
    /// A tone that was there in the last `tonalHoldSeconds` stays a tone down to this prominence: a tone that breathes (its
    /// level moves with the music) must not flicker between a dot and a streak.
    var tonalHoldProminenceDB: Float = 2.5
    var tonalHoldSeconds = 1.5
    private var binsPerOctave: Float = 90

    private static let capacity = 8192
    private let store: UnsafeMutablePointer<Float>
    private var panP: UnsafeMutablePointer<Float> { store }
    private var levelP: UnsafeMutablePointer<Float> { store + Self.capacity }
    private var powL: UnsafeMutablePointer<Float> { store + Self.capacity * 2 }
    private var powR: UnsafeMutablePointer<Float> { store + Self.capacity * 3 }
    private var tmpL: UnsafeMutablePointer<Float> { store + Self.capacity * 4 }
    private var tmpR: UnsafeMutablePointer<Float> { store + Self.capacity * 5 }
    private var alpha: [Float] = []
    private var alphaDT = -1.0
    private var bandWindow: [Float] = []
    private var primed = false
    private var key: (Int, Float, Float, Double) = (0, 0, 0, 0)

    init() {
        store = .allocate(capacity: Self.capacity * 6)
        store.initialize(repeating: 0, count: Self.capacity * 6)
        panHistory = .allocate(capacity: Self.capacity * Self.historyLength)
        panHistory.initialize(repeating: 0, count: Self.capacity * Self.historyLength)
        panStamp = .allocate(capacity: Self.capacity * Self.historyLength)
        panStamp.initialize(repeating: 0, count: Self.capacity * Self.historyLength)
    }

    deinit { store.deallocate(); panHistory.deallocate(); panStamp.deallocate() }

    func reset() {
        primed = false
        panStamp.update(repeating: 0, count: Self.capacity * Self.historyLength)
        for i in lastTonal.indices { lastTonal[i] = 0; lastPanFrame[i] = 0 }
    }

    func update(_ s: SpectrumReading, dt: Double, sampleRate: Double) {
        let n = min(s.left.count, s.right.count, s.frequencies.count, Self.capacity)
        guard n >= 8, s.frequencies[0] > 0, s.frequencies[n - 1] > s.frequencies[0] else { count = 0; return }
        if key != (n, s.frequencies[0], s.frequencies[n - 1], sampleRate) {
            key = (n, s.frequencies[0], s.frequencies[n - 1], sampleRate)
            count = n
            // Width of one FFT bin of the long window, in display bins.
            let df = Float(1 / SpectrumTiming(sampleRate: sampleRate).window.0)
            let binsPerOctave = Float(n - 1) / log2(s.frequencies[n - 1] / s.frequencies[0])
            self.binsPerOctave = binsPerOctave
            tonal = [UInt8](repeating: 0, count: n)
            dropped = tonal
            confidence = [Float](repeating: 1, count: n)
            confidenceBins = s.frequencies.prefix(n).firstIndex(where: { $0 >= confidenceFadeHz }) ?? 0
            panMean = [Float](repeating: 0, count: confidenceBins); panSquare = panMean
            confidencePrimed = false
            prefix = [Float](repeating: 0, count: n + 1)
            prefixL = prefix; prefixR = prefix
            lastTonal = [Int32](repeating: 0, count: n)
            lastPan = [Float](repeating: 0, count: n)
            lastPanFrame = lastTonal
            tonalPeaks.reserveCapacity(64)
            panStamp.update(repeating: 0, count: Self.capacity * Self.historyLength)
            spread = s.frequencies.prefix(n).map { f in
                let w = df / (f * Float(M_LN2)) * binsPerOctave          // display bins per FFT bin
                return f < 150 ? Int32(min(w.rounded(), 14)) : 0
            }
            // The analysis window behind each bin: a pan reading cannot settle faster than its window renews.
            let timing = SpectrumTiming(sampleRate: sampleRate)
            bandWindow = s.frequencies.prefix(n).map { f in
                let w = SpectrumTiming.weights(atHz: f)
                return w.low * Float(timing.window.0) + w.mid * Float(timing.window.1) + w.high * Float(timing.window.2)
            }
            alphaDT = -1
            primed = false
        }
        let vn = vDSP_Length(n)
        var cnt = Int32(n)
        var k = Float(M_LN10 / 10)
        let target = primed ? (tmpL, tmpR) : (powL, powR)
        vDSP_vsmul(s.left, 1, &k, target.0, 1, vn); vvexpf(target.0, target.0, &cnt)
        vDSP_vsmul(s.right, 1, &k, target.1, 1, vn); vvexpf(target.1, target.1, &cnt)
        if primed {
            // One pole: p = p * (1 - a) + new * a
            // Time constant per bin: `smoothingSeconds`, or 1.2 analysis windows where that is longer (the lows).
            if abs(dt - alphaDT) > 1e-4 {
                alphaDT = dt
                alpha = bandWindow.map { Float(1 - exp(-max(dt, 0) / max(smoothingSeconds, Double($0) * 1.2, 1e-3))) }
            }
            // p += (new - p) * a
            vDSP_vsub(powL, 1, tmpL, 1, tmpL, 1, vn); vDSP_vma(tmpL, 1, alpha, 1, powL, 1, powL, 1, vn)
            vDSP_vsub(powR, 1, tmpR, 1, tmpR, 1, vn); vDSP_vma(tmpR, 1, alpha, 1, powR, 1, powR, 1, vn)
        }
        primed = true
        // Frequency averaging under 150 Hz, plain copy above. tmpL = L, tmpR = R after this.
        tmpL.update(from: powL, count: n); tmpR.update(from: powR, count: n)
        var i = 0
        while i < n, spread[i] > 0 {
            let r = Int(spread[i]), lo = max(i - r, 0), hi = min(i + r, n - 1)
            var l: Float = 0, rr: Float = 0
            for j in lo...hi { l += powL[j]; rr += powR[j] }
            tmpL[i] = l / Float(hi - lo + 1); tmpR[i] = rr / Float(hi - lo + 1)
            i += 1
        }
        vDSP_vsub(tmpL, 1, tmpR, 1, panP, 1, vn)                       // R - L
        vDSP_vadd(tmpL, 1, tmpR, 1, tmpL, 1, vn)                       // total
        var eps: Float = 1e-30
        vDSP_vsadd(tmpL, 1, &eps, tmpL, 1, vn)
        vDSP_vdiv(tmpL, 1, panP, 1, panP, 1, vn)                       // (R - L) / total
        vvlog10f(levelP, tmpL, &cnt)
        var ten: Float = 10
        vDSP_vsmul(levelP, 1, &ten, levelP, 1, vn)
        dampLowsByConfidence(s, n, dt: dt)
        // tmpL = total, tmpR = R (frequency averaged): L = total - R.
        placeTones(n, dt: dt, left: s.left, right: s.right)
    }

    /// Under 40 Hz: pan *= confidence (see `confidence`). Tones are placed after this and keep their own pan.
    private func dampLowsByConfidence(_ s: SpectrumReading, _ n: Int, dt: Double) {
        let m = min(confidenceBins, n)
        guard m > 0 else { return }
        let k = Float(1 - exp(-max(dt, 0) / max(confidenceSeconds, 1e-3)))
        let half = max(Int(binsPerOctave / 2), 1)
        // This frame's powers of the bins the lows average over (no allocation: the arrays keep their size).
        let reachBins = min(m + 15, n)
        if framePowL.count != reachBins { framePowL = [Float](repeating: 0, count: reachBins); framePowR = framePowL }
        for j in 0..<reachBins { framePowL[j] = pow(10, s.left[j] / 10); framePowR[j] = pow(10, s.right[j] / 10) }
        for i in 0..<m {
            // This frame's pan from this frame's powers, averaged over the same bins as the smoothed pan.
            let r = Int(spread[i]), lo = max(i - r, 0), hi = min(i + r, n - 1)
            var l: Float = 0, rr: Float = 0
            for j in lo...min(hi, reachBins - 1) { l += framePowL[j]; rr += framePowR[j] }
            let p = (rr - l) / max(rr + l, 1e-30)
            if confidencePrimed {
                panMean[i] += (p - panMean[i]) * k; panSquare[i] += (p * p - panSquare[i]) * k
            } else {
                // One reading says nothing about steadiness: start without confidence in a pan away from the center.
                panMean[i] = p; panSquare[i] = p * p + 0.05
            }
            let coherence = min(panMean[i] * panMean[i] / max(panSquare[i], 1e-6), 1)
            var floor = levelP[i]
            for j in stride(from: max(i - half, 0), through: min(i + half, n - 1), by: 2) { floor = min(floor, levelP[j]) }
            // A flat stretch has no floor to stand over: the level factor asks only that the bin is not the hole itself.
            let over = min(max((levelP[i] - floor - 3) / 9, 0), 1)
            let flat = levelP[min(i + half, n - 1)] - floor < 6 && levelP[max(i - half, 0)] - floor < 6
            let c = coherence * (flat ? 1 : over)
            let f = s.frequencies[i]
            let fade = min(max((f - confidenceHz) / max(confidenceFadeHz - confidenceHz, 1), 0), 1)
            confidence[i] = c + (1 - c) * fade
            panP[i] *= confidence[i]
        }
        confidencePrimed = true
    }

    /// Finds the tonal peaks and gives every bin of a tone's lobe the pan of the tone.
    /// A peak is a local maximum of the smoothed L + R level. Its prominence is the largest of three: in L + R, in L alone and
    /// in R alone (a tone in one channel stands 3 dB higher over that channel's noise than over the noise of both).
    private func placeTones(_ n: Int, dt: Double, left: [Float], right rightDB: [Float]) {
        frameNumber &+= 1
        if frameNumber <= 0 || frameNumber > Int32.max - 8 {
            frameNumber = 1
            panStamp.update(repeating: 0, count: Self.capacity * Self.historyLength)
            for i in 0..<n { lastTonal[i] = 0; lastPanFrame[i] = 0 }
        }
        let level = levelP, total = tmpL, right = tmpR
        for i in 0..<n {
            tonal[i] = 0; dropped[i] = 0
            prefix[i + 1] = prefix[i] + level[i]
            prefixL[i + 1] = prefixL[i] + left[i]
            prefixR[i + 1] = prefixR[i] + rightDB[i]
        }
        tonalPeaks.removeAll(keepingCapacity: true)
        let r = max(Int((binsPerOctave / 6).rounded()), 3)
        let reach = r * 2
        let flank = max(r / 2, 2)
        let frames = min(max(Int((medianSeconds / max(dt, 1e-3)).rounded()), 1), Self.historyLength)
        let holdFrames = Int32(max(tonalHoldSeconds / max(dt, 1e-3), 2))
        var i = 2
        while i < n - 2 {
            let v = level[i]
            guard v > gateDB, v >= level[i - 1], v > level[i + 1] else { i += 1; continue }
            let a0 = max(i - r, 0), b0 = min(i + r, n - 1), c0 = Float(b0 - a0 + 1)
            let prominence = max(v - (prefix[b0 + 1] - prefix[a0]) / c0,
                                 max(left[i - 1], left[i], left[i + 1]) - (prefixL[b0 + 1] - prefixL[a0]) / c0,
                                 max(rightDB[i - 1], rightDB[i], rightDB[i + 1]) - (prefixR[b0 + 1] - prefixR[a0]) / c0)
            let held = max(lastTonal[i - 1], lastTonal[i], lastTonal[i + 1])
            let wasTonal = held > 0 && frameNumber - held <= holdFrames
            guard prominence >= (wasTonal ? tonalHoldProminenceDB : tonalProminenceDB) else { i += 1; continue }
            // Only a full detection renews the hold: a held tone cannot hold itself for ever.
            if prominence >= tonalProminenceDB { lastTonal[i] = frameNumber }
            // The lobe: downhill from the peak, at most 1/3 octave, not under the gate.
            var a = i, b = i
            // The skirt of a lobe falls steeply; where the fall flattens (under 0.8 dB over two bins) the background begins,
            // and the background keeps its own pan.
            func falls(_ from: Int, _ step: Int) -> Bool {
                let next = from + step, after = min(max(next + step, 0), n - 1)
                return level[next] < level[from] + 0.3 && level[after] < level[from] - 0.8
            }
            while a > 0, i - a < reach, falls(a, -1), level[a - 1] > gateDB - 6, tonal[a - 1] == 0 { a -= 1 }
            while b < n - 1, b - i < reach, falls(b, 1), level[b + 1] > gateDB - 6 { b += 1 }
            // Noise of each channel beside the lobe (mean power of the two flanks). A flank inside another tone does not count.
            var nt: Float = 0, nr: Float = 0, c: Float = 0
            for j in max(a - flank, 0)..<a where tonal[j] == 0 { nt += total[j]; nr += right[j]; c += 1 }
            if b + 1 < n { for j in (b + 1)...min(b + flank, n - 1) { nt += total[j]; nr += right[j]; c += 1 } }
            if c > 0 { nt /= c; nr /= c }
            // The tone's power per channel: what stands over that channel's noise (1.5 times the flank mean: the peak bin of
            // a channel without the tone reads a little over its flanks). A one-sided tone sits at the far side, not where
            // the noise of the other channel pulls it.
            let pr = right[i], pl = max(total[i] - right[i], 0), nl = max(nt - nr, 0)
            let toneR = max(pr - 1.5 * nr, 0), toneL = max(pl - 1.5 * nl, 0)
            let sum = toneL + toneR
            // Only a tone that stands 6 dB over the noise in its louder channel gives a pan that can be trusted. A weaker one
            // (a tone that breathes, a partial that dies away) keeps the last trusted pan: see below.
            // And the tone must still sound: the smoothed power of the lows outlives a note by a second. Once the frame's own
            // level has fallen 10 dB under the smoothed level, what is left is the tail of the smoothing, not a reading.
            let live = max(left[i - 1], left[i], left[i + 1], rightDB[i - 1], rightDB[i], rightDB[i + 1]) + 3
            let trusted = sum > 0 && live >= v - 10 && max(pr / max(nr, 1e-30), pl / max(nl, 1e-30)) >= 4
            if trusted {
                let slot = Int(frameNumber) % Self.historyLength
                panHistory[i * Self.historyLength + slot] = (toneR - toneL) / sum
                panStamp[i * Self.historyLength + slot] = frameNumber
                lastPan[i] = (toneR - toneL) / sum
                lastPanFrame[i] = frameNumber
            }
            // Median of the tone's pan over the last `frames` frames. The peak may sit one bin higher or lower from frame to frame.
            var m = 0
            for j in max(i - 1, 0)...min(i + 1, n - 1) {
                for k in 0..<Self.historyLength {
                    let stamp = panStamp[j * Self.historyLength + k]
                    if stamp > 0, frameNumber - stamp < Int32(frames), m < medianScratch.count { medianScratch[m] = panHistory[j * Self.historyLength + k]; m += 1 }
                }
            }
            if m == 0 {
                // No trusted reading in the last 200 ms: the newest one of the hold time, if there is one.
                var newest: Int32 = 0
                for j in max(i - 1, 0)...min(i + 1, n - 1) where lastPanFrame[j] > newest && frameNumber - lastPanFrame[j] <= holdFrames {
                    newest = lastPanFrame[j]; medianScratch[0] = lastPan[j]; m = 1
                }
            }
            if m > 0 {
                // Insertion sort: m is at most 48.
                if m > 1 {
                    for x in 1..<m {
                        let key = medianScratch[x]
                        var y = x - 1
                        while y >= 0, medianScratch[y] > key { medianScratch[y + 1] = medianScratch[y]; y -= 1 }
                        medianScratch[y + 1] = key
                    }
                }
                let median = m % 2 == 1 ? medianScratch[m / 2] : (medianScratch[m / 2 - 1] + medianScratch[m / 2]) / 2
                for j in a...b { panP[j] = median; tonal[j] = 1; if level[j] < v - skirtDropDB { dropped[j] = 1 } }
                tonalPeaks.append(i)
                // Past the lobe the skirt goes on under the noise. While a bin there is more than 12 dB under the peak and
                // its pan is still pulled from the background toward the tone, it is skirt: no light. The walk ends where
                // the pull ends, where the level climbs again (the next sound) and after `reach` bins.
                var bg: Float = 0, bc: Float = 0
                for j in max(a - reach - flank, 0)..<max(a - reach, 0) where tonal[j] == 0 { bg += panP[j]; bc += 1 }
                for j in min(b + reach + 1, n)..<min(b + reach + flank + 1, n) { bg += panP[j]; bc += 1 }
                if bc > 0 { bg /= bc }
                let pull = median - bg
                if abs(pull) > 0.2 {
                    for step in [-1, 1] {
                        var j = step < 0 ? a - 1 : b + 1
                        var lowest = level[step < 0 ? a : b]
                        var walked = 0
                        while j >= 0, j < n, walked < reach, tonal[j] == 0, level[j] < v - skirtDropDB, level[j] <= lowest + 1,
                              (panP[j] - bg) / pull > 0.15 {
                            dropped[j] = 1
                            lowest = min(lowest, level[j])
                            j += step; walked += 1
                        }
                    }
                }
            }
            i = b + 1
        }
    }

    /// Light of a bin, 0...1: 0 at or under the gate or `bottomDB`, 1 at `topDB`.
    @inline(__always) func light(_ i: Int, topDB: Float, bottomDB: Float) -> Float {
        let v = levelDB[i]
        let floor = max(bottomDB, gateDB)
        guard v > floor, dropped[i] == 0 else { return 0 }
        return min((v - floor) / max(topDB - floor, 1), 1)
    }
}
