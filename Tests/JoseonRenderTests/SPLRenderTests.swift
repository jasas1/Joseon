import XCTest
import JoseonCore
@testable import JoseonRender

/// "Level at the ear" in the meters panel and the dB SPL axis of the spectrum.
final class SPLRenderTests: XCTestCase {
    private static func splFrames(_ count: Int = 240, hot: Bool = false, headphone: Bool = false) -> [AnalysisFrame] {
        var o = SyntheticFrames.Options()
        o.includeSPL = true; o.hot = hot; o.includeHeadphone = headphone
        return SyntheticFrames.sequence(count: count, options: o)
    }

    private func labels(_ panel: PanelKind, _ frames: [AnalysisFrame], _ size: CGSize, _ settings: OffscreenRenderer.Settings = .init()) throws -> [(text: String, rect: CGRect)] {
        let s = try OffscreenRenderer.Session(panel: panel, size: size, scale: 2, theme: Theme(), settings: settings)
        try s.feed(frames)
        _ = try s.snapshotPNG()
        return s.renderer.textLayer.lastLabels
    }

    private func assertNoCollisions(_ labels: [(text: String, rect: CGRect)], _ size: CGSize, _ name: String) {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
        for (i, a) in labels.enumerated() {
            XCTAssertTrue(bounds.contains(a.rect), "\(name) \(Int(size.width))x\(Int(size.height)): \"\(a.text)\" \(a.rect) leaves the panel")
            for b in labels[(i + 1)...] where a.rect.intersects(b.rect) {
                XCTFail("\(name) \(Int(size.width))x\(Int(size.height)): \"\(a.text)\" \(a.rect) on \"\(b.text)\" \(b.rect)")
            }
        }
    }

    // MARK: Synthetic reading

    func testDemoSPLIsPlausible() {
        let frames = Self.splFrames(600)
        let first = frames[120].spl!, last = frames[599].spl!
        XCTAssertEqual(last.calibrationName, "WA33 at 10 o'clock")
        XCTAssertEqual(last.uncertaintyDB, 2)
        for f in frames.suffix(300) {
            let s = f.spl!
            XCTAssertTrue((74 ... 86).contains(s.levelAFast), "\(s.levelAFast)")
            XCTAssertTrue((76 ... 84).contains(s.levelASlow), "\(s.levelASlow)")
            XCTAssertEqual(s.levelAFast, f.loudness.momentaryLUFS + 93, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(s.maxAFast, s.levelAFast)
        }
        XCTAssertGreaterThan(last.doseNIOSH, first.doseNIOSH)
        XCTAssertLessThan(last.doseNIOSH - first.doseNIOSH, 0.001, "the dose rises slowly")
        XCTAssertGreaterThan(last.doseWHOWeekly, first.doseWHOWeekly)
        XCTAssertEqual(last.bandLevelsEardrum.count, 31)
        XCTAssertEqual(frames[599].thirdOctave?.left.count, 31)
        XCTAssertTrue(last.secondsToNIOSHLimit.isFinite && last.secondsToNIOSHLimit > 3600)
        XCTAssertNil(SyntheticFrames.sequence(count: 2)[1].spl, "off by default")
        let silent = SyntheticFrames.addingDemoSPL(to: SyntheticFrames.silence(count: 5))
        XCTAssertEqual(silent[4].spl?.levelAFast, SPLReading.floorDB)
    }

    // MARK: Text

    func testTimeLeftFormat() {
        XCTAssertEqual(EarShown.timeText(EarShown.steppedMinutes(.infinity)), "\u{221E}")
        XCTAssertEqual(EarShown.timeText(-2), Fmt.dash)
        XCTAssertEqual(EarShown.timeText(EarShown.steppedMinutes(7 * 3600 + 42 * 60)), "7:30")
        XCTAssertEqual(EarShown.timeText(EarShown.steppedMinutes(62 * 60)), "1:00")
        XCTAssertEqual(EarShown.timeText(EarShown.steppedMinutes(9 * 60)), "0:05")
        XCTAssertEqual(EarShown.timeText(EarShown.steppedMinutes(23.4 * 3600)), "23:00")
        XCTAssertEqual(EarShown.timeText(EarShown.steppedMinutes(0)), "0:00")
        var s = Self.splFrames(60)[59].spl!
        XCTAssertEqual(EarShown(s, silent: true).leftNIOSH, -2, "a dash while silent")
        s.levelASlow = 60
        XCTAssertEqual(EarShown(s, silent: false).leftWHO, -1, "more than a week left reads as no limit")
    }

    // MARK: One source for the "±" text and for the dose

    /// The meters block and the header print a total with ONE function (the app's `SPLController.uncertaintyText`
    /// is `EarUncertaintyText.total`), so the same total reads the same on both: 3.6 dB is "± 4 dB" on both, never
    /// "± 3.6 dB" on one of them.
    func testMetersAndHeaderFormatTheSameTotalIdentically() {
        var s = Self.splFrames(60)[59].spl!
        let totals: [(Double, String)] = [(2, "\u{00B1} 2 dB"), (13.0.squareRoot(), "\u{00B1} 4 dB"), (8.0.squareRoot(), "\u{00B1} 3 dB"), (2.5, "\u{00B1} 3 dB"),
                                          (3.5, "\u{00B1} 4 dB"), (45.0.squareRoot(), "\u{00B1} 7 dB"), (3.45, "\u{00B1} 3 dB"), (0, "\u{00B1} 0 dB")]
        for (total, text) in totals {
            s.uncertaintyDB = Float(total)
            let header = EarUncertaintyText.total(total)
            XCTAssertEqual(header, text)
            XCTAssertEqual(EarShown(s, silent: false).uncertaintyText, header, "meters and header, total \(total)")
            XCTAssertFalse(EarShown(s, silent: false).uncertaintyText.contains("."), "whole dB: no total is known to a tenth")
        }
        XCTAssertEqual(EarUncertaintyText.total(13.0.squareRoot(), unit: false), "\u{00B1} 4")
        // A term keeps the half step the measurement window printed ("± 3.5 dB (rig-limited)"); fixed terms are whole.
        XCTAssertEqual(EarUncertaintyText.term(3.5), "\u{00B1} 3.5 dB")
        XCTAssertEqual(EarUncertaintyText.term(2), "\u{00B1} 2 dB")
        XCTAssertEqual(EarUncertaintyText.term(1.5, unit: false), "\u{00B1} 1.5")
        XCTAssertEqual(EarUncertaintyText.term(.nan), "\u{00B1} 0 dB")
    }

    /// With the app's ledger the block shows the header's figure: today's stored dose, not the running dose of the estimator.
    func testTheLedgerIsTheDoseOfTheBlock() {
        var s = Self.splFrames(60)[59].spl!
        s.doseNIOSH = 0.02; s.doseWHOWeekly = 0.01          // a new estimator after a launch: near zero
        s.levelASlow = 88; s.secondsToNIOSHLimit = (1 - 0.02) * 4 * 3600
        let session = EarShown(s, silent: false)
        XCTAssertEqual(session.doseNIOSH, 2)
        let ledger = EarDoseLedger(nioshToday: 0.52, whoWeek: 0.314)
        let day = EarShown(s, silent: false, ledger: ledger)
        XCTAssertEqual(day.doseNIOSH, 52, "the header ring prints Int((nioshToday * 100).rounded())")
        XCTAssertEqual(day.doseWHO, 31)
        // 88 dB(A) allows 4 h; 48 % of today is left: 1 h 55 min, in steps of 5 min.
        XCTAssertEqual(day.leftNIOSH, EarShown.steppedMinutes(0.48 * 4 * 3600))
        XCTAssertLessThan(day.leftNIOSH, session.leftNIOSH)
        XCTAssertEqual(day.slow, session.slow, "the ledger changes the dose, nothing else")
        XCTAssertEqual(day.uncertaintyText, session.uncertaintyText)
        // Under the NIOSH threshold the estimator says "no limit": the ledger does not turn that into a time.
        s.secondsToNIOSHLimit = .infinity
        XCTAssertEqual(EarShown(s, silent: false, ledger: ledger).leftNIOSH, -1)
        // A used-up day: no time left, at any level.
        s.secondsToNIOSHLimit = 3600
        XCTAssertEqual(EarShown(s, silent: false, ledger: EarDoseLedger(nioshToday: 1.2, whoWeek: 0.2)).leftNIOSH, 0)
    }

    func testTheLedgerReachesTheRenderedBlock() throws {
        try RenderTestSupport.requireMetal()
        let frames = Self.splFrames()
        for standard in [DoseStandard.nioshDaily, .whoWeekly] {
            var settings = OffscreenRenderer.Settings(); settings.doseStandard = standard
            let s = try OffscreenRenderer.Session(panel: .meters, size: SPLReviewTests.sizes[0], scale: 2, theme: Theme(), settings: settings)
            let r = s.renderer as! MetersRenderer
            try s.feed(frames)
            r.doseLedger = EarDoseLedger(nioshToday: 0.52, whoWeek: 0.77)
            XCTAssertEqual(r.earShown?.doseNIOSH, 52, "a new percent shows at once, not at the next 4 Hz latch")
            _ = try s.snapshotPNG()
            let texts = s.renderer.textLayer.lastLabels.map(\.text)
            XCTAssertTrue(texts.contains(standard == .nioshDaily ? "52 %" : "77 %"), "\(texts)")
            XCTAssertTrue(texts.contains(standard == .nioshDaily ? "DOSE \u{00B7} NIOSH DAY" : "DOSE \u{00B7} WHO WEEK"))
            XCTAssertTrue(r.earAccessibilityText(frames[frames.count - 1].spl!, silent: false).contains(standard == .nioshDaily ? "dose 52 percent" : "dose 77 percent"))
        }
    }

    func testBlockIsAbsentWithoutSPL() throws {
        try RenderTestSupport.requireMetal()
        for size in SPLReviewTests.sizes {
            let s = try OffscreenRenderer.Session(panel: .meters, size: size, scale: 2, theme: Theme(), settings: .init())
            try s.feed(SyntheticFrames.sequence(count: 60))
            _ = try s.snapshotPNG()
            let r = s.renderer as! MetersRenderer
            XCTAssertEqual(r.earMode, .none)
            XCTAssertEqual(r.ear, .zero)
            XCTAssertEqual(r.compact, size.width < 760, "the wide layout starts where it did")
            let texts = s.renderer.textLayer.lastLabels.map(\.text)
            XCTAssertFalse(texts.contains { $0.contains("EAR") || $0.contains("\u{2248}") || $0.contains("DOSE") }, "\(texts)")
        }
    }

    func testEveryNumberIsMarkedAsEstimate() throws {
        try RenderTestSupport.requireMetal()
        let frames = Self.splFrames()
        let expected: [(CGSize, MetersRenderer.EarMode)] = [(SPLReviewTests.sizes[0], .column), (SPLReviewTests.sizes[1], .strip),
                                                           (SPLReviewTests.sizes[2], .strip), (SPLReviewTests.sizes[3], .row)]
        for (size, mode) in expected {
            let s = try OffscreenRenderer.Session(panel: .meters, size: size, scale: 2, theme: Theme(), settings: .init())
            try s.feed(frames)
            _ = try s.snapshotPNG()
            XCTAssertEqual((s.renderer as! MetersRenderer).earMode, mode)
            let texts = s.renderer.textLayer.lastLabels.map(\.text)
            XCTAssertTrue(texts.contains("\u{2248}"), "\(size): the numeral carries the sign of an estimate")
            XCTAssertTrue(texts.contains { $0.hasSuffix(" %") }, "\(size): dose percent")
            if mode == .row {
                // The smallest size: the numeral and the dose percent, nothing else of the block.
                XCTAssertFalse(texts.contains { $0.contains("LEQ") || $0.contains("left") || $0.contains("WA33") }, "\(texts)")
            } else {
                XCTAssertTrue(texts.contains { $0.contains("estimate") }, "\(size): \(texts)")
                XCTAssertTrue(texts.contains { $0.contains("WA33 at 10 o'clock") && $0.contains("\u{00B1} 2 dB") }, "\(size): provenance, \(texts)")
            }
            if mode == .column {
                XCTAssertTrue(texts.contains("85 dB(A) \u{00B7} 8 h"))
                for t in ["LEQ TRACK", "LEQ SESSION", "MAX FAST", "TIME LEFT", "DOSE \u{00B7} NIOSH DAY"] { XCTAssertTrue(texts.contains(t), t) }
            }
        }
    }

    func testDoseStandardSelectsTheDose() throws {
        try RenderTestSupport.requireMetal()
        let frames = Self.splFrames()
        let spl = frames[frames.count - 1].spl!
        var who = OffscreenRenderer.Settings(); who.doseStandard = .whoWeekly
        let a = try labels(.meters, frames, SPLReviewTests.sizes[0]).map(\.text)
        let b = try labels(.meters, frames, SPLReviewTests.sizes[0], who).map(\.text)
        XCTAssertTrue(a.contains("\(Int((spl.doseNIOSH * 100).rounded())) %"), "\(a)")
        XCTAssertTrue(b.contains("\(Int((spl.doseWHOWeekly * 100).rounded())) %"), "\(b)")
        XCTAssertTrue(b.contains("DOSE \u{00B7} WHO WEEK"))
    }

    func testNoTextCollisionWithSPL() throws {
        try RenderTestSupport.requireMetal()
        var target = OffscreenRenderer.Settings(); target.targetLUFS = -14
        var who = target; who.doseStandard = .whoWeekly
        var spl = OffscreenRenderer.Settings(); spl.levelAxis = .dBSPL
        let frames = Self.splFrames(), hot = Self.splFrames(hot: true), hp = Self.splFrames(headphone: true)
        let real = SyntheticFrames.addingDemoSPL(to: Array(RealFrames.demo(seconds: 4).suffix(120)))
        let silent = SyntheticFrames.addingDemoSPL(to: SyntheticFrames.silence(count: 10))
        var long = frames
        for i in long.indices { long[i].spl?.calibrationName = "Woo Audio WA33 Elite, volume knob at 10 o'clock, high gain"; long[i].spl?.doseNIOSH = 12.5; long[i].spl?.levelASlow = 104 }
        for size in LabelLayoutTests.sizes + [CGSize(width: 820, height: 400), CGSize(width: 760, height: 300), CGSize(width: 560, height: 220)] {
            assertNoCollisions(try labels(.meters, frames, size, target), size, "meters spl")
            assertNoCollisions(try labels(.meters, hot, size, who), size, "meters spl hot who")
            assertNoCollisions(try labels(.meters, real, size, target), size, "meters spl real")
            assertNoCollisions(try labels(.meters, silent, size, target), size, "meters spl silent")
            assertNoCollisions(try labels(.meters, long, size, target), size, "meters spl long name")
            assertNoCollisions(try labels(.spectrum, frames, size, spl), size, "spectrum spl")
            assertNoCollisions(try labels(.spectrum, hp, size, spl), size, "spectrum spl headphone")
            assertNoCollisions(try labels(.spectrum, real, size, spl), size, "spectrum spl real")
            assertNoCollisions(try labels(.spectrum, SyntheticFrames.sequence(count: 120), size, spl), size, "spectrum not calibrated")
        }
    }

    // MARK: Accessibility and repaint rate

    func testAccessibilityValueNamesTheEarLevel() throws {
        try RenderTestSupport.requireMetal()
        let frames = Self.splFrames()
        let s = try OffscreenRenderer.Session(panel: .meters, size: SPLReviewTests.sizes[0], scale: 2, theme: Theme(), settings: .init())
        try s.feed(frames)
        let spl = frames[frames.count - 1].spl!
        let want = "about \(Int(spl.levelASlow.rounded())) dB A at the ear, dose \(Int((spl.doseNIOSH * 100).rounded())) percent"
        XCTAssertTrue(s.renderer.accessibilityValueText.hasSuffix(want), s.renderer.accessibilityValueText)
        let plain = try OffscreenRenderer.Session(panel: .meters, size: SPLReviewTests.sizes[0], scale: 2, theme: Theme(), settings: .init())
        try plain.feed(SyntheticFrames.sequence(count: 30))
        XCTAssertFalse(plain.renderer.accessibilityValueText.contains("ear"))
    }

    func testEarNumbersChangeAtMostFourTimesPerSecond() throws {
        try RenderTestSupport.requireMetal()
        var frames = Self.splFrames(360)
        // A level that moves 3 dB with every frame: the worst case for the text.
        for i in frames.indices { frames[i].spl?.levelASlow = 78 + Float(i % 2) * 3; frames[i].spl?.levelAFast = 80 - Float(i % 2) * 3 }
        let s = try OffscreenRenderer.Session(panel: .meters, size: SPLReviewTests.sizes[0], scale: 2, theme: Theme(), settings: .init())
        let r = s.renderer as! MetersRenderer
        var changes = 0
        var last: EarShown?
        for f in frames { r.ingest(f); if r.earShown != last { changes += 1; last = r.earShown } }
        XCTAssertLessThanOrEqual(changes, 6 * 4 + 1, "6 s of frames")
        XCTAssertGreaterThan(changes, 4)
    }

    // MARK: Spectrum

    func testSpectrumSPLAxis() throws {
        try RenderTestSupport.requireMetal()
        let frames = Self.splFrames()
        var spl = OffscreenRenderer.Settings(); spl.levelAxis = .dBSPL
        let size = SPLReviewTests.sizes[0]

        let on = try OffscreenRenderer.Session(panel: .spectrum, size: size, scale: 2, theme: Theme(), settings: spl)
        try on.feed(frames)
        let withBands = try RenderTestSupport.decode(png: on.snapshotPNG())
        let r = on.renderer as! SpectrumRenderer
        XCTAssertTrue(r.splShown)
        // The axis offset is what the reading says: eardrum band level minus dBFS RMS band level (median), minus 3.01 dB.
        let f = frames[frames.count - 1]
        let diffs = (0..<31).map { f.spl!.bandLevelsEardrum[$0] - max(f.thirdOctave!.left[$0], f.thirdOctave!.right[$0]) }.sorted()
        XCTAssertEqual(r.splOffset, (diffs[15] - 3.01).rounded(), accuracy: 1.01)
        let texts = on.renderer.textLayer.lastLabels.map(\.text)
        XCTAssertTrue(texts.contains("dB SPL at eardrum \u{00B7} 1/3 oct \u{00B7} \u{2248}"), "\(texts)")
        XCTAssertTrue(texts.contains("dB SPL") && texts.contains("dBFS"))

        // Default axis: the same frames draw the picture of today.
        let off = try OffscreenRenderer.Session(panel: .spectrum, size: size, scale: 2, theme: Theme(), settings: .init())
        try off.feed(frames)
        let without = try RenderTestSupport.decode(png: off.snapshotPNG())
        XCTAssertFalse((off.renderer as! SpectrumRenderer).splShown)
        XCTAssertFalse(off.renderer.textLayer.lastLabels.contains { $0.text.contains("SPL") })
        let plain = try OffscreenRenderer.Session(panel: .spectrum, size: size, scale: 2, theme: Theme(), settings: .init())
        var stripped = frames
        for i in stripped.indices { stripped[i].spl = nil; stripped[i].thirdOctave = nil }
        try plain.feed(stripped)
        XCTAssertEqual(try RenderTestSupport.decode(png: plain.snapshotPNG()).data, without.data, "dBFS axis: an SPL reading changes nothing")

        // The band layer is in the picture: over the curves' region of the bass, pixels differ.
        var differing = 0
        for y in stride(from: 200, to: 1000, by: 8) { for x in stride(from: 120, to: 2200, by: 8) where withBands.rgb(x, y) != without.rgb(x, y) { differing += 1 } }
        XCTAssertGreaterThan(differing, 500)

        // No calibration: a note, and nothing else.
        let none = try OffscreenRenderer.Session(panel: .spectrum, size: size, scale: 2, theme: Theme(), settings: spl)
        try none.feed(stripped)
        _ = try none.snapshotPNG()
        XCTAssertFalse((none.renderer as! SpectrumRenderer).splShown)
        XCTAssertEqual((none.renderer as! SpectrumRenderer).plotRectForTesting, (plain.renderer as! SpectrumRenderer).plotRectForTesting)
        XCTAssertTrue(none.renderer.textLayer.lastLabels.contains { $0.text.contains("not calibrated") })
    }
}
