import Foundation
import XCTest
@testable import JoseonHeadphones

// The whole measurement chain, simulated in code. Nothing here opens a device, plays a sound or
// records anything: a "microphone" is a transfer function and a "recording" is an array.
//
//     sweep → distortion → headphone → interface gain → clock drift → delay → microphone → noise
//
// Every stage has a closed form, so every test compares against a truth it computed rather than
// against another run of the same code.

// MARK: - Biquads

/// One RBJ-cookbook biquad. `process` is the real filter; `responseDB` is its exact magnitude.
struct Biquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    static func highPass(hz: Double, q: Double, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * hz / sampleRate
        let alpha = sin(w) / (2 * q)
        let cosw = cos(w)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 + cosw) / 2 / a0,
            b1: -(1 + cosw) / a0,
            b2: (1 + cosw) / 2 / a0,
            a1: -2 * cosw / a0,
            a2: (1 - alpha) / a0
        )
    }

    /// A **first-order** high-pass, by bilinear transform of `s / (s + ω₀)`.
    ///
    ///     K = tan(π·f₀/fs),  b₀ = 1/(1+K),  b₁ = −1/(1+K),  a₁ = (K−1)/(1+K)
    ///
    /// This is the shape a seal leak has: 6 dB per octave, no resonance. `responseDB` handles it
    /// because `b₂` and `a₂` are simply zero.
    static func firstOrderHighPass(hz: Double, sampleRate: Double) -> Biquad {
        let k = tan(Double.pi * hz / sampleRate)
        return Biquad(b0: 1 / (1 + k), b1: -1 / (1 + k), b2: 0, a1: (k - 1) / (1 + k), a2: 0)
    }

    static func peaking(hz: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w = 2 * Double.pi * hz / sampleRate
        let alpha = sin(w) / (2 * q)
        let cosw = cos(w)
        let a0 = 1 + alpha / a
        return Biquad(
            b0: (1 + alpha * a) / a0,
            b1: -2 * cosw / a0,
            b2: (1 - alpha * a) / a0,
            a1: -2 * cosw / a0,
            a2: (1 - alpha / a) / a0
        )
    }

    /// Exact magnitude in dB at one frequency.
    func responseDB(atHz hz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        let (cw, sw) = (cos(w), sin(w))
        let (c2w, s2w) = (cos(2 * w), sin(2 * w))
        let numeratorRe = b0 + b1 * cw + b2 * c2w
        let numeratorIm = -(b1 * sw + b2 * s2w)
        let denominatorRe = 1 + a1 * cw + a2 * c2w
        let denominatorIm = -(a1 * sw + a2 * s2w)
        let numerator = (numeratorRe * numeratorRe + numeratorIm * numeratorIm).squareRoot()
        let denominator = (denominatorRe * denominatorRe + denominatorIm * denominatorIm).squareRoot()
        guard denominator > 0 else { return 0 }
        return 20 * log10(numerator / denominator)
    }
}

struct FilterCascade {
    var stages: [Biquad]
    var sampleRate: Double

    /// The headphone under test: bass roll-off, +6 dB at 3 kHz, −8 dB at 8 kHz.
    static func headphone(sampleRate: Double) -> FilterCascade {
        FilterCascade(stages: [
            .highPass(hz: 35, q: 0.707, sampleRate: sampleRate),
            .peaking(hz: 3_000, gainDB: 6, q: 2, sampleRate: sampleRate),
            .peaking(hz: 8_000, gainDB: -8, q: 3, sampleRate: sampleRate),
        ], sampleRate: sampleRate)
    }

    func process(_ x: [Double]) -> [Double] {
        var y = x
        for stage in stages {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<y.count {
                let input = y[i]
                let output = stage.b0 * input + stage.b1 * x1 + stage.b2 * x2 - stage.a1 * y1 - stage.a2 * y2
                x2 = x1; x1 = input
                y2 = y1; y1 = output
                y[i] = output
            }
        }
        return y
    }

    func responseDB(atHz hz: Double) -> Double {
        stages.reduce(0) { $0 + $1.responseDB(atHz: hz, sampleRate: sampleRate) }
    }

    func responseDB(onGrid grid: [Double]) -> [Double] { grid.map(responseDB(atHz:)) }
}

// MARK: - The simulated chain

struct SimulatedChain {
    var sampleRate: Double = 48_000
    var headphone: FilterCascade
    /// Points of the microphone's own response, in dB. Applied zero-phase, the way a magnitude
    /// calibration file describes it.
    var micCurve: [(hz: Double, db: Double)] = []
    /// Delay between playing and recording, in samples.
    var delaySamples: Int = 3_733
    var tailSamples: Int = 6_000
    /// Broadband signal-to-noise ratio of the recording, in dB. `nil` for a silent room.
    var snrDB: Double?
    /// Injected 2nd and 3rd harmonic, as a ratio of the fundamental (0.01 = 1 %).
    var secondHarmonic: Double = 0
    var thirdHarmonic: Double = 0
    /// Clock difference between the two devices, in parts per million.
    var driftPPM: Double = 0
    /// Everything linear between the headphone terminals and the samples: volts per pascal,
    /// interface gain, the lot.
    var gain: Double = 1
    var seed: UInt64 = 0xC0FFEE

    /// The microphone response as the module's interpolator sees it, so that a test's tilt and
    /// the parsed calibration file are the same function of frequency.
    var micCalibrationCurve: HeadphoneCurve {
        HeadphoneCurve(
            name: "Test microphone",
            source: "simulated",
            frequenciesHz: micCurve.map { Float($0.hz) },
            levelsDB: micCurve.map { Float($0.db) }
        )
    }

    /// The exact magnitude of everything the analysis should recover, in dB, including the
    /// interface gain and the microphone.
    func trueResponseDB(onGrid grid: [Double], includeMic: Bool) -> [Double] {
        let gainDB = 20 * log10(gain)
        var out = grid.map { headphone.responseDB(atHz: $0) + gainDB }
        if includeMic, !micCurve.isEmpty {
            let mic = CurveInterpolator(curve: micCalibrationCurve)
            for i in 0..<out.count { out[i] += Double(mic.level(atHz: Float(grid[i]))) }
        }
        return out
    }

    /// Record one run of `sweep`.
    func record(_ sweep: SweepSignal) -> [Double] {
        var x = sweep.samples

        // Memoryless distortion on the drive signal (a Hammerstein driver).
        if secondHarmonic != 0 || thirdHarmonic != 0 {
            x = distort(
                x,
                amplitude: pow(10, sweep.levelDBFS / 20),
                secondHarmonic: secondHarmonic,
                thirdHarmonic: thirdHarmonic
            )
        }

        x = headphone.process(x)
        if gain != 1 { for i in 0..<x.count { x[i] *= gain } }
        if driftPPM != 0 { x = resample(x, ratio: 1 + driftPPM * 1e-6) }

        var recording = [Double](repeating: 0, count: delaySamples + x.count + tailSamples)
        for i in 0..<x.count { recording[delaySamples + i] = x[i] }

        if !micCurve.isEmpty {
            recording = applyZeroPhaseCurve(recording, curve: micCalibrationCurve, sampleRate: sampleRate)
        }
        if let snrDB {
            let signalRMS = x.rms
            let noise = pinkNoise(count: recording.count, rms: signalRMS * pow(10, -snrDB / 20), seed: seed &+ 7)
            for i in 0..<recording.count { recording[i] += noise[i] }
        }
        return recording
    }

    /// A recording of the same room with nothing playing, the same length as `record` makes.
    func silence(_ sweep: SweepSignal, seed extra: UInt64 = 99) -> [Double] {
        let count = delaySamples + sweep.samples.count + tailSamples
        guard let snrDB else { return [Double](repeating: 0, count: count) }
        var x = headphone.process(sweep.samples)
        if gain != 1 { for i in 0..<x.count { x[i] *= gain } }
        return pinkNoise(count: count, rms: x.rms * pow(10, -snrDB / 20), seed: seed &+ extra)
    }
}

// MARK: - Signal helpers

/// Add a known amount of 2nd and 3rd harmonic, band limited the way a real chain is.
///
/// Two things have to be right or the test measures the simulation rather than the analysis.
///
/// 1. **No aliasing.** The cubic term of a sweep that reaches 20 kHz puts products at 60 kHz.
///    In a real chain the microphone preamp and the converter's filter throw those away; in a
///    plain `v*v*v` at 48 kHz they fold back into the audio band as a descending chirp that
///    smears across the whole impulse response. So the polynomial runs at four times the rate
///    and the result is brick-wall filtered back down, which is what an anti-aliasing filter
///    does.
/// 2. **No change to the fundamental.** `v³` contains `3/4·v` as well as the third harmonic, so
///    a naive cubic raises the whole response by 20·log₁₀(1 + 3·d₃) — half a decibel at 2 %.
///    That term is subtracted, so the linear gain of this chain is exactly 1 and a test of
///    harmonic leakage measures leakage.
func distort(_ x: [Double], amplitude: Double, secondHarmonic d2: Double, thirdHarmonic d3: Double) -> [Double] {
    let n = nextPowerOfTwo(x.count)
    let up = 4 * n
    let fine = RealFFT(count: up)
    let coarse = RealFFT(count: n)

    var upSpectrum = HalfSpectrum(n: up)
    let spectrum = coarse.forward(x)
    for k in 0..<spectrum.binCount {
        upSpectrum.real[k] = spectrum.real[k] * 4
        upSpectrum.imag[k] = spectrum.imag[k] * 4
    }
    var y = fine.inverse(upSpectrum)

    let a2 = 2 * d2 / amplitude
    let a3 = 4 * d3 / (amplitude * amplitude)
    for i in 0..<y.count {
        let v = y[i]
        y[i] = v + a2 * v * v + a3 * v * v * v - 3 * d3 * v
    }

    let filtered = fine.forward(y)
    var downSpectrum = HalfSpectrum(n: n)
    for k in 0..<downSpectrum.binCount {
        downSpectrum.real[k] = filtered.real[k] * 0.25
        downSpectrum.imag[k] = filtered.imag[k] * 0.25
    }
    downSpectrum.imag[downSpectrum.binCount - 1] = 0
    return Array(coarse.inverse(downSpectrum)[0..<x.count])
}

/// Pink noise (power ∝ 1/f) with a given RMS, from a seeded generator.
func pinkNoise(count: Int, rms: Double, seed: UInt64) -> [Double] {
    guard count > 0, rms > 0 else { return [Double](repeating: 0, count: max(count, 0)) }
    let n = nextPowerOfTwo(count)
    var spectrum = HalfSpectrum(n: n)
    var rng = SplitMix64(seed: seed)
    for k in 1..<spectrum.binCount {
        let magnitude = 1 / Double(k).squareRoot()
        let phase = 2 * Double.pi * rng.nextUnit()
        spectrum.real[k] = magnitude * cos(phase)
        spectrum.imag[k] = magnitude * sin(phase)
    }
    spectrum.imag[spectrum.binCount - 1] = 0
    var x = RealFFT(count: n).inverse(spectrum)
    let current = x.rms
    guard current > 0 else { return Array(x[0..<count]) }
    let scale = rms / current
    for i in 0..<n { x[i] *= scale }
    return Array(x[0..<count])
}

/// Resample by a tiny ratio with a 32-tap Blackman-windowed sinc — clock drift, without the
/// high-frequency loss a linear interpolator would add on top of it.
func resample(_ x: [Double], ratio: Double) -> [Double] {
    let taps = 32
    let half = taps / 2
    let outCount = Int(Double(x.count) / ratio)
    var out = [Double](repeating: 0, count: outCount)
    for n in 0..<outCount {
        let position = Double(n) * ratio
        let base = Int(position.rounded(.down))
        let fraction = position - Double(base)
        var sum = 0.0
        for t in (-half + 1)...half {
            let index = base + t
            guard index >= 0, index < x.count else { continue }
            let d = Double(t) - fraction
            let sincValue = abs(d) < 1e-12 ? 1 : sin(Double.pi * d) / (Double.pi * d)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * (Double(t + half) + 0.5 - fraction) / Double(taps))
                + 0.08 * cos(4 * Double.pi * (Double(t + half) + 0.5 - fraction) / Double(taps))
            sum += x[index] * sincValue * w
        }
        out[n] = sum
    }
    return out
}

/// Multiply a buffer by a magnitude curve with zero phase — how a magnitude-only calibration
/// describes a microphone. Cyclic, and the buffer has silence at both ends, so nothing wraps
/// into the signal.
func applyZeroPhaseCurve(_ x: [Double], curve: HeadphoneCurve, sampleRate: Double) -> [Double] {
    let n = nextPowerOfTwo(x.count)
    let fft = RealFFT(count: n)
    var spectrum = fft.forward(x)
    let interpolator = CurveInterpolator(curve: curve)
    let binHz = sampleRate / Double(n)
    for k in 0..<spectrum.binCount {
        let f = max(Double(k) * binHz, 1e-6)
        let gain = pow(10, Double(interpolator.level(atHz: Float(f))) / 20)
        spectrum.real[k] *= gain
        spectrum.imag[k] *= gain
    }
    return Array(fft.inverse(spectrum)[0..<x.count])
}

// MARK: - Assertions

/// Largest absolute difference between two curves over a frequency range, and where it happened.
func worstDifference(
    _ a: [Double],
    _ b: [Double],
    onGrid grid: [Double],
    from lowHz: Double,
    to highHz: Double
) -> (dB: Double, hz: Double) {
    var worst = 0.0
    var where_ = 0.0
    for (i, f) in grid.enumerated() where f >= lowHz && f <= highHz {
        let d = abs(a[i] - b[i])
        if d > worst { worst = d; where_ = f }
    }
    return (worst, where_)
}

/// Mean of a curve over a frequency range.
func mean(_ values: [Double], onGrid grid: [Double], from lowHz: Double, to highHz: Double) -> Double {
    var sum = 0.0
    var used = 0
    for (i, f) in grid.enumerated() where f >= lowHz && f <= highHz {
        sum += values[i]
        used += 1
    }
    return used > 0 ? sum / Double(used) : 0
}

/// Shift a curve so that its mean over 800–1250 Hz is 0 dB — the module's normalization.
func normalizedTo1kHz(_ values: [Double], onGrid grid: [Double]) -> [Double] {
    let reference = mean(values, onGrid: grid, from: 800, to: 1250)
    return values.map { $0 - reference }
}

extension XCTestCase {
    /// Report the number, then assert on it. A test that prints its accuracy is a test whose
    /// limits can be read off the log instead of guessed at.
    func expect(
        _ value: Double,
        atMost limit: Double,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        print(String(format: "  %@: %.3f (limit %.3f)", label, value, limit))
        XCTAssertLessThanOrEqual(value, limit, label, file: file, line: line)
    }
}
