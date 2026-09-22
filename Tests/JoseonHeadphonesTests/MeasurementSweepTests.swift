import XCTest
@testable import JoseonHeadphones

final class MeasurementSweepTests: XCTestCase {

    func testSweepShapeAndLimits() {
        let sweep = SweepSignal.exponentialSweep(sampleRate: 48_000, seconds: 3, levelDBFS: -6)
        XCTAssertEqual(sweep.samples.count, 144_000)
        XCTAssertEqual(sweep.durationSeconds, 3, accuracy: 1e-9)
        XCTAssertEqual(sweep.samples.map { abs($0) }.max() ?? 0, 0.5012, accuracy: 0.002)
        // Raised-cosine fades: the ends are silent, the middle is not.
        XCTAssertEqual(sweep.samples[0], 0, accuracy: 1e-9)
        XCTAssertEqual(sweep.samples[sweep.samples.count - 1], 0, accuracy: 1e-6)
        let middle = sweep.samples[71_900..<72_100].map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(middle, 0.49)
    }

    func testEndFrequencyIsClampedUnderNyquist() {
        let sweep = SweepSignal.exponentialSweep(sampleRate: 44_100, startHz: 20, endHz: 24_000)
        XCTAssertLessThan(sweep.endHz, 22_050)
        XCTAssertEqual(sweep.endHz, 44_100 * 0.5 * 0.95, accuracy: 1e-6)
    }

    func testDurationIsClampedToTheSpecRange() {
        XCTAssertEqual(SweepSignal.exponentialSweep(sampleRate: 48_000, seconds: 0.5).durationSeconds, 2, accuracy: 1e-9)
        XCTAssertEqual(SweepSignal.exponentialSweep(sampleRate: 48_000, seconds: 60).durationSeconds, 10, accuracy: 1e-9)
    }

    func testHarmonicOffsetsFollowTheSweepRate() {
        let sweep = SweepSignal.exponentialSweep(sampleRate: 48_000, startHz: 20, endHz: 20_000, seconds: 5)
        let l = 5.0 / log(sweep.endHz / sweep.startHz)
        XCTAssertEqual(sweep.sweepRateSeconds, l, accuracy: 1e-9)
        XCTAssertEqual(sweep.harmonicTimeOffsetSeconds(2), l * log(2.0), accuracy: 1e-9)
        XCTAssertEqual(sweep.harmonicTimeOffsetSeconds(3), l * log(3.0), accuracy: 1e-9)
        XCTAssertEqual(sweep.harmonicTimeOffsetSeconds(1), 0)
        // A 20 Hz–19 kHz sweep can only show a 2nd harmonic under 9.5 kHz.
        XCTAssertEqual(sweep.harmonicBandCoverage(2), log(sweep.endHz / 40) / log(sweep.endHz / 20), accuracy: 1e-9)
        XCTAssertGreaterThan(sweep.harmonicBandCoverage(2), 0.88)
        XCTAssertLessThan(sweep.harmonicBandCoverage(3), sweep.harmonicBandCoverage(2))
    }

    /// Farina's inverse filter: convolved with the sweep it must give a flat unit passband.
    func testInverseFilterFlattensTheSweep() throws {
        let sweep = SweepSignal.exponentialSweep(sampleRate: 48_000, seconds: 2, levelDBFS: 0)
        let inverse = try XCTUnwrap(sweep.inverseFilter())
        XCTAssertEqual(inverse.count, sweep.samples.count)

        let n = nextPowerOfTwo(2 * sweep.samples.count)
        let fft = RealFFT(count: n)
        let x = fft.forward(sweep.samples)
        let f = fft.forward(inverse)
        var product = HalfSpectrum(n: n)
        for k in 0..<product.binCount {
            product.real[k] = x.real[k] * f.real[k] - x.imag[k] * f.imag[k]
            product.imag[k] = x.real[k] * f.imag[k] + x.imag[k] * f.real[k]
        }
        let grid = [50.0, 100, 300, 1_000, 3_000, 8_000, 15_000]
        let db = SweepAnalysis.smoothedMagnitudeDB(product, sampleRate: 48_000, grid: grid, smoothing: .sixth)
        for (i, f) in grid.enumerated() {
            XCTAssertEqual(db[i], 0, accuracy: 1.0, "inverse filter is not flat at \(f) Hz")
        }
        // And it really is an impulse: the peak dwarfs the rest.
        let impulse = fft.inverse(product)
        let peak = peakIndex(impulse)
        XCTAssertGreaterThan(abs(impulse[peak]) / impulse.rms, 50)
    }

    func testPinkNoiseIsPeriodicPinkAndRepeatable() {
        let noise = SweepSignal.periodicPinkNoise(sampleRate: 48_000, seconds: 2, levelDBFS: -6, seed: 42)
        XCTAssertEqual(noise.kind, .periodicPinkNoise)
        XCTAssertEqual(noise.periodSamples, nextPowerOfTwo(96_000))
        XCTAssertEqual(noise.samples.map { abs($0) }.max() ?? 0, 0.5012, accuracy: 0.002)

        // Same seed, same samples.
        let again = SweepSignal.periodicPinkNoise(sampleRate: 48_000, seconds: 2, levelDBFS: -6, seed: 42)
        XCTAssertEqual(noise.samples, again.samples)
        XCTAssertNotEqual(
            SweepSignal.periodicPinkNoise(sampleRate: 48_000, seconds: 2, levelDBFS: -6, seed: 43).samples,
            noise.samples
        )

        // −3 dB per octave.
        let fft = RealFFT(count: noise.periodSamples)
        let spectrum = fft.forward(noise.samples)
        let grid = [100.0, 200, 400, 800, 1_600, 3_200, 6_400]
        let db = SweepAnalysis.smoothedMagnitudeDB(spectrum, sampleRate: 48_000, grid: grid, smoothing: .third)
        for i in 1..<grid.count {
            XCTAssertEqual(db[i] - db[i - 1], -3.01, accuracy: 0.6, "slope wrong at \(grid[i]) Hz")
        }
        XCTAssertNil(noise.inverseFilter())
    }

    /// The crest-factor difference between the two stimuli, which is why the sweep is the default.
    func testSweepDeliversMoreEnergyThanNoiseAtTheSamePeak() {
        let sweep = SweepSignal.exponentialSweep(sampleRate: 48_000, seconds: 2, levelDBFS: -6)
        let noise = SweepSignal.periodicPinkNoise(sampleRate: 48_000, seconds: 2, levelDBFS: -6)
        print(String(format: "  sweep RMS %.2f dBFS, pink noise RMS %.2f dBFS",
                     sweep.rmsLevelDBFS, noise.rmsLevelDBFS))
        XCTAssertGreaterThan(sweep.rmsLevelDBFS - noise.rmsLevelDBFS, 5)
        XCTAssertEqual(sweep.rmsLevelDBFS, -9.01, accuracy: 0.5)
    }

    func testRealFFTRoundTrips() {
        let fft = RealFFT(count: 1_024)
        var rng = SplitMix64(seed: 5)
        let x = (0..<1_024).map { _ in rng.nextGaussian() }
        let back = fft.inverse(fft.forward(x))
        for i in 0..<1_024 {
            XCTAssertEqual(back[i], x[i], accuracy: 1e-9)
        }
        // A known single bin: 4 cycles of a cosine put all the energy in bin 4.
        let tone = (0..<1_024).map { cos(2 * Double.pi * 4 * Double($0) / 1_024) }
        let spectrum = fft.forward(tone)
        XCTAssertEqual(spectrum.magnitude(4), 512, accuracy: 1e-6)
        XCTAssertEqual(spectrum.magnitude(5), 0, accuracy: 1e-6)
    }
}
