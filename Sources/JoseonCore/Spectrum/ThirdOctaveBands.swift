import Accelerate
import Foundation

/// IEC 61260 third-octave band levels, summed out of the FFT power spectra the analyzer
/// already computes. No extra transform runs for this.
///
/// ## The normalisation, derived
///
/// The display path is *not* reusable here. It sums a fixed small number of bins per display
/// bin and adds drawn tone lobes on top, which is calibrated for tones and only approximately
/// right for noise. A band level has to be right for both, so this reads `SpectrumResolution.power`
/// directly. That array happens to carry exactly the constant this needs, and it is worth
/// writing out why.
///
/// vDSP's packed real forward FFT returns twice the mathematical DFT, so the squared magnitude
/// it reports is `4 |X[k]|^2`. `SpectrumResolution` then multiplies by `normScale = 1 / (N * Sw2)`
/// with `Sw2 = sum_n w[n]^2`. Parseval for the windowed block `y[n] = x[n] w[n]` says
/// `sum_{k=0}^{N-1} |X[k]|^2 = N * sum_n y[n]^2`, and for a real block the one-sided half
/// (bins `1 ... N/2 - 1`, which is what the analyzer keeps) holds half of that. So
///
///     sum_k power[k] = 4 / (N * Sw2) * (1/2) * N * sum_n y[n]^2
///                    = 2 * sum_n (x[n] w[n])^2 / Sw2.
///
/// If the block's mean square is `ms` then `sum_n (x w)^2 = ms * Sw2` (exactly in expectation for
/// stationary noise; exactly up to one half-cycle of ripple for a sine over a window that spans
/// many periods). Both window sums cancel, and what is left is
///
///     **sum_k power[k] = 2 * ms**
///
/// with no window correction of any kind still to apply. That single fact is why the same
/// constant serves noise and tones at once: `normScale` is Parseval's constant, not the
/// coherent-gain constant a tone-only calibration would use.
///
/// So a band's RMS level is
///
///     L_band = 10 * log10( sum_{k in band} power[k] / 2 )   dBFS RMS
///
/// and a full-scale sine sitting inside a band reads `10 * log10(1/2) = -3.01 dBFS`, which is the
/// convention `ThirdOctaveReading` asks for. (The same arithmetic re-derives the claim in
/// `SpectrumResolution`'s header that a full-scale sine's main lobe sums to 1.0 there.)
///
/// ## Band edges
///
/// Base-10 bands: exact centre `fc(n) = 1000 * 10^(n/10)` for `n = -17 ... 13`, edges
/// `fc * 10^(+-1/20)`. The nominal centres in `ThirdOctaveReading.nominalCentersHz` are only
/// labels; every sum uses the exact edges, so neighbouring bands tile the axis with no gap and
/// no overlap (`fc(n) * 10^(1/20) == fc(n+1) * 10^(-1/20)`).
///
/// A bin `k` covers `(k +- 0.5) * df`. Bins that straddle a band edge are taken with the
/// fraction of their width that falls inside, which is the unbiased split for broadband content
/// and, for a tone, divides it between the two bands the way its own bandwidth really does.
///
/// ## Which FFT feeds which band
///
/// The shortest FFT that puts at least `minBinsPerBand` bins across the band width
/// `fc * (10^(1/20) - 10^(-1/20)) = 0.2308 * fc`. Shortest, because a short window is a fast
/// meter; at least three bins, because below that the band is narrower than the window's own
/// resolution bandwidth and the level stops being a band level. At 48 kHz that gives
///
/// | bands          | FFT   | df       | bins in the narrowest band of the group |
/// |----------------|-------|----------|------------------------------------------|
/// | 20 - 63 Hz     | 32768 | 1.465 Hz | 3.1 at 20 Hz                             |
/// | 80 - 250 Hz    | 8192  | 5.859 Hz | 3.1 at 80 Hz                             |
/// | 315 Hz - 20 kHz| 2048  | 23.44 Hz | 3.1 at 315 Hz                            |
///
/// The split lands in the same place at 44.1 kHz and 96 kHz, because the analyzer scales the FFT
/// sizes with the sample rate to keep the window durations fixed.
///
/// ## Effective integration time per band
///
/// The time weighting is IEC 61672 "fast": a one-pole on band **power** with `fastTau` = 125 ms,
/// stepped by the audio clock on every `process` call. But the FFT window in front of it is an
/// averager too, and for the long windows it is the slower of the two. A Hann window of `N`
/// samples averages power over an equivalent rectangular time of `(sum w^2)^2 / sum w^4 / fs`,
/// which is `0.514 * N / fs`; a one-pole of time constant `tau` is equivalent to `2 * tau`; the
/// two in series add to a good approximation. Latency is the window centre, `N / (2 fs)`.
///
/// | bands           | window   | hop    | window averages | + fast | total  | latency |
/// |-----------------|----------|--------|-----------------|--------|--------|---------|
/// | 20 - 63 Hz      | 683 ms   | 114 ms | 351 ms          | 250 ms | ~600 ms| 341 ms  |
/// | 80 - 250 Hz     | 171 ms   | 21 ms  | 88 ms           | 250 ms | ~338 ms| 85 ms   |
/// | 315 Hz - 20 kHz | 43 ms    | 16 ms  | 22 ms           | 250 ms | ~272 ms| 21 ms   |
///
/// So only the top group is a true 125 ms fast meter. The bottom six bands are slower than fast
/// and lag by a third of a second. That is not a defect that can be tuned away: 4.6 Hz of
/// bandwidth at 20 Hz cannot be measured in 125 ms, and a shorter window there would report
/// noise instead of level. It is accepted and documented rather than hidden.
final class ThirdOctaveBank {
    static let bandCount = 31
    static let floorDB = ThirdOctaveReading.floorDB
    /// A resolution may serve a band only when it puts at least this many bins across it.
    static let minBinsPerBand: Double = 3
    /// IEC 61672 "fast": one pole on band power, 125 ms.
    static let fastTau = 0.125
    /// Bands whose exact centre sits above this fraction of Nyquist report the floor.
    static let nyquistFraction = 0.9
    /// Exponents of the base-10 band centres: `fc = 1000 * 10^(n/10)`, 20 Hz ... 20 kHz.
    static let firstExponent = -17

    /// Exact (not nominal) centre of band `b`.
    static func exactCenterHz(_ b: Int) -> Double { 1_000 * pow(10, Double(b + firstExponent) / 10) }
    static func lowerEdgeHz(_ b: Int) -> Double { exactCenterHz(b) * pow(10, -0.05) }
    static func upperEdgeHz(_ b: Int) -> Double { exactCenterHz(b) * pow(10, 0.05) }

    // MARK: - Map

    /// Which resolution serves each band: 0 low, 1 mid, 2 high, -1 floor (above Nyquist * 0.9).
    private var layerOf = [Int](repeating: -1, count: ThirdOctaveBank.bandCount)
    /// Contiguous band range each resolution owns. The "shortest FFT with enough bins" rule is
    /// monotone in frequency, so these really are ranges and `capture` is one loop.
    private var layerFirstBand = [Int](repeating: 0, count: 3)
    private var layerLastBand = [Int](repeating: -1, count: 3)
    private var firstBin = [Int](repeating: 0, count: ThirdOctaveBank.bandCount)
    private var binCount = [Int](repeating: 0, count: ThirdOctaveBank.bandCount)
    private var weightOffset = [Int](repeating: 0, count: ThirdOctaveBank.bandCount)
    /// Per-bin fraction-inside-the-band weights, all bands end to end.
    private var weights = FloatScratch(1)

    // MARK: - State

    /// Latest instantaneous band power, `channel * bandCount + band`. Channel 0 left, 1 right.
    private var target = FloatScratch(2 * ThirdOctaveBank.bandCount)
    /// The fast-weighted band power: what the reading is made of.
    private var smooth = FloatScratch(2 * ThirdOctaveBank.bandCount)
    private var work = FloatScratch(2 * ThirdOctaveBank.bandCount)
    /// A resolution that serves bands has transformed at least once.
    private var seen = [Bool](repeating: false, count: 3)
    private var configured = false

    // MARK: - Configuration

    /// Build the band-to-bin map. Runs only from `SpectrumAnalyzer.configure`, never from `process`.
    /// Returns the FFT-bin range each resolution has to compute left/right power over, or nil
    /// where it serves no band.
    func configure(sampleRate: Double, resolutions: [SpectrumResolution?]) -> [(lo: Int, hi: Int)?] {
        layerOf = [Int](repeating: -1, count: Self.bandCount)
        firstBin = [Int](repeating: 0, count: Self.bandCount)
        binCount = [Int](repeating: 0, count: Self.bandCount)
        weightOffset = [Int](repeating: 0, count: Self.bandCount)
        layerFirstBand = [Int](repeating: 0, count: 3)
        layerLastBand = [Int](repeating: -1, count: 3)
        seen = [Bool](repeating: false, count: 3)
        target.zero()
        smooth.zero()
        configured = false

        let nyquist = sampleRate / 2
        var flat = [Float]()
        flat.reserveCapacity(4_096)

        for b in 0..<Self.bandCount {
            let center = Self.exactCenterHz(b)
            let lower = Self.lowerEdgeHz(b), upper = Self.upperEdgeHz(b)
            guard center <= nyquist * Self.nyquistFraction else { continue }

            // Shortest FFT (highest layer index) with enough bins across the band.
            var chosen = -1
            for layer in [2, 1, 0] {
                guard let res = resolutions[layer] else { continue }
                if (upper - lower) / Double(res.df) >= Self.minBinsPerBand { chosen = layer; break }
            }
            guard chosen >= 0, let res = resolutions[chosen] else { continue }

            let df = Double(res.df)
            let maxBin = res.half - 1
            // Bin k spans (k - 0.5) df ... (k + 0.5) df. These are the bins that overlap the band.
            let k0 = max(Int((lower / df - 0.5).rounded(.down)) + 1, 1)
            let k1 = min(Int((upper / df + 0.5).rounded(.up)) - 1, maxBin)
            guard k1 >= k0 else { continue }

            layerOf[b] = chosen
            firstBin[b] = k0
            binCount[b] = k1 - k0 + 1
            weightOffset[b] = flat.count
            for k in k0...k1 {
                let binLo = (Double(k) - 0.5) * df, binHi = (Double(k) + 0.5) * df
                let overlap = min(binHi, upper) - max(binLo, lower)
                flat.append(Float(max(0, min(overlap / df, 1))))
            }
            if layerLastBand[chosen] < layerFirstBand[chosen] { layerFirstBand[chosen] = b }
            layerLastBand[chosen] = b
        }

        weights = FloatScratch(max(flat.count, 1))
        for i in 0..<flat.count { weights.p[i] = flat[i] }
        configured = true

        return (0..<3).map { layer -> (lo: Int, hi: Int)? in
            let first = layerFirstBand[layer], last = layerLastBand[layer]
            guard last >= first else { return nil }
            var lo = Int.max, hi = 0
            for b in first...last where binCount[b] > 0 {
                lo = min(lo, firstBin[b])
                hi = max(hi, firstBin[b] + binCount[b] - 1)
            }
            return lo <= hi ? (lo, hi) : nil
        }
    }

    // MARK: - Per-transform capture

    /// New instantaneous band power for the bands this resolution owns. Called right after the
    /// resolution transformed, so it reads the power spectrum of that hop.
    func capture(layer: Int, from res: SpectrumResolution) {
        let first = layerFirstBand[layer], last = layerLastBand[layer]
        guard last >= first else { return }
        seen[layer] = true
        let half = res.half
        for c in 0..<2 {
            let pw = UnsafePointer(res.power.p + c * half)
            let out = target.p + c * Self.bandCount
            for b in first...last {
                let n = binCount[b]
                guard n > 0 else { continue }
                var sum: Float = 0
                vDSP_dotpr(pw + firstBin[b], 1, weights.p + weightOffset[b], 1, &sum, vDSP_Length(n))
                out[b] = max(sum, 0)
            }
        }
    }

    /// Step the fast integrator by `seconds` of audio. One pole on power, audio-clock driven.
    func advance(seconds: Double) {
        guard configured, seconds > 0 else { return }
        var alpha = Float(1 - exp(-seconds / Self.fastTau))
        let n = vDSP_Length(2 * Self.bandCount)
        vDSP_vsub(smooth.p, 1, target.p, 1, work.p, 1, n)          // work = target - smooth
        vDSP_vsma(work.p, 1, &alpha, smooth.p, 1, smooth.p, 1, n)  // smooth += alpha * work
    }

    // MARK: - Output

    /// True once every resolution that serves a band has transformed at least once.
    var hasData: Bool {
        guard configured else { return false }
        for layer in 0..<3 where layerLastBand[layer] >= layerFirstBand[layer] {
            if !seen[layer] { return false }
        }
        return true
    }

    /// The reading. Allocates the two arrays; `process` never calls this.
    func reading() -> ThirdOctaveReading? {
        guard hasData else { return nil }
        var left = [Float](repeating: Self.floorDB, count: Self.bandCount)
        var right = [Float](repeating: Self.floorDB, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            left[b] = Self.levelDB(smooth.p[b])
            right[b] = Self.levelDB(smooth.p[Self.bandCount + b])
        }
        return ThirdOctaveReading(left: left, right: right)
    }

    /// Band power to dBFS RMS. The `/ 2` is the whole calibration; see the type's header.
    @inline(__always)
    static func levelDB(_ power: Float) -> Float {
        guard power > 0, power.isFinite else { return floorDB }
        return max(10 * log10(power / 2), floorDB)
    }

    /// Clears the integrators. The band map and the "has transformed" flags are kept: the
    /// analyzer's own `reset` keeps the FFT history too, so the meter refills instead of blanking.
    func reset() {
        target.zero()
        smooth.zero()
    }

    // MARK: - Test hooks

    /// Which resolution (0 low, 1 mid, 2 high, -1 floor) serves each band.
    var layerAssignment: [Int] { layerOf }
    /// FFT bins summed for each band, and the sum of their weights (the band width in bins).
    func footprint(_ band: Int) -> (first: Int, count: Int, weightSum: Float) {
        var s: Float = 0
        for i in 0..<binCount[band] { s += weights.p[weightOffset[band] + i] }
        return (firstBin[band], binCount[band], s)
    }
}
