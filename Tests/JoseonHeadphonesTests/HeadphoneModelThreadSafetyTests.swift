import XCTest
import JoseonCore
@testable import JoseonHeadphones

/// `evaluate` runs on the analysis queue while the app changes thresholds and resets flags on the main thread.
final class HeadphoneModelThreadSafetyTests: XCTestCase {
    private func loudSubBassInput() -> (SpectrumReading, BandEnergy, LoudnessReading) {
        let spectrum = Fixture.spectrum(bins: 1024) { hz in hz < 60 ? -10 : -40 }
        return (spectrum, Fixture.bands(subBass: -8), Fixture.loudness(truePeakMax: 0.5, plr: 6, measuredSeconds: 60, integrated: -9))
    }

    func testEvaluateWhileThresholdsAndFlagsChangeOnOtherThreads() {
        let model = HeadphoneModel(curve: Fixture.curve(name: "Rolled") { hz in hz < 60 ? -12 : 0 }, target: Fixture.flatCurve(name: "Target"))
        let (spectrum, bands, loudness) = loudSubBassInput()
        let otherGrid = Fixture.spectrum(bins: 512) { _ in -30 }
        let stop = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        let running = ManagedAtomicFlag()

        // "Main thread": thresholds, resets, a second grid (invalidates both caches).
        for worker in 0..<2 {
            done.enter()
            DispatchQueue.global().async {
                var i = 0
                while running.isSet {
                    var t = StressThresholds()
                    t.holdSeconds = Double(i % 5)
                    t.subBassLoadDBFS = -24 - Float(i % 7)
                    model.thresholds = t
                    if i % 3 == worker { model.resetFlags() }
                    if i % 11 == 0 { _ = model.stressFlags(spectrum: otherGrid, bands: bands, loudness: loudness) }
                    _ = model.thresholds
                    i += 1
                }
                done.leave()
            }
        }
        // "Analysis queue".
        var evaluations = 0
        let end = ProcessInfo.processInfo.systemUptime + 0.6
        while ProcessInfo.processInfo.systemUptime < end {
            let reading = model.evaluate(spectrum: spectrum, bands: bands, loudness: loudness)
            XCTAssertEqual(reading.predictedAtEarDB.count, 1024)
            XCTAssertEqual(reading.responseDB.count, 1024)
            evaluations += 1
        }
        running.clear()
        stop.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertGreaterThan(evaluations, 100)
    }

    /// Budget from the spec: `evaluate` stays under 0.2 ms on a 1024-bin grid, lock included.
    func testEvaluateStaysUnderBudget() {
        let model = HeadphoneModel(curve: Fixture.curve(name: "Rolled") { hz in hz < 60 ? -12 : 0 }, target: Fixture.flatCurve(name: "Target"))
        let (spectrum, bands, loudness) = loudSubBassInput()
        for _ in 0..<50 { _ = model.evaluate(spectrum: spectrum, bands: bands, loudness: loudness) }
        let runs = 2000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<runs { _ = model.evaluate(spectrum: spectrum, bands: bands, loudness: loudness) }
        let meanMS = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(runs) / 1e6
        print("HeadphoneModel.evaluate mean \(String(format: "%.4f", meanMS)) ms")
        #if DEBUG
        XCTAssertLessThan(meanMS, 2.0)
        #else
        XCTAssertLessThan(meanMS, 0.2)
        #endif
    }
}

/// A stop flag two threads can share.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var isSet: Bool { lock.withLock { value } }
    func clear() { lock.withLock { value = false } }
}
