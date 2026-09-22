import Accelerate
import Foundation

/// Turning a recording of a sweep into a frequency response.
///
/// The chain, in order:
///
/// 1. **Deconvolution.** `H = R·conj(S) / (|S|² + ε)`. Dividing by the spectrum of the sweep
///    that was actually played takes out the fades, the band edges and the clamped end
///    frequency for free. ε is Kirkeby regularization: −50 dB under the mean sweep power
///    inside the swept band, 0 dB outside it, with a third-octave raised-cosine ramp between.
///    Inside the band ε is far below `|S|²` everywhere, so it changes nothing; outside it stops
///    the division from amplifying noise by 60 dB.
/// 2. **Alignment.** The peak of that impulse response is the round-trip delay. It is a
///    whitened cross-correlation of the recording against the sweep, which is the same thing as
///    a plain cross-correlation with the matched filter flattened, and it peaks far more
///    sharply. `delaySamples(recorded:reference:)` does the plain version for anyone who wants
///    it, and for aligning a run against another run.
/// 3. **Windowing.** Half-Hann in, half-Hann out. The leading edge is short (5 ms by default) so
///    that the harmonic impulse responses — which sit `L·ln(n)` seconds *before* the linear one —
///    stay outside. The trailing edge is adaptive: walk forward in 1 ms blocks until the
///    envelope has been within 3 dB of the noise floor for 3 blocks running, then clamp into
///    `minimumPostWindowSeconds ... maximumPostWindowSeconds`.
/// 4. **Magnitude** on the module's 200-point log grid, with fractional-octave smoothing.
///
/// Everything is a static function over arrays. No I/O, no state, nothing that can make sound.
public enum SweepAnalysis {

    // MARK: - Options

    /// How much smoothing to apply to the magnitude response.
    public enum OctaveSmoothing: String, Sendable, Equatable, CaseIterable {
        case none
        case twelfth = "1/12 octave"
        case sixth = "1/6 octave"
        case third = "1/3 octave"

        /// The `b` in "1/b octave", or `nil` for no smoothing.
        public var denominator: Double? {
            switch self {
            case .none: return nil
            case .twelfth: return 12
            case .sixth: return 6
            case .third: return 3
            }
        }
    }

    public struct Options: Sendable, Equatable {
        /// Regularization inside the swept band, in dB under the mean sweep power. −50 dB is
        /// deep enough to be invisible in band and shallow enough to stay numerically safe.
        public var inBandRegularizationDB: Double = -50
        /// Regularization outside the swept band, in dB relative to the mean sweep power.
        /// 0 dB means "where the sweep had no energy, return nothing".
        public var outOfBandRegularizationDB: Double = 0
        /// Width of the raised-cosine ramp between the two, in octaves, centred on each band edge.
        public var regularizationRampOctaves: Double = 1.0 / 3
        /// Window length before the impulse peak. Never more than half the distance back to the
        /// 2nd-harmonic impulse response, whatever is set here.
        public var preWindowSeconds: Double = 0.005
        /// Shortest trailing window the adaptive rule may choose. 100 ms holds the ring of a
        /// 30 Hz high-pass; going shorter would flatten the bass by truncation.
        public var minimumPostWindowSeconds: Double = 0.100
        /// Longest trailing window. 300 ms is the spec default and covers a reflective
        /// flat-plate rig.
        public var maximumPostWindowSeconds: Double = 0.300
        /// Fraction of the trailing window spent in the half-Hann fade-out.
        public var postWindowFadeFraction: Double = 0.25
        /// How far above the measured noise floor the envelope must fall before the trailing
        /// window is allowed to close.
        public var decayStopMarginDB: Double = 3
        /// Default smoothing for `magnitudeResponse`.
        public var smoothing: OctaveSmoothing = .twelfth
        /// FFT length used for the windowed response. 65536 gives 0.73 Hz bins at 48 kHz.
        public var responseFFTSize: Int = 65_536

        public init() {}
    }

    // MARK: - Results

    /// A deconvolved impulse response, before windowing.
    public struct ImpulseResponse: Sendable {
        /// The cyclic impulse response, one FFT length long. Harmonic distortion products sit
        /// before `peakIndex` (wrapping round the end of the buffer for a short recording).
        public var samples: [Double]
        public var sampleRate: Double
        /// Sample of the linear impulse peak — the play-to-record delay.
        public var peakIndex: Int
        /// The same peak to a fraction of a sample, from a parabolic fit.
        public var peakSubSample: Double
        /// Noise floor in dB relative to the peak, measured just before the peak.
        public var noiseFloorDBRelativePeak: Double
        /// Where the n-th harmonic impulse response sits, in samples before `peakIndex`.
        public var harmonicOffsetSamples: [Int: Int]

        public var delaySeconds: Double { Double(peakIndex) / sampleRate }
    }

    /// A windowed impulse response, ready to transform.
    public struct WindowedImpulseResponse: Sendable {
        public var samples: [Double]
        public var sampleRate: Double
        /// Index of the impulse peak inside `samples` (equals `preSamples`).
        public var peakOffset: Int
        public var preSamples: Int
        public var postSamples: Int
        /// Lowest frequency the window can resolve, `1 / windowSeconds`. Below it the curve is
        /// the window's shape, not the headphone's.
        public var lowestResolvedHz: Double {
            sampleRate / Double(max(samples.count, 1))
        }
    }

    /// A complex frequency response on a linear FFT grid. This is what gets averaged across runs.
    public struct ComplexResponse: Sendable {
        var spectrum: HalfSpectrum
        public var sampleRate: Double
        public var fftSize: Int { spectrum.n }
        public func magnitudeDB(onGrid grid: [Double], smoothing: OctaveSmoothing) -> [Double] {
            SweepAnalysis.smoothedMagnitudeDB(spectrum, sampleRate: sampleRate, grid: grid, smoothing: smoothing)
        }
    }

    /// Harmonic distortion read off the impulse responses the sweep separated in time.
    public struct HarmonicDistortion: Sendable, Equatable {
        /// √(ΣEₙ / E₁) over the harmonics measured, as a percentage.
        public var totalPercent: Double
        /// Per harmonic, `2` and `3`, as a percentage.
        public var perHarmonicPercent: [Int: Double]
        /// How much of the sweep's band each harmonic could be measured over (1.0 = all of it).
        /// The percentages are already divided by this.
        public var bandCoverage: [Int: Double]

        public static let none = HarmonicDistortion(totalPercent: 0, perHarmonicPercent: [:], bandCoverage: [:])
    }

    // MARK: - Alignment

    /// Play-to-record delay in samples, by plain cross-correlation of `recorded` against
    /// `reference`, with the sub-sample position from a parabolic fit.
    ///
    /// This is the textbook matched filter: `IFFT(R · conj(S))`. It needs no model of the signal
    /// and works for any stimulus, which is why it is the one exposed for aligning one run
    /// against another. For a sweep, `impulseResponse` finds the same delay with a sharper peak,
    /// because the regularized inverse whitens the correlation first.
    ///
    /// - Returns: the integer delay, the sub-sample delay, and a 0...1 confidence — the peak
    ///   divided by the RMS of the whole correlation, scaled so that a clean measurement reads
    ///   near 1 and pure noise reads near 0.
    public static func delaySamples(
        recorded: [Double],
        reference: [Double]
    ) -> (samples: Int, subSample: Double, confidence: Double) {
        let length = nextPowerOfTwo(max(recorded.count, reference.count) + 1)
        let fft = RealFFT(count: length)
        let r = fft.forward(recorded)
        let s = fft.forward(reference)
        var product = HalfSpectrum(n: length)
        for k in 0..<product.binCount {
            // R · conj(S)
            product.real[k] = r.real[k] * s.real[k] + r.imag[k] * s.imag[k]
            product.imag[k] = r.imag[k] * s.real[k] - r.real[k] * s.imag[k]
        }
        let correlation = fft.inverse(product)
        let peak = peakIndex(correlation)
        let rms = correlation.rms
        let confidence = rms > 0 ? min(1, abs(correlation[peak]) / (rms * Double(length).squareRoot())) : 0
        return (peak, parabolicPeakOffset(correlation, around: peak), confidence)
    }

    // MARK: - Impulse response

    /// Deconvolve one recording of `sweep` into an impulse response.
    ///
    /// The recording may start whenever it likes: the delay comes out as `peakIndex`. It must
    /// be no longer than `nextPowerOfTwo(max(recorded, sweep))` samples, which it always is for
    /// a recording that is the sweep plus a tail.
    public static func impulseResponse(
        recorded: [Double],
        sweep: SweepSignal,
        options: Options = Options()
    ) -> ImpulseResponse {
        let deconvolver = SweepDeconvolver(sweep: sweep, recordedCount: recorded.count, options: options)
        return deconvolver.impulseResponse(of: recorded)
    }

    // MARK: - Windowing

    /// Cut the linear impulse out of `ir` with an adaptive half-Hann window.
    ///
    /// The leading edge rejects the harmonic impulse responses; the trailing edge stops where
    /// the decay reaches the noise floor, so a quiet room gets a long window and a noisy one a
    /// short one, with the low-frequency resolution that implies (`lowestResolvedHz`).
    public static func window(_ ir: ImpulseResponse, options: Options = Options()) -> WindowedImpulseResponse {
        let n = ir.samples.count
        let fs = ir.sampleRate
        let peak = ir.peakIndex

        // Leading edge: the default, but never more than half the way back to the 2nd harmonic.
        var pre = max(1, Int(options.preWindowSeconds * fs))
        if let h2 = ir.harmonicOffsetSamples[2], h2 > 2 {
            pre = min(pre, h2 / 2)
        }
        pre = min(pre, n / 4)

        // Trailing edge: walk in 1 ms blocks until the envelope sits on the noise floor.
        let block = max(8, Int(0.001 * fs))
        let floorRMS = noiseFloorRMS(ir.samples, peak: peak, sampleRate: fs, harmonics: ir.harmonicOffsetSamples)
        let stopRMS = floorRMS * pow(10, options.decayStopMarginDB / 20)
        let maxPost = min(Int(options.maximumPostWindowSeconds * fs), n / 2)
        let minPost = min(Int(options.minimumPostWindowSeconds * fs), maxPost)
        var post = maxPost
        var quiet = 0
        var offset = 0
        while offset + block <= maxPost {
            var sum = 0.0
            for i in offset..<(offset + block) {
                let v = ir.samples[cyclicIndex(peak + i, n)]
                sum += v * v
            }
            let blockRMS = (sum / Double(block)).squareRoot()
            if blockRMS <= stopRMS {
                quiet += 1
                if quiet >= 3 {
                    post = offset + block
                    break
                }
            } else {
                quiet = 0
            }
            offset += block
        }
        post = min(max(post, minPost), maxPost)

        return window(ir, preSamples: pre, postSamples: post, fadeFraction: options.postWindowFadeFraction)
    }

    /// The same window with the lengths fixed by the caller.
    ///
    /// Averaging several runs needs every run windowed identically, and so does the noise-only
    /// segment that the signal-to-noise estimate compares against — otherwise the comparison is
    /// between two different filters. The pipeline picks the lengths once, from the first run,
    /// and passes them here for everything after.
    ///
    /// The window can be placed anywhere, including on a buffer with no impulse in it at all
    /// (which is exactly what the noise segment is).
    public static func window(
        _ ir: ImpulseResponse,
        preSamples pre: Int,
        postSamples post: Int,
        fadeFraction: Double = 0.25,
        centre: Int? = nil
    ) -> WindowedImpulseResponse {
        let n = ir.samples.count
        let peak = centre ?? ir.peakIndex
        let pre = max(1, min(pre, n / 4))
        let post = max(1, min(post, n / 2))
        var out = [Double](repeating: 0, count: pre + post)
        let fade = max(1, Int(Double(post) * fadeFraction))
        for i in 0..<(pre + post) {
            let sample = ir.samples[cyclicIndex(peak - pre + i, n)]
            var w = 1.0
            if i < pre {
                // Rising half-Hann across the whole leading edge.
                w = 0.5 * (1 - cos(Double.pi * Double(i) / Double(pre)))
            } else if i >= pre + post - fade {
                let j = i - (pre + post - fade)
                w = 0.5 * (1 + cos(Double.pi * Double(j) / Double(fade)))
            }
            out[i] = sample * w
        }
        return WindowedImpulseResponse(
            samples: out,
            sampleRate: ir.sampleRate,
            peakOffset: pre,
            preSamples: pre,
            postSamples: post
        )
    }

    // MARK: - Magnitude

    /// Complex frequency response of a windowed impulse response.
    public static func complexResponse(
        _ windowed: WindowedImpulseResponse,
        options: Options = Options()
    ) -> ComplexResponse {
        let size = max(nextPowerOfTwo(options.responseFFTSize), nextPowerOfTwo(windowed.samples.count))
        let fft = RealFFT(count: size)
        return ComplexResponse(spectrum: fft.forward(windowed.samples), sampleRate: windowed.sampleRate)
    }

    /// Magnitude response in dB on `grid`, smoothed.
    ///
    /// The grid defaults to the module's 200-point log grid, the one every embedded curve uses,
    /// so a measured curve drops straight into the overlay next to an AutoEq one.
    public static func magnitudeResponse(
        ir windowed: WindowedImpulseResponse,
        grid: [Double] = SweepAnalysis.standardGrid,
        smoothing: OctaveSmoothing = .twelfth,
        options: Options = Options()
    ) -> [Double] {
        complexResponse(windowed, options: options).magnitudeDB(onGrid: grid, smoothing: smoothing)
    }

    /// The module's 200-point log-spaced grid, 20 Hz ... 20 kHz, as `Double`.
    public static let standardGrid: [Double] = EmbeddedCurves.standardFrequenciesHz.map(Double.init)

    /// Fractional-octave smoothing of a spectrum onto a log grid.
    ///
    /// Power is averaged inside each band with a Hann weight over log frequency — the usual
    /// acoustics convention, and the one that leaves a broad peak or notch at its real height.
    /// Where a band is narrower than one FFT bin (the bottom of a 1/12-octave sweep), the value
    /// is interpolated between bins instead, so the bass never goes to zero for want of a bin.
    static func smoothedMagnitudeDB(
        _ spectrum: HalfSpectrum,
        sampleRate: Double,
        grid: [Double],
        smoothing: OctaveSmoothing
    ) -> [Double] {
        let bins = spectrum.binCount
        var power = [Double](repeating: 0, count: bins)
        for k in 0..<bins { power[k] = spectrum.power(k) }
        let binHz = sampleRate / Double(spectrum.n)

        func interpolatedDB(_ f: Double) -> Double {
            let x = f / binHz
            let k = Int(x)
            guard k >= 1, k + 1 < bins else {
                let clamped = min(max(k, 1), bins - 1)
                return powerDB(power[clamped])
            }
            let t = x - Double(k)
            return powerDB(power[k]) * (1 - t) + powerDB(power[k + 1]) * t
        }

        guard let b = smoothing.denominator else {
            return grid.map(interpolatedDB)
        }

        let halfWidth = pow(2.0, 1.0 / (2 * b))
        var out = [Double](repeating: 0, count: grid.count)
        for (i, f) in grid.enumerated() {
            let lowHz = f / halfWidth
            let highHz = f * halfWidth
            let kLow = max(1, Int(ceil(lowHz / binHz)))
            let kHigh = min(bins - 1, Int(floor(highHz / binHz)))
            if kHigh < kLow {
                out[i] = interpolatedDB(f)
                continue
            }
            var sum = 0.0
            var weight = 0.0
            let span = log(halfWidth)
            for k in kLow...kHigh {
                let u = log(Double(k) * binHz / f) / span     // −1 ... +1 across the band
                let w = 0.5 * (1 + cos(Double.pi * min(1, abs(u))))
                sum += w * power[k]
                weight += w
            }
            out[i] = weight > 0 ? powerDB(sum / weight) : interpolatedDB(f)
        }
        return out
    }

    // MARK: - Averaging runs

    /// Complex average of several runs, with a run-to-run agreement number.
    ///
    /// Complex, not magnitude: averaging magnitudes would keep the noise (it adds power), while
    /// averaging the complex responses cancels it, 3 dB per doubling of runs. That only works
    /// if the runs line up, so each response is first shifted onto the first one by a fractional
    /// delay taken from the peak of their cross-correlation — an integer alignment leaves a
    /// phase ramp that eats the top octave.
    ///
    /// - Returns: the averaged response; the per-grid-point standard deviation of the individual
    ///   runs about it, in dB; and the mean of that over 100 Hz ... 10 kHz as one number for the
    ///   UI. One run gives zeros — no agreement can be measured from a single run.
    public static func average(
        _ runs: [ComplexResponse],
        grid: [Double] = SweepAnalysis.standardGrid,
        smoothing: OctaveSmoothing = .twelfth
    ) -> (mean: ComplexResponse, spreadDB: [Double], agreementDB: Double) {
        precondition(!runs.isEmpty, "average needs at least one run")
        let first = runs[0]
        guard runs.count > 1 else {
            return (first, [Double](repeating: 0, count: grid.count), 0)
        }

        let n = first.spectrum.n
        let fs = first.sampleRate
        var aligned: [HalfSpectrum] = [first.spectrum]
        let fft = RealFFT(count: n)
        for run in runs.dropFirst() {
            precondition(run.spectrum.n == n, "runs must share an FFT length")
            aligned.append(alignPhase(run.spectrum, to: first.spectrum, fft: fft))
        }

        var mean = HalfSpectrum(n: n)
        let scale = 1.0 / Double(aligned.count)
        for s in aligned {
            for k in 0..<mean.binCount {
                mean.real[k] += s.real[k] * scale
                mean.imag[k] += s.imag[k] * scale
            }
        }
        let meanResponse = ComplexResponse(spectrum: mean, sampleRate: fs)

        // Spread: how far each run's smoothed magnitude sits from the average.
        let meanDB = meanResponse.magnitudeDB(onGrid: grid, smoothing: smoothing)
        var spread = [Double](repeating: 0, count: grid.count)
        for s in aligned {
            let db = smoothedMagnitudeDB(s, sampleRate: fs, grid: grid, smoothing: smoothing)
            for i in 0..<grid.count {
                let d = db[i] - meanDB[i]
                spread[i] += d * d
            }
        }
        let divisor = Double(aligned.count)
        for i in 0..<grid.count { spread[i] = (spread[i] / divisor).squareRoot() }

        var sum = 0.0
        var used = 0
        for (i, f) in grid.enumerated() where f >= 100 && f <= 10_000 {
            sum += spread[i]
            used += 1
        }
        return (meanResponse, spread, used > 0 ? sum / Double(used) : 0)
    }

    /// Shift `s` onto `reference` by the fractional delay between them.
    private static func alignPhase(_ s: HalfSpectrum, to reference: HalfSpectrum, fft: RealFFT) -> HalfSpectrum {
        let n = s.n
        var cross = HalfSpectrum(n: n)
        for k in 0..<cross.binCount {
            cross.real[k] = s.real[k] * reference.real[k] + s.imag[k] * reference.imag[k]
            cross.imag[k] = s.imag[k] * reference.real[k] - s.real[k] * reference.imag[k]
        }
        let correlation = fft.inverse(cross)
        let peak = peakIndex(correlation)
        var tau = parabolicPeakOffset(correlation, around: peak)
        if tau > Double(n / 2) { tau -= Double(n) }        // negative lags wrap round
        guard abs(tau) > 1e-6 else { return s }

        var out = HalfSpectrum(n: n)
        for k in 0..<out.binCount {
            let phase = -2 * Double.pi * Double(k) * tau / Double(n)
            let c = cos(phase), sn = sin(phase)
            out.real[k] = s.real[k] * c - s.imag[k] * sn
            out.imag[k] = s.real[k] * sn + s.imag[k] * c
        }
        return out
    }

    // MARK: - Signal to noise

    /// The noise floor of a deconvolved noise-only recording, as a magnitude spectrum, measured
    /// with the same window the response was measured with.
    ///
    /// One window of one noise recording is a terrible estimate of a noise floor: a 1/12-octave
    /// band at 140 Hz holds about one independent sample of a 100 ms window, so the number swings
    /// by ten decibels from run to run. So the buffer is chopped into `segments` windows and
    /// their **powers** are averaged, the way Welch's method does it. Sixteen segments bring the
    /// swing down to a couple of decibels, which is the difference between a signal-to-noise
    /// read-out the user can act on and one that just looks unstable.
    ///
    /// Phase is discarded: a noise floor has none worth keeping.
    public static func noiseFloorResponse(
        deconvolvedNoise noise: [Double],
        sampleRate: Double,
        preSamples: Int,
        postSamples: Int,
        usableSamples: Int,
        segments: Int = 32,
        options: Options = Options()
    ) -> ComplexResponse {
        let length = preSamples + postSamples
        let usable = max(length, min(usableSamples, noise.count))
        // Spread the segments evenly over whatever noise there is, overlapping when it is short.
        let available = max(1, (usable - length) / max(length / 2, 1) + 1)
        let count = max(1, min(segments, available))
        let stride = count > 1 ? (usable - length) / (count - 1) : 0

        let ir = ImpulseResponse(
            samples: noise,
            sampleRate: sampleRate,
            peakIndex: 0,
            peakSubSample: 0,
            noiseFloorDBRelativePeak: 0,
            harmonicOffsetSamples: [:]
        )
        var power: [Double] = []
        for segment in 0..<count {
            let windowed = window(
                ir,
                preSamples: preSamples,
                postSamples: postSamples,
                fadeFraction: options.postWindowFadeFraction,
                centre: segment * stride + preSamples
            )
            let spectrum = complexResponse(windowed, options: options).spectrum
            if power.isEmpty { power = [Double](repeating: 0, count: spectrum.binCount) }
            for k in 0..<spectrum.binCount { power[k] += spectrum.power(k) }
        }

        let size = max(nextPowerOfTwo(options.responseFFTSize), nextPowerOfTwo(length))
        var mean = HalfSpectrum(n: size)
        for k in 0..<min(power.count, mean.binCount) {
            mean.real[k] = (power[k] / Double(count)).squareRoot()
        }
        return ComplexResponse(spectrum: mean, sampleRate: sampleRate)
    }

    /// Per-band signal-to-noise ratio in dB: the measured response over the measured noise floor.
    ///
    /// Both sides are the energy in one analysis window, through the same deconvolution and the
    /// same window, so there is no length correction to make and the sweep's processing gain is
    /// already in the number. The noise recording does have to be about as long as the sweep:
    /// the regularized inverse is a sweep-length filter, and a short burst of noise comes out of
    /// it thinner than noise that ran under the whole measurement. `HeadphoneMeasurement` warns
    /// when it is short.
    public static func signalToNoiseDB(
        signal: ComplexResponse,
        noise: ComplexResponse,
        grid: [Double] = SweepAnalysis.standardGrid,
        smoothing: OctaveSmoothing = .twelfth
    ) -> [Double] {
        let s = signal.magnitudeDB(onGrid: grid, smoothing: smoothing)
        // The noise floor is always read at a third of an octave, whatever the response is
        // smoothed at. A room's noise floor is a broad thing, and a wider band is a steadier
        // estimate of it; reading it at 1/12 octave would only add scatter to a number whose
        // whole job is to tell the user which parts of the curve to believe.
        let n = noise.magnitudeDB(onGrid: grid, smoothing: .third)
        return zip(s, n).map(-)
    }

    // MARK: - Distortion

    /// Total harmonic distortion from the 2nd and 3rd harmonic impulse responses.
    ///
    /// The ESS puts the n-th harmonic `L·ln(n)` seconds before the linear impulse, rotated by a
    /// constant phase but otherwise the same shape, so the energy ratio of the two windows is
    /// the harmonic amplitude ratio. Two corrections are applied and both are visible in the
    /// result: each harmonic is measured over only the part of the band whose harmonic still
    /// fits under the sweep's end frequency (`bandCoverage`), and the harmonic windows are
    /// symmetric because the phase rotation spreads energy both ways.
    ///
    /// This is a **quality number**, not a distortion measurement: it is one figure for the
    /// whole band, it includes whatever the amplifier and the microphone contributed, and it
    /// says nothing about where in the band the distortion was.
    public static func harmonicDistortion(
        _ ir: ImpulseResponse,
        sweep: SweepSignal,
        options: Options = Options()
    ) -> HarmonicDistortion {
        guard sweep.kind == .exponentialSweep else { return .none }
        let n = ir.samples.count
        let fs = ir.sampleRate
        let pre = max(1, Int(options.preWindowSeconds * fs))
        let post = min(Int(options.minimumPostWindowSeconds * fs), n / 8)
        let half = max(pre, post)

        let fundamental = symmetricEnergy(ir.samples, centre: ir.peakIndex, halfWidth: half)
        guard fundamental > 0 else { return .none }

        var perHarmonic: [Int: Double] = [:]
        var coverage: [Int: Double] = [:]
        var total = 0.0
        for order in [2, 3] {
            guard let offset = ir.harmonicOffsetSamples[order], offset > half else { continue }
            let cover = sweep.harmonicBandCoverage(order)
            guard cover > 0.05 else { continue }
            let energy = symmetricEnergy(ir.samples, centre: ir.peakIndex - offset, halfWidth: half) / cover
            let ratio = (energy / fundamental).squareRoot()
            perHarmonic[order] = ratio * 100
            coverage[order] = cover
            total += energy
        }
        return HarmonicDistortion(
            totalPercent: (total / fundamental).squareRoot() * 100,
            perHarmonicPercent: perHarmonic,
            bandCoverage: coverage
        )
    }

    private static func symmetricEnergy(_ x: [Double], centre: Int, halfWidth: Int) -> Double {
        let n = x.count
        var sum = 0.0
        let fade = max(1, halfWidth / 4)
        for i in -halfWidth...halfWidth {
            let v = x[cyclicIndex(centre + i, n)]
            var w = 1.0
            let edge = halfWidth - abs(i)
            if edge < fade {
                w = 0.5 * (1 + cos(Double.pi * Double(fade - edge) / Double(fade)))
            }
            sum += (v * w) * (v * w)
        }
        return sum
    }
}

// MARK: - Deconvolver

/// Holds the FFT plan and the regularized inverse of one sweep, so that averaging N runs does
/// not redo work that only depends on the stimulus.
///
/// One instance is one length. Not thread safe (it owns an `FFTSetupD`).
final class SweepDeconvolver {
    let length: Int
    let sampleRate: Double
    private let fft: RealFFT
    private let sweep: SweepSignal
    /// `conj(S) / (|S|² + ε)`.
    private var kernel: HalfSpectrum

    init(sweep: SweepSignal, recordedCount: Int, options: SweepAnalysis.Options) {
        self.length = nextPowerOfTwo(max(recordedCount, sweep.samples.count) + 1)
        self.sampleRate = sweep.sampleRate
        self.sweep = sweep
        self.fft = RealFFT(count: length)

        let s = fft.forward(sweep.samples)
        let binHz = sampleRate / Double(length)
        let ramp = pow(2.0, options.regularizationRampOctaves / 2)
        let innerLow = sweep.startHz * ramp
        let innerHigh = sweep.endHz / ramp
        let outerLow = sweep.startHz / ramp
        let outerHigh = sweep.endHz * ramp

        // Mean in-band power is the reference ε is stated against.
        var sum = 0.0
        var used = 0
        for k in 1..<s.binCount {
            let f = Double(k) * binHz
            if f >= innerLow && f <= innerHigh {
                sum += s.power(k)
                used += 1
            }
        }
        let reference = used > 0 ? sum / Double(used) : 1

        var kernel = HalfSpectrum(n: length)
        for k in 0..<s.binCount {
            let f = Double(k) * binHz
            let shapeDB = SweepDeconvolver.regularizationDB(
                atHz: f,
                outerLow: outerLow, innerLow: innerLow,
                innerHigh: innerHigh, outerHigh: outerHigh,
                inBandDB: options.inBandRegularizationDB,
                outOfBandDB: options.outOfBandRegularizationDB
            )
            let epsilon = reference * pow(10, shapeDB / 10)
            let denominator = s.power(k) + epsilon
            guard denominator > 0 else { continue }
            kernel.real[k] = s.real[k] / denominator
            kernel.imag[k] = -s.imag[k] / denominator
        }
        self.kernel = kernel
    }

    /// Raised-cosine ramp, in dB, between the in-band and out-of-band regularization.
    static func regularizationDB(
        atHz f: Double,
        outerLow: Double, innerLow: Double, innerHigh: Double, outerHigh: Double,
        inBandDB: Double, outOfBandDB: Double
    ) -> Double {
        if f >= innerLow && f <= innerHigh { return inBandDB }
        if f <= outerLow || f >= outerHigh { return outOfBandDB }
        let t: Double
        if f < innerLow {
            t = log(f / outerLow) / log(innerLow / outerLow)
        } else {
            t = log(outerHigh / f) / log(outerHigh / innerHigh)
        }
        let blend = 0.5 * (1 - cos(Double.pi * min(max(t, 0), 1)))
        return outOfBandDB + (inBandDB - outOfBandDB) * blend
    }

    /// Deconvolve a recording into an impulse response.
    func impulseResponse(of recorded: [Double]) -> SweepAnalysis.ImpulseResponse {
        let h = deconvolve(recorded)
        let peak = peakIndex(h)
        var offsets: [Int: Int] = [:]
        for order in [2, 3, 4, 5] {
            let samples = Int((sweep.harmonicTimeOffsetSeconds(order) * sampleRate).rounded())
            if samples > 0 { offsets[order] = samples }
        }
        let floor = noiseFloorRMS(h, peak: peak, sampleRate: sampleRate, harmonics: offsets)
        let peakValue = abs(h[peak])
        return SweepAnalysis.ImpulseResponse(
            samples: h,
            sampleRate: sampleRate,
            peakIndex: peak,
            peakSubSample: parabolicPeakOffset(h, around: peak),
            noiseFloorDBRelativePeak: peakValue > 0 ? amplitudeDB(floor / peakValue) : 0,
            harmonicOffsetSamples: offsets
        )
    }

    /// The raw deconvolution, without any peak finding.
    func deconvolve(_ recorded: [Double]) -> [Double] {
        let r = fft.forward(recorded)
        var product = HalfSpectrum(n: length)
        for k in 0..<product.binCount {
            product.real[k] = r.real[k] * kernel.real[k] - r.imag[k] * kernel.imag[k]
            product.imag[k] = r.real[k] * kernel.imag[k] + r.imag[k] * kernel.real[k]
        }
        return fft.inverse(product)
    }
}

// MARK: - Shared helpers

/// Index into a cyclic buffer of length `n`.
func cyclicIndex(_ i: Int, _ n: Int) -> Int {
    let m = i % n
    return m < 0 ? m + n : m
}

/// RMS of the quiet stretch just before the impulse peak — noise, and nothing else.
///
/// The stretch ends 20 ms before the peak so that the impulse's own leading edge stays out, and
/// starts no further back than halfway to the 2nd harmonic so that distortion stays out too.
func noiseFloorRMS(_ x: [Double], peak: Int, sampleRate: Double, harmonics: [Int: Int]) -> Double {
    let n = x.count
    var gap = Int(0.020 * sampleRate)
    var span = Int(0.100 * sampleRate)
    if let h2 = harmonics[2], h2 > 16 {
        gap = min(gap, h2 / 8)
        span = min(span, h2 / 2 - gap)
    }
    guard span > 8 else { return 0 }
    var sum = 0.0
    for i in 0..<span {
        let v = x[cyclicIndex(peak - gap - span + i, n)]
        sum += v * v
    }
    return (sum / Double(span)).squareRoot()
}
