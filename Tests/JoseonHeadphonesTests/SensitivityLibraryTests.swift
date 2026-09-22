import XCTest
import JoseonCore
@testable import JoseonHeadphones

/// The sensitivity library holds published figures only. These tests defend that rule.
final class SensitivityLibraryTests: XCTestCase {

    // MARK: The figures, as published

    /// Sennheiser prints dB SPL at 1 V, which needs no conversion.
    func testSennheiserFiguresAreUsedAsPublished() {
        XCTAssertEqual(HeadphoneSensitivityLibrary.hd600.dbSPLPerVolt, 97, accuracy: 1e-9)
        XCTAssertEqual(HeadphoneSensitivityLibrary.hd600.impedanceOhms, 300, accuracy: 1e-9)
        XCTAssertEqual(HeadphoneSensitivityLibrary.hd650.dbSPLPerVolt, 103, accuracy: 1e-9)
        XCTAssertEqual(HeadphoneSensitivityLibrary.hd800s.dbSPLPerVolt, 102, accuracy: 1e-9)
        XCTAssertEqual(HeadphoneSensitivityLibrary.hd800s.impedanceOhms, 300, accuracy: 1e-9)
    }

    /// dB/mW to dB/V is `+10·log10(1000 / Z)`. Focal: 104 dB/mW into 80 Ω.
    func testFocalConversion() {
        let s = HeadphoneSensitivityLibrary.focalUtopia
        XCTAssertEqual(s.impedanceOhms, 80, accuracy: 1e-9)
        XCTAssertEqual(s.dbSPLPerVolt, 104 + 10 * log10(1000 / 80), accuracy: 1e-9)
        XCTAssertEqual(s.dbSPLPerVolt, 114.97, accuracy: 0.01)
    }

    /// Audeze: 103 dB/mW into 20 Ω.
    func testAudezeConversion() {
        let s = HeadphoneSensitivityLibrary.lcdX
        XCTAssertEqual(s.impedanceOhms, 20, accuracy: 1e-9)
        XCTAssertEqual(s.dbSPLPerVolt, 103 + 10 * log10(1000 / 20), accuracy: 1e-9)
        XCTAssertEqual(s.dbSPLPerVolt, 119.99, accuracy: 0.01)
    }

    /// Sony: 102 dB/mW into 48 Ω, the wired figure with the headset powered.
    func testSonyConversion() {
        let s = HeadphoneSensitivityLibrary.sonyWH1000XM5
        XCTAssertEqual(s.impedanceOhms, 48, accuracy: 1e-9)
        XCTAssertEqual(s.dbSPLPerVolt, 102 + 10 * log10(1000 / 48), accuracy: 1e-9)
        XCTAssertEqual(s.dbSPLPerVolt, 115.19, accuracy: 0.01)
    }

    /// The conversion itself, on a case where the answer is exact: 1000 Ω gives +0 dB.
    func testMilliwattConversionIdentityAtOneKiloOhm() {
        let s = HeadphoneSensitivity.fromDBPerMilliwatt(100, impedanceOhms: 1_000, source: "synthetic test fixture")
        XCTAssertEqual(s.dbSPLPerVolt, 100, accuracy: 1e-9)
    }

    // MARK: Provenance

    /// Every entry cites a manufacturer URL and the fetch date. A figure with no source is a
    /// figure someone remembered.
    func testEveryEntryCitesItsSourceAndDate() {
        for (name, sensitivity) in HeadphoneSensitivityLibrary.byCurveName {
            XCTAssertTrue(sensitivity.source.contains("2026-09-21"), "\(name) has no fetch date")
            XCTAssertTrue(sensitivity.source.contains("fetched"), "\(name) does not say it was fetched")
            XCTAssertTrue(
                sensitivity.source.contains("sennheiser") || sensitivity.source.contains("focal")
                    || sensitivity.source.contains("audeze") || sensitivity.source.contains("sony"),
                "\(name) does not cite a manufacturer domain"
            )
            XCTAssertFalse(sensitivity.source.isEmpty)
        }
    }

    /// Published figures are physically plausible: nothing here is a typo by 10 dB.
    func testEveryFigureIsPlausible() {
        for (name, s) in HeadphoneSensitivityLibrary.byCurveName {
            XCTAssertGreaterThan(s.dbSPLPerVolt, 80, "\(name)")
            XCTAssertLessThan(s.dbSPLPerVolt, 135, "\(name)")
            XCTAssertGreaterThan(s.impedanceOhms, 4, "\(name)")
            XCTAssertLessThan(s.impedanceOhms, 1_000, "\(name)")
        }
    }

    // MARK: What is deliberately missing

    /// The library covers exactly the six headphones whose makers publish a usable figure.
    func testTheLibraryHoldsOnlyVerifiedHeadphones() {
        XCTAssertEqual(Set(HeadphoneSensitivityLibrary.byCurveName.keys), [
            "Sennheiser HD 600", "Sennheiser HD 650", "Sennheiser HD 800 S",
            "Focal Utopia", "Audeze LCD-X (2021)", "Sony WH-1000XM5",
        ])
    }

    /// HiFiMAN publishes a bare "86dB" with no reference. An unreferenced dB figure cannot be
    /// converted to dB/V, so the Susvara Unveiled is absent — even though it is the first
    /// user's own headphone. This test exists so nobody quietly fills the gap from memory.
    func testHiFiMANIsAbsentBecauseTheFigureHasNoReference() {
        XCTAssertNil(HeadphoneSensitivityLibrary.sensitivity(forCurveNamed: "HiFiMAN Susvara Unveiled"))
        XCTAssertNil(HeadphoneSensitivityLibrary.sensitivity(forCurveNamed: "HiFiMAN Susvara"))
        let reason = HeadphoneSensitivityLibrary.reason(forCurveNamed: "HiFiMAN Susvara Unveiled")
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("86dB"))
    }

    /// Apple publishes nothing for either AirPods model.
    func testAirPodsAreAbsent() {
        XCTAssertNil(HeadphoneSensitivityLibrary.sensitivity(forCurveNamed: "Apple AirPods Max"))
        XCTAssertNil(HeadphoneSensitivityLibrary.sensitivity(forCurveNamed: "Apple AirPods Pro 2"))
        XCTAssertNotNil(HeadphoneSensitivityLibrary.reason(forCurveNamed: "Apple AirPods Max"))
    }

    /// The retired models are absent, and no neighbouring model's figure was borrowed.
    func testRetiredModelsAreAbsentAndNothingWasSubstituted() {
        XCTAssertNil(HeadphoneSensitivityLibrary.sensitivity(forCurveNamed: "Meze Empyrean (leather earpads)"))
        XCTAssertNil(HeadphoneSensitivityLibrary.sensitivity(forCurveNamed: "ZMF Verite"))
        let meze = HeadphoneSensitivityLibrary.reason(forCurveNamed: "Meze Empyrean (leather earpads)")
        XCTAssertNotNil(meze)
        XCTAssertTrue(meze!.contains("Empyrean II"), "the reason must warn against carrying the II's figure over")
    }

    /// Every embedded curve is accounted for: it has either a figure or a stated reason.
    /// No headphone can fall between the two lists and leave the UI with nothing to say.
    func testEveryEmbeddedCurveIsEitherListedOrExplained() {
        for curve in EmbeddedCurves.headphones {
            let hasFigure = HeadphoneSensitivityLibrary.sensitivity(forCurveNamed: curve.name) != nil
            let hasReason = HeadphoneSensitivityLibrary.reason(forCurveNamed: curve.name) != nil
            XCTAssertTrue(hasFigure != hasReason, "\(curve.name) is in neither list, or in both")
        }
        XCTAssertEqual(
            HeadphoneSensitivityLibrary.byCurveName.count + HeadphoneSensitivityLibrary.unlisted.count,
            EmbeddedCurves.headphones.count
        )
    }

    /// Every "user must enter" entry names the page that was checked.
    func testEveryUnlistedEntryNamesWhatWasChecked() {
        for entry in HeadphoneSensitivityLibrary.unlisted {
            XCTAssertFalse(entry.reason.isEmpty, "\(entry.name)")
            XCTAssertTrue(entry.checkedURL.hasPrefix("https://"), "\(entry.name)")
        }
    }

    /// Lookup uses the same names as the curve library, so a UI that picks a curve can ask
    /// for its sensitivity without translating anything.
    func testLookupUsesCurveLibraryNames() {
        let library = HeadphoneLibrary(userCurvesDirectory: URL(fileURLWithPath: "/nonexistent"))
        for name in HeadphoneSensitivityLibrary.byCurveName.keys {
            XCTAssertNotNil(library.curve(named: name), "no embedded curve named \(name)")
        }
        for entry in HeadphoneSensitivityLibrary.unlisted {
            XCTAssertNotNil(library.curve(named: entry.name), "no embedded curve named \(entry.name)")
        }
    }

    // MARK: User-entered figures

    /// A typed figure is marked "User" so it can never be mistaken for a published one.
    func testUserEnteredFiguresAreMarked() {
        let typed = HeadphoneSensitivityLibrary.userEntered(dbSPLPerVolt: 90, impedanceOhms: 45)
        XCTAssertEqual(typed.source, "User")
        XCTAssertTrue(HeadphoneSensitivityLibrary.isUserEntered(typed))
        XCTAssertFalse(HeadphoneSensitivityLibrary.isUserEntered(HeadphoneSensitivityLibrary.hd600))

        let fromMW = HeadphoneSensitivityLibrary.userEntered(dbPerMilliwatt: 86, impedanceOhms: 45)
        XCTAssertEqual(fromMW.source, "User")
        XCTAssertEqual(fromMW.dbSPLPerVolt, 86 + 10 * log10(1000 / 45), accuracy: 1e-9)
    }

    /// A real chain end to end: HD 650 on a 2 V source, at a plausible listening level.
    /// This is a coherence check on the whole library, not a measurement.
    func testAPublishedHeadphoneGivesAPlausibleLevel() {
        let estimator = SPLEstimator(
            curve: EmbeddedCurves.hd650,
            sensitivity: HeadphoneSensitivityLibrary.hd650,
            calibration: PlaybackCalibration.fromMeasuredTone(name: "2 V source", measuredVrms: 2.0, toneLevelDBFS: 0)
        )
        // Music at about −20 dBFS RMS spread over the band, which is a normal master.
        var bands = SPLFixture.floorBands
        for i in 0..<bands.count where ThirdOctaveReading.nominalCentersHz[i] >= 40
            && ThirdOctaveReading.nominalCentersHz[i] <= 12_500 {
            bands[i] = -38
        }
        let reading = estimator.evaluate(
            thirdOctave: ThirdOctaveReading(left: bands, right: bands), dt: 0.125, isSilent: false
        )
        // Loud listening, not a bad number: somewhere between a quiet room and a rock concert.
        XCTAssertGreaterThan(reading.levelAFast, 60)
        XCTAssertLessThan(reading.levelAFast, 120)
        print("HD 650 on 2 V, −38 dBFS per band: \(String(format: "%.1f", reading.levelAFast)) dBA")
    }
}
