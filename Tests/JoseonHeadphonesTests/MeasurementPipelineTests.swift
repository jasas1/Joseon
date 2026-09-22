import XCTest
@testable import JoseonHeadphones
import JoseonCore

/// The whole session, the way the app will drive it, ending in a file the library can read back.
final class MeasurementPipelineTests: XCTestCase {

    let sampleRate = 48_000.0
    let grid = SweepAnalysis.standardGrid

    private func session(runs: Int = 3, noise: Bool = true) throws -> MeasuredHeadphone {
        var chain = SimulatedChain(sampleRate: sampleRate, headphone: .headphone(sampleRate: sampleRate))
        chain.snrDB = 45
        chain.secondHarmonic = 0.005
        let sweep = SweepSignal.exponentialSweep(sampleRate: sampleRate, seconds: 3, levelDBFS: -6)
        let mic = try MicCalibration.parse(
            text: "\"Sens Factor =-14.0412dB, SERNO: 7012345\"\r\n20\t0\t0\r\n1000\t0\t0\r\n20000\t0\t0\r\n10000\t0\t0",
            name: "UMIK-1 7012345 (0°)"
        )
        let session = HeadphoneMeasurement(sweep: sweep, micCalibration: mic)
        if noise { session.setNoiseSegment(chain.silence(sweep)) }
        for i in 0..<runs {
            var c = chain
            c.seed = UInt64(i) &* 17 &+ 1
            let summary = session.addRun(c.record(sweep))
            XCTAssertEqual(summary.delaySamples, 3_733)
            XCTAssertFalse(summary.clipped)
        }
        return try XCTUnwrap(session.result(
            name: "HiFiMAN Susvara Unveiled (measured)",
            sensitivity: HeadphoneMeasurement.SensitivityContext(
                playback: .fromMeasuredTone(name: "WA33 at 10 o'clock", measuredVrms: 0.1, toneLevelDBFS: -6),
                absoluteLevel: AbsoluteLevel.scale(for: .fromMicCalibration(mic)),
                impedanceOhms: 45
            )
        ))
    }

    func testResultIsOnTheModuleGridAndNormalized() throws {
        let measured = try session()
        XCTAssertEqual(measured.curve.frequenciesHz.count, 200)
        XCTAssertEqual(measured.curve.frequenciesHz, EmbeddedCurves.standardFrequenciesHz)
        XCTAssertEqual(measured.curve.referenceLevelDB, 0, accuracy: 0.05, "normalized to 0 dB at 1 kHz")
        XCTAssertTrue(measured.curve.levelsDB.allSatisfy { $0.isFinite })
        XCTAssertEqual(measured.quality.runs, 3)
        XCTAssertFalse(measured.quality.snrDB.isEmpty)
        XCTAssertGreaterThan(measured.quality.snrDB(atHz: 1_000) ?? 0, 30)
        XCTAssertEqual(measured.quality.thdPercent, 0.5, accuracy: 0.15)
        XCTAssertLessThan(measured.quality.agreementDB, 0.2)
        XCTAssertEqual(measured.quality.lowestResolvedHz, 9.5, accuracy: 1.0)
        print("  method: \(measured.method)")
        print("  SNR at 30 Hz \(measured.quality.snrDB(atHz: 30) ?? 0) dB, at 10 kHz \(measured.quality.snrDB(atHz: 10_000) ?? 0) dB")
    }

    func testWarningsSayWhatIsMissing() throws {
        let sweep = SweepSignal.exponentialSweep(sampleRate: sampleRate, seconds: 2)
        var chain = SimulatedChain(sampleRate: sampleRate, headphone: .headphone(sampleRate: sampleRate))
        chain.snrDB = 40
        let session = HeadphoneMeasurement(sweep: sweep)         // no microphone file, no coupler
        session.addRun(chain.record(sweep))                       // one run, no noise segment
        let measured = try XCTUnwrap(session.result(name: "bare"))
        let warnings = measured.quality.warnings
        for expected in ["No microphone calibration", "No coupler correction", "One run only",
                         "No noise-only segment", "No sensitivity was derived", "Clock drift"] {
            XCTAssertTrue(warnings.contains { $0.contains(expected) }, "missing warning about \(expected)")
        }
        XCTAssertNil(measured.sensitivity)

        // Clipping is caught and said out loud.
        let clipping = HeadphoneMeasurement(sweep: sweep)
        var loud = chain.record(sweep)
        loud[10_000] = 1.0
        clipping.addRun(loud)
        let clipped = try XCTUnwrap(clipping.result(name: "clipped"))
        XCTAssertTrue(clipped.quality.warnings.contains { $0.contains("clipped") })
    }

    /// The point of `csv()`: what comes out goes back in.
    func testCSVRoundTripsThroughTheLibrary() throws {
        let measured = try session()
        let csv = measured.csv()
        XCTAssertTrue(csv.contains("frequency,raw"))
        XCTAssertTrue(csv.hasPrefix("# HiFiMAN Susvara Unveiled (measured)"))

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("joseon-measure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("HiFiMAN Susvara Unveiled (measured).csv")
        try csv.write(to: file, atomically: true, encoding: .utf8)

        let library = HeadphoneLibrary(userCurvesDirectory: directory.appendingPathComponent("Curves"))
        let reloaded = try library.importCurve(from: file)

        XCTAssertEqual(reloaded.frequenciesHz.count, measured.curve.frequenciesHz.count)
        var worst: Float = 0
        for i in 0..<reloaded.levelsDB.count {
            XCTAssertEqual(reloaded.frequenciesHz[i], measured.curve.frequenciesHz[i], accuracy: 0.001)
            worst = max(worst, abs(reloaded.levelsDB[i] - measured.curve.levelsDB[i]))
        }
        print(String(format: "  CSV round trip: worst level difference %.6f dB", worst))
        XCTAssertLessThan(worst, 0.001)

        // It is a curve the rest of the module can use like any other.
        XCTAssertEqual(library.userCurves().count, 1)
        XCTAssertEqual(library.curve(named: "HiFiMAN Susvara Unveiled (measured)")?.levelsDB.count, 200)
        let model = HeadphoneModel(curve: reloaded, target: nil)
        let response = model.responseDB(onGrid: [30, 1_000, 3_000, 8_000])
        XCTAssertEqual(response[1], 0, accuracy: 0.05)
        XCTAssertGreaterThan(response[2], 4)     // the 3 kHz peak survived the round trip
        XCTAssertLessThan(response[3], -5)       // and so did the 8 kHz notch
    }

    func testNoRunsMeansNoResult() {
        let sweep = SweepSignal.exponentialSweep(sampleRate: sampleRate, seconds: 2)
        let session = HeadphoneMeasurement(sweep: sweep)
        XCTAssertNil(session.result(name: "nothing"))
        XCTAssertEqual(session.runCount, 0)
        if case .derived = session.derivedSensitivity(
            HeadphoneMeasurement.SensitivityContext(
                playback: .fromMeasuredTone(name: "x", measuredVrms: 0.1, toneLevelDBFS: -6),
                absoluteLevel: AbsoluteLevel.scale(for: .calibrator(readingDBFS: -32)),
                impedanceOhms: 45
            )
        ) {
            XCTFail("a sensitivity was derived from no measurement")
        }
    }

    /// Pink noise as the stimulus: a coarser tool, and it says so.
    func testPinkNoiseStimulusAlsoRecoversTheCurve() throws {
        let noise = SweepSignal.periodicPinkNoise(sampleRate: sampleRate, seconds: 4, levelDBFS: -6)
        var chain = SimulatedChain(sampleRate: sampleRate, headphone: .headphone(sampleRate: sampleRate))
        chain.snrDB = 50
        var options = SweepAnalysis.Options()
        options.smoothing = .sixth
        let session = HeadphoneMeasurement(sweep: noise, options: options)
        for i in 0..<4 {
            var c = chain
            c.seed = UInt64(i) &* 31 &+ 5
            session.addRun(c.record(noise))
        }
        let measured = try XCTUnwrap(session.result(name: "pink"))
        let truth = normalizedTo1kHz(chain.trueResponseDB(onGrid: grid, includeMic: false), onGrid: grid)
        let recovered = measured.curve.levelsDB.map(Double.init)
        let worst = worstDifference(recovered, truth, onGrid: grid, from: 50, to: 16_000)
        print(String(format: "  pink noise, 4 periods: worst %.3f dB at %.0f Hz", worst.dB, worst.hz))
        expect(worst.dB, atMost: 1.5, "pink-noise measurement, 50 Hz – 16 kHz")
        XCTAssertEqual(measured.quality.thdPercent, 0)
        XCTAssertTrue(measured.quality.warnings.contains { $0.contains("Pink noise can not separate distortion") })
    }
}
