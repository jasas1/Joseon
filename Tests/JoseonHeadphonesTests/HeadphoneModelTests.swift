import XCTest
import JoseonCore
@testable import JoseonHeadphones

final class InterpolationTests: XCTestCase {

    private let knots = HeadphoneCurve(
        name: "knots", source: "synthetic",
        frequenciesHz: [100, 200, 400, 800, 1_600, 3_200, 6_400, 12_800],
        levelsDB: [-6, -3, 0, 3, 6, 3, 0, -6]
    )

    func testExactAtKnownPoints() {
        let interp = CurveInterpolator(curve: knots)
        for (f, db) in zip(knots.frequenciesHz, knots.levelsDB) {
            XCTAssertEqual(interp.level(atHz: f), db, accuracy: 1e-4, "at \(f) Hz")
        }
        let grid = interp.levels(atHz: knots.frequenciesHz)
        for (got, want) in zip(grid, knots.levelsDB) {
            XCTAssertEqual(got, want, accuracy: 1e-4)
        }
    }

    func testLinearInDBOverLogFrequency() {
        let interp = CurveInterpolator(curve: knots)
        // Geometric mean of 100 and 200 is the half-way point on a log axis.
        XCTAssertEqual(interp.level(atHz: sqrt(100 * 200)), -4.5, accuracy: 1e-3)
        XCTAssertEqual(interp.level(atHz: sqrt(800 * 1_600)), 4.5, accuracy: 1e-3)
    }

    func testFlatBeyondTheEnds() {
        let interp = CurveInterpolator(curve: knots)
        XCTAssertEqual(interp.level(atHz: 99), -6, accuracy: 1e-5)
        XCTAssertEqual(interp.level(atHz: 5), -6, accuracy: 1e-5)
        XCTAssertEqual(interp.level(atHz: 0.001), -6, accuracy: 1e-5)
        XCTAssertEqual(interp.level(atHz: 12_801), -6, accuracy: 1e-5)
        XCTAssertEqual(interp.level(atHz: 96_000), -6, accuracy: 1e-5)
    }

    func testGridAndScalarPathsAgree() {
        let interp = CurveInterpolator(curve: knots)
        let grid = Fixture.grid(bins: 512)
        let batch = interp.levels(atHz: grid)
        for (i, f) in grid.enumerated() {
            XCTAssertEqual(batch[i], interp.level(atHz: f), accuracy: 1e-4, "at \(f) Hz")
        }
    }

    func testGridPathHandlesRealEmbeddedCurve() {
        let c = EmbeddedCurves.hd650
        let interp = CurveInterpolator(curve: c)
        let batch = interp.levels(atHz: Fixture.grid(bins: 1_024))
        XCTAssertEqual(batch.count, 1_024)
        XCTAssertTrue(batch.allSatisfy { $0.isFinite })
        // Below 20 Hz and above 20 kHz the display grid is outside the measurement.
        XCTAssertEqual(batch.first!, c.levelsDB.first!, accuracy: 1e-4)
        XCTAssertEqual(batch.last!, c.levelsDB.last!, accuracy: 1e-4)
    }
}

final class NormalizationTests: XCTestCase {

    func testReferenceIsMeanOf800To1250() {
        let c = Fixture.curve(name: "offset") { _ in 7.5 }
        XCTAssertEqual(c.referenceLevelDB, 7.5, accuracy: 1e-4)
        let n = c.normalizedTo1kHz()
        XCTAssertTrue(n.levelsDB.allSatisfy { abs($0) < 1e-4 })
    }

    func testEveryEmbeddedCurveNormalizesToZeroAt1kHz() {
        for c in EmbeddedCurves.headphones + EmbeddedCurves.targets {
            let n = c.normalizedTo1kHz()
            // The definition: mean over the 800–1250 Hz band is 0 dB.
            var sum: Float = 0
            var count = 0
            for (i, f) in n.frequenciesHz.enumerated() where f >= 800 && f <= 1250 {
                sum += n.levelsDB[i]
                count += 1
            }
            XCTAssertGreaterThan(count, 0, "\(c.name): no points in 800–1250 Hz")
            XCTAssertEqual(sum / Float(count), 0, accuracy: 0.05, "\(c.name): reference band not 0 dB")
        }
    }

    func testFlatCurveIsExactlyZeroAt1kHzAfterNormalization() {
        let model = HeadphoneModel(curve: Fixture.curve(name: "flat 3 dB") { _ in 3 }, target: nil)
        XCTAssertEqual(CurveInterpolator(curve: model.normalizedCurve).level(atHz: 1_000), 0, accuracy: 0.05)
    }

    func testModelNormalizesBothCurveAndTarget() {
        let model = HeadphoneModel(
            curve: Fixture.curve(name: "c") { _ in -12 },
            target: Fixture.curve(name: "t") { _ in 41 }
        )
        XCTAssertEqual(model.normalizedCurve.referenceLevelDB, 0, accuracy: 1e-4)
        XCTAssertEqual(model.normalizedTarget!.referenceLevelDB, 0, accuracy: 1e-4)
    }
}

final class EvaluateTests: XCTestCase {

    func testPredictedAtEarIsMidPlusResponse() {
        let model = HeadphoneModel(curve: EmbeddedCurves.susvaraUnveiled, target: EmbeddedCurves.harmanOverEar2018)
        let spectrum = Fixture.spectrum(bins: 512) { hz in -40 + 5 * sin(log(hz)) }
        let r = model.evaluate(spectrum: spectrum, bands: Fixture.bands(), loudness: Fixture.loudness())
        XCTAssertEqual(r.responseDB.count, 512)
        XCTAssertEqual(r.targetDB.count, 512)
        XCTAssertEqual(r.predictedAtEarDB.count, 512)
        for i in 0..<512 {
            XCTAssertEqual(r.predictedAtEarDB[i], spectrum.mid[i] + r.responseDB[i], accuracy: 1e-4, "bin \(i)")
        }
        XCTAssertEqual(r.modelName, "HiFiMAN Susvara Unveiled")
    }

    func testTargetIsZerosWithoutATarget() {
        let model = HeadphoneModel(curve: EmbeddedCurves.hd600, target: nil)
        let r = model.evaluate(spectrum: Fixture.silentSpectrum(bins: 64),
                               bands: Fixture.bands(), loudness: Fixture.loudness())
        XCTAssertEqual(r.targetDB, [Float](repeating: 0, count: 64))
        XCTAssertFalse(r.responseDB.allSatisfy { $0 == 0 })
    }

    func testResampleCacheSurvivesRepeatCallsAndFollowsGridChanges() {
        let model = HeadphoneModel(curve: EmbeddedCurves.hd800s, target: EmbeddedCurves.harmanOverEar2018)
        let a = Fixture.silentSpectrum(bins: 128)
        let first = model.evaluate(spectrum: a, bands: Fixture.bands(), loudness: Fixture.loudness())
        let second = model.evaluate(spectrum: a, bands: Fixture.bands(), loudness: Fixture.loudness())
        XCTAssertEqual(first.responseDB, second.responseDB)

        let b = Fixture.silentSpectrum(bins: 256)
        let third = model.evaluate(spectrum: b, bands: Fixture.bands(), loudness: Fixture.loudness())
        XCTAssertEqual(third.responseDB.count, 256)
        XCTAssertEqual(third.responseDB, model.responseDB(onGrid: b.frequencies))
    }

    func testResponseOnGridMatchesNormalizedCurve() {
        let model = HeadphoneModel(curve: EmbeddedCurves.focalUtopia, target: nil)
        let onOwnGrid = model.responseDB(onGrid: model.normalizedCurve.frequenciesHz)
        for (got, want) in zip(onOwnGrid, model.normalizedCurve.levelsDB) {
            XCTAssertEqual(got, want, accuracy: 1e-4)
        }
    }
}

final class PerformanceTests: XCTestCase {

    func testEvaluateUnder200MicrosecondsFor1024Bins() {
        let model = HeadphoneModel(
            curve: EmbeddedCurves.susvaraUnveiled,
            target: EmbeddedCurves.harmanOverEar2018
        )
        let spectrum = Fixture.spectrum(bins: 1_024) { hz in -30 - 6 * log2(max(hz, 20) / 1_000) }
        let bands = Fixture.bands(subBass: -26)
        let loudness = Fixture.loudness(truePeakMax: -1, plr: 11, measuredSeconds: 60)

        for _ in 0..<200 { _ = model.evaluate(spectrum: spectrum, bands: bands, loudness: loudness) }

        let iterations = 2_000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { _ = model.evaluate(spectrum: spectrum, bands: bands, loudness: loudness) }
        let perCallMS = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations) / 1_000_000

        print("HeadphoneModel.evaluate: \(String(format: "%.4f", perCallMS)) ms per call, 1024 bins")
        XCTAssertLessThan(perCallMS, 0.2, "evaluate too slow: \(perCallMS) ms per call")
    }
}

final class TargetFlagTests: XCTestCase {
    func testHasTargetFollowsTheModel() {
        let spectrum = Fixture.spectrum { _ in -40 }
        let with = HeadphoneModel(curve: Fixture.flatCurve(), target: Fixture.flatCurve(name: "Flat target"))
        let without = HeadphoneModel(curve: Fixture.flatCurve(), target: nil)
        XCTAssertTrue(with.evaluate(spectrum: spectrum, bands: Fixture.bands(), loudness: Fixture.loudness()).hasTarget)
        let reading = without.evaluate(spectrum: spectrum, bands: Fixture.bands(), loudness: Fixture.loudness())
        XCTAssertFalse(reading.hasTarget)
        XCTAssertEqual(reading.targetDB, [Float](repeating: 0, count: spectrum.frequencies.count), "placeholder zeros")
    }

    func testResetDropsTheFlagHold() {
        let model = HeadphoneModel(curve: Fixture.flatCurve(), target: nil)
        model.reset()   // HeadphoneModeling.reset: must exist and not trap on a fresh model
        let asProtocol: HeadphoneModeling = model
        asProtocol.reset()
    }
}
