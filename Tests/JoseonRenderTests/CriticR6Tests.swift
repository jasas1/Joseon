import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Design review round 6: single-defect fixes, one test (or more) per defect. Review images go to
/// `RenderTestSupport.outputDirectory` (set JOSEON_RENDER_OUT), with the prefix `cr6-`.
final class CriticR6Tests: XCTestCase {
    static func session(_ panel: PanelKind, _ frames: [AnalysisFrame], _ settings: OffscreenRenderer.Settings = .init(), size: CGSize,
                        write name: String? = nil) throws -> OffscreenRenderer.Session {
        let s = try OffscreenRenderer.Session(panel: panel, size: size, scale: 2, theme: Theme(), settings: settings)
        try s.feed(frames)
        let png = try s.snapshotPNG()
        if let name { RenderTestSupport.write(png, "cr6-\(name).png") }
        return s
    }
    static func texts(_ s: OffscreenRenderer.Session) -> [String] { s.renderer.textLayer.lastLabels.map(\.text) }

    static func compareSettings(_ frames: [AnalysisFrame], edit: (inout OffscreenRenderer.Settings) -> Void = { _ in }) -> OffscreenRenderer.Settings {
        var s = OffscreenRenderer.Settings()
        s.comparison = SyntheticFrames.demoComparison(from: frames[frames.count - 1])
        edit(&s)
        return s
    }

    // MARK: D7: A/B labels and look

    func testBIsNamedLongTermAndTheStripSaysOnceThatTheCurvesAreAsPlayed() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 12).suffix(120))
        let on = try Self.session(.spectrum, frames, Self.compareSettings(frames), size: CGSize(width: 1200, height: 600), write: "d7-compare-1200x600")
        let t = Self.texts(on)
        XCTAssertTrue(t.contains("B \u{00B7} long-term"), "\(t)")
        XCTAssertFalse(t.contains { $0.contains("live") }, "\(t)")
        XCTAssertEqual(t.filter { $0 == "curves as played \u{00B7} lane level-matched" }.count, 1, "\(t)")
        XCTAssertTrue(t.contains { $0.hasPrefix("level-matched, B is") }, "the offset stays in the strip: \(t)")

        let off = try Self.session(.spectrum, frames, Self.compareSettings(frames) { $0.comparisonLevelMatch = false }, size: CGSize(width: 1200, height: 600))
        XCTAssertFalse(Self.texts(off).contains { $0.contains("curves as played") }, "nothing is matched: nothing to explain")

        // The card: the note keeps its place (short form at least) before the long form of the detail.
        let card = try Self.session(.spectrum, frames, Self.compareSettings(frames), size: CGSize(width: 560, height: 360), write: "d7-compare-560x360")
        XCTAssertEqual(Self.texts(card).filter { $0.hasPrefix("curves as played") }.count, 1, "\(Self.texts(card))")
    }

    func testAIsASaturatedGoldLineOfOneAndAHalfPoints() throws {
        try RenderTestSupport.requireMetal()
        let c = Palette(theme: Theme(), highContrast: false).reference
        XCTAssertEqual(c.x, 0xE3 / 255.0, accuracy: 0.002); XCTAssertEqual(c.y, 0xB3 / 255.0, accuracy: 0.002); XCTAssertEqual(c.z, 0x41 / 255.0, accuracy: 0.002)
        XCTAssertEqual(c.w, 0.90, accuracy: 0.001)
        XCTAssertEqual(SpectrumRenderer.referenceHalfWidth * 2, 1.5)

        // Only A and B on the plot: gold pixels are A. At scale 2 a 1.5 pt line covers 3 px or more of a column.
        let frames = Array(RealFrames.demo(seconds: 12).suffix(120))
        let settings = Self.compareSettings(frames) { $0.spectrum.showMid = false; $0.spectrum.showLeftRight = false; $0.spectrum.showPeakHold = false }
        let s = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 900, height: 420), scale: 2, theme: Theme(), settings: settings)
        try s.feed(frames)
        let px = try RenderTestSupport.decode(png: try s.snapshotPNG())
        let r = try XCTUnwrap(s.renderer as? SpectrumRenderer)
        let plot = r.plotRectForTesting
        var columns = 0, thick = 0
        for x in stride(from: Int(plot.minX * 2) + 40, to: Int(plot.maxX * 2) - 80, by: 7) {
            var gold = 0
            for y in Int(plot.minY * 2)..<Int(plot.maxY * 2) {
                let (red, green, blue) = px.rgb(x, y)
                if red > 105, red - blue > 60, green > blue + 35 { gold += 1 }
            }
            if gold > 0 { columns += 1 }
            if gold >= 3 { thick += 1 }
        }
        XCTAssertGreaterThan(columns, 100, "A is on the plot, and it is gold")
        XCTAssertGreaterThan(Double(thick), Double(columns) * 0.8, "1.5 pt: 3 device pixels or more in most columns")
    }

    // MARK: D8: the lane never draws without a scale

    func testTheLaneHasFiftySixPointsAndATickPairOrIsDroppedWithANote() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 12).suffix(60))
        let settings = Self.compareSettings(frames)
        var shown = 0, dropped = 0
        for size in LabelLayoutTests.sizes + [CGSize(width: 560, height: 250), CGSize(width: 560, height: 262), CGSize(width: 620, height: 236), CGSize(width: 900, height: 300)] {
            let name = "\(Int(size.width))x\(Int(size.height))"
            let review = [CGSize(width: 620, height: 236), CGSize(width: 900, height: 300), CGSize(width: 560, height: 262)].contains(size)
            let s = try Self.session(.spectrum, frames, settings, size: size, write: review ? "d8-lane-\(name)" : nil)
            let r = try XCTUnwrap(s.renderer as? SpectrumRenderer)
            let t = Self.texts(s)
            if r.laneRectForTesting == .zero {
                dropped += 1
                XCTAssertTrue(t.contains { SpectrumRenderer.laneHiddenNotes.contains($0) }, "\(name): a dropped lane is said: \(t)")
                XCTAssertFalse(t.contains(ComparisonText.deltaName), name)
                XCTAssertFalse(r.referenceTraceForTesting.isEmpty, "\(name): the trace stays")
                XCTAssertTrue(s.renderer.accessibilityValueText.contains("Difference lane hidden"), name)
                if size.width >= 600 { XCTAssertTrue(t.contains("B \u{2212} A lane hidden (panel too small)"), "\(name): \(t)") }
            } else {
                shown += 1
                let body = r.laneBodyForTesting
                XCTAssertGreaterThanOrEqual(body.height, 56, name)
                XCTAssertLessThanOrEqual(r.laneRectForTesting.height / (r.plotRectForTesting.height + r.laneRectForTesting.height), SpectrumRenderer.laneMaximumFraction + 0.001, name)
                XCTAssertFalse(t.contains { SpectrumRenderer.laneHiddenNotes.contains($0) }, name)
                // A signed tick pair beside the zero, inside the lane body.
                let ticks = s.renderer.textLayer.lastLabels.filter { ["+3", "\u{2212}3", "+6", "\u{2212}6", "+12", "\u{2212}12"].contains($0.text) && $0.rect.midY > body.minY && $0.rect.midY < body.maxY }
                XCTAssertGreaterThanOrEqual(ticks.count, 2, "\(name): \(t)")
                XCTAssertTrue(r.laneTicks.contains { $0 > 0 } && r.laneTicks.contains { $0 < 0 }, name)
            }
        }
        XCTAssertGreaterThan(shown, 3); XCTAssertGreaterThan(dropped, 1)
    }

    // MARK: D9 and clutter: fewer traces while a reference or a ghost trace asks the question

    /// Pixels of the plot that are the dashed cyan of the ghost trace, and how many runs they make along a row band.
    private static func cyanPixels(_ px: RenderTestSupport.Pixels, in rect: CGRect) -> Int {
        var n = 0
        for y in Int(rect.minY * 2)..<Int(rect.maxY * 2) {
            for x in Int(rect.minX * 2)..<Int(rect.maxX * 2) {
                let (r, g, b) = px.rgb(x, y)
                if b > 170, g > 120, r < 110, b - r > 110 { n += 1 }
            }
        }
        return n
    }

    func testNoLeftRightWithAReferenceAndNoPeakHoldOrLongTermWithAGhostTrace() throws {
        try RenderTestSupport.requireMetal()
        let all = RealFrames.demo(seconds: 12)
        let frames = Array(all.suffix(120))
        let size = CGSize(width: 1200, height: 600)

        // A reference: no L, no R, in the plot, the legend or the readout. The switch gives them back.
        var settings = Self.compareSettings(frames) { $0.cursor = PanelCursor(frequencyHz: 3_100, source: .spectrum, isPinned: true) }
        let on = try Self.session(.spectrum, frames, settings, size: size, write: "d9-reference-1200x600")
        let r = try XCTUnwrap(on.renderer as? SpectrumRenderer)
        XCTAssertNil(r.curveForTesting("left")); XCTAssertNil(r.curveForTesting("right"))
        XCTAssertFalse(Self.texts(on).contains("L")); XCTAssertFalse(Self.texts(on).contains("R"))
        XCTAssertFalse(Self.texts(on).contains { $0.hasPrefix("L ") && $0.contains("R ") }, "\(Self.texts(on))")
        XCTAssertFalse(Self.texts(on).contains(SpectrumRenderer.leftRightSmoothingHint))
        settings.spectrumAutoDeclutter = false
        let off = try Self.session(.spectrum, frames, settings, size: size)
        XCTAssertNotNil((off.renderer as? SpectrumRenderer)?.curveForTesting("left"))
        XCTAssertTrue(Self.texts(off).contains("L"))

        // A timed cursor with its ghost trace: no Peak hold, no Long-term; the ghost is dashed cyan and named.
        var ghost = OffscreenRenderer.Settings()
        ghost.cursor = PanelCursor(frequencyHz: 392, secondsAgo: 3.2, source: .spectrogram)
        ghost.cursorHistorySlice = try XCTUnwrap(try OffscreenRenderer.historySlice(frames: all, secondsAgo: 3.2))
        let g = try OffscreenRenderer.Session(panel: .spectrum, size: size, scale: 2, theme: Theme(), settings: ghost)
        try g.feed(frames)
        let png = try g.snapshotPNG()
        RenderTestSupport.write(png, "cr6-d9-ghost-1200x600.png")
        let gr = try XCTUnwrap(g.renderer as? SpectrumRenderer)
        XCTAssertNotNil(gr.curveForTesting("ghost"))
        XCTAssertNil(gr.curveForTesting("peakHold")); XCTAssertNil(gr.curveForTesting("average"))
        let t = Self.texts(g)
        XCTAssertFalse(t.contains("Peak hold")); XCTAssertFalse(t.contains(SpectrumRenderer.averageLegend))
        XCTAssertTrue(t.contains { $0.hasPrefix("then (") }, "\(t)")
        let c = Palette(theme: Theme(), highContrast: false).cursorGhost
        XCTAssertEqual(c.x, 0x39 / 255.0, accuracy: 0.002); XCTAssertEqual(c.y, 0xC2 / 255.0, accuracy: 0.002); XCTAssertEqual(c.z, 1, accuracy: 0.002); XCTAssertEqual(c.w, 0.85, accuracy: 0.001)
        XCTAssertEqual(SpectrumRenderer.ghostDash.period * SpectrumRenderer.ghostDash.duty, 6, accuracy: 0.001)
        XCTAssertEqual(SpectrumRenderer.ghostDash.period * (1 - SpectrumRenderer.ghostDash.duty), 4, accuracy: 0.001)

        // Dashed on the picture: along the quiet highs (the curve is near level there) the cyan comes in runs with gaps.
        let px = try RenderTestSupport.decode(png: png)
        let plot = gr.plotRectForTesting
        XCTAssertGreaterThan(Self.cyanPixels(px, in: plot), 400)
        var runs = 0, inRun = false
        let x0 = Int(gr.xForTesting(hz: 7_500) * 2), x1 = Int(gr.xForTesting(hz: 16_000) * 2)
        for x in x0..<x1 {
            var hit = false
            for y in Int(plot.minY * 2)..<Int(plot.maxY * 2) {
                let (red, green, blue) = px.rgb(x, y)
                if blue > 170, green > 120, red < 110, blue - red > 110 { hit = true; break }
            }
            if hit, !inRun { runs += 1 }
            inRun = hit
        }
        let expected = Double(x1 - x0) / 2 / 10
        XCTAssertGreaterThan(Double(runs), expected * 0.6, "about one dash per 10 pt")
        XCTAssertLessThan(Double(runs), expected * 1.5)

        // Without the switch the two lines are back.
        ghost.spectrumAutoDeclutter = false
        let loud = try Self.session(.spectrum, frames, ghost, size: size)
        XCTAssertTrue(Self.texts(loud).contains("Peak hold"))
    }

    /// At card sizes (and at every size) L / R, Side, Peak hold and Long-term are drawn only with their name in the legend.
    func testNoTraceWithoutItsNameInTheLegend() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 12).suffix(120))
        var plain = OffscreenRenderer.Settings(); plain.spectrum.showSide = true
        var unnamed = 0
        for (k, settings) in [plain, Self.compareSettings(frames)].enumerated() {
            for size in LabelLayoutTests.sizes {
                let name = "\(k == 0 ? "plain" : "reference")-\(Int(size.width))x\(Int(size.height))"
                let s = try Self.session(.spectrum, frames, settings, size: size, write: size == CGSize(width: 460, height: 330) ? "d9-card-\(name)" : nil)
                let r = try XCTUnwrap(s.renderer as? SpectrumRenderer)
                let t = Self.texts(s)
                for (slot, label) in [(SpectrumRenderer.Slot.left, "L"), (.side, "Side"), (.peakHold, "Peak hold"), (.average, SpectrumRenderer.averageLegend)] {
                    XCTAssertEqual(r.legendNamed.contains(slot), t.contains(label), "\(name): \(label)")
                    if !t.contains(label) { unnamed += 1 }
                }
                XCTAssertEqual(t.contains("L"), t.contains("R"), name)
            }
        }
        XCTAssertGreaterThan(unnamed, 8, "the cards have no room for every name: the rule is exercised")

        // The picture: a card whose legend names only Mid has no L (blue-grey) or R (salmon) line over the quiet highs.
        var o = OffscreenRenderer.Settings(); o.spectrum.showPeakHold = false; o.spectrum.showAverage = false
        let size = CGSize(width: 250, height: 210)
        func sidePixels(_ settings: OffscreenRenderer.Settings) throws -> (Int, [String]) {
            let s = try OffscreenRenderer.Session(panel: .spectrum, size: size, scale: 2, theme: Theme(), settings: settings)
            try s.feed(frames)
            let px = try RenderTestSupport.decode(png: try s.snapshotPNG())
            let r = try XCTUnwrap(s.renderer as? SpectrumRenderer)
            let plot = r.plotRectForTesting
            var n = 0
            // Over Mid between 700 Hz and 2.5 kHz (the demo's L and R stand a few dB over Mid there): salmon pixels are R.
            for x in Int(r.xForTesting(hz: 700) * 2)..<Int(r.xForTesting(hz: 2_500) * 2) {
                for y in Int(plot.minY * 2)..<Int(plot.maxY * 2) {
                    let (red, green, blue) = px.rgb(x, y)
                    if red > 150, red - blue > 50, red - green > 40, blue > 70 { n += 1 }
                }
            }
            return (n, s.renderer.textLayer.lastLabels.map(\.text))
        }
        let (tidy, labels) = try sidePixels(o)
        XCTAssertFalse(labels.contains("R"), "the fixture: no room for L and R in the legend: \(labels)")
        o.spectrumAutoDeclutter = false
        let (all, _) = try sidePixels(o)
        XCTAssertGreaterThan(all, 20, "the R line is there without the rule")
        XCTAssertLessThan(tidy, all / 4)
    }

    // MARK: D10: no headphone band without its words

    func testTheHeadphoneBandIsDrawnOnlyWithItsLegendRowAndAxis() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 6, headphone: true).suffix(60))
        let bandWords = ["Response", "Target", "Error"]
        var shown = 0, hidden = 0
        for size in LabelLayoutTests.sizes + [CGSize(width: 560, height: 190), CGSize(width: 470, height: 260), CGSize(width: 900, height: 300)] {
            let name = "\(Int(size.width))x\(Int(size.height))"
            let review = [CGSize(width: 560, height: 190), CGSize(width: 470, height: 260), CGSize(width: 900, height: 300)].contains(size)
            let s = try Self.session(.spectrum, frames, size: size, write: review ? "d10-band-\(name)" : nil)
            let r = try XCTUnwrap(s.renderer as? SpectrumRenderer)
            let t = Self.texts(s)
            if r.headphoneBandForTesting != nil {
                shown += 1
                for w in bandWords + ["Demo headphone", "dB rel", "+12", "\u{2212}12"] where !(w.hasSuffix("12") && size.height < 300) { XCTAssertTrue(t.contains(w), "\(name): \(w) in \(t)") }
                XCTAssertTrue(t.contains("0"), name)
                XCTAssertEqual(r.atEarShown, t.contains(SpectrumRenderer.atEarVsTargetLegend), "\(name): the at-ear trace and its name go together")
                XCTAssertFalse(t.contains { ComparisonText.bandHidden.contains($0) }, name)
            } else {
                hidden += 1
                XCTAssertFalse(r.atEarShown, name)
                XCTAssertTrue(t.contains { ComparisonText.bandHidden.contains($0) }, "\(name): the header says that the band is hidden: \(t)")
                for w in bandWords + ["dB rel"] { XCTAssertFalse(t.contains(w), "\(name): \(w)") }
                XCTAssertTrue(s.renderer.accessibilityValueText.contains("Headphone band hidden"), name)
            }
        }
        XCTAssertGreaterThan(shown, 2); XCTAssertGreaterThan(hidden, 3)
    }

    /// The picture of a hidden band: no amber response line in the top quarter of a compact card.
    func testACompactCardDrawsNoUnlabelledHeadphoneCurves() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 6, headphone: true).suffix(60))
        func amber(_ settings: OffscreenRenderer.Settings) throws -> Int {
            let s = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 560, height: 190), scale: 2, theme: Theme(), settings: settings)
            try s.feed(frames)
            let px = try RenderTestSupport.decode(png: try s.snapshotPNG())
            let plot = try XCTUnwrap(s.renderer as? SpectrumRenderer).plotRectForTesting
            var n = 0
            // Above 5 kHz the music is far under the top quarter: amber there is the headphone response.
            for x in Int(plot.minX * 2 + plot.width * 2 * 0.8)..<Int(plot.maxX * 2) - 40 {
                for y in Int(plot.minY * 2)..<Int(plot.minY * 2 + plot.height * 2 * 0.25) {
                    let (r, g, b) = px.rgb(x, y)
                    if r > 120, r - b > 60, g > b + 20 { n += 1 }
                }
            }
            return n
        }
        XCTAssertEqual(try amber(.init()), 0)
    }

    /// With the lane on Signal and under 420 pt of plot the band gives way, at the 900 pt layout as at 1280.
    func testTheBandGivesWayToTheSignalLaneUnderFourHundredTwentyPoints() throws {
        try RenderTestSupport.requireMetal()
        let frames = ComparisonReviewTests.live(seconds: 8, headphone: .hd800sLike)
        var settings = OffscreenRenderer.Settings()
        settings.comparison = SyntheticFrames.demoComparison(from: try XCTUnwrap(frames.last), headphone: .susvaraLike)
        for (size, both) in [(CGSize(width: 900, height: 420), false), (CGSize(width: 1280, height: 380), false), (CGSize(width: 900, height: 470), false), (CGSize(width: 900, height: 500), true), (CGSize(width: 1200, height: 600), true)] {
            let name = "\(Int(size.width))x\(Int(size.height))"
            let s = try Self.session(.spectrum, Array(frames.suffix(30)), settings, size: size, write: size.height == 420 ? "d10-lane-wins-\(name)" : nil)
            let r = try XCTUnwrap(s.renderer as? SpectrumRenderer)
            XCTAssertNotEqual(r.laneRectForTesting, .zero, name)
            XCTAssertEqual(r.headphoneBandForTesting != nil, both, name)
            XCTAssertEqual(Self.texts(s).contains("headphone band hidden"), !both, "\(name): \(Self.texts(s))")
        }
        // In headphone mode the band is part of the question: it stays down to 360 pt of view.
        settings.comparisonMode = .headphone
        let hp = try Self.session(.spectrum, Array(frames.suffix(30)), settings, size: CGSize(width: 900, height: 420))
        XCTAssertNotNil((hp.renderer as? SpectrumRenderer)?.headphoneBandForTesting)
    }

    // MARK: D5: one color rule for the target delta; the clip lamp keeps its word

    func testTheTargetDeltaHasOneColorRuleAtEverySize() throws {
        try RenderTestSupport.requireMetal()
        let p = Palette(theme: Theme(), highContrast: false)
        XCTAssertEqual(MetersRenderer.targetDeltaColor(8.6, p), p.warn); XCTAssertEqual(MetersRenderer.targetDeltaColor(1.04, p), p.text)
        XCTAssertEqual(MetersRenderer.targetDeltaColor(0, p), p.text); XCTAssertEqual(MetersRenderer.targetDeltaColor(-1.0, p), p.text)
        XCTAssertEqual(MetersRenderer.targetDeltaColor(-1.06, p), p.good); XCTAssertEqual(MetersRenderer.targetDeltaColor(1.06, p), p.warn)

        var frames = Array(RealFrames.demo(seconds: 6).suffix(90))
        var settings = OffscreenRenderer.Settings(); settings.targetLUFS = -14
        enum Tone { case amber, neutral, green }
        for (delta, want) in [(Float(8.6), Tone.amber), (0.4, .neutral), (-6.2, .green)] {
            for i in frames.indices { frames[i].loudness.integratedLUFS = -14 + delta; frames[i].loudness.isIntegratedValid = true }
            for size in [CGSize(width: 1200, height: 600), CGSize(width: 560, height: 360), CGSize(width: 460, height: 330), CGSize(width: 300, height: 220)] {
                let name = "\(delta) at \(Int(size.width))x\(Int(size.height))"
                let s = try OffscreenRenderer.Session(panel: .meters, size: size, scale: 2, theme: Theme(), settings: settings)
                try s.feed(frames)
                let png = try s.snapshotPNG()
                if delta > 8 { RenderTestSupport.write(png, "cr6-d5-hot-meters-\(Int(size.width))x\(Int(size.height)).png") }
                let px = try RenderTestSupport.decode(png: png)
                let label = try XCTUnwrap(s.renderer.textLayer.lastLabels.first { $0.text.hasSuffix(" LU") && ($0.text.hasPrefix("+") || $0.text.hasPrefix("\u{2212}")) }, name)
                // The brightest pixel of the label is its ink.
                var ink = (0, 0, 0)
                for y in Int(label.rect.minY * 2)..<Int(label.rect.maxY * 2) { for x in Int(label.rect.minX * 2)..<Int(label.rect.maxX * 2) {
                    let c = px.rgb(x, y); if c.0 + c.1 + c.2 > ink.0 + ink.1 + ink.2 { ink = c }
                } }
                switch want {
                case .amber: XCTAssertTrue(ink.0 > ink.2 + 60 && ink.0 > ink.1, "\(name): amber, got \(ink)")
                case .neutral: XCTAssertTrue(abs(ink.0 - ink.1) < 30 && abs(ink.1 - ink.2) < 40, "\(name): neutral, got \(ink)")
                case .green: XCTAssertTrue(ink.1 > ink.0 + 60 && ink.1 > ink.2, "\(name): green-cyan, got \(ink)")
                }
            }
        }
    }

    func testTheClipLampNeverLosesItsWord() throws {
        try RenderTestSupport.requireMetal()
        var frames = Array(RealFrames.demo(seconds: 3).suffix(30))
        for i in frames.indices { frames[i].loudness.clipCount = 1234 }
        var full = 0, word = 0
        for width in stride(from: 200, through: 1200, by: 20) {
            for height in [220, 330, 600] as [CGFloat] {
                let s = try Self.session(.meters, frames, size: CGSize(width: CGFloat(width), height: height))
                let t = Self.texts(s)
                XCTAssertFalse(t.contains("999+"), "\(width)x\(Int(height)): the count never stands alone")
                if t.contains("CLIP 999+") { full += 1 } else { XCTAssertTrue(t.contains("CLIP"), "\(width)x\(Int(height)): \(t)"); word += 1 }
            }
        }
        XCTAssertGreaterThan(full, 100)
        print("CR6 clip lamp: \(full) sizes with CLIP 999+, \(word) with the word only")
    }

    // MARK: D12: timeline small print

    static let utc = TimeZone(identifier: "UTC")!
    static func timelineSettings(_ edit: (inout OffscreenRenderer.Settings) -> Void = { _ in }) -> OffscreenRenderer.Settings {
        var s = OffscreenRenderer.Settings()
        s.session = SyntheticFrames.demoSession(minutes: 25); s.timelineWindowSeconds = 1800; s.timelineTimeZone = utc; s.targetLUFS = -14
        edit(&s)
        return s
    }

    func testTimelineWordsAndTheTruePeakRangeAndTheOptInEarLane() throws {
        try RenderTestSupport.requireMetal()
        let frames = SyntheticFrames.sequence(count: 2)
        let wide = try Self.session(.timeline, frames, Self.timelineSettings(), size: CGSize(width: 1200, height: 220), write: "d12-timeline-1200x220")
        let t = Self.texts(wide)
        XCTAssertTrue(t.contains("S range "), "\(t)")
        XCTAssertTrue(t.contains("\u{2212}20\u{2026}\u{2212}9"), "\(t)")
        XCTAssertTrue(t.contains("8 s with clipped samples"), "\(t)")
        XCTAssertTrue(t.contains("1 true-peak over"), "\(t)")
        XCTAssertFalse(t.contains { $0.hasSuffix("s clipped") || $0 == "1 over" })
        XCTAssertEqual(TimelineRenderer.overCountText(3), "3 true-peak overs"); XCTAssertEqual(TimelineRenderer.clipCountText(0), "no clipped samples")
        // The words fit into the right-hand column.
        for l in wide.renderer.textLayer.lastLabels { XCTAssertLessThanOrEqual(l.rect.maxX, 1200, l.text) }

        // True peak: +3 ... -12 dBTP, 0 stands in the upper half of the lane no more.
        XCTAssertEqual(TimelineRenderer.peakRange.top, 3); XCTAssertEqual(TimelineRenderer.peakRange.bottom, -12)
        XCTAssertFalse(t.contains("\u{2212}24") && !t.contains("\u{2212}12"))

        // The lane "At the ear" is opt-in; the number stays in the readout.
        let r = try XCTUnwrap(wide.renderer as? TimelineRenderer)
        XCTAssertEqual(r.lanesForTesting.map(\.kind), [.loudness, .peak])
        XCTAssertFalse(t.contains("AT THE EAR"))
        let on = try Self.session(.timeline, frames, Self.timelineSettings { $0.timelineShowLevelAtEar = true }, size: CGSize(width: 1200, height: 220))
        XCTAssertEqual((on.renderer as? TimelineRenderer)?.lanesForTesting.map(\.kind), [.loudness, .peak, .ear])
        XCTAssertFalse(TimelineView(frameProvider: { AnalysisFrame(hostTime: 0, spectrum: .silent(binCount: 16), isSilent: true) }, sessionProvider: { SessionSnapshot() }).showLevelAtEar)
    }

    /// On a low strip the flag bars have no titles: each kind has its own warm hue, and the readout of the header row
    /// (the strip's hover) carries the hue before the flag's name.
    func testStripFlagBarsHaveAHuePerKindAndTheHoverIsTheirLegend() throws {
        try RenderTestSupport.requireMetal()
        let frames = SyntheticFrames.sequence(count: 2)
        let size = CGSize(width: 1200, height: 140)
        let plain = try OffscreenRenderer.Session(panel: .timeline, size: size, scale: 2, theme: Theme(), settings: Self.timelineSettings())
        let r = try XCTUnwrap(plain.renderer as? TimelineRenderer)
        let kinds = Set(r.model.spans.map(\.flagID))
        XCTAssertGreaterThanOrEqual(kinds.count, 2, "the demo record has two kinds of flag or more")
        let hues = Set(kinds.map { r.spanColor($0) })
        XCTAssertEqual(hues.count, min(kinds.count, TimelineRenderer.spanHues.count), "one hue per kind")
        for h in hues { XCTAssertTrue(h.x > h.z + 0.25 && h.x >= h.y, "warm: \(h)") }

        // Hover over a span: the header row names the flag with its hue.
        let span = try XCTUnwrap(r.model.spans.first { $0.end - $0.start > 30 })
        var hover = Self.timelineSettings()
        hover.hover = CGPoint(x: r.x(forTime: (span.start + span.end) / 2), y: 60)
        let s = try Self.session(.timeline, frames, hover, size: size, write: "d12-timeline-strip-hover-1200x140")
        let hr = try XCTUnwrap(s.renderer as? TimelineRenderer)
        let item = try XCTUnwrap(hr.cursorItems().first { $0.text.contains(span.title) })
        XCTAssertEqual(item.swatch, hr.spanColor(span.flagID))
        XCTAssertTrue(Self.texts(s).contains { $0.contains(span.title) }, "\(Self.texts(s))")
    }

    /// The box at the pointer never covers the labels of the time axis, wherever the pointer stands.
    func testTheHoverBoxNeverCoversTheTimeAxisLabels() throws {
        try RenderTestSupport.requireMetal()
        let frames = SyntheticFrames.sequence(count: 2)
        for size in [CGSize(width: 1200, height: 220), CGSize(width: 900, height: 200), CGSize(width: 560, height: 360), CGSize(width: 1200, height: 184)] {
            let probe = try OffscreenRenderer.Session(panel: .timeline, size: size, scale: 2, theme: Theme(), settings: Self.timelineSettings())
            let axisY = try XCTUnwrap(probe.renderer as? TimelineRenderer).axisYForTesting
            for fx in [0.2, 0.52, 0.74, 0.85] as [CGFloat] {
                for fy in [0.3, 0.6, 0.85] as [CGFloat] {
                    var settings = Self.timelineSettings()
                    settings.hover = CGPoint(x: size.width * fx, y: min(size.height * fy, axisY - 2))
                    let name = "\(Int(size.width))x\(Int(size.height)) at \(fx), \(fy)"
                    let s = try Self.session(.timeline, frames, settings, size: size, write: size.height == 220 && fx == 0.52 && fy == 0.85 ? "d12-timeline-hover-low-1200x220" : nil)
                    let r = try XCTUnwrap(s.renderer as? TimelineRenderer)
                    guard let label = r.hoverLabel() else {
                        // No box: the readout stands in the header row.
                        XCTAssertFalse(r.cursorItems().isEmpty, name); continue
                    }
                    let o = OverlayContext(size: size, pixelScale: 2)
                    let box = HoverLabel.boxSize(o, lines: label.lines)
                    let origin = HoverLabel.origin(anchor: label.anchor, box: box, bounds: size, floor: r.hoverLabelFloor)
                    XCTAssertLessThanOrEqual(origin.y + box.height, axisY, "\(name): the box ends over the axis")
                    XCTAssertGreaterThanOrEqual(origin.y, 0, name)
                }
            }
        }
    }

    // MARK: Minor: one name for the true-peak column, the PEAK readout stays in the header, the placement field

    func testTheTruePeakColumnHasOneNameByWidth() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 3).suffix(30))
        var long = 0, short = 0
        for width in stride(from: 240, through: 1200, by: 40) {
            for height in [220, 330, 600] as [CGFloat] {
                let t = Self.texts(try Self.session(.meters, frames, size: CGSize(width: CGFloat(width), height: height)))
                XCTAssertFalse(t.contains("PEAK"), "\(width)x\(Int(height)): \(t)")
                if t.contains("TRUE PEAK") { long += 1 } else if t.contains("TP") { short += 1 }
            }
        }
        XCTAssertGreaterThan(long, 20); XCTAssertGreaterThan(short, 3)
    }

    func testThePeakReadoutOfTheSpectrumIsInTheHeaderRowAtEverySize() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 6).suffix(60))
        for size in [CGSize(width: 1600, height: 700), CGSize(width: 1200, height: 600), CGSize(width: 1199, height: 600), CGSize(width: 900, height: 420), CGSize(width: 560, height: 360)] {
            let name = "\(Int(size.width))x\(Int(size.height))"
            let s = try Self.session(.spectrum, frames, size: size, write: size.width == 1600 ? "minor-peak-header-\(name)" : nil)
            let plot = try XCTUnwrap(s.renderer as? SpectrumRenderer).plotRectForTesting
            let labels = s.renderer.textLayer.lastLabels
            let caption = try XCTUnwrap(labels.first { $0.text == "PEAK" }, name)
            let hz = try XCTUnwrap(labels.first { $0.text.hasSuffix(" Hz") && $0.rect.minY < plot.minY }, name)
            XCTAssertLessThanOrEqual(caption.rect.maxY, plot.minY + 1, "\(name): over the plot")
            XCTAssertLessThanOrEqual(hz.rect.maxY, plot.minY + 1, name)
            XCTAssertFalse(labels.contains { $0.text.hasSuffix(" Hz") && $0.rect.minY >= plot.minY && $0.rect.maxY <= plot.maxY }, "\(name): no readout inside the plot")
        }
    }

    func testPlacementLightStaysInsideTheFrequencyAxisAndTheLegendIsSmooth() throws {
        try RenderTestSupport.requireMetal()
        let frames = RealFrames.demo(seconds: 6)
        var settings = OffscreenRenderer.Settings(); settings.vectorscopeMode = .panSpectrum
        let size = CGSize(width: 460, height: 460)
        let s = try OffscreenRenderer.Session(panel: .vectorscope, size: size, scale: 2, theme: Theme(), settings: settings)
        try s.feed(frames)
        let png = try s.snapshotPNG()
        RenderTestSupport.write(png, "cr6-minor-placement-460x460.png")
        let px = try RenderTestSupport.decode(png: png)
        let r = try XCTUnwrap(s.renderer as? VectorscopeRenderer)
        let axis = r.panAxisRectForTesting, legend = try XCTUnwrap(r.panLegendForTesting)

        // Just over the 20 Hz line the sub-bass is lit; under it nothing is.
        func lit(_ rows: Range<Int>) -> Int {
            var n = 0
            // The column of the centered bass, left of the legend and its numbers.
            for y in rows { for x in 460..<525 { let c = px.rgb(x, y); if max(c.0, c.1, c.2) > 70 { n += 1 } } }
            return n
        }
        let edge = Int(axis.maxY * 2)
        XCTAssertGreaterThan(lit(edge - 40..<edge - 2), 200, "the fixture: the sub-bass stands at the bottom of the axis")
        XCTAssertEqual(lit(edge + 2..<edge + 7), 0, "no glow under the 20 Hz line (the rows over the legend's numbers)")

        // The legend: a ramp without steps. Along each row the level never jumps, and there are many levels.
        XCTAssertGreaterThanOrEqual(VectorscopeRenderer.panLegendSteps(width: legend.width, scale: 2), Int(legend.width * 2) - 1)
        for row in 0..<3 {
            let y = Int((legend.minY + (CGFloat(row) + 0.5) * legend.height / 3) * 2)
            var last: Int?, levels = Set<Int>(), worst = 0
            for x in Int(legend.minX * 2) + 3..<Int(legend.maxX * 2) - 3 {
                let c = px.rgb(x, y), v = c.0 + c.1 + c.2
                if let last { worst = max(worst, abs(v - last)) }
                last = v; levels.insert(v)
            }
            XCTAssertLessThanOrEqual(worst, 14, "row \(row): no band edge (12 steps gave jumps of 40 and more)")
            XCTAssertGreaterThan(levels.count, 60, "row \(row)")
        }
    }

    // MARK: Spectrogram: the dashed quiet tone (r5 item 6)
    //
    // Cause (measured, see the two tests): not the row pick and not the color floor. `SpectrumResolution.detectTones()`
    // (JoseonCore) decided per FFT transform, without memory, whether a peak is tonal (5-bin power 14 dB over the noise
    // beside it). A steady tone 9 dB over the displayed noise stood under that gate and passed it on noise excursions
    // only: in 2 % of transforms `spectrum.mid` carried a pointed lobe at -55 dB, in the others it stayed on the
    // 1/6-octave noise curve and read as a broad bump at -61 dB. The spectrogram drew both truthfully: bright dashes on a
    // dim band. Round 8 gave the gate a memory (a second gate on the power spectrum averaged over eight transforms).

    /// A steady tone that the frames carry as a steady lobe is a continuous line: same row and same color in every column.
    func testASteadyLobeInTheFramesIsAContinuousLineInTheSpectrogram() throws {
        try RenderTestSupport.requireMetal()
        var base = SpectrumReading.silent(binCount: 1024)
        let bin = Round6FixTests.bin(base, 3_100)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func jitter() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return (Float(seed >> 40) / Float(1 << 24) - 0.5) * 3 }
        let frames: [AnalysisFrame] = (0..<(14 * 60)).map { k in
            for i in 0..<1024 { base.mid[i] = -65 + jitter() }
            // The lobe of a tone 9 dB over the noise, between two display bins' worth of skirt.
            base.mid[bin - 1] = -61; base.mid[bin] = -56; base.mid[bin + 1] = -61
            var f = AnalysisFrame(hostTime: Double(k) / 60, spectrum: base, isSilent: false)
            f.stream = StreamInfo(sampleRate: 48_000, channelCount: 2, deviceName: "Test")
            return f
        }
        let s = try OffscreenRenderer.Session(panel: .spectrogram, size: CGSize(width: 900, height: 300), scale: 2, theme: Theme(), settings: .init())
        try s.feed(frames)
        let png = try s.snapshotPNG()
        RenderTestSupport.write(png, "cr6-spectrogram-steady-lobe-900x300.png")
        let r = try XCTUnwrap(s.renderer as? SpectrogramRenderer)
        // The history: the line's row holds the tone in every column.
        for back in 0..<400 {
            let v = try XCTUnwrap(r.historyLevel(columnsBack: back, hz: base.frequencies[bin]))
            XCTAssertEqual(v, -56, accuracy: 1.0, "column \(back)")
        }
        // The picture: along the line every pixel column is lit alike, and stands over the rows beside it.
        let px = try RenderTestSupport.decode(png: png)
        let plot = r.plotRectForTesting
        let y = Int((r.yForTesting(hz: base.frequencies[bin]) * 2).rounded())
        var levels: [Int] = []
        // 14 s of frames in a 20 s history: the newest 55 % of the width.
        for x in Int((plot.minX + plot.width * 0.45) * 2)..<Int(plot.maxX * 2) - 40 {
            var best = 0
            for yy in y - 2...y + 2 { let c = px.rgb(x, yy); best = max(best, c.0 + c.1 + c.2) }
            let above = px.rgb(x, y - 12), below = px.rgb(x, y + 12)
            XCTAssertGreaterThan(best, max(above.0 + above.1 + above.2, below.0 + below.1 + below.2) + 40, "x \(x): the line stands over its surroundings")
            levels.append(best)
        }
        let lo = try XCTUnwrap(levels.min()), hi = try XCTUnwrap(levels.max())
        XCTAssertLessThan(Double(hi - lo), Double(hi) * 0.12, "no dashes: the line's light varies by under 12 % (\(lo)...\(hi))")
    }

    /// The same tone as audio through the real analyzer. Before `detectTones()` had hysteresis the tonal gate flipped and
    /// the line was dashed (pointed in 87 of 500 columns); with it, the line is continuous.
    func testASteadyToneNineDecibelsOverTheNoiseThroughTheRealAnalyzer() throws {
        try RenderTestSupport.requireMetal()
        let sr = 48_000.0, block = 800
        let noiseL = TestSignals.pinkNoise(amplitude: 0.04, count: 1 << 17, seed: 7), noiseR = TestSignals.pinkNoise(amplitude: 0.04, count: 1 << 17, seed: 99)
        let amp = Float(pow(10, -56.0 / 20))
        let engine = AnalysisEngine()
        engine.streamInfo = StreamInfo(sampleRate: sr, channelCount: 2, deviceName: "Test", bitDepth: 32, activeSources: [])
        var frames: [AnalysisFrame] = []
        for k in 0..<(14 * 60) {
            var l = [Float](repeating: 0, count: block), r = l
            for i in 0..<block {
                let n = k * block + i
                let tone = amp * Float(sin(2 * .pi * 3_100 * Double(n) / sr))
                l[i] = tone + noiseL[n % noiseL.count]; r[i] = tone + noiseR[n % noiseR.count]
            }
            var f = engine.processNow(left: l, right: r, count: block, sampleRate: sr)
            f.hostTime = Double(k) / 60
            frames.append(f)
        }
        let s = try OffscreenRenderer.Session(panel: .spectrogram, size: CGSize(width: 900, height: 300), scale: 2, theme: Theme(), settings: .init())
        try s.feed(frames)
        RenderTestSupport.write(try s.snapshotPNG(), "cr6-spectrogram-steady-tone-real-analyzer-900x300.png")
        let r = try XCTUnwrap(s.renderer as? SpectrogramRenderer)
        var pointed = 0, columns = 0
        var bed: Float = 0
        for back in 0..<500 {
            guard let v = r.historyLevel(columnsBack: back, hz: 3_100), let a = r.historyLevel(columnsBack: back, hz: 3_100 / 1.035), let b = r.historyLevel(columnsBack: back, hz: 3_100 * 1.035),
                  let far = r.historyLevel(columnsBack: back, hz: 2_700) else { continue }
            columns += 1; bed += far
            if v - max(a, b) >= 3 { pointed += 1 }
        }
        XCTAssertGreaterThan(columns, 400)
        XCTAssertEqual(bed / Float(columns), -65, accuracy: 2.5, "the fixture: the noise stands near -65 dB, 9 dB under the tone")
        print("CR6 steady tone through the analyzer: a pointed line in \(pointed) of \(columns) columns")
        XCTAssertGreaterThan(Double(pointed), Double(columns) * 0.95, "a steady tone is a continuous line")
    }
}
