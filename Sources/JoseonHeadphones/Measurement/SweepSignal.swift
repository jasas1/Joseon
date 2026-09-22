import Foundation

/// A measurement stimulus: the samples to play, and everything the analysis needs to know
/// about how they were made.
///
/// Two kinds:
///
/// - `.exponentialSweep` — Farina's exponential sine sweep (ESS). The instantaneous frequency
///   rises geometrically, so every octave gets the same energy and the harmonic distortion
///   products land at *earlier* times in the deconvolved impulse response, where a window can
///   throw them away. This is the one to use.
/// - `.periodicPinkNoise` — one exact period of pink noise. Playing it back to back lets the
///   app average synchronously without any alignment, which is handy for a long unattended
///   run, but the crest factor costs about 9 dB of signal-to-noise against a sweep at the same
///   peak level, and distortion cannot be separated out at all.
///
/// Nothing here plays anything. `samples` is an array; making sound is the app's job, after
/// the user presses a button that says it will.
public struct SweepSignal: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable {
        case exponentialSweep
        case periodicPinkNoise
    }

    public let kind: Kind
    public let sampleRate: Double
    /// First frequency of the sweep, or the low edge of the noise band.
    public let startHz: Double
    /// Last frequency of the sweep, or the high edge of the noise band. Always under Nyquist.
    public let endHz: Double
    public let durationSeconds: Double
    /// Peak level of the stimulus in dBFS (a 0 dBFS signal touches ±1.0).
    public let levelDBFS: Double
    /// The signal itself.
    public let samples: [Double]
    /// Length of the raised-cosine fade at the start, in seconds. 0 for pink noise.
    public let fadeInSeconds: Double
    /// Length of the raised-cosine fade at the end, in seconds. 0 for pink noise.
    ///
    /// It matters more than it looks: on an exponential sweep the fade-out sits on the **top**
    /// frequencies, so the last fraction of an octave is driven at less than full level. See
    /// `highestFullEnergyHz`.
    public let fadeOutSeconds: Double

    /// Shortest and longest sweep the factory will make. Under 2 s the signal-to-noise ratio in
    /// the bass falls apart; over 10 s the room and the clocks drift more than the sweep gains.
    public static let durationRangeSeconds: ClosedRange<Double> = 2...10

    init(
        kind: Kind,
        sampleRate: Double,
        startHz: Double,
        endHz: Double,
        durationSeconds: Double,
        levelDBFS: Double,
        samples: [Double],
        fadeInSeconds: Double = 0,
        fadeOutSeconds: Double = 0
    ) {
        self.kind = kind
        self.sampleRate = sampleRate
        self.startHz = startHz
        self.endHz = endHz
        self.durationSeconds = durationSeconds
        self.levelDBFS = levelDBFS
        self.samples = samples
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
    }

    // MARK: - Where the stimulus stops

    /// The highest frequency this stimulus drove at **full** level, under the Nyquist clamp.
    ///
    /// For an exponential sweep the instantaneous frequency is `f₁·e^(t/L)`, so the fade-out — the
    /// last `fadeOutSeconds` of the sweep — covers the top `L·ln` worth of the band:
    ///
    ///     highestFullEnergyHz = f₂ · e^(−fadeOut / L)
    ///
    /// A 5 s 20 Hz–20 kHz sweep with a 20 ms fade-out stops driving at full level at 19.45 kHz,
    /// and a 3 s one at 19.10 kHz. Above that the deconvolution is dividing by a spectrum the
    /// fade took away, which is exactly where a measured curve grows a hook at the top of the
    /// log grid. `HeadphoneMeasurement` holds the curve flat above this frequency and reports it
    /// as `MeasurementQuality.highestReliableHz`.
    ///
    /// Pink noise has no fade: its band simply ends at `endHz`.
    public var highestFullEnergyHz: Double {
        let nyquist = sampleRate / 2
        switch kind {
        case .exponentialSweep:
            let rate = sweepRateSeconds
            guard rate > 0, fadeOutSeconds > 0 else { return min(endHz, nyquist) }
            return min(endHz * exp(-fadeOutSeconds / rate), endHz, nyquist)
        case .periodicPinkNoise:
            return min(endHz, nyquist)
        }
    }

    // MARK: - Exponential sine sweep

    /// Farina exponential sine sweep with raised-cosine fades.
    ///
    ///     x(t) = sin( ω₁·L·( e^(t/L) − 1 ) ),   L = T / ln(ω₂/ω₁)
    ///
    /// `endHz` is clamped to 95 % of Nyquist and `seconds` to `durationRangeSeconds`, so the
    /// caller can pass a user's numbers straight through.
    ///
    /// The fades are deliberately short (10 ms in, 20 ms out by default). They do not bias the
    /// result: `SweepAnalysis` divides by the spectrum of *these* samples, fades included.
    ///
    /// - Parameter levelDBFS: peak level. −6 dBFS leaves headroom for the interface and is the
    ///   default; the app should run a level check at −30 dBFS first.
    public static func exponentialSweep(
        sampleRate: Double,
        startHz: Double = 20,
        endHz: Double = 20_000,
        seconds: Double = 5,
        levelDBFS: Double = -6,
        fadeInSeconds: Double = 0.010,
        fadeOutSeconds: Double = 0.020
    ) -> SweepSignal {
        let f1 = max(1.0, min(startHz, sampleRate * 0.4))
        let f2 = max(f1 * 1.5, min(endHz, sampleRate * 0.5 * 0.95))
        let duration = min(max(seconds, durationRangeSeconds.lowerBound), durationRangeSeconds.upperBound)
        let count = max(16, Int((duration * sampleRate).rounded()))
        let amplitude = pow(10, levelDBFS / 20)

        let l = duration / log(f2 / f1)          // seconds per neper of frequency
        let k = 2 * Double.pi * f1 * l
        var x = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            x[i] = amplitude * sin(k * (exp(t / l) - 1))
        }
        applyFades(&x, sampleRate: sampleRate, fadeIn: fadeInSeconds, fadeOut: fadeOutSeconds)

        return SweepSignal(
            kind: .exponentialSweep,
            sampleRate: sampleRate,
            startHz: f1,
            endHz: f2,
            durationSeconds: Double(count) / sampleRate,
            levelDBFS: levelDBFS,
            samples: x,
            fadeInSeconds: max(0, fadeInSeconds),
            fadeOutSeconds: max(0, fadeOutSeconds)
        )
    }

    /// Seconds of sweep per neper of frequency: `T / ln(f₂/f₁)`.
    ///
    /// Everything about the ESS hangs off this number — it is how far back in time the
    /// harmonics land, and how fast the deconvolved response decorrelates from the noise.
    public var sweepRateSeconds: Double {
        guard kind == .exponentialSweep, endHz > startHz, startHz > 0 else { return 0 }
        return durationSeconds / log(endHz / startHz)
    }

    /// How far **before** the linear impulse response the `n`-th harmonic lands, in seconds.
    ///
    ///     Δt(n) = L · ln(n)
    ///
    /// Because `sin(n·φ(t)) = sin(φ(t + L·ln n) − ω₁L)`, the n-th harmonic of an ESS is the same
    /// sweep advanced in time by a constant. That is the whole trick: after deconvolution the
    /// distortion sits in its own place and a window rejects it.
    public func harmonicTimeOffsetSeconds(_ n: Int) -> Double {
        guard n >= 2 else { return 0 }
        return sweepRateSeconds * log(Double(n))
    }

    /// Fraction of the sweep's octaves whose `n`-th harmonic still fits under `endHz`.
    ///
    /// A 20 Hz–20 kHz sweep only produces a measurable 2nd harmonic for fundamentals under
    /// 10 kHz, so a tenth of the octaves contribute nothing to the 2nd-harmonic impulse
    /// response. `SweepAnalysis` divides the harmonic energy by this to undo the bias.
    public func harmonicBandCoverage(_ n: Int) -> Double {
        guard n >= 2, endHz > startHz, startHz > 0 else { return 1 }
        let usable = log(endHz / (Double(n) * startHz))
        guard usable > 0 else { return 0 }
        return min(1, usable / log(endHz / startHz))
    }

    /// Farina's inverse filter: the sweep reversed in time, with a −6 dB/octave envelope, scaled
    /// so that convolving it with the sweep gives unit gain through the swept band.
    ///
    /// `SweepAnalysis` does **not** use this — it divides by the measured sweep spectrum with a
    /// regularized inverse, which also takes out the fades and the band edges. This is here
    /// because the classic recipe is the one people check a measurement rig against, and
    /// because it needs no FFT of the recording at all. `nil` for pink noise, which has no
    /// time-domain inverse.
    public func inverseFilter() -> [Double]? {
        guard kind == .exponentialSweep else { return nil }
        let n = samples.count
        let l = sweepRateSeconds
        guard n > 0, l > 0 else { return nil }

        // The reversed sweep runs from f₂ down to f₁, and its own spectrum still falls at
        // −3 dB/octave. Flattening the product needs an envelope proportional to frequency,
        // which on the reversed time axis is a decay of exp(−τ/L) — one time constant per
        // neper of frequency, the classic 6 dB/octave.
        var f = [Double](repeating: 0, count: n)
        for j in 0..<n {
            f[j] = samples[n - 1 - j] * exp(-Double(j) / (sampleRate * l))
        }

        // Scale for unit magnitude through the band. Doing it numerically rather than from the
        // closed form keeps it honest about the fades and the clamped end frequency.
        let length = nextPowerOfTwo(2 * n)
        let fft = RealFFT(count: length)
        let x = fft.forward(samples)
        let fSpectrum = fft.forward(f)
        let lo = Int((startHz * pow(2, 1.0 / 3) * Double(length) / sampleRate).rounded())
        let hi = Int((endHz * pow(2, -1.0 / 3) * Double(length) / sampleRate).rounded())
        var sum = 0.0
        var used = 0
        if hi > lo {
            for k in lo...min(hi, x.binCount - 1) {
                let re = x.real[k] * fSpectrum.real[k] - x.imag[k] * fSpectrum.imag[k]
                let im = x.real[k] * fSpectrum.imag[k] + x.imag[k] * fSpectrum.real[k]
                sum += (re * re + im * im).squareRoot()
                used += 1
            }
        }
        guard used > 0, sum > 0 else { return f }
        let scale = Double(used) / sum
        for j in 0..<n { f[j] *= scale }
        return f
    }

    // MARK: - Periodic pink noise

    /// One exact period of pink noise, band limited to `startHz ... endHz`.
    ///
    /// The period is rounded **up to a power of two samples**, so the app can loop it and the
    /// analysis can average periods with no alignment step and no FFT length juggling.
    /// `durationSeconds` reports what that rounding produced.
    ///
    /// Built in the frequency domain: magnitude `1/√f` in band, raised-cosine edges over a third
    /// of an octave, and phases from a seeded generator, so a given `seed` always gives the same
    /// signal and a test can rely on it.
    public static func periodicPinkNoise(
        sampleRate: Double,
        seconds: Double = 4,
        levelDBFS: Double = -6,
        startHz: Double = 20,
        endHz: Double = 20_000,
        seed: UInt64 = 0x5EED_10AD
    ) -> SweepSignal {
        let f1 = max(1.0, min(startHz, sampleRate * 0.4))
        let f2 = max(f1 * 1.5, min(endHz, sampleRate * 0.5 * 0.95))
        let duration = min(max(seconds, durationRangeSeconds.lowerBound), durationRangeSeconds.upperBound)
        let n = nextPowerOfTwo(Int((duration * sampleRate).rounded()))

        var spectrum = HalfSpectrum(n: n)
        var rng = SplitMix64(seed: seed)
        let df = sampleRate / Double(n)
        let edge = pow(2.0, 1.0 / 3.0)
        for k in 1..<spectrum.binCount {
            let f = Double(k) * df
            var magnitude = 1 / f.squareRoot()          // pink: power ∝ 1/f
            if f < f1 {
                let u = log(f / (f1 / edge)) / log(edge)
                magnitude *= u <= 0 ? 0 : 0.5 * (1 - cos(Double.pi * min(1, u)))
            }
            if f > f2 {
                let u = log((f2 * edge) / f) / log(edge)
                magnitude *= u <= 0 ? 0 : 0.5 * (1 - cos(Double.pi * min(1, u)))
            }
            let phase = 2 * Double.pi * rng.nextUnit()
            spectrum.real[k] = magnitude * cos(phase)
            spectrum.imag[k] = magnitude * sin(phase)
        }
        spectrum.imag[spectrum.binCount - 1] = 0        // Nyquist must be real

        let fft = RealFFT(count: n)
        var x = fft.inverse(spectrum)
        let peak = x.reduce(0.0) { max($0, abs($1)) }
        let amplitude = pow(10, levelDBFS / 20)
        if peak > 0 {
            let scale = amplitude / peak
            for i in 0..<n { x[i] *= scale }
        }

        return SweepSignal(
            kind: .periodicPinkNoise,
            sampleRate: sampleRate,
            startHz: f1,
            endHz: f2,
            durationSeconds: Double(n) / sampleRate,
            levelDBFS: levelDBFS,
            samples: x
        )
    }

    /// Samples in one period. Only meaningful for `.periodicPinkNoise`.
    public var periodSamples: Int { samples.count }

    /// RMS of the stimulus in dBFS, where a full-scale sine reads −3.01.
    ///
    /// The gap between this and `levelDBFS` is the crest factor, and it is the honest way to
    /// compare a sweep with noise: at the same peak level the sweep delivers about 9 dB more
    /// energy to the headphone.
    public var rmsLevelDBFS: Double { amplitudeDB(samples.rms) }
}

// MARK: - Helpers

/// Raised-cosine fade in and out, in place.
private func applyFades(_ x: inout [Double], sampleRate: Double, fadeIn: Double, fadeOut: Double) {
    let n = x.count
    let inCount = min(max(0, Int(fadeIn * sampleRate)), n / 2)
    let outCount = min(max(0, Int(fadeOut * sampleRate)), n / 2)
    if inCount > 1 {
        for i in 0..<inCount {
            x[i] *= 0.5 * (1 - cos(Double.pi * Double(i) / Double(inCount - 1)))
        }
    }
    if outCount > 1 {
        for j in 0..<outCount {
            let i = n - 1 - j
            x[i] *= 0.5 * (1 - cos(Double.pi * Double(j) / Double(outCount - 1)))
        }
    }
}

/// Seeded generator, so "random" phases are reproducible in a test.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)`.
    mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Standard normal, Box–Muller.
    mutating func nextGaussian() -> Double {
        let u1 = max(nextUnit(), 1e-12)
        let u2 = nextUnit()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}
