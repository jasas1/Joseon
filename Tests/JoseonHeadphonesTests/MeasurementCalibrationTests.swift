import XCTest
@testable import JoseonHeadphones
import JoseonCore

final class MeasurementCalibrationTests: XCTestCase {

    // MARK: - Parsing

    /// A miniDSP UMIK-1 file: quoted sensitivity header, tabs, three columns, CRLF endings.
    func testUMIKFile() throws {
        let text = "\"Sens Factor =-1.2dB, SERNO: 7012345\"\r\n"
            + "20.000\t-2.4345\t0.0000\r\n"
            + "25.000\t-1.9876\t1.2000\r\n"
            + "1000.000\t0.0000\t0.0000\r\n"
            + "10000.000\t1.5000\t-3.4000\r\n"
            + "20000.000\t4.2000\t-8.0000\r\n"
        let mic = try MicCalibration.parse(text: text, name: "UMIK-1 7012345")
        XCTAssertEqual(mic.frequenciesHz.count, 5)
        XCTAssertEqual(mic.sensFactorDB ?? 0, -1.2, accuracy: 1e-9)
        XCTAssertTrue(mic.hasPhaseColumn)
        XCTAssertEqual(mic.levelsDB[0], -2.4345, accuracy: 1e-9)
        XCTAssertEqual(mic.levelsDB[4], 4.2, accuracy: 1e-9)
        // "\r\n" is one Character, so splitting on `isNewline` leaves no stray carriage return.
        XCTAssertFalse(mic.frequenciesHz.contains { !$0.isFinite })
        XCTAssertEqual(mic.micSensitivityDBFSPerPascal() ?? 0,
                       MicCalibration.sensFactorReferenceDBFS - 1.2, accuracy: 1e-9)
    }

    func testSensFactorSpellings() {
        XCTAssertEqual(CalibrationFileParser.sensFactorValue(in: "Sens Factor =-.1dB, SERNO: 1")!, -0.1, accuracy: 1e-9)
        XCTAssertEqual(CalibrationFileParser.sensFactorValue(in: "sens factor = 1.25 dB")!, 1.25, accuracy: 1e-9)
        XCTAssertEqual(CalibrationFileParser.sensFactorValue(in: "SensFactor=-12dB")!, -12, accuracy: 1e-9)
        XCTAssertNil(CalibrationFileParser.sensFactorValue(in: "20.0 -2.4"))
        XCTAssertNil(CalibrationFileParser.sensFactorValue(in: "Sens Factor without a number"))
    }

    func testTwoColumnREWStyleWithCommentsAndBadRows() throws {
        let text = """
        * Microphone calibration file
        # exported by something
        // another comment style
        ; and one more
        0.0, 0.0
        -5.0, 1.0
        rubbish, 2.0
        20.0, -2.0
        50.0, -1.0
        100.0, -0.5
        1000.0, 0.0
        5000.0, 1.0
        10000.0, 2.5
        20000.0
        20000.0, 5.0
        """
        let mic = try MicCalibration.parse(text: text, name: "REW")
        XCTAssertEqual(mic.frequenciesHz, [20, 50, 100, 1_000, 5_000, 10_000, 20_000])
        XCTAssertFalse(mic.hasPhaseColumn)
        XCTAssertNil(mic.sensFactorDB)
    }

    func testSpaceSeparatedAndDuplicateFrequencies() throws {
        let text = """
        20   -2.0
        20   -4.0
        100  -1.0
        1000  0.0
        10000 2.0
        """
        let mic = try MicCalibration.parse(text: text, name: "spaces")
        XCTAssertEqual(mic.frequenciesHz, [20, 100, 1_000, 10_000])
        XCTAssertEqual(mic.levelsDB[0], -3.0, accuracy: 1e-9, "duplicate frequencies are averaged")
    }

    func testTooFewRowsThrows() {
        XCTAssertThrowsError(try MicCalibration.parse(text: "20,1\n100,2\n1000,3", name: "short")) { error in
            guard case .noData = (error as? CurveParseError) ?? .badRow(0) else {
                return XCTFail("expected CurveParseError.noData, got \(error)")
            }
        }
        XCTAssertThrowsError(try MicCalibration.parse(text: "", name: "empty"))
        XCTAssertThrowsError(try CouplerCorrection.parse(text: "nothing here", name: "junk"))
    }

    func testCorrectionIsFlatBeyondTheEndsOfTheFile() throws {
        let mic = try MicCalibration.parse(
            text: "100,1.0\n200,2.0\n1000,3.0\n5000,4.0\n10000,5.0",
            name: "short range"
        )
        let correction = mic.correctionDB(onGrid: [20, 100, 1_000, 10_000, 20_000])
        XCTAssertEqual(correction[0], 1.0, accuracy: 1e-6, "flat below the first point")
        XCTAssertEqual(correction[4], 5.0, accuracy: 1e-6, "flat above the last point")
        XCTAssertEqual(correction[2], 3.0, accuracy: 1e-6)
        // Applying it subtracts.
        let applied = mic.apply(toMagnitudeDB: [0, 0, 0, 0, 0], onGrid: [20, 100, 1_000, 10_000, 20_000])
        XCTAssertEqual(applied[2], -3.0, accuracy: 1e-6)
    }

    func testCouplerCorrectionUsesTheSameParser() throws {
        let coupler = try CouplerCorrection.parse(
            text: "# flat plate, characterised 2026-09-21\n20,3.0\n100,2.0\n1000,0.0\n8000,-4.0\n20000,-6.0",
            name: "Flat plate"
        )
        XCTAssertEqual(coupler.frequenciesHz.count, 5)
        let applied = coupler.apply(toMagnitudeDB: [0, 0], onGrid: [20, 8_000])
        XCTAssertEqual(applied[0], -3.0, accuracy: 1e-6)
        XCTAssertEqual(applied[1], 4.0, accuracy: 1e-6)
    }

    // MARK: - Absolute level

    func testCalibratorGivesAnOffset() {
        let result = AbsoluteLevel.scale(for: .calibrator(readingDBFS: -32.04))
        let scale = try! XCTUnwrap(result.scale)
        XCTAssertEqual(scale.offsetDB, 94 + 32.04, accuracy: 1e-9)
        XCTAssertEqual(scale.splDB(fromDBFS: -32.04), 94, accuracy: 1e-9)
        XCTAssertTrue(result.isAvailable)
        XCTAssertNil(result.unavailableReason)
    }

    func testMicSensitivityGivesTheSameOffset() {
        let sensitivity = AbsoluteLevel.scale(for: .micSensitivity(dbFSPerPascal: -32.04))
        XCTAssertEqual(sensitivity.scale?.offsetDB ?? 0, 94 + 32.04, accuracy: 1e-9)
    }

    /// The point of the enum: with nothing to tie dBFS to pascals there is no number to use by
    /// accident.
    func testNoReferenceMeansNoAbsoluteLevel() throws {
        let none = AbsoluteLevel.scale(for: .fromMicCalibration(nil))
        XCTAssertNil(none.scale)
        XCTAssertFalse(none.isAvailable)
        XCTAssertTrue(try XCTUnwrap(none.unavailableReason).contains("pascals"))

        let headerless = try MicCalibration.parse(text: "20,1\n100,2\n1000,3\n10000,4", name: "no header")
        let withoutHeader = AbsoluteLevel.scale(for: .fromMicCalibration(headerless))
        XCTAssertNil(withoutHeader.scale)
        let reason = try XCTUnwrap(withoutHeader.unavailableReason)
        XCTAssertTrue(reason.contains("sensitivity header"), reason)

        let bad = AbsoluteLevel.scale(for: .calibrator(readingDBFS: 3))
        XCTAssertNil(bad.scale)
    }

    /// The drive term is whatever the active calibration says it is — the same figure the
    /// calibration window prints. Critic round 6, D2: two screens rating one calibration at
    /// ± 0.5 dB and ± 2 dB is one screen lying.
    func testDriveVoltageUncertaintyIsTheCalibrationsOwnFigure() {
        let measured = PlaybackCalibration.fromMeasuredTone(name: "m", measuredVrms: 0.1, toneLevelDBFS: -6)
        let specs = PlaybackCalibration.fromSpecs(name: "s", dacFullScaleVrms: 2, ampGainDB: 10, volumeAttenuationDB: 20)
        XCTAssertEqual(AbsoluteLevel.driveVoltageUncertaintyDB(for: measured), measured.uncertaintyDB)
        XCTAssertEqual(AbsoluteLevel.driveVoltageUncertaintyDB(for: measured), 2.0)
        XCTAssertEqual(AbsoluteLevel.driveVoltageUncertaintyDB(for: specs), specs.uncertaintyDB)
        XCTAssertEqual(specs.uncertaintyDB, 6.0)
    }

    // MARK: - Sensitivity derivation

    /// 0.1 V RMS into a headphone of known sensitivity, measured with a 12.5 mV/Pa microphone
    /// through an interface of known gain. The derivation has to give back the number the
    /// simulation started from.
    func testSensitivityDerivation() throws {
        let sampleRate = 48_000.0
        let grid = SweepAnalysis.standardGrid
        let headphone = FilterCascade.headphone(sampleRate: sampleRate)

        let targetSensitivity = 100.0              // dB SPL per volt at 1 kHz, the answer wanted
        let driveVrms = 0.1
        let sweepLevelDBFS = -6.0
        let fullScaleVrms = driveVrms * pow(10, -sweepLevelDBFS / 20)
        let micVoltsPerPascal = 0.0125
        let interfaceDigitalPerVolt = 2.0
        let digitalPerPascal = micVoltsPerPascal * interfaceDigitalPerVolt
        let micSensitivityDBFSPerPascal = 20 * log10(digitalPerPascal)

        // The linear gain of everything between the digital drive and the digital recording,
        // chosen so that the whole chain really has `targetSensitivity` at 1 kHz.
        let at1kHz = headphone.responseDB(atHz: 1_000)
        let gain = pow(10, -at1kHz / 20)
            * 2.0.squareRoot() * fullScaleVrms
            * pow(10, (targetSensitivity - 94) / 20)
            * digitalPerPascal

        var chain = SimulatedChain(sampleRate: sampleRate, headphone: headphone)
        chain.gain = gain
        chain.snrDB = 60

        let sweep = SweepSignal.exponentialSweep(
            sampleRate: sampleRate, seconds: 3, levelDBFS: sweepLevelDBFS
        )
        let playback = PlaybackCalibration.fromMeasuredTone(
            name: "WA33 at 10 o'clock", measuredVrms: driveVrms, toneLevelDBFS: sweepLevelDBFS
        )
        XCTAssertEqual(playback.fullScaleVrms, fullScaleVrms, accuracy: 1e-9)

        // Route 1: a UMIK file whose Sens Factor states the microphone's sensitivity.
        let sensFactor = micSensitivityDBFSPerPascal - MicCalibration.sensFactorReferenceDBFS
        let calText = ["\"Sens Factor =\(String(format: "%.4f", sensFactor))dB, SERNO: 7012345\"",
                       "20\t0.0\t0.0", "100\t0.0\t0.0", "1000\t0.0\t0.0", "20000\t0.0\t0.0"]
        let mic = try MicCalibration.parse(text: calText.joined(separator: "\r\n"), name: "UMIK-1")

        let session = HeadphoneMeasurement(sweep: sweep, micCalibration: mic)
        session.setNoiseSegment(chain.silence(sweep))
        for run in 0..<3 {
            var c = chain
            c.seed = UInt64(run) &* 101 &+ 3
            session.addRun(c.record(sweep))
        }
        let context = HeadphoneMeasurement.SensitivityContext(
            playback: playback,
            absoluteLevel: AbsoluteLevel.scale(for: .fromMicCalibration(mic)),
            impedanceOhms: 45
        )
        let measured = try XCTUnwrap(session.result(name: "simulated headphone", sensitivity: context))
        let derived = try XCTUnwrap(measured.derivedSensitivity)

        print(String(format: "  derived %.3f dB SPL/V (simulated %.3f), ± %.2f dB; SPL at 1 kHz during the run %.1f dB, drive %.4f Vrms",
                     derived.sensitivity.dbSPLPerVolt, targetSensitivity,
                     derived.uncertaintyDB, derived.measuredSPLAt1kHz, derived.driveVoltsRMS))
        expect(abs(derived.sensitivity.dbSPLPerVolt - targetSensitivity), atMost: 0.2,
               "derived sensitivity against the simulated 1 kHz gain")
        XCTAssertEqual(derived.driveVoltsRMS, driveVrms, accuracy: 1e-6)
        XCTAssertEqual(derived.measuredSPLAt1kHz, targetSensitivity + 20 * log10(driveVrms), accuracy: 0.2)
        XCTAssertEqual(derived.sensitivity.impedanceOhms, 45)
        XCTAssertTrue(derived.sensitivity.source.hasPrefix("Measured with Joseon"))

        // The uncertainty is the pieces in quadrature, and every piece is named.
        let quadrature = derived.uncertaintyComponents.reduce(0) { $0 + $1.dB * $1.dB }.squareRoot()
        XCTAssertEqual(derived.uncertaintyDB, quadrature, accuracy: 1e-9)
        XCTAssertEqual(derived.uncertaintyComponents.count, 5)
        XCTAssertEqual(
            Set(derived.uncertaintyComponents.map(\.name)),
            ["Absolute level reference", "Drive voltage", "Rig",
             "Microphone response at 1 kHz", "Measurement repeatability"]
        )
        XCTAssertGreaterThan(derived.uncertaintyDB, MicCalibration.sensFactorUncertaintyDB)
        print("  budget: \(derived.uncertaintyHeadline)")

        // Route 2: an acoustic calibrator reading, which must land on the same answer.
        let calibratorReading = micSensitivityDBFSPerPascal      // 94 dB SPL is 1 Pa
        let viaCalibrator = session.derivedSensitivity(
            HeadphoneMeasurement.SensitivityContext(
                playback: playback,
                absoluteLevel: AbsoluteLevel.scale(for: .calibrator(readingDBFS: calibratorReading)),
                impedanceOhms: 45
            )
        )
        let calibrated = try XCTUnwrap(viaCalibrator.value)
        expect(abs(calibrated.sensitivity.dbSPLPerVolt - targetSensitivity), atMost: 0.2,
               "derived sensitivity through an acoustic calibrator")
        XCTAssertLessThan(calibrated.uncertaintyDB, derived.uncertaintyDB,
                          "a calibrator is a better reference than a sensitivity header")

        // Route 3: nothing. The curve still comes back; the sensitivity does not.
        let none = HeadphoneMeasurement.SensitivityContext(
            playback: playback,
            absoluteLevel: AbsoluteLevel.scale(for: .fromMicCalibration(nil)),
            impedanceOhms: 45
        )
        let withoutReference = try XCTUnwrap(session.result(name: "x", sensitivity: none))
        XCTAssertNil(withoutReference.sensitivity)
        XCTAssertNil(withoutReference.derivedSensitivity)
        XCTAssertTrue(withoutReference.quality.warnings.contains { $0.contains("No sensitivity was derived") })
        XCTAssertEqual(withoutReference.curve.frequenciesHz.count, grid.count)
    }

    func testDerivationRefusesAZeroVoltageCalibration() {
        let broken = PlaybackCalibration(name: "none", method: .enteredSpecs, fullScaleVrms: 0, uncertaintyDB: 8)
        let result = AbsoluteLevel.deriveSensitivity(
            magnitudeAt1kHzDB: -20,
            absoluteLevel: AbsoluteLevel.scale(for: .calibrator(readingDBFS: -32)),
            playback: broken,
            sweepLevelDBFS: -6,
            impedanceOhms: 45,
            source: "test"
        )
        XCTAssertNil(result.value)
        XCTAssertNotNil(result.unavailableReason)
    }
}
