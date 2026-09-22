import XCTest
@testable import JoseonCore

final class SessionRecorderTests: XCTestCase {

    private func makeRecorder(capacity: Int = 10, clock: ManualClock = ManualClock()) -> SessionRecorder {
        SessionRecorder(capacitySeconds: capacity, now: clock.read)
    }

    // MARK: Per-second aggregation

    /// Two half-second frames make one sample: max, last, and the means in the right domain.
    func testOneSecondOfFramesMakesOneSample() throws {
        let recorder = makeRecorder()
        recorder.ingest(SessionTestFrame.make(momentary: -20, shortTerm: -22, truePeakLeft: -1, truePeakRight: -3,
                                              correlation: 0.2, bandsDB: 0, levelA: 80), dt: 0.5)
        XCTAssertTrue(recorder.snapshot().samples.isEmpty, "half a second is not a sample yet")
        recorder.ingest(SessionTestFrame.make(momentary: -14, shortTerm: -18, truePeakLeft: -2, truePeakRight: -0.5,
                                              correlation: 0.8, bandsDB: -20, levelA: 90), dt: 0.5)

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.samples.count, 1)
        let s = try XCTUnwrap(snapshot.samples.first)
        XCTAssertEqual(s.time, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.momentaryMaxLUFS, -14, "max of the momentary values")
        XCTAssertEqual(s.shortTermLUFS, -18, "the last short-term value of the second")
        XCTAssertEqual(s.truePeakDBTP, -0.5, accuracy: 1e-6, "max true peak of the louder channel")
        XCTAssertEqual(s.correlation, 0.5, accuracy: 1e-6, "mean correlation")
        XCTAssertEqual(s.bands.count, 8)
        // Mean POWER of 0 dB and -20 dB = (1 + 0.01) / 2 = 0.505 -> -2.966 dB. A mean of the
        // decibels would be -10 dB.
        for band in s.bands { XCTAssertEqual(band, -2.966, accuracy: 0.01) }
        // Mean ENERGY of 80 and 90 dB SPL = (1e8 + 1e9) / 2 -> 87.40 dB.
        XCTAssertEqual(try XCTUnwrap(s.levelA), 87.404, accuracy: 0.01)
        XCTAssertFalse(s.isSilent)
    }

    func testSilentSecondNeedsEverySilentFrame() {
        let recorder = makeRecorder()
        for i in 0..<4 {
            recorder.ingest(SessionTestFrame.make(isSilent: i != 2), dt: 0.25)
        }
        XCTAssertEqual(recorder.snapshot().samples.first?.isSilent, false)
        for _ in 0..<4 { recorder.ingest(SessionTestFrame.make(isSilent: true), dt: 0.25) }
        XCTAssertEqual(recorder.snapshot().samples.last?.isSilent, true)
    }

    func testLevelAIsNilWhenNoEstimateArrives() {
        let recorder = makeRecorder()
        recorder.ingest(SessionTestFrame.make(), dt: 1)
        XCTAssertNil(recorder.snapshot().samples.first?.levelA)
    }

    // MARK: The ring

    func testRingWrapsAtCapacityAndKeepsTheNewest() {
        let recorder = makeRecorder(capacity: 4)
        for second in 1...10 {
            recorder.ingest(SessionTestFrame.make(momentary: Float(-60 + second)), dt: 1)
        }
        let samples = recorder.snapshot().samples
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples.map { $0.time }, [7, 8, 9, 10])
        XCTAssertEqual(samples.map { $0.momentaryMaxLUFS }, [-53, -52, -51, -50])
    }

    func testPartialSecondIsCarriedOverNotLost() {
        let recorder = makeRecorder()
        // 0.75 s steps: the leftover of every second is carried into the next one.
        for _ in 0..<5 { recorder.ingest(SessionTestFrame.make(), dt: 0.75) }
        let samples = recorder.snapshot().samples
        XCTAssertEqual(samples.map { $0.time }, [1, 2, 3])
    }

    // MARK: Clocks

    /// The axis is audio time. Wall time may run far ahead (or stand still): only the dates follow it.
    func testAudioTimeClockIgnoresWallTime() {
        let clock = ManualClock(start: Date(timeIntervalSinceReferenceDate: 1_000))
        let recorder = makeRecorder(clock: clock)
        for _ in 0..<8 {
            clock.advance(60)       // a minute of wall time per frame
            recorder.ingest(SessionTestFrame.make(), dt: 0.25)
        }
        let samples = recorder.snapshot().samples
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].time, 1.0, accuracy: 1e-9, "audio time, not wall time")
        XCTAssertEqual(samples[1].time, 2.0, accuracy: 1e-9)
        XCTAssertEqual(samples[0].date.timeIntervalSinceReferenceDate, 1_000 + 4 * 60, accuracy: 1e-6)
        XCTAssertEqual(samples[1].date.timeIntervalSinceReferenceDate, 1_000 + 8 * 60, accuracy: 1e-6)
    }

    func testFramesWithoutNewAudioDoNotMoveTheClock() {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        for _ in 0..<100 {
            clock.advance(1.0 / 60)
            recorder.ingest(SessionTestFrame.make(), dt: 0)
        }
        XCTAssertTrue(recorder.snapshot().samples.isEmpty, "no audio, no samples")
    }

    // MARK: Events — silence

    func testSilenceEventsFromAudioTime() {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        for _ in 0..<8 {                    // 4 s of silence in 0.5 s steps
            clock.advance(0.5)
            recorder.ingest(SessionTestFrame.make(isSilent: true), dt: 0.5)
        }
        var events = recorder.snapshot().events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .silenceStart)
        XCTAssertEqual(events[0].time, 0, accuracy: 1e-9, "the start of the silence, not where it was noticed")

        clock.advance(0.5)
        recorder.ingest(SessionTestFrame.make(momentary: -20, isSilent: false), dt: 0.5)
        events = recorder.snapshot().events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].kind, .silenceEnd)
        XCTAssertEqual(events[1].time, 4.5, accuracy: 1e-9)
        XCTAssertEqual(events[1].date.timeIntervalSinceReferenceDate, 4.5, accuracy: 1e-6)
        XCTAssertGreaterThan(events[1].id, events[0].id)
    }

    func testShortSilenceMakesNoEvent() {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        for _ in 0..<3 {
            clock.advance(0.5)
            recorder.ingest(SessionTestFrame.make(isSilent: true), dt: 0.5)     // 1.5 s only
        }
        clock.advance(0.5)
        recorder.ingest(SessionTestFrame.make(isSilent: false), dt: 0.5)
        XCTAssertTrue(recorder.snapshot().events.isEmpty)
    }

    /// The engine sleeps on silence: it stops publishing, or publishes frames with `dt` 0.
    /// The gap in wall time is the silence.
    func testSilenceEventsFromAWallClockGapWhileDTIsZero() {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        clock.advance(0.1)
        recorder.ingest(SessionTestFrame.make(momentary: -20), dt: 0.1)
        clock.advance(3)                    // the engine slept for 3 s
        recorder.ingest(SessionTestFrame.make(isSilent: true), dt: 0)
        var events = recorder.snapshot().events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .silenceStart)
        XCTAssertEqual(events[0].time, 0.1, accuracy: 1e-9, "audio time did not move during the gap")
        XCTAssertEqual(events[0].date.timeIntervalSinceReferenceDate, 0.1, accuracy: 1e-6, "wall-clock date of the gap start")

        clock.advance(10)
        recorder.ingest(SessionTestFrame.make(momentary: -20, isSilent: false), dt: 0.1)
        events = recorder.snapshot().events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1].kind, .silenceEnd)
        XCTAssertEqual(events[1].time, 0.2, accuracy: 1e-9, "the 13 s gap did not stretch the axis")
        XCTAssertEqual(events[1].date.timeIntervalSinceReferenceDate, 13.1, accuracy: 1e-6)
    }

    // MARK: Events — clipping

    func testClipEventCountsNewRunsOncePerSecond() {
        let recorder = makeRecorder()
        recorder.ingest(SessionTestFrame.make(clipCount: 2), dt: 0.5)
        recorder.ingest(SessionTestFrame.make(clipCount: 5), dt: 0.5)      // 5 new runs in second 1
        recorder.ingest(SessionTestFrame.make(clipCount: 5), dt: 1)        // nothing new in second 2
        let events = recorder.snapshot().events
        XCTAssertEqual(events.count, 1, "at most one clip event per second")
        XCTAssertEqual(events[0].kind, .clip)
        XCTAssertEqual(events[0].value, 5)
        XCTAssertEqual(events[0].time, 1.0, accuracy: 1e-9)
    }

    func testAClipCountThatFallsIsANewBaselineNotNegativeClips() {
        let recorder = makeRecorder()
        recorder.ingest(SessionTestFrame.make(clipCount: 7), dt: 1)
        // A measurement reset: the meter starts from 0 and clips again.
        recorder.ingest(SessionTestFrame.make(clipCount: 3), dt: 1)
        recorder.ingest(SessionTestFrame.make(clipCount: 4), dt: 1)
        let events = recorder.snapshot().events
        XCTAssertEqual(events.map { $0.kind }, [.clip, .clip])
        XCTAssertEqual(events[0].value, 7)
        XCTAssertEqual(events[1].value, 1, "3 -> 4 is one new run; the fall from 7 is not counted")
        XCTAssertTrue(events.allSatisfy { $0.value >= 0 })
    }

    func testNoteTrackStartRebasesTheClipCount() {
        let recorder = makeRecorder()
        recorder.ingest(SessionTestFrame.make(clipCount: 9), dt: 1)
        recorder.noteTrackStart()
        recorder.ingest(SessionTestFrame.make(clipCount: 6), dt: 1)     // a fresh meter that clipped 6 times
        let clips = recorder.snapshot().events.filter { $0.kind == .clip }
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[1].value, 6, "after a track start the whole new count is new")
    }

    // MARK: Events — inter-sample overs

    func testInterSampleOverIsOnePerSecondWithTheMaximum() {
        let recorder = makeRecorder()
        recorder.ingest(SessionTestFrame.make(truePeakLeft: 0.8, truePeakRight: -3), dt: 0.5)
        recorder.ingest(SessionTestFrame.make(truePeakLeft: -3, truePeakRight: 1.5), dt: 0.5)
        recorder.ingest(SessionTestFrame.make(truePeakLeft: -0.2, truePeakRight: -0.3), dt: 1)
        let events = recorder.snapshot().events
        XCTAssertEqual(events.count, 1, "one event for the second, none while under 0 dBTP")
        XCTAssertEqual(events[0].kind, .interSampleOver)
        XCTAssertEqual(events[0].value, 1.5, accuracy: 1e-6)
        XCTAssertEqual(recorder.snapshot().samples[0].truePeakDBTP, 1.5, accuracy: 1e-6)
    }

    // MARK: Events — stress flags

    func testStressFlagsAreDiffedNotRepeated() {
        let recorder = makeRecorder()
        let sub = SessionTestFrame.flag("subBassLoad", title: "Sub-bass load high", severity: .high)
        let dense = SessionTestFrame.flag("denseMaster", title: "Dense master")
        // The flag holds for 30 frames (hysteresis keeps it up): one raised event, not 30.
        for _ in 0..<30 { recorder.ingest(SessionTestFrame.make(flags: [sub]), dt: 1.0 / 60) }
        for _ in 0..<30 { recorder.ingest(SessionTestFrame.make(flags: [sub, dense]), dt: 1.0 / 60) }
        for _ in 0..<30 { recorder.ingest(SessionTestFrame.make(flags: [dense]), dt: 1.0 / 60) }
        for _ in 0..<30 { recorder.ingest(SessionTestFrame.make(flags: []), dt: 1.0 / 60) }

        let events = recorder.snapshot().events
        XCTAssertEqual(events.map { $0.kind }, [.stressFlagRaised, .stressFlagRaised, .stressFlagCleared, .stressFlagCleared])
        XCTAssertEqual(events[0].label, "Sub-bass load high")
        XCTAssertEqual(events[0].detail, "subBassLoad")
        XCTAssertEqual(events[0].value, Float(StressFlag.Severity.high.rawValue))
        XCTAssertEqual(events[1].detail, "denseMaster")
        XCTAssertEqual(events[2].detail, "subBassLoad")
        XCTAssertEqual(events[3].detail, "denseMaster")
        XCTAssertEqual(events.map { $0.id }, [1, 2, 3, 4], "ids rise monotonically")
    }

    func testTrackStartEvent() {
        let clock = ManualClock()
        let recorder = makeRecorder(clock: clock)
        clock.advance(2)
        recorder.ingest(SessionTestFrame.make(), dt: 2)
        recorder.noteTrackStart()
        let events = recorder.snapshot().events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .trackStart)
        XCTAssertEqual(events[0].time, 2.0, accuracy: 1e-9)
        XCTAssertEqual(events[0].date.timeIntervalSinceReferenceDate, 2, accuracy: 1e-6)
    }

    // MARK: Event housekeeping

    func testEventsOlderThanTheOldestSampleAreDropped() {
        let recorder = makeRecorder(capacity: 3)
        recorder.noteTrackStart()                                   // at time 0
        for _ in 0..<2 { recorder.ingest(SessionTestFrame.make(), dt: 1) }
        XCTAssertEqual(recorder.snapshot().events.count, 1, "still inside the record")
        for _ in 0..<5 { recorder.ingest(SessionTestFrame.make(), dt: 1) }
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.samples.map { $0.time }, [5, 6, 7])
        XCTAssertTrue(snapshot.events.isEmpty, "the event is older than the oldest second")
    }

    func testEventsAreCappedAtTwoThousand() {
        let recorder = makeRecorder()
        for _ in 0..<2_500 { recorder.noteTrackStart() }
        let events = recorder.snapshot().events
        XCTAssertEqual(events.count, SessionRecorder.maxEvents)
        XCTAssertEqual(events.first?.id, 501, "the oldest went first")
        XCTAssertEqual(events.last?.id, 2_500)
        XCTAssertEqual(events.map { $0.id }, Array(501...2_500))
    }

    // MARK: Revision and clear

    func testRevisionRisesOnEverySampleAndEvent() {
        let recorder = makeRecorder()
        XCTAssertEqual(recorder.snapshot().revision, 0)
        recorder.ingest(SessionTestFrame.make(), dt: 0.5)
        XCTAssertEqual(recorder.snapshot().revision, 0, "nothing closed yet")
        recorder.ingest(SessionTestFrame.make(), dt: 0.5)
        let afterSample = recorder.snapshot().revision
        XCTAssertEqual(afterSample, 1)
        recorder.noteTrackStart()
        XCTAssertEqual(recorder.snapshot().revision, afterSample + 1)
    }

    func testClearForgetsEverythingAndRestartsTheClock() {
        let recorder = makeRecorder()
        for _ in 0..<3 { recorder.ingest(SessionTestFrame.make(clipCount: 1), dt: 1) }
        recorder.noteTrackStart()
        XCTAssertFalse(recorder.snapshot().samples.isEmpty)
        let before = recorder.snapshot().revision

        recorder.clear()
        let empty = recorder.snapshot()
        XCTAssertTrue(empty.samples.isEmpty)
        XCTAssertTrue(empty.events.isEmpty)
        XCTAssertGreaterThan(empty.revision, before, "panels see that the record changed")

        recorder.ingest(SessionTestFrame.make(momentary: -12), dt: 1)
        let after = recorder.snapshot()
        XCTAssertEqual(after.samples.count, 1)
        XCTAssertEqual(after.samples[0].time, 1.0, accuracy: 1e-9, "the audio clock starts again")
        XCTAssertEqual(after.samples[0].momentaryMaxLUFS, -12)
        XCTAssertTrue(after.events.isEmpty, "no clip event from the count before the clear")
    }

    // MARK: Bad input

    func testNonFiniteReadingsNeverReachASample() throws {
        let recorder = makeRecorder()
        recorder.ingest(SessionTestFrame.make(momentary: .nan, shortTerm: .infinity, truePeakLeft: .nan,
                                              truePeakRight: -.infinity, correlation: .nan, bandsDB: .nan,
                                              levelA: .nan), dt: 1)
        let s = recorder.snapshot().samples[0]
        XCTAssertTrue(s.momentaryMaxLUFS.isFinite)
        XCTAssertTrue(s.shortTermLUFS.isFinite)
        XCTAssertTrue(s.truePeakDBTP.isFinite)
        XCTAssertTrue(s.correlation.isFinite)
        XCTAssertTrue(s.bands.allSatisfy { $0.isFinite && $0 >= SpectrumReading.floorDB })
        XCTAssertTrue(try XCTUnwrap(s.levelA).isFinite)
        XCTAssertTrue(recorder.snapshot().events.isEmpty, "a NaN peak is not an over")
    }

    func testCapacityIsNeverZero() {
        let recorder = SessionRecorder(capacitySeconds: 0)
        recorder.ingest(SessionTestFrame.make(), dt: 1)
        recorder.ingest(SessionTestFrame.make(), dt: 1)
        XCTAssertEqual(recorder.capacitySeconds, 1)
        XCTAssertEqual(recorder.snapshot().samples.count, 1)
    }
}
