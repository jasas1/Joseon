import XCTest
import JoseonCore
@testable import JoseonHeadphones

/// The chain from dBFS bands to dB SPL at the eardrum, and the weightings on top of it.
final class SPLEstimatorTests: XCTestCase {

    // MARK: The chain

    /// A 1 kHz band at −23.01 dBFS RMS, 1 V full scale, 100 dB/V flat headphone.
    /// `−23.01 + 3.01 + 20·log10(1) + 100 + 0 = 80.0` dB SPL at the eardrum.
    func testEardrumLevelOfAKnownBand() {
        let estimator = SPLFixture.estimator()
        let reading = estimator.evaluate(
            thirdOctave: SPLFixture.oneBand(atHz: 1_000, dBFS: -23.01), dt: 0.125, isSilent: false
        )
        XCTAssertEqual(reading.bandLevelsEardrum[SPLFixture.bandIndex(1_000)], 80.0, accuracy: 0.05)
    }

    /// The A-weighted, diffuse-field-equivalent level for the same band is the eardrum level
    /// minus the diffuse-field term at 1 kHz (A-weighting is 0 dB there by definition).
    func testAWeightedLevelIsEardrumMinusTheDiffuseFieldTerm() {
        let estimator = SPLFixture.estimator()
        let reading = estimator.evaluate(
            thirdOctave: SPLFixture.oneBand(atHz: 1_000, dBFS: -23.01), dt: 0.125, isSilent: false
        )
        let df = SPLEstimator.diffuseFieldTermDB(centerHz: 1_000)
        XCTAssertEqual(Double(reading.levelAFast), 80.0 - df, accuracy: 0.05)
    }

    /// Ten times the voltage is 20 dB more, everywhere in the chain.
    func testTenTimesTheVoltageIsTwentyDBMore() {
        let one = SPLFixture.estimator(fullScaleVrms: 1.0)
        let ten = SPLFixture.estimator(fullScaleVrms: 10.0)
        let bands = SPLFixture.oneBand(atHz: 1_000, dBFS: -23.01)
        let a = one.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)
        let b = ten.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)
        XCTAssertEqual(b.levelAFast - a.levelAFast, 20.0, accuracy: 0.05)
        XCTAssertEqual(
            b.bandLevelsEardrum[SPLFixture.bandIndex(1_000)]
                - a.bandLevelsEardrum[SPLFixture.bandIndex(1_000)],
            20.0, accuracy: 0.05
        )
    }

    /// The same voltage change made live through `configure` gives the same 20 dB.
    func testConfigureReplacesTheCalibrationLive() {
        let estimator = SPLFixture.estimator(fullScaleVrms: 1.0)
        let bands = SPLFixture.oneBand(atHz: 1_000, dBFS: -23.01)
        let before = estimator.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)
        estimator.configure(calibration: SPLFixture.calibration(fullScaleVrms: 10.0, uncertaintyDB: 4))
        let after = estimator.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)
        XCTAssertEqual(after.levelAFast - before.levelAFast, 20.0, accuracy: 0.05)
        XCTAssertEqual(after.uncertaintyDB, 4)
    }

    /// A curve that is +6 dB across the 4 kHz band raises that band by exactly 6 dB.
    func testCurveBoostRaisesItsBand() {
        let flat = SPLFixture.estimator()
        // The 4 kHz third-octave band spans 3565–4490 Hz; the plateau covers it with room to spare.
        let boosted = SPLFixture.estimator(curve: SPLFixture.plateauCurve(boostDB: 6, from: 3_000, to: 5_500))
        let bands = SPLFixture.oneBand(atHz: 4_000, dBFS: -23.01)
        let a = flat.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)
        let b = boosted.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)
        let i = SPLFixture.bandIndex(4_000)
        XCTAssertEqual(b.bandLevelsEardrum[i] - a.bandLevelsEardrum[i], 6.0, accuracy: 0.05)
    }

    /// The plateau leaves 1 kHz alone: normalization is the 800–1250 Hz mean, which the
    /// plateau does not touch.
    func testCurveBoostLeavesOtherBandsAlone() {
        let flat = SPLFixture.estimator()
        let boosted = SPLFixture.estimator(curve: SPLFixture.plateauCurve(boostDB: 6, from: 3_000, to: 5_500))
        let bands = SPLFixture.oneBand(atHz: 1_000, dBFS: -23.01)
        let a = flat.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)
        let b = boosted.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)
        let i = SPLFixture.bandIndex(1_000)
        XCTAssertEqual(b.bandLevelsEardrum[i], a.bandLevelsEardrum[i], accuracy: 0.02)
    }

    // MARK: A-weighting

    /// IEC 61672 values at the nominal centers, from the published table.
    func testAWeightingMatchesTheStandardTable() {
        XCTAssertEqual(AWeighting.dB(atHz: 100), -19.1, accuracy: 0.1)
        XCTAssertEqual(AWeighting.dB(atHz: 1_000), 0.0, accuracy: 0.1)
        XCTAssertEqual(AWeighting.dB(atHz: 10_000), -2.5, accuracy: 0.1)
    }

    /// 1 kHz is exactly 0 by construction, not merely close.
    func testAWeightingIsExactlyZeroAtOneKilohertz() {
        XCTAssertEqual(AWeighting.dB(atHz: 1_000), 0.0, accuracy: 1e-12)
    }

    /// The whole published table, so a sign slip or a wrong pole cannot hide anywhere.
    ///
    /// The printed values are defined at the EXACT base-10 midband frequencies, so that is
    /// where they are checked. `testNominalCentersCostUnderTwoTenthsOfADB` covers the
    /// difference against the nominal centers the estimator actually uses.
    static let publishedATable: [(nominalHz: Double, dB: Double)] = [
        (20, -50.5), (25, -44.7), (31.5, -39.4), (40, -34.6), (50, -30.2), (63, -26.2),
        (80, -22.5), (100, -19.1), (125, -16.1), (160, -13.4), (200, -10.9), (250, -8.6),
        (315, -6.6), (400, -4.8), (500, -3.2), (630, -1.9), (800, -0.8), (1_000, 0.0),
        (1_250, 0.6), (1_600, 1.0), (2_000, 1.2), (2_500, 1.3), (3_150, 1.2), (4_000, 1.0),
        (5_000, 0.5), (6_300, -0.1), (8_000, -1.1), (10_000, -2.5), (12_500, -4.3),
        (16_000, -6.6), (20_000, -9.3),
    ]

    func testAWeightingMatchesTheWholeStandardTable() {
        for (nominal, dB) in Self.publishedATable {
            let exact = ThirdOctaveBands.exactCenterHz(nominalHz: nominal)
            XCTAssertEqual(AWeighting.dB(atHz: exact), dB, accuracy: 0.1,
                           "A-weighting at nominal \(nominal) Hz (exact \(exact) Hz)")
        }
    }

    /// Using the nominal center instead of the exact one is a real but small error. The
    /// estimator uses nominal centers, so the size of that choice is pinned down here.
    func testNominalCentersCostUnderTwoTenthsOfADB() {
        var worst = 0.0
        var worstHz = 0.0
        for (nominal, dB) in Self.publishedATable {
            let error = AWeighting.dB(atHz: nominal) - dB
            if abs(error) > abs(worst) { worst = error; worstHz = nominal }
        }
        print("A-weighting at nominal centers vs the table: worst "
            + "\(String(format: "%+.2f", worst)) dB at \(Int(worstHz)) Hz")
        XCTAssertLessThan(abs(worst), 0.2)
    }

    /// The exact midband grid is the base-10 one IEC 61260 defines.
    func testExactCenterFrequencies() {
        XCTAssertEqual(ThirdOctaveBands.exactCenterHz(nominalHz: 1_000), 1_000, accuracy: 1e-9)
        XCTAssertEqual(ThirdOctaveBands.exactCenterHz(nominalHz: 16_000), 15_848.93, accuracy: 0.01)
        XCTAssertEqual(ThirdOctaveBands.exactCenterHz(nominalHz: 31.5), 31.6228, accuracy: 0.001)
    }

    // MARK: Time weighting

    /// The slow weighting is a 1 s exponential on A-weighted energy, so a step from silence
    /// is within 1 dB after about 2.3 s (10·log10(1 − e^−2.3) = −0.46 dB) and not before 1.6 s.
    func testSlowWeightingReachesAStepInAboutTwoPointThreeSeconds() {
        let estimator = SPLFixture.estimator()
        let bands = SPLFixture.reading(atDBA: 80)

        var elapsed = 0.0
        var reading = estimator.evaluate(thirdOctave: bands, dt: 0, isSilent: false)
        while elapsed < 1.0 - 1e-9 {
            reading = estimator.evaluate(thirdOctave: bands, dt: 0.05, isSilent: false)
            elapsed += 0.05
        }
        // Still climbing at 1 s: 10·log10(1 − e^−1) = −1.99 dB.
        XCTAssertLessThan(Double(reading.levelASlow), 80.0 - 1.0)

        while elapsed < 2.3 - 1e-9 {
            reading = estimator.evaluate(thirdOctave: bands, dt: 0.05, isSilent: false)
            elapsed += 0.05
        }
        XCTAssertEqual(Double(reading.levelASlow), 80.0, accuracy: 1.0)
        XCTAssertEqual(Double(reading.levelAFast), 80.0, accuracy: 0.05)
    }

    /// The fast level needs no smoothing: the incoming bands are already 125 ms averages.
    func testFastLevelFollowsTheBandsImmediately() {
        let estimator = SPLFixture.estimator()
        let quiet = estimator.evaluate(thirdOctave: SPLFixture.reading(atDBA: 70), dt: 0.125, isSilent: false)
        let loud = estimator.evaluate(thirdOctave: SPLFixture.reading(atDBA: 95), dt: 0.125, isSilent: false)
        XCTAssertEqual(Double(quiet.levelAFast), 70.0, accuracy: 0.05)
        XCTAssertEqual(Double(loud.levelAFast), 95.0, accuracy: 0.05)
    }

    // MARK: Louder ear

    /// The louder channel decides every reported value, per frame.
    func testLouderEarIsChosenPerFrame() {
        let estimator = SPLFixture.estimator()
        let dBFS = SPLFixture.dBFS(forADBA: 90)
        let leftLoud = SPLFixture.leftOnly(atHz: 1_000, dBFS: dBFS)
        var rightLoud = leftLoud
        swap(&rightLoud.left, &rightLoud.right)

        let a = estimator.evaluate(thirdOctave: leftLoud, dt: 0.125, isSilent: false)
        let b = estimator.evaluate(thirdOctave: rightLoud, dt: 0.125, isSilent: false)
        XCTAssertEqual(Double(a.levelAFast), 90.0, accuracy: 0.05)
        XCTAssertEqual(Double(b.levelAFast), 90.0, accuracy: 0.05)
        XCTAssertEqual(a.bandLevelsEardrum[SPLFixture.bandIndex(1_000)],
                       b.bandLevelsEardrum[SPLFixture.bandIndex(1_000)], accuracy: 0.001)
    }

    // MARK: Leq

    /// 30 s at 80 dBA then 30 s at 90 dBA: `10·log10((30·10^8 + 30·10^9) / 60) = 87.40` dBA.
    func testLeqOfTwoLevels() {
        let estimator = SPLFixture.estimator()
        SPLFixture.run(estimator, atDBA: 80, seconds: 30)
        let reading = SPLFixture.run(estimator, atDBA: 90, seconds: 30)
        XCTAssertEqual(Double(reading.leqATrack), 87.4, accuracy: 0.1)
        XCTAssertEqual(Double(reading.leqASession), 87.4, accuracy: 0.1)
        XCTAssertEqual(reading.doseSeconds, 60, accuracy: 1e-6)
    }

    /// `resetMeasurement` clears the track Leq and the max, and leaves the dose alone.
    func testResetMeasurementClearsTrackAndMaxOnly() {
        let estimator = SPLFixture.estimator()
        SPLFixture.run(estimator, atDBA: 90, seconds: 30)
        estimator.resetMeasurement()
        let reading = SPLFixture.run(estimator, atDBA: 80, seconds: 30)
        XCTAssertEqual(Double(reading.leqATrack), 80.0, accuracy: 0.05)
        XCTAssertEqual(Double(reading.maxAFast), 80.0, accuracy: 0.05)
        // Session Leq and dose kept running across the track change.
        XCTAssertEqual(Double(reading.leqASession), 87.4, accuracy: 0.1)
        XCTAssertEqual(reading.doseSeconds, 60, accuracy: 1e-6)
    }

    /// `maxAFast` holds the loudest frame, not the loudest average.
    func testMaxAFastHoldsThePeakFrame() {
        let estimator = SPLFixture.estimator()
        SPLFixture.run(estimator, atDBA: 70, seconds: 5)
        _ = estimator.evaluate(thirdOctave: SPLFixture.reading(atDBA: 101), dt: 0.125, isSilent: false)
        let reading = SPLFixture.run(estimator, atDBA: 70, seconds: 5)
        XCTAssertEqual(Double(reading.maxAFast), 101.0, accuracy: 0.05)
    }

    /// Quiet music is not silence: it counts into the Leq and the dose clock.
    /// Only digital silence is skipped.
    func testQuietButNotSilentTimeCounts() {
        let estimator = SPLFixture.estimator()
        let reading = SPLFixture.run(estimator, atDBA: 35, seconds: 10, isSilent: false)
        XCTAssertEqual(reading.doseSeconds, 10, accuracy: 1e-6)
        XCTAssertEqual(Double(reading.leqATrack), 35.0, accuracy: 0.1)
        // 35 dBA is far under every dose threshold, so the dose stays at zero.
        XCTAssertEqual(reading.doseNIOSH, 0, accuracy: 1e-9)
    }

    // MARK: Floors and bad input

    /// Digital silence reads at the contract floor, not at −infinity.
    func testSilenceReadsAtTheFloor() {
        let estimator = SPLFixture.estimator()
        let reading = SPLFixture.run(estimator, atDBA: 90, seconds: 2)
        XCTAssertGreaterThan(reading.levelAFast, 80)
        var last = reading
        for _ in 0..<200 { last = estimator.evaluate(thirdOctave: SPLFixture.silence, dt: 0.125, isSilent: true) }
        XCTAssertEqual(last.levelASlow, SPLReading.floorDB, accuracy: 0.5)
        XCTAssertEqual(last.levelZEardrum, SPLReading.floorDB, accuracy: 0.5)
        XCTAssertTrue(last.bandLevelsEardrum.allSatisfy { $0 >= SPLReading.floorDB })
    }

    /// A zero-volt calibration is not a level; it must not produce NaN or −infinity.
    func testZeroVoltCalibrationDoesNotProduceNaN() {
        let estimator = SPLEstimator(
            curve: SPLFixture.flatCurve(),
            sensitivity: SPLFixture.sensitivity100,
            calibration: PlaybackCalibration(name: "zero", method: .enteredSpecs, fullScaleVrms: 0, uncertaintyDB: 4)
        )
        let reading = estimator.evaluate(thirdOctave: SPLFixture.oneBand(atHz: 1_000, dBFS: -20), dt: 0.125, isSilent: false)
        XCTAssertTrue(reading.levelAFast.isFinite)
        XCTAssertTrue(reading.levelASlow.isFinite)
        XCTAssertTrue(reading.levelZEardrum.isFinite)
        XCTAssertTrue(reading.bandLevelsEardrum.allSatisfy { $0.isFinite })
    }

    /// The reading carries the calibration's own name and uncertainty, so the UI can never
    /// show a level without showing what it depends on.
    func testReadingCarriesTheCalibrationIdentity() {
        let estimator = SPLFixture.estimator()
        let reading = estimator.evaluate(thirdOctave: SPLFixture.reading(atDBA: 80), dt: 0.125, isSilent: false)
        XCTAssertEqual(reading.calibrationName, "test bench")
        XCTAssertEqual(reading.uncertaintyDB, 2)
    }

    /// The Z level is the unweighted eardrum sum, so it sits above the A level whenever the
    /// diffuse-field term is positive at that frequency.
    func testZLevelIsTheUnweightedEardrumSum() {
        let estimator = SPLFixture.estimator()
        var reading = estimator.evaluate(thirdOctave: SPLFixture.oneBand(atHz: 1_000, dBFS: -23.01), dt: 0, isSilent: false)
        for _ in 0..<100 {
            reading = estimator.evaluate(thirdOctave: SPLFixture.oneBand(atHz: 1_000, dBFS: -23.01), dt: 0.125, isSilent: false)
        }
        XCTAssertEqual(Double(reading.levelZEardrum), 80.0, accuracy: 0.1)
    }

    // MARK: Band geometry

    /// The band mean is a real band mean: a curve with a narrow peak inside one band shows a
    /// smaller value there than the peak itself.
    func testBandMeanAveragesAcrossTheBandNotAtTheCenter() {
        let flat = SPLFixture.estimator()
        // A +12 dB plateau only 1/20 octave wide, centred on 1 kHz: a point sample at the
        // center would see +12, the band mean sees much less.
        let narrow = SPLFixture.plateauCurve(boostDB: 12, from: 983, to: 1_017)
        let peaky = SPLEstimator(curve: narrow, sensitivity: SPLFixture.sensitivity100,
                                 calibration: SPLFixture.calibration())
        let bands = SPLFixture.oneBand(atHz: 1_000, dBFS: -23.01)
        let a = flat.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)
        let b = peaky.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)
        let i = SPLFixture.bandIndex(1_000)
        let rise = b.bandLevelsEardrum[i] - a.bandLevelsEardrum[i]
        XCTAssertLessThan(rise, 6.0)
    }
}
