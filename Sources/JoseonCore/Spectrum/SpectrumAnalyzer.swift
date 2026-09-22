import Accelerate
import Foundation

/// Multi-resolution FFT spectrum analyzer.
///
/// Three Hann-windowed FFTs run in parallel over one shared history ring:
///
/// | band | window at 48 kHz | duration | hop     | refresh |
/// |------|------------------|----------|---------|---------|
/// | low  | 32768            | 683 ms   | 5461    | 8.8 Hz  |
/// | mid  | 8192             | 171 ms   | 1024    | 46.9 Hz |
/// | high | 2048             | 43 ms    | 768     | 62.5 Hz |
///
/// The hop rates are not the same on purpose: frames are read at 60 Hz, so transforming
/// faster than that is work nobody sees, and a 683 ms window cannot say anything new every
/// 16 ms anyway.
///
/// Sizes scale with the sample rate (nearest power of two) so the window *durations* stay
/// the same from 44.1 kHz to 192 kHz.
///
/// ## Two crossfades, not one
///
/// Blending the three curves is not enough on its own to hide the change of FFT size. A
/// tone reads the same level from any of the three, but broadband content does not: the
/// coarser FFT collects noise over four times the bandwidth, so it sits 6 dB higher. Blend
/// two curves that disagree by 6 dB and the seam is still there, just smeared.
///
/// So there are two separate transitions:
///
/// - **Blend**, smoothstep in log frequency over half an octave either side of 200 Hz and
///   2 kHz. This is which FFT the display bin comes from. The blend is in the power domain and
///   comes *after* the release smoothing, which runs per resolution, so the three curves in
///   `SpectrumReading.midLayers` blended with their weights are exactly `mid`. Inside a
///   crossfade both resolutions draw a tone with the same lobe (see `SpectrumResolution`).
/// - **Noise bandwidth ramp**, one and a half octaves either side of 100 Hz and 1 kHz.
///   Each resolution widens its per-bin power sum to hit a common target bandwidth, so the
///   two curves being blended agree on noise as well as on tones.
///
/// The ramp is wider than the blend and sits an octave lower, so the target bandwidth has
/// already reached what the coarser FFT can deliver before that FFT starts contributing.
/// What is left is a smooth 12 dB rise in the displayed noise floor from 25 Hz to 12 kHz,
/// spread across six octaves: the analyzer really does look at more bandwidth as frequency
/// goes up, which is the point of a multi-resolution design.
///
/// Levels are peak-amplitude calibrated: a full-scale sine reads 0 dBFS at any frequency
/// and any FFT size. See `SpectrumResolution` for the window and calibration maths.
///
/// Threading: `process` and `read` run on one thread (the analysis thread). No locking.
/// Allocation: everything is allocated in `configure`, which runs on the first call and
/// again only when the sample rate or the display grid changes. `process` is allocation
/// free in the steady state (checked by `SpectrumPerformanceTests`).
public final class SpectrumAnalyzer: SpectrumAnalyzing, TopPeaksProviding, ThirdOctaveProviding {
    public var settings: SpectrumSettings

    // Window lengths at 48 kHz. Scaled to other rates by nearest power of two.
    private static let lowSizeAt48k = 32_768
    private static let midSizeAt48k = 8_192
    private static let highSizeAt48k = 2_048
    private static let referenceRate = 48_000.0

    // Crossover centres and half-width of the crossfade, in octaves.
    private static let lowMidHz: Float = 200
    private static let midHighHz: Float = 2_000
    private static let crossfadeOctaves: Float = 0.5
    /// Half-width of the noise-bandwidth ramp, in octaves. Wider than the blend on purpose.
    private static let bandwidthOctaves: Float = 1.5

    private static let floorDB = SpectrumReading.floorDB
    private static let floorPower: Float = 1e-12      // floorDB as power
    private var binsPerOctave: Float = 91
    private static let ch = SpectrumResolution.channelCount

    // MARK: - Configured state

    private var low: SpectrumResolution?
    private var mid: SpectrumResolution?
    private var high: SpectrumResolution?

    private var configuredRate: Double = 0
    private var configuredBins = 0
    private var configuredMinHz: Float = 0
    private var configuredMaxHz: Float = 0
    private var configuredTilt: Float = .nan

    private var historyL = FloatScratch(1)
    private var historyR = FloatScratch(1)
    private var historyCapacity = 1
    private var historyMask = 0
    private var samplesWritten = 0

    private var weightLow = FloatScratch(1)
    private var weightMid = FloatScratch(1)
    private var weightHigh = FloatScratch(1)
    private var tiltDB = FloatScratch(1)
    private var frequencies = [Float]()

    /// Per resolution and channel, after attack/release: `(layer * ch + channel) * bins`.
    /// The release runs per resolution and the blend comes after it, so `SpectrumReading.midLayers`
    /// blended with their weights *is* `mid`, not an approximation of it.
    private var layerSmooth = FloatScratch(1)
    private var smooth = FloatScratch(1)     // ch * bins: the blend of `layerSmooth`, untilted dB
    private var targetMidPower = FloatScratch(1) // bins: blend of the unsmoothed mid curves, as power
    private var layerFirst = [Int](repeating: 0, count: 3)
    private var layerLast = [Int](repeating: -1, count: 3)
    private var layerWeights = [[Float]](repeating: [], count: 3)
    private var layerLatency = [Float](repeating: 0, count: 3)
    /// Runs of display bins that come from one resolution (`b < 0`) or from a blend of two.
    private struct Segment { var lo: Int; var hi: Int; var a: Int; var b: Int }
    private var segments = [Segment]()
    private var widthLimitOctaves = FloatScratch(1) // bins: widest -3 dB width that still counts as a tone
    private var smoothedAverage = FloatScratch(1)   // bins: scratch for `updateLowestStrong`
    private var peakHoldDB = FloatScratch(1) // bins
    private var averagePower = FloatScratch(1) // bins, running power mean since reset
    /// Seconds that went into `averagePower`, per entry of `segments`, since `reset`. Every display
    /// bin of a segment is fed by the same resolution(s), so they share one count: it is the
    /// averaging denominator of each of those bins. A segment counts time only while all the
    /// resolutions that feed it have data. One clock for all bins (`averageSeconds`) made the bins
    /// of the 32768-point FFT average the floor for the 0.8 s before its first transform, and the
    /// long-term line of a steady 30 Hz tone then read 5 dB low after 1.1 s (4 dB and less later).
    /// Sized in `configure`, zeroed in place in `reset`: nothing allocates in `process`.
    private var segmentSeconds = [Double]()
    private var work1 = FloatScratch(1)      // bins
    private var work2 = FloatScratch(1)      // bins

    /// IEC 61260 third-octave band levels (`ThirdOctaveProviding`), off the same power spectra.
    /// Internal rather than private so the tests can read the band-to-FFT map out of it.
    let thirdOctaveBank = ThirdOctaveBank()

    private var bandStartBin = [Int](repeating: 0, count: 8)
    private var bandEndBin = [Int](repeating: 0, count: 8)
    private let bandValues = FloatScratch(8)
    private static let histogramBuckets = 141
    private let histogram = Int32Scratch(SpectrumAnalyzer.histogramBuckets)

    private var audioTime: Double = 0
    private var lastSmoothTime: Double = 0
    /// The measurement clock since `reset` (`lowestStrongHz` runs on it). Not the averaging
    /// denominator: that is `segmentSeconds`.
    private var averageSeconds: Double = 0
    private var currentPeak = PeakReading()
    private var currentBands = BandEnergy()
    private var medianMidDB: Float = SpectrumReading.floorDB
    private var medianStale = true
    private var peaksStale = true

    // `lowestStrongHz` state.
    private var lowestCandidateHz: Float = 0
    private var lowestCandidateSince: Double = 0
    private var lowestPublishedHz: Float = 0

    /// `TopPeaksProviding` storage. Filled in `process`, turned into values in `read`.
    static let maxTopPeaks = 5
    /// Two peaks closer than this are the same tone as far as the list is concerned.
    static let topPeakSeparationOctaves: Float = 1.0 / 6
    /// Seconds of measurement before `lowestStrongHz` answers at all.
    static let lowestStrongWarmupSeconds = 3.0
    /// How far below the loudest part of the long-term average still counts as strong content.
    static let lowestStrongRangeDB: Float = 12
    /// The answer has to hold still (within 1/12 octave) this long before it is published.
    static let lowestStrongStableSeconds = 1.0
    /// Never below this: under 20 Hz a number would be about the analyzer, not about the music.
    static let lowestStrongMinHz: Float = 20
    /// A tonal peak stands this far over the lowest point on each side within `tonalReachOctaves`...
    static let tonalProminenceDB: Float = 8
    static let tonalReachOctaves: Float = 1.0 / 6
    /// ...and is narrower than this at -3 dB (or than 1.3 times the analyzer's own lobe, where
    /// that is wider: below about 40 Hz a pure tone measures 1/11 octave in a 683 ms window).
    static let tonalWidthOctaves: Float = 1.0 / 12
    private let peakHz = FloatScratch(SpectrumAnalyzer.maxTopPeaks)
    private let peakLevel = FloatScratch(SpectrumAnalyzer.maxTopPeaks)
    private let peakBin = Int32Scratch(SpectrumAnalyzer.maxTopPeaks)
    private var peakCount = 0
    /// The first entry of the list is `peak` itself and `peak` is not tonal (no note name).
    private var firstPeakIsBroad = false

    public init(settings: SpectrumSettings = SpectrumSettings()) {
        self.settings = settings
    }

    // MARK: - SpectrumAnalyzing

    public func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard count > 0, sampleRate > 0 else { return }
        configureIfNeeded(sampleRate: sampleRate)
        guard let low, let mid, let high else { return }

        appendHistory(left: left, right: right, count: count)
        samplesWritten += count
        audioTime = Double(samplesWritten) / configuredRate

        let lowHopped = run(low)
        let midHopped = run(mid)
        let highHopped = run(high)
        if lowHopped || midHopped || highHopped { compositeMidPower() }

        // Third-octave bands: a weighted power sum over the bins of the transform that just ran,
        // then the fast integrator stepped by this block's own duration. Both are cheap; nothing
        // here allocates and no extra FFT runs.
        if lowHopped { thirdOctaveBank.capture(layer: 0, from: low) }
        if midHopped { thirdOctaveBank.capture(layer: 1, from: mid) }
        if highHopped { thirdOctaveBank.capture(layer: 2, from: high) }
        thirdOctaveBank.advance(seconds: Double(count) / configuredRate)

        accumulateAverage(seconds: Double(count) / configuredRate)
        if lowHopped {
            updateBands(using: low)
            updateLowestStrong()
            medianStale = true
        }
        peaksStale = true
    }

    @inline(__always)
    private func run(_ res: SpectrumResolution) -> Bool {
        guard let end = res.dueHop(samplesWritten: samplesWritten, historyCapacity: historyCapacity) else { return false }
        res.transform(historyL: historyL.p, historyR: historyR.p, capacity: historyCapacity, mask: historyMask, end: end)
        return true
    }

    public func read() -> (spectrum: SpectrumReading, peak: PeakReading, bands: BandEnergy) {
        configureIfNeeded(sampleRate: configuredRate > 0 ? configuredRate : 48_000)
        let n = configuredBins
        guard n >= 2 else {
            return (SpectrumReading.silent(binCount: 2), PeakReading(), BandEnergy())
        }

        applySmoothing()
        findPeaks()

        var out = SpectrumReading(
            frequencies: frequencies,
            left: shaped(smooth.p + SpectrumResolution.chLeft * n, n),
            right: shaped(smooth.p + SpectrumResolution.chRight * n, n),
            mid: shaped(smooth.p + SpectrumResolution.chMid * n, n),
            side: shaped(smooth.p + SpectrumResolution.chSide * n, n),
            peakHold: shaped(peakHoldDB.p, n),
            average: shaped(averageDB(n), n)
        )
        // The three mid curves before the blend, for the spectrogram: it delays each one by its
        // own latency and blends after that. Same calibration, release and tilt as `mid`, and
        // `10 log10(sum(weight * 10^(level / 10)))` over the layers gives `mid` back.
        out.midLayers = (0..<3).map { layer in
            SpectrumLayer(levelsDB: shaped(layerSmooth.p + (layer * Self.ch + SpectrumResolution.chMid) * n, n),
                          weights: layerWeights[layer], latencySeconds: layerLatency[layer])
        }
        return (out, currentPeak, currentBands)
    }

    // MARK: - TopPeaksProviding

    /// The strongest tonal peaks of mid, strongest first, at most five.
    ///
    /// Every entry is a local maximum **of the mid display curve**, in the smoothing state the
    /// display uses, so a marker drawn at (`frequencyHz`, `levelDB`) sits on the curve. Offset
    /// rule: `levelDB` is the untilted level; with a display tilt the curve is at
    /// `levelDB + tiltDBPerOctave * log2(frequencyHz / 1000)`. The frequency is refined inside
    /// its display bin from the long FFT, which is what makes the cents meaningful.
    ///
    /// A peak is tonal when it is over the gate the note readout uses (above -80 dBFS, 10 dB over
    /// the median of the curve), stands `tonalProminenceDB` over the lowest point on each side
    /// within `tonalReachOctaves`, and is narrower than `tonalWidthOctaves` at -3 dB. A kick
    /// drum's hump is a maximum too, but it is half an octave wide: it gets no note.
    ///
    /// When the list is not empty its first entry is `peak`. If `peak` itself is a broad maximum,
    /// that first entry has an empty note name and the tonal peaks follow it.
    public var topPeaks: [PeakReading] {
        if peaksStale, configuredBins >= 2 { applySmoothing(); findPeaks() }
        guard peakCount > 0 else { return [] }
        var out = [PeakReading]()
        out.reserveCapacity(peakCount)
        for i in 0..<peakCount {
            if i == 0, firstPeakIsBroad { out.append(currentPeak); continue }
            let hz = peakHz.p[i]
            let (name, cents) = NoteNamer.note(forHz: hz)
            out.append(PeakReading(frequencyHz: hz, levelDB: max(peakLevel.p[i], Self.floorDB), noteName: name, cents: cents))
        }
        return out
    }

    // MARK: - ThirdOctaveProviding

    /// RMS level per IEC 61260 third-octave band, per channel, in dBFS RMS where a full-scale
    /// sine reads -3.01. Time weighting is "fast" (125 ms) on band power; see `ThirdOctaveBank`
    /// for the normalisation, the band-to-FFT map and the real integration time of each band.
    ///
    /// `nil` until every resolution that serves a band has transformed once. Bands whose centre
    /// is above 0.9 of Nyquist read the floor.
    public var thirdOctave: ThirdOctaveReading? { thirdOctaveBank.reading() }

    /// Lowest frequency that carries sustained content, in whole Hz, never under 20 Hz.
    ///
    /// The lowest frequency at or over 20 Hz where the long-term average of mid, smoothed over a
    /// third of an octave, is within 12 dB of its maximum. The *average*, not the live curve,
    /// because the question is what the track has at the bottom, not what one frame caught; a
    /// third of an octave, so one narrow spike of hum does not decide it. 0 until three seconds
    /// have been measured and the answer has held still for one second, and 0 on silence.
    public var lowestStrongHz: Float { lowestPublishedHz }

    /// Starts a new measurement: the long-term average and the peak hold.
    /// The live spectrum and the FFT history are kept, so the display does not blank.
    public func reset() {
        averagePower.zero()
        averageSeconds = 0
        for s in segmentSeconds.indices { segmentSeconds[s] = 0 }
        peakHoldDB.fill(Self.floorDB)
        currentPeak = PeakReading()
        currentBands = BandEnergy()
        peakCount = 0
        firstPeakIsBroad = false
        peaksStale = false
        lowestCandidateHz = 0
        lowestCandidateSince = 0
        lowestPublishedHz = 0
        thirdOctaveBank.reset()
    }

    // MARK: - Configuration

    private func configureIfNeeded(sampleRate: Double) {
        let bins = max(2, min(settings.displayBins, 1 << 14))
        let minHz = max(settings.minHz, 0.1)
        let maxHz = max(settings.maxHz, minHz * 2)
        let structural = sampleRate != configuredRate
            || bins != configuredBins
            || minHz != configuredMinHz
            || maxHz != configuredMaxHz
        if structural {
            configure(sampleRate: sampleRate, bins: bins, minHz: minHz, maxHz: maxHz)
        }
        if settings.tiltDBPerOctave != configuredTilt {
            configuredTilt = settings.tiltDBPerOctave
            for i in 0..<configuredBins {
                tiltDB.p[i] = configuredTilt * log2(frequencies[i] / 1_000)
            }
        }
    }

    private func configure(sampleRate: Double, bins: Int, minHz: Float, maxHz: Float) {
        configuredRate = sampleRate
        configuredBins = bins
        configuredMinHz = minHz
        configuredMaxHz = maxHz
        configuredTilt = .nan

        let scale = sampleRate / Self.referenceRate
        let lowSize = joseonNearestPow2(Double(Self.lowSizeAt48k) * scale, min: 4_096, max: 1 << 17)
        let midSize = joseonNearestPow2(Double(Self.midSizeAt48k) * scale, min: 1_024, max: 1 << 15)
        let highSize = joseonNearestPow2(Double(Self.highSizeAt48k) * scale, min: 256, max: 1 << 13)

        // Hop rates differ on purpose. The display is read at 60 Hz, so a resolution that
        // transforms faster than that is doing work nobody sees, and a resolution whose band
        // cannot change that fast does not need 60 Hz either. Lows: 683 ms of window, so a
        // 6th-of-a-window hop is 8.8 Hz, which is already faster than the band moves and is
        // what drives the peak readout. Highs: 62.5 Hz, just over the frame rate.
        low = SpectrumResolution(size: lowSize, hop: lowSize / 6, sampleRate: sampleRate)
        mid = SpectrumResolution(size: midSize, hop: midSize / 8, sampleRate: sampleRate)
        high = SpectrumResolution(size: highSize, hop: highSize * 3 / 8, sampleRate: sampleRate)
        // The peak readout and the band energies come from the long FFT across the whole
        // band, so its mid channel is the one resolution/channel pair that needs every bin.
        low?.fullSpectrumChannel = SpectrumResolution.chMid

        // The ring has to hold the longest window plus one hop of slack.
        historyCapacity = joseonNextPow2(lowSize * 2)
        historyMask = historyCapacity - 1
        historyL = FloatScratch(historyCapacity)
        historyR = FloatScratch(historyCapacity)
        samplesWritten = 0
        audioTime = 0
        lastSmoothTime = 0

        // Log-spaced display grid, identical to SpectrumReading.silent.
        let ratio = maxHz / minHz
        let step = pow(ratio, 1 / Float(bins - 1))
        frequencies = (0..<bins).map { minHz * pow(ratio, Float($0) / Float(bins - 1)) }

        weightLow = FloatScratch(bins)
        weightMid = FloatScratch(bins)
        weightHigh = FloatScratch(bins)
        tiltDB = FloatScratch(bins)
        for i in 0..<bins {
            let f = frequencies[i]
            let wl = 1 - Self.smoothstepOctaves(f, centre: Self.lowMidHz)
            let wh = Self.smoothstepOctaves(f, centre: Self.midHighHz)
            weightLow.p[i] = wl
            weightHigh.p[i] = wh
            weightMid.p[i] = max(0, 1 - wl - wh)
        }

        // The bandwidth ramp is wider than the blend and sits an octave lower, so by the time
        // a coarser resolution starts contributing, the target bandwidth has already reached
        // what that resolution can deliver, and the 4x bandwidth change is spread over 1.5
        // octaves instead of landing on top of the crossfade.
        let log2DfLow = log2(low?.df ?? 1), log2DfMid = log2(mid?.df ?? 1), log2DfHigh = log2(high?.df ?? 1)
        let rampWidth = Self.bandwidthOctaves
        let bandwidth: (Float) -> Float = { f in
            let sLow = Self.smoothstepOctaves(f, centre: Self.lowMidHz / 2, halfWidth: rampWidth)
            let sHigh = Self.smoothstepOctaves(f, centre: Self.midHighHz / 2, halfWidth: rampWidth)
            let log2Df = (1 - sLow) * log2DfLow + sLow * (1 - sHigh) * log2DfMid + sHigh * log2DfHigh
            // Three bins, not the five of the Hann main lobe: tonal peaks are drawn from their
            // own curve now, so the noise curve is free to keep the finest bandwidth the FFT
            // really has. At 20 Hz that is 4.4 Hz instead of 7.3 Hz, which is the difference
            // between a curve that follows the data and the flat shelf round 2 showed.
            return 3 * exp2(log2Df)
        }

        // Bin width of the lobe a tone is drawn with: the FFT's own outside the crossfades, and
        // inside one the same for both resolutions, moving with the blend weight.
        let toneBin: (Float) -> Float = { f in
            let sLow = Self.smoothstepOctaves(f, centre: Self.lowMidHz)
            let sHigh = Self.smoothstepOctaves(f, centre: Self.midHighHz)
            return exp2((1 - sLow) * log2DfLow + sLow * (1 - sHigh) * log2DfMid + sHigh * log2DfHigh)
        }

        frequencies.withUnsafeBufferPointer { freq in
            low?.updateMap(displayBins: bins, frequencies: freq.baseAddress!, binRatio: step, weight: weightLow.p, targetBandwidthHz: bandwidth, toneBinHz: toneBin)
            mid?.updateMap(displayBins: bins, frequencies: freq.baseAddress!, binRatio: step, weight: weightMid.p, targetBandwidthHz: bandwidth, toneBinHz: toneBin)
            high?.updateMap(displayBins: bins, frequencies: freq.baseAddress!, binRatio: step, weight: weightHigh.p, targetBandwidthHz: bandwidth, toneBinHz: toneBin)
        }

        layerSmooth = FloatScratch(3 * Self.ch * bins)
        layerSmooth.fill(Self.floorDB)
        targetMidPower = FloatScratch(bins)
        targetMidPower.fill(Self.floorPower)
        smoothedAverage = FloatScratch(bins)
        smooth = FloatScratch(Self.ch * bins)
        smooth.fill(Self.floorDB)

        // Which resolution, or which two, each display bin comes from.
        let weights = [weightLow, weightMid, weightHigh]
        segments.removeAll()
        for layer in 0..<3 {
            layerFirst[layer] = bins; layerLast[layer] = -1
            layerWeights[layer] = (0..<bins).map { weights[layer].p[$0] }
        }
        layerLatency = [low, mid, high].map { Float(Double($0?.size ?? 0) / 2 / sampleRate) }
        for i in 0..<bins {
            var order = [0, 1, 2].filter { weights[$0].p[i] > 0 }
            order.sort { weights[$0].p[i] > weights[$1].p[i] }
            let a = order.first ?? 1
            let b = order.count > 1 ? order[1] : -1
            let pair = b >= 0 ? (min(a, b), max(a, b)) : (a, -1)
            for layer in order.prefix(2) { layerFirst[layer] = min(layerFirst[layer], i); layerLast[layer] = max(layerLast[layer], i) }
            if let last = segments.last, last.a == pair.0, last.b == pair.1 {
                segments[segments.count - 1].hi = i
            } else {
                segments.append(Segment(lo: i, hi: i, a: pair.0, b: pair.1))
            }
        }

        // -3 dB width of a Hann lobe is 1.44 bins; the display adds one display bin to it.
        widthLimitOctaves = FloatScratch(bins)
        for i in 0..<bins {
            let f = frequencies[i]
            let own = 1.44 * toneBin(f) / (f * Float(log(2.0))) + log2(step)
            widthLimitOctaves.p[i] = max(Self.tonalWidthOctaves, 1.3 * own)
        }
        binsPerOctave = 1 / log2(step)
        medianStale = true
        peaksStale = false
        peakCount = 0
        firstPeakIsBroad = false
        lowestCandidateHz = 0
        lowestCandidateSince = 0
        lowestPublishedHz = 0
        peakHoldDB = FloatScratch(bins)
        peakHoldDB.fill(Self.floorDB)
        averagePower = FloatScratch(bins)
        averageSeconds = 0
        segmentSeconds = [Double](repeating: 0, count: segments.count)
        work1 = FloatScratch(bins)
        work2 = FloatScratch(bins)
        currentPeak = PeakReading()
        currentBands = BandEnergy()

        if let low { computeBandBins(for: low) }

        // Third-octave map. It is built after `updateMap`, because it widens the left/right power
        // range each resolution computes and that has to sit on top of the display's own range.
        let ranges = thirdOctaveBank.configure(sampleRate: sampleRate, resolutions: [low, mid, high])
        low?.extraPowerRange = ranges[0]
        mid?.extraPowerRange = ranges[1]
        high?.extraPowerRange = ranges[2]
    }

    /// 0 below `centre` minus `halfWidth` octaves, 1 above it, smooth in between.
    private static func smoothstepOctaves(_ f: Float, centre: Float, halfWidth: Float = crossfadeOctaves) -> Float {
        let t = (log2(f / centre) + halfWidth) / (2 * halfWidth)
        let c = min(max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }

    private func computeBandBins(for res: SpectrumResolution) {
        let edges = BandEnergy.edgesHz
        let nyquistBin = res.half - 1
        for b in 0..<8 {
            let k0 = max(Int((edges[b] / res.df).rounded(.up)), 1)
            let k1 = min(Int((edges[b + 1] / res.df).rounded(.up)) - 1, nyquistBin)
            bandStartBin[b] = k0
            bandEndBin[b] = k1
        }
    }

    // MARK: - History

    private func appendHistory(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        var src = 0
        var n = count
        if n > historyCapacity { src = n - historyCapacity; n = historyCapacity }
        var pos = (samplesWritten + src) & historyMask
        var remaining = n
        var offset = src
        while remaining > 0 {
            let chunk = min(remaining, historyCapacity - pos)
            (historyL.p + pos).update(from: left + offset, count: chunk)
            (historyR.p + pos).update(from: right + offset, count: chunk)
            pos = (pos + chunk) & historyMask
            offset += chunk
            remaining -= chunk
        }
    }

    // MARK: - Composite, smoothing, output

    /// Blend one channel of the three resolutions in the power domain.
    ///
    /// Outside the two crossfades a display bin comes from one resolution and is copied; inside
    /// one it is `wa * Pa + wb * Pb`. The two curves agree on noise (the bandwidth ramp sees to
    /// that) and on stationary tones, so there the domain does not matter; where they disagree -
    /// a transient the short window has and the long one has not yet - power is what adds.
    private func blend(_ sources: (UnsafePointer<Float>, UnsafePointer<Float>, UnsafePointer<Float>),
                       into dst: UnsafeMutablePointer<Float>, asPower: Bool) {
        var toExponent = Float(log(10.0) / 10.0)
        var ten: Float = 10, zero: Float = 0
        var floorPower = Self.floorPower
        let weights = (weightLow.p, weightMid.p, weightHigh.p)
        @inline(__always) func source(_ layer: Int) -> UnsafePointer<Float> { layer == 0 ? sources.0 : (layer == 1 ? sources.1 : sources.2) }
        @inline(__always) func weight(_ layer: Int) -> UnsafeMutablePointer<Float> { layer == 0 ? weights.0 : (layer == 1 ? weights.1 : weights.2) }
        for segment in segments {
            let count = segment.hi - segment.lo + 1
            let vn = vDSP_Length(count)
            var n32 = Int32(count)
            let out = dst + segment.lo
            if segment.b < 0 {
                if asPower {
                    vDSP_vsmul(source(segment.a) + segment.lo, 1, &toExponent, out, 1, vn)
                    vvexpf(out, out, &n32)
                    vDSP_vthr(out, 1, &floorPower, out, 1, vn)
                } else {
                    out.update(from: source(segment.a) + segment.lo, count: count)
                }
                continue
            }
            vDSP_vsmul(source(segment.a) + segment.lo, 1, &toExponent, work1.p, 1, vn)
            vvexpf(work1.p, work1.p, &n32)
            vDSP_vmul(work1.p, 1, weight(segment.a) + segment.lo, 1, work1.p, 1, vn)
            vDSP_vsmul(source(segment.b) + segment.lo, 1, &toExponent, work2.p, 1, vn)
            vvexpf(work2.p, work2.p, &n32)
            vDSP_vma(work2.p, 1, weight(segment.b) + segment.lo, 1, work1.p, 1, out, 1, vn)
            vDSP_vthr(out, 1, &floorPower, out, 1, vn)
            if !asPower {
                vvlog10f(out, out, &n32)
                vDSP_vsmsa(out, 1, &ten, &zero, out, 1, vn)
            }
        }
    }

    /// The unsmoothed mid curve as power, for the long-term average.
    private func compositeMidPower() {
        guard let low, let mid, let high else { return }
        let offset = SpectrumResolution.chMid * configuredBins
        blend((UnsafePointer(low.displayDB.p + offset), UnsafePointer(mid.displayDB.p + offset), UnsafePointer(high.displayDB.p + offset)),
              into: targetMidPower.p, asPower: true)
    }

    /// Instant attack, exponential release, per resolution, then the blend. `releaseSeconds` is
    /// the time constant of a one-pole in the dB domain, so a 60 dB drop closes 63% of the
    /// remaining gap per time constant. Driven by the audio clock, so it is deterministic in tests.
    private func applySmoothing() {
        guard let low, let mid, let high else { return }
        let n = configuredBins
        let vn = vDSP_Length(n)
        let dt = max(audioTime - lastSmoothTime, 0)
        lastSmoothTime = audioTime
        let tau = settings.releaseSeconds
        var coefficient: Float = (tau > 0 && dt > 0) ? exp(Float(-dt) / tau) : (dt > 0 ? 0 : 1)
        var rest = 1 - coefficient
        var floorValue = Self.floorDB
        let resolutions = [low, mid, high]

        for layer in 0..<3 {
            let first = layerFirst[layer], last = layerLast[layer]
            guard last >= first else { continue }
            let count = vDSP_Length(last - first + 1)
            for c in 0..<Self.ch {
                // Hold the target at the display floor. Without this a digital-silence target of
                // about -300 dB would make the release look instant on the way down.
                vDSP_vthr(resolutions[layer].displayDB.p + c * n + first, 1, &floorValue, work1.p, 1, count)
                let state = layerSmooth.p + (layer * Self.ch + c) * n + first
                // state = max(target, coefficient * state + (1 - coefficient) * target)
                vDSP_vsmsma(state, 1, &coefficient, work1.p, 1, &rest, state, 1, count)
                vDSP_vmax(state, 1, work1.p, 1, state, 1, count)
            }
        }
        for c in 0..<Self.ch {
            blend((UnsafePointer(layerSmooth.p + (0 * Self.ch + c) * n),
                   UnsafePointer(layerSmooth.p + (1 * Self.ch + c) * n),
                   UnsafePointer(layerSmooth.p + (2 * Self.ch + c) * n)),
                  into: smooth.p + c * n, asPower: false)
        }

        // Peak hold of mid: linear dB ramp down, jumps up to the displayed curve.
        var fall = -settings.peakDecayDBPerSecond * Float(dt)
        vDSP_vsadd(peakHoldDB.p, 1, &fall, peakHoldDB.p, 1, vn)
        vDSP_vmax(peakHoldDB.p, 1, smooth.p + SpectrumResolution.chMid * n, 1, peakHoldDB.p, 1, vn)
    }

    /// Running power mean of the untilted mid curve since `reset`, per display bin over the time
    /// that bin has been measured (see `segmentSeconds`).
    private func accumulateAverage(seconds: Double) {
        guard seconds > 0, let low, let mid, let high else { return }
        averageSeconds += seconds
        let ready = (low.hasData, mid.hasData, high.hasData)
        @inline(__always) func hasData(_ layer: Int) -> Bool { layer == 0 ? ready.0 : (layer == 1 ? ready.1 : ready.2) }
        for s in 0..<segments.count {
            let segment = segments[s]
            // Before its FFT has run, `targetMidPower` holds the floor there: not a measurement.
            guard hasData(segment.a), segment.b < 0 || hasData(segment.b) else { continue }
            segmentSeconds[s] += seconds
            var w = Float(seconds / segmentSeconds[s])
            let vn = vDSP_Length(segment.hi - segment.lo + 1)
            let mean = averagePower.p + segment.lo
            vDSP_vsub(mean, 1, targetMidPower.p + segment.lo, 1, work2.p, 1, vn)  // work2 = new - mean
            vDSP_vsma(work2.p, 1, &w, mean, 1, mean, 1, vn)
        }
    }

    private func averageDB(_ n: Int) -> UnsafeMutablePointer<Float> {
        guard averageSeconds > 0 else {
            work2.fill(Self.floorDB)
            return work2.p
        }
        var count = Int32(n)
        var eps: Float = 1e-30
        var ten: Float = 10, zero: Float = 0
        vDSP_vsadd(averagePower.p, 1, &eps, work2.p, 1, vDSP_Length(n))
        vvlog10f(work2.p, work2.p, &count)
        vDSP_vsmsa(work2.p, 1, &ten, &zero, work2.p, 1, vDSP_Length(n))
        // Nothing measured yet in these bins: the floor, not the logarithm of an empty mean.
        for s in 0..<segments.count where segmentSeconds[s] <= 0 {
            let segment = segments[s]
            guard segment.lo < n else { continue }
            (work2.p + segment.lo).update(repeating: Self.floorDB, count: min(segment.hi, n - 1) - segment.lo + 1)
        }
        return work2.p
    }

    /// Add the tilt, clamp to the floor, hand back a fresh array for the frame.
    private func shaped(_ src: UnsafePointer<Float>, _ n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n)
        var floorValue = Self.floorDB
        out.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            vDSP_vadd(src, 1, tiltDB.p, 1, p, 1, vDSP_Length(n))
            vDSP_vthr(p, 1, &floorValue, p, 1, vDSP_Length(n))
        }
        return out
    }

    // MARK: - Peak and band energy

    /// Band energy comes from the longest FFT: it has the finest bins at every frequency, and
    /// it is a slow meter that does not need a 60 Hz refresh.
    private func updateBands(using res: SpectrumResolution) {
        let pw = res.power.p + SpectrumResolution.chMid * res.half
        let maxBin = res.half - 1
        // Plain power sums over the FFT bins of each band, same calibration as the display, so a
        // full-scale sine inside a band reads 0 dB. Taken from the mid channel, so the numbers
        // agree with `SpectrumReading.mid`.
        for b in 0..<8 {
            let s = bandStartBin[b], e = min(bandEndBin[b], maxBin)
            guard e >= s else { bandValues.p[b] = Self.floorDB; continue }
            var sum: Float = 0
            vDSP_sve(pw + s, 1, &sum, vDSP_Length(e - s + 1))
            bandValues.p[b] = max(10 * log10(max(sum, 1e-30)), Self.floorDB)
        }
        currentBands = BandEnergy(
            subBass: bandValues.p[0], bass: bandValues.p[1], lowMid: bandValues.p[2], mid: bandValues.p[3],
            upperMid: bandValues.p[4], presence: bandValues.p[5], brilliance: bandValues.p[6], air: bandValues.p[7]
        )
    }

    // MARK: - Peaks

    /// `peak` and the top-peaks list, from the mid display curve as it stands after smoothing.
    ///
    /// Round 3 took both from the long FFT's 5-bin sums. On broadband content a 5-bin sum reads
    /// 2.2 dB over the 3-bin curve, so the markers floated over it, and any local maximum over
    /// the gate counted, so the kick's hump was named F1, A#1 and D#2.
    private func findPeaks() {
        peaksStale = false
        peakCount = 0
        firstPeakIsBroad = false
        let n = configuredBins
        guard n >= 3, samplesWritten > 0 else { currentPeak = PeakReading(); return }
        let s = UnsafePointer(smooth.p + SpectrumResolution.chMid * n)

        var top: Float = 0
        var topIndex: vDSP_Length = 0
        vDSP_maxvi(s, 1, &top, &topIndex, vDSP_Length(n))
        guard top > Self.floorDB + 0.5 else { currentPeak = PeakReading(); return }

        if medianStale { medianMidDB = medianDB(s, n); medianStale = false }
        let gate = max(medianMidDB + 10, -80)

        let g = Int(topIndex)
        let topHz = refinedFrequency(bin: g)
        let topIsTonal = top >= gate && g > 0 && g < n - 1 && isTonal(s, g, n)
        var name = ""
        var cents: Float = 0
        if topIsTonal { (name, cents) = NoteNamer.note(forHz: topHz) }
        currentPeak = PeakReading(frequencyHz: topHz, levelDB: max(top, Self.floorDB), noteName: name, cents: cents)

        // Every other tonal local maximum over the gate, strongest first, a sixth of an octave apart.
        let ratio = exp2(Self.topPeakSeparationOctaves)
        var i = 1
        while i < n - 1 {
            let v = s[i]
            guard v >= gate, v > s[i - 1], v >= s[i + 1], isTonal(s, i, n) else { i += 1; continue }
            insertPeak(bin: i, level: v, ratio: ratio)
            i += 2
        }
        for k in 0..<peakCount { peakHz.p[k] = refinedFrequency(bin: Int(peakBin.p[k])) }

        // The contract: a list that is not empty starts with `peak`.
        if peakCount > 0, !topIsTonal {
            let count = min(peakCount, Self.maxTopPeaks - 1)
            var k = count
            while k > 0 { peakHz.p[k] = peakHz.p[k - 1]; peakLevel.p[k] = peakLevel.p[k - 1]; peakBin.p[k] = peakBin.p[k - 1]; k -= 1 }
            peakHz.p[0] = topHz; peakLevel.p[0] = top; peakBin.p[0] = Int32(g)
            peakCount = count + 1
            firstPeakIsBroad = true
        }
    }

    /// Prominence and width of the local maximum at display bin `i`.
    private func isTonal(_ s: UnsafePointer<Float>, _ i: Int, _ n: Int) -> Bool {
        let top = s[i]
        let reach = max(Int((Self.tonalReachOctaves * binsPerOctave).rounded()), 2)
        var leftMin = top, rightMin = top
        var j = i - 1
        while j >= max(i - reach, 0) { leftMin = min(leftMin, s[j]); j -= 1 }
        j = i + 1
        while j <= min(i + reach, n - 1) { rightMin = min(rightMin, s[j]); j += 1 }
        guard top - max(leftMin, rightMin) >= Self.tonalProminenceDB else { return false }

        // -3 dB width, with the crossing interpolated between display bins.
        let edge = top - 3
        var l = i
        while l > 0, s[l] > edge, i - l <= reach { l -= 1 }
        var r = i
        while r < n - 1, s[r] > edge, r - i <= reach { r += 1 }
        guard s[l] <= edge, s[r] <= edge else { return false }
        let xl = Float(l) + (edge - s[l]) / max(s[l + 1] - s[l], 1e-6)
        let xr = Float(r) - (edge - s[r]) / max(s[r - 1] - s[r], 1e-6)
        return (xr - xl) / binsPerOctave < widthLimitOctaves.p[i]
    }

    private func insertPeak(bin: Int, level: Float, ratio: Float) {
        let hz = frequencies[bin]
        // Drop it if a stronger entry already owns this part of the spectrum; otherwise take
        // over the weaker entry that does.
        var replace = -1
        for k in 0..<peakCount {
            let other = peakHz.p[k]
            let r = hz > other ? hz / other : other / hz
            if r < ratio {
                if peakLevel.p[k] >= level { return }
                replace = k
                break
            }
        }
        if replace >= 0 {
            for k in replace..<(peakCount - 1) { peakHz.p[k] = peakHz.p[k + 1]; peakLevel.p[k] = peakLevel.p[k + 1]; peakBin.p[k] = peakBin.p[k + 1] }
            peakCount -= 1
        } else if peakCount == Self.maxTopPeaks, level <= peakLevel.p[peakCount - 1] {
            return
        }
        var slot = min(peakCount, Self.maxTopPeaks - 1)
        while slot > 0, peakLevel.p[slot - 1] < level {
            peakHz.p[slot] = peakHz.p[slot - 1]; peakLevel.p[slot] = peakLevel.p[slot - 1]; peakBin.p[slot] = peakBin.p[slot - 1]
            slot -= 1
        }
        peakHz.p[slot] = hz
        peakLevel.p[slot] = level
        peakBin.p[slot] = Int32(bin)
        peakCount = min(peakCount + 1, Self.maxTopPeaks)
    }

    /// The frequency of the peak in display bin `i`, to a fraction of a bin of the long FFT.
    ///
    /// A display bin is 0.76% wide, 13 cents: too coarse for a tuner. The long FFT has the finest
    /// bins at every frequency, so the strongest of its bins inside the display bin is found and
    /// interpolated (the Hann main lobe is close to a parabola in dB, which lands inside a cent).
    /// The answer never leaves the display bin by more than one bin, so the marker stays on the
    /// peak it belongs to even while the long window is still catching up with a change.
    private func refinedFrequency(bin i: Int) -> Float {
        let f = frequencies[i]
        guard let res = low, res.hasData else { return f }
        let pw = res.power.p + SpectrumResolution.chMid * res.half
        let maxBin = res.half - 2
        let step = exp2(1 / binsPerOctave)
        let kLo = max(Int((f / step / res.df).rounded(.down)) - 1, 2)
        let kHi = min(Int((f * step / res.df).rounded(.up)) + 1, maxBin)
        guard kHi >= kLo else { return f }
        var value: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(pw + kLo, 1, &value, &index, vDSP_Length(kHi - kLo + 1))
        let k = kLo + Int(index)
        guard value > 0, k >= 1, k <= maxBin else { return f }
        let y0 = 10 * log10(max(pw[k - 1], 1e-30))
        let y1 = 10 * log10(max(pw[k], 1e-30))
        let y2 = 10 * log10(max(pw[k + 1], 1e-30))
        let denominator = y0 - 2 * y1 + y2
        var delta: Float = 0
        if abs(denominator) > 1e-9 { delta = min(max(0.5 * (y0 - y2) / denominator, -0.5), 0.5) }
        let hz = (Float(k) + delta) * res.df
        return abs(log2(hz / f)) * binsPerOctave <= 1.5 ? hz : f
    }

    // MARK: - Lowest strong content

    /// Runs when the long FFT has hopped (8.8 Hz): that is as fast as the bottom of the average moves.
    private func updateLowestStrong() {
        let n = configuredBins
        guard n >= 2, averageSeconds > 0 else { return }
        guard let first = frequencies.firstIndex(where: { $0 >= Self.lowestStrongMinHz }) else { return }

        // A third of an octave, as a running power mean over the display bins.
        let half = max(Int((binsPerOctave / 6).rounded()), 1)
        let p = UnsafePointer(averagePower.p)
        let out = smoothedAverage.p
        var sum: Float = 0
        var lo = first, hi = first - 1
        var best: Float = 0
        for i in first..<n {
            let wantLo = max(i - half, first), wantHi = min(i + half, n - 1)
            while hi < wantHi { hi += 1; sum += p[hi] }
            while lo < wantLo { sum -= p[lo]; lo += 1 }
            let mean = max(sum, 0) / Float(hi - lo + 1)
            out[i] = mean
            if mean > best { best = mean }
        }
        // Silence, or nothing but the display floor: no answer.
        guard best > Self.floorPower * 100 else { publishLowest(0); return }

        let threshold = best * pow(10, -Self.lowestStrongRangeDB / 10)
        var found = -1
        for i in first..<n where out[i] >= threshold { found = i; break }
        guard found >= 0 else { publishLowest(0); return }
        // The smoothing spreads a tone a sixth of an octave down. Inside that reach, the lowest
        // bin of the unsmoothed average that is itself over the threshold is where the content is.
        for i in found...min(found + half, n - 1) where p[i] >= threshold { found = i; break }
        publishLowest(max(frequencies[found].rounded(), Self.lowestStrongMinHz))
    }

    private func publishLowest(_ hz: Float) {
        guard hz > 0 else {
            lowestCandidateHz = 0
            lowestPublishedHz = 0
            return
        }
        let moved = lowestCandidateHz <= 0 || abs(log2(hz / lowestCandidateHz)) > 1.0 / 12
        if moved {
            lowestCandidateHz = hz
            lowestCandidateSince = averageSeconds
        }
        let stable = averageSeconds - lowestCandidateSince >= Self.lowestStrongStableSeconds
        if stable, averageSeconds >= Self.lowestStrongWarmupSeconds {
            lowestPublishedHz = hz
            lowestCandidateHz = hz   // follow a slow drift instead of calling it a move
        }
    }

    /// Median by histogram: one pass, no allocation, 1 dB buckets. Good enough for a 10 dB gate.
    private func medianDB(_ values: UnsafePointer<Float>, _ n: Int) -> Float {
        guard n > 0 else { return Self.floorDB }
        let buckets = Self.histogramBuckets      // -120...+20 dB in 1 dB steps
        for b in 0..<buckets { histogram.p[b] = 0 }
        for i in 0..<n {
            let b = min(max(Int((values[i] + 120).rounded()), 0), buckets - 1)
            histogram.p[b] += 1
        }
        var seen: Int32 = 0
        for b in 0..<buckets {
            seen += histogram.p[b]
            if Int(seen) * 2 >= n { return Float(b) - 120 }
        }
        return Self.floorDB
    }
}
