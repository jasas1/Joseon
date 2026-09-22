import Foundation

/// ITU-R BS.1770-4 / EBU R128 loudness, EBU Tech 3342 loudness range, and
/// inter-sample true peak.
///
/// Design notes
/// - K-weighting coefficients are derived from the analogue prototype at the
///   live sample rate (`KWeighting`), never read from the 48 kHz table.
/// - Audio is cut into 100 ms blocks. Every finished block updates the 400 ms
///   momentary window, the 3 s short-term window and the 300 ms RMS window, and
///   files one value into each histogram. Memory is therefore constant: an
///   eight-hour listen costs the same as one second.
/// - `process` allocates nothing after the first call at a given sample rate.
///   Every buffer is sized in `init` or in `configure(sampleRate:)`.
/// - One thread only. There is no locking; `AnalysisEngine` calls `process` and
///   `read` from its own analysis queue.
public final class LoudnessMeter: LoudnessMetering {

    // MARK: - Standard constants

    /// Gating block hop. BS.1770 overlaps 400 ms blocks by 75 %.
    static let blockSeconds = 0.1
    static let momentaryBlocks = 4      // 400 ms
    static let shortTermBlocks = 30     // 3 s
    static let rmsBlocks = 3            // 300 ms
    /// BS.1770 loudness offset, -0.691 dB.
    static let loudnessOffset = -0.691
    static let absoluteGateLUFS = -70.0
    static let integratedRelativeGateLU = -10.0
    static let rangeRelativeGateLU = -20.0
    static let rangeLowPercentile = 0.10
    static let rangeHighPercentile = 0.95
    /// Channel weights for stereo, BS.1770 Table 3.
    static let channelWeight = 1.0
    /// True-peak display ballistics. The hold is a sliding maximum over this many
    /// seconds, so a repeating peak keeps the meter up and two channels carrying the
    /// same peak read the same number (see `PeakHoldBallistics`).
    static let truePeakHoldSeconds = 1.5
    static let truePeakFallDBPerSecond = 20.0
    /// A sample at or above this magnitude counts as full scale.
    static let clipThreshold: Float = 0.9999
    /// How many full-scale samples in a row make one clip event.
    static let clipRunLength = 3
    /// Lowest number any dB field reports. Matches `LoudnessReading.silenceLUFS`.
    static let floorDB = Double(LoudnessReading.silenceLUFS)

    // MARK: - Configuration

    private var sampleRate: Double = 0
    private var blockSamples: Int = 0

    // MARK: - Filters and peak detectors

    private var weightingLeft = KWeightingFilter()
    private var weightingRight = KWeightingFilter()
    private let truePeakLeft = TruePeakDetector()
    private let truePeakRight = TruePeakDetector()

    // MARK: - Current 100 ms block

    private var blockFill = 0
    private var blockSumWeightedLeft = 0.0
    private var blockSumWeightedRight = 0.0
    private var blockSumRawLeft = 0.0
    private var blockSumRawRight = 0.0

    // MARK: - Ring of finished blocks (mean square per block, per channel)

    private let ringCapacity = LoudnessMeter.shortTermBlocks
    private var ringWeightedLeft: [Double]
    private var ringWeightedRight: [Double]
    private var ringRawLeft: [Double]
    private var ringRawRight: [Double]
    private var ringWrite = 0
    private var ringFilled = 0
    /// Blocks finished since the windows last started. Only whole 400 ms and 3 s
    /// windows feed the histograms and the maxima.
    private var blocksSinceReset = 0

    // MARK: - Distributions and running extremes

    private var integratedHistogram = LoudnessHistogram()
    private var rangeHistogram = LoudnessHistogram()
    private var momentaryMax = LoudnessMeter.floorDB
    private var shortTermMax = LoudnessMeter.floorDB
    private var statsDirty = true
    private var cachedIntegrated = LoudnessMeter.floorDB
    private var cachedRange = 0.0

    // MARK: - True peak state

    private let truePeakBallisticsLeft = PeakHoldBallistics(
        holdSeconds: LoudnessMeter.truePeakHoldSeconds,
        fallDBPerSecond: LoudnessMeter.truePeakFallDBPerSecond,
        floorDB: LoudnessMeter.floorDB)
    private let truePeakBallisticsRight = PeakHoldBallistics(
        holdSeconds: LoudnessMeter.truePeakHoldSeconds,
        fallDBPerSecond: LoudnessMeter.truePeakFallDBPerSecond,
        floorDB: LoudnessMeter.floorDB)
    private var truePeakMax = LoudnessMeter.floorDB

    // MARK: - Clipping and timing

    private var clipRunLeft = 0
    private var clipRunRight = 0
    private var clipCount = 0
    private var measuredSeconds = 0.0

    // MARK: - Init

    public init() {
        ringWeightedLeft = [Double](repeating: 0, count: LoudnessMeter.shortTermBlocks)
        ringWeightedRight = [Double](repeating: 0, count: LoudnessMeter.shortTermBlocks)
        ringRawLeft = [Double](repeating: 0, count: LoudnessMeter.shortTermBlocks)
        ringRawRight = [Double](repeating: 0, count: LoudnessMeter.shortTermBlocks)
    }

    // MARK: - LoudnessMetering

    public func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, sampleRate rate: Double) {
        guard count > 0, rate.isFinite, rate > 0 else { return }
        if rate != sampleRate { configure(sampleRate: rate) }

        var done = 0
        while done < count {
            let chunk = min(blockSamples - blockFill, count - done)
            consume(left + done, right + done, chunk)
            done += chunk
            if blockFill >= blockSamples { finishBlock() }
        }
        measuredSeconds += Double(count) / sampleRate
    }

    public func read() -> LoudnessReading {
        var r = LoudnessReading()
        r.momentaryLUFS = Float(loudness(overBlocks: Self.momentaryBlocks))
        r.shortTermLUFS = Float(loudness(overBlocks: Self.shortTermBlocks))
        refreshStatsIfNeeded()
        r.integratedLUFS = Float(cachedIntegrated)
        r.momentaryMaxLUFS = Float(momentaryMax)
        r.shortTermMaxLUFS = Float(shortTermMax)
        r.loudnessRangeLU = Float(cachedRange)
        r.truePeakLeftDBTP = Float(truePeakBallisticsLeft.display)
        r.truePeakRightDBTP = Float(truePeakBallisticsRight.display)
        r.truePeakMaxDBTP = Float(truePeakMax)
        r.rmsLeftDB = Float(rmsDB(ringRawLeft))
        r.rmsRightDB = Float(rmsDB(ringRawRight))

        let currentTruePeak = max(truePeakBallisticsLeft.display, truePeakBallisticsRight.display)
        r.plrDB = (cachedIntegrated > Self.floorDB && truePeakMax > Self.floorDB)
            ? Float(truePeakMax - cachedIntegrated) : 0
        let shortTerm = Double(r.shortTermLUFS)
        r.psrDB = (shortTerm > Self.floorDB && currentTruePeak > Self.floorDB)
            ? Float(currentTruePeak - shortTerm) : 0

        r.clipCount = clipCount
        r.measuredSeconds = measuredSeconds
        r.isIntegratedValid = cachedIntegrated > Self.floorDB
        return r
    }

    public func reset() {
        weightingLeft.clear()
        weightingRight.clear()
        truePeakLeft.clear()
        truePeakRight.clear()
        clearWindows()
        integratedHistogram.removeAll()
        rangeHistogram.removeAll()
        momentaryMax = Self.floorDB
        shortTermMax = Self.floorDB
        truePeakMax = Self.floorDB
        clipCount = 0
        clipRunLeft = 0
        clipRunRight = 0
        measuredSeconds = 0
        cachedIntegrated = Self.floorDB
        cachedRange = 0
        statsDirty = false
    }

    // MARK: - Configuration

    /// A new sample rate means new filter coefficients and a new block length,
    /// so the sliding windows and filter states start again. The integrated
    /// histograms, the maxima and the clip count survive: they belong to the
    /// measurement, not to the window, and only `reset()` clears them.
    private func configure(sampleRate rate: Double) {
        sampleRate = rate
        blockSamples = max(1, Int((rate * Self.blockSeconds).rounded()))
        weightingLeft.configure(sampleRate: rate)
        weightingRight.configure(sampleRate: rate)
        let factor = TruePeakDetector.factor(forSampleRate: rate)
        truePeakLeft.configure(factor: factor)
        truePeakRight.configure(factor: factor)
        clearWindows()
    }

    private func clearWindows() {
        blockFill = 0
        blockSumWeightedLeft = 0; blockSumWeightedRight = 0
        blockSumRawLeft = 0; blockSumRawRight = 0
        for i in 0..<ringCapacity {
            ringWeightedLeft[i] = 0; ringWeightedRight[i] = 0
            ringRawLeft[i] = 0; ringRawRight[i] = 0
        }
        ringWrite = 0
        ringFilled = 0
        blocksSinceReset = 0
        truePeakBallisticsLeft.clear()
        truePeakBallisticsRight.clear()
    }

    // MARK: - Hot path

    /// Filter, square, peak-detect and clip-detect `n` frames. `n` never crosses
    /// a 100 ms block boundary, so the true-peak ballistics step is bounded.
    private func consume(_ l: UnsafePointer<Float>, _ r: UnsafePointer<Float>, _ n: Int) {
        blockSumWeightedLeft += weightingLeft.sumOfSquares(l, count: n)
        blockSumWeightedRight += weightingRight.sumOfSquares(r, count: n)

        var sumRawL = 0.0, sumRawR = 0.0
        var runL = clipRunLeft, runR = clipRunRight
        var clips = 0
        let threshold = Self.clipThreshold
        let runLength = Self.clipRunLength
        for i in 0..<n {
            let xl = Double(l[i]), xr = Double(r[i])
            sumRawL += xl * xl
            sumRawR += xr * xr
            if abs(l[i]) >= threshold {
                runL += 1
                if runL == runLength { clips += 1 }
            } else {
                runL = 0
            }
            if abs(r[i]) >= threshold {
                runR += 1
                if runR == runLength { clips += 1 }
            } else {
                runR = 0
            }
        }
        blockSumRawLeft += sumRawL
        blockSumRawRight += sumRawR
        clipRunLeft = runL
        clipRunRight = runR
        clipCount += clips

        let peakL = truePeakLeft.maxAbs(l, count: n)
        let peakR = truePeakRight.maxAbs(r, count: n)

        blockFill += n
        let dt = Double(n) / sampleRate
        let levelL = Self.decibels(amplitude: Double(peakL))
        let levelR = Self.decibels(amplitude: Double(peakR))
        if levelL > truePeakMax { truePeakMax = levelL }
        if levelR > truePeakMax { truePeakMax = levelR }
        // About 1.5 s hold, then about 20 dB/s fall, like a hardware peak meter. The
        // two channels run the same arithmetic on their own levels, so identical input
        // gives identical readings.
        truePeakBallisticsLeft.update(level: levelL, dt: dt)
        truePeakBallisticsRight.update(level: levelR, dt: dt)
    }

    private func finishBlock() {
        let inverse = 1.0 / Double(blockSamples)
        ringWeightedLeft[ringWrite] = blockSumWeightedLeft * inverse
        ringWeightedRight[ringWrite] = blockSumWeightedRight * inverse
        ringRawLeft[ringWrite] = blockSumRawLeft * inverse
        ringRawRight[ringWrite] = blockSumRawRight * inverse
        ringWrite = (ringWrite + 1) % ringCapacity
        if ringFilled < ringCapacity { ringFilled += 1 }
        blockFill = 0
        blockSumWeightedLeft = 0; blockSumWeightedRight = 0
        blockSumRawLeft = 0; blockSumRawRight = 0

        if blocksSinceReset < Int.max { blocksSinceReset += 1 }

        // Only whole windows count towards the gated measures and the maxima.
        if blocksSinceReset >= Self.momentaryBlocks {
            let power = weightedPower(overBlocks: Self.momentaryBlocks)
            let level = Self.loudness(fromPower: power)
            if level > momentaryMax { momentaryMax = level }
            integratedHistogram.add(loudness: level, power: power)
            statsDirty = true
        }
        if blocksSinceReset >= Self.shortTermBlocks {
            let power = weightedPower(overBlocks: Self.shortTermBlocks)
            let level = Self.loudness(fromPower: power)
            if level > shortTermMax { shortTermMax = level }
            rangeHistogram.add(loudness: level, power: power)
            statsDirty = true
        }
    }

    // MARK: - Window maths

    /// BS.1770 weighted channel sum over the newest `blocks` finished blocks.
    private func weightedPower(overBlocks blocks: Int) -> Double {
        let n = min(blocks, ringFilled)
        guard n > 0 else { return 0 }
        var left = 0.0, right = 0.0
        var index = ringWrite
        for _ in 0..<n {
            index = index == 0 ? ringCapacity - 1 : index - 1
            left += ringWeightedLeft[index]
            right += ringWeightedRight[index]
        }
        let inverse = 1.0 / Double(n)
        return Self.channelWeight * left * inverse + Self.channelWeight * right * inverse
    }

    private func loudness(overBlocks blocks: Int) -> Double {
        Self.loudness(fromPower: weightedPower(overBlocks: blocks))
    }

    private func rmsDB(_ ring: [Double]) -> Double {
        let n = min(Self.rmsBlocks, ringFilled)
        guard n > 0 else { return Self.floorDB }
        var sum = 0.0
        var index = ringWrite
        for _ in 0..<n {
            index = index == 0 ? ringCapacity - 1 : index - 1
            sum += ring[index]
        }
        return Self.decibels(power: sum / Double(n))
    }

    // MARK: - Gated measures

    private func refreshStatsIfNeeded() {
        guard statsDirty else { return }
        statsDirty = false
        cachedIntegrated = computeIntegrated()
        cachedRange = computeRange()
    }

    /// BS.1770-4 gated loudness: absolute gate at -70 LUFS, then a relative gate
    /// 10 LU below the mean of what survived.
    private func computeIntegrated() -> Double {
        guard integratedHistogram.totalCount > 0 else { return Self.floorDB }
        let mean = integratedHistogram.totalPower / Double(integratedHistogram.totalCount)
        let threshold = Self.loudness(fromPower: mean) + Self.integratedRelativeGateLU
        let gate = integratedHistogram.gated(aboveLUFS: threshold)
        guard gate.count > 0 else { return Self.floorDB }
        return Self.loudness(fromPower: gate.power / Double(gate.count))
    }

    /// EBU Tech 3342 loudness range: short-term values, absolute gate at
    /// -70 LUFS, relative gate 20 LU down, then the 10th to 95th percentile.
    private func computeRange() -> Double {
        guard rangeHistogram.totalCount > 0 else { return 0 }
        let mean = rangeHistogram.totalPower / Double(rangeHistogram.totalCount)
        let threshold = Self.loudness(fromPower: mean) + Self.rangeRelativeGateLU
        guard let low = rangeHistogram.percentile(Self.rangeLowPercentile, aboveLUFS: threshold),
              let high = rangeHistogram.percentile(Self.rangeHighPercentile, aboveLUFS: threshold)
        else { return 0 }
        return max(0, high - low)
    }

    // MARK: - Scalar helpers

    /// BS.1770 loudness from the weighted channel power sum. Silence reads the
    /// floor, never NaN and never -inf.
    static func loudness(fromPower power: Double) -> Double {
        guard power > 0, power.isFinite else { return floorDB }
        let value = loudnessOffset + 10.0 * log10(power)
        return value.isFinite ? max(value, floorDB) : floorDB
    }

    static func decibels(power: Double) -> Double {
        guard power > 0, power.isFinite else { return floorDB }
        let value = 10.0 * log10(power)
        return value.isFinite ? max(value, floorDB) : floorDB
    }

    static func decibels(amplitude: Double) -> Double {
        guard amplitude > 0, amplitude.isFinite else { return floorDB }
        let value = 20.0 * log10(amplitude)
        return value.isFinite ? max(value, floorDB) : floorDB
    }
}
