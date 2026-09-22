import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// The session timeline: the record model (windows, spans, gaps, numbers), the picture,
/// the cursor in both directions, the keyboard, and the rule that nothing is drawn when nothing changed.
final class TimelineTests: XCTestCase {
    private static let session = SyntheticFrames.demoSession(minutes: 25)
    private static let utc = TimeZone(secondsFromGMT: 0)!

    private func settings(_ session: SessionSnapshot? = TimelineTests.session, window: Int = 900) -> OffscreenRenderer.Settings {
        var s = OffscreenRenderer.Settings()
        s.session = session; s.timelineWindowSeconds = window; s.timelineTimeZone = Self.utc; s.targetLUFS = -14
        s.timelineShowLevelAtEar = true     // the lane is opt-in since critic r6; these tests are about the lane
        return s
    }

    private func renderer(_ settings: OffscreenRenderer.Settings, size: CGSize = CGSize(width: 1200, height: 220)) throws -> (OffscreenRenderer.Session, TimelineRenderer) {
        try RenderTestSupport.requireMetal()
        let s = try OffscreenRenderer.Session(panel: .timeline, size: size, scale: 2, theme: Theme(), settings: settings)
        return (s, try XCTUnwrap(s.renderer as? TimelineRenderer))
    }

    // MARK: The demo record and the model

    func testDemoSessionHoldsWhatTheBriefAsksFor() {
        let s = Self.session
        XCTAssertEqual(s.samples.count, 25 * 60)
        XCTAssertEqual(s.events.filter { $0.kind == .trackStart }.count, 4)
        XCTAssertEqual(s.events.filter { $0.kind == .interSampleOver }.count, 1)
        XCTAssertEqual(s.events.filter { $0.kind == .silenceStart }.count, 1)
        XCTAssertGreaterThanOrEqual(s.events.filter { $0.kind == .stressFlagRaised && $0.detail == "sub-bass" }.count, 1)
        // Two clip bursts: runs of neighbor seconds.
        let clips = s.events.filter { $0.kind == .clip }.map(\.time)
        XCTAssertEqual(zip(clips, clips.dropFirst()).filter { $1 - $0 > 1.5 }.count, 1, "two bursts = one break between the clip seconds")
        XCTAssertEqual(s.samples.filter(\.isSilent).count, 20)
        // Oldest first, one per second of audio, deterministic.
        for (a, b) in zip(s.samples, s.samples.dropFirst()) { XCTAssertEqual(b.time - a.time, 1, accuracy: 1e-9) }
        XCTAssertEqual(s.events.map(\.time), s.events.map(\.time).sorted())
        XCTAssertEqual(SyntheticFrames.demoSession(minutes: 25).samples, s.samples)
        XCTAssertTrue(s.samples.allSatisfy { $0.levelA != nil })
        XCTAssertTrue(SyntheticFrames.demoSession(minutes: 25, includeLevelA: false).samples.allSatisfy { $0.levelA == nil })
        // Four tracks of different loudness.
        let starts = s.events.filter { $0.kind == .trackStart }.map { Int($0.time) }
        let means = starts.map { t0 -> Float in
            let part = s.samples[(t0 + 30)..<(t0 + 150)]
            return part.reduce(0) { $0 + $1.shortTermLUFS } / Float(part.count)
        }
        XCTAssertGreaterThan((means.max() ?? 0) - (means.min() ?? 0), 8)
    }

    func testModelCutsTheWindowAndCountsWhatItHolds() {
        let all = TimelineModel(snapshot: Self.session, windowSeconds: 1800)
        XCTAssertEqual(all.samples.count, 1500)
        XCTAssertEqual(all.stats.tracks, 4); XCTAssertEqual(all.stats.clipEvents, 8); XCTAssertEqual(all.stats.overs, 1); XCTAssertEqual(all.stats.flags, 3)
        XCTAssertEqual(all.stats.truePeakMax ?? 0, 0.4, accuracy: 1e-5)
        XCTAssertEqual(all.silences.count, 1)
        XCTAssertEqual((all.silences.first?.upperBound ?? 0) - (all.silences.first?.lowerBound ?? 0), 20, accuracy: 0.01)
        XCTAssertEqual(all.gaps.count, 1)
        XCTAssertEqual(all.gaps.first?.skippedSeconds ?? 0, 190, accuracy: 0.01)

        let five = TimelineModel(snapshot: Self.session, windowSeconds: 300)
        XCTAssertEqual(five.samples.count, 300)
        XCTAssertEqual(five.stats.tracks, 0); XCTAssertEqual(five.stats.clipEvents, 3); XCTAssertEqual(five.stats.overs, 0)
        XCTAssertTrue(five.gaps.isEmpty)
        XCTAssertTrue(five.events.allSatisfy { $0.time > five.newestTime - 300 })

        // Two flags overlap: two rows. The later sub-bass span goes back to the first row.
        XCTAssertEqual(all.spanRows, 2)
        XCTAssertEqual(all.spans.map(\.row), [0, 1, 0])
        XCTAssertEqual(all.hiddenSpans, 0)
        XCTAssertEqual(all.accessibilityValue,
                       "last 30 minutes: short-term mostly \u{2212}20 to \u{2212}9 LUFS, true peak max +0.4 dBTP, at the ear up to about 85 dB(A), 8 seconds with clipped samples, 1 true-peak over, 3 stress flags, 4 track starts, 1 pause")
        XCTAssertEqual(TimelineModel(snapshot: SessionSnapshot(), windowSeconds: 900).accessibilityValue, "last 15 minutes: nothing recorded yet")
    }

    func testSpansWithoutARaiseOrAClearAndMoreThanThreeAtOnce() {
        var s = SessionSnapshot(samples: Array(Self.session.samples.prefix(600)), events: [], revision: 1)
        func ev(_ id: Int, _ kind: SessionEvent.Kind, _ t: Double, _ flag: String) -> SessionEvent {
            SessionEvent(id: id, kind: kind, time: t, date: s.samples[Int(t) - 1].date, label: "Flag \(flag)", detail: flag)
        }
        s.events = [ev(1, .stressFlagCleared, 100, "old"),        // its raise is older than the record
                    ev(2, .stressFlagRaised, 200, "a"), ev(3, .stressFlagRaised, 210, "b"), ev(4, .stressFlagRaised, 220, "c"),
                    ev(5, .stressFlagRaised, 230, "d"), ev(6, .stressFlagRaised, 240, "e"), ev(7, .stressFlagCleared, 300, "a")]
        let m = TimelineModel(snapshot: s, windowSeconds: 900)
        let old = try? XCTUnwrap(m.spans.first { $0.flagID == "old" })
        XCTAssertEqual(old?.start, s.samples[0].time); XCTAssertEqual(old?.end, 100)
        let b = m.spans.first { $0.flagID == "b" }
        XCTAssertEqual(b?.isOpen, true); XCTAssertEqual(b?.end, m.newestTime)
        XCTAssertEqual(m.spanRows, 3)
        XCTAssertEqual(m.hiddenSpans, 2, "d and e find no row while a, b and c are up")
        XCTAssertEqual(m.stats.flags, 6)
        XCTAssertEqual(Set(m.spans(atSample: 249).map(\.flagID)), ["a", "b", "c"])
    }

    func testWallClockMarksStandOnRecordedMinutesAndSkipThePause() {
        let m = TimelineModel(snapshot: Self.session, windowSeconds: 1800)
        let marks = m.minuteMarks(stepMinutes: 1, timeZone: Self.utc)
        XCTAssertGreaterThan(marks.count, 20)
        let gap = try! XCTUnwrap(m.gaps.first)
        let before = m.samples[gap.sampleAfter - 1].date, after = m.samples[gap.sampleAfter].date
        for mark in marks {
            XCTAssertEqual(mark.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60), 0, accuracy: 1e-6)
            XCTAssertFalse(mark.date > before.addingTimeInterval(1.5) && mark.date < after.addingTimeInterval(-1.5), "a minute inside the pause has no place on the audio axis")
            // The mark's audio time lies in the second of the sample with that wall-clock date (a minute at the very start of a
            // second belongs to that second: the first one after the pause here).
            let i = try! XCTUnwrap(m.sampleIndex(atTime: mark.time + 1e-6))
            XCTAssertEqual(m.samples[i].date.timeIntervalSince(mark.date), 0, accuracy: 1.01)
        }
        XCTAssertEqual(marks.map(\.time), marks.map(\.time).sorted())
        // Three minutes of wall clock are missing between the two marks around the pause.
        let steps = zip(marks, marks.dropFirst()).map { $1.date.timeIntervalSince($0.date) }
        XCTAssertEqual(steps.filter { $0 > 61 }.count, 1)
        XCTAssertEqual(TimelineFormat.clock(Date(timeIntervalSince1970: 21 * 3600 + 42 * 60 + 7), seconds: false, timeZone: Self.utc), "21:42")
        XCTAssertEqual(TimelineFormat.clock(Date(timeIntervalSince1970: 21 * 3600 + 42 * 60 + 7), seconds: true, timeZone: Self.utc), "21:42:07")
        XCTAssertEqual(TimelineFormat.ago(192), "\u{2212}3:12"); XCTAssertEqual(TimelineFormat.ago(0.2), "now"); XCTAssertEqual(TimelineFormat.ago(42), "\u{2212}42 s")
    }

    // MARK: Picture

    func testRendersEverySizeAndFollowsTheRecord() throws {
        try RenderTestSupport.requireMetal()
        let frames = SyntheticFrames.sequence(count: 2)
        for size in TimelineReviewTests.sizes {
            let a = try RenderTestSupport.decode(png: OffscreenRenderer.png(panel: .timeline, frames: frames, size: size, settings: settings()))
            XCTAssertEqual(a.width, Int(size.width) * 2); XCTAssertEqual(a.height, Int(size.height) * 2)
            XCTAssertGreaterThan(a.distinctColors, 300, "\(size)")
            let again = try RenderTestSupport.decode(png: OffscreenRenderer.png(panel: .timeline, frames: frames, size: size, settings: settings()))
            XCTAssertEqual(a.data, again.data, "same record, same picture")
            let b = try RenderTestSupport.decode(png: OffscreenRenderer.png(panel: .timeline, frames: frames, size: size, settings: settings(window: 300)))
            var diff = 0
            for i in stride(from: 0, to: a.data.count, by: 4) where abs(Int(a.data[i + 2]) - Int(b.data[i + 2])) > 12 { diff += 1 }
            XCTAssertGreaterThan(diff, 1500, "\(size): the window changes the picture")
        }
    }

    func testLanesFollowTheDataAndTheHeight() throws {
        let plain = SyntheticFrames.demoSession(minutes: 25, includeLevelA: false)
        XCTAssertEqual(try renderer(settings()).1.lanesForTesting.map(\.kind), [.loudness, .peak, .ear])
        XCTAssertEqual(try renderer(settings(plain)).1.lanesForTesting.map(\.kind), [.loudness, .peak], "no level at the ear: no empty lane")
        XCTAssertEqual(try renderer(settings(), size: CGSize(width: 1200, height: 140)).1.lanesForTesting.map(\.kind), [.loudness, .peak], "the strip: loudness and peak only")
        XCTAssertEqual(try renderer(settings(), size: CGSize(width: 900, height: 120)).1.lanesForTesting.map(\.kind), [.loudness, .peak])
        XCTAssertEqual(try renderer(settings(), size: CGSize(width: 560, height: 360)).1.lanesForTesting.map(\.kind), [.loudness, .peak, .ear, .tone])
        var off = settings(); off.timelineShowBands = false
        XCTAssertEqual(try renderer(off, size: CGSize(width: 560, height: 360)).1.lanesForTesting.map(\.kind), [.loudness, .peak, .ear])
        for size in TimelineReviewTests.sizes {
            let r = try renderer(settings(), size: size).1
            for l in r.lanesForTesting {
                XCTAssertGreaterThanOrEqual(l.rect.height, 20, "\(size) \(l.kind)")
                XCTAssertLessThanOrEqual(l.rect.maxY, r.spansTopForTesting)
            }
            XCTAssertLessThan(r.spansTopForTesting, r.axisYForTesting)
        }
    }

    func testClipTicksAndTheOverAreRedOnThePeakLane() throws {
        let (s, r) = try renderer(settings(window: 1800))
        let px = try RenderTestSupport.decode(png: s.snapshotPNG())
        let peak = try XCTUnwrap(r.lanesForTesting.first { $0.kind == .peak })
        func red(atTime t: Double) -> Int {
            let cx = Int(r.x(forTime: t) * 2)
            var n = 0
            for y in Int(peak.rect.minY * 2 - 6)...Int(peak.rect.minY * 2 + 2) {
                for x in (cx - 4)...(cx + 4) { let c = px.rgb(x, y); if c.0 > 200, c.1 < 110, c.2 < 110 { n += 1 } }
            }
            return n
        }
        let clip = try XCTUnwrap(Self.session.events.first { $0.kind == .clip })
        let over = try XCTUnwrap(Self.session.events.first { $0.kind == .interSampleOver })
        XCTAssertGreaterThan(red(atTime: clip.time), 12)
        XCTAssertGreaterThan(red(atTime: over.time), 6)
        XCTAssertEqual(red(atTime: clip.time + 60), 0, "a clean minute has no red mark")
    }

    func testEmptyStateSaysSoAndKeepsTheAxes() throws {
        for size in TimelineReviewTests.sizes {
            let (s, r) = try renderer(settings(nil), size: size)
            _ = try s.snapshotPNG()
            let labels = r.textLayer.lastLabels.map(\.text)
            XCTAssertTrue(labels.contains("The timeline fills as you listen"), "\(size)")
            XCTAssertTrue(labels.contains("now")); XCTAssertTrue(labels.contains("LOUDNESS")); XCTAssertTrue(labels.contains("0"))
            XCTAssertEqual(r.accessibilityValueText, "last 15 minutes: nothing recorded yet")
        }
    }

    // MARK: Layout

    func testTimelineLabelsNeverIntersect() throws {
        try RenderTestSupport.requireMetal()
        var crowded = Self.session
        let last = crowded.samples[crowded.samples.count - 1]
        for (k, t) in [1000.0, 1010, 1020, 1030, 1040].enumerated() {
            crowded.events.append(SessionEvent(id: 900 + k, kind: .stressFlagRaised, time: t, date: last.date, label: "A flag with a long title number \(k)", detail: "x\(k)"))
        }
        crowded.events.sort { $0.time < $1.time }
        crowded.revision += 1
        let cursors: [PanelCursor?] = [nil, PanelCursor(frequencyHz: 392, secondsAgo: 166, source: .timeline, isPinned: true),
                                       PanelCursor(frequencyHz: 392, secondsAgo: 3.2, source: .spectrogram), PanelCursor(frequencyHz: 392, secondsAgo: 5_000, source: .spectrogram),
                                       PanelCursor(frequencyHz: 3_100, source: .spectrum)]
        let sessions: [(String, SessionSnapshot?)] = [("ear", Self.session), ("plain", SyntheticFrames.demoSession(minutes: 25, includeLevelA: false)),
                                                     ("crowded", crowded), ("short", SyntheticFrames.demoSession(minutes: 2)), ("empty", nil)]
        for size in TimelineReviewTests.sizes + [CGSize(width: 420, height: 300), CGSize(width: 760, height: 180)] {
            for window in [300, 900, 1800] {
                for (name, session) in sessions {
                    for (k, c) in cursors.enumerated() {
                        var st = settings(session, window: window)
                        st.cursor = c
                        // A pointer in a strip reads in the header row: part of the layout.
                        if k == 0, size.height < 180 { st.hover = CGPoint(x: size.width * 0.5, y: size.height * 0.5) }
                        let (s, r) = try renderer(st, size: size)
                        _ = try s.snapshotPNG()
                        let labels = r.textLayer.lastLabels
                        XCTAssertFalse(labels.isEmpty)
                        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
                        let tag = "\(Int(size.width))x\(Int(size.height)) \(window) s \(name) cursor \(k)"
                        for (i, a) in labels.enumerated() {
                            XCTAssertTrue(bounds.contains(a.rect), "\(tag): \"\(a.text)\" \(a.rect) leaves the panel")
                            for b in labels[(i + 1)...] where a.rect.intersects(b.rect) { XCTFail("\(tag): \"\(a.text)\" \(a.rect) on \"\(b.text)\" \(b.rect)") }
                        }
                    }
                }
            }
        }
    }

    // MARK: Cursor

    func testPointerMakesATimedCursorOnTheSecondUnderItAndKeepsTheFrequency() throws {
        let (_, r) = try renderer(settings())
        r.cursorLinked = true
        let lane = try XCTUnwrap(r.lanesForTesting.first)
        let sample = r.model.samples[r.model.samples.count - 1 - 166]
        let p = CGPoint(x: r.x(forTime: sample.time - 0.4), y: lane.rect.midY)
        let c = try XCTUnwrap(r.cursor(at: p))
        XCTAssertEqual(c.source, .timeline)
        XCTAssertEqual(try XCTUnwrap(c.secondsAgo), 166, accuracy: 1e-6)
        XCTAssertEqual(c.frequencyHz, 1000, "no frequency yet: the fallback")
        r.cursor = PanelCursor(frequencyHz: 392, source: .spectrum)
        XCTAssertEqual(r.cursor(at: p)?.frequencyHz, 392, "the timeline has no frequency axis: it keeps the link's frequency")
        XCTAssertNil(r.cursor(at: CGPoint(x: 5, y: lane.rect.midY)), "the gutter")
        XCTAssertNil(r.cursor(at: CGPoint(x: p.x, y: 4)), "the header row")
        // Left of the oldest sample (a record shorter than the window): nothing to point at.
        let (_, short) = try renderer(settings(SyntheticFrames.demoSession(minutes: 2)))
        XCTAssertNil(short.cursor(at: CGPoint(x: short.plotX.lowerBound + 20, y: lane.rect.midY)))
        XCTAssertNotNil(short.cursor(at: CGPoint(x: short.plotX.upperBound - 20, y: lane.rect.midY)))
    }

    func testFollowsTheSpectrogramsSecondsAgoAndReadsThatSecond() throws {
        var st = settings()
        st.cursor = PanelCursor(frequencyHz: 392, secondsAgo: 12.4, source: .spectrogram)
        let (s, r) = try renderer(st)
        let idx = try XCTUnwrap(r.focusIndex)
        let sample = r.model.samples[idx]
        XCTAssertEqual(r.model.newestTime - sample.time, 12, accuracy: 1e-6, "12.4 s ago lies in the second that ended 12 s ago")
        let items = r.cursorItems().map(\.text)
        XCTAssertEqual(items.first, TimelineFormat.clock(sample.date, seconds: true, timeZone: Self.utc))
        XCTAssertTrue(items.contains("S \(Fmt.db(sample.shortTermLUFS)) LUFS")); XCTAssertTrue(items.contains("TP \(Fmt.db(sample.truePeakDBTP, signed: true)) dBTP"))
        XCTAssertTrue(r.showsHeaderReadout)
        // The hairline stands at the cursor's time on the audio axis.
        let bare = try RenderTestSupport.decode(png: renderer(settings()).0.snapshotPNG())
        let with = try RenderTestSupport.decode(png: s.snapshotPNG())
        let lane = try XCTUnwrap(r.lanesForTesting.first)
        let y = Int(lane.rect.minY * 2) + 6
        var changed: [Int] = []
        for x in Int(r.plotX.lowerBound * 2)..<Int(r.plotX.upperBound * 2) where bare.rgb(x, y) != with.rgb(x, y) { changed.append(x) }
        let mid = try XCTUnwrap(changed.isEmpty ? nil : Double(changed.reduce(0, +)) / Double(changed.count))
        XCTAssertEqual(mid / 2, Double(r.x(forSecondsAgo: 12.4)), accuracy: 1.5)
        // A cursor without a time, and one outside the window, draw no hairline.
        r.cursor = PanelCursor(frequencyHz: 392, source: .spectrum)
        XCTAssertNil(r.focusIndex); XCTAssertTrue(r.cursorItems().isEmpty)
        r.cursor = PanelCursor(frequencyHz: 392, secondsAgo: 5_000, source: .spectrogram)
        XCTAssertNil(r.focusIndex)
        XCTAssertEqual(r.cursorItems().map(\.text), ["\u{2212}83:20", "outside the record"])
    }

    func testReadoutNamesTheEventsOfTheSecond() throws {
        let (_, r) = try renderer(settings(window: 1800))
        func index(_ kind: SessionEvent.Kind) throws -> Int {
            let e = try XCTUnwrap(Self.session.events.first { $0.kind == kind })
            return try XCTUnwrap(r.model.sampleIndex(atTime: e.time))
        }
        let clip = try index(.clip)
        XCTAssertTrue(r.readoutLines(clip).contains("clipped \u{00D7}3"))
        XCTAssertEqual(r.readoutLines(clip).count, 5)
        XCTAssertTrue(r.readoutLines(try index(.interSampleOver)).contains("true peak over +0.4 dBTP"))
        XCTAssertTrue(r.readoutLines(try index(.stressFlagRaised)).contains("flag raised: Strong sub-bass in the signal"))
        XCTAssertTrue(r.readoutLines(try index(.stressFlagRaised) + 30).contains("flag up: Strong sub-bass in the signal"))
        XCTAssertEqual(r.readoutLines(try index(.silenceStart) + 5)[1], "digital silence")
        let gap = try XCTUnwrap(r.model.gaps.first)
        XCTAssertTrue(r.readoutLines(gap.sampleAfter).contains("after a pause of 3:10 min"))
        XCTAssertTrue(r.readoutLines(gap.sampleAfter).contains("track start"))
        let s = r.model.samples[clip]
        XCTAssertEqual(r.readoutLines(clip)[1], "S \(Fmt.db(s.shortTermLUFS))   M max \(Fmt.db(s.momentaryMaxLUFS)) LUFS")
    }

    // MARK: The view: pulls, keys, clicks, accessibility

    private final class Source {
        var snapshot = TimelineTests.session
        var pulls = 0
        func provider() -> SessionProvider { { [unowned self] in self.pulls += 1; return self.snapshot } }
    }

    private func view(_ source: Source, link: PanelCursorLink?) throws -> (TimelineView, TimelineRenderer) {
        try RenderTestSupport.requireMetal()
        let frame = SyntheticFrames.sequence(count: 1)[0]
        let v = TimelineView(frameProvider: { frame }, sessionProvider: source.provider())
        v.frame = CGRect(x: 0, y: 0, width: 1200, height: 140)
        v.layout()
        v.cursorLink = link
        return (v, try XCTUnwrap(v.renderer as? TimelineRenderer))
    }

    func testPullsOncePerSecondAndSkipsAnUnchangedRevision() throws {
        let source = Source()
        let (v, r) = try view(source, link: nil)
        let now = Self.session.samples.last!.date
        v.syncSession(now: 100, date: now)
        XCTAssertEqual(source.pulls, 1); XCTAssertEqual(r.rebuildCount, 1); XCTAssertTrue(r.isLive)
        XCTAssertTrue(r.refreshText(now: 100)); r.needsDisplay = false
        // 60 ticks inside the second: no pull, nothing dirty, no text work.
        for k in 1..<60 { v.syncSession(now: 100 + Double(k) / 60, date: now) }
        XCTAssertEqual(source.pulls, 1)
        XCTAssertFalse(r.needsDisplay); XCTAssertFalse(r.refreshText(now: 100.9))
        // The next second: a pull, but the same revision changes nothing.
        v.syncSession(now: 101.01, date: now)
        XCTAssertEqual(source.pulls, 2); XCTAssertEqual(r.rebuildCount, 1)
        XCTAssertFalse(r.needsDisplay); XCTAssertFalse(r.refreshText(now: 101.2))
        // A new revision redraws.
        source.snapshot = SyntheticFrames.demoSession(minutes: 24)
        v.syncSession(now: 102.02, date: now)
        XCTAssertEqual(r.rebuildCount, 2); XCTAssertTrue(r.needsDisplay); XCTAssertTrue(r.refreshText(now: 102.2))
        // The audio clock stood still for a while: the axis no longer says "now".
        r.needsDisplay = false
        v.syncSession(now: 103.03, date: now.addingTimeInterval(400))
        XCTAssertFalse(r.isLive); XCTAssertTrue(r.needsDisplay)
        // The options of the view reach the renderer.
        v.windowSeconds = 300; v.targetLUFS = -16; v.showBands = false
        v.syncSession(now: 103.1, date: now)
        XCTAssertEqual(r.windowSeconds, 300); XCTAssertEqual(r.targetLUFS, -16); XCTAssertFalse(r.showBands); XCTAssertEqual(r.model.samples.count, 300)
        XCTAssertFalse(r.usesAnalysisFrames, "display ticks do not pull or ingest analysis frames")
    }

    func testOnlyATimeOrPinChangeOfTheCursorRedraws() throws {
        let source = Source(), link = PanelCursorLink()
        let (v, r) = try view(source, link: link)
        v.syncSession(now: 10)
        r.refreshText(now: 10); r.needsDisplay = false
        // The pointer runs along the spectrum: a frequency cursor without a time. Nothing here shows it.
        for k in 0..<40 { link.set(PanelCursor(frequencyHz: 400 + Float(k), source: .spectrum)) }
        XCTAssertFalse(r.needsDisplay); XCTAssertFalse(r.refreshText(now: 10.5))
        v.syncSession(now: 10.6)
        XCTAssertEqual(source.pulls, 1, "no time, no pull")
        // The spectrogram gives it a time: hairline and header readout.
        link.set(PanelCursor(frequencyHz: 440, secondsAgo: 3.2, source: .spectrogram))
        XCTAssertTrue(r.needsDisplay); XCTAssertTrue(r.refreshText(now: 11))
        v.syncSession(now: 11.01)
        XCTAssertEqual(source.pulls, 2, "a moved timed cursor pulls the record")
        r.needsDisplay = false
        link.set(PanelCursor(frequencyHz: 880, secondsAgo: 3.2, source: .spectrogram))
        XCTAssertFalse(r.needsDisplay, "the same time at another frequency")
        link.set(PanelCursor(frequencyHz: 880, secondsAgo: 3.2, source: .spectrogram, isPinned: true))
        XCTAssertTrue(r.needsDisplay)
    }

    func testClickPinsKeysStepSecondsAndEscClears() throws {
        let source = Source(), link = PanelCursorLink()
        let (v, r) = try view(source, link: link)
        v.syncSession(now: 1)
        XCTAssertTrue(v.acceptsFirstResponder)
        XCTAssertFalse(v.handleCursorKey(.escape, shift: false)); XCTAssertFalse(v.handleCursorKey(.up, shift: false))
        // The first arrow key starts at the newest second, with the frame's peak as the frequency.
        XCTAssertTrue(v.handleCursorKey(.left, shift: false))
        XCTAssertEqual(link.cursor?.secondsAgo, 0); XCTAssertEqual(link.cursor?.source, .timeline)
        XCTAssertGreaterThan(link.cursor?.frequencyHz ?? 0, 19)
        XCTAssertTrue(v.handleCursorKey(.left, shift: false)); XCTAssertEqual(link.cursor?.secondsAgo, 1)
        XCTAssertTrue(v.handleCursorKey(.left, shift: true)); XCTAssertEqual(link.cursor?.secondsAgo, 11)
        XCTAssertTrue(v.handleCursorKey(.right, shift: false)); XCTAssertEqual(link.cursor?.secondsAgo, 10)
        XCTAssertTrue(v.handleCursorKey(.right, shift: true)); XCTAssertEqual(link.cursor?.secondsAgo, 0)
        XCTAssertTrue(v.handleCursorKey(.right, shift: true)); XCTAssertEqual(link.cursor?.secondsAgo, 0, "not past now")
        for _ in 0..<200 { v.handleCursorKey(.left, shift: true) }
        XCTAssertEqual(link.cursor?.secondsAgo, 899, "not past the oldest second of the window")
        XCTAssertFalse(v.handleCursorKey(.down, shift: false), "up and down belong to the spectrogram")
        // Return pins, Return again unpins, Esc clears.
        XCTAssertTrue(v.handleCursorKey(.pin, shift: false)); XCTAssertEqual(link.cursor?.isPinned, true)
        XCTAssertTrue(v.handleCursorKey(.pin, shift: false)); XCTAssertEqual(link.cursor?.isPinned, false)
        XCTAssertTrue(v.handleCursorKey(.escape, shift: false)); XCTAssertNil(link.cursor)
        // A cursor from the spectrum gets a time here and keeps its frequency.
        link.set(PanelCursor(frequencyHz: 3_100, source: .spectrum))
        XCTAssertTrue(v.handleCursorKey(.left, shift: false))
        XCTAssertEqual(link.cursor?.frequencyHz, 3_100); XCTAssertEqual(link.cursor?.secondsAgo, 0)
        link.clear()

        // Click: pin at the second under the pointer; a click on the pinned hairline clears the pin.
        let lane = try XCTUnwrap(r.lanesForTesting.first)
        let p = CGPoint(x: r.x(forSecondsAgo: 165.5), y: lane.rect.midY)
        XCTAssertTrue(v.handleCursorClick(at: p))
        XCTAssertEqual(link.cursor?.isPinned, true); XCTAssertEqual(try XCTUnwrap(link.cursor?.secondsAgo), 165, accuracy: 1e-6)
        link.set(PanelCursor(frequencyHz: 100, secondsAgo: 2, source: .spectrogram))
        XCTAssertEqual(try XCTUnwrap(link.cursor?.secondsAgo), 165, accuracy: 1e-6, "hover moves do not replace a pin")
        XCTAssertTrue(v.handleCursorClick(at: CGPoint(x: p.x + 2, y: lane.rect.midY)))
        XCTAssertEqual(link.cursor?.isPinned, false)
        XCTAssertFalse(v.handleCursorClick(at: CGPoint(x: 4, y: 4)))
    }

    func testAccessibilityValueCarriesTheWindowAndTheCursor() throws {
        let source = Source(), link = PanelCursorLink()
        let (v, _) = try view(source, link: link)
        XCTAssertEqual(v.accessibilityRoleDescription(), "session timeline")
        XCTAssertEqual(v.accessibilityLabel(), "Session timeline")
        XCTAssertTrue(v.accessibilitySummary.hasPrefix("last 15 minutes: short-term mostly \u{2212}20 to \u{2212}10 LUFS"), v.accessibilitySummary)
        XCTAssertTrue(v.accessibilitySummary.contains("3 seconds with clipped samples")); XCTAssertTrue(v.accessibilitySummary.contains("3 stress flags"))
        var said: [String] = []
        v.announcementSink = { said.append($0) }
        XCTAssertTrue(v.handleCursorKey(.left, shift: false))
        XCTAssertTrue(v.accessibilitySummary.contains(". Cursor: "), v.accessibilitySummary)
        XCTAssertEqual(said.count, 1)
        XCTAssertTrue(said[0].contains("LUFS"), said[0])
    }

    /// A real window for a moment (JOSEON_LIVE_VIEW_TEST=1): analysis frames change 60 times per second, the record does not,
    /// so the display link ticks and the panel draws once; a new revision draws once more.
    func testLiveViewDrawsOnlyWhenTheRecordChanges() throws {
        guard ProcessInfo.processInfo.environment["JOSEON_LIVE_VIEW_TEST"] == "1" else { throw XCTSkip("Set JOSEON_LIVE_VIEW_TEST=1") }
        try RenderTestSupport.requireMetal()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        PanelView.ignoresOcclusionForTesting = true
        defer { PanelView.ignoresOcclusionForTesting = false }
        let generator = SyntheticFrames()
        var latest = generator.next()
        let source = Source()
        let v = TimelineView(frameProvider: { latest }, sessionProvider: source.provider())
        v.cursorLink = PanelCursorLink()
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1200, height: 140), styleMask: [.titled], backing: .buffered, defer: false)
        v.frame = CGRect(x: 0, y: 0, width: 1200, height: 140)
        window.contentView = v
        window.orderFrontRegardless()
        func run(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { latest = generator.next(); RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.0 / 60.0)) }
        }
        run(2.6)
        print("TIMELINELIVE", v.debugRunState, "pulls:", source.pulls)
        if v.tickCount == 0 { window.close(); throw XCTSkip("No display link callbacks (no screen?)") }
        XCTAssertGreaterThanOrEqual(v.drawnFrameCount, 1)
        XCTAssertLessThanOrEqual(v.drawnFrameCount, 3, "one record, one picture (plus the layout passes of a new window)")
        XCTAssertLessThanOrEqual(source.pulls, 4); XCTAssertGreaterThanOrEqual(source.pulls, 2)
        let drawn = v.drawnFrameCount
        source.snapshot = SyntheticFrames.demoSession(minutes: 24)
        run(1.3)
        XCTAssertEqual(v.drawnFrameCount, drawn + 1, "a new revision: one redraw")
        v.cursorLink?.set(PanelCursor(frequencyHz: 440, secondsAgo: 3, source: .spectrogram))
        run(0.3)
        XCTAssertEqual(v.drawnFrameCount, drawn + 2, "a cursor move: one redraw")
        print("TIMELINELIVE", v.debugRunState, "pulls:", source.pulls)
        window.close()
    }

    // MARK: Cost

    func testFrameCost() throws {
        try RenderTestSupport.requireMetal()
        let frames = SyntheticFrames.sequence(count: 4)
        for (size, window) in [(CGSize(width: 1200, height: 140), 900), (CGSize(width: 1200, height: 220), 1800), (CGSize(width: 560, height: 360), 1800)] {
            var st = settings(SyntheticFrames.demoSession(minutes: 30), window: window)
            st.cursor = PanelCursor(frequencyHz: 392, secondsAgo: 166, source: .timeline, isPinned: true)
            let cost = try OffscreenRenderer.measure(panel: .timeline, frames: frames, size: size, scale: 2, iterations: 60, settings: st)
            print(String(format: "TIMELINECOST %dx%d %d s: one redraw = gpu %.3f ms, cpu-encode %.3f ms, text %.3f ms", Int(size.width), Int(size.height), window, cost.gpuMS, cost.cpuEncodeMS, cost.textMS))
            XCTAssertLessThan(cost.gpuMS, 2.0)
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 { _ = TimelineModel(snapshot: SyntheticFrames.demoSession(minutes: 1), windowSeconds: 1800) }
        let session = SyntheticFrames.demoSession(minutes: 30)
        let t1 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 { _ = TimelineModel(snapshot: session, windowSeconds: 1800) }
        print(String(format: "TIMELINECOST model of 1800 samples: %.3f ms (once per second)", (CFAbsoluteTimeGetCurrent() - t1) / 20 * 1000))
        _ = t0
    }
}
