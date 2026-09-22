import Foundation

/// Inter-sample (true) peak detector.
///
/// The signal is oversampled with a polyphase FIR interpolator and the largest
/// absolute value on the fine grid is the true peak. BS.1770-4 Annex 2 prints a
/// 48-tap 4x filter; this one is a 64-tap windowed-sinc design (Kaiser, beta 9),
/// which is longer and flatter, so it meets "Annex 2 quality or better".
///
/// The prototype is centred on an integer tap, so phase 0 is exactly a unit
/// impulse. Two useful consequences: the reported true peak can never fall below
/// the sample peak, and no multiply is needed for that phase.
///
/// Measured against ideal sine reconstruction (see LoudnessTruePeakTests):
/// never over-reads; worst under-read is the 4x grid limit itself, about
/// -0.44 dB for a full-scale sine at 0.8 x Nyquist.
final class TruePeakDetector {
    /// Taps per polyphase branch. Must be even (phase 0 needs a centre tap).
    static let tapsPerPhase = 16
    static let kaiserBeta = 9.0
    /// Largest oversampling factor the coefficient store is sized for.
    static let maxFactor = 4

    private(set) var factor: Int = 0

    private let taps = TruePeakDetector.tapsPerPhase
    /// Reversed coefficients for phases 1 ..< factor. Phase 0 is the impulse.
    private let coefficients: UnsafeMutablePointer<Float>
    /// Doubled delay line so each branch reads one contiguous window.
    private let history: UnsafeMutablePointer<Float>
    private var cursor = 0

    init() {
        let coeffCount = (TruePeakDetector.maxFactor - 1) * TruePeakDetector.tapsPerPhase
        coefficients = .allocate(capacity: coeffCount)
        coefficients.initialize(repeating: 0, count: coeffCount)
        history = .allocate(capacity: 2 * TruePeakDetector.tapsPerPhase)
        history.initialize(repeating: 0, count: 2 * TruePeakDetector.tapsPerPhase)
        configure(factor: 4)
    }

    deinit {
        coefficients.deallocate()
        history.deallocate()
    }

    /// The oversampling factor Joseon uses at `sampleRate`.
    /// 4x up to 96 kHz family rates; high rates already resolve inter-sample
    /// peaks well, so 176.4 kHz and up drop to 2x and 352.8 kHz and up to 1x.
    static func factor(forSampleRate sampleRate: Double) -> Int {
        if sampleRate >= 352_800 { return 1 }
        if sampleRate >= 176_400 { return 2 }
        return 4
    }

    /// Rebuild the interpolator. Allocation free: the store is sized for maxFactor.
    func configure(factor newFactor: Int) {
        let f = max(1, min(newFactor, TruePeakDetector.maxFactor))
        if f != factor {
            factor = f
            buildCoefficients()
        }
        clear()
    }

    func clear() {
        history.update(repeating: 0, count: 2 * taps)
        cursor = 0
    }

    /// Feed one sample, get the largest absolute value on the oversampled grid.
    @inline(__always)
    func push(_ x: Float) -> Float {
        history[cursor] = x
        history[cursor + taps] = x
        // After the write the window oldest..newest is history[cursor+1 ... cursor+taps].
        let window = history + cursor + 1
        // Phase 0 is a unit impulse at tap taps/2, so it is just the delayed sample.
        var peak = abs(window[taps / 2 - 1])
        if factor > 1 {
            var coeff = coefficients
            for _ in 1..<factor {
                var acc: Float = 0
                for j in 0..<taps { acc += coeff[j] * window[j] }
                let m = abs(acc)
                if m > peak { peak = m }
                coeff += taps
            }
        }
        cursor += 1
        if cursor == taps { cursor = 0 }
        return peak
    }

    /// Largest oversampled magnitude over `count` samples.
    func maxAbs(_ x: UnsafePointer<Float>, count: Int) -> Float {
        var peak: Float = 0
        for i in 0..<count {
            let v = push(x[i])
            if v > peak { peak = v }
        }
        return peak
    }

    // MARK: - Filter design

    private func buildCoefficients() {
        guard factor > 1 else { return }
        let n = factor * taps
        let centre = n / 2
        let i0Beta = TruePeakDetector.besselI0(TruePeakDetector.kaiserBeta)
        var prototype = [Double](repeating: 0, count: n)
        for m in 0..<n {
            // Kaiser window of length n+1 sampled on 0 ..< n, so its peak sits on `centre`.
            let t = 2.0 * Double(m) / Double(n) - 1.0
            let w = TruePeakDetector.besselI0(TruePeakDetector.kaiserBeta * max(0, 1 - t * t).squareRoot()) / i0Beta
            prototype[m] = TruePeakDetector.sinc(Double(m - centre) / Double(factor)) * w
        }
        // Phase p takes every factor-th tap; normalise each branch to unity DC gain
        // and store it reversed so the hot loop is a straight dot product.
        for p in 1..<factor {
            var branch = [Double]()
            branch.reserveCapacity(taps)
            var m = p
            while m < n { branch.append(prototype[m]); m += factor }
            let sum = branch.reduce(0, +)
            let gain = sum == 0 ? 1 : sum
            let dst = coefficients + (p - 1) * taps
            for j in 0..<taps { dst[j] = Float(branch[taps - 1 - j] / gain) }
        }
    }

    static func sinc(_ x: Double) -> Double {
        if x == 0 { return 1 }
        let p = Double.pi * x
        return sin(p) / p
    }

    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let half = x / 2
        var k = 1.0
        while k < 200 {
            term *= (half / k) * (half / k)
            sum += term
            if term < sum * 1e-17 { break }
            k += 1
        }
        return sum
    }

    /// Phase `p` of the current design in convolution order: element k multiplies
    /// x[n - k]. Tests use this.
    func phaseCoefficients(_ p: Int) -> [Float] {
        guard p > 0, p < factor else {
            var impulse = [Float](repeating: 0, count: taps)
            impulse[taps / 2] = 1
            return impulse
        }
        let src = coefficients + (p - 1) * taps
        return (0..<taps).map { src[taps - 1 - $0] }
    }
}
