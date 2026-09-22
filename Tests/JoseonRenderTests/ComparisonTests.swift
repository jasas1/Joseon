import XCTest
import JoseonCore
@testable import JoseonRender

/// A/B compare: the math first (the numbers a listener will trust), then what the panels make of it.
final class ComparisonMathTests: XCTestCase {
    static func bins(_ n: Int, minHz: Float = 10, maxHz: Float = 24_000) -> [Float] { SpectrumReading.silent(binCount: n, minHz: minHz, maxHz: maxHz).frequencies }

    /// A music-like long-term curve: a bass hump, then about -4.5 dB per octave, with a ripple. No tilt.
    static func music(_ f: [Float]) -> [Float] {
        f.map { hz in
            let o = log2(hz / 1000)
            return -52 - 4.5 * o - 14 * exp(-0.5 * pow((log2(hz) - log2(28)) / 0.5, 2)) + 1.5 * sin(o * 3.1)
        }
    }

    static func snapshot(_ f: [Float], _ average: [Float], tilt: Float = 0, name: String = "A \u{00B7} 21:42 \u{00B7} Qobuz",
                         loudness: LoudnessReading = LoudnessReading(), headphone: String? = nil, response: [Float]? = nil) -> ComparisonSnapshot {
        var s = ComparisonSnapshot(name: name, date: Date(timeIntervalSince1970: 0), measuredSeconds: 60, frequencies: f, averageDB: average, peakHoldDB: average,
                                   bands: BandEnergy(), loudness: loudness, correlation: 0.8, width: 0.4, balance: 0, headphoneName: headphone,
                                   responseDB: response, targetDB: nil, leqA: nil, lowestStrongHz: 32)
        s.tiltDBPerOctave = tilt
        return s
    }

    private func curves(_ a: ComparisonSnapshot, live f: [Float], _ b: [Float], tilt: Float = 0, match: Bool, floor: Float = SpectrumReading.floorDB) -> ComparisonCurves {
        let c = ComparisonCurves()
        c.setReference(a, liveFrequencies: f)
        c.update(liveAverage: b, liveTilt: tilt, levelMatch: match, displayFloorDB: floor)
        return c
    }

    /// B = A + 3 dB everywhere: level match on gives a flat lane at 0 and "B is +3.0 dB louder"; off gives a flat +3.0.
    func testThreeDBLouderEverywhere() throws {
        let f = Self.bins(1024), a = Self.music(f), b = a.map { $0 + 3 }
        let on = curves(Self.snapshot(f, a), live: f, b, match: true)
        let offset = try XCTUnwrap(on.levelOffsetDB)
        XCTAssertEqual(offset, 3, accuracy: 0.001)
        XCTAssertEqual(ComparisonText.louder(offset), "B is +3.0 dB louder")
        XCTAssertEqual(on.difference.count, 1024)
        for d in on.difference { XCTAssertEqual(d, 0, accuracy: 0.002) }
        for d in on.bandDeltas { XCTAssertEqual(try XCTUnwrap(d), 0, accuracy: 0.002) }

        let off = curves(Self.snapshot(f, a), live: f, b, match: false)
        XCTAssertEqual(try XCTUnwrap(off.levelOffsetDB), 3, accuracy: 0.001, "the offset is printed with level match off too")
        for d in off.difference { XCTAssertEqual(d, 3, accuracy: 0.002) }
        for d in off.bandDeltas { XCTAssertEqual(try XCTUnwrap(d), 3, accuracy: 0.002) }
    }

    func testLouderWords() {
        XCTAssertEqual(ComparisonText.louder(-2.26), "B is 2.3 dB quieter")
        XCTAssertEqual(ComparisonText.louder(0.04), "same level")
        XCTAssertEqual(ComparisonText.louderShort(-1), "B \u{2212}1.0 dB", "a real minus sign")
        XCTAssertEqual(ComparisonText.referenceLegends("A \u{00B7} 21:42 \u{00B7} Qobuz"), ["A \u{00B7} 21:42 \u{00B7} Qobuz", "A \u{00B7} 21:42", "A"])
        XCTAssertEqual(ComparisonText.referenceLegends("Master 2019"), ["A \u{00B7} Master 2019", "A"], "a name without the letter gets it once")
    }

    /// +4 dB above 5 kHz. The level match is a power mean over 100 Hz ... 10 kHz, so a change that is not broadband moves
    /// it a little. On a FLAT spectrum the octave 5 ... 10 kHz is 15 % of the bins: the offset is 10 log10(0.85 + 0.15 * 10^0.4)
    /// = 0.89 dB, the lane shows +3.11 dB there and -0.89 dB below. On music (the power sits low) the same change moves the
    /// offset by under 0.1 dB and the lane reads +4 and about 0.
    func testShelfAboveFiveKilohertzAndTheBiasOfTheLevelMatch() throws {
        let f = Self.bins(1024)
        func shelf(_ v: [Float]) -> [Float] { zip(v, f).map { $1 >= 5_000 ? $0 + 4 : $0 } }
        func at(_ c: ComparisonCurves, _ hz: Float) throws -> Float { try XCTUnwrap(c.value(of: c.difference, atHz: hz)) }

        let flat = [Float](repeating: -40, count: f.count)
        let inRange = f.filter { $0 >= 100 && $0 <= 10_000 }
        let raised = inRange.filter { $0 >= 5_000 }.count
        let expected = 10 * log10((Float(inRange.count - raised) + Float(raised) * pow(10, 0.4)) / Float(inRange.count))
        XCTAssertEqual(expected, 0.89, accuracy: 0.02, "the bias on a flat spectrum, as documented")
        let c = curves(Self.snapshot(f, flat), live: f, shelf(flat), match: true)
        XCTAssertEqual(try XCTUnwrap(c.levelOffsetDB), expected, accuracy: 0.005)
        XCTAssertEqual(try at(c, 8_000), 4 - expected, accuracy: 0.01)
        XCTAssertEqual(try at(c, 1_000), -expected, accuracy: 0.01)
        XCTAssertEqual(try at(c, 15_000), 4 - expected, accuracy: 0.01, "outside the match range the shelf is still +4 before the offset")

        let music = Self.music(f)
        let m = curves(Self.snapshot(f, music), live: f, shelf(music), match: true)
        let bias = try XCTUnwrap(m.levelOffsetDB)
        XCTAssertGreaterThan(bias, 0)
        XCTAssertLessThan(bias, 0.1, "on music the shelf hardly moves the power mean")
        XCTAssertEqual(try at(m, 8_000), 4 - bias, accuracy: 0.01)
        XCTAssertEqual(try at(m, 1_000), -bias, accuracy: 0.01)
        XCTAssertEqual(try at(m, 300), 0, accuracy: 0.1)

        let off = curves(Self.snapshot(f, music), live: f, shelf(music), match: false)
        XCTAssertEqual(try at(off, 8_000), 4, accuracy: 0.01)
        XCTAssertEqual(try at(off, 1_000), 0, accuracy: 0.01)
        // The edge is 1/6 octave wide (the smoothing), centered on 5 kHz.
        XCTAssertEqual(try at(off, 5_000), 2, accuracy: 0.35)
        XCTAssertEqual(try at(off, 5_000 * pow(2, 0.1)), 4, accuracy: 0.01)
        XCTAssertEqual(try at(off, 5_000 / pow(2, 0.1)), 0, accuracy: 0.01)
    }

    /// A captured under a 3 dB/oct display tilt, B live under 4.5 dB/oct, the same music: the difference is zero, the
    /// offset is zero, and A is drawn where B is (with the live tilt).
    func testTiltMismatchIsRemovedExactly() throws {
        let f = Self.bins(1024), base = Self.music(f)
        func tilted(_ t: Float) -> [Float] { zip(base, f).map { $0 + t * log2($1 / 1000) } }
        let b = tilted(4.5)
        let c = curves(Self.snapshot(f, tilted(3), tilt: 3), live: f, b, tilt: 4.5, match: true)
        XCTAssertEqual(try XCTUnwrap(c.levelOffsetDB), 0, accuracy: 0.001)
        for d in c.difference { XCTAssertEqual(d, 0, accuracy: 0.002) }
        for i in f.indices { XCTAssertEqual(c.referenceDrawn[i], b[i], accuracy: 0.002, "A is drawn with the live tilt") }
        // And the offset does not depend on the tilt the curves are shown with.
        let louder = curves(Self.snapshot(f, tilted(3).map { $0 - 2 }, tilt: 3), live: f, b, tilt: 4.5, match: true)
        let plain = curves(Self.snapshot(f, base.map { $0 - 2 }), live: f, base, match: true)
        XCTAssertEqual(try XCTUnwrap(louder.levelOffsetDB), try XCTUnwrap(plain.levelOffsetDB), accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(louder.levelOffsetDB), 2, accuracy: 0.002)
    }

    /// A on 512 bins, live on 1024: a narrow feature (a 6 dB bump, sigma 0.05 octave, about 1/8 octave wide at half height)
    /// keeps its shape within 0.3 dB.
    func testResamplingKeepsANarrowFeature() throws {
        func curve(_ f: [Float]) -> [Float] { zip(Self.music(f), f).map { $0 + 6 * exp(-0.5 * pow(log2($1 / 2_310) / 0.05, 2)) } }
        let coarse = Self.bins(512), fine = Self.bins(1024)
        let resampled = ComparisonCurves.resample(curve(coarse), from: coarse, onto: fine)
        let truth = curve(fine)
        var worst: Float = 0
        for i in fine.indices { worst = max(worst, abs(resampled[i] - truth[i])) }
        XCTAssertLessThan(worst, 0.3)
        let top = try XCTUnwrap(fine.firstIndex { $0 >= 2_310 })
        XCTAssertEqual(resampled[top], truth[top], accuracy: 0.3, "the top of the bump")
        // Through the whole comparison: the same music on both bin counts differs by nothing the lane would show.
        let c = curves(Self.snapshot(coarse, curve(coarse)), live: fine, truth, match: false)
        for d in c.difference { XCTAssertEqual(d, 0, accuracy: 0.3) }
        // The same bins: resampling changes nothing.
        let same = ComparisonCurves.resample(truth, from: fine, onto: fine)
        for i in fine.indices { XCTAssertEqual(same[i], truth[i], accuracy: 1e-4) }
    }

    /// Outside the overlap of the two frequency ranges there is nothing.
    func testNothingOutsideTheOverlap() throws {
        let live = Self.bins(1024), narrow = Self.bins(400, minHz: 40, maxHz: 12_000)
        let c = curves(Self.snapshot(narrow, Self.music(narrow)), live: live, Self.music(live), match: true)
        for (i, hz) in live.enumerated() {
            if hz < 40 * 0.999 || hz > 12_000 * 1.001 {
                XCTAssertTrue(c.difference[i].isNaN, "\(hz) Hz"); XCTAssertTrue(c.referenceDrawn[i].isNaN)
            } else if hz > 41, hz < 11_800 {
                XCTAssertEqual(c.difference[i], 0, accuracy: 0.05, "\(hz) Hz")
            }
        }
        let ov = try XCTUnwrap(c.overlap)
        XCTAssertGreaterThanOrEqual(live[ov.lowerBound], 40 * 0.999); XCTAssertLessThanOrEqual(live[ov.upperBound], 12_000 * 1.001)
    }

    /// Silence in a band of B (its long-term curve at the floor), or a curve within 6 dB of the display floor: a gap.
    func testFloorRegionsAreGaps() throws {
        let f = Self.bins(1024), a = Self.music(f)
        let silentBand = zip(a, f).map { $1 >= 2_000 && $1 <= 4_000 ? SpectrumReading.floorDB : $0 + 1 }
        let c = curves(Self.snapshot(f, a), live: f, silentBand, match: false)
        for (i, hz) in f.enumerated() {
            if hz >= 2_000, hz <= 4_000 { XCTAssertTrue(c.difference[i].isNaN, "\(hz) Hz") } else { XCTAssertEqual(c.difference[i], 1, accuracy: 0.01, "\(hz) Hz: the gap does not leak into its neighbours") }
        }
        XCTAssertNil(c.bandDeltas[4], "2-4 kHz has nothing to compare")
        XCTAssertEqual(try XCTUnwrap(c.bandDeltas[3]), 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(c.levelOffsetDB), 1, accuracy: 0.01, "the offset comes from the bins that can be compared")

        // Display floor -84, quieter music: the curve passes -78 (floor + 6) near 10 kHz. No lane value where A is under
        // that; the offset and the bands do not depend on the plot range.
        let q = a.map { $0 - 10 }
        let d = curves(Self.snapshot(f, q), live: f, q.map { $0 + 1 }, match: false, floor: -84)
        for (i, hz) in f.enumerated() where hz > 100 && abs(q[i] + 78) > 0.01 {
            if q[i] <= -78 { XCTAssertTrue(d.difference[i].isNaN, "\(hz) Hz") } else { XCTAssertEqual(d.difference[i], 1, accuracy: 0.01) }
        }
        XCTAssertTrue(d.difference.contains { $0.isNaN }); XCTAssertTrue(d.difference.contains { $0.isFinite })
        XCTAssertEqual(try XCTUnwrap(d.bandDeltas[7]), 1, accuracy: 0.01)
    }

    /// The smoothing is a mean in dB over 1/6 octave: a one-bin spike is spread over the window, a broad change stays.
    func testSmoothingIsOneSixthOctaveInDB() throws {
        let f = Self.bins(1024), a = Self.music(f)
        let k = try XCTUnwrap(f.firstIndex { $0 >= 1_000 })
        var b = a; b[k] += 12
        let c = curves(Self.snapshot(f, a), live: f, b, match: false)
        let half = pow(Float(2), 1.0 / 12)
        let window = f.filter { $0 >= f[k] / half && $0 <= f[k] * half }.count
        XCTAssertEqual(c.difference[k], 12 / Float(window), accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(window, 14); XCTAssertLessThanOrEqual(window, 16)
        XCTAssertEqual(c.difference[k + window], 0, accuracy: 0.001)
    }

    /// The headphone lane: response of B minus response of A, whatever the music does.
    func testHeadphoneDifference() throws {
        let f = Self.bins(1024), a = Self.music(f)
        let susvara = f.map { SyntheticFrames.DemoHeadphone.susvaraLike.responseDB(atHz: $0) }, hd800 = f.map { SyntheticFrames.DemoHeadphone.hd800sLike.responseDB(atHz: $0) }
        let c = ComparisonCurves()
        c.setReference(Self.snapshot(f, a, headphone: "Susvara-like", response: susvara), liveFrequencies: f)
        c.updateHeadphone(liveResponse: hd800)
        XCTAssertEqual(try XCTUnwrap(c.value(of: c.responseDifference, atHz: 1_000)), 0, accuracy: 0.05, "both are 0 dB at 1 kHz")
        XCTAssertLessThan(try XCTUnwrap(c.value(of: c.responseDifference, atHz: 25)), -3, "the dynamic headphone has less sub-bass")
        XCTAssertGreaterThan(try XCTUnwrap(c.value(of: c.responseDifference, atHz: 6_100)), 3, "and its 6 kHz peak")
        for hp in SyntheticFrames.DemoHeadphone.allCases { XCTAssertEqual(hp.responseDB(atHz: 1_000), 0, accuracy: 1e-4) }
        c.updateHeadphone(liveResponse: nil)
        XCTAssertTrue(c.responseDifference.isEmpty)
    }
}

/// What the panels draw and say with a comparison set.
final class ComparisonRenderTests: XCTestCase {
    static let sizes = [CGSize(width: 1200, height: 600), CGSize(width: 560, height: 360), CGSize(width: 460, height: 330)]

    private func session(_ panel: PanelKind, _ frames: [AnalysisFrame], _ settings: OffscreenRenderer.Settings, size: CGSize = CGSize(width: 1200, height: 600)) throws -> OffscreenRenderer.Session {
        let s = try OffscreenRenderer.Session(panel: panel, size: size, scale: 2, theme: Theme(), settings: settings)
        try s.feed(frames)
        _ = try s.snapshotPNG()
        return s
    }
    private func texts(_ s: OffscreenRenderer.Session) -> [String] { s.renderer.textLayer.lastLabels.map(\.text) }

    /// B is the frame itself, A is the frame's long-term curve 3 dB down: the panel draws a flat lane and says +3.0.
    func testFlatLaneAndTheRemovedOffsetInThePanel() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 8).suffix(60))
        let last = try XCTUnwrap(frames.last)
        var a = ComparisonSnapshot.capture(from: last, name: "A \u{00B7} 21:42 \u{00B7} Qobuz")
        a.averageDB = a.averageDB.map { $0 <= SpectrumReading.floorDB ? $0 : $0 - 3 }
        var settings = OffscreenRenderer.Settings(); settings.comparison = a
        let on = try session(.spectrum, frames, settings)
        let r = try XCTUnwrap(on.renderer as? SpectrumRenderer)
        XCTAssertEqual(r.laneStateForTesting, .signal)
        let lane = r.laneValuesForTesting.filter { $0.isFinite }
        XCTAssertGreaterThan(lane.count, r.pointCountForTesting / 2)
        for d in lane { XCTAssertEqual(d, 0, accuracy: 0.01) }
        XCTAssertTrue(texts(on).contains("level-matched, B is +3.0 dB louder"), "\(texts(on))")
        XCTAssertTrue(texts(on).contains("B \u{2212} A")); XCTAssertTrue(texts(on).contains("B \u{00B7} long-term")); XCTAssertTrue(texts(on).contains("A \u{00B7} 21:42 \u{00B7} Qobuz"))
        XCTAssertFalse(texts(on).contains(SpectrumRenderer.averageLegend), "Long-term is renamed while a reference is set")
        XCTAssertTrue(texts(on).contains("+6"), "a small difference is read on the \u{00B1}6 dB axis")

        settings.comparisonLevelMatch = false
        let off = try session(.spectrum, frames, settings)
        let r2 = try XCTUnwrap(off.renderer as? SpectrumRenderer)
        for d in r2.laneValuesForTesting where d.isFinite { XCTAssertEqual(d, 3, accuracy: 0.01) }
        XCTAssertTrue(texts(off).contains("not level-matched, B is +3.0 dB louder"), "\(texts(off))")

        // The reference trace stands 3 dB under B's long-term curve, on the plot's points.
        let trace = r2.referenceTraceForTesting, b = try XCTUnwrap(r2.curveForTesting("average"))
        var compared = 0
        for (i, v) in trace.enumerated() { if let v, b[i] > r2.musicRange.min + 4 { XCTAssertEqual(v, b[i] - 3, accuracy: 0.05); compared += 1 } }
        XCTAssertGreaterThan(compared, 100)
        XCTAssertTrue(on.renderer.accessibilityValueText.contains("B is +3.0 dB louder"))
    }

    /// A difference past ±5.5 dB puts the lane on its ±12 dB axis.
    func testLaneAxisFollowsTheSizeOfTheDifference() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 8).suffix(30))
        var a = ComparisonSnapshot.capture(from: try XCTUnwrap(frames.last), name: "A")
        a.averageDB = zip(a.averageDB, a.frequencies).map { $1 > 2_000 ? $0 - 8 : $0 }
        var settings = OffscreenRenderer.Settings(); settings.comparison = a; settings.comparisonLevelMatch = false
        let s = try session(.spectrum, frames, settings)
        XCTAssertEqual((s.renderer as? SpectrumRenderer)?.laneAxisDB, 12)
        XCTAssertTrue(texts(s).contains("+12")); XCTAssertTrue(texts(s).contains("\u{2212}12"))
    }

    /// B younger than 5 s: no curve, `measuring B…`, dashes in the cursor readout; the reference trace is there.
    func testMeasuringB() throws {
        try RenderTestSupport.requireMetal()
        let old = RealFrames.demo(seconds: 8), young = RealFrames.demo(seconds: 3)
        XCTAssertLessThan(try XCTUnwrap(young.last).loudness.measuredSeconds, 5)
        var settings = OffscreenRenderer.Settings()
        settings.comparison = SyntheticFrames.demoComparison(from: try XCTUnwrap(old.last))
        settings.cursor = PanelCursor(frequencyHz: 1_000, source: .meters)
        for panel in [PanelKind.spectrum, .meters] {
            let s = try session(panel, young, settings)
            XCTAssertTrue(texts(s).contains { $0.hasPrefix(ComparisonText.measuring) }, "\(panel): \(texts(s))")
        }
        let s = try session(.spectrum, young, settings)
        let r = try XCTUnwrap(s.renderer as? SpectrumRenderer)
        XCTAssertEqual(r.laneStateForTesting, .measuring)
        XCTAssertTrue(r.laneValuesForTesting.isEmpty)
        XCTAssertFalse(r.referenceTraceForTesting.compactMap { $0 }.isEmpty)
        XCTAssertTrue(r.cursorItems().contains { $0.text == "B\u{2212}A \u{2014}" }, "\(r.cursorItems().map(\.text))")
        XCTAssertFalse(texts(s).contains { $0.contains("louder") }, "no offset is printed before B is measured")
    }

    /// The cursor readout: `A −47.0 dB · B−A +2.1 dB`, the numbers of the trace and of the lane.
    func testCursorReadoutAddsReferenceAndDifference() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 8).suffix(30))
        let last = try XCTUnwrap(frames.last)
        var settings = OffscreenRenderer.Settings()
        settings.comparison = SyntheticFrames.demoComparison(from: last)
        settings.cursor = PanelCursor(frequencyHz: 12_000, source: .spectrogram, isPinned: true)
        let s = try session(.spectrum, frames, settings)
        let r = try XCTUnwrap(s.renderer as? SpectrumRenderer)
        let v = try XCTUnwrap(r.cursorValues())
        let a = try XCTUnwrap(v.reference), d = try XCTUnwrap(v.delta)
        XCTAssertEqual(d, try XCTUnwrap(r.laneValue(atHz: 12_000)))
        XCTAssertGreaterThan(d, 1, "the demo reference has less air than B")
        let items = r.cursorItems().map(\.text)
        XCTAssertTrue(items.contains("A \(Fmt.db(a)) dB"), "\(items)")
        XCTAssertTrue(items.contains("B\u{2212}A \(Fmt.number(d, signed: true)) dB"), "\(items)")
        XCTAssertTrue(texts(s).contains("B\u{2212}A \(Fmt.number(d, signed: true)) dB"), "the header row shows it: \(texts(s))")
        XCTAssertTrue(r.cursorAccessibilityText.contains("B\u{2212}A"))
        // The lane's point at the hairline is the lane's value on the plot points.
        let lane = r.laneValuesForTesting
        let x = try XCTUnwrap(r.cursorXForTesting), plot = r.plotRectForTesting
        let j = Int(((x - plot.minX) / plot.width * CGFloat(r.pointCountForTesting - 1)).rounded())
        XCTAssertEqual(lane[j], d, accuracy: 0.1)
        // The pointer can ask from inside the lane too.
        let body = r.laneBodyForTesting
        XCTAssertEqual(try XCTUnwrap(r.cursor(at: CGPoint(x: x, y: body.midY))).frequencyHz, 12_000, accuracy: 60)
        XCTAssertNil(r.cursor(at: CGPoint(x: x, y: (r.laneRectForTesting.minY + body.minY) / 2)), "the label strip is not a plot")
    }

    /// The demo reference: 2 dB quieter, less air, more sub-bass.
    func testDemoComparisonIsBelievable() throws {
        let frames = RealFrames.demo(seconds: 8)
        let last = try XCTUnwrap(frames.last)
        let a = SyntheticFrames.demoComparison(from: last)
        XCTAssertEqual(a.frequencies, last.spectrum.frequencies)
        XCTAssertEqual(a.loudness.integratedLUFS, last.loudness.integratedLUFS - 2, accuracy: 0.001)
        let c = ComparisonCurves()
        c.setReference(a, liveFrequencies: last.spectrum.frequencies)
        c.update(liveAverage: last.spectrum.average, liveTilt: 0, levelMatch: true, displayFloorDB: SpectrumReading.floorDB)
        XCTAssertEqual(try XCTUnwrap(c.levelOffsetDB), 2, accuracy: 0.6)
        XCTAssertGreaterThan(try XCTUnwrap(c.value(of: c.difference, atHz: 14_000)), 1.5)
        XCTAssertLessThan(try XCTUnwrap(c.value(of: c.difference, atHz: 30)), -1)
        let bright = SyntheticFrames.demoComparison(from: last, brighter: true, louderDB: 1, headphone: .susvaraLike)
        XCTAssertEqual(bright.headphoneName, "Susvara-like"); XCTAssertEqual(bright.responseDB?.count, a.frequencies.count)
        c.setReference(bright, liveFrequencies: last.spectrum.frequencies)
        c.update(liveAverage: last.spectrum.average, liveTilt: 0, levelMatch: true, displayFloorDB: SpectrumReading.floorDB)
        XCTAssertLessThan(try XCTUnwrap(c.value(of: c.difference, atHz: 14_000)), -1.5)
    }

    /// Headphone compare: the second response trace with both names, and the lane in headphone mode. The same headphone
    /// on both sides, or none in A: the lane says why it is empty.
    func testHeadphoneMode() throws {
        try RenderTestSupport.requireMetal()
        let frames = ComparisonReviewTests.live(seconds: 8, headphone: .hd800sLike)
        let last = try XCTUnwrap(frames.last)
        var settings = OffscreenRenderer.Settings()
        settings.comparison = SyntheticFrames.demoComparison(from: last, headphone: .susvaraLike)
        let signal = try session(.spectrum, frames, settings)
        XCTAssertTrue(texts(signal).contains("B \u{00B7} HD 800 S-like")); XCTAssertTrue(texts(signal).contains("A \u{00B7} Susvara-like"))
        XCTAssertNotNil((signal.renderer as? SpectrumRenderer)?.curveForTesting("referenceResponse"))

        settings.comparisonMode = .headphone
        let hp = try session(.spectrum, frames, settings)
        let r = try XCTUnwrap(hp.renderer as? SpectrumRenderer)
        XCTAssertEqual(r.laneStateForTesting, .headphone)
        XCTAssertTrue(texts(hp).contains("headphone response: HD 800 S-like \u{2212} Susvara-like"), "\(texts(hp))")
        let want = SyntheticFrames.DemoHeadphone.hd800sLike.responseDB(atHz: 6_100) - SyntheticFrames.DemoHeadphone.susvaraLike.responseDB(atHz: 6_100)
        XCTAssertEqual(try XCTUnwrap(r.laneValue(atHz: 6_100)), want, accuracy: 0.8, "1/6 octave of smoothing takes a little off a narrow peak")
        XCTAssertEqual(try XCTUnwrap(r.laneValue(atHz: 200)), SyntheticFrames.DemoHeadphone.hd800sLike.responseDB(atHz: 200) - SyntheticFrames.DemoHeadphone.susvaraLike.responseDB(atHz: 200), accuracy: 0.05)

        settings.comparison = SyntheticFrames.demoComparison(from: last, headphone: .hd800sLike)
        let same = try session(.spectrum, frames, settings)
        XCTAssertEqual((same.renderer as? SpectrumRenderer)?.laneStateForTesting, .unavailable("same headphone in A and B"))
        XCTAssertTrue(texts(same).contains("same headphone in A and B"))
        XCTAssertFalse(texts(same).contains("A \u{00B7} HD 800 S-like"), "one headphone: one response trace")
        let plain = RealFrames.demo(seconds: 8)
        settings.comparison = SyntheticFrames.demoComparison(from: try XCTUnwrap(plain.last))
        let none = try session(.spectrum, Array(plain.suffix(30)), settings)
        XCTAssertTrue(texts(none).contains("no headphone in A"))
    }

    /// Space rules: the music scale keeps 45 % of the plot height or more; the lane's curve area is 56 pt or more; under 360 pt the lane wins over the headphone
    /// band and the header says so; under 240 pt there is no lane.
    func testSpaceRules() throws {
        try RenderTestSupport.requireMetal()
        let frames = ComparisonReviewTests.live(seconds: 8, headphone: .hd800sLike)
        var settings = OffscreenRenderer.Settings()
        settings.comparison = SyntheticFrames.demoComparison(from: try XCTUnwrap(frames.last), headphone: .susvaraLike)
        for size in LabelLayoutTests.sizes + [CGSize(width: 560, height: 359), CGSize(width: 900, height: 361), CGSize(width: 420, height: 400)] {
            let s = try session(.spectrum, Array(frames.suffix(30)), settings, size: size)
            let r = try XCTUnwrap(s.renderer as? SpectrumRenderer)
            let name = "\(Int(size.width))x\(Int(size.height))"
            if size.height < 240 {
                XCTAssertEqual(r.laneRectForTesting, .zero, name)
                XCTAssertTrue(texts(s).contains { SpectrumRenderer.laneHiddenNotes.contains($0) }, "\(name): \(texts(s))")
                XCTAssertNil(r.headphoneBandForTesting, "\(name): a compact card has no room for the band's legend row and axis (critic r6, D10)")
                XCTAssertFalse(r.referenceTraceForTesting.isEmpty, "\(name): the trace stays")
                continue
            }
            let lane = r.laneRectForTesting, plot = r.plotRectForTesting
            // 22 % of the plot, or what a 56 pt curve area under its strip needs (critic r6, D8).
            let strip = r.laneBodyForTesting.minY - lane.minY
            XCTAssertEqual(lane.height, max(((plot.height + lane.height) * 0.22).rounded(), 56 + strip), accuracy: 0.01, name)
            XCTAssertEqual(lane.minY, plot.maxY, accuracy: 0.01, name)
            XCTAssertGreaterThanOrEqual(r.musicFractionForTesting, 0.45, name)
            // Signal mode: the band needs 420 pt of plot beside the lane (critic r6), and a panel wide enough for its legend row.
            if size.height < 470 || size.width < 460 {
                XCTAssertNil(r.headphoneBandForTesting, name)
                XCTAssertTrue(r.headphoneBandHiddenForTesting, name)
                XCTAssertTrue(texts(s).contains { ComparisonText.bandHidden.contains($0) }, "\(name): \(texts(s))")
                XCTAssertTrue(s.renderer.accessibilityValueText.contains("Headphone band hidden"))
            } else {
                XCTAssertNotNil(r.headphoneBandForTesting, name)
                XCTAssertFalse(texts(s).contains { ComparisonText.bandHidden.contains($0) }, name)
            }
            // A and B are named at every size that has a lane.
            XCTAssertTrue(texts(s).contains { $0 == "A" || $0.hasPrefix("A \u{00B7}") }, "\(name): \(texts(s))")
            XCTAssertTrue(texts(s).contains { $0 == "B" || $0 == ComparisonText.liveLegend }, "\(name): \(texts(s))")
        }
        // Without a comparison nothing of this exists.
        let none = try session(.spectrum, Array(frames.suffix(30)), .init(), size: CGSize(width: 1200, height: 330))
        let r = try XCTUnwrap(none.renderer as? SpectrumRenderer)
        XCTAssertEqual(r.laneRectForTesting, .zero); XCTAssertNotNil(r.headphoneBandForTesting); XCTAssertTrue(texts(none).contains(SpectrumRenderer.averageLegend))
    }

    /// Never text on text, with everything on: lane and headphone band, both modes, level match on and off, measuring,
    /// a cursor; spectrum and meters; at the three app sizes and at every size of the layout test.
    func testComparisonLabelsNeverIntersect() throws {
        try RenderTestSupport.requireMetal()
        for size in Self.sizes { XCTAssertTrue(LabelLayoutTests.sizes.contains(size)) }
        var scenarios = ComparisonReviewTests.scenarios()
        // A long name, SPL on, a hot signal, a cursor in the bass (the header readout is at its longest).
        var o = SyntheticFrames.Options(); o.includeHeadphone = true; o.includeSPL = true; o.hot = true
        let spl = SyntheticFrames.sequence(count: 600, options: o)
        var long = OffscreenRenderer.Settings()
        long.comparison = SyntheticFrames.demoComparison(from: spl[spl.count - 1], headphone: .susvaraLike, name: "A \u{00B7} 21:42 \u{00B7} Qobuz \u{00B7} Remaster 2019 (Deluxe Edition)")
        long.levelAxis = .dBSPL; long.spectrum.showSide = true; long.targetLUFS = -14
        long.cursor = PanelCursor(frequencyHz: 47, source: .spectrogram, isPinned: true)
        scenarios.append(.init(name: "long name, SPL, side, cursor", frames: spl, settings: long))
        long.comparisonMode = .headphone; long.cursor = PanelCursor(frequencyHz: 18_000, source: .meters)
        scenarios.append(.init(name: "headphone mode, SPL, cursor", frames: spl, settings: long))
        for sc in scenarios {
            for size in LabelLayoutTests.sizes {
                for panel in [PanelKind.spectrum, .meters] {
                    let s = try session(panel, Array(sc.frames.suffix(panel == .spectrum ? 30 : 200)), sc.settings, size: size)
                    let labels = s.renderer.textLayer.lastLabels
                    let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
                    let name = "\(panel.rawValue) \(sc.name) \(Int(size.width))x\(Int(size.height))"
                    for (i, a) in labels.enumerated() {
                        XCTAssertTrue(bounds.contains(a.rect), "\(name): \"\(a.text)\" \(a.rect) leaves the panel")
                        for b in labels[(i + 1)...] where a.rect.intersects(b.rect) { XCTFail("\(name): \"\(a.text)\" \(a.rect) on \"\(b.text)\" \(b.rect)") }
                    }
                }
            }
        }
    }

    /// The meters table: A, B and B − A with the formatter of the panel; dashes for what is not measured; level match
    /// moves the band rows and nothing else.
    func testMetersTable() throws {
        try RenderTestSupport.requireMetal()
        let frames = RealFrames.demo(seconds: 8)
        let last = try XCTUnwrap(frames.last)
        var a = ComparisonSnapshot.capture(from: last, name: "A \u{00B7} 21:42 \u{00B7} Qobuz")
        a.averageDB = a.averageDB.map { $0 <= SpectrumReading.floorDB ? $0 : $0 - 3 }
        a.loudness.integratedLUFS -= 3; a.loudness.truePeakMaxDBTP -= 2.5; a.loudness.plrDB += 0.5
        a.lowestStrongHz = max(last.lowestStrongHz - 6, 20)
        var settings = OffscreenRenderer.Settings(); settings.comparison = a
        let on = try session(.meters, frames, settings)
        let r = try XCTUnwrap(on.renderer as? MetersRenderer)
        // The table takes its numbers 4 times per second: here it must read the frame A was captured from.
        func fresh(_ r: MetersRenderer) -> MetersRenderer.CompareShown? { r.compareShown = nil; r.ensureCompareShown(); return r.compareShown }
        let shown = try XCTUnwrap(fresh(r))
        XCTAssertEqual(shown.rows.first?.delta, "+3.0"); XCTAssertEqual(shown.rows.first?.a, Fmt.number(a.loudness.integratedLUFS))
        XCTAssertEqual(shown.rows.first { $0.kind == 3 }?.delta, "+2.5"); XCTAssertEqual(shown.rows.first { $0.kind == 2 }?.delta, "\u{2212}0.5", "a real minus sign")
        XCTAssertEqual(shown.rows.first { $0.kind == 1 }?.b, Fmt.dash, "the range of 8 s is not a range yet"); XCTAssertEqual(shown.rows.first { $0.kind == 1 }?.delta, Fmt.dash)
        XCTAssertEqual(shown.rows.first { $0.kind == 5 }?.delta, last.lowestStrongHz > 26 ? "+6" : Fmt.number(last.lowestStrongHz - a.lowestStrongHz, digits: 0, signed: true))
        XCTAssertNil(shown.rows.first { $0.kind == 4 }, "no Leq row unless both have one")
        XCTAssertEqual(shown.bands.count, 8)
        for b in shown.bands.compactMap({ $0 }) { XCTAssertEqual(b, 0, "level-matched: \(shown.bands)") }
        XCTAssertGreaterThanOrEqual(shown.bands.compactMap { $0 }.count, 6)
        XCTAssertEqual(shown.offsetTenths, 30)
        XCTAssertTrue(texts(on).contains { $0.hasPrefix("bands level-matched") }, "\(texts(on))")
        XCTAssertTrue(texts(on).contains("A VS B")); XCTAssertTrue(texts(on).contains("+3.0"))
        XCTAssertEqual(r.spark, .zero, "the table stands where the history stood")
        XCTAssertTrue(on.renderer.accessibilityValueText.contains("Integrated +3.0 LU"))

        settings.comparisonLevelMatch = false
        let off = try session(.meters, frames, settings)
        let unmatched = try XCTUnwrap(fresh(try XCTUnwrap(off.renderer as? MetersRenderer)))
        XCTAssertEqual(unmatched.rows, shown.rows, "level match touches the band rows only")
        for b in unmatched.bands.compactMap({ $0 }) { XCTAssertEqual(b, 30) }
        XCTAssertTrue(texts(off).contains { $0.hasPrefix("bands not level-matched") })

        // B before its first gated block: dashes.
        var early = frames
        for i in early.indices { early[i].loudness.isIntegratedValid = false }
        let e = try XCTUnwrap(fresh(try XCTUnwrap(try session(.meters, early, settings).renderer as? MetersRenderer)))
        XCTAssertEqual(e.rows[0].b, Fmt.dash); XCTAssertEqual(e.rows[0].delta, Fmt.dash); XCTAssertEqual(e.rows[0].a, shown.rows[0].a)
        XCTAssertEqual(e.rows.first { $0.kind == 2 }?.delta, Fmt.dash)

        // Without a comparison the history is back; a high panel keeps both.
        XCTAssertGreaterThan(try XCTUnwrap(try session(.meters, frames, .init()).renderer as? MetersRenderer).spark.width, 0)
        settings.comparisonLevelMatch = true
        let tall = try XCTUnwrap(try session(.meters, frames, settings, size: CGSize(width: 1200, height: 820)).renderer as? MetersRenderer)
        XCTAssertGreaterThan(tall.spark.height, 60); XCTAssertGreaterThan(tall.compareRect.height, 100)
        XCTAssertLessThanOrEqual(tall.compareRect.maxY, tall.spark.minY)
    }

    /// The two panels print the same offset (same frame, same tilt), also when the plot range of the spectrum gates bins.
    func testSpectrumAndMetersAgreeOnTheOffset() throws {
        try RenderTestSupport.requireMetal()
        let frames = RealFrames.demo(seconds: 8)
        var settings = OffscreenRenderer.Settings()
        settings.comparison = SyntheticFrames.demoComparison(from: try XCTUnwrap(frames.last), louderDB: -2.7, tiltDBPerOctave: 0)
        settings.liveTiltDBPerOctave = 0
        let s = try XCTUnwrap(try session(.spectrum, Array(frames.suffix(30)), settings).renderer as? SpectrumRenderer)
        let m = try XCTUnwrap(try session(.meters, frames, settings).renderer as? MetersRenderer)
        _ = s.laneStateForTesting
        let a = try XCTUnwrap(s.compare.levelOffsetDB)
        m.compareShown = nil; m.ensureCompareShown()
        XCTAssertEqual(try XCTUnwrap(m.compareShown?.offsetTenths), Int((a * 10).rounded()))
    }

    /// Freeze interplay: the frame stands still, a reference is set, the lane and the table appear without a new frame.
    func testComparisonAppearsWhileTheDisplayIsFrozen() throws {
        try RenderTestSupport.requireMetal()
        let frames = RealFrames.demo(seconds: 8)
        for panel in [PanelKind.spectrum, .meters] {
            let s = try session(panel, Array(frames.suffix(60)), .init(), size: CGSize(width: 900, height: 420))
            let a = SyntheticFrames.demoComparison(from: try XCTUnwrap(frames.last))
            (s.renderer as? SpectrumRenderer)?.comparison = a
            (s.renderer as? MetersRenderer)?.comparison = a
            XCTAssertTrue(s.renderer.needsDisplay)
            _ = try s.snapshotPNG()
            XCTAssertTrue(texts(s).contains(panel == .spectrum ? "B \u{2212} A" : "A VS B"), "\(panel): \(texts(s))")
            // The same reference again: nothing to redraw.
            s.renderer.needsDisplay = false
            (s.renderer as? SpectrumRenderer)?.comparison = a
            (s.renderer as? MetersRenderer)?.comparison = a
            XCTAssertFalse(s.renderer.needsDisplay)
            (s.renderer as? SpectrumRenderer)?.comparison = nil
            (s.renderer as? MetersRenderer)?.comparison = nil
            _ = try s.snapshotPNG()
            XCTAssertFalse(texts(s).contains("B \u{2212} A")); XCTAssertFalse(texts(s).contains("A VS B"))
        }
    }

    /// The views carry the public API of the brief.
    func testPublicAPI() throws {
        let frame = SyntheticFrames.sequence(count: 1)[0]
        let spectrum = SpectrumView(frameProvider: { frame })
        XCTAssertNil(spectrum.comparison); XCTAssertTrue(spectrum.comparisonLevelMatch); XCTAssertEqual(spectrum.comparisonMode, .signal); XCTAssertEqual(spectrum.liveTiltDBPerOctave, 0)
        let meters = MetersView(frameProvider: { frame })
        XCTAssertNil(meters.comparison); XCTAssertTrue(meters.comparisonLevelMatch)
        let a = SyntheticFrames.demoComparison(from: frame)
        spectrum.comparison = a; spectrum.comparisonMode = .headphone; spectrum.liveTiltDBPerOctave = 3; meters.comparison = a; meters.liveTiltDBPerOctave = 3
        spectrum.syncOptions(); meters.syncOptions()
        if let r = spectrum.renderer as? SpectrumRenderer { XCTAssertEqual(r.comparison?.id, a.id); XCTAssertEqual(r.comparisonMode, .headphone); XCTAssertEqual(r.liveTiltDBPerOctave, 3) }
        if let r = meters.renderer as? MetersRenderer { XCTAssertEqual(r.comparison?.id, a.id) }
        let s = OffscreenRenderer.Settings()
        XCTAssertNil(s.comparison); XCTAssertTrue(s.comparisonLevelMatch); XCTAssertEqual(s.comparisonMode, .signal); XCTAssertEqual(s.liveTiltDBPerOctave, 0)
    }

    /// What a comparison costs per frame. Printed for the report; the bound is the panel budget of the render brief.
    func testFrameCostWithAndWithoutAComparison() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 8).suffix(120))
        var with = OffscreenRenderer.Settings()
        with.comparison = SyntheticFrames.demoComparison(from: try XCTUnwrap(frames.last))
        for panel in [PanelKind.spectrum, .meters] {
            let base = try OffscreenRenderer.measure(panel: panel, frames: frames, size: CGSize(width: 1200, height: 600), iterations: 240)
            let cost = try OffscreenRenderer.measure(panel: panel, frames: frames, size: CGSize(width: 1200, height: 600), iterations: 240, settings: with)
            print(String(format: "A/B cost %@ 1200x600@2x: cpu %.3f -> %.3f ms, gpu %.3f -> %.3f ms, text %.3f -> %.3f ms", panel.rawValue,
                         base.cpuEncodeMS, cost.cpuEncodeMS, base.gpuMS, cost.gpuMS, base.textMS, cost.textMS))
            XCTAssertLessThan(cost.gpuMS, 2.0, "\(panel)")
            XCTAssertLessThan(cost.cpuEncodeMS, base.cpuEncodeMS + 0.6, "\(panel)")
        }
    }
}
