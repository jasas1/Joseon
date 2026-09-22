import XCTest
import JoseonCore
@testable import JoseonHeadphones

/// Real analyzer bands -> real estimator, through the engine, the way the app runs it.
final class SPLEndToEndTests: XCTestCase {
    func testSineThroughEngineGivesExpectedLevelAtTheEar() {
        let engine = AnalysisEngine()
        let flat = HeadphoneCurve(name: "Flat", source: "test", frequenciesHz: [20, 1_000, 20_000], levelsDB: [0, 0, 0])
        let estimator = SPLEstimator(
            curve: flat,
            sensitivity: HeadphoneSensitivity(dbSPLPerVolt: 100, impedanceOhms: 32, source: "test"),
            calibration: PlaybackCalibration(name: "test", method: .measuredVoltage, fullScaleVrms: 1.0, uncertaintyDB: 2)
        )
        engine.splEstimator = estimator
        let sr = 48_000.0
        let tone = TestSignals.sine(hz: 1_000, amplitude: 0.1, sampleRate: sr, seconds: 6)   // −20 dBFS peak
        var frame = AnalysisFrame(spectrum: .silent(binCount: 16))
        var i = 0
        while i + 800 <= tone.count {
            tone.withUnsafeBufferPointer { p in
                frame = engine.processNow(left: p.baseAddress! + i, right: p.baseAddress! + i, count: 800, sampleRate: sr)
            }
            i += 800
        }
        guard let spl = frame.spl else { return XCTFail("no SPL reading: bands or estimator missing") }
        // −20 dBFS sine at 1 Vrms full scale = 0.1 Vrms -> 100 dB/V − 20 dB = 80 dB SPL at the eardrum.
        XCTAssertEqual(spl.levelZEardrum, 80, accuracy: 0.5)
        // A-weighting is 0 dB at 1 kHz; the diffuse-field equivalent sits a few dB under the eardrum level.
        XCTAssertLessThan(spl.levelASlow, spl.levelZEardrum)
        XCTAssertGreaterThan(spl.levelASlow, spl.levelZEardrum - 8)
        XCTAssertGreaterThan(spl.doseSeconds, 4)
        XCTAssertEqual(spl.calibrationName, "test")
    }
}
