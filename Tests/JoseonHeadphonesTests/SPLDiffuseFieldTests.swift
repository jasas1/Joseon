import XCTest
import JoseonCore
@testable import JoseonHeadphones

/// The diffuse-field reference, and the calibration helpers built on the same chain.
final class SPLDiffuseFieldTests: XCTestCase {

    /// The offset is the published one, not a rounded stand-in.
    func testOffsetIsThePublishedValue() {
        XCTAssertEqual(DiffuseFieldReference.absoluteOffsetAt1kHzDB, 4.1, accuracy: 1e-12)
        XCTAssertTrue(DiffuseFieldReference.absoluteOffsetSource.contains("Hammershøi"))
        XCTAssertTrue(DiffuseFieldReference.absoluteOffsetSource.contains("11904-1"))
    }

    /// The embedded KEMAR diffuse-field target, normalized to its own 800–1250 Hz mean and
    /// shifted by the single published constant, must reproduce an INDEPENDENT measurement of
    /// the same physical quantity — Hammershøi & Møller's mean of human diffuse-field eardrum
    /// HRTFs, Table II. Two unrelated datasets agreeing is what makes the construction
    /// believable; if this drifts, the shape and the anchor no longer belong together.
    func testConstructedResponseMatchesThePublishedTable() {
        var worst = 0.0
        var worstHz = 0.0
        var sumSquares = 0.0
        for (hz, published) in DiffuseFieldOffsetDecision.publishedEardrumDiffuseFieldDB {
            let mine = SPLEstimator.diffuseFieldTermDB(centerHz: hz)
            let error = mine - published
            sumSquares += error * error
            if abs(error) > abs(worst) { worst = error; worstHz = hz }
            XCTAssertEqual(mine, published, accuracy: 1.0, "diffuse-field term at \(hz) Hz")
        }
        let rms = (sumSquares / Double(DiffuseFieldOffsetDecision.publishedEardrumDiffuseFieldDB.count)).squareRoot()
        print("diffuse-field term vs Hammershøi & Møller Table II: rms \(String(format: "%.2f", rms)) dB, "
            + "worst \(String(format: "%+.2f", worst)) dB at \(Int(worstHz)) Hz")
        XCTAssertLessThan(rms, 0.6)
    }

    /// The shape peaks where the ear canal and concha resonate, well above 1 kHz.
    func testTheResponsePeaksAroundThreeKilohertz() {
        let atOneK = SPLEstimator.diffuseFieldTermDB(centerHz: 1_000)
        let atThreeK = SPLEstimator.diffuseFieldTermDB(centerHz: 3_150)
        XCTAssertGreaterThan(atThreeK, atOneK + 8)
        XCTAssertLessThan(SPLEstimator.diffuseFieldTermDB(centerHz: 100), 1.0)
    }

    /// ISO 11904 subtracts: the diffuse-field-equivalent level is BELOW the eardrum level
    /// wherever the ear's own response is positive. A sign slip here would flatter the dose.
    func testTheTermIsSubtractedNotAdded() {
        let estimator = SPLFixture.estimator()
        let reading = estimator.evaluate(
            thirdOctave: SPLFixture.oneBand(atHz: 3_150, dBFS: -23.01), dt: 0.125, isSilent: false
        )
        let eardrum = Double(reading.bandLevelsEardrum[SPLFixture.bandIndex(3_150)])
        // A-weighting at 3150 Hz is about +1.2 dB, the diffuse-field term about +15 dB,
        // so the A-weighted level must land well under the eardrum level.
        XCTAssertLessThan(Double(reading.levelAFast), eardrum - 10)
    }

    // MARK: Calibration helpers

    /// `fullScaleVrms = measuredVrms · 10^(−toneLevelDBFS / 20)`.
    func testFromMeasuredTone() {
        let c = PlaybackCalibration.fromMeasuredTone(name: "WA33 at 10 o'clock", measuredVrms: 0.1, toneLevelDBFS: -20)
        XCTAssertEqual(c.fullScaleVrms, 1.0, accuracy: 1e-9)
        XCTAssertEqual(c.method, .measuredVoltage)
        XCTAssertEqual(c.uncertaintyDB, 2)
        XCTAssertEqual(c.name, "WA33 at 10 o'clock")
    }

    /// A tone measured at full scale needs no scaling at all.
    func testFromMeasuredToneAtFullScale() {
        let c = PlaybackCalibration.fromMeasuredTone(name: "bench", measuredVrms: 2.5, toneLevelDBFS: 0)
        XCTAssertEqual(c.fullScaleVrms, 2.5, accuracy: 1e-9)
    }

    /// Specs: DAC output times the amplifier gain, less the attenuation.
    func testFromSpecs() {
        let c = PlaybackCalibration.fromSpecs(
            name: "DAC + amp", dacFullScaleVrms: 2.0, ampGainDB: 20, volumeAttenuationDB: 20,
            attenuationIsEstimated: false
        )
        XCTAssertEqual(c.fullScaleVrms, 2.0, accuracy: 1e-9)
        XCTAssertEqual(c.method, .enteredSpecs)
        XCTAssertEqual(c.uncertaintyDB, 4)
    }

    /// A guessed knob position costs more uncertainty, and is the default assumption.
    func testFromSpecsWithAGuessedKnobIsLessCertain() {
        let guessed = PlaybackCalibration.fromSpecs(
            name: "WA33", dacFullScaleVrms: 2.0, ampGainDB: 20, volumeAttenuationDB: 20
        )
        XCTAssertEqual(guessed.uncertaintyDB, 6)
        XCTAssertEqual(guessed.uncertaintyDB, PlaybackCalibration.specsWithGuessedAttenuationUncertaintyDB)
        XCTAssertGreaterThan(guessed.uncertaintyDB, PlaybackCalibration.specsUncertaintyDB)
    }

    /// The sanity line the calibration sheet shows: a −20 dBFS 1 kHz tone at 98 dB SPL
    /// per volt with a 1 V full scale is 78 dB SPL.
    func testExpectedSPLSanityLine() {
        let sensitivity = HeadphoneSensitivity(dbSPLPerVolt: 98, impedanceOhms: 300, source: "synthetic test fixture")
        let calibration = PlaybackCalibration.fromMeasuredTone(name: "bench", measuredVrms: 1.0, toneLevelDBFS: 0)
        XCTAssertEqual(
            expectedSPL(forSineDBFS: -20, sensitivity: sensitivity, calibration: calibration),
            78.0, accuracy: 1e-9
        )
    }

    /// `expectedSPL` and the band chain must agree, or the sanity line lies about the meter.
    /// A −20 dBFS sine lands in the 1 kHz band at −23.01 dBFS RMS.
    func testExpectedSPLAgreesWithTheBandChain() {
        let estimator = SPLFixture.estimator()
        let reading = estimator.evaluate(
            thirdOctave: SPLFixture.oneBand(atHz: 1_000, dBFS: -23.01), dt: 0.125, isSilent: false
        )
        let expected = expectedSPL(
            forSineDBFS: -20,
            sensitivity: SPLFixture.sensitivity100,
            calibration: SPLFixture.calibration()
        )
        XCTAssertEqual(expected, 80.0, accuracy: 1e-9)
        XCTAssertEqual(Double(reading.bandLevelsEardrum[SPLFixture.bandIndex(1_000)]), expected, accuracy: 0.05)
    }

    /// At a frequency away from 1 kHz the headphone's own response shapes the answer.
    func testExpectedSPLAtAnotherFrequency() {
        let plain = expectedSPL(
            forSineDBFS: -20, atHz: 4_000,
            sensitivity: SPLFixture.sensitivity100, calibration: SPLFixture.calibration(),
            curve: SPLFixture.flatCurve()
        )
        let boosted = expectedSPL(
            forSineDBFS: -20, atHz: 4_000,
            sensitivity: SPLFixture.sensitivity100, calibration: SPLFixture.calibration(),
            curve: SPLFixture.plateauCurve(boostDB: 6, from: 3_000, to: 5_500)
        )
        XCTAssertEqual(boosted - plain, 6.0, accuracy: 0.05)
    }
}
