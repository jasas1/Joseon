import Foundation
import Accelerate

/// Stereo field analysis: phase correlation, balance, width, the same three per listening
/// band, and the vectorscope point cloud.
///
/// Design
/// ------
/// * All running numbers use one exponential window of about 300 ms. The window is a
///   one-pole leaky integrator over the raw products `L·L`, `R·R` and `L·R`, so
///   `correlation = ΣLR / √(ΣLL · ΣRR)`. Mid and side get their own accumulators instead
///   of being derived from the three above: for a near-mono signal the derived form
///   cancels to noise.
/// * The band numbers come from a filter bank of 8th-order Linkwitz-Riley band-passes
///   (48 dB/octave), one per `BandEnergy.edgesHz` band, built for the live sample rate
///   (`BandSplitFilterBank`). Left and right run identical coefficients.
/// * A band whose level sits under `silenceMeanSquare` (-100 dBFS) or more than 80 dB
///   under the broadband level reports 0 correlation and 0 balance, so empty bands read
///   neutral instead of amplifying filter skirt leakage.
/// * `width` is the side RMS over the mid RMS: 0 for mono, 1 for a hard-panned channel,
///   clamped at `maxWidth` where there is no mid energy at all.
/// * `process` is real-time safe after the first call at a given sample rate: every
///   buffer it touches is allocated in `configure`. It works in chunks of
///   `maxChunkFrames`, so a large `count` still allocates nothing. `read` allocates its
///   result arrays, as the contract allows.
/// * One thread. There is no internal locking: `AnalysisEngine` calls `process` and
///   `read` from its own analysis queue.
public final class StereoAnalyzer: StereoAnalyzing {
    // MARK: Tunables

    /// Time constant of the running window in seconds.
    public static let windowSeconds: Double = 0.3
    /// Span of the vectorscope point cloud in seconds.
    public static let scopeSeconds: Double = 0.05
    /// `width` is clamped here. An anti-phase signal has no mid energy at all.
    public static let maxWidth: Float = 4
    /// Below this mean square (-100 dBFS) the input counts as silent.
    public static let silenceMeanSquare: Double = 1e-10
    /// A band this far under the broadband level (80 dB) counts as empty.
    public static let bandRelativeFloor: Double = 1e-8
    /// Frames per internal processing chunk. Bounds every scratch buffer.
    public static let maxChunkFrames = 1024

    // MARK: Contract

    public var scopePointCount: Int = 2048

    // MARK: State

    private let bandCount = BandEnergy.edgesHz.count - 1
    private var configuredSampleRate: Double = 0
    /// Per-sample decay of the running window.
    private var perSampleDecay: Double = 0

    private var accLL: Double = 0
    private var accRR: Double = 0
    private var accLR: Double = 0
    private var accMM: Double = 0
    private var accSS: Double = 0
    /// Sum of the window weights. Turns the accumulators into mean squares.
    private var accNorm: Double = 0
    /// Chunks that had a NaN or an Inf sample. For tests and diagnostics.
    private(set) var sanitizedChunkCount = 0

    private let bandLL: UnsafeMutablePointer<Double>
    private let bandRR: UnsafeMutablePointer<Double>
    private let bandLR: UnsafeMutablePointer<Double>

    private var bank: BandSplitFilterBank?

    // Scratch, sized once for `maxChunkFrames`.
    private let workL: UnsafeMutablePointer<Double>
    private let workR: UnsafeMutablePointer<Double>
    private let workM: UnsafeMutablePointer<Double>
    private let workS: UnsafeMutablePointer<Double>
    private let bandL: UnsafeMutablePointer<Double>
    private let bandR: UnsafeMutablePointer<Double>

    // Vectorscope ring, one slot per input frame over `scopeSeconds`.
    private var scopeX: UnsafeMutablePointer<Float>?
    private var scopeY: UnsafeMutablePointer<Float>?
    private var scopeCapacity = 0
    private var scopeWrite = 0
    private var scopeFilled = 0

    public init() {
        let chunk = Self.maxChunkFrames
        let bands = BandEnergy.edgesHz.count - 1
        bandLL = .allocate(capacity: bands); bandLL.initialize(repeating: 0, count: bands)
        bandRR = .allocate(capacity: bands); bandRR.initialize(repeating: 0, count: bands)
        bandLR = .allocate(capacity: bands); bandLR.initialize(repeating: 0, count: bands)
        workL = .allocate(capacity: chunk); workL.initialize(repeating: 0, count: chunk)
        workR = .allocate(capacity: chunk); workR.initialize(repeating: 0, count: chunk)
        workM = .allocate(capacity: chunk); workM.initialize(repeating: 0, count: chunk)
        workS = .allocate(capacity: chunk); workS.initialize(repeating: 0, count: chunk)
        bandL = .allocate(capacity: chunk); bandL.initialize(repeating: 0, count: chunk)
        bandR = .allocate(capacity: chunk); bandR.initialize(repeating: 0, count: chunk)
    }

    deinit {
        bandLL.deallocate(); bandRR.deallocate(); bandLR.deallocate()
        workL.deallocate(); workR.deallocate(); workM.deallocate(); workS.deallocate()
        bandL.deallocate(); bandR.deallocate()
        scopeX?.deallocate(); scopeY?.deallocate()
    }

    // MARK: Configuration

    /// Rebuilds the filter bank and the scope ring for a new sample rate and clears state.
    /// Called from `process` when the rate changes, never in the steady state.
    private func configure(sampleRate: Double) {
        configuredSampleRate = sampleRate
        perSampleDecay = exp(-1.0 / (Self.windowSeconds * sampleRate))
        bank = BandSplitFilterBank(edgesHz: BandEnergy.edgesHz, sampleRate: sampleRate)

        let wanted = max(64, Int((Self.scopeSeconds * sampleRate).rounded(.up)))
        if wanted != scopeCapacity {
            scopeX?.deallocate(); scopeY?.deallocate()
            let x = UnsafeMutablePointer<Float>.allocate(capacity: wanted)
            x.initialize(repeating: 0, count: wanted)
            let y = UnsafeMutablePointer<Float>.allocate(capacity: wanted)
            y.initialize(repeating: 0, count: wanted)
            scopeX = x; scopeY = y
            scopeCapacity = wanted
        }
        clearRunningState()
    }

    private func clearRunningState() {
        accLL = 0; accRR = 0; accLR = 0; accMM = 0; accSS = 0; accNorm = 0
        bandLL.update(repeating: 0, count: bandCount)
        bandRR.update(repeating: 0, count: bandCount)
        bandLR.update(repeating: 0, count: bandCount)
        bank?.resetState()
        scopeWrite = 0
        scopeFilled = 0
        if let x = scopeX, let y = scopeY, scopeCapacity > 0 {
            x.update(repeating: 0, count: scopeCapacity)
            y.update(repeating: 0, count: scopeCapacity)
        }
    }

    public func reset() {
        clearRunningState()
    }

    // MARK: Processing

    public func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard count > 0, sampleRate > 0, sampleRate.isFinite else { return }
        if sampleRate != configuredSampleRate { configure(sampleRate: sampleRate) }

        var offset = 0
        while offset < count {
            let n = min(Self.maxChunkFrames, count - offset)
            processChunk(left: left + offset, right: right + offset, count: n)
            offset += n
        }
    }

    private func processChunk(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count n: Int) {
        let length = vDSP_Length(n)
        vDSP_vspdp(left, 1, workL, 1, length)
        vDSP_vspdp(right, 1, workR, 1, length)

        // A NaN or an Inf sample would stay in the accumulators and in the filter memory until the next
        // reset. The two energy sums below are needed anyway; they are finite only when every sample is
        // finite. So the check is free, and the repair (non-finite → 0) runs only for a bad block.
        var sumLL = 0.0, sumRR = 0.0
        vDSP_dotprD(workL, 1, workL, 1, &sumLL, length)
        vDSP_dotprD(workR, 1, workR, 1, &sumRR, length)
        let hadNonFinite = !(sumLL + sumRR).isFinite
        if hadNonFinite {
            sanitizedChunkCount += 1
            for i in 0..<n {
                // Float.greatestFiniteMagnitude squared is finite in Double, so only NaN and Inf land here.
                if !workL[i].isFinite { workL[i] = 0 }
                if !workR[i].isFinite { workR[i] = 0 }
            }
            vDSP_dotprD(workL, 1, workL, 1, &sumLL, length)
            vDSP_dotprD(workR, 1, workR, 1, &sumRR, length)
        }

        // Mid = (L+R)/2, side = (L-R)/2. vDSP_vsubD computes C = B - A.
        var half = 0.5
        vDSP_vaddD(workL, 1, workR, 1, workM, 1, length)
        vDSP_vsmulD(workM, 1, &half, workM, 1, length)
        vDSP_vsubD(workR, 1, workL, 1, workS, 1, length)
        vDSP_vsmulD(workS, 1, &half, workS, 1, length)

        var sumLR = 0.0, sumMM = 0.0, sumSS = 0.0
        vDSP_dotprD(workL, 1, workR, 1, &sumLR, length)
        vDSP_dotprD(workM, 1, workM, 1, &sumMM, length)
        vDSP_dotprD(workS, 1, workS, 1, &sumSS, length)

        let decay = pow(perSampleDecay, Double(n))
        accLL = accLL * decay + sumLL
        accRR = accRR * decay + sumRR
        accLR = accLR * decay + sumLR
        accMM = accMM * decay + sumMM
        accSS = accSS * decay + sumSS
        accNorm = accNorm * decay + Double(n)

        if let bank {
            for band in 0..<bandCount {
                bank.filterLeft(band: band, input: workL, output: bandL, count: n)
                bank.filterRight(band: band, input: workR, output: bandR, count: n)
                var bLL = 0.0, bRR = 0.0, bLR = 0.0
                vDSP_dotprD(bandL, 1, bandL, 1, &bLL, length)
                vDSP_dotprD(bandR, 1, bandR, 1, &bRR, length)
                vDSP_dotprD(bandL, 1, bandR, 1, &bLR, length)
                bandLL[band] = bandLL[band] * decay + bLL
                bandRR[band] = bandRR[band] * decay + bRR
                bandLR[band] = bandLR[band] * decay + bLR
            }
        }

        // Long silence would otherwise let every accumulator decay through the denormal
        // range and stay there. Nothing this small is ever read back.
        if accLL + accRR < 1e-30 {
            accLL = 0; accRR = 0; accLR = 0; accMM = 0; accSS = 0
            bandLL.update(repeating: 0, count: bandCount)
            bandRR.update(repeating: 0, count: bandCount)
            bandLR.update(repeating: 0, count: bandCount)
        }

        appendScopePoints(left: left, right: right, count: n, sanitize: hadNonFinite)
    }

    /// x = (R − L)·0.5, y = (L + R)·0.5. The clamp to -1...1 is for out-of-range input only.
    ///
    /// The scale is 0.5, not 0.7071, so that the mapping fits the contract's -1...1 box for
    /// every in-range sample: |x| + |y| = max(|L|, |R|) ≤ 1, which is the unit square's
    /// inscribed diamond. The full-scale diamond therefore has its tips exactly at ±1 on
    /// both axes, and a hard-clipped signal runs along its 45° edges instead of hitting a
    /// clamp. At 0.7071 a clipped mono signal gave y = ±1.414 and the clamp drew a flat top
    /// and bottom inside the diamond (critic r4 defect 11).
    ///
    /// A renderer draws the diamond with its tips at ±1 on both axes, and recovers
    /// max(|L|, |R|) as |x| + |y|.
    ///
    /// `sanitize`: the chunk has a non-finite sample; those samples count as 0.
    private func appendScopePoints(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count n: Int, sanitize: Bool = false) {
        guard let xs = scopeX, let ys = scopeY, scopeCapacity > 0 else { return }
        let k: Float = 0.5
        // Only the newest `scopeCapacity` frames can survive.
        var start = 0
        if n > scopeCapacity { start = n - scopeCapacity }
        var w = scopeWrite
        for i in start..<n {
            var l = left[i], r = right[i]
            if sanitize {
                if !l.isFinite { l = 0 }
                if !r.isFinite { r = 0 }
            }
            var x = (r - l) * k
            var y = (l + r) * k
            if x > 1 { x = 1 } else if x < -1 { x = -1 } else if x.isNaN { x = 0 }
            if y > 1 { y = 1 } else if y < -1 { y = -1 } else if y.isNaN { y = 0 }
            xs[w] = x
            ys[w] = y
            w += 1
            if w == scopeCapacity { w = 0 }
        }
        scopeWrite = w
        scopeFilled = min(scopeCapacity, scopeFilled + (n - start))
    }

    // MARK: Reading

    public func read() -> StereoReading {
        var reading = StereoReading(
            correlation: 0,
            balance: 0,
            width: 0,
            bandCorrelation: [Float](repeating: 0, count: bandCount),
            bandBalance: [Float](repeating: 0, count: bandCount),
            bandActive: [Bool](repeating: false, count: bandCount),
            scopePoints: []
        )
        reading.scopePoints = gatherScopePoints()

        guard accNorm > 0 else { return reading }
        let broadbandMeanSquare = (accLL + accRR) / (2 * accNorm)
        guard broadbandMeanSquare.isFinite, broadbandMeanSquare >= Self.silenceMeanSquare else { return reading }

        reading.correlation = Self.correlation(ll: accLL, rr: accRR, lr: accLR)
        reading.balance = Self.balance(ll: accLL, rr: accRR)
        reading.width = width(midSum: accMM, sideSum: accSS)

        let bandFloor = max(Self.silenceMeanSquare, broadbandMeanSquare * Self.bandRelativeFloor)
        for band in 0..<bandCount {
            let meanSquare = (bandLL[band] + bandRR[band]) / (2 * accNorm)
            guard meanSquare.isFinite, meanSquare >= bandFloor else { continue }
            reading.bandActive[band] = true
            reading.bandCorrelation[band] = Self.correlation(ll: bandLL[band], rr: bandRR[band], lr: bandLR[band])
            reading.bandBalance[band] = Self.balance(ll: bandLL[band], rr: bandRR[band])
        }
        return reading
    }

    /// Side RMS over mid RMS. 0 for mono, 1 for a hard-panned channel, clamped at `maxWidth`.
    private func width(midSum: Double, sideSum: Double) -> Float {
        let mid = max(midSum, 0)
        let side = max(sideSum, 0)
        guard side > 0 else { return 0 }
        guard mid > 0 else { return Self.maxWidth }
        let ratio = (side / mid).squareRoot()
        guard ratio.isFinite else { return Self.maxWidth }
        return Float(min(ratio, Double(Self.maxWidth)))
    }

    private static func correlation(ll: Double, rr: Double, lr: Double) -> Float {
        let denominator = (max(ll, 0) * max(rr, 0)).squareRoot()
        guard denominator > 0, denominator.isFinite else { return 0 }
        let c = lr / denominator
        guard c.isFinite else { return 0 }
        return Float(min(max(c, -1), 1))
    }

    private static func balance(ll: Double, rr: Double) -> Float {
        let l = max(ll, 0).squareRoot()
        let r = max(rr, 0).squareRoot()
        let sum = l + r
        guard sum > 0, sum.isFinite else { return 0 }
        let b = (r - l) / sum
        guard b.isFinite else { return 0 }
        return Float(min(max(b, -1), 1))
    }

    /// The newest `scopePointCount` points, newest last, spread evenly over the stored
    /// `scopeSeconds` of audio.
    private func gatherScopePoints() -> [SIMD2<Float>] {
        guard let xs = scopeX, let ys = scopeY else { return [] }
        let window = scopeFilled
        let wanted = min(max(scopePointCount, 0), window)
        guard wanted > 0 else { return [] }

        let oldest = (scopeWrite - window + scopeCapacity) % scopeCapacity
        var points = [SIMD2<Float>]()
        points.reserveCapacity(wanted)
        if wanted == 1 {
            let index = (oldest + window - 1) % scopeCapacity
            points.append(SIMD2<Float>(xs[index], ys[index]))
            return points
        }
        let span = Double(window - 1)
        let steps = Double(wanted - 1)
        for i in 0..<wanted {
            let position = Int((Double(i) * span / steps).rounded())
            let index = (oldest + position) % scopeCapacity
            points.append(SIMD2<Float>(xs[index], ys[index]))
        }
        return points
    }
}
