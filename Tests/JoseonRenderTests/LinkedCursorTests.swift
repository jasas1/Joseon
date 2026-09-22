import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// The linked cursor: one frequency, the same place on every panel's own axis; honest
/// numbers; pointer, click and keyboard handling through the entry points the events call; coalesced redraws.
final class LinkedCursorTests: XCTestCase {
    private static let frames = Array(RealFrames.demo(seconds: 6).suffix(240))
    private static let session = SyntheticFrames.demoSession(minutes: 5)

    private func session(_ kind: PanelKind, size: CGSize = CGSize(width: 560, height: 360), cursor: PanelCursor?, slice: CursorHistorySlice? = nil,
                         mode: VectorscopeMode = .lissajous, configure: (inout OffscreenRenderer.Settings) -> Void = { _ in }) throws -> OffscreenRenderer.Session {
        var settings = OffscreenRenderer.Settings()
        settings.vectorscopeMode = mode
        settings.cursor = cursor
        settings.cursorHistorySlice = slice
        configure(&settings)
        let s = try OffscreenRenderer.Session(panel: kind, size: size, scale: 2, theme: Theme(), settings: settings)
        // A linked panel without a cursor has the linked layout: the reference picture of the pixel tests.
        s.renderer.cursorLinked = true
        try s.feed(Self.frames)
        return s
    }

    // MARK: Formatting

    func testFrequencyNoteAndBandFormats() {
        XCTAssertEqual(CursorMath.hz(392), "392.0 Hz")
        XCTAssertEqual(CursorMath.hz(999.94), "999.9 Hz")
        XCTAssertEqual(CursorMath.hz(999.96), "1.00 kHz")
        XCTAssertEqual(CursorMath.hz(3_100), "3.10 kHz")
        XCTAssertEqual(CursorMath.hz(12_340), "12.3 kHz")
        XCTAssertEqual(CursorMath.note(440), "A4 \u{00B1}0 \u{00A2}")
        // 3 cents over A4, equal temperament, A4 = 440 Hz.
        XCTAssertEqual(CursorMath.note(440 * pow(2, 3.0 / 1200)), "A4 +3 \u{00A2}")
        XCTAssertEqual(CursorMath.note(440 * pow(2, -20.0 / 1200)), "A4 \u{2212}20 \u{00A2}")
        XCTAssertEqual(CursorMath.ago(3.2), "\u{2212}3.2 s")
        XCTAssertEqual(CursorMath.band(containing: 5_000), 5)
        XCTAssertEqual(CursorMath.bandRange(5), "4\u{2013}6 kHz")
        XCTAssertEqual(CursorMath.bandRange(1), "60\u{2013}250 Hz")
        XCTAssertEqual(CursorMath.bandRange(3), "500 Hz\u{2013}2 kHz")
        XCTAssertNil(CursorMath.band(containing: 10))
        XCTAssertEqual(CursorMath.step(440, semitones: 12, in: 20...20_000), 880, accuracy: 0.01)
        XCTAssertEqual(CursorMath.step(19_000, semitones: 12, in: 20...20_000), 20_000)
    }

    func testReadoutNumbersAreTheFrameAtTheCursor() throws {
        try RenderTestSupport.requireMetal()
        let c = PanelCursor(frequencyHz: 392, source: .meters, isPinned: true)
        let s = try session(.spectrum, cursor: c)
        let f = Self.frames.last!
        let items = s.renderer.cursorItems().map(\.text)
        let mid = try XCTUnwrap(CursorMath.level(of: f.spectrum.mid, frequencies: f.spectrum.frequencies, atHz: 392))
        let l = try XCTUnwrap(CursorMath.level(of: f.spectrum.left, frequencies: f.spectrum.frequencies, atHz: 392))
        let r = try XCTUnwrap(CursorMath.level(of: f.spectrum.right, frequencies: f.spectrum.frequencies, atHz: 392))
        XCTAssertEqual(items, ["392.0 Hz", "G4 \u{00B1}0 \u{00A2}", "Mid \(Fmt.db(mid)) dB", "L \(Fmt.db(l))  R \(Fmt.db(r))"])
        XCTAssertTrue(items[2].contains("\u{2212}"), "a real minus sign")
        // Interpolation in dB between the two bins around the frequency.
        let freqs = f.spectrum.frequencies
        let i = try XCTUnwrap(freqs.firstIndex { $0 > 392 }) - 1
        XCTAssertTrue(mid >= min(f.spectrum.mid[i], f.spectrum.mid[i + 1]) - 0.001 && mid <= max(f.spectrum.mid[i], f.spectrum.mid[i + 1]) + 0.001)
        // The spectrogram and the placement field show the same Mid number for the same cursor.
        XCTAssertTrue(try session(.spectrogram, cursor: c).renderer.cursorItems().map(\.text).contains("Mid \(Fmt.db(mid)) dB"))
        let placement = try session(.vectorscope, cursor: c, mode: .panSpectrum).renderer.cursorItems().map(\.text)
        XCTAssertTrue(placement.contains("Mid \(Fmt.db(mid)) dB"))
        XCTAssertTrue(placement.contains { $0.hasPrefix("pan ") })
    }

    func testAtEarAndSPLAndSideItems() throws {
        try RenderTestSupport.requireMetal()
        var o = SyntheticFrames.Options(); o.includeHeadphone = true; o.includeSPL = true
        let frames = SyntheticFrames.sequence(count: 120, options: o)
        var settings = OffscreenRenderer.Settings()
        settings.cursor = PanelCursor(frequencyHz: 3_100, source: .spectrogram, isPinned: true)
        settings.levelAxis = .dBSPL; settings.spectrum.showSide = true
        let s = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: settings)
        try s.feed(frames)
        let f = frames.last!, hp = try XCTUnwrap(f.headphone)
        let v = try XCTUnwrap((s.renderer as? SpectrumRenderer)?.cursorValues())
        let mid = try XCTUnwrap(CursorMath.level(of: f.spectrum.mid, frequencies: f.spectrum.frequencies, atHz: 3_100))
        let resp = try XCTUnwrap(CursorMath.level(of: hp.responseDB, frequencies: f.spectrum.frequencies, atHz: 3_100))
        let target = try XCTUnwrap(CursorMath.level(of: hp.targetDB, frequencies: f.spectrum.frequencies, atHz: 3_100))
        XCTAssertEqual(try XCTUnwrap(v.atEar), mid + resp - target, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(v.atEarDelta), resp - target, accuracy: 0.001)
        XCTAssertNotNil(v.side)
        let spl = try XCTUnwrap(v.spl)
        XCTAssertEqual(spl.center, 3_150, accuracy: 1, "3.1 kHz lies in the 3.15 kHz third-octave band")
        let texts = s.renderer.cursorItems().map(\.text)
        XCTAssertTrue(texts.contains { $0.hasPrefix("at ear vs target ") && $0.hasSuffix(" dB") })
        XCTAssertTrue(texts.contains { $0.hasPrefix("Side ") })
        XCTAssertTrue(texts.contains { $0.contains("dB SPL") })
    }

    // MARK: The same frequency at the same place in every panel

    /// Pixels that differ between two renders, counted per column and per row inside `rect` (points).
    private func difference(_ a: Data, _ b: Data, in rect: CGRect, scale: CGFloat = 2) throws -> (columns: [Int: Int], rows: [Int: Int]) {
        let pa = try RenderTestSupport.decode(png: a), pb = try RenderTestSupport.decode(png: b)
        var columns: [Int: Int] = [:], rows: [Int: Int] = [:]
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                let p = pa.rgb(x, y), q = pb.rgb(x, y)
                if abs(p.0 - q.0) + abs(p.1 - q.1) + abs(p.2 - q.2) > 12 { columns[x, default: 0] += 1; rows[y, default: 0] += 1 }
            }
        }
        return (columns, rows)
    }

    func testHairlineStandsOnEachPanelsOwnAxisAt1kHz() throws {
        try RenderTestSupport.requireMetal()
        // From another panel (the meters cannot make pointer cursors): no pointer crosshair, no label box, only the hairline.
        let c = PanelCursor(frequencyHz: 1_000, source: .meters)
        for size in [CGSize(width: 1200, height: 600), CGSize(width: 560, height: 360), CGSize(width: 460, height: 330)] {
            // Spectrum: a vertical hairline at the x of 1 kHz.
            do {
                let with = try session(.spectrum, size: size, cursor: c), without = try session(.spectrum, size: size, cursor: nil)
                let r = try XCTUnwrap(with.renderer as? SpectrumRenderer)
                let plot = r.plotRectForTesting
                let d = try difference(with.snapshotPNG(), without.snapshotPNG(), in: plot.insetBy(dx: 1, dy: 1))
                let column = try XCTUnwrap(d.columns.max { $0.value < $1.value })
                XCTAssertGreaterThan(CGFloat(column.value), plot.height * 2 * 0.6, "a line over the plot height")
                XCTAssertEqual(CGFloat(column.key), r.xForTesting(hz: 1_000) * 2, accuracy: 1, "spectrum \(size)")
                XCTAssertEqual(r.cursorXForTesting, r.xForTesting(hz: 1_000))
            }
            // Spectrogram: a horizontal hairline at the y of 1 kHz.
            do {
                let with = try session(.spectrogram, size: size, cursor: c), without = try session(.spectrogram, size: size, cursor: nil)
                let r = try XCTUnwrap(with.renderer as? SpectrogramRenderer)
                let plot = r.plotRectForTesting
                let d = try difference(with.snapshotPNG(), without.snapshotPNG(), in: plot.insetBy(dx: 1, dy: 1))
                // The bed is 3 px: the rows that differ most are the hairline and its two neighbours; their middle is the line.
                let top = d.rows.sorted { $0.value > $1.value }.prefix(3).map(\.key)
                XCTAssertFalse(top.isEmpty)
                let middle = CGFloat(top.reduce(0, +)) / CGFloat(top.count)
                XCTAssertEqual(middle, r.yForTesting(hz: 1_000) * 2, accuracy: 1.5, "spectrogram \(size)")
            }
            // Stereo placement: a horizontal hairline at the y of 1 kHz on the placement axis.
            do {
                let with = try session(.vectorscope, size: size, cursor: c, mode: .panSpectrum)
                let without = try session(.vectorscope, size: size, cursor: nil, mode: .panSpectrum)
                let r = try XCTUnwrap(with.renderer as? VectorscopeRenderer)
                let field = r.fieldForTesting
                let d = try difference(with.snapshotPNG(), without.snapshotPNG(), in: field.insetBy(dx: 2, dy: 2))
                let row = try XCTUnwrap(d.rows.max { $0.value < $1.value })
                XCTAssertGreaterThan(CGFloat(row.value), field.width * 2 * 0.5)
                XCTAssertEqual(CGFloat(row.key), r.panYForTesting(hz: 1_000) * 2, accuracy: 1, "placement \(size)")
            }
        }
    }

    func testPointerMakesTheCursorFromThePanelsAxisAndBack() throws {
        try RenderTestSupport.requireMetal()
        let s = try session(.spectrum, cursor: nil)
        let r = try XCTUnwrap(s.renderer as? SpectrumRenderer)
        let x = r.xForTesting(hz: 1_000)
        let c = try XCTUnwrap(r.cursor(at: CGPoint(x: x, y: r.plotRectForTesting.midY)))
        XCTAssertEqual(c.frequencyHz, 1_000, accuracy: 0.5)
        XCTAssertEqual(c.source, .spectrum); XCTAssertNil(c.secondsAgo); XCTAssertFalse(c.isPinned)
        XCTAssertNil(r.cursor(at: CGPoint(x: 2, y: 2)), "outside the plot")

        let g = try XCTUnwrap(try session(.spectrogram, cursor: nil).renderer as? SpectrogramRenderer)
        let point = CGPoint(x: g.xForTesting(secondsAgo: 3.2), y: g.yForTesting(hz: 392))
        let t = try XCTUnwrap(g.cursor(at: point))
        XCTAssertEqual(t.frequencyHz, 392, accuracy: 1.5)
        XCTAssertEqual(try XCTUnwrap(t.secondsAgo), 3.2, accuracy: 0.02)

        XCTAssertNil(try session(.meters, cursor: nil).renderer.cursor(at: CGPoint(x: 100, y: 100)))
        XCTAssertNil(try session(.vectorscope, cursor: nil).renderer.cursor(at: CGPoint(x: 100, y: 100)), "the goniometer has no frequency axis")
        let p = try XCTUnwrap(try session(.vectorscope, cursor: nil, mode: .panSpectrum).renderer as? VectorscopeRenderer)
        let pc = try XCTUnwrap(p.cursor(at: CGPoint(x: p.fieldForTesting.midX, y: p.panYForTesting(hz: 250))))
        XCTAssertEqual(pc.frequencyHz, 250, accuracy: 1)
        XCTAssertEqual(pc.source, .vectorscope)
    }

    // MARK: History slice and the ghost trace

    func testSpectrogramPublishesTheColumnAndTheThenNumberMatches() throws {
        try RenderTestSupport.requireMetal()
        let link = PanelCursorLink()
        let view = SpectrogramView(frameProvider: { Self.frames.last! })
        view.frame = CGRect(x: 0, y: 0, width: 560, height: 360)
        view.layout()
        view.cursorLink = link
        let r = try XCTUnwrap(view.renderer as? SpectrogramRenderer)
        for f in Self.frames { r.ingest(f) }
        var changes = 0
        link.addObserver { changes += 1 }

        link.set(PanelCursor(frequencyHz: 392, secondsAgo: 2.0, source: .spectrogram))
        XCTAssertNil(link.historySlice)
        view.publishHistorySliceIfNeeded(now: 100)
        let slice = try XCTUnwrap(link.historySlice)
        XCTAssertEqual(slice.secondsAgo, 2.0)
        // The CPU copy of the history holds rows, not the frames' bins: 1024 rows, uniform on the log axis, 20 Hz ... 20 kHz.
        XCTAssertEqual(slice.frequencies.count, SpectrogramRenderer.rows)
        XCTAssertEqual(slice.midDB.count, SpectrogramRenderer.rows)
        XCTAssertEqual(slice.frequencies.first!, 20, accuracy: 0.01); XCTAssertEqual(slice.frequencies.last!, 20_000, accuracy: 1)
        XCTAssertTrue(slice.midDB.contains { $0 > -60 }, "the column holds the music")

        // Nothing new: no publish, however often the tick asks.
        let before = changes
        for k in 1...5 { view.publishHistorySliceIfNeeded(now: 100 + Double(k) * 0.001) }
        XCTAssertEqual(changes, before)

        // The history scrolls under the cursor: a new column, but not more often than 30 times per second.
        var f = Self.frames.last!
        for k in 1...6 { f.hostTime += 1.0 / 60; f.spectrum.mid[300] += Float(k); r.ingest(f) }
        view.publishHistorySliceIfNeeded(now: 100.01)
        XCTAssertEqual(changes, before, "10 ms after the last publish")
        view.publishHistorySliceIfNeeded(now: 100.05)
        XCTAssertEqual(changes, before + 1)

        // The spectrum's "then" number and the spectrogram's level at (f, t) are one number.
        let published = try XCTUnwrap(link.historySlice)
        let then = try XCTUnwrap(CursorMath.level(of: published.midDB, frequencies: published.frequencies, atHz: 392))
        XCTAssertTrue(r.cursorItems().map(\.text).contains(then <= r.floorDB ? "Mid under \(Fmt.number(r.floorDB, digits: 0)) dB" : "Mid \(Fmt.db(then)) dB"))

        // Outside the history: nil, once.
        link.set(PanelCursor(frequencyHz: 392, secondsAgo: 19.5, source: .spectrogram))
        view.publishHistorySliceIfNeeded(now: 107)
        XCTAssertNil(link.historySlice)
        // A cursor without a time: the link drops the slice itself, the view publishes nothing.
        link.set(PanelCursor(frequencyHz: 392, source: .spectrum))
        let quiet = changes
        view.publishHistorySliceIfNeeded(now: 108)
        XCTAssertEqual(changes, quiet)
    }

    func testGhostTraceDrawsOnlyWithATimedCursorAndASlice() throws {
        try RenderTestSupport.requireMetal()
        let slice = try XCTUnwrap(try OffscreenRenderer.historySlice(frames: Self.frames, secondsAgo: 2.0))
        let timed = PanelCursor(frequencyHz: 392, secondsAgo: 2.0, source: .spectrogram)
        let with = try session(.spectrum, size: CGSize(width: 1200, height: 600), cursor: timed, slice: slice)
        let r = try XCTUnwrap(with.renderer as? SpectrumRenderer)
        _ = try with.snapshotPNG()
        let ghost = try XCTUnwrap(r.curveForTesting("ghost"))
        // The ghost is the published column on this panel's axis.
        let i = ghost.count / 2
        let expected = try XCTUnwrap(CursorMath.level(of: slice.midDB, frequencies: slice.frequencies, atHz: r.frequencyForTesting(point: i)))
        XCTAssertEqual(ghost[i], max(expected, r.shownRange.min), accuracy: 1.0)
        let labels = with.renderer.textLayer.lastLabels.map(\.text)
        XCTAssertTrue(labels.contains("then (\u{2212}2.0 s)"), "legend entry while the ghost shows")
        XCTAssertTrue(labels.contains { $0.hasPrefix("then ") && $0.hasSuffix("dB (\u{2212}2.0 s)") }, "\(labels)")

        // No slice, or no time: no ghost, no legend entry.
        for (c, s) in [(timed, nil), (PanelCursor(frequencyHz: 392, source: .spectrum, isPinned: true), slice)] as [(PanelCursor, CursorHistorySlice?)] {
            let plain = try session(.spectrum, size: CGSize(width: 1200, height: 600), cursor: c, slice: s)
            _ = try plain.snapshotPNG()
            XCTAssertNil((plain.renderer as? SpectrumRenderer)?.curveForTesting("ghost"))
            XCTAssertFalse(plain.renderer.textLayer.lastLabels.contains { $0.text.hasPrefix("then") })
        }
    }

    // MARK: Views: link, click, keyboard, accessibility

    private func view(_ kind: PanelKind, link: PanelCursorLink?) throws -> PanelView {
        try RenderTestSupport.requireMetal()
        let provider: FrameProvider = { Self.frames.last! }
        let v: PanelView
        switch kind {
        case .spectrum: v = SpectrumView(frameProvider: provider)
        case .spectrogram: v = SpectrogramView(frameProvider: provider)
        case .vectorscope: v = VectorscopeView(frameProvider: provider)
        case .meters: v = MetersView(frameProvider: provider)
        case .timeline: v = TimelineView(frameProvider: provider, sessionProvider: { Self.session })
        }
        v.frame = CGRect(x: 0, y: 0, width: 560, height: 360)
        v.layout()
        v.cursorLink = link
        for f in Self.frames.suffix(30) { v.renderer?.ingest(f) }
        return v
    }

    func testPanelWithoutALinkIsUnchanged() throws {
        let v = try view(.spectrogram, link: nil)
        XCTAssertFalse(v.acceptsFirstResponder)
        XCTAssertFalse(v.handleCursorKey(.right, shift: false))
        XCTAssertFalse(v.handleCursorClick(at: CGPoint(x: 200, y: 200)))
        let r = try XCTUnwrap(v.renderer as? SpectrogramRenderer)
        XCTAssertFalse(r.cursorLinked)
        XCTAssertEqual(r.plotRectForTesting.minY, 12, "the unlinked layout has no header row")
        XCTAssertEqual(r.cursorAccessibilityText, "")
        r.hover = CGPoint(x: 200, y: 200)
        XCTAssertEqual(r.hoverLabel()?.lines.first?.hasPrefix("cursor  "), true, "the hover label of before")
        // The same picture as a panel that never heard of cursors: the settings' default.
        let a = try OffscreenRenderer.png(panel: .spectrum, frames: Self.frames, size: CGSize(width: 560, height: 360))
        let b = try OffscreenRenderer.png(panel: .spectrum, frames: Self.frames, size: CGSize(width: 560, height: 360), settings: .init())
        XCTAssertEqual(a, b)
    }

    func testEveryPanelOfAWindowFollowsOneLink() throws {
        let link = PanelCursorLink()
        let views = try PanelKind.allCases.map { try view($0, link: link) }
        for v in views { XCTAssertTrue(v.acceptsFirstResponder); XCTAssertEqual(v.renderer?.cursorLinked, true) }
        link.set(PanelCursor(frequencyHz: 5_000, source: .spectrum))
        for v in views { XCTAssertEqual(v.renderer?.cursor?.frequencyHz, 5_000) }
        link.clear()
        for v in views { XCTAssertNil(v.renderer?.cursor) }
        // Unlinking stops the updates and restores the old layout.
        views[1].cursorLink = nil
        link.set(PanelCursor(frequencyHz: 100, source: .spectrum))
        XCTAssertNil(views[1].renderer?.cursor)
        XCTAssertEqual(views[1].renderer?.cursorLinked, false)
    }

    func testCursorMovesCoalesceIntoOneRedrawAndUnchangedPanelsStayClean() throws {
        let link = PanelCursorLink()
        let spectrum = try view(.spectrum, link: link), meters = try view(.meters, link: link)
        let rs = try XCTUnwrap(spectrum.renderer), rm = try XCTUnwrap(meters.renderer)
        rs.needsDisplay = false; rm.needsDisplay = false
        // Many moves between two display ticks: one dirty flag, no drawing in the observer.
        for k in 0..<50 { link.set(PanelCursor(frequencyHz: 4_100 + Float(k), source: .spectrum)) }
        XCTAssertTrue(rs.needsDisplay)
        XCTAssertTrue(rm.needsDisplay, "the cursor entered the Presence band")
        rs.needsDisplay = false; rm.needsDisplay = false
        XCTAssertTrue(rm.refreshText(now: 1000)); XCTAssertFalse(rm.refreshText(now: 1001), "nothing changed: no repaint")
        // A move inside the same band changes nothing the meters draw.
        link.set(PanelCursor(frequencyHz: 4_500, source: .spectrum))
        XCTAssertTrue(rs.needsDisplay)
        XCTAssertFalse(rm.needsDisplay)
        XCTAssertFalse(rm.refreshText(now: 1002))
        // The same cursor again: the link does not even notify.
        rs.needsDisplay = false
        link.set(PanelCursor(frequencyHz: 4_500, source: .spectrum))
        XCTAssertFalse(rs.needsDisplay)
        // Text of a linked panel follows the cursor at most 30 times per second.
        XCTAssertTrue(rs.refreshText(now: 2000))
        link.set(PanelCursor(frequencyHz: 4_600, source: .spectrogram))
        XCTAssertFalse(rs.refreshText(now: 2000.01))
        XCTAssertTrue(rs.refreshText(now: 2000.04))
    }

    func testClickPinsAndAClickOnThePinnedCursorClears() throws {
        let link = PanelCursorLink()
        let v = try view(.spectrum, link: link)
        let r = try XCTUnwrap(v.renderer as? SpectrumRenderer)
        let y = r.plotRectForTesting.midY
        XCTAssertTrue(v.handleCursorClick(at: CGPoint(x: r.xForTesting(hz: 3_100), y: y)))
        XCTAssertEqual(link.cursor?.isPinned, true)
        XCTAssertEqual(try XCTUnwrap(link.cursor).frequencyHz, 3_100, accuracy: 2)
        XCTAssertFalse(r.showsPointerReadout); XCTAssertTrue(r.showsHeaderReadout, "a pinned cursor reads in the header row, also in its source panel")
        // Hover moves are ignored while pinned (the link's rule); a click elsewhere moves the pin.
        link.set(PanelCursor(frequencyHz: 100, source: .spectrogram))
        XCTAssertEqual(try XCTUnwrap(link.cursor).frequencyHz, 3_100, accuracy: 2)
        XCTAssertTrue(v.handleCursorClick(at: CGPoint(x: r.xForTesting(hz: 500), y: y)))
        XCTAssertEqual(try XCTUnwrap(link.cursor).frequencyHz, 500, accuracy: 1)
        XCTAssertEqual(link.cursor?.isPinned, true)
        // On the hairline (within 5 pt): cleared, and the pointer's hover cursor takes over.
        XCTAssertTrue(v.handleCursorClick(at: CGPoint(x: r.xForTesting(hz: 500) + 3, y: y)))
        XCTAssertEqual(link.cursor?.isPinned, false)
        XCTAssertTrue(r.showsPointerReadout)
        // Outside the plot: not a cursor click.
        XCTAssertFalse(v.handleCursorClick(at: CGPoint(x: 3, y: 3)))
        XCTAssertFalse(try view(.meters, link: link).handleCursorClick(at: CGPoint(x: 100, y: 100)))
    }

    func testKeyboardStepsPinsAndClears() throws {
        let link = PanelCursorLink()
        let v = try view(.spectrum, link: link)
        XCTAssertFalse(v.handleCursorKey(.escape, shift: false), "Esc without a cursor goes up the responder chain")
        XCTAssertFalse(v.handleCursorKey(.pin, shift: false))
        XCTAssertFalse(v.handleCursorKey(.up, shift: false), "time steps belong to the spectrogram")
        // The first arrow key starts at the frame's peak.
        XCTAssertTrue(v.handleCursorKey(.right, shift: false))
        let peak = Self.frames.last!.peak.frequencyHz
        XCTAssertEqual(try XCTUnwrap(link.cursor).frequencyHz, peak, accuracy: 0.001)
        XCTAssertEqual(link.cursor?.source, .spectrum)
        XCTAssertTrue(v.handleCursorKey(.right, shift: false))
        XCTAssertEqual(try XCTUnwrap(link.cursor).frequencyHz, peak * pow(2, 1.0 / 12), accuracy: 0.01)
        XCTAssertTrue(v.handleCursorKey(.left, shift: true))
        XCTAssertEqual(try XCTUnwrap(link.cursor).frequencyHz, peak * pow(2, 1.0 / 12) / 2, accuracy: 0.01)
        XCTAssertEqual(v.renderer?.showsHeaderReadout, true, "no pointer: the readout stands in the header row")
        // Return pins, arrows move the pinned cursor, Return unpins, Esc clears.
        XCTAssertTrue(v.handleCursorKey(.pin, shift: false)); XCTAssertEqual(link.cursor?.isPinned, true)
        XCTAssertTrue(v.handleCursorKey(.right, shift: true)); XCTAssertEqual(link.cursor?.isPinned, true)
        XCTAssertEqual(try XCTUnwrap(link.cursor).frequencyHz, peak * pow(2, 1.0 / 12), accuracy: 0.01)
        XCTAssertTrue(v.handleCursorKey(.pin, shift: false)); XCTAssertEqual(link.cursor?.isPinned, false)
        XCTAssertTrue(v.handleCursorKey(.escape, shift: false)); XCTAssertNil(link.cursor)

        // The meters move the same cursor (frequency only).
        let m = try view(.meters, link: link)
        XCTAssertTrue(m.handleCursorKey(.left, shift: false)); XCTAssertEqual(link.cursor?.source, .meters)

        // Spectrogram: up / down step the time by one column, Shift by one second; never newer than the newest column.
        link.clear()
        let g = try view(.spectrogram, link: link)
        let r = try XCTUnwrap(g.renderer as? SpectrogramRenderer)
        XCTAssertTrue(g.handleCursorKey(.down, shift: false))
        XCTAssertEqual(try XCTUnwrap(link.cursor?.secondsAgo), r.newestSecondsAgo, accuracy: 1e-9)
        XCTAssertTrue(g.handleCursorKey(.down, shift: false))
        XCTAssertEqual(try XCTUnwrap(link.cursor?.secondsAgo), r.newestSecondsAgo + r.columnSeconds, accuracy: 1e-9)
        XCTAssertTrue(g.handleCursorKey(.down, shift: true))
        XCTAssertEqual(try XCTUnwrap(link.cursor?.secondsAgo), r.newestSecondsAgo + r.columnSeconds + 1, accuracy: 1e-9)
        for _ in 0..<3 { XCTAssertTrue(g.handleCursorKey(.up, shift: true)) }
        XCTAssertEqual(try XCTUnwrap(link.cursor?.secondsAgo), r.newestSecondsAgo, accuracy: 1e-9)
        // Left / right keep the time.
        XCTAssertTrue(g.handleCursorKey(.right, shift: false))
        XCTAssertNotNil(link.cursor?.secondsAgo)
    }

    func testAccessibilityValueAndRateLimitedAnnouncements() throws {
        let link = PanelCursorLink()
        let v = try view(.spectrum, link: link), m = try view(.meters, link: link)
        XCTAssertFalse(v.accessibilitySummary.contains("ursor"))
        var said: [String] = []
        v.announcementSink = { said.append($0) }
        // A hover cursor changes the value, but says nothing.
        link.set(PanelCursor(frequencyHz: 440, source: .spectrogram))
        XCTAssertTrue(v.accessibilitySummary.contains("Cursor: 440.0 Hz, A4"), v.accessibilitySummary)
        XCTAssertTrue(m.accessibilitySummary.contains("Cursor: Low mid 250\u{2013}500 Hz"), m.accessibilitySummary)
        XCTAssertTrue(said.isEmpty)
        // A burst of key moves: one announcement at once, and one more with the place the cursor came to rest.
        for _ in 0..<8 { v.handleCursorKey(.right, shift: false) }
        XCTAssertEqual(said.count, 1)
        let rest = expectation(description: "trailing announcement")
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelView.announcementInterval + 0.25) { rest.fulfill() }
        wait(for: [rest], timeout: 3)
        XCTAssertEqual(said.count, 2, "at most 2 per second")
        XCTAssertTrue(said[1].hasPrefix("Cursor: \(CursorMath.hz(link.cursor!.frequencyHz))"), said[1])
        v.handleCursorKey(.pin, shift: false)
        let pinned = expectation(description: "pin announcement")
        DispatchQueue.main.asyncAfter(deadline: .now() + PanelView.announcementInterval + 0.25) { pinned.fulfill() }
        wait(for: [pinned], timeout: 3)
        XCTAssertTrue(said.last?.hasPrefix("Pinned cursor: ") == true)
    }

    func testBandHighlightFollowsTheCursor() throws {
        try RenderTestSupport.requireMetal()
        // Meters: the caption names the band of the cursor frequency.
        let s = try session(.meters, cursor: PanelCursor(frequencyHz: 5_000, source: .spectrum, isPinned: true))
        _ = try s.snapshotPNG()
        XCTAssertTrue(s.renderer.textLayer.lastLabels.contains { $0.text.hasPrefix("Presence 4\u{2013}6 kHz") }, "\(s.renderer.textLayer.lastLabels.map(\.text))")
        // The picture differs from the one without a cursor only around the Presence bar.
        let without = try session(.meters, cursor: nil)
        let whole = CGRect(x: 0, y: 0, width: 560, height: 360)
        let d = try difference(s.snapshotPNG(), without.snapshotPNG(), in: whole)
        XCTAssertFalse(d.columns.isEmpty)
        // Goniometer at card size: the block under the key numbers.
        let v = try session(.vectorscope, cursor: PanelCursor(frequencyHz: 5_000, source: .spectrum))
        _ = try v.snapshotPNG()
        XCTAssertTrue(v.renderer.textLayer.lastLabels.contains { $0.text == "PRESENCE 4\u{2013}6 kHz" }, "\(v.renderer.textLayer.lastLabels.map(\.text))")
    }
}
