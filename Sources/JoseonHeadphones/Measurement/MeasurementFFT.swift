import Accelerate
import Foundation

// Small numeric helpers shared by the measurement code. Everything here is `internal`:
// the public surface of `Measurement/**` is signals, curves and results, never a buffer
// in some packed FFT layout.

/// Smallest power of two that is at least `n`.
func nextPowerOfTwo(_ n: Int) -> Int {
    guard n > 1 else { return 1 }
    return 1 << (Int.bitWidth - (n - 1).leadingZeroBitCount)
}

/// One-sided spectrum of a real signal of length `n`: bins `0 ... n/2`, unpacked.
///
/// Accelerate's real FFT hides the Nyquist bin inside `imagp[0]` and scales everything by 2.
/// This type holds the plain mathematical values instead, so every line of DSP below reads
/// like the formula it implements. The unpacking costs one pass over the buffer.
struct HalfSpectrum {
    var real: [Double]
    var imag: [Double]
    let n: Int

    init(n: Int) {
        self.n = n
        self.real = [Double](repeating: 0, count: n / 2 + 1)
        self.imag = [Double](repeating: 0, count: n / 2 + 1)
    }

    var binCount: Int { n / 2 + 1 }

    /// Hz of bin `k` at `sampleRate`.
    func frequency(_ k: Int, sampleRate: Double) -> Double { Double(k) * sampleRate / Double(n) }

    func power(_ k: Int) -> Double { real[k] * real[k] + imag[k] * imag[k] }
    func magnitude(_ k: Int) -> Double { power(k).squareRoot() }
}

/// Real FFT over Accelerate, in `Double`.
///
/// Double, not Float: a 5 s sweep is a quarter of a million samples and the deconvolution
/// divides by a spectrum that spans 60 dB, so Float's 24-bit mantissa would show up in the
/// bass. One instance owns one `FFTSetupD` and two scratch buffers, so it is **not** thread
/// safe — make one per worker.
final class RealFFT {
    let n: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetupD
    private var realScratch: [Double]
    private var imagScratch: [Double]

    init(count n: Int) {
        precondition(n >= 4 && (n & (n - 1)) == 0, "FFT length must be a power of two, got \(n)")
        self.n = n
        self.log2n = vDSP_Length(63 - UInt64(n).leadingZeroBitCount)
        guard let setup = vDSP_create_fftsetupD(self.log2n, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("vDSP_create_fftsetupD failed for length \(n)")
        }
        self.setup = setup
        self.realScratch = [Double](repeating: 0, count: n / 2)
        self.imagScratch = [Double](repeating: 0, count: n / 2)
    }

    deinit { vDSP_destroy_fftsetupD(setup) }

    /// Forward transform of `x`, zero padded (or truncated) to `n`.
    func forward(_ x: [Double]) -> HalfSpectrum {
        var padded = x
        if padded.count < n {
            padded.append(contentsOf: repeatElement(0, count: n - padded.count))
        } else if padded.count > n {
            padded.removeLast(padded.count - n)
        }
        var out = HalfSpectrum(n: n)
        let half = n / 2
        realScratch.withUnsafeMutableBufferPointer { rp in
            imagScratch.withUnsafeMutableBufferPointer { ip in
                var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                padded.withUnsafeBufferPointer { xp in
                    xp.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) { cp in
                        vDSP_ctozD(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                // vDSP packs DC in realp[0], Nyquist in imagp[0], and scales by 2.
                out.real[0] = rp[0] * 0.5
                out.real[half] = ip[0] * 0.5
                for k in 1..<half {
                    out.real[k] = rp[k] * 0.5
                    out.imag[k] = ip[k] * 0.5
                }
            }
        }
        return out
    }

    /// Inverse transform back to a real signal of length `n`.
    func inverse(_ s: HalfSpectrum) -> [Double] {
        precondition(s.n == n, "spectrum length \(s.n) does not match this FFT (\(n))")
        var out = [Double](repeating: 0, count: n)
        let half = n / 2
        realScratch.withUnsafeMutableBufferPointer { rp in
            imagScratch.withUnsafeMutableBufferPointer { ip in
                rp[0] = s.real[0]
                ip[0] = s.real[half]
                for k in 1..<half {
                    rp[k] = s.real[k]
                    ip[k] = s.imag[k]
                }
                var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBufferPointer { op in
                    op.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: half) { cp in
                        vDSP_ztocD(&split, 1, cp, 2, vDSP_Length(half))
                    }
                }
            }
        }
        // The forward pass was un-scaled by 0.5 on the way out, so the round trip is N, not 2N.
        var scale = 1.0 / Double(n)
        vDSP_vsmulD(out, 1, &scale, &out, 1, vDSP_Length(n))
        return out
    }
}

// MARK: - Small array math

extension Array where Element == Double {
    /// Root mean square. Zero for an empty array.
    var rms: Double {
        guard !isEmpty else { return 0 }
        var sum = 0.0
        vDSP_svesqD(self, 1, &sum, vDSP_Length(count))
        return (sum / Double(count)).squareRoot()
    }
}

/// dB of an amplitude ratio, floored so that a silent band prints a number rather than `-inf`.
func amplitudeDB(_ amplitude: Double, floorDB: Double = -200) -> Double {
    let a = abs(amplitude)
    guard a > 0 else { return floorDB }
    return Swift.max(20 * log10(a), floorDB)
}

/// dB of a power ratio, floored the same way.
func powerDB(_ power: Double, floorDB: Double = -200) -> Double {
    guard power > 0 else { return floorDB }
    return Swift.max(10 * log10(power), floorDB)
}

/// Index of the largest `|x|`, or 0 for an empty array.
func peakIndex(_ x: [Double]) -> Int {
    var best = 0
    var bestValue = 0.0
    for (i, v) in x.enumerated() {
        let a = abs(v)
        if a > bestValue { bestValue = a; best = i }
    }
    return best
}

/// Sub-sample peak position around `i`, by fitting a parabola to `|x|` at `i-1, i, i+1`.
///
/// Returns `Double(i)` when the neighbours are missing or the fit is degenerate.
func parabolicPeakOffset(_ x: [Double], around i: Int) -> Double {
    guard i > 0, i + 1 < x.count else { return Double(i) }
    let a = abs(x[i - 1]), b = abs(x[i]), c = abs(x[i + 1])
    let denominator = a - 2 * b + c
    guard denominator != 0 else { return Double(i) }
    let delta = 0.5 * (a - c) / denominator
    guard delta.isFinite, abs(delta) <= 1 else { return Double(i) }
    return Double(i) + delta
}
