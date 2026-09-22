import XCTest
@testable import JoseonCore

/// The engine end of the session recorder: one ingest per published frame, audio-time `dt`,
/// a `trackStart` on a measurement reset, and silence events that survive the sleep-on-silence path.
final class SessionEngineTests: XCTestCase {

    private let rate = 48_000.0
    private let block = 800     // one 60 Hz tick

    private func run(_ engine: AnalysisEngine, left: [Float], right: [Float]) -> AnalysisFrame {
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                engine.processNow(left: l.baseAddress!, right: r.baseAddress!, count: left.count, sampleRate: rate)
            }
        }
    }

    /// Twelve seconds of the demo signal make about twelve samples, with sane numbers in them.
    func testTwelveSecondsOfDemoAudio() throws {
        let engine = AnalysisEngine()
        for tick in 0..<(12 * 60) {
            let audio = TestSignals.demoBlock(startSample: tick * block, count: block, sampleRate: rate)
            _ = run(engine, left: audio.left, right: audio.right)
        }

        let snapshot = engine.session.snapshot()
        XCTAssertEqual(engine.session.capacitySeconds, 1800, "30 minutes by default")
        XCTAssertEqual(Double(snapshot.samples.count), 12, accuracy: 1, "about one sample per second of audio")
        let last = try XCTUnwrap(snapshot.samples.last)
        XCTAssertEqual(last.time, Double(snapshot.samples.count), accuracy: 0.05, "audio time, one second per sample")

        // The demo signal is music-like: loud, mostly in phase, never clipped, never silent.
        for sample in snapshot.samples.dropFirst() {
            XCTAssertGreaterThan(sample.momentaryMaxLUFS, -30, "the demo signal is not quiet")
            XCTAssertLessThan(sample.momentaryMaxLUFS, 0)
            XCTAssertGreaterThan(sample.shortTermLUFS, -40)
            XCTAssertLessThan(sample.truePeakDBTP, 0, "the demo signal never goes over")
            XCTAssertGreaterThan(sample.truePeakDBTP, -20)
            XCTAssertGreaterThan(sample.correlation, 0.2)
            XCTAssertLessThanOrEqual(sample.correlation, 1)
            XCTAssertEqual(sample.bands.count, 8)
            XCTAssertGreaterThan(sample.bands[1], -60, "the demo signal has bass")
            XCTAssertTrue(sample.bands.allSatisfy { $0.isFinite && $0 < 6 })
            XCTAssertNil(sample.levelA, "no SPL estimator on this engine")
            XCTAssertFalse(sample.isSilent)
        }
        XCTAssertTrue(snapshot.events.filter { $0.kind == .clip || $0.kind == .interSampleOver }.isEmpty,
                      "the demo signal has no clips and no overs")

        // A measurement reset is a new track, and the event reaches the record with the next frame.
        let eventsBefore = snapshot.events.count
        engine.resetMeasurement()
        let audio = TestSignals.demoBlock(startSample: 12 * 60 * block, count: block, sampleRate: rate)
        _ = run(engine, left: audio.left, right: audio.right)
        let after = engine.session.snapshot()
        XCTAssertEqual(after.events.count, eventsBefore + 1)
        let event = try XCTUnwrap(after.events.last)
        XCTAssertEqual(event.kind, .trackStart)
        XCTAssertEqual(event.time, last.time, accuracy: 1.1, "at the point of the reset on the audio axis")
        XCTAssertGreaterThan(after.revision, snapshot.revision)
    }

    /// The engine stops analyzing after seconds of digital silence. The record must still say
    /// "silence here", and the sleep must not stretch the audio axis.
    func testSilenceEventsSurviveTheSleepPath() throws {
        let clock = ManualClock()
        let recorder = SessionRecorder(capacitySeconds: 600, now: clock.read)
        let engine = AnalysisEngine(session: recorder)
        engine.sleepsInProcessNow = true
        var settings = SpectrumSettings()
        settings.peakDecayDBPerSecond = 48          // reach the rest state quickly
        engine.updateSpectrumSettings(settings)

        let tone = TestSignals.sine(hz: 1_000, amplitude: 0.5, sampleRate: rate, seconds: 0.1)
        let zeros = [Float](repeating: 0, count: 4_800)
        for _ in 0..<10 {                            // 1 s of signal
            clock.advance(0.1)
            _ = run(engine, left: tone, right: tone)
        }
        var silentBlocks = 0
        for _ in 0..<600 where !engine.isAsleep {    // silence until the engine sleeps
            clock.advance(0.1)
            _ = run(engine, left: zeros, right: zeros)
            silentBlocks += 1
        }
        XCTAssertTrue(engine.isAsleep, "the engine must reach the sleep path for this test")
        let audioTimeAtSleep = try XCTUnwrap(recorder.snapshot().samples.last).time

        for _ in 0..<100 {                           // 10 s of wall time asleep: no analysis, no audio time
            clock.advance(0.1)
            _ = run(engine, left: zeros, right: zeros)
        }
        let asleepSnapshot = recorder.snapshot()
        XCTAssertEqual(try XCTUnwrap(asleepSnapshot.samples.last).time, audioTimeAtSleep,
                       "the sleep does not stretch the axis")
        let starts = asleepSnapshot.events.filter { $0.kind == .silenceStart }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts[0].time, 1.0, accuracy: 0.2, "silence began when the tone stopped")
        XCTAssertEqual(starts[0].date.timeIntervalSinceReferenceDate, 1.0, accuracy: 0.2)

        clock.advance(0.1)
        _ = run(engine, left: tone, right: tone)
        let awake = recorder.snapshot()
        let ends = awake.events.filter { $0.kind == .silenceEnd }
        XCTAssertEqual(ends.count, 1)
        XCTAssertEqual(ends[0].time, audioTimeAtSleep, accuracy: 1.1, "the axis carried on where it stopped")
        XCTAssertEqual(ends[0].date.timeIntervalSinceReferenceDate,
                       1 + Double(silentBlocks) * 0.1 + 10.1, accuracy: 0.2, "the wall-clock date of the wake-up")
        XCTAssertLessThan(ends[0].time, ends[0].date.timeIntervalSinceReferenceDate - 9,
                          "ten seconds of wall time are not ten seconds of the timeline")
    }

    /// The recorder and the SPL estimator get the same audio `dt`: the level at the ear reaches the samples.
    func testLevelAtTheEarReachesTheSamples() throws {
        final class FixedSPL: SPLEstimating {
            var seconds: Double = 0
            func evaluate(thirdOctave: ThirdOctaveReading, dt: Double, isSilent: Bool) -> SPLReading {
                seconds += dt
                return SessionTestFrame.splReading(levelASlow: 83)
            }
            func resetMeasurement() {}
            func resetDose() {}
        }
        let estimator = FixedSPL()
        let engine = AnalysisEngine()
        engine.splEstimator = estimator
        for tick in 0..<(3 * 60) {
            let audio = TestSignals.demoBlock(startSample: tick * block, count: block, sampleRate: rate)
            _ = run(engine, left: audio.left, right: audio.right)
        }
        // The estimator starts when the spectrum analyzer can give third-octave bands (a short warm-up),
        // so it sees a little less than the 3 s the recorder's axis holds.
        XCTAssertGreaterThan(estimator.seconds, 2)
        XCTAssertLessThanOrEqual(estimator.seconds, 3.001, "audio seconds, never more")
        let samples = engine.session.snapshot().samples
        XCTAssertGreaterThanOrEqual(samples.count, 2)
        XCTAssertLessThanOrEqual(samples.count, 3)
        for sample in samples { XCTAssertEqual(try XCTUnwrap(sample.levelA), 83, accuracy: 0.001) }
    }
}
