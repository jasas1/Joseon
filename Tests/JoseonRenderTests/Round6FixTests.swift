import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Critic round 4: single-defect fixes, one test (or more) per defect.
final class Round6FixTests: XCTestCase {
    static func frames(_ s: SpectrumReading, count: Int = 12, edit: (inout AnalysisFrame) -> Void = { _ in }) -> [AnalysisFrame] {
        (0..<count).map { k in
            var f = AnalysisFrame(hostTime: 10 + Double(k) / 60, spectrum: s, isSilent: false)
            f.stream = StreamInfo(sampleRate: 48_000, channelCount: 2, deviceName: "Test")
            edit(&f)
            return f
        }
    }

    static func bin(_ s: SpectrumReading, _ hz: Float) -> Int {
        s.frequencies.indices.min(by: { abs(s.frequencies[$0] - hz) < abs(s.frequencies[$1] - hz) })!
    }

    // MARK: Defect 1: peak hold never under the average

    func testPeakHoldIsNeverDrawnUnderTheAverageAndTheAverageIsNamedLongTerm() throws {
        try RenderTestSupport.requireMetal()
        var s = SpectrumReading.silent(binCount: 1024)
        for i in 0..<1024 { s.mid[i] = -60; s.left[i] = -60; s.right[i] = -60; s.average[i] = -58; s.peakHold[i] = -50 }
        // Old chord partials: still in the long-term average, already gone from peak hold.
        for hz in [220, 330, 395] as [Float] {
            let i = Self.bin(s, hz)
            for (k, db) in [(-1, -40), (0, -30), (1, -40)] as [(Int, Float)] { s.average[i + k] = db }
        }
        var settings = OffscreenRenderer.Settings(); settings.spectrumAutoRange = false
        settings.spectrum.minDB = -96; settings.spectrum.maxDB = 0
        let session = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: settings)
        try session.feed(Self.frames(s))
        _ = try session.snapshotPNG()
        let r = try XCTUnwrap(session.renderer as? SpectrumRenderer)
        let peak = try XCTUnwrap(r.curveForTesting("peakHold")), average = try XCTUnwrap(r.curveForTesting("average"))
        XCTAssertGreaterThan(average.max() ?? -100, -35, "the fixture has average spikes over peak hold")
        for i in peak.indices { XCTAssertGreaterThanOrEqual(peak[i], average[i] - 0.001, "column \(i)") }
        // Away from the spikes peak hold is the analyzer's value.
        XCTAssertEqual(peak[peak.count / 2 + 200], -50, accuracy: 0.2)
        let labels = session.renderer.textLayer.lastLabels.map(\.text)
        XCTAssertTrue(labels.contains("Long-term"), "\(labels)")
        XCTAssertFalse(labels.contains("Average"))
    }

    // MARK: Defect 3: a note label belongs to its own dot

    /// The demo chord signal at card size. At several moments of the chord loop every label is centered within 10 pt of its
    /// own dot or has a leader, never covers the frequency of another peak when offset, and the count follows the width.
    func testCardSizeNoteLabelsStandOverTheirOwnDotsOrHaveALeader() throws {
        try RenderTestSupport.requireMetal()
        let all = RealFrames.demo(seconds: 8)
        var labelled = 0, leaders = 0
        for end in [150, 210, 270, 330, 390, 450, 480] {
            let s = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 460, height: 330), scale: 2, theme: Theme(), settings: OffscreenRenderer.Settings())
            try s.feed(Array(all[max(end - 90, 0)..<end]))
            let png = try s.snapshotPNG()
            if end == 390 { RenderTestSupport.write(png, "r6-card-labels-460x330.png") }
            let r = try XCTUnwrap(s.renderer as? SpectrumRenderer)
            let last = all[end - 1]
            let peakXs = last.topPeaks.map { r.plotRectForTesting.minX + CGFloat(log($0.frequencyHz / 20) / log(Float(1000))) * r.plotRectForTesting.width }
            XCTAssertLessThanOrEqual(r.peakLabelPlacements.count, max(Int(r.plotRectForTesting.width / 70), 1))
            for pl in r.peakLabelPlacements {
                labelled += 1; if pl.leader { leaders += 1 }
                XCTAssertTrue(abs(pl.box.midX - pl.dot.x) <= 10 || pl.leader, "\(pl.name) at frame \(end): center \(pl.box.midX), dot \(pl.dot.x)")
                XCTAssertLessThanOrEqual(abs(pl.box.midX - pl.dot.x), 12, "\(pl.name): an offset stays small")
                XCTAssertLessThan(pl.box.maxY, pl.dot.y, "\(pl.name) is above its dot")
                if pl.leader {
                    for x in peakXs where abs(x - pl.dot.x) > 0.5 {
                        XCTAssertFalse(pl.box.minX <= x && x <= pl.box.maxX, "\(pl.name) at frame \(end) covers the peak at x = \(x)")
                    }
                }
            }
            // No two label boxes touch.
            let boxes = r.peakLabelPlacements.map(\.box)
            for i in boxes.indices { for j in boxes.indices where j > i { XCTAssertFalse(boxes[i].intersects(boxes[j])) } }
        }
        print("R6 card labels: \(labelled) labels, \(leaders) with a leader")
        XCTAssertGreaterThanOrEqual(labelled, 14, "the chord's partials are labelled at card size")
    }

    // MARK: Defect 6: the headphone curves have their own band

    private func headphoneSession(response: Float, target: Float, hasTarget: Bool, music: Float = -120) throws -> OffscreenRenderer.Session {
        var s = SpectrumReading.silent(binCount: 1024)
        for i in 0..<1024 { s.mid[i] = music; s.left[i] = music; s.right[i] = music; s.average[i] = music; s.peakHold[i] = music }
        let n = s.frequencies.count
        let hp = HeadphoneReading(modelName: "Test phone", responseDB: [Float](repeating: response, count: n), targetDB: [Float](repeating: hasTarget ? target : 0, count: n),
                                  hasTarget: hasTarget, predictedAtEarDB: s.mid.map { $0 + response }, stressFlags: [])
        var settings = OffscreenRenderer.Settings(); settings.spectrumAutoRange = false
        settings.spectrum.minDB = -96; settings.spectrum.maxDB = 0
        let session = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: settings)
        try session.feed(Self.frames(s) { $0.headphone = hp })
        return session
    }

    /// Amber (the response color) pixels of a row range inside the plot.
    private func amber(_ p: RenderTestSupport.Pixels, plot: CGRect, y0: CGFloat, y1: CGFloat) -> Int {
        var count = 0
        for y in Int(y0 * 2)..<Int(y1 * 2) { for x in Int(plot.minX * 2 + 4)..<Int(plot.maxX * 2 - 40) {
            let c = p.rgb(x, y); if c.0 > 110, c.2 < c.0 / 2, c.1 > c.0 / 2, c.1 < c.0 { count += 1 }
        } }
        return count
    }

    func testHeadphoneCurvesStayInTheTopQuarterAndTheMusicScaleStartsUnderIt() throws {
        try RenderTestSupport.requireMetal()
        // A response on its 0 line: drawn in the band, at 60 % alpha, nothing of it under the band.
        let flat = try headphoneSession(response: 0, target: 3, hasTarget: true)
        let png = try flat.snapshotPNG()
        RenderTestSupport.write(png, "r6-headphone-band.png")
        let r = try XCTUnwrap(flat.renderer as? SpectrumRenderer)
        let plot = r.plotRectForTesting, band = try XCTUnwrap(r.headphoneBandForTesting)
        XCTAssertEqual(band.minY, plot.minY, accuracy: 0.01); XCTAssertEqual(band.height, plot.height * 0.25, accuracy: 0.01)
        let px = try RenderTestSupport.decode(png: png)
        XCTAssertGreaterThan(amber(px, plot: plot, y0: band.minY, y1: band.maxY - 2), 1500, "the response line is in the band")
        XCTAssertEqual(amber(px, plot: plot, y0: band.maxY + 2, y1: plot.maxY), 0, "and nowhere under it")
        // 60 % alpha: the line's brightest red is well under the palette's full amber.
        var top = 0
        for x in stride(from: Int(plot.minX * 2) + 100, to: Int(plot.maxX * 2) - 100, by: 7) { for y in Int(band.minY * 2)..<Int(band.maxY * 2) { top = max(top, px.rgb(x, y).0) } }
        let full = Int(Palette(theme: Theme(), highContrast: false).hpResponse.x * 255)
        XCTAssertLessThan(top, full * 3 / 4, "the response is drawn at about 60 %: \(top) against \(full)")
        // The music scale (options: -96...0) ends at the band: 0 dB is at the band's lower edge.
        XCTAssertEqual(r.musicRange.max, 0); XCTAssertEqual(r.shownRange.max, 32, accuracy: 0.01)
        // A response far under the axis is cut at the band, not drawn through the music.
        let low = try headphoneSession(response: -40, target: 0, hasTarget: true)
        let lowPx = try RenderTestSupport.decode(png: low.snapshotPNG())
        XCTAssertEqual(amber(lowPx, plot: plot, y0: band.maxY + 2, y1: plot.maxY), 0)
    }

    func testAtEarIsMidPlusResponseMinusTargetWithATargetAndMidPlusResponseWithout() throws {
        try RenderTestSupport.requireMetal()
        let with = try headphoneSession(response: 9, target: 7, hasTarget: true, music: -50)
        let without = try headphoneSession(response: 9, target: 0, hasTarget: false, music: -50)
        _ = try with.snapshotPNG(); _ = try without.snapshotPNG()
        let a = try XCTUnwrap((with.renderer as? SpectrumRenderer)?.curveForTesting("atEar"))
        let b = try XCTUnwrap((without.renderer as? SpectrumRenderer)?.curveForTesting("atEar"))
        for i in stride(from: 20, to: a.count - 20, by: 25) {
            XCTAssertEqual(a[i], -48, accuracy: 0.05, "Mid + (Response - Target)")
            XCTAssertEqual(b[i], -41, accuracy: 0.05, "Mid + Response")
        }
        let la = with.renderer.textLayer.lastLabels.map(\.text), lb = without.renderer.textLayer.lastLabels.map(\.text)
        XCTAssertTrue(la.contains("At ear vs target"), "\(la)"); XCTAssertTrue(la.contains("Target"))
        XCTAssertTrue(lb.contains("At eardrum (incl. ear gain)"), "\(lb)"); XCTAssertFalse(lb.contains("Target"))
    }

    // MARK: Defect 7: a quiet tone in one channel shows in that channel

    func testAQuietLeftOnlyToneSurvivesTheLeftRightSmoothingAndTheLegendNamesTheSmoothing() throws {
        try RenderTestSupport.requireMetal()
        var settings = OffscreenRenderer.Settings(); settings.spectrumAutoRange = false
        settings.spectrum.minDB = -96; settings.spectrum.maxDB = 0
        let session = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: settings)
        let r = try XCTUnwrap(session.renderer as? SpectrumRenderer)
        let n = r.pointCountForTesting
        // What the analyzer gives for the demo's 3.1 kHz tone in L: a bump about 1/6 octave wide, 5 dB over R, on -60 dB noise.
        let peak = (0..<n).min(by: { abs(r.frequencyForTesting(point: $0) - 3_100) < abs(r.frequencyForTesting(point: $1) - 3_100) })!
        var left = (0..<n).map { i -> Float in -60 + 1.2 * sin(Float(i) * 0.9) * cos(Float(i) * 0.23) }
        let right = (0..<n).map { i -> Float in -60 + 1.2 * sin(Float(i) * 0.7 + 2) * cos(Float(i) * 0.31) }
        for k in -12...12 { left[peak + k] = -60 + 5 * pow(cos(Float(k) / 12 * .pi / 2), 2) }
        let alone = r.smoothHighsForTesting(left), withOther = r.smoothHighsForTesting(left, other: right)
        XCTAssertLessThan(alone[peak], -56.2, "one curve alone cannot tell this bump from noise: it is smoothed down")
        XCTAssertEqual(withOther[peak], -55, accuracy: 0.05, "against R the tone is found on the L curve and kept at its level")
        // Beside the tone and everywhere else the result is the plain smoothing: shared noise keeps nothing.
        for i in stride(from: peak + 60, to: n - 20, by: 7) { XCTAssertEqual(withOther[i], alone[i], accuracy: 0.01, "point \(i)") }
        for i in (peak + 60)..<(n - 20) { XCTAssertLessThan(abs(withOther[i] + 60), 0.8) }

        // Real pipeline: the demo's L-only 3.1 kHz tone and R-only 6.2 kHz tone stand in their own curve.
        let real = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: OffscreenRenderer.Settings())
        try real.feed(Array(RealFrames.demo(seconds: 6).suffix(30)))
        _ = try real.snapshotPNG()
        let rr = try XCTUnwrap(real.renderer as? SpectrumRenderer)
        let l = try XCTUnwrap(rr.curveForTesting("left"))
        func at(_ hz: Float) -> Int { (0..<l.count).min(by: { abs(rr.frequencyForTesting(point: $0) - hz) < abs(rr.frequencyForTesting(point: $1) - hz) })! }
        let raw = RealFrames.demo(seconds: 6).last!.spectrum
        XCTAssertEqual(l[at(3_100)], raw.left[Self.bin(raw, 3_100)], accuracy: 0.6, "L at 3.1 kHz is the analyzer's level")
        XCTAssertGreaterThan(l[at(3_100)] - l[at(2_800)], 2.0, "and stands over L beside it")
        let labels = real.renderer.textLayer.lastLabels.map(\.text)
        XCTAssertTrue(labels.contains("L/R 1/6 oct"), "\(labels)")
        var off = OffscreenRenderer.Settings(); off.spectrum.showLeftRight = false
        let hidden = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: off)
        try hidden.feed(Array(RealFrames.demo(seconds: 6).suffix(30)))
        _ = try hidden.snapshotPNG()
        XCTAssertFalse(hidden.renderer.textLayer.lastLabels.contains { $0.text == "L/R 1/6 oct" })
    }

    // MARK: Defect 8: L and R are thin desaturated tints everywhere

    func testLeftAndRightAreDesaturatedOnePointLinesAtEveryFrequency() throws {
        try RenderTestSupport.requireMetal()
        var s = SpectrumReading.silent(binCount: 1024)
        for i in 0..<1024 { s.mid[i] = -120; s.left[i] = -50; s.right[i] = -30; s.average[i] = -120; s.peakHold[i] = -120 }
        var settings = OffscreenRenderer.Settings(); settings.spectrumAutoRange = false
        settings.spectrum.minDB = -96; settings.spectrum.maxDB = 0
        settings.spectrum.showMid = false; settings.spectrum.showAverage = false; settings.spectrum.showPeakHold = false
        let session = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: settings)
        try session.feed(Self.frames(s))
        let px = try RenderTestSupport.decode(png: session.snapshotPNG())
        let r = try XCTUnwrap(session.renderer as? SpectrumRenderer)
        let plot = r.plotRectForTesting
        func column(_ hz: Float, _ db: Float) -> (color: (Int, Int, Int), lit: Int) {
            let x = Int((plot.minX + CGFloat(log(hz / 20) / log(Float(1000))) * plot.width) * 2) + 5      // beside the grid line
            let yc = Int((plot.maxY - CGFloat((db + 96) / 96) * plot.height) * 2)
            var best = (0, 0, 0), lit = 0
            let bg = px.rgb(x, yc - 30)
            for y in (yc - 8)...(yc + 8) {
                let c = px.rgb(x, y)
                if c.0 + c.1 + c.2 > best.0 + best.1 + best.2 { best = c }
                if c.0 + c.1 + c.2 > bg.0 + bg.1 + bg.2 + 60 { lit += 1 }
            }
            return (best, lit)
        }
        let palette = Palette(theme: Theme(), highContrast: false)
        for (db, tint, name) in [(-30, palette.spectrumRight, "R"), (-50, palette.spectrumLeft, "L")] as [(Float, SIMD4<Float>, String)] {
            let low = column(45, db), high = column(4_500, db)
            for c in [low, high] {
                // The tint at 75 % over the dark plot: every channel at or under the tint, and the same hue order.
                XCTAssertLessThanOrEqual(c.color.0, Int(tint.x * 255) + 3); XCTAssertLessThanOrEqual(c.color.2, Int(tint.z * 255) + 3)
                let hi = max(c.color.0, c.color.1, c.color.2), lo = min(c.color.0, c.color.1, c.color.2)
                XCTAssertLessThan(Double(hi - lo) / Double(hi), 0.55, "\(name) is a desaturated tint: \(c.color)")
                XCTAssertGreaterThan(hi, 120, "\(name) is visible")
                XCTAssertLessThanOrEqual(c.lit, 4, "\(name) is 1 pt wide, no glow: \(c.lit) px lit")
            }
            XCTAssertLessThan(abs(low.color.0 - high.color.0) + abs(low.color.1 - high.color.1) + abs(low.color.2 - high.color.2), 12, "\(name): one color at 45 Hz and at 4.5 kHz")
        }
        XCTAssertEqual(palette.spectrumLeft.x, Float(0x7F) / 255, accuracy: 0.001); XCTAssertEqual(palette.spectrumRight.x, Float(0xD9) / 255, accuracy: 0.001)
        XCTAssertEqual(palette.spectrumRight.w, 0.75)
    }

    // MARK: Defect 11: a hard-clipped signal follows the 45 degree edges

    /// Scope points in the analyzer's mapping: x = (R - L) / 2, y = (L + R) / 2.
    static func scopePoint(l: Float, r: Float) -> SIMD2<Float> { SIMD2((r - l) * 0.5, (l + r) * 0.5) }

    func testHardClippedStereoNoiseFillsTheDiamondWithStraight45DegreeEdges() throws {
        try RenderTestSupport.requireMetal()
        XCTAssertEqual(Self.scopePoint(l: 1, r: 1), SIMD2(0, 1)); XCTAssertEqual(Self.scopePoint(l: 1, r: 0), SIMD2(-0.5, 0.5))
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func uniform() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) }
        func clipped() -> Float { let g = (uniform() + uniform() + uniform() - 1.5) * 6; return min(max(g, -1), 1) }
        let frames = (0..<60).map { k -> AnalysisFrame in
            var f = AnalysisFrame(hostTime: 10 + Double(k) / 60, spectrum: .silent(binCount: 64), isSilent: false)
            f.stereo = StereoReading(correlation: 0, width: 1, scopePoints: (0..<2048).map { _ in Self.scopePoint(l: clipped(), r: clipped()) })
            return f
        }
        let session = try OffscreenRenderer.Session(panel: .vectorscope, size: CGSize(width: 600, height: 500), scale: 2, theme: Theme(), settings: .init())
        try session.feed(frames)
        let png = try session.snapshotPNG()
        RenderTestSupport.write(png, "r6-scope-clipped-noise.png")
        let px = try RenderTestSupport.decode(png: png)
        let r = try XCTUnwrap(session.renderer as? VectorscopeRenderer)
        let field = r.fieldForTesting
        let cx = Int(field.midX * 2), cy = Int(field.midY * 2)
        // Full scale at gain 0.85 (the automatic gain's floor for a full-scale signal), in pixels.
        XCTAssertEqual(r.gain, 0.85, accuracy: 0.01)
        let reach = Double(field.width) * 0.86 * Double(r.gain)          // = radius (points) * gain * 2 px / pt
        // The trace is blue to cyan; the grid is grey.
        func lit(_ x: Int, _ y: Int) -> Bool { let c = px.rgb(x, y); return c.2 > 110 && c.2 > c.0 * 2 }
        var worst = 0.0
        for part in stride(from: -0.8, through: 0.8, by: 0.1) where abs(part) > 0.05 {
            let dy = Int(part * reach)
            var right = 0, left = 0
            // 30 px past the expected edge: the L and R labels stand further out.
            for dx in 0..<(Int(reach) - abs(dy) + 30) { if lit(cx + dx, cy - dy) { right = dx }; if lit(cx - dx, cy - dy) { left = dx } }
            for edge in [right, left] {
                // On the edge of the diamond |dx| + |dy| = reach: a flat top would leave rows over it dark (edge = 0).
                worst = max(worst, abs(Double(edge + abs(dy)) - reach))
            }
        }
        XCTAssertLessThan(worst, reach * 0.04, "the outline is the 45 degree diamond, off by at most 4 % of its size (\(worst) px of \(reach))")
        // The tips carry light: L = R = +-1 is (0, +-1), not a clamped flat.
        var tip = 0
        for dy in Int(reach * 0.93)..<Int(reach * 1.0) { for dx in -6...6 where lit(cx + dx, cy - dy) { tip += 1 } }
        XCTAssertGreaterThan(tip, 20, "the top tip is lit")
    }

    // MARK: Defect 12: placement

    func testPanUnder40HzIsDampedWhenItIsEstimationNoiseAndKeptWhenItIsSteady() {
        var seed: UInt64 = 42
        func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) - 0.5 }
        var s = SpectrumReading.silent(binCount: 1024)
        let lows = s.frequencies.indices.filter { s.frequencies[$0] >= 20 && s.frequencies[$0] <= 36 }
        // Independent noise in L and R: the level of each channel moves by +-5 dB, anew every 0.4 s (one analysis window).
        let noisy = PanField(), steady = PanField(), undamped = PanField()
        undamped.confidenceFadeHz = 0; undamped.confidenceHz = 0
        var worstNoisy: Float = 0, leastSteady: Float = 1, worstUndamped: Float = 0
        var dl: Float = 0, dr: Float = 0
        for k in 0..<(60 * 12) {
            if k % 24 == 0 { dl = rnd() * 10; dr = rnd() * 10 }
            for i in 0..<1024 { s.left[i] = -45 + dl; s.right[i] = -45 + dr }
            noisy.update(s, dt: 1.0 / 60, sampleRate: 48_000)
            undamped.update(s, dt: 1.0 / 60, sampleRate: 48_000)
            if k > 60 * 6 { for i in lows { worstUndamped = max(worstUndamped, abs(undamped.pan[i])) } }
            // The same sound in both channels, 10 dB louder in R, its level moving: a steady placement.
            for i in 0..<1024 { s.left[i] = -50 + dl; s.right[i] = -40 + dl }
            steady.update(s, dt: 1.0 / 60, sampleRate: 48_000)
            if k > 60 * 6 { for i in lows { worstNoisy = max(worstNoisy, abs(noisy.pan[i])); leastSteady = min(leastSteady, steady.pan[i]) } }
        }
        XCTAssertGreaterThan(worstUndamped, 0.3, "the fixture wanders without the damping")
        XCTAssertLessThan(worstNoisy, 0.12, "wandering pan under 40 Hz is damped to the center")
        XCTAssertGreaterThan(leastSteady, 0.7, "a steady pan under 40 Hz stays where it is (10 dB = 0.82)")
        // Over the fade nothing is damped.
        let high = s.frequencies.firstIndex(where: { $0 > 200 })!
        XCTAssertEqual(noisy.confidence[high], 1)
    }

    func testTheSkirtOfAHardPannedToneDrawsNoStreakToTheCenter() {
        var s = SpectrumReading.silent(binCount: 1024)
        for i in 0..<1024 { s.left[i] = -60; s.right[i] = -60 }
        let peak = Self.bin(s, 1_000)
        // R only: a tone at -20 dB with a window skirt that sinks into the -60 dB noise 9 bins out.
        let skirt: [Float] = [-20, -24, -31, -38, -44, -49, -53, -56, -58, -59.5]
        for (k, db) in skirt.enumerated() {
            for j in Set([peak - k, peak + k]) { s.right[j] = 10 * log10(pow(10, db / 10) + 1e-6) }
        }
        let field = PanField()
        for _ in 0..<90 { field.update(s, dt: 1.0 / 60, sampleRate: 48_000) }
        XCTAssertTrue(field.tonalPeaks.contains(where: { abs($0 - peak) <= 1 }))
        XCTAssertEqual(field.pan[peak], 1, accuracy: 0.05, "the tone is at the far right")
        var lit = 0
        for i in (peak - 40)...(peak + 40) where field.light(i, topDB: -17, bottomDB: -71) > 0 {
            lit += 1
            XCTAssertFalse(field.pan[i] > 0.15 && field.pan[i] < 0.85, "bin \(i - peak) from the tone is lit at pan \(field.pan[i]): part of a streak")
            if field.pan[i] >= 0.85 { XCTAssertGreaterThanOrEqual(field.levelDB[i], field.levelDB[peak] - 12.5, "the dot is the top 12 dB of the lobe") }
        }
        XCTAssertGreaterThan(lit, 60, "the centered noise beside the tone keeps its light")
        XCTAssertEqual(field.dropped[peak], 0); XCTAssertEqual(field.dropped[peak + 5], 1); XCTAssertEqual(field.dropped[peak + 30], 0)
    }

    func testThePlacementLegendIsWideAndHasAMiddleTick() throws {
        try RenderTestSupport.requireMetal()
        var settings = OffscreenRenderer.Settings(); settings.vectorscopeMode = .panSpectrum
        let session = try OffscreenRenderer.Session(panel: .vectorscope, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: settings)
        try session.feed(Array(RealFrames.demo(seconds: 3).suffix(90)))
        _ = try session.snapshotPNG()
        let r = try XCTUnwrap(session.renderer as? VectorscopeRenderer)
        let legend = try XCTUnwrap(r.panLegendForTesting)
        XCTAssertEqual(legend.width, 160, accuracy: 0.5)
        let labels = session.renderer.textLayer.lastLabels
        func value(_ l: (text: String, rect: CGRect)) -> Float? { Float(l.text.replacingOccurrences(of: "\u{2212}", with: "-")) }
        let low = try XCTUnwrap(labels.first { $0.rect.maxX <= legend.minX && abs($0.rect.midY - legend.midY) < 4 }.flatMap(value))
        let high = try XCTUnwrap(labels.first { $0.rect.minX >= legend.maxX && abs($0.rect.midY - legend.midY) < 4 }.flatMap(value))
        let middle = try XCTUnwrap(labels.first { abs($0.rect.midX - legend.midX) < 2 && $0.rect.minY >= legend.maxY }.flatMap(value))
        XCTAssertEqual(middle, (low + high) / 2, accuracy: 0.5, "the middle tick: -45 on a -70 ... -20 scale")
        XCTAssertLessThan(labels.first { abs($0.rect.midX - legend.midX) < 2 && $0.rect.minY >= legend.maxY }!.rect.maxY, r.fieldForTesting.maxY)
    }

    // MARK: Defect 13, panel side

    /// Silence as the real pipeline sends it: `isSilent`, 2048 scope points that are all zero, correlation 0.
    static func realSilence(seconds: Double = 2) -> [AnalysisFrame] {
        let engine = AnalysisEngine()
        engine.streamInfo = StreamInfo(sampleRate: 48_000, channelCount: 2, deviceName: "Silence", bitDepth: 32, activeSources: [])
        let zeros = [Float](repeating: 0, count: 800)
        return (0..<Int(seconds * 60)).map { k in
            var f = engine.processNow(left: zeros, right: zeros, count: 800, sampleRate: 48_000)
            f.hostTime = Double(k) / 60
            return f
        }
    }

    func testSilentStateShowsDashesInLineAndNoGain() throws {
        try RenderTestSupport.requireMetal()
        let silence = Self.realSilence()
        XCTAssertTrue(silence.last!.isSilent); XCTAssertFalse(silence.last!.stereo.scopePoints.isEmpty, "the fixture is the case the app has")
        for size in [CGSize(width: 1200, height: 600), CGSize(width: 460, height: 330), CGSize(width: 320, height: 229)] {
            let scope = try OffscreenRenderer.Session(panel: .vectorscope, size: size, scale: 2, theme: Theme(), settings: .init())
            try scope.feed(Array(RealFrames.demo(seconds: 1).suffix(30)) + silence)
            RenderTestSupport.write(try scope.snapshotPNG(), "r6-silent-scope-\(Int(size.width)).png")
            let labels = scope.renderer.textLayer.lastLabels
            XCTAssertFalse(labels.contains { $0.text.hasPrefix("gain") }, "\(size): no gain label")
            XCTAssertFalse(labels.contains { $0.text == "0.00" || $0.text == "+0.00" }, "\(size): no made-up correlation of 0")
            XCTAssertTrue(labels.contains { $0.text == Fmt.dash })

            let meters = try OffscreenRenderer.Session(panel: .meters, size: size, scale: 2, theme: Theme(), settings: .init())
            try meters.feed(silence)
            RenderTestSupport.write(try meters.snapshotPNG(), "r6-silent-meters-\(Int(size.width)).png")
            let ml = meters.renderer.textLayer.lastLabels
            // Every dash of the readouts stands under the left edge of a caption (M, S, I, LRA, ...): same x as a label above it.
            let captions = ml.filter { $0.text != Fmt.dash }
            let dashes = ml.filter { $0.text == Fmt.dash }
            let inReadout = dashes.filter { d in captions.contains { abs($0.rect.minX - d.rect.minX) < 0.75 && $0.rect.maxY <= d.rect.minY + 1 && d.rect.minY - $0.rect.maxY < 40 } }
            XCTAssertGreaterThanOrEqual(inReadout.count, 3, "\(size): M, S and I dashes line up with their captions: \(dashes.map { $0.rect.origin })")
            let widths = Set(inReadout.map { ($0.rect.width * 10).rounded() })
            XCTAssertEqual(widths.count, 1, "\(size): one dash size in the readouts")
        }
    }

    func testBalanceHasAUnitAndTheAxesHaveTheirLabels() throws {
        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let v = try XCTUnwrap(PanelRenderer.make(kind: .vectorscope, ctx: ctx, theme: Theme()) as? VectorscopeRenderer)
        XCTAssertEqual(v.balanceText(0.19, silent: false), "R 19%"); XCTAssertEqual(v.balanceText(-0.052, silent: false), "L 5%")
        XCTAssertEqual(v.balanceText(0.001, silent: false), "C"); XCTAssertEqual(v.balanceText(0.3, silent: true), Fmt.dash)

        let frames = Array(RealFrames.demo(seconds: 6).suffix(240))
        // Loudness history: -24 and -36 between the end labels (the demo's window is -12 ... -42).
        let meters = try OffscreenRenderer.Session(panel: .meters, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: .init())
        try meters.feed(frames)
        _ = try meters.snapshotPNG()
        let ml = meters.renderer.textLayer.lastLabels
        let historyTitle = try XCTUnwrap(ml.first { $0.text == "LOUDNESS HISTORY" })
        let axis = ml.filter { $0.rect.minY > historyTitle.rect.maxY && $0.rect.minX > historyTitle.rect.maxX && $0.text.hasPrefix(Fmt.minus) && !$0.text.contains("s") }.map(\.text)
        XCTAssertGreaterThanOrEqual(axis.count, 4, "top, bottom and two inner ticks: \(axis)")
        XCTAssertTrue(axis.contains("\(Fmt.minus)24") && axis.contains("\(Fmt.minus)36"), "\(axis)")

        // Spectrogram colorbar: the top of the scale is labelled.
        let sg = try OffscreenRenderer.Session(panel: .spectrogram, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: .init())
        try sg.feed(frames)
        _ = try sg.snapshotPNG()
        let r = try XCTUnwrap(sg.renderer as? SpectrogramRenderer)
        let top = Fmt.number(r.topDB.rounded(), digits: 0)
        let topLabel = try XCTUnwrap(sg.renderer.textLayer.lastLabels.first { $0.text == top && $0.rect.minX > 1100 }, "the colorbar's top label \(top)")
        XCTAssertLessThan(topLabel.rect.minY, 30)
        for other in sg.renderer.textLayer.lastLabels where other.rect.minX > 1100 && other.text != top { XCTAssertFalse(other.rect.intersects(topLabel.rect.insetBy(dx: 0, dy: -2))) }
    }

    func testTheSpectrogramFadesInOnceFromTheFirstValidColumn() throws {
        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let r = try XCTUnwrap(PanelRenderer.make(kind: .spectrogram, ctx: ctx, theme: Theme()) as? SpectrogramRenderer)
        r.setLayout(size: CGSize(width: 1200, height: 600), scale: 2)
        for f in RealFrames.demo(seconds: 3) { r.ingest(f) }
        // The oldest columns with data, oldest first, at 110 Hz (the first chord's root: a steady tone from t = 0).
        var series: [Float] = []
        for back in stride(from: 400, through: 0, by: -1) { if let v = r.historyLevel(columnsBack: back, hz: 110) { series.append(v) } }
        XCTAssertGreaterThan(series.count, 60)
        XCTAssertLessThan(series[0], r.floorDB + 3, "the first valid column starts at the floor")
        let settled = series[30]
        XCTAssertGreaterThan(settled, -35, "the tone is there after the fade")
        // One rise: no bright line followed by a dark gap (round 5 dropped back to the floor 4 columns in).
        for k in 1..<30 { XCTAssertGreaterThanOrEqual(series[k], series[k - 1] - 1.5, "column \(k) of the fade: \(series.prefix(30))") }
    }

    // MARK: Defect 2, panel side: the figure fills the card

    func testScopeAndPlacementFillTheRealCardSizes() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 3).suffix(60))
        let bandNames = Set(BandEnergy.names + ["Sub", "Bass", "LoMid", "UpMid", "Pres", "Brill", "Air"])
        for size in [CGSize(width: 600, height: 500), CGSize(width: 460, height: 330), CGSize(width: 320, height: 229), CGSize(width: 268, height: 199)] {
            for mode in [VectorscopeMode.lissajous, .panSpectrum] {
                var settings = OffscreenRenderer.Settings(); settings.vectorscopeMode = mode
                let s = try OffscreenRenderer.Session(panel: .vectorscope, size: size, scale: 2, theme: Theme(), settings: settings)
                try s.feed(frames)
                RenderTestSupport.write(try s.snapshotPNG(), "r6-card-\(mode == .lissajous ? "scope" : "placement")-\(Int(size.width))x\(Int(size.height)).png")
                let r = try XCTUnwrap(s.renderer as? VectorscopeRenderer)
                let field = r.fieldForTesting
                let labels = s.renderer.textLayer.lastLabels
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(field))
                // The figure takes the card: at least 75 % of the card height (the rest: padding and, under it, one line of numbers).
                XCTAssertGreaterThanOrEqual(field.height, size.height * 0.75, "\(size) \(mode): figure \(field)")
                if mode == .lissajous { XCTAssertEqual(field.width, field.height, accuracy: 0.5, "the scope is a square") }
                else { XCTAssertGreaterThanOrEqual(field.width, size.width * 0.6) }
                // No label on the border of the figure or outside the card.
                for l in labels { XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(l.rect), "\(size): \(l.text) leaves the card") }
                if size.width < 300 {
                    XCTAssertEqual(r.arrangement, .keysUnder)
                    XCTAssertTrue(labels.allSatisfy { !bandNames.contains($0.text) }, "no band table at \(size)")
                    let numbers = labels.filter { $0.rect.minY >= field.maxY }
                    XCTAssertGreaterThanOrEqual(numbers.count, 6, "CORR, WIDTH, BAL and their values")
                    let mids = numbers.map { $0.rect.midY }
                    XCTAssertLessThan(mids.max()! - mids.min()!, 3, "the numbers are one line")
                }
            }
        }
    }

    // MARK: Defect 5: bass tails (finding: the layers are centered; the tail is the analyzer's release, not the window)

    /// Real `midLayers`, chord change at t = 2.00 s (root 110 Hz -> 130.81 Hz). Each layer is composed at its own window
    /// center, so the NEW root rises through its -6 dB point at the time of the change. The old root falls later: that lag
    /// is the release smoothing the analyzer applies to the layers (instant attack, `releaseSeconds` = 0.25 s, in
    /// `SpectrumAnalyzer.applySmoothing`), measured and printed here. The renderer adds no tail of its own.
    func testSpectrogramLayersAreCenteredTheNewRootRisesAtTheChordChange() throws {
        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let r = try XCTUnwrap(PanelRenderer.make(kind: .spectrogram, ctx: ctx, theme: Theme()) as? SpectrogramRenderer)
        r.setLayout(size: CGSize(width: 1200, height: 600), scale: 2)
        for f in RealFrames.demo(seconds: 5) { r.ingest(f) }
        XCTAssertTrue(r.usesLayers)
        let columnSeconds = r.historySeconds / Double(SpectrogramRenderer.columns)
        func level(_ hz: Float, _ t: Double) -> Float { r.historyLevel(columnsBack: Int(((r.newestColumnTime - t) / columnSeconds).rounded()), hz: hz) ?? -120 }
        func crossing(_ hz: Float, rising: Bool) -> Double {
            let steady = rising ? level(hz, 3.0) : level(hz, 1.5)
            var t = 1.5
            while t < 3.0 { if rising ? level(hz, t) >= steady - 6 : level(hz, t) <= steady - 6 { return t }; t += columnSeconds }
            return 3.0
        }
        for (old, new) in [(110, 130.81), (165, 196.2), (220, 261.6)] as [(Float, Float)] {
            let rise = crossing(new, rising: true), fall = crossing(old, rising: false)
            print(String(format: "R6 chord change at 2.00 s: %.0f Hz rises through -6 dB at %.2f s, %.0f Hz falls through -6 dB at %.2f s (release lag %.2f s)", new, rise, old, fall, fall - rise))
            XCTAssertEqual(rise, 2.0, accuracy: 0.08, "\(new) Hz: the layer is centered on its window")
            XCTAssertGreaterThanOrEqual(fall, rise - 0.02, "the fall never leads the rise")
        }
    }
}
