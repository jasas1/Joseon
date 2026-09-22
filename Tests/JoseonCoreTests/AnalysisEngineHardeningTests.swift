import XCTest
@testable import JoseonCore

final class AnalysisEngineHardeningTests: XCTestCase {
    /// Counts `process` calls and samples; passes everything on to a real stereo analyzer.
    private final class CountingStereo: StereoAnalyzing {
        let inner = StereoAnalyzer()
        var calls = 0
        var samples = 0
        var sawNonFinite = false
        var scopePointCount: Int {
            get { inner.scopePointCount }
            set { inner.scopePointCount = newValue }
        }
        func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, sampleRate: Double) {
            calls += 1
            samples += count
            for i in 0..<count where !left[i].isFinite || !right[i].isFinite { sawNonFinite = true }
            inner.process(left: left, right: right, count: count, sampleRate: sampleRate)
        }
        func read() -> StereoReading { inner.read() }
        func reset() { inner.reset() }
    }

    private func wait(_ seconds: TimeInterval) {
        let e = expectation(description: "wait")
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: seconds + 5)
    }

    // MARK: Timer lifetime

    func testReleaseWhileRunningDoesNotCrash() {
        for _ in 0..<20 {
            let ring = StereoRingBuffer()
            var engine: AnalysisEngine? = AnalysisEngine()
            engine?.start(reading: ring, ticksPerSecond: 500)
            usleep(3000)
            engine = nil        // a resumed, uncancelled dispatch source would abort here
        }
        wait(0.05)
    }

    func testStopStartAndRateChangesInAnyOrder() {
        let engine = AnalysisEngine()
        let ring = StereoRingBuffer()
        engine.stop()
        engine.setTickRate(30)          // stopped: no effect, no crash
        engine.start(reading: ring, ticksPerSecond: 200)
        engine.start(reading: StereoRingBuffer(), ticksPerSecond: 200)   // restart on a new ring
        engine.setTickRate(10)
        engine.stop()
        engine.stop()
        engine.setTickRate(60)
        engine.start(reading: ring, ticksPerSecond: 100)
        engine.stop()
    }

    /// `start` swaps the ring while ticks run, from two threads at once.
    func testConcurrentStartStopWhileTicking() {
        let engine = AnalysisEngine()
        let rings = (0..<4).map { _ in StereoRingBuffer() }
        let tone = TestSignals.sine(hz: 440, amplitude: 0.3, sampleRate: 48_000, seconds: 0.05)
        let group = DispatchGroup()
        for worker in 0..<3 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<60 {
                    let ring = rings[(i + worker) % rings.count]
                    engine.start(reading: ring, ticksPerSecond: 1000)
                    if worker == 0 { ring.write(left: tone, right: tone, count: tone.count, sampleRate: 48_000) }
                    if i % 4 == worker { engine.stop() }
                    engine.setTickRate(Double(100 + i))
                    _ = engine.latestFrame
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        engine.stop()
    }

    // MARK: isSilent

    /// Several chunks in one tick: signal first, a silent chunk last. The frame is not silent.
    func testIsSilentCoversEveryChunkOfATick() {
        let engine = AnalysisEngine()
        let ring = StereoRingBuffer()
        // More than one engine scratch block (32768 frames): 0.5 s of tone, then 0.4 s of silence.
        let tone = TestSignals.sine(hz: 1000, amplitude: 0.5, sampleRate: 48_000, seconds: 0.5)
        let silence = [Float](repeating: 0, count: 19_200)
        ring.write(left: tone, right: tone, count: tone.count, sampleRate: 48_000)
        ring.write(left: silence, right: silence, count: silence.count, sampleRate: 48_000)
        engine.start(reading: ring, ticksPerSecond: 1)      // first tick at once, the next after 1 s
        wait(0.2)
        let frame = engine.latestFrame
        engine.stop()
        XCTAssertGreaterThan(frame.hostTime, 0)
        XCTAssertFalse(frame.isSilent, "signal in an earlier chunk of the tick: the frame is not silent")
    }

    func testProcessNowSilenceFlag() {
        let engine = AnalysisEngine()
        let tone = TestSignals.sine(hz: 1000, amplitude: 0.5, sampleRate: 48_000, seconds: 0.05)
        let zeros = [Float](repeating: 0, count: 2400)
        XCTAssertFalse(engine.processNow(left: tone, right: tone, count: tone.count, sampleRate: 48_000).isSilent)
        XCTAssertTrue(engine.processNow(left: zeros, right: zeros, count: zeros.count, sampleRate: 48_000).isSilent)
        XCTAssertFalse(engine.processNow(left: zeros, right: tone, count: zeros.count, sampleRate: 48_000).isSilent)
    }

    /// A tick with no new samples keeps the frame: consumers see the same `hostTime` and skip their work.
    func testNoNewSamplesKeepsTheFrame() throws {
        let engine = AnalysisEngine()
        let ring = StereoRingBuffer()
        let tone = TestSignals.sine(hz: 1000, amplitude: 0.5, sampleRate: 48_000, seconds: 0.05)
        ring.write(left: tone, right: tone, count: tone.count, sampleRate: 48_000)
        let started = ProcessInfo.processInfo.systemUptime
        engine.start(reading: ring, ticksPerSecond: 200)
        wait(0.03)
        let first = engine.latestFrame
        wait(0.08)      // about 16 ticks, no samples, not yet stale
        let second = engine.latestFrame
        let info = StreamInfo(sampleRate: 48_000, channelCount: 2, deviceName: "Test device")
        engine.streamInfo = info
        wait(0.04)
        let third = engine.latestFrame
        engine.stop()
        // On a busy Mac the waits can run long; after 0.25 s the input counts as stale and zeros flow.
        try XCTSkipIf(ProcessInfo.processInfo.systemUptime - started > AnalysisEngine.staleAfterSeconds - 0.02, "too slow to test")
        XCTAssertGreaterThan(first.hostTime, 0)
        XCTAssertEqual(first.hostTime, second.hostTime)
        XCTAssertEqual(third.hostTime, first.hostTime)
        XCTAssertEqual(third.stream, info, "stream facts reach the frame also without new audio")
    }

    /// Analysis slower than real time (a DEBUG build at 96 kHz) must still end its tick and publish frames.
    func testSlowAnalysisStillPublishes() {
        final class SlowStereo: StereoAnalyzing {
            var scopePointCount = 0
            func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, sampleRate: Double) { usleep(30_000) }
            func read() -> StereoReading { StereoReading() }
            func reset() {}
        }
        let engine = AnalysisEngine(stereo: SlowStereo())
        let ring = StereoRingBuffer()
        let tone = TestSignals.sine(hz: 1000, amplitude: 0.5, sampleRate: 48_000, seconds: 0.01)
        let writer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "test.writer"))
        writer.schedule(deadline: .now(), repeating: .milliseconds(5))
        writer.setEventHandler { ring.write(left: tone, right: tone, count: tone.count, sampleRate: 48_000) }
        writer.resume()
        engine.start(reading: ring, ticksPerSecond: 100)
        wait(0.4)
        let first = engine.latestFrame.hostTime
        wait(0.4)
        let second = engine.latestFrame.hostTime
        engine.stop()
        writer.cancel()
        XCTAssertGreaterThan(first, 0, "the first tick must end and publish")
        XCTAssertGreaterThan(second, first, "later ticks publish too")
    }

    // MARK: Non-finite input

    func testNonFiniteSamplesNeverReachTheAnalyzers() {
        let stereo = CountingStereo()
        let engine = AnalysisEngine(stereo: stereo)
        var left = TestSignals.sine(hz: 1000, amplitude: 0.5, sampleRate: 48_000, seconds: 0.2)
        var right = left
        left[100] = .nan
        right[2000] = .infinity
        left[3000] = -.infinity
        var frame = engine.processNow(left: left, right: right, count: left.count, sampleRate: 48_000)
        XCTAssertEqual(engine.sanitizedBlockCount, 1)
        XCTAssertFalse(stereo.sawNonFinite)
        XCTAssertFalse(frame.isSilent)

        // The next clean blocks read like a clean run: nothing is poisoned.
        let clean = TestSignals.sine(hz: 1000, amplitude: 0.5, sampleRate: 48_000, seconds: 1.0)
        frame = engine.processNow(left: clean, right: clean, count: clean.count, sampleRate: 48_000)
        XCTAssertEqual(engine.sanitizedBlockCount, 1)
        XCTAssertEqual(frame.stereo.correlation, 1, accuracy: 0.01)
        XCTAssertTrue(frame.loudness.momentaryLUFS.isFinite)
        XCTAssertGreaterThan(frame.loudness.momentaryLUFS, -20)
        XCTAssertTrue(frame.loudness.truePeakMaxDBTP.isFinite)
        XCTAssertLessThan(frame.loudness.truePeakMaxDBTP, 1)
        XCTAssertTrue(frame.spectrum.mid.allSatisfy { $0.isFinite })
        let bin = frame.spectrum.frequencies.firstIndex { $0 >= 1000 } ?? 0
        XCTAssertGreaterThan(frame.spectrum.mid[bin], -12)
    }

    func testABlockOfOnlyNaNCountsAsSilence() {
        let engine = AnalysisEngine()
        let bad = [Float](repeating: .nan, count: 4800)
        let frame = engine.processNow(left: bad, right: bad, count: bad.count, sampleRate: 48_000)
        XCTAssertTrue(frame.isSilent)
        XCTAssertEqual(frame.stereo.correlation, 0)
        XCTAssertLessThanOrEqual(frame.loudness.momentaryLUFS, -100)
    }

    // MARK: Stereo on demand

    func testStereoAnalysisCanPauseAndRestartsFromAReset() {
        let stereo = CountingStereo()
        let engine = AnalysisEngine(stereo: stereo)
        let tone = TestSignals.sine(hz: 1000, amplitude: 0.5, sampleRate: 48_000, seconds: 0.5)
        let inverted = tone.map { -$0 }
        XCTAssertEqual(engine.processNow(left: tone, right: inverted, count: tone.count, sampleRate: 48_000).stereo.correlation, -1, accuracy: 0.02)

        engine.analyzesStereo = false
        let paused = engine.processNow(left: tone, right: inverted, count: tone.count, sampleRate: 48_000)
        XCTAssertEqual(stereo.calls, 1, "paused: the stereo analyzer does not run")
        XCTAssertEqual(paused.stereo.correlation, 0)
        XCTAssertTrue(paused.stereo.scopePoints.isEmpty)
        XCTAssertGreaterThan(paused.loudness.momentaryLUFS, -20, "the other analyzers keep running")

        engine.analyzesStereo = true
        let resumed = engine.processNow(left: tone, right: tone, count: tone.count, sampleRate: 48_000)
        XCTAssertEqual(stereo.calls, 2)
        XCTAssertEqual(resumed.stereo.correlation, 1, accuracy: 0.02, "no anti-phase state left from before the pause")
    }

    // MARK: Sleep on silence

    /// After the decays end, zeros do not go through the analyzers. Signal wakes the engine at once.
    func testEngineSleepsOnLongSilenceAndWakesOnSignal() {
        let stereo = CountingStereo()
        let engine = AnalysisEngine(stereo: stereo)
        engine.sleepsInProcessNow = true
        var settings = SpectrumSettings()
        settings.peakDecayDBPerSecond = 48
        engine.updateSpectrumSettings(settings)
        let tone = TestSignals.sine(hz: 1000, amplitude: 0.5, sampleRate: 48_000, seconds: 0.5)
        let zeros = [Float](repeating: 0, count: 4800)
        _ = engine.processNow(left: tone, right: tone, count: tone.count, sampleRate: 48_000)

        var secondsToSleep: Double?
        for block in 0..<600 {      // up to 60 s of silence
            let frame = engine.processNow(left: zeros, right: zeros, count: zeros.count, sampleRate: 48_000)
            XCTAssertTrue(frame.isSilent)
            if engine.isAsleep { secondsToSleep = Double(block + 1) * 0.1; break }
        }
        guard let secondsToSleep else { return XCTFail("the engine never went to sleep") }
        print("engine asleep after \(secondsToSleep) s of silence")
        XCTAssertGreaterThanOrEqual(secondsToSleep, AnalysisEngine.sleepAfterSilentSeconds)
        XCTAssertLessThan(secondsToSleep, 30)

        let callsAtSleep = stereo.calls
        var asleepFrame = engine.latestFrame
        for _ in 0..<50 { asleepFrame = engine.processNow(left: zeros, right: zeros, count: zeros.count, sampleRate: 48_000) }
        XCTAssertEqual(stereo.calls, callsAtSleep, "asleep: zeros do not reach the analyzers")
        XCTAssertTrue(asleepFrame.isSilent)
        XCTAssertTrue(AnalysisEngine.isAtRest(asleepFrame))

        let awake = engine.processNow(left: tone, right: tone, count: tone.count, sampleRate: 48_000)
        XCTAssertFalse(engine.isAsleep)
        XCTAssertFalse(awake.isSilent)
        XCTAssertEqual(stereo.calls, callsAtSleep + 1)
        let bin = awake.spectrum.frequencies.firstIndex { $0 >= 1000 } ?? 0
        XCTAssertGreaterThan(awake.spectrum.mid[bin], -12)

        // A reset wakes it too (the frame must show the reset), then it sleeps again.
        for _ in 0..<600 where !engine.isAsleep { _ = engine.processNow(left: zeros, right: zeros, count: zeros.count, sampleRate: 48_000) }
        XCTAssertTrue(engine.isAsleep)
        engine.resetMeasurement()
        let callsBeforeReset = stereo.calls
        _ = engine.processNow(left: zeros, right: zeros, count: zeros.count, sampleRate: 48_000)
        XCTAssertGreaterThan(stereo.calls, callsBeforeReset)
    }

    func testProcessNowNeverSleepsByDefault() {
        let stereo = CountingStereo()
        let engine = AnalysisEngine(stereo: stereo)
        let zeros = [Float](repeating: 0, count: 48_000)
        for _ in 0..<30 { _ = engine.processNow(left: zeros, right: zeros, count: zeros.count, sampleRate: 48_000) }
        XCTAssertFalse(engine.isAsleep)
        XCTAssertEqual(stereo.calls, 30)
    }

    /// A stalled source feeds zeros, but never more than 1.5 ticks of them per tick.
    func testStaleFeedIsCappedPerTick() {
        let stereo = CountingStereo()
        let engine = AnalysisEngine(stereo: stereo)
        engine.start(reading: StereoRingBuffer(), ticksPerSecond: 50)
        wait(1.25)
        engine.stop()
        wait(0.05)
        // About 1 s stale at 48 kHz. Real time is the upper bound (plus scheduling slack).
        XCTAssertGreaterThan(stereo.samples, 24_000)
        XCTAssertLessThan(stereo.samples, 60_000)
        XCTAssertLessThanOrEqual(stereo.samples / max(stereo.calls, 1), Int(48_000 * 0.02 * 1.5) + 1)
    }
}
