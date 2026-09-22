import XCTest
import JoseonCore
@testable import JoseonHeadphones

/// `evaluate` runs on the analysis queue while the app reconfigures on the main thread.
final class SPLThreadSafetyTests: XCTestCase {

    /// Swap curve, sensitivity and calibration from other threads while frames keep arriving.
    /// Every frame must stay finite and correctly shaped; nothing may tear.
    func testConfigureWhileEvaluating() {
        let estimator = SPLFixture.estimator()
        let bands = SPLFixture.reading(atDBA: 88)
        let curves = [
            SPLFixture.flatCurve(),
            SPLFixture.plateauCurve(boostDB: 6, from: 3_000, to: 5_500),
            EmbeddedCurves.hd650,
        ]
        let running = SPLStopFlag()
        let done = DispatchGroup()

        for worker in 0..<3 {
            done.enter()
            DispatchQueue.global().async {
                var i = 0
                while running.isSet {
                    switch (i + worker) % 4 {
                    case 0:
                        estimator.configure(curve: curves[i % curves.count])
                    case 1:
                        estimator.configure(sensitivity: HeadphoneSensitivityLibrary.hd600)
                    case 2:
                        estimator.configure(calibration: SPLFixture.calibration(fullScaleVrms: 0.5 + Double(i % 5)))
                    default:
                        estimator.configure(
                            curve: curves[i % curves.count],
                            sensitivity: HeadphoneSensitivityLibrary.focalUtopia,
                            calibration: SPLFixture.calibration(fullScaleVrms: 2.0)
                        )
                    }
                    if i % 17 == 0 { estimator.resetMeasurement() }
                    if i % 37 == 0 { _ = estimator.doseState() }
                    _ = estimator.chainOffsetDB
                    i += 1
                }
                done.leave()
            }
        }

        var frames = 0
        let bandCount = ThirdOctaveReading.nominalCentersHz.count
        let end = ProcessInfo.processInfo.systemUptime + 0.6
        while ProcessInfo.processInfo.systemUptime < end {
            let reading = estimator.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)
            XCTAssertEqual(reading.bandLevelsEardrum.count, bandCount)
            XCTAssertTrue(reading.levelAFast.isFinite)
            XCTAssertTrue(reading.levelASlow.isFinite)
            XCTAssertTrue(reading.levelZEardrum.isFinite)
            XCTAssertTrue(reading.doseNIOSH.isFinite)
            XCTAssertFalse(reading.doseNIOSH.isNaN)
            frames += 1
        }
        running.clear()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertGreaterThan(frames, 100)
    }

    /// A curve swap and a sensitivity swap in one `configure` land together, so no frame is
    /// ever computed from half of a headphone change.
    func testConfigureIsAtomicAcrossItsArguments() {
        let estimator = SPLFixture.estimator()
        let quiet = HeadphoneSensitivity(dbSPLPerVolt: 60, impedanceOhms: 32, source: "synthetic test fixture")
        let bands = SPLFixture.oneBand(atHz: 1_000, dBFS: -23.01)

        let before = estimator.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)
        estimator.configure(curve: EmbeddedCurves.hd650, sensitivity: quiet)
        let after = estimator.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)

        // 100 dB/V down to 60 dB/V is 40 dB, plus whatever the HD 650 does at 1 kHz
        // (near 0, because the curve is normalized over 800–1250 Hz).
        XCTAssertEqual(before.levelAFast - after.levelAFast, 40.0, accuracy: 0.5)
        XCTAssertEqual(estimator.sensitivity, quiet)
        XCTAssertEqual(estimator.normalizedCurve.name, "Sennheiser HD 650")
    }

    /// Budget from the spec: under 0.05 ms per `evaluate` in release.
    func testEvaluateStaysUnderBudget() {
        let estimator = SPLFixture.estimator(curve: EmbeddedCurves.hd650)
        let bands = SPLFixture.reading(atDBA: 88)
        for _ in 0..<200 { _ = estimator.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false) }

        let runs = 20_000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<runs { _ = estimator.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false) }
        let meanMS = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(runs) / 1e6
        print("SPLEstimator.evaluate mean \(String(format: "%.5f", meanMS)) ms")
        #if DEBUG
        XCTAssertLessThan(meanMS, 0.5)
        #else
        XCTAssertLessThan(meanMS, 0.05)
        #endif
    }

    /// The band cache must not be rebuilt on every frame — that is what makes the budget.
    /// A curve change does rebuild it, and the next frame must already show the new curve.
    func testCurveChangeTakesEffectOnTheNextFrame() {
        let estimator = SPLFixture.estimator()
        let bands = SPLFixture.oneBand(atHz: 4_000, dBFS: -23.01)
        let i = SPLFixture.bandIndex(4_000)
        let before = estimator.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)
        estimator.configure(curve: SPLFixture.plateauCurve(boostDB: 6, from: 3_000, to: 5_500))
        let after = estimator.evaluate(thirdOctave: bands, dt: 0.125, isSilent: false)
        XCTAssertEqual(after.bandLevelsEardrum[i] - before.bandLevelsEardrum[i], 6.0, accuracy: 0.05)
    }
}
