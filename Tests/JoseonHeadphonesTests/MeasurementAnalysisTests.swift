import XCTest
@testable import JoseonHeadphones

/// The accuracy suite. Every test simulates the whole chain and compares the recovered curve
/// against the closed form of the filters that made it.
final class MeasurementAnalysisTests: XCTestCase {

    let sampleRate = 48_000.0
    let grid = SweepAnalysis.standardGrid

    private func sweep(seconds: Double = 3, levelDBFS: Double = -6) -> SweepSignal {
        SweepSignal.exponentialSweep(
            sampleRate: sampleRate, startHz: 20, endHz: 20_000,
            seconds: seconds, levelDBFS: levelDBFS
        )
    }

    private func chain() -> SimulatedChain {
        SimulatedChain(sampleRate: sampleRate, headphone: .headphone(sampleRate: sampleRate))
    }

    /// Run a whole measurement and return the recovered magnitude in dB, un-normalized.
    private func measure(
        _ chain: SimulatedChain,
        sweep: SweepSignal,
        runs: Int = 1,
        mic: MicCalibration? = nil,
        smoothing: SweepAnalysis.OctaveSmoothing = .twelfth,
        withNoiseSegment: Bool = false
    ) -> MeasuredHeadphone {
        var options = SweepAnalysis.Options()
        options.smoothing = smoothing
        let session = HeadphoneMeasurement(sweep: sweep, options: options, micCalibration: mic)
        if withNoiseSegment { session.setNoiseSegment(chain.silence(sweep)) }
        for run in 0..<runs {
            var c = chain
            c.seed = chain.seed &+ UInt64(run) &* 1_009
            session.addRun(c.record(sweep))
        }
        return session.result(name: "test", source: "simulated")!
    }

    // MARK: - Alignment

    func testDelayIsFoundToTheSample() {
        let s = sweep(seconds: 2)
        for delay in [1, 977, 3_733, 12_001] {
            var recording = [Double](repeating: 0, count: delay + s.samples.count + 4_000)
            for i in 0..<s.samples.count { recording[delay + i] = s.samples[i] }
            let noise = pinkNoise(count: recording.count, rms: s.samples.rms * 0.03, seed: UInt64(delay))
            for i in 0..<recording.count { recording[i] += noise[i] }

            let found = SweepAnalysis.delaySamples(recorded: recording, reference: s.samples)
            XCTAssertEqual(found.samples, delay, "cross-correlation missed a \(delay) sample delay")
            XCTAssertEqual(found.subSample, Double(delay), accuracy: 0.05)
            XCTAssertGreaterThan(found.confidence, 0.1)

            let ir = SweepAnalysis.impulseResponse(recorded: recording, sweep: s)
            XCTAssertEqual(ir.peakIndex, delay, "deconvolution missed a \(delay) sample delay")
        }
    }

    /// With the headphone filter in the way the peak still lands on the delay sample: a
    /// minimum-phase response of this shape has its impulse peak at time zero.
    func testDelayThroughTheWholeChain() {
        let s = sweep(seconds: 2)
        var c = chain()
        c.snrDB = 40
        c.delaySamples = 3_733
        let session = HeadphoneMeasurement(sweep: s)
        let summary = session.addRun(c.record(s), measureCrossCorrelation: true)
        print("  delay found \(summary.delaySamples), injected 3733, cross-correlation \(summary.crossCorrelationDelaySamples ?? -1)")
        XCTAssertEqual(summary.delaySamples, 3_733)
        XCTAssertEqual(summary.crossCorrelationDelaySamples ?? -1, 3_733)
    }

    // MARK: - Accuracy

    func testMagnitudeWithin03dBAt60dBSNR() {
        var c = chain()
        c.snrDB = 60
        let s = sweep(seconds: 5)
        let measured = measure(c, sweep: s, smoothing: .twelfth)

        let truth = c.trueResponseDB(onGrid: grid, includeMic: false)
        let recovered = measured.absoluteMagnitudeDB.map(Double.init)
        let worst = worstDifference(recovered, truth, onGrid: grid, from: 30, to: 16_000)
        print(String(format: "  60 dB SNR, 1/12 oct: worst %.3f dB at %.0f Hz", worst.dB, worst.hz))
        expect(worst.dB, atMost: 0.3, "worst error 30 Hz – 16 kHz")

        // The shape is right where it matters: the peak and the notch come back at full height.
        let normalized = normalizedTo1kHz(recovered, onGrid: grid)
        let normalizedTruth = normalizedTo1kHz(truth, onGrid: grid)
        let peak = worstDifference(normalized, normalizedTruth, onGrid: grid, from: 2_500, to: 3_500)
        expect(peak.dB, atMost: 0.3, "3 kHz peak error")
        let notch = worstDifference(normalized, normalizedTruth, onGrid: grid, from: 7_000, to: 9_000)
        expect(notch.dB, atMost: 0.3, "8 kHz notch error")
    }

    func testMagnitudeWithin1dBAt30dBSNRWithFourRuns() {
        var c = chain()
        c.snrDB = 30
        let s = sweep(seconds: 5)
        let measured = measure(c, sweep: s, runs: 4, smoothing: .twelfth)
        XCTAssertEqual(measured.quality.runs, 4)

        let truth = c.trueResponseDB(onGrid: grid, includeMic: false)
        let recovered = measured.absoluteMagnitudeDB.map(Double.init)
        let worst = worstDifference(recovered, truth, onGrid: grid, from: 30, to: 16_000)
        print(String(format: "  30 dB SNR, 4 runs: worst %.3f dB at %.0f Hz, agreement %.3f dB",
                     worst.dB, worst.hz, measured.quality.agreementDB))
        expect(worst.dB, atMost: 1.0, "worst error 30 Hz – 16 kHz")
    }

    /// Averaging must actually buy something. At a noise level where noise, not method, sets the
    /// error, four complex-averaged runs should come within sight of the 6 dB the theory promises.
    func testAveragingReducesNoise() {
        var c = chain()
        c.snrDB = 0                       // the sweep is buried in the noise
        let s = sweep(seconds: 2)
        let truth = c.trueResponseDB(onGrid: grid, includeMic: false)

        func rmsError(_ measured: [Double]) -> Double {
            var sum = 0.0
            var used = 0
            for (i, f) in grid.enumerated() where f >= 100 && f <= 16_000 {
                let d = measured[i] - truth[i]
                sum += d * d
                used += 1
            }
            return (sum / Double(max(used, 1))).squareRoot()
        }

        let one = rmsError(measure(c, sweep: s, runs: 1).absoluteMagnitudeDB.map(Double.init))
        let four = rmsError(measure(c, sweep: s, runs: 4).absoluteMagnitudeDB.map(Double.init))
        print(String(format: "  0 dB SNR: one run %.3f dB RMS, four runs %.3f dB RMS (%.1f dB better)",
                     one, four, 20 * log10(one / four)))
        XCTAssertLessThan(four, one * 0.75, "four runs should be clearly better than one")
    }

    // MARK: - Microphone calibration

    func testMicrophoneCalibrationIsRemoved() throws {
        var withMic = chain()
        withMic.snrDB = 60
        withMic.micCurve = [
            (10, 0), (100, 0.3), (500, -0.2), (1_000, 0), (3_000, 0.8),
            (5_000, 1.5), (10_000, 3.0), (15_000, 4.5), (20_000, 6.0),
        ]
        var withoutMic = chain()
        withoutMic.snrDB = 60

        // The calibration file states exactly what the microphone does.
        let text = ["\"Sens Factor =-1.20dB, SERNO: 7012345\""]
            + withMic.micCurve.map { String(format: "%.4f\t%.4f\t0.0", $0.hz, $0.db) }
        let mic = try MicCalibration.parse(text: text.joined(separator: "\r\n"), name: "UMIK test")
        XCTAssertEqual(mic.sensFactorDB ?? 0, -1.2, accuracy: 1e-9)
        XCTAssertTrue(mic.hasPhaseColumn)

        let s = sweep(seconds: 3)
        let corrected = measure(withMic, sweep: s, mic: mic).absoluteMagnitudeDB.map(Double.init)
        let clean = measure(withoutMic, sweep: s).absoluteMagnitudeDB.map(Double.init)
        let worst = worstDifference(corrected, clean, onGrid: grid, from: 30, to: 16_000)
        print(String(format: "  microphone removal: worst %.4f dB at %.0f Hz", worst.dB, worst.hz))
        expect(worst.dB, atMost: 0.05, "microphone correction residue")

        // And without the file the tilt is still in the answer — the correction is doing the work.
        let uncorrected = measure(withMic, sweep: s).absoluteMagnitudeDB.map(Double.init)
        let tilt = worstDifference(uncorrected, clean, onGrid: grid, from: 30, to: 16_000)
        XCTAssertGreaterThan(tilt.dB, 4)
    }

    // MARK: - Distortion

    func testTHDEstimateMatchesTheInjectedSecondHarmonic() {
        var c = chain()
        c.secondHarmonic = 0.01
        c.snrDB = 70
        let s = sweep(seconds: 5)
        let ir = SweepAnalysis.impulseResponse(recorded: c.record(s), sweep: s)
        let distortion = SweepAnalysis.harmonicDistortion(ir, sweep: s)
        let second = distortion.perHarmonicPercent[2] ?? 0
        print(String(format: "  injected 1.000 %% second harmonic, measured %.3f %% (total %.3f %%)",
                     second, distortion.totalPercent))
        expect(abs(second - 1.0) / 1.0, atMost: 0.20, "relative error of the 2nd harmonic estimate")

        // A clean chain reads near zero.
        var clean = chain()
        clean.snrDB = 70
        let cleanIR = SweepAnalysis.impulseResponse(recorded: clean.record(s), sweep: s)
        let cleanTHD = SweepAnalysis.harmonicDistortion(cleanIR, sweep: s)
        print(String(format: "  clean chain reads %.4f %%", cleanTHD.totalPercent))
        expect(cleanTHD.totalPercent, atMost: 0.1, "distortion of a linear chain")
    }

    func testThirdHarmonicIsSeparated() {
        var c = chain()
        c.thirdHarmonic = 0.02
        c.snrDB = 70
        let s = sweep(seconds: 5)
        let ir = SweepAnalysis.impulseResponse(recorded: c.record(s), sweep: s)
        let distortion = SweepAnalysis.harmonicDistortion(ir, sweep: s)
        print(String(format: "  injected 2.000 %% third harmonic, measured %.3f %% (2nd reads %.3f %%)",
                     distortion.perHarmonicPercent[3] ?? 0, distortion.perHarmonicPercent[2] ?? 0))
        expect(abs((distortion.perHarmonicPercent[3] ?? 0) - 2.0) / 2.0, atMost: 0.20,
               "relative error of the 3rd harmonic estimate")
        expect(distortion.perHarmonicPercent[2] ?? 0, atMost: 0.3, "2nd harmonic leaking from the 3rd")
    }

    /// The point of the exponential sweep: distortion must not touch the linear response.
    func testHarmonicsDoNotLeakIntoTheLinearResponse() {
        var clean = chain()
        clean.snrDB = 70
        var distorted = chain()
        distorted.snrDB = 70
        distorted.secondHarmonic = 0.03
        distorted.thirdHarmonic = 0.02

        let s = sweep(seconds: 5)
        let a = measure(clean, sweep: s).absoluteMagnitudeDB.map(Double.init)
        let b = measure(distorted, sweep: s).absoluteMagnitudeDB.map(Double.init)
        let worst = worstDifference(a, b, onGrid: grid, from: 30, to: 16_000)
        print(String(format: "  3 %% 2nd + 2 %% 3rd harmonic moves the curve by %.4f dB at %.0f Hz",
                     worst.dB, worst.hz))
        expect(worst.dB, atMost: 0.2, "harmonic leakage into the linear response")
    }

    // MARK: - Clock drift

    func testTwentyPPMDriftCostsLessThanADecibelInTheTopOctave() {
        var straight = chain()
        straight.snrDB = 70
        var drifting = chain()
        drifting.snrDB = 70
        drifting.driftPPM = 20

        let s = sweep(seconds: 5)
        let a = measure(straight, sweep: s).absoluteMagnitudeDB.map(Double.init)
        let b = measure(drifting, sweep: s).absoluteMagnitudeDB.map(Double.init)
        let top = worstDifference(a, b, onGrid: grid, from: 10_000, to: 20_000)
        let rest = worstDifference(a, b, onGrid: grid, from: 30, to: 10_000)
        print(String(format: "  20 ppm drift: top octave %.3f dB at %.0f Hz, below 10 kHz %.3f dB",
                     top.dB, top.hz, rest.dB))
        expect(top.dB, atMost: 1.0, "top-octave error from 20 ppm of clock drift")
        expect(rest.dB, atMost: 0.3, "error below 10 kHz from 20 ppm of clock drift")
    }

    // MARK: - Signal to noise

    func testSNREstimateIsWithin3dB() {
        var c = chain()
        c.snrDB = 30
        let s = sweep(seconds: 5)

        // Truth: the same measurement, but handed the exact noise that corrupted this recording
        // instead of an independent recording of the same room.
        let truthSNR = truthSNRDB(chain: c, sweep: s)

        let measured = measure(c, sweep: s, withNoiseSegment: true)
        let estimate = measured.quality.snrDB.map(Double.init)
        XCTAssertEqual(estimate.count, grid.count)

        var worst = 0.0
        var worstHz = 0.0
        for (i, f) in grid.enumerated() where f >= 30 && f <= 16_000 {
            let d = abs(estimate[i] - truthSNR[i])
            if d > worst { worst = d; worstHz = f }
        }
        print(String(format: "  SNR estimate: worst %.2f dB off at %.0f Hz (1 kHz: %.1f dB estimated, %.1f dB true)",
                     worst, worstHz, estimate[grid.firstIndex(where: { $0 >= 1_000 })!],
                     truthSNR[grid.firstIndex(where: { $0 >= 1_000 })!]))
        expect(worst, atMost: 3.0, "per-band signal-to-noise estimate")

        // Ten dB more noise must read ten dB less signal-to-noise.
        var noisier = chain()
        noisier.snrDB = 20
        let quieter = measure(noisier, sweep: s, withNoiseSegment: true).quality.snrDB.map(Double.init)
        let drop = mean(zip(estimate, quieter).map(-), onGrid: grid, from: 100, to: 10_000)
        print(String(format: "  10 dB more noise moves the estimate by %.2f dB", drop))
        expect(abs(drop - 10), atMost: 1.5, "signal-to-noise tracks the noise level")
    }

    /// Ground truth for `testSNREstimateIsWithin3dB`.
    ///
    /// The noise that actually corrupted the recording is recovered by subtracting a noiseless
    /// run, and the analysis is given *that* as its noise segment. The estimator under test gets
    /// an independent recording of the same room instead, so the two differ by exactly what is
    /// being measured: how well one noise recording predicts another.
    private func truthSNRDB(chain c: SimulatedChain, sweep s: SweepSignal) -> [Double] {
        let recorded = c.record(s)
        var quiet = c
        quiet.snrDB = nil
        let justNoise = zip(recorded, quiet.record(s)).map(-)

        let session = HeadphoneMeasurement(sweep: s)
        session.addRun(recorded)
        session.setNoiseSegment(justNoise)
        return session.result(name: "truth")!.quality.snrDB.map(Double.init)
    }

    // MARK: - Smoothing and windowing

    func testSmoothingWidensWithTheFraction() {
        var c = chain()
        c.snrDB = 60
        let s = sweep(seconds: 3)
        let truth = c.trueResponseDB(onGrid: grid, includeMic: false)
        var worse: [Double] = []
        for smoothing in [SweepAnalysis.OctaveSmoothing.twelfth, .sixth, .third] {
            let measured = measure(c, sweep: s, smoothing: smoothing).absoluteMagnitudeDB.map(Double.init)
            let worst = worstDifference(measured, truth, onGrid: grid, from: 30, to: 16_000)
            print(String(format: "  %@: worst %.3f dB at %.0f Hz", smoothing.rawValue, worst.dB, worst.hz))
            worse.append(worst.dB)
        }
        // Broader smoothing rounds the 8 kHz notch off, so the error grows, never shrinks.
        XCTAssertLessThan(worse[0], worse[2])
        // Even a third of an octave keeps the shape recognisable.
        expect(worse[2], atMost: 2.0, "1/3 octave smoothing error on a Q = 3 notch")
    }

    func testWindowRejectsWhatComesBeforeTheImpulse() {
        var c = chain()
        c.snrDB = 60
        c.secondHarmonic = 0.05
        let s = sweep(seconds: 5)
        let ir = SweepAnalysis.impulseResponse(recorded: c.record(s), sweep: s)
        let windowed = SweepAnalysis.window(ir)

        let harmonicOffset = ir.harmonicOffsetSamples[2] ?? 0
        XCTAssertGreaterThan(harmonicOffset, windowed.preSamples,
                             "the 2nd harmonic must land outside the leading edge of the window")
        print("  window \(windowed.preSamples) + \(windowed.postSamples) samples; 2nd harmonic \(harmonicOffset) samples before the peak")
        XCTAssertGreaterThanOrEqual(windowed.preSamples, Int(0.004 * sampleRate))
        XCTAssertLessThanOrEqual(windowed.samples.count, Int(0.305 * sampleRate) + windowed.preSamples)
        XCTAssertGreaterThanOrEqual(windowed.postSamples, Int(0.099 * sampleRate))
    }
}
