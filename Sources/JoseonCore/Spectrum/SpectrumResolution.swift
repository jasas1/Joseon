import Accelerate
import Foundation

/// One FFT resolution of the multi-resolution spectrum analyzer.
///
/// It owns the window, the vDSP FFT setup, the per-channel power spectra and the
/// map from FFT bins to display bins. The analyzer owns three of these (lows, mids,
/// highs) and crossfades their display output.
///
/// ## Window choice: periodic Hann
///
/// Hann, not Blackman-Harris. Two reasons, both measurable:
///
/// 1. **Resolution.** Hann's main lobe is 4 bins wide null to null; Blackman-Harris
///    (4-term) is 8. The brief asks for 30 Hz and 40 Hz to show as two peaks with a
///    real dip between them. At 48 kHz the 32768-point low FFT has 1.465 Hz bins, so
///    those tones sit 6.8 bins apart. Hann leaves them cleanly separated;
///    Blackman-Harris main lobes (+-4 bins) would nearly touch.
/// 2. **Level accuracy for free.** A Hann-windowed tone puts *all* of its energy in the
///    3 bins around it when on-bin, and in 5 bins for any sub-bin offset. So summing
///    power over +-2 bins and normalising by `4 / (N * sum(w^2))` gives the tone's peak
///    amplitude with under 0.01 dB of scalloping ripple, at any frequency and any FFT
///    size. No flat-top window and no zero padding needed.
///
/// The price is Hann's -31 dB first sidelobe. A Blackman-Harris switch would cost the
/// 30/40 Hz separation, so the sidelobes stay and are documented as a known limit.
///
/// ## Two curves, added in the power domain
///
/// A sliding power sum written to every bin gives the right level for noise, but it also
/// turns a pure tone into a flat-topped table as wide as the sum. So each transform builds
/// **two** curves and the display takes the louder of them:
///
/// 1. **Noise curve.** Tonal main lobes are lifted out of the power spectrum and replaced
///    by the local noise level, then a bandwidth-matched sliding sum runs over the result.
///    No table under a tone, and the bandwidth is a *continuous* function of frequency
///    (see `updateMap`), so the displayed noise floor has no steps.
/// 2. **Tone lobes.** Every tonal peak is measured (frequency to a fraction of a bin, level
///    from the calibrated 5-bin sum less the noise under it) and then *drawn*: the Hann main
///    lobe of the analyzer's resolution bandwidth at that frequency, evaluated at the display
///    bins themselves and added to the noise curve in the power domain. The lobe falls
///    smoothly to nothing at its first null, so it meets the noise curve wherever the noise
///    happens to be, with no edge of its own.
///
/// Round 2 combined the two by `max` on tone-only values and every partial ended in a step.
/// Round 3 added the raw FFT bins of the lobe over +-4 bins, and the defect stayed, because
/// the cause was somewhere else (measured in round 4, demo signal, 8192-point FFT):
/// a noise bin three bins from a real tone is a local maximum whose 5-bin sum still holds
/// the real tone's -6 dB skirt bin, so it read 20 dB over its own context and was **taken
/// for a tone**. It was then drawn as one: a -47 dB peak 17.6 Hz either side of the -39 dB
/// partial at 392 Hz, ending in a 10 dB step at 416 Hz where the false lobe stopped.
/// `detectTones` now requires the peak bin to carry its share of the 5-bin sum, which a real
/// Hann peak always does (48% or more) and a bin beside one never does (3% in that case).
final class SpectrumResolution {
    /// Channel order inside every per-channel buffer: left, right, mid, side.
    static let channelCount = 4
    static let chLeft = 0, chRight = 1, chMid = 2, chSide = 3

    /// Bins with no FFT data (above Nyquist, or a display bin this resolution does not serve).
    static let floorDB: Float = SpectrumReading.floorDB

    let size: Int          // FFT length in samples
    let half: Int          // usable spectrum length; bin k is k * df Hz for k in 1...half-1
    let hop: Int           // samples between transforms
    let df: Float          // Hz per FFT bin

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: FloatScratch      // size
    private let work: FloatScratch        // size
    private let re: FloatScratch          // channelCount * half
    private let im: FloatScratch          // channelCount * half
    /// Calibrated power per FFT bin: a full-scale sine's main lobe sums to 1.0 here.
    let power: FloatScratch               // channelCount * half

    // One-channel scratch. Each channel is built, mapped and finished before the next
    // starts, so these do not need a per-channel copy.
    private let detoned: FloatScratch     // half, power with the tonal main lobes taken out
    private let noiseP: FloatScratch      // half, bandwidth-matched sliding sum of `detoned`
    private let noiseDB: FloatScratch     // half, 10*log10(noiseP)
    private let toneBin: Int32Scratch     // shared tonal peak bins of this transform
    private let toneFlag: Int32Scratch    // per FFT bin: any channel found a tone here
    private let tonePower: FloatScratch   // per tone, this channel: calibrated power less the noise under it
    private let toneOffset: FloatScratch  // per tone, this channel: position of the tone in bins from its peak bin
    private var toneCount = 0
    /// Per channel and FFT bin: the power spectrum averaged over the last transforms, the memory
    /// of the tonal gate. See `toneAverageOnThreshold`.
    private let toneAverage: FloatScratch // channelCount * half
    /// Transforms in `toneAverage` so far (0: none yet). The averaged gate waits for `toneAverageWarmup`.
    private var toneAverageCount = 0
    /// Per FFT bin: the tone flag of the previous transform.
    private let tonePrevious: Int32Scratch // half
    /// Per FFT bin: what the averaged gate decided when it last ran (see `toneAverageEvery`).
    private let toneAverageFlag: Int32Scratch // half
    /// One-channel scratch for the peak search: `peakRise[k] = min(p[k] - p[k+1], p[k] - p[k-1])`,
    /// positive at a local maximum. Three vDSP calls over the range, then the search reads one
    /// value per bin instead of three and takes one branch that is nearly always the same way.
    private let peakRise: FloatScratch      // half
    private let peakRiseWork: FloatScratch  // half
    /// One-channel scratch: sliding sums of the spectrum being searched, `sum3[j] = p[j] + p[j+1]
    /// + p[j+2]` and `sum5[k] = p[k-2] + ... + p[k+2]`, from four vDSP adds. A candidate's tone
    /// power is then one read and each context block one read instead of three.
    private let sum3: FloatScratch          // half
    private let sum5: FloatScratch          // half
    /// The averaged gate runs every this many transforms. Its spectrum moves with a time constant
    /// of 8 transforms, so deciding on every transform is work that finds what the last decision
    /// found: at most about 24 decisions a second (3rd transform of the 2048-point FFT at 48 kHz,
    /// 2nd of the 8192-point, every one of the 32768-point). Between decisions the last one holds.
    /// Measured: the scan over every bin of every channel cost 27 us per 800-frame block on the
    /// demo signal, a fifth of the whole `process` budget; this takes two thirds of that back.
    let toneAverageEvery: Int

    /// A peak is tonal when its 5-bin power is this many times the 5-bin noise power beside it (14 dB).
    ///
    /// Both the test and the fill use the *median* of four block means. Round 2 tested against the
    /// quietest of the four, which reads about 2.5 dB low on plain noise, so the gate was really
    /// 7.5 dB: one frame of a 2048-point FFT on pink noise then passed a dozen false peaks, and the
    /// display drew a comb of pointed spikes over what is a smooth noise floor. An unbiased estimate
    /// and 13 dB leave the demo signal's own 6.2 kHz tone as the only spike above 5 kHz (measured).
    /// A tone that misses the gate stays on the noise curve, where the base sum is only three bins
    /// wide, so it still reads as a narrow bump rather than a table.
    private static let toneThreshold: Float = 25
    /// The second gate, on the power spectrum averaged over the last transforms (`toneAverageAlpha`),
    /// against the raw second-smallest block mean with no `contextGain` (averaged blocks do not
    /// read low the way one transform's do). 7.4 dB on, and 6 dB to stay on where the bin, or one
    /// beside it, was tonal in the previous transform.
    ///
    /// The 14 dB gate above is the fast path: it decides from one transform, so a loud tone is a
    /// tone at once, and it needs 14 dB because a single 2048-point transform of pink noise has
    /// candidates 15 dB over their neighbourhood (measured: the loudest false candidate per
    /// transform is 11 dB at the median, 18 dB at the worst of 800). A quiet steady tone does
    /// not reach it: 3.1 kHz at 9 dB over pink noise reads 6.9 dB at the 1st percentile, 11.9 dB
    /// at the median, 14.8 dB at the 90th, so it passed in 2% of transforms and the spectrogram
    /// drew it as dashes (pointed in 87 of 500 columns). Averaging 8 transforms takes the
    /// variance out of both sides: the same tone reads 8.4 dB at the 1st percentile and 9.4 dB
    /// at the median, and the loudest false candidate per transform on pink noise reads 2.4 dB
    /// at the median and 5.8 dB at the worst of 1 500 (2048-, 8192- and 32768-point). A hold of a
    /// few transforms on the 14 dB gate could not do this: at 2% entry, no hold short enough to
    /// release a stopped tone keeps the line whole.
    ///
    /// A tone that stops is released as the average decays: about 9 transforms (150 ms for the
    /// 2048-point FFT, 1 s for the 32768-point), and it cannot renew itself, since nothing but
    /// the spectrum feeds the average. A false candidate that passed the 14 dB gate is held only
    /// while it lifts the average over 6 dB: two transforms at most, measured.
    private static let toneAverageOnThreshold: Float = 5.5
    private static let toneAverageOffThreshold: Float = 4
    private static let toneAverageAlpha: Float = 0.125
    /// Transforms before the averaged gate decides: two time constants, so the average no longer
    /// has the variance of the one transform it started from.
    private static let toneAverageWarmup = 16
    /// A channel draws a shared tone as a lobe only where it carries it: its own 5-bin power over
    /// its own noise passes the 14 dB gate in this transform, or 3.5 dB on its averaged spectrum.
    /// A channel without the tone keeps its noise curve there. It used to draw a lobe of
    /// `max(sum - 5 * fill, 0)`, which on plain noise is half-rectified noise, so it was positive
    /// half the time; the instant-attack release smoothing then held those excursions, and the
    /// channel showed a bump 3 to 5 dB over its own floor at a tone it does not have (measured
    /// on the demo's left-only 3.1 kHz sparkle: the right channel read 4.8 dB over its flanks and
    /// the vectorscope placed the tone at -0.85 instead of hard left). On the averaged spectrum a
    /// channel without the tone reads about 0 dB there, and 3.5 dB is under what the quietest
    /// tone the gate accepts reads in the channel that carries it (6 dB, measured on the 3.1 kHz
    /// fixture with the tone in both channels).
    private static let toneChannelThreshold: Float = 2.25
    /// Power under which a transform is digital silence: the tonal memory is cleared, so a tone
    /// that comes back after a gap has to pass a gate again.
    private static let toneSilencePower: Float = 1e-20
    /// 3-bin blocks each side that make the noise estimate, starting 3 bins from the peak (outside the main lobe).
    ///
    /// Three, and the estimate is the *second smallest* of the six. Round 3 used the median of
    /// four, which a chord defeats: the partials of the demo chord sit 8 bins apart in the
    /// 8192-point FFT, so a partial in the middle has a neighbour inside a block on each side, the
    /// median lands on a contaminated block, and the partial is not seen as a tone at all
    /// (measured: 147 Hz and 247 Hz never, 196 Hz every other frame). Such a partial went down
    /// the noise path and came out as a 1/6-octave bell, which is why round 3 drew bells at
    /// 200-300 Hz and needles above. Four of the six blocks may now hold something else.
    private static let toneContextBlocks = 3
    /// The second smallest of six block means reads low on plain noise: 0.525 of the true level,
    /// measured on Hann-windowed white noise over 280 000 candidate peaks. Taken out again here,
    /// so the gate and the fill are unbiased. False tones on plain noise at the 14 dB gate: under
    /// 0.2 per 10 000 candidates in that run.
    private static let contextGain: Float = 1 / 0.525
    /// Half-width of the main lobe that is lifted out of the noise curve.
    private static let lobeHalf = 2
    /// A Hann peak bin holds 48% to 67% of its own 5-bin sum. A bin that holds less than this is not
    /// the top of a lobe: it is a bump on the skirt of a louder neighbour.
    private static let tonePeakShare: Float = 0.3

    /// Hann main lobe in dB, `lobeSteps` entries per bin off centre, from 0 to the first null at 2.
    private static let lobeSteps = 64
    private let lobeDB = FloatScratch(2 * SpectrumResolution.lobeSteps + 2)
    /// `10 * log10(1 + 10^(-x / 10))` for x = 0 ... 40 dB: adds two levels in the power domain
    /// without leaving dB. `sumSteps` entries per dB.
    private static let sumSteps = 8
    private static let sumRangeDB = 40
    private let sumDB = FloatScratch(SpectrumResolution.sumSteps * SpectrumResolution.sumRangeDB + 2)
    /// Per FFT bin: the bin width of the drawn lobe as a multiple of this FFT's own bin width.
    /// Outside the crossfades that is 1: the lobe this FFT measured. Inside a crossfade the two
    /// resolutions that are being blended draw the *same* lobe, whose width moves from the finer
    /// FFT's to the coarser one's in step with the blend weights. Otherwise a tone inside a
    /// crossfade is a needle standing on a bell, which is a ledge the signal does not have.
    private var lobeScale = FloatScratch(1)

    /// Level in dB per display bin, per channel. `floorDB` where this resolution has nothing.
    private(set) var displayDB = FloatScratch(1)
    private(set) var displayBins = 0

    // MARK: Display map
    //
    // Three contiguous index ranges, in this order, all inside `firstServed...lastServed`:
    //   fade   : the display bin sits below the first usable FFT bin -> fade towards the floor
    //   interp : fewer than two FFT bins in the display bin -> interpolate
    //   mean   : two or more FFT bins -> power mean over them
    // The test that separates interp from mean is continuous in frequency, so the ranges
    // really are contiguous and each pass can run over a plain index range.
    private var mapStart = Int32Scratch(1)   // mean range: first FFT bin of the display bin
    private var mapEnd = Int32Scratch(1)     // mean range: last FFT bin
    private var mapPos = FloatScratch(1)     // interp range: fractional FFT-bin position
    private var fadeLo = 1, fadeHi = 0
    private var interpLo = 1, interpHi = 0
    private var meanLo = 1, meanHi = 0
    private var servedLo = 1, servedHi = 0
    private var smoothWork = FloatScratch(1)
    /// Half-width of the noise smoothing kernel in display bins (see `smoothNoise`).
    private var smoothHalfWidth = 0
    /// Width of the noise smoothing kernel, in octaves from end to end.
    static let smoothOctaves: Float = 1.0 / 6
    /// Cap on the kernel half-width, so the scratch buffer is always big enough.
    static let maxSmoothHalfWidth = 48
    /// Geometric half-width of a display bin: it spans f / halfStep ... f * halfStep.
    private var displayHalfStep: Float = 1
    /// Display index of frequency f is `logF0Scale * log(f) + logF0Offset`.
    private var logF0Scale: Float = 1
    private var logF0Offset: Float = 0
    private var binLo = 1
    private var binHi = 1
    /// Highest FFT bin the dB conversion has to cover: only the interpolating display bins read
    /// it. Above that the display maps power directly, so converting those bins is wasted work -
    /// three quarters of the 2048-point FFT's range, at the highest hop rate of the three.
    private var dbHi = 1
    /// Bins the display path reads, including the reach of the widest sliding sum.
    private var usedLo = 1
    private var usedHi = 1
    /// Set for the resolution that also feeds `PeakReading` and `BandEnergy`: that channel's
    /// power spectrum is computed over the whole band, not only over the bins the display uses.
    var fullSpectrumChannel: Int?
    /// Extra FFT-bin range the **left and right** power spectra have to cover, on top of what the
    /// display reads. `ThirdOctaveBank` sums raw power over band edges that reach well below the
    /// display range of the short FFTs: the 2048-point FFT draws nothing under 1.4 kHz but owns
    /// the 315 Hz band, whose lowest bin is 12. Only left and right are widened, because the
    /// bands are per channel; mid and side keep the display's range, and `deriveMidSide` with them.
    var extraPowerRange: (lo: Int, hi: Int)?

    /// Half-width, in FFT bins, of the power sum at each bin, with a fractional part.
    /// Integer taps would step the displayed noise floor by 1.5 dB (5 bins -> 7 bins) at the
    /// frequency where the quantiser ticks, in the same place for every signal. That was
    /// visible in round 2. The fractional edge weight makes the analysis bandwidth a
    /// continuous function of frequency.
    private var tapsHalf = Int32Scratch(1)
    private var tapsFrac = FloatScratch(1)
    private var wideLo = 1
    private var wideHi = 0
    private var widestTapsHalf = 2

    /// Multiplies (re^2 + im^2) from vDSP's packed real FFT into squared sine amplitude.
    ///
    /// vDSP's real forward FFT returns twice the mathematical DFT, so |X|^2 = (re^2+im^2)/4.
    /// Parseval over the one-sided spectrum gives sum|X|^2 = A^2 * N * sum(w^2) / 4 for a sine
    /// of peak amplitude A, hence A^2 = (re^2+im^2 summed over the main lobe) / (N * sum(w^2)).
    private let normScale: Float

    /// Absolute sample index of the right edge of the last transform.
    var hopEnd = 0
    private(set) var hasData = false

    init?(size: Int, hop: Int, sampleRate: Double) {
        guard size >= 64, size & (size - 1) == 0, hop > 0, sampleRate > 0 else { return nil }
        let l2 = vDSP_Length(log2(Double(size)).rounded())
        guard let s = vDSP_create_fftsetup(l2, FFTRadix(kFFTRadix2)) else { return nil }
        self.size = size
        self.half = size / 2
        self.hop = hop
        self.log2n = l2
        self.setup = s
        self.df = Float(sampleRate / Double(size))

        window = FloatScratch(size)
        work = FloatScratch(size)
        re = FloatScratch(Self.channelCount * half)
        im = FloatScratch(Self.channelCount * half)
        power = FloatScratch(Self.channelCount * half)
        detoned = FloatScratch(half)
        noiseP = FloatScratch(half)
        noiseDB = FloatScratch(half)
        toneBin = Int32Scratch(half / 2 + 1)
        toneFlag = Int32Scratch(half)
        toneAverage = FloatScratch(Self.channelCount * half)
        tonePrevious = Int32Scratch(half)
        toneAverageFlag = Int32Scratch(half)
        peakRise = FloatScratch(half)
        peakRiseWork = FloatScratch(half)
        sum3 = FloatScratch(half)
        sum5 = FloatScratch(half)
        toneAverageEvery = Swift.max(Int((sampleRate / Double(hop) / 16).rounded()), 1)
        tonePower = FloatScratch(half / 2 + 1)
        toneOffset = FloatScratch(half / 2 + 1)
        for i in 0..<lobeDB.count {
            let u = Float(i) / Float(Self.lobeSteps)
            var h: Float = 1
            if abs(u - 1) < 1e-4 { h = 0.5 } else if u > 1e-4 { h = sin(.pi * u) / (.pi * u) / (1 - u * u) }
            lobeDB.p[i] = u >= 2 ? -200 : Swift.max(20 * log10(Swift.max(abs(h), 1e-10)), -200)
        }
        for i in 0..<sumDB.count {
            sumDB.p[i] = 10 * log10(1 + pow(10, -Float(i) / Float(Self.sumSteps) / 10))
        }

        // Periodic Hann. sum(w^2) = 3N/8 exactly, but compute it so the constant follows
        // the window if the window is ever changed.
        var sumSquares: Float = 0
        for i in 0..<size {
            let w = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(size))
            window.p[i] = w
            sumSquares += w * w
        }
        normScale = 1 / (Float(size) * sumSquares)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    // MARK: - Display map

    /// Rebuild the FFT-bin -> display-bin map. Called only when the sample rate or the
    /// display grid changes; never from `process` in the steady state.
    ///
    /// - Parameter weight: crossfade weight of this resolution per display bin. Bins with
    ///   zero weight are skipped entirely, which is what keeps the long FFT cheap: the
    ///   32768-point transform only has to be mapped over its ~200 lowest bins.
    func updateMap(
        displayBins n: Int,
        frequencies: UnsafePointer<Float>,
        binRatio: Float,
        weight: UnsafePointer<Float>,
        targetBandwidthHz: (Float) -> Float,
        toneBinHz: (Float) -> Float
    ) {
        // A new map serves other bins: what the old one remembered about them is stale.
        toneAverageCount = 0
        tonePrevious.fill(0)
        toneAverageFlag.fill(0)
        if displayBins != n {
            displayBins = n
            displayDB = FloatScratch(Self.channelCount * n)
            mapStart = Int32Scratch(n)
            mapEnd = Int32Scratch(n)
            mapPos = FloatScratch(n)
            smoothWork = FloatScratch(n + Self.maxSmoothHalfWidth + 1)
        }
        displayDB.fill(Self.floorDB)

        let halfStep = sqrt(binRatio)          // geometric half-width of a display bin
        displayHalfStep = halfStep
        logF0Scale = 1 / log(binRatio)
        logF0Offset = -log(frequencies[0]) * logF0Scale
        let maxBin = half - 1                  // bin 0 packs DC and Nyquist; never use it
        // Width of a display bin in FFT bins. Continuous in f, so the three passes below
        // cover contiguous index ranges.
        let spanPerHz = (halfStep - 1 / halfStep) / df

        fadeLo = n; fadeHi = -1
        interpLo = n; interpHi = -1
        meanLo = n; meanHi = -1
        var lo = maxBin
        var hi = 1
        var dbTop = 1
        var any = false

        for i in 0..<n {
            mapStart.p[i] = -1
            guard weight[i] > 0 else { continue }
            let f = frequencies[i]
            let x = f / df
            if x < 1 {
                // Below the first usable FFT bin. Fade towards the floor instead of holding
                // the value of bin 1 as a plateau or dropping straight to the floor.
                mapStart.p[i] = -3
                mapPos.p[i] = x
                fadeLo = Swift.min(fadeLo, i); fadeHi = Swift.max(fadeHi, i)
                lo = Swift.min(lo, 1); hi = Swift.max(hi, 3)
                any = true
            } else if x > Float(maxBin) {
                continue                        // above Nyquist: nothing to show
            } else if f * spanPerHz >= 2 {
                // Two or more FFT bins in this display bin: power mean over them. A mean, not
                // a max: a max is biased upward by an amount that depends on how many bins
                // fall in the display bin, and that count steps with frequency, which put a
                // visible ledge in the noise floor. Tonal peaks keep their height through the
                // tone curve, which is mapped with a max.
                let k0 = Swift.max(Int((f / halfStep / df).rounded()), 1)
                let k1 = Swift.min(Swift.max(Int((f * halfStep / df).rounded()), k0 + 1), maxBin)
                mapStart.p[i] = Int32(k0)
                mapEnd.p[i] = Int32(k1)
                mapPos.p[i] = x
                meanLo = Swift.min(meanLo, i); meanHi = Swift.max(meanHi, i)
                lo = Swift.min(lo, k0 - 2); hi = Swift.max(hi, k1 + 2)
                any = true
            } else {
                // Fewer than two FFT bins inside: interpolate in the dB domain so the low end
                // is a smooth curve instead of a staircase of repeated FFT-bin values.
                mapStart.p[i] = -2
                mapPos.p[i] = x
                interpLo = Swift.min(interpLo, i); interpHi = Swift.max(interpHi, i)
                let c = Int(x)
                lo = Swift.min(lo, c - 2); hi = Swift.max(hi, c + 2)
                dbTop = Swift.max(dbTop, c + 2)
                any = true
            }
        }

        servedLo = Swift.min(Swift.min(fadeLo, interpLo), meanLo)
        servedHi = Swift.max(Swift.max(fadeHi, interpHi), meanHi)
        let binsPerOctave = 1 / log2(binRatio)
        smoothHalfWidth = Swift.min(Swift.max(Int((Self.smoothOctaves * binsPerOctave / 2).rounded()), 1), Self.maxSmoothHalfWidth)

        binLo = any ? Swift.max(lo, 1) : 1
        binHi = any ? Swift.min(hi, maxBin) : 1
        if binHi < binLo { binHi = binLo }
        dbHi = Swift.min(Swift.max(dbTop, binLo), binHi)

        // Noise-bandwidth match. A tone keeps its level however wide the sum is (it is drawn
        // from the tone curve), but broadband content scales with the summed bandwidth.
        // Widening the finer FFT inside a crossfade is what stops pink noise from stepping up
        // ~6 dB where the analyzer changes FFT size.
        if tapsHalf.count < half { tapsHalf = Int32Scratch(half); tapsFrac = FloatScratch(half); lobeScale = FloatScratch(half) }
        lobeScale.fill(1)
        wideLo = binHi + 1
        wideHi = binLo - 1
        widestTapsHalf = Self.baseTapsHalf
        for k in binLo...binHi {
            let hz = Float(k) * df
            let wanted = targetBandwidthHz(hz) / df
            let exact = Swift.max((wanted - 1) / 2, Float(Self.baseTapsHalf))
            let w = Swift.min(Int(exact), half / 4)
            tapsHalf.p[k] = Int32(w)
            tapsFrac.p[k] = w < half / 4 ? exact - Float(w) : 0
            widestTapsHalf = Swift.max(widestTapsHalf, w + 1)
            if w > Self.baseTapsHalf || tapsFrac.p[k] > 0 {
                wideLo = Swift.min(wideLo, k)
                wideHi = Swift.max(wideHi, k)
            }
        }

        // The peak search reads three 3-bin context blocks past the widest sliding sum, so the
        // power spectrum has to be valid that far outside the display's own range.
        let reach = widestTapsHalf + Self.toneReach + 3 * Self.toneContextBlocks + 3
        usedLo = Swift.max(binLo - reach, 1)
        usedHi = Swift.min(binHi + reach, maxBin)
        for k in usedLo...usedHi {
            lobeScale.p[k] = Swift.max(toneBinHz(Float(k) * df) / df, 0.125)
        }
    }

    /// How far outside the display's own bin range a tone is still looked for, on top of the
    /// widest sliding sum: its lobe can reach back in.
    private static let toneReach = 4

    /// The narrowest sum the noise curve ever uses, in bins each side. Three bins in total:
    /// a tone does not need the sum any more (it has its own curve), so the noise curve can
    /// keep the finest resolution the FFT actually has. That is what lets the bottom two
    /// octaves follow the data instead of sitting on a half-octave-wide shelf.
    static let baseTapsHalf = 1

    // MARK: - Transform

    /// Advance the hop clock. Returns the sample index to transform at, or nil when nothing is due.
    ///
    /// Only the newest due hop is run. Feeding a big block therefore costs one transform, not
    /// many, which is what bounds `process` cost when the caller is late.
    func dueHop(samplesWritten: Int, historyCapacity: Int) -> Int? {
        let behind = samplesWritten - hopEnd
        guard behind >= hop else { return nil }
        hopEnd += (behind / hop) * hop
        guard hopEnd >= size else { return nil }
        // The window must still be inside the history ring.
        if samplesWritten - hopEnd > historyCapacity - size { hopEnd = samplesWritten }
        return hopEnd
    }

    /// Window, transform, derive mid/side, calibrate, and map to display bins.
    func transform(historyL: UnsafePointer<Float>, historyR: UnsafePointer<Float>, capacity: Int, mask: Int, end: Int) {
        let start = (end - size) & mask
        forwardFFT(history: historyL, start: start, capacity: capacity, channel: Self.chLeft)
        forwardFFT(history: historyR, start: start, capacity: capacity, channel: Self.chRight)
        deriveMidSide()
        for c in 0..<Self.channelCount { computePower(channel: c) }
        detectTones()
        for c in 0..<Self.channelCount {
            removeTones(channel: c)
            slidingPowerSum()
            toDecibels()
            mapChannel(c)
        }
        hasData = true
    }

    private func forwardFFT(history: UnsafePointer<Float>, start: Int, capacity: Int, channel: Int) {
        // Window straight out of the ring buffer; the wrap is two vDSP_vmul calls, no copy.
        let n = vDSP_Length(size)
        if start + size <= capacity {
            vDSP_vmul(history + start, 1, window.p, 1, work.p, 1, n)
        } else {
            let first = capacity - start
            vDSP_vmul(history + start, 1, window.p, 1, work.p, 1, vDSP_Length(first))
            vDSP_vmul(history, 1, window.p + first, 1, work.p + first, 1, vDSP_Length(size - first))
        }
        var split = DSPSplitComplex(realp: re.p + channel * half, imagp: im.p + channel * half)
        work.p.withMemoryRebound(to: DSPComplex.self, capacity: half) { packed in
            vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
    }

    /// The FFT is linear, so mid = (L+R)/2 and side = (L-R)/2 can be formed on the complex
    /// spectra. Two transforms per hop instead of four. Only over the bins something reads:
    /// for the 32768-point low FFT that is about 200 bins out of 16384.
    private func deriveMidSide() {
        let (mLo, mHi) = spectrumRange(channel: Self.chMid)
        let (sLo, sHi) = spectrumRange(channel: Self.chSide)
        var h: Float = 0.5
        func combine(_ lo: Int, _ hi: Int, _ dstChannel: Int, add: Bool) {
            guard hi >= lo else { return }
            let n = vDSP_Length(hi - lo + 1)
            let rl = re.p + Self.chLeft * half + lo, il = im.p + Self.chLeft * half + lo
            let rr = re.p + Self.chRight * half + lo, ir = im.p + Self.chRight * half + lo
            let rd = re.p + dstChannel * half + lo, id = im.p + dstChannel * half + lo
            if add {
                vDSP_vasm(rl, 1, rr, 1, &h, rd, 1, n)
                vDSP_vasm(il, 1, ir, 1, &h, id, 1, n)
            } else {
                vDSP_vsbsm(rl, 1, rr, 1, &h, rd, 1, n)
                vDSP_vsbsm(il, 1, ir, 1, &h, id, 1, n)
            }
        }
        combine(mLo, mHi, Self.chMid, add: true)
        combine(sLo, sHi, Self.chSide, add: false)
    }

    /// Bins of the spectrum a channel needs this frame. Everything outside the display's reach
    /// is skipped, except for the one channel that also feeds the peak readout and band energy.
    @inline(__always)
    private func spectrumRange(channel c: Int) -> (Int, Int) {
        if c == fullSpectrumChannel { return (1, half - 1) }
        if c == Self.chLeft || c == Self.chRight, let extra = extraPowerRange {
            return (Swift.min(usedLo, extra.lo), Swift.max(usedHi, extra.hi))
        }
        return (usedLo, usedHi)
    }

    private func computePower(channel c: Int) {
        let (lo, hi) = spectrumRange(channel: c)
        guard hi >= lo else { return }
        let n = vDSP_Length(hi - lo + 1)
        var scale = normScale
        var split = DSPSplitComplex(realp: re.p + c * half + lo, imagp: im.p + c * half + lo)
        let pw = power.p + c * half + lo
        vDSP_zvmags(&split, 1, pw, 1, n)
        vDSP_vsmul(pw, 1, &scale, pw, 1, n)
        if lo <= 1 { power.p[c * half] = 0 }   // bin 0 packs DC and Nyquist together: drop it
    }

    /// List the tonal peaks of this transform: the *union* over the four channels.
    ///
    /// A tone is a property of the signal, not of a channel. A quiet one-sided tone sits about
    /// 3 dB closer to the noise in mid than in the channel that carries it, which is enough to
    /// pass the gate in one and miss it in the other - and then mid draws the noise-path level
    /// and disagrees with left by a few dB at the same frequency. Deciding once for all four
    /// keeps the curves consistent: a channel that has no tone at a shared bin simply adds a
    /// lobe of the power it actually has there, which is what the noise curve said anyway.
    private func detectTones() {
        toneCount = 0
        let reach = widestTapsHalf + Self.toneReach
        let first = Swift.max(binLo - reach, 3)
        let last = Swift.min(binHi + reach, half - 4)
        guard last >= first else { return }
        let flags = toneFlag.p
        let previous = tonePrevious.p
        let count = last - first + 1
        (flags + first).update(repeating: 0, count: count)

        // The averaged spectra. The context blocks read 11 bins each side of a candidate, and
        // the memory is the same as one transform's the first time.
        let avgLo = Swift.max(first - 11, 0), avgHi = Swift.min(last + 11, half - 1)
        var alpha = toneAverageCount > 0 ? Self.toneAverageAlpha : 1
        var rest = 1 - alpha
        var loudest: Float = 0
        for c in 0..<Self.channelCount {
            let pw = power.p + c * half + avgLo, avg = toneAverage.p + c * half + avgLo
            let n = vDSP_Length(avgHi - avgLo + 1)
            vDSP_vsmsma(avg, 1, &rest, pw, 1, &alpha, avg, 1, n)   // avg = (1 - alpha) * avg + alpha * pw
            var m: Float = 0
            vDSP_maxv(pw, 1, &m, n)
            loudest = Swift.max(loudest, m)
        }
        toneAverageCount += 1
        // Digital silence in every channel: forget the tones. The averaged spectrum keeps its shape
        // as it decays, and the gate reads ratios, so without this a tone that stopped into silence
        // would stay tonal until the average underflowed. The memory starts over, warm-up included.
        if loudest < Self.toneSilencePower {
            (previous + first).update(repeating: 0, count: count)
            (toneAverageFlag.p + first).update(repeating: 0, count: count)
            for c in 0..<Self.channelCount { (toneAverage.p + c * half + avgLo).update(repeating: 0, count: avgHi - avgLo + 1) }
            toneAverageCount = 0
        }
        let averaged = toneAverageCount >= Self.toneAverageWarmup
        let decide = averaged && toneAverageCount % toneAverageEvery == 0
        let avgFlags = toneAverageFlag.p
        if decide { (avgFlags + first).update(repeating: 0, count: count) }

        // One streaming pass per channel and spectrum - the same shape as the old per-channel
        // search, so each power spectrum is walked once in order - ORed into a per-bin flag.
        for c in 0..<Self.channelCount {
            // The fast path: one transform, the 14 dB gate.
            let pw = power.p + c * half
            let rise = markLocalMaxima(pw, first, last)
            let (s3, s5, blockLo, blockHi) = slidingSums(pw, avgLo, avgHi)
            var k = first
            while k <= last {
                guard rise[k] > 0 else { k += 1; continue }
                let tone = s5[k]
                // The top of a Hann lobe, not a bump on the skirt of the tone next door: see the
                // type's header for what happens without this.
                guard pw[k] >= Self.tonePeakShare * tone else { k += 1; continue }
                if let (block, corrected) = Self.secondSmallestBlock(s3, k, lo: blockLo, hi: blockHi),
                   tone > Self.toneThreshold * 5 / 3 * (corrected ? block * Self.contextGain : block) {
                    flags[k] = 1
                    k += 2      // the next local maximum is at least two bins away
                } else {
                    k += 1
                }
            }
            // The memory: the averaged spectrum, the lower gate, and the lower still to stay on.
            guard decide else { continue }
            let avg = UnsafePointer(toneAverage.p + c * half)
            let avgRise = markLocalMaxima(avg, first, last)
            let (a3, a5, aLo, aHi) = slidingSums(avg, avgLo, avgHi)
            k = first
            while k <= last {
                guard avgRise[k] > 0 else { k += 1; continue }
                let tone = a5[k]
                guard avg[k] >= Self.tonePeakShare * tone, let (block, _) = Self.secondSmallestBlock(a3, k, lo: aLo, hi: aHi) else { k += 1; continue }
                let noise = 5 * block / 3
                if tone > Self.toneAverageOnThreshold * noise
                    || (tone > Self.toneAverageOffThreshold * noise && Swift.max(previous[k - 1], previous[k], previous[k + 1]) != 0) {
                    avgFlags[k] = 1
                    k += 2
                } else {
                    k += 1
                }
            }
        }
        // What the averaged gate holds, this transform or the last time it ran.
        if averaged { vDSP_vaddi(flags + first, 1, avgFlags + first, 1, flags + first, 1, vDSP_Length(count)) }
        (previous + first).update(from: flags + first, count: count)

        var k = first
        while k <= last {
            if flags[k] != 0, toneCount < toneBin.count {
                toneBin.p[toneCount] = Int32(k)
                toneCount += 1
                k += 2
            } else {
                k += 1
            }
        }
    }

    /// `peakRise` over `first...last` for one spectrum: positive where the bin stands over both
    /// neighbours. (A bin equal to its lower neighbour reads 0 and is not a peak; the search used
    /// to allow that, which two floating-point bins of a real spectrum never are anyway.)
    @inline(__always)
    private func markLocalMaxima(_ p: UnsafePointer<Float>, _ first: Int, _ last: Int) -> UnsafePointer<Float> {
        let n = vDSP_Length(last - first + 1)
        let rise = peakRise.p + first, work = peakRiseWork.p + first
        vDSP_vsub(p + first + 1, 1, p + first, 1, rise, 1, n)   // p[k] - p[k+1]
        vDSP_vsub(p + first - 1, 1, p + first, 1, work, 1, n)   // p[k] - p[k-1]
        vDSP_vmin(rise, 1, work, 1, rise, 1, n)
        return UnsafePointer(peakRise.p)   // indexed by bin, like the spectrum
    }

    /// `sum3` and `sum5` of one spectrum over `lo...hi`, and the range of `sum3` a context block may
    /// start at: `lo` (never bin 0), and `hi - 2` so that the block's three bins are inside.
    @inline(__always)
    private func slidingSums(_ p: UnsafePointer<Float>, _ lo: Int, _ hi: Int) -> (UnsafePointer<Float>, UnsafePointer<Float>, Int, Int) {
        let s3 = sum3.p, s5 = sum5.p
        let n3 = vDSP_Length(hi - lo - 1)            // sum3[lo ... hi-2]
        vDSP_vadd(p + lo, 1, p + lo + 1, 1, s3 + lo, 1, n3)
        vDSP_vadd(s3 + lo, 1, p + lo + 2, 1, s3 + lo, 1, n3)
        let n5 = vDSP_Length(hi - lo - 3)            // sum5[lo+2 ... hi-2]
        vDSP_vadd(s3 + lo, 1, p + lo + 3, 1, s5 + lo + 2, 1, n5)      // p[k-2..k] + p[k+1]
        vDSP_vadd(s5 + lo + 2, 1, p + lo + 4, 1, s5 + lo + 2, 1, n5)  // + p[k+2]
        return (UnsafePointer(s3), UnsafePointer(s5), Swift.max(lo, 1), hi - 2)
    }

    /// `contextBlock` on the sliding 3-bin *sums* (three times the block mean): the second smallest
    /// of the six blocks beside `k`, and whether it is that (with fewer than three blocks near an
    /// edge, the smallest). Six reads instead of eighteen.
    @inline(__always)
    private static func secondSmallestBlock(_ s3: UnsafePointer<Float>, _ k: Int, lo: Int, hi: Int) -> (Float, Bool)? {
        var b0 = Float.greatestFiniteMagnitude, b1 = Float.greatestFiniteMagnitude
        var seen = 0
        var block = 0
        while block < toneContextBlocks {
            let a = k + 3 + 3 * block, d = k - 5 - 3 * block
            if a <= hi { insert(s3[a], into: &b0, &b1); seen += 1 }
            if d >= lo { insert(s3[d], into: &b0, &b1); seen += 1 }
            block += 1
        }
        guard seen > 0 else { return nil }
        return seen >= 3 ? (b1, true) : (b0, false)
    }

    /// Test hook: the tonal peak bins of the last transform, and what the last channel (side) drew for them.
    var detectedTones: [(bin: Int, offset: Float, powerDB: Float)] {
        (0..<toneCount).map { (Int(toneBin.p[$0]), toneOffset.p[$0], 10 * log10(Swift.max(tonePower.p[$0], 1e-30))) }
    }

    /// Noise power per bin near `k`, from six 3-bin blocks, three each side, outside the main lobe.
    ///
    /// Block means, not a side mean: in a chord the next partial often sits inside one side. A low
    /// order statistic with its bias on plain noise taken out, not the bare minimum: round 2 used
    /// the minimum, which reads about 2.5 dB low, let noise through the gate and notched the noise
    /// curve beside every real peak.
    @inline(__always)
    private func contextNoise(_ pw: UnsafePointer<Float>, _ k: Int) -> Float? {
        guard let (block, corrected) = contextBlock(pw, k) else { return nil }
        return corrected ? block * Self.contextGain : block
    }

    /// The raw block estimate under `contextNoise`: the second smallest of the six block means,
    /// and whether that is what it is (with fewer than three blocks near an edge, the smallest).
    @inline(__always)
    private func contextBlock(_ pw: UnsafePointer<Float>, _ k: Int) -> (Float, Bool)? {
        var b0 = Float.greatestFiniteMagnitude, b1 = Float.greatestFiniteMagnitude
        var seen = 0
        var block = 0
        while block < Self.toneContextBlocks {
            let a = k + 3 + 3 * block, d = k - 5 - 3 * block
            if a + 2 <= half - 1 { Self.insert((pw[a] + pw[a + 1] + pw[a + 2]) / 3, into: &b0, &b1); seen += 1 }
            if d >= 1 { Self.insert((pw[d] + pw[d + 1] + pw[d + 2]) / 3, into: &b0, &b1); seen += 1 }
            block += 1
        }
        guard seen > 0 else { return nil }
        return seen >= 3 ? (b1, true) : (b0, false)
    }

    /// Write `detoned` for one channel: its power with every shared tonal main lobe replaced by
    /// its own local noise level, and record its own calibrated level for each of them.
    private func removeTones(channel c: Int) {
        let pw = power.p + c * half
        let q = detoned.p
        (q + usedLo).update(from: pw + usedLo, count: usedHi - usedLo + 1)
        guard toneCount > 0 else { return }
        let avg = UnsafePointer(toneAverage.p + c * half)
        let steady = toneAverageCount >= Self.toneAverageWarmup
        for t in 0..<toneCount {
            let k = Int(toneBin.p[t])
            let fill = contextNoise(pw, k) ?? 0
            let sum = pw[k - 2] + pw[k - 1] + pw[k] + pw[k + 1] + pw[k + 2]
            // Does this channel carry the tone? See `toneChannelThreshold`.
            if steady, sum <= Self.toneThreshold * 5 * fill {
                let avgSum = avg[k - 2] + avg[k - 1] + avg[k] + avg[k + 1] + avg[k + 2]
                let avgBlock = contextBlock(avg, k)?.0 ?? 0
                if avgSum <= Self.toneChannelThreshold * 5 * avgBlock {
                    tonePower.p[t] = 0
                    toneOffset.p[t] = 0
                    continue
                }
            }
            // The noise under the lobe stays on the noise curve, so it is not counted twice.
            tonePower.p[t] = Swift.max(sum - 5 * fill, 0)
            // Where the tone sits between bins. For a Hann window the ratio of the two largest
            // bin amplitudes gives the offset exactly: r = |X[k+-1]| / |X[k]|, d = (2r - 1) / (r + 1).
            let c0 = pw[k], l = pw[k - 1], r = pw[k + 1]
            var offset: Float = 0
            if c0 > 0 {
                let ratio = (Swift.max(l, r) / c0).squareRoot()
                offset = Swift.min(Swift.max((2 * ratio - 1) / (ratio + 1), 0), 0.5)
                if l > r { offset = -offset }
            }
            toneOffset.p[t] = offset
            for j in (k - Self.lobeHalf)...(k + Self.lobeHalf) { q[j] = Swift.min(q[j], fill) }
        }
    }

    /// Keeps the two smallest block values, `b0 <= b1`: the statistic reads only those.
    @inline(__always)
    private static func insert(_ v: Float, into b0: inout Float, _ b1: inout Float) {
        if v < b0 { b1 = b0; b0 = v } else if v < b1 { b1 = v }
    }

    /// `noiseP[k] = sum(detoned[k-w...k+w]) + frac * (detoned[k-w-1] + detoned[k+w+1])`,
    /// with `w` and `frac` from the bandwidth ramp. The fractional edge weight is what keeps
    /// the displayed noise floor free of 1.5 dB ledges where an integer tap count would tick.
    private func slidingPowerSum() {
        let pw = UnsafePointer(detoned.p)
        let out = noiseP.p
        let w0 = Self.baseTapsHalf
        let vecLo = Swift.max(binLo, w0)
        let vecHi = Swift.min(binHi, half - 1 - w0)
        if vecHi >= vecLo {
            let n = vDSP_Length(vecHi - vecLo + 1)
            let src = pw + vecLo
            let dst = out + vecLo
            vDSP_vadd(src - w0, 1, src, 1, dst, 1, n)
            var j = -w0 + 1
            while j <= w0 {
                if j != 0 { vDSP_vadd(dst, 1, src + j, 1, dst, 1, n) }
                j += 1
            }
        }
        // Bins outside the vectorised span (at most a handful at each end).
        var k = binLo
        while k <= binHi {
            if k >= vecLo && k <= vecHi { k = vecHi + 1; continue }
            out[k] = Self.clampedSum(pw, k, w0, half)
            k += 1
        }
        // Bins inside a bandwidth ramp need a wider sum. `tapsHalf` only ever grows with
        // frequency, so the sum is carried forward: one add and one subtract to slide it,
        // two more on the rare bin where the width grows. Recomputing it from scratch cost
        // up to 21 adds per bin over most of the display.
        guard wideHi >= wideLo else { return }
        var carried: Float = 0
        var carriedWidth = -1
        var sinceFull = 0
        for k in wideLo...wideHi {
            let w = Int(tapsHalf.p[k])
            let frac = tapsFrac.p[k]
            if w == w0 && frac == 0 { carriedWidth = -1; continue }
            if carriedWidth == w && sinceFull < Self.carryResyncBins && carried > 0 {
                let drop = k - 1 - w, add = k + w
                carried += (add <= half - 1 ? pw[add] : 0) - (drop >= 0 ? pw[drop] : 0)
                sinceFull += 1
            } else if carriedWidth >= 0 && w > carriedWidth && sinceFull < Self.carryResyncBins && carried > 0 {
                // Slide by one, then widen to the new half-width.
                let drop = k - 1 - carriedWidth, add = k + carriedWidth
                carried += (add <= half - 1 ? pw[add] : 0) - (drop >= 0 ? pw[drop] : 0)
                var width = carriedWidth
                while width < w {
                    width += 1
                    let a = k - width, b = k + width
                    if a >= 0 { carried += pw[a] }
                    if b <= half - 1 { carried += pw[b] }
                }
                carriedWidth = w
                sinceFull += 1
            } else {
                carried = Self.clampedSum(pw, k, w, half)
                carriedWidth = w
                sinceFull = 0
            }
            var s = Swift.max(carried, 0)
            if frac > 0 {
                let a = k - w - 1, b = k + w + 1
                if a >= 0 { s += frac * pw[a] }
                if b <= half - 1 { s += frac * pw[b] }
            }
            out[k] = s
        }
    }

    /// A carried sum is rebuilt from scratch this often. Power spectra span 200 dB, so
    /// subtracting a tone out of a running sum leaves a residue that single precision cannot
    /// cancel; resyncing bounds it, and a sum that has gone negative is rebuilt at once.
    private static let carryResyncBins = 32

    @inline(__always)
    private static func clampedSum(_ pw: UnsafePointer<Float>, _ k: Int, _ w: Int, _ half: Int) -> Float {
        var s: Float = 0
        let a = Swift.max(k - w, 0), b = Swift.min(k + w, half - 1)
        var j = a
        while j <= b { s += pw[j]; j += 1 }
        return s
    }

    private func toDecibels() {
        let n = dbHi - binLo + 1
        guard n > 0 else { return }
        let src = noiseP.p + binLo
        let dst = noiseDB.p + binLo
        var eps: Float = 1e-30                      // keeps log10 finite on digital silence
        var count = Int32(n)
        var ten: Float = 10, zero: Float = 0
        vDSP_vthr(src, 1, &zero, dst, 1, vDSP_Length(n))   // no negative power reaches log10
        vDSP_vsadd(dst, 1, &eps, dst, 1, vDSP_Length(n))
        vvlog10f(dst, dst, &count)
        vDSP_vsmsa(dst, 1, &ten, &zero, dst, 1, vDSP_Length(n))
    }

    // MARK: - Display mapping

    private func mapChannel(_ c: Int) {
        let n = displayBins
        guard n > 0 else { return }
        let out = displayDB.p + c * n
        let db = noiseDB.p
        let lo = binLo, hi = dbHi

        // Below the first usable FFT bin: fade towards the floor, 18 dB per octave, so the
        // curve leaves the plot instead of holding a plateau at the value of bin 1.
        if fadeHi >= fadeLo {
            let edge = db[Swift.max(lo, 1)]
            for i in fadeLo...fadeHi where mapStart.p[i] == -3 {
                let octaves = -log2(Swift.max(mapPos.p[i], 1e-6))
                out[i] = Swift.max(edge - 18 * octaves, Self.floorDB)
            }
        }

        // Finer than the FFT grid: interpolate. The value at the centre of the display bin,
        // not the loudest point inside it: a max biases the noise floor upward by an amount
        // that grows with the span, which is a slope the signal does not have.
        if interpHi >= interpLo {
            // The tangents only change when the display bin moves to the next pair of FFT
            // bins, and at the bottom of the range twenty display bins share one pair, so
            // the segment is computed once and then only the cubic is evaluated per bin.
            var segment = -1
            var y1: Float = 0, y2: Float = 0, m1: Float = 0, m2: Float = 0
            for i in interpLo...interpHi where mapStart.p[i] == -2 {
                let x = mapPos.p[i]
                let i1 = Swift.min(Swift.max(Int(x), lo), hi)
                if i1 != segment {
                    segment = i1
                    (y1, y2, m1, m2) = Self.hermiteSegment(db, lo: lo, hi: hi, i1: i1)
                }
                let t = x - Float(i1)
                let t2 = t * t, t3 = t2 * t
                out[i] = (2 * t3 - 3 * t2 + 1) * y1 + (t3 - 2 * t2 + t) * m1
                    + (-2 * t3 + 3 * t2) * y2 + (t3 - t2) * m2
            }
        }

        // Two or more FFT bins: power mean, then one vectorised log for the whole range.
        if meanHi >= meanLo {
            for i in meanLo...meanHi {
                let s = Int(mapStart.p[i])
                guard s >= 0 else { out[i] = 1e-30; continue }
                let e = Int(mapEnd.p[i])
                var sum: Float = 0
                var k = s
                while k <= e { sum += noiseP.p[k]; k += 1 }
                out[i] = Swift.max(sum / Float(e - s + 1), 1e-30)
            }
            var count = Int32(meanHi - meanLo + 1)
            var ten: Float = 10, zero: Float = 0
            vvlog10f(out + meanLo, out + meanLo, &count)
            vDSP_vsmsa(out + meanLo, 1, &ten, &zero, out + meanLo, 1, vDSP_Length(meanHi - meanLo + 1))
            for i in meanLo...meanHi where mapStart.p[i] < 0 { out[i] = Self.floorDB }
        }

        smoothNoise(out)
        guard toneCount > 0 else { return }
        mapTones(out)
    }

    /// A triangular kernel across *display* bins, applied to the noise curve only.
    ///
    /// One frame of a periodogram scatters by about 2 dB from bin to bin whatever the FFT size:
    /// that is the chi-square of the estimator, not structure in the signal, and it is what made
    /// the round 2 noise floor jump several dB between neighbouring columns. Because the display
    /// grid is logarithmic, a fixed kernel in display bins is constant-Q: `smoothOctaves` wide
    /// everywhere. It costs nothing below a few hundred Hz, where one FFT bin is already many
    /// display bins wide, and it is what holds the noise floor together at the top, where one
    /// display bin is barely one FFT bin. Tonal peaks are added after this and stay pointed.
    /// A triangular kernel is a box filter applied twice, and a box filter is a running sum,
    /// so this costs four adds per display bin however wide the kernel is. The wide scalar
    /// convolution it replaces was the single most expensive thing in `process`.
    private func smoothNoise(_ out: UnsafeMutablePointer<Float>) {
        let lo = servedLo, hi = servedHi
        let m = smoothHalfWidth
        guard m > 0, hi - lo >= 2 * m else { return }
        let n = hi - lo + 1
        let length = m + 1
        let w = smoothWork.p                        // capacity is displayBins + maxSmoothHalfWidth
        let src = out + lo
        @inline(__always) func source(_ j: Int) -> Float { src[Swift.min(Swift.max(j, 0), n - 1)] }

        // Pass 1, forward box of `length` taps: w[j + m] = sum of source(j ... j+m).
        var box: Float = 0
        for u in 0..<length { box += source(-m + u) }
        w[0] = box
        var j = -m + 1
        // The interior needs no clamping, which is most of the range and all of the cost.
        while j <= 0 {
            box += src[Swift.min(j + length - 1, n - 1)] - src[0]
            w[j + m] = box
            j += 1
        }
        let interiorEnd = n - length
        while j <= interiorEnd {
            box += src[j + length - 1] - src[j - 1]
            w[j + m] = box
            j += 1
        }
        while j <= n - 1 {
            box += src[n - 1] - src[j - 1]
            w[j + m] = box
            j += 1
        }

        // Pass 2, backward box over the first: the two together are the triangle, centred.
        let norm = 1 / Float(length * length)
        var acc: Float = 0
        for t in 0..<length { acc += w[m - t] }
        out[lo] = acc * norm
        var i = 1
        while i < n {
            acc += w[i + m] - w[i - 1]
            out[lo + i] = acc * norm
            i += 1
        }
    }

    /// Draw every tone's main lobe onto the noise curve, in the power domain.
    ///
    /// The lobe is evaluated at the display bins, not sampled at FFT bins and interpolated: the
    /// tone's position is known to a fraction of a bin and the window's lobe is known exactly, so
    /// the flank is the smooth curve it really is at any display resolution. A display bin takes
    /// the lobe at the point of its own span that is nearest to the tone, which is the highest
    /// point inside it, so the bin that holds the tone reads the calibrated level.
    private func mapTones(_ out: UnsafeMutablePointer<Float>) {
        let lobe = UnsafePointer(lobeDB.p), sums = UnsafePointer(sumDB.p)
        let lobeSteps = Float(Self.lobeSteps), sumSteps = Float(Self.sumSteps)
        let sumRange = Float(Self.sumRangeDB)
        let first = Swift.min(interpLo, meanLo), last = Swift.max(interpHi, meanHi)
        guard last >= first else { return }
        for t in 0..<toneCount {
            let power = tonePower.p[t]
            guard power > 1e-20 else { continue }
            let k = Int(toneBin.p[t])
            let x0 = Float(k) + toneOffset.p[t]
            let scale = lobeScale.p[k]
            let peakDB = 10 * log10(power)
            let f0 = Swift.max((x0 - 2 * scale) * df, 1e-3)
            let f1 = (x0 + 2 * scale) * df
            let i0 = Swift.max(Int((logF0Scale * log(f0) + logF0Offset).rounded(.down)), first)
            let i1 = Swift.min(Int((logF0Scale * log(f1) + logF0Offset).rounded(.up)), last)
            guard i1 >= i0 else { continue }
            let perUnit = lobeSteps / scale
            for i in i0...i1 where mapStart.p[i] != -1 && mapStart.p[i] != -3 {
                let x = mapPos.p[i]
                let xLo = x / displayHalfStep, xHi = x * displayHalfStep
                let distance = x0 < xLo ? xLo - x0 : (x0 > xHi ? x0 - xHi : 0)
                let u = distance * perUnit
                guard u < 2 * lobeSteps else { continue }
                let ui = Int(u)
                let toneDB = peakDB + lobe[ui] + (u - Float(ui)) * (lobe[ui + 1] - lobe[ui])
                // out = 10 log10(10^(out/10) + 10^(tone/10)), from the table.
                let noise = out[i]
                let hi = Swift.max(noise, toneDB)
                let gap = abs(noise - toneDB)
                if gap >= sumRange { out[i] = hi; continue }
                let g = gap * sumSteps
                let gi = Int(g)
                out[i] = hi + sums[gi] + (g - Float(gi)) * (sums[gi + 1] - sums[gi])
            }
        }
    }

    /// End values and clamped tangents of the monotone cubic Hermite (Fritsch-Carlson) segment
    /// `i1 ... i1+1`, in the dB domain. Used where display bins are finer than FFT bins, which is
    /// the whole low end of a log display. Monotone, not Catmull-Rom: a plain cubic overshoots on
    /// noisy data and a clamped one then flattens into short plateaus.
    ///
    /// The Fritsch-Carlson clamp is normally written with `a = m1 / delta` and `b = m2 / delta`.
    /// Both tests it needs - the signs and `a^2 + b^2 > 9` - can be made without the divisions,
    /// and a division is the most expensive thing in the display mapping.
    @inline(__always)
    static func hermiteSegment(_ y: UnsafePointer<Float>, lo: Int, hi: Int, i1: Int) -> (Float, Float, Float, Float) {
        let y0 = y[Swift.max(i1 - 1, lo)]
        let y1 = y[i1]
        let y2 = y[Swift.min(i1 + 1, hi)]
        let y3 = y[Swift.min(i1 + 2, hi)]

        let delta = y2 - y1
        if delta == 0 { return (y1, y2, 0, 0) }
        var m1 = 0.5 * (y2 - y0)
        var m2 = 0.5 * (y3 - y1)
        if m1 * delta < 0 { m1 = 0 }
        if m2 * delta < 0 { m2 = 0 }
        let sum = m1 * m1 + m2 * m2
        let limit = 9 * delta * delta
        if sum > limit {
            let scale = 3 * abs(delta) / sum.squareRoot()
            m1 *= scale
            m2 *= scale
        }
        return (y1, y2, m1, m2)
    }
}
