import Accelerate
import Foundation
import XCTest
@testable import JoseonCore

/// The band normalisation, proved on noise.
///
/// A tone-calibrated analyzer can read a tone correctly and still be several dB wrong on
/// broadband content, because a tone's energy is in one main lobe and noise is spread over every
/// bin. These tests pin the constant from the other side: white noise of a known RMS, checked as
/// an absolute total and as a shape across the bands.
///
/// The arithmetic being checked is `L_band = 10 log10(sum_k power[k] / 2)`, so
/// `sum_b 10^(L_b / 10)` is the mean square of the signal inside the summed bands. For white
/// noise of mean square `ms` spread flat over `0 ... fs/2`, the mean square inside `[f1, f2]` is
/// `ms * (f2 - f1) / (fs / 2)`.
final class ThirdOctaveNoiseTests: XCTestCase {

    /// How long the noise runs for. Not a round number chosen for comfort: the 20 Hz band is
    /// 4.6 Hz wide, and a power estimate over `T` seconds of a `B` Hz band scatters by
    /// `1 / sqrt(B T)` whatever the analyzer does. Ten seconds gives `B T = 46`, so 0.63 dB of
    /// scatter, and a 0.7 dB tolerance on the bottom band would then be a coin toss against
    /// physics rather than a test of the code. Forty seconds gives `B T = 184` and 0.31 dB, so
    /// the tolerance is measuring the analyzer again. The signals are deterministic, so the
    /// numbers below are reproducible, not a sample.
    static let noiseSeconds = 40.0

    /// White noise: the power sum of the bands equals the noise power over the same
    /// frequency range. This is the normalisation proof - it is an absolute check with no free
    /// constant, and it uses the same code path the tone tests use.
    func testWhiteNoisePowerSumMatchesTheNoisePower() {
        for rate in [48_000.0, 96_000.0] {
            let analyzer = SpectrumAnalyzer()
            let noise = TestSignals.whiteNoise(amplitude: 0.5, count: Int(rate * Self.noiseSeconds))
            let ms = ThirdOctave.meanSquare(noise)
            let levels = ThirdOctave.averageLevels(analyzer, left: noise, right: noise, rate: rate, fromSeconds: 1.0)

            // The bands that actually report at this rate.
            let layers = analyzer.thirdOctaveBank.layerAssignment
            let used = layers.indices.filter { layers[$0] >= 0 }
            let lower = ThirdOctave.edges(used.first!).lower
            let upper = ThirdOctave.edges(used.last!).upper

            let measured = used.reduce(0.0) { $0 + pow(10, levels.left[$1] / 10) }
            let expected = ms * (upper - lower) / (rate / 2)
            let errorDB = 10 * log10(measured / expected)
            print(String(format: "white noise at %.0f kHz: sum of bands %.3f dB vs noise power in %.0f-%.0f Hz, error %.3f dB (signal RMS %.4f)",
                         rate / 1000, 10 * log10(measured), lower, upper, errorDB, ms.squareRoot()))
            XCTAssertEqual(errorDB, 0, accuracy: 0.3, "band power sum is off at \(rate)")
        }
    }

    /// White noise rises by 1 dB per third octave, because the band width does
    /// (`10^(1/10) = 1.259`). Checked against the absolute prediction per band, not only against
    /// the neighbour, so a constant offset cannot hide in it.
    func testWhiteNoiseRisesOneDBPerThirdOctave() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let noise = TestSignals.whiteNoise(amplitude: 0.5, count: Int(rate * Self.noiseSeconds))
        let ms = ThirdOctave.meanSquare(noise)
        let levels = ThirdOctave.averageLevels(analyzer, left: noise, right: noise, rate: rate, fromSeconds: 1.0)

        var worst = 0.0
        var worstBand = -1
        var report = [String]()
        for b in 0..<ThirdOctave.bandCount {
            let (lower, upper) = ThirdOctave.edges(b)
            let expected = 10 * log10(ms * (upper - lower) / (rate / 2))
            let error = levels.left[b] - expected
            report.append(String(format: "%.0f:%+.2f", ThirdOctaveReading.nominalCentersHz[b], error))
            if abs(error) > abs(worst) { worst = error; worstBand = b }
        }
        print("white noise, band level minus the white-noise prediction (dB): " + report.joined(separator: " "))
        print(String(format: "worst band %.0f Hz, %+.2f dB", ThirdOctaveReading.nominalCentersHz[worstBand], worst))
        XCTAssertLessThan(abs(worst), 0.7, "band \(ThirdOctaveReading.nominalCentersHz[worstBand]) Hz is off the white-noise slope")

        // Stated the other way round: the step from band to band is +1 dB.
        for b in 1..<ThirdOctave.bandCount {
            XCTAssertEqual(levels.left[b] - levels.left[b - 1], 1.0, accuracy: 0.9,
                           "step into band \(ThirdOctaveReading.nominalCentersHz[b]) Hz")
        }
    }

    /// Pink noise is flat across the bands: constant power per third octave is what "pink" means.
    ///
    /// `TestSignals.pinkNoise` is a three-pole Kellet approximation, which is only pink over a
    /// finite range, so the test builds its own reference pink noise by shaping white noise with
    /// an exact `1/f` magnitude in the frequency domain. Flatness is then a property of the
    /// analyzer alone.
    func testPinkNoiseIsFlatAcrossBands() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let pink = ThirdOctaveNoiseTests.exactPinkNoise(count: Int(rate * Self.noiseSeconds), sampleRate: rate, amplitude: 0.3)
        let levels = ThirdOctave.averageLevels(analyzer, left: pink, right: pink, rate: rate, fromSeconds: 1.0)

        // All 31 bands: the shaping is exact from bin 1 up, so there is nothing to exclude.
        let first = 0, last = ThirdOctave.bandCount - 1
        let mean = (first...last).reduce(0.0) { $0 + levels.left[$1] } / Double(last - first + 1)
        var worst = 0.0, worstBand = -1
        var report = [String]()
        for b in first...last {
            let d = levels.left[b] - mean
            report.append(String(format: "%.0f:%+.2f", ThirdOctaveReading.nominalCentersHz[b], d))
            if abs(d) > abs(worst) { worst = d; worstBand = b }
        }
        print("pink noise, band level minus the mean (dB): " + report.joined(separator: " "))
        print(String(format: "pink flatness: worst %+.2f dB at %.0f Hz", worst, ThirdOctaveReading.nominalCentersHz[worstBand]))
        XCTAssertLessThan(abs(worst), 1.0, "pink noise is not flat across the bands")
    }

    /// Left and right are measured independently: two different noises, two different answers.
    func testChannelsAreIndependent() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let left = TestSignals.whiteNoise(amplitude: 0.5, count: Int(rate * 4), seed: 1)
        let right = TestSignals.whiteNoise(amplitude: 0.25, count: Int(rate * 4), seed: 2)
        let levels = ThirdOctave.averageLevels(analyzer, left: left, right: right, rate: rate, fromSeconds: 1.0)
        let band = ThirdOctave.band(1_000)
        print(String(format: "independent channels at 1 kHz: left %.2f dB, right %.2f dB, difference %.2f dB",
                     levels.left[band], levels.right[band], levels.left[band] - levels.right[band]))
        XCTAssertEqual(levels.left[band] - levels.right[band], 6.02, accuracy: 0.3)
    }

    // MARK: - Reference pink noise

    /// White noise shaped to an exact `1/f` magnitude with one inverse FFT. Deterministic.
    static func exactPinkNoise(count: Int, sampleRate: Double, amplitude: Float) -> [Float] {
        // Longer than the test runs, so the table never repeats: a repeat would make the signal
        // periodic, and its line spacing (fs / n) has to stay well under the 1.46 Hz bins of the
        // 32768-point FFT or the bottom bands would be measuring a comb instead of noise.
        let n = 1 << 21
        precondition(count <= n)
        let white = TestSignals.whiteNoise(amplitude: 1, count: n, seed: 0x50494E4B)
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        let log2n = vDSP_Length(log2(Double(n)).rounded())
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }

        white.withUnsafeBufferPointer { src in
            real.withUnsafeMutableBufferPointer { re in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { packed in
                        vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(n / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // Shape: amplitude ~ 1 / sqrt(f) gives power ~ 1 / f, which is constant power
                    // per octave and so constant power per third octave.
                    re[0] = 0; im[0] = 0            // DC and Nyquist pack into bin 0
                    for k in 1..<(n / 2) {
                        let g = 1 / Float(k).squareRoot()
                        re[k] *= g; im[k] *= g
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                }
            }
        }
        var table = [Float](repeating: 0, count: n)
        table.withUnsafeMutableBufferPointer { dst in
            real.withUnsafeMutableBufferPointer { re in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    dst.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { packed in
                        vDSP_ztoc(&split, 1, packed, 2, vDSP_Length(n / 2))
                    }
                }
            }
        }
        var peak: Float = 1e-9
        for v in table { peak = max(peak, abs(v)) }
        let gain = amplitude / peak
        // The table is one period of a circularly shaped noise, so repeating it is seamless.
        return (0..<count).map { table[$0 % n] * gain }
    }
}
