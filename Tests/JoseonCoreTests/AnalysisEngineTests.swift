import XCTest
@testable import JoseonCore

final class AnalysisEngineTests: XCTestCase {
    private final class CountingModel: HeadphoneModeling {
        let modelName = "counting"
        var resets = 0
        func evaluate(spectrum: SpectrumReading, bands: BandEnergy, loudness: LoudnessReading) -> HeadphoneReading {
            HeadphoneReading(modelName: modelName, responseDB: [], targetDB: [], predictedAtEarDB: [], stressFlags: [])
        }
        func reset() { resets += 1 }
    }

    private func wait(_ seconds: TimeInterval) {
        let e = expectation(description: "wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: seconds + 5)
    }

    func testSettingsUpdateAppliesBeforeTheNextAnalysis() {
        let engine = AnalysisEngine()
        var s = SpectrumSettings()
        s.displayBins = 512
        engine.updateSpectrumSettings(s)
        let tone = TestSignals.sine(hz: 1000, amplitude: 0.5, sampleRate: 48_000, seconds: 0.2)
        let frame = engine.processNow(left: tone, right: tone, count: tone.count, sampleRate: 48_000)
        XCTAssertEqual(frame.spectrum.frequencies.count, 512)
        XCTAssertEqual(engine.spectrum.settings, s)
    }

    func testResetMeasurementResetsTheHeadphoneModel() {
        let engine = AnalysisEngine()
        let model = CountingModel()
        engine.headphoneModel = model
        let tone = TestSignals.sine(hz: 1000, amplitude: 0.5, sampleRate: 48_000, seconds: 0.1)
        _ = engine.processNow(left: tone, right: tone, count: tone.count, sampleRate: 48_000)
        XCTAssertEqual(model.resets, 0)
        engine.resetMeasurement()
        _ = engine.processNow(left: tone, right: tone, count: tone.count, sampleRate: 48_000)
        XCTAssertEqual(model.resets, 1)
        _ = engine.processNow(left: tone, right: tone, count: tone.count, sampleRate: 48_000)
        XCTAssertEqual(model.resets, 1)
    }

    /// A source that stops delivering samples must not leave the last spectrum and meters on screen.
    func testStalledInputGoesSilentAndFalls() {
        let engine = AnalysisEngine()
        let ring = StereoRingBuffer()
        let tone = TestSignals.sine(hz: 1000, amplitude: 0.5, sampleRate: 48_000, seconds: 1.0)
        engine.start(reading: ring, ticksPerSecond: 60)
        ring.write(left: tone, right: tone, count: tone.count, sampleRate: 48_000)
        wait(0.15)
        let live = engine.latestFrame
        XCTAssertFalse(live.isSilent)
        XCTAssertGreaterThan(live.loudness.rmsLeftDB, -12)

        wait(1.6)   // no more writes: stale after 0.25 s, then zeros flow
        let stale = engine.latestFrame
        engine.stop()
        XCTAssertTrue(stale.isSilent)
        XCTAssertGreaterThan(stale.hostTime, live.hostTime)
        let bin = stale.spectrum.frequencies.firstIndex { $0 >= 1000 } ?? 0
        XCTAssertGreaterThan(live.spectrum.mid[bin], -12)
        XCTAssertLessThan(stale.spectrum.mid[bin], live.spectrum.mid[bin] - 20, "the spectrum must release")
        XCTAssertLessThan(stale.loudness.rmsLeftDB, -60, "the RMS meter must fall")
        XCTAssertLessThan(stale.loudness.momentaryLUFS, -60, "momentary loudness must fall")
    }

    func testSetTickRateChangesTheRateWithoutRestart() {
        let engine = AnalysisEngine()
        let ring = StereoRingBuffer()
        engine.start(reading: ring, ticksPerSecond: 100)
        // An empty ring gives no new frame until the input counts as stale (0.25 s); then every tick publishes.
        wait(AnalysisEngine.staleAfterSeconds + 0.1)

        func framesIn(_ seconds: TimeInterval) -> Int {
            var seen = Set<TimeInterval>()
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < end {
                seen.insert(engine.latestFrame.hostTime)
                usleep(1000)
            }
            return seen.count
        }
        let fast = framesIn(0.5)
        engine.setTickRate(10)
        wait(0.15)
        let slow = framesIn(0.5)
        engine.setTickRate(100)
        wait(0.15)
        let fastAgain = framesIn(0.5)
        engine.stop()
        XCTAssertGreaterThan(fast, 25)
        XCTAssertLessThan(slow, 12)
        XCTAssertGreaterThan(slow, 2)
        XCTAssertGreaterThan(fastAgain, 25)
    }
}
