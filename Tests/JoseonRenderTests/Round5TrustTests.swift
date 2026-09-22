import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Critic round 3, render side: what the display shows must be true and readable.
final class Round5TrustTests: XCTestCase {
    // MARK: Defect 4: no stripes in the spectrum fill

    /// Narrow tones over a flat noise floor. In a pixel row well under the noise floor the fill must vary smoothly along x:
    /// no column differs from the median of its +-8 neighbours by more than 4 % (or 2 steps of the 8-bit sum, whichever is
    /// larger: the row is dark). Columns on a grid line are left out: the grid is drawn over the fill.
    func testFillHasNoStripesUnderNarrowTones() throws {
        try RenderTestSupport.requireMetal()
        var s = SpectrumReading.silent(binCount: 1024)
        for i in 0..<1024 { s.mid[i] = -40; s.left[i] = -40; s.right[i] = -40; s.average[i] = -40; s.peakHold[i] = -40 }
        for hz in [395, 1_250, 6_200] as [Float] {
            let i = s.frequencies.indices.min(by: { abs(s.frequencies[$0] - hz) < abs(s.frequencies[$1] - hz) })!
            for (k, db) in [(-2, -34), (-1, -22), (0, -12), (1, -22), (2, -34)] as [(Int, Float)] { s.mid[i + k] = db; s.peakHold[i + k] = db }
        }
        let frames = (0..<30).map { k -> AnalysisFrame in
            var f = AnalysisFrame(hostTime: 10 + Double(k) / 60, spectrum: s, isSilent: false)
            f.stream = StreamInfo(sampleRate: 48_000, channelCount: 2, deviceName: "Test")
            return f
        }
        var settings = OffscreenRenderer.Settings()
        settings.spectrumAutoRange = false
        settings.spectrum.minDB = -72; settings.spectrum.maxDB = 0
        settings.spectrum.showLeftRight = false; settings.spectrum.showAverage = false; settings.spectrum.showPeakHold = false
        let session = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: settings)
        try session.feed(frames)
        let png = try session.snapshotPNG()
        RenderTestSupport.write(png, "fill-stripes-test.png")
        let p = try RenderTestSupport.decode(png: png)
        let r = try XCTUnwrap(session.renderer as? SpectrumRenderer)
        let plot = r.plotRectForTesting
        // Noise floor at -40 of -72...0: 44 % of the plot height. Rows at 30 % and 18 % of the height are well under it.
        let gridX = r.gridFrequenciesForTesting.map { Int((plot.minX + CGFloat(log($0 / 20) / log(Float(1000))) * plot.width) * 2) }
        for part in [0.30, 0.18] as [CGFloat] {
            let y = Int((plot.maxY - plot.height * part) * 2)
            let x0 = Int(plot.minX * 2) + 12, x1 = Int(plot.maxX * 2) - 48
            let row: [Double] = (x0..<x1).map { x in let c = p.rgb(x, y); return Double(c.0 + c.1 + c.2) }
            var worst = 0.0, worstX = 0
            for k in 8..<(row.count - 8) {
                let x = x0 + k
                if gridX.contains(where: { abs($0 - x) <= 10 }) { continue }
                var near: [Double] = []
                for j in (k - 8)...(k + 8) where !gridX.contains(where: { abs($0 - (x0 + j)) <= 2 }) { near.append(row[j]) }
                near.sort()
                let median = near[near.count / 2]
                let off = abs(row[k] - median) - max(median * 0.04, 2)
                if off > worst { worst = off; worstX = x }
            }
            XCTAssertLessThanOrEqual(worst, 0, "fill row at \(Int(part * 100)) % of the plot height: column \(worstX) px stands out")
            XCTAssertGreaterThan(row.max() ?? 0, 30, "the row must hold fill, not only background")
        }
    }

    // MARK: Defect 7: a one-sided tone does not stand on a box

    func testLeftRightSmoothingKeepsAToneAndLiftsNoBoxAroundIt() throws {
        try RenderTestSupport.requireMetal()
        var settings = OffscreenRenderer.Settings(); settings.spectrumAutoRange = false
        settings.spectrum.minDB = -96; settings.spectrum.maxDB = 0
        let session = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: settings)
        let r = try XCTUnwrap(session.renderer as? SpectrumRenderer)
        let n = r.pointCountForTesting
        // Noise at -64 dB with a +-2 dB ripple, and a tone at 6.2 kHz, 24 dB over it, 5 points wide.
        var curve = (0..<n).map { i -> Float in -64 + 2 * sin(Float(i) * 1.7) * cos(Float(i) * 0.31) }
        let peak = (0..<n).min(by: { abs(r.frequencyForTesting(point: $0) - 6_200) < abs(r.frequencyForTesting(point: $1) - 6_200) })!
        for (k, db) in [(-2, -58), (-1, -48), (0, -40), (1, -48), (2, -58)] as [(Int, Float)] { curve[peak + k] = db }
        let out = r.smoothHighsForTesting(curve)
        XCTAssertEqual(out[peak], -40, accuracy: 0.01, "the tonal peak is not smoothed")
        for k in [-2, -1, 1, 2] { XCTAssertEqual(out[peak + k], curve[peak + k], accuracy: 0.01, "the two neighbours either side stay raw") }
        // Round 4 lifted a flat box of about +6 dB over +-1/12 octave around the tone. Now the noise beside the tone stays noise.
        for k in Array(4...14) + Array(-14 ... -4) {
            XCTAssertEqual(out[peak + k], -64, accuracy: 1.6, "no pedestal \(k) points from the tone")
        }
        // Continuous join: no step larger than the lobe's own slope beside the lobe.
        for k in 3...16 { XCTAssertLessThan(abs(out[peak + k] - out[peak + k + 1]), 2.5); XCTAssertLessThan(abs(out[peak - k] - out[peak - k - 1]), 2.5) }
        // Far from the tone the ripple is smoothed away as before.
        let far = peak - 60
        XCTAssertLessThan(abs(out[far] + 64), 1.0)
    }

    // MARK: Defect 6: the click ridge is vertical with layers

    func testAClickIsOneVerticalRidgeWithSpectrumLayers() throws {
        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let r = try XCTUnwrap(PanelRenderer.make(kind: .spectrogram, ctx: ctx, theme: Theme()) as? SpectrogramRenderer)
        r.setLayout(size: CGSize(width: 1200, height: 600), scale: 2)
        let clicks = [2.0, 3.5, 5.0]
        for f in SyntheticFrames.layeredClicks(seconds: 7, clickTimes: clicks) { r.ingest(f) }
        XCTAssertTrue(r.usesLayers)
        let columnSeconds = r.historySeconds / Double(SpectrogramRenderer.columns)
        // 40 Hz to 10 kHz, with the crossfade zones 160-280 Hz and 1.4-2.8 kHz sampled densely.
        let probes: [Float] = [40, 63, 100, 140, 160, 180, 200, 230, 260, 280, 320, 500, 1_000, 1_400, 1_700, 2_000, 2_400, 2_800, 4_000, 6_300, 10_000]
        var report: [String] = []
        for click in clicks {
            // The panel clock starts one frame (1 / 60 s) before the first frame, whose time is 1 / 60 s: clock = signal time.
            let expectedBack = (r.newestColumnTime - click) / columnSeconds
            var ridge: [Double] = []
            for hz in probes {
                // Centroid of the power over the half-maximum: the top of a hill that is 40 columns wide is flat.
                var series: [(Int, Double)] = []
                for back in Int(expectedBack - 45)...Int(expectedBack + 45) {
                    guard let v = r.historyLevel(columnsBack: back, hz: hz) else { continue }
                    series.append((back, pow(10, Double(v) / 10)))
                }
                let top = series.map(\.1).max() ?? 0, base = series.map(\.1).min() ?? 0
                XCTAssertGreaterThan(10 * log10(top / max(base, 1e-12)), 6, "\(hz) Hz: the click stands over the floor")
                var sw = 0.0, sx = 0.0
                for (back, pw) in series where pw - base > (top - base) / 2 { sw += pw - base; sx += (pw - base) * Double(back) }
                ridge.append(expectedBack - sx / sw)          // columns late against the true click time
            }
            report.append("click \(click): " + zip(probes, ridge).map { String(format: "%.0f:%+.2f", $0, $1) }.joined(separator: " "))
            let lo = ridge.min()!, hi = ridge.max()!
            XCTAssertLessThanOrEqual(hi - lo, 2.0, "the ridge is vertical within +-1 column from 40 Hz to 10 kHz: \(report.last!)")
            XCTAssertEqual((hi + lo) / 2, 0, accuracy: 2.0, "and it stands at the time of the click")
        }
        print("LAYERS ridge position, columns late (1 column = \(Int(columnSeconds * 1000)) ms):\n" + report.joined(separator: "\n"))
    }

    /// The history starts with one vertical edge: no row shows data before the slowest layer has data.
    func testHistoryStartsOnOneEdge() throws {
        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let r = try XCTUnwrap(PanelRenderer.make(kind: .spectrogram, ctx: ctx, theme: Theme()) as? SpectrogramRenderer)
        r.setLayout(size: CGSize(width: 1200, height: 600), scale: 2)
        for f in SyntheticFrames.layeredClicks(seconds: 3, clickTimes: []) { r.ingest(f) }
        // The column where a row comes within 6 dB of its steady level (the fade-in is over), counted back from the newest.
        var edge: [Int] = []
        for hz in [30, 60, 110, 200, 440, 1_000, 2_000, 3_100] as [Float] {
            let steady = try XCTUnwrap(r.historyLevel(columnsBack: 20, hz: hz))
            var oldest = -1
            for back in 0..<400 { if let v = r.historyLevel(columnsBack: back, hz: hz), v > steady - 6 { oldest = back } }
            XCTAssertGreaterThan(oldest, 60, "\(hz) Hz has history")
            edge.append(oldest)
        }
        // The fade-in (0.12 s = 7 columns) lets a loud row reach its level a little later than a quiet one. The staircase of
        // round 4 was 20 columns and more between the lows and the highs.
        XCTAssertLessThanOrEqual(edge.max()! - edge.min()!, 8, "one left edge for every row: \(edge)")
    }

    // MARK: Defect 12: colorbar and contrast

    func testColorbarTicksAreEvenAndAQuietToneStandsOutOfTheNoise() throws {
        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let r = try XCTUnwrap(PanelRenderer.make(kind: .spectrogram, ctx: ctx, theme: Theme()) as? SpectrogramRenderer)
        r.setLayout(size: CGSize(width: 1200, height: 600), scale: 2)
        for f in RealFrames.demo(seconds: 2) { r.ingest(f) }
        let ticks = r.legendTicksForTesting
        XCTAssertGreaterThanOrEqual(ticks.count, 4)
        for t in ticks { XCTAssertEqual(t.truncatingRemainder(dividingBy: 15), 0, "tick \(t) is a multiple of 15 dB") }
        XCTAssertEqual(ticks.first, -75)
        for (a, b) in zip(ticks, ticks.dropFirst()) { XCTAssertEqual(b - a, 15) }

        func luminance(_ c: SIMD3<Float>) -> Float {
            func lin(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.x) + 0.7152 * lin(c.y) + 0.0722 * lin(c.z)
        }
        let tone = luminance(r.colorForTesting(db: -46)), noise = luminance(r.colorForTesting(db: -65)), black = luminance(r.colorForTesting(db: -75))
        let contrast = (tone + 0.05) / (noise + 0.05)
        print(String(format: "HEATMAP top %.0f dB: luminance -46 dB %.3f, -65 dB %.3f, -75 dB %.4f, contrast %.2f : 1", r.topDB, tone, noise, black, contrast))
        XCTAssertGreaterThan(contrast, 3.0, "a -46 dB tone against -65 dB noise")
        XCTAssertGreaterThan(noise, black * 1.5, "the noise floor is still visible over black")
        XCTAssertLessThan(black, 0.006, "-75 dB and under stays black")
    }

    // MARK: Defect 11: placement of tones

    func testDemoTonesSitHardLeftAndRightAndChordPartialsAreCompact() throws {
        let frames = RealFrames.demo(seconds: 6)
        let field = PanField()
        // 200 ms windows at the end of the run. Per frame: pan and light of the bins of each tone.
        struct Sample { var pan: Float; var level: Float }
        var history: [[Int: Sample]] = []
        var freqs: [Float] = []
        for f in frames {
            field.update(f.spectrum, dt: 1.0 / 60, sampleRate: 48_000)
            freqs = f.spectrum.frequencies
            var row: [Int: Sample] = [:]
            for i in 0..<field.count where field.levelDB[i] > field.gateDB { row[i] = Sample(pan: field.pan[i], level: field.levelDB[i]) }
            history.append(row)
        }
        func bins(around hz: Float, octaves: Float) -> [Int] { freqs.indices.filter { abs(log2(freqs[$0] / hz)) < octaves } }
        func weightedPan(_ hz: Float, frames range: Range<Int>) -> (mean: Float, lo: Float, hi: Float) {
            var sw: Float = 0, sp: Float = 0, lo: Float = 2, hi: Float = -2
            for k in range {
                // The bins that carry the tone's light: within 6 dB of the strongest bin near it (the core of the blob).
                let near = bins(around: hz, octaves: 0.02).compactMap { i in history[k][i].map { (i, $0) } }
                guard let top = near.map({ $0.1.level }).max() else { continue }
                for (_, s) in near where s.level > top - 6 {
                    let w = pow(10, s.level / 10)
                    sw += w; sp += w * s.pan; lo = min(lo, s.pan); hi = max(hi, s.pan)
                }
            }
            return (sp / max(sw, 1e-20), lo, hi)
        }
        let last = (history.count - 12)..<history.count
        let sparkle = weightedPan(3_100, frames: last), shimmer = weightedPan(6_200, frames: last)
        print(String(format: "PLACEMENT 3.1 kHz pan %.3f (%.3f...%.3f), 6.2 kHz pan %.3f (%.3f...%.3f)", sparkle.mean, sparkle.lo, sparkle.hi, shimmer.mean, shimmer.lo, shimmer.hi))
        XCTAssertLessThan(sparkle.mean, -0.9, "3.1 kHz is in the left channel only")
        XCTAssertGreaterThan(shimmer.mean, 0.9, "6.2 kHz is in the right channel only")

        // Chord of the last two seconds (t = 4...6 s): root 146.83 Hz. Every partial is one compact blob in each 200 ms window:
        // the spread of its lit bins is under 8 % of the pan width (2.0).
        var worst: Float = 0
        for window in [(history.count - 60)..<(history.count - 48), (history.count - 36)..<(history.count - 24), last] {
            for m in [1.5, 2.0, 2.52, 3.0, 4.0] as [Float] {
                let p = weightedPan(146.83 * m, frames: window)
                worst = max(worst, (p.hi - p.lo) / 2)
                XCTAssertLessThan((p.hi - p.lo) / 2, 0.08, "partial at \(146.83 * m) Hz: pans \(p.lo)...\(p.hi)")
                // L = 1 - 0.4 s, R = 1 + 0.4 s with s = sin(0.7 t): the blob sits where the power ratio says. The reading lags
                // the signal by about one analysis window and the smoothing: compare with the signal 0.7 s earlier.
                let t = Float(window.lowerBound + 6) / 60 - 0.7
                let sl = sin(0.7 * t), l = 1 - 0.4 * sl, rr = 1 + 0.4 * sl
                XCTAssertEqual(p.mean, (rr * rr - l * l) / (rr * rr + l * l), accuracy: 0.2, "partial at \(146.83 * m) Hz sits at its true pan")
            }
        }
        print(String(format: "PLACEMENT chord partials: largest spread in a 200 ms window %.1f %% of the width", worst * 100))
    }

    // MARK: Defect 8: meters

    func testLoudnessRangeIsADashUntilThirtySecondsAndCardsShowTheHistory() throws {
        try RenderTestSupport.requireMetal()
        var frames = Array(RealFrames.demo(seconds: 7).suffix(200))
        for size in [CGSize(width: 460, height: 330), CGSize(width: 560, height: 360), CGSize(width: 1200, height: 600)] {
            let s = try OffscreenRenderer.Session(panel: .meters, size: size, scale: 2, theme: Theme(), settings: .init())
            try s.feed(frames)
            _ = try s.snapshotPNG()
            let labels = s.renderer.textLayer.lastLabels
            let caption = try XCTUnwrap(labels.first { $0.text == "LRA" || $0.text == "RANGE  LRA" }, "\(size)")
            // The value stands under (compact) or under-right of the caption: the nearest label below it.
            let below = labels.filter { $0.rect.minY > caption.rect.minY + 2 && abs($0.rect.minX - caption.rect.minX) < 40 }.min { $0.rect.minY < $1.rect.minY }
            XCTAssertEqual(below?.text, Fmt.dash, "LRA after 7 s at \(size): \(below?.text ?? "nil")")
            XCTAssertTrue(labels.contains { $0.text == "LOUDNESS HISTORY" || $0.text == "HISTORY" }, "loudness history at \(size)")
        }
        // After 30 s the number shows.
        for i in frames.indices { frames[i].loudness.measuredSeconds = 31 + Double(i) / 60; frames[i].loudness.loudnessRangeLU = 4.2 }
        let s = try OffscreenRenderer.Session(panel: .meters, size: CGSize(width: 460, height: 330), scale: 2, theme: Theme(), settings: .init())
        try s.feed(frames)
        _ = try s.snapshotPNG()
        XCTAssertTrue(s.renderer.textLayer.lastLabels.contains { $0.text == "4.2" })
    }

    /// `PEAK` and `CLIP` share a row: at every width they keep at least 8 pt between them, also with a long clip count.
    func testPeakCaptionAndClipIndicatorNeverTouch() throws {
        try RenderTestSupport.requireMetal()
        var frames = Array(RealFrames.demo(seconds: 3).suffix(30))
        for clips in [0, 1234] {
            for i in frames.indices { frames[i].loudness.clipCount = clips }
            for width in stride(from: 260, through: 760, by: 20) {
                let s = try OffscreenRenderer.Session(panel: .meters, size: CGSize(width: CGFloat(width), height: 330), scale: 2, theme: Theme(), settings: .init())
                try s.feed(frames)
                _ = try s.snapshotPNG()
                let labels = s.renderer.textLayer.lastLabels
                let clip = try XCTUnwrap(labels.first { $0.text.hasPrefix("CLIP") || $0.text == "999+" || $0.text == "0" && $0.rect.minY < 30 }, "width \(width)")
                if let caption = labels.first(where: { $0.text == "TRUE PEAK" || $0.text == "TP" }) {
                    XCTAssertGreaterThanOrEqual(clip.rect.minX - caption.rect.maxX, 8, "width \(width), clips \(clips): \(caption.text) and \(clip.text)")
                }
            }
        }
    }

    // MARK: Defects 9, 13: layout and the empty state

    func testScopeFillsTheCardAndCollapsesToKeyNumbers() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 3).suffix(60))
        for (size, least) in [(CGSize(width: 460, height: 330), CGFloat(240)), (CGSize(width: 300, height: 220), 190), (CGSize(width: 290, height: 300), 230),
                              (CGSize(width: 560, height: 360), 240), (CGSize(width: 1200, height: 600), 540)] {
            let s = try OffscreenRenderer.Session(panel: .vectorscope, size: size, scale: 2, theme: Theme(), settings: .init())
            try s.feed(frames)
            _ = try s.snapshotPNG()
            let r = try XCTUnwrap(s.renderer as? VectorscopeRenderer)
            XCTAssertGreaterThanOrEqual(r.fieldForTesting.width, least, "scope diameter at \(size)")
            let labels = s.renderer.textLayer.lastLabels.map(\.text)
            // Correlation, width and balance are on screen at every size.
            XCTAssertTrue(labels.contains { $0.hasPrefix("+0.") || $0.hasPrefix("\u{2212}0.") || $0 == "+1.00" }, "correlation at \(size): \(labels)")
            XCTAssertTrue(labels.contains("WIDTH"), "width at \(size)")
            XCTAssertTrue(labels.contains("BAL") || labels.contains("BALANCE"), "balance at \(size)")
        }
    }

    func testBandLabelsAreTwoLettersUnder480() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 3).suffix(30))
        for (width, expected) in [(460, "LM"), (420, "LM"), (560, "LoMid")] {
            let s = try OffscreenRenderer.Session(panel: .meters, size: CGSize(width: CGFloat(width), height: 330), scale: 2, theme: Theme(), settings: .init())
            try s.feed(frames)
            _ = try s.snapshotPNG()
            let labels = s.renderer.textLayer.lastLabels.map(\.text)
            XCTAssertTrue(labels.contains(expected) || (width >= 480 && labels.contains("Low mid")), "\(width): \(labels)")
        }
    }

    func testEmptyStateShowsNoGainAndNoPeakCard() throws {
        try RenderTestSupport.requireMetal()
        let silence = SyntheticFrames.silence(count: 60)
        for size in [CGSize(width: 1200, height: 600), CGSize(width: 460, height: 330)] {
            let scope = try OffscreenRenderer.Session(panel: .vectorscope, size: size, scale: 2, theme: Theme(), settings: .init())
            // A quiet passage first (the automatic gain climbs), then silence.
            var quiet = Array(RealFrames.demo(seconds: 2).suffix(60))
            for i in quiet.indices { quiet[i].stereo.scopePoints = quiet[i].stereo.scopePoints.map { $0 * 0.01 } }
            try scope.feed(quiet + silence)
            _ = try scope.snapshotPNG()
            let r = try XCTUnwrap(scope.renderer as? VectorscopeRenderer)
            XCTAssertLessThanOrEqual(r.gain, VectorscopeRenderer.maxGain)
            XCTAssertFalse(scope.renderer.textLayer.lastLabels.contains { $0.text.hasPrefix("gain") }, "no gain label over an empty scope")

            let spectrum = try OffscreenRenderer.Session(panel: .spectrum, size: size, scale: 2, theme: Theme(), settings: .init())
            try spectrum.feed(silence)
            _ = try spectrum.snapshotPNG()
            let labels = spectrum.renderer.textLayer.lastLabels.map(\.text)
            XCTAssertFalse(labels.contains("PEAK"), "no peak readout without a peak: \(labels)")
            XCTAssertFalse(labels.contains(Fmt.dash), "no row of dashes either")
        }
    }

    // MARK: Coordinator additions: no invented note names, lowest strong content

    func testABroadPeakShowsNoNoteAndOnlyTonalEntriesGetLabels() throws {
        try RenderTestSupport.requireMetal()
        var frames = Array(RealFrames.demo(seconds: 3).suffix(60))
        for i in frames.indices {
            // A broad hump is the strongest "peak": the analyzer gives it no note name and keeps it first in the list.
            let broad = PeakReading(frequencyHz: 52.3, levelDB: -22, noteName: "", cents: 0)
            frames[i].peak = broad
            frames[i].topPeaks = [broad, PeakReading(frequencyHz: 196, levelDB: -30, noteName: "G3", cents: 2),
                                  PeakReading(frequencyHz: 80, levelDB: -28, noteName: "", cents: 0),
                                  PeakReading(frequencyHz: 392, levelDB: -36, noteName: "G4", cents: -3)]
            frames[i].lowestStrongHz = 32.4
        }
        for size in [CGSize(width: 1200, height: 600), CGSize(width: 900, height: 420)] {
            let s = try OffscreenRenderer.Session(panel: .spectrum, size: size, scale: 2, theme: Theme(), settings: .init())
            try s.feed(frames)
            let pixels = try RenderTestSupport.decode(png: s.snapshotPNG())
            let labels = s.renderer.textLayer.lastLabels.map(\.text)
            XCTAssertTrue(labels.contains("52.3 Hz"), "\(labels)")
            XCTAssertFalse(labels.contains { $0.contains("\u{00A2}") }, "no cents for a broad peak: \(labels)")
            XCTAssertFalse(labels.contains("G\u{266F}1") || labels.contains("A1") || labels.contains("G1"), "no note made up from 52.3 Hz: \(labels)")
            XCTAssertTrue(labels.contains("G3") && labels.contains("G4"), "tonal entries are labeled: \(labels)")
            XCTAssertFalse(labels.contains("E2") || labels.contains("D\u{266F}2"), "the unnamed 80 Hz entry gets no note: \(labels)")
            // Lowest strong content: whole Hz, neutral color, and a tick under the x axis at 32 Hz.
            XCTAssertTrue(labels.contains("32 Hz"), "\(labels)")
            let r = try XCTUnwrap(s.renderer as? SpectrumRenderer)
            let plot = r.plotRectForTesting
            let tx = Int((plot.minX + CGFloat(log(Float(32.4) / 20) / log(Float(1000))) * plot.width) * 2), ty = Int((plot.maxY + 3.5) * 2)
            let tick = pixels.rgb(tx, ty), beside = pixels.rgb(tx + 12, ty)
            XCTAssertGreaterThan(tick.0 + tick.1 + tick.2, beside.0 + beside.1 + beside.2 + 200, "a tick under the axis at 32 Hz")
            // Neutral: the value's pixels are not red (round 4 drew it in the alarm-like hue of the lows).
            let box = try XCTUnwrap(s.renderer.textLayer.lastLabels.first { $0.text == "32 Hz" }).rect
            var red = 0, bright = 0
            for y in Int(box.minY * 2)...Int(box.maxY * 2) { for x in Int(box.minX * 2)...Int(box.maxX * 2) {
                let c = pixels.rgb(x, y); if max(c.0, c.1, c.2) > 140 { bright += 1; if c.0 > c.2 + 40 { red += 1 } }
            } }
            XCTAssertGreaterThan(bright, 20); XCTAssertEqual(red, 0, "the value is drawn in the neutral text color")
        }
    }

    // MARK: Missing 5: Side trace

    func testSideTraceHasALegendEntryAndDrawsInItsOwnHue() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 3).suffix(60))
        var on = OffscreenRenderer.Settings(); on.spectrum.showSide = true
        on.hover = CGPoint(x: 600, y: 300)
        let a = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: on)
        try a.feed(frames)
        let withSide = try RenderTestSupport.decode(png: a.snapshotPNG())
        XCTAssertTrue(a.renderer.textLayer.lastLabels.contains { $0.text == "Side" })
        XCTAssertTrue(a.renderer.textLayer.lastLabels.contains { $0.text.contains("Side  ") }, "the hover readout names the Side level")
        let b = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: .init())
        try b.feed(frames)
        let without = try RenderTestSupport.decode(png: b.snapshotPNG())
        XCTAssertFalse(b.renderer.textLayer.lastLabels.contains { $0.text == "Side" })
        // Magenta-violet pixels (#C77DFF: red and blue high, green lower) that are not there without the trace.
        func violet(_ p: RenderTestSupport.Pixels) -> Int {
            var n = 0
            for y in stride(from: 100, to: p.height - 80, by: 2) { for x in stride(from: 100, to: p.width - 40, by: 1) {
                let c = p.rgb(x, y); if c.2 > 170, c.0 > 120, c.1 < c.0 - 25, c.1 < c.2 - 70 { n += 1 }
            } }
            return n
        }
        XCTAssertGreaterThan(violet(withSide), violet(without) + 400)
    }

    // MARK: Item 11: text repaints only what changed

    func testTextLayerPaintsOnlyChangedItems() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 3).suffix(60))
        let s = try OffscreenRenderer.Session(panel: .meters, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: .init())
        try s.feed(frames)
        _ = try s.snapshotPNG()
        let layer = s.renderer.textLayer
        let all = layer.lastItemCount
        XCTAssertGreaterThan(all, 40)
        // Two redraws of the same content fill both bitmaps; the third has nothing to paint.
        s.renderer.refreshText(now: 100, force: true); s.renderer.refreshText(now: 101, force: true)
        s.renderer.refreshText(now: 102, force: true)
        XCTAssertEqual(layer.lastPaintedCount, 0, "unchanged text is not painted again")
        // One readout changes: only a few items are painted (both bitmaps catch up over two redraws).
        var f = frames[frames.count - 1]
        f.hostTime += 1; f.loudness.momentaryLUFS -= 3.3
        s.renderer.ingest(f)
        s.renderer.refreshText(now: 103, force: true)
        XCTAssertGreaterThan(layer.lastPaintedCount, 0)
        XCTAssertLessThan(layer.lastPaintedCount, all / 4, "a changed readout repaints its own rectangle, not the panel")
        // The picture is still right: compare with a fresh session fed the same frames.
        let png = try RenderTestSupport.decode(png: s.snapshotPNG())
        let fresh = try OffscreenRenderer.Session(panel: .meters, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: .init())
        try fresh.feed(frames + [f])
        let want = try RenderTestSupport.decode(png: fresh.snapshotPNG())
        var differing = 0
        for i in stride(from: 0, to: png.data.count, by: 4) where abs(Int(png.data[i]) - Int(want.data[i])) > 8 || abs(Int(png.data[i + 1]) - Int(want.data[i + 1])) > 8 { differing += 1 }
        XCTAssertLessThan(differing, 50, "incremental text equals a full repaint")
    }
}

/// The label tests read the strings a panel recorded. This one reads the PIXELS: a readout that is recorded but not painted
/// (round 5 had that bug for a moment: every number from the glyph table was missing, and all label tests passed) fails here.
final class NumeralPixelTests: XCTestCase {
    func testEveryRecordedLabelLeavesInkInThePicture() throws {
        try RenderTestSupport.requireMetal()
        let frames = Array(RealFrames.demo(seconds: 3).suffix(60))
        var target = OffscreenRenderer.Settings(); target.targetLUFS = -14
        for (kind, settings) in [(PanelKind.meters, target), (.spectrum, OffscreenRenderer.Settings()), (.vectorscope, .init()), (.spectrogram, .init())] {
            for size in [CGSize(width: 1200, height: 600), CGSize(width: 460, height: 330)] {
                let s = try OffscreenRenderer.Session(panel: kind, size: size, scale: 2, theme: Theme(), settings: settings)
                try s.feed(kind == .spectrum ? RealFrames.annotated(frames) : frames)
                let p = try RenderTestSupport.decode(png: s.snapshotPNG())
                let labels = s.renderer.textLayer.lastLabels
                XCTAssertFalse(labels.isEmpty)
                var numerals = 0
                for l in labels where l.text != Fmt.dash {
                    // Bright pixels inside the label's ink box. Text is 0.8 and more of white; the ground is dark navy.
                    // (Labels on a bright part of a plot pass trivially; most stand on the panel ground.)
                    let x0 = max(Int(l.rect.minX * 2), 0), x1 = min(Int(l.rect.maxX * 2), p.width - 1)
                    let y0 = max(Int(l.rect.minY * 2), 0), y1 = min(Int(l.rect.maxY * 2), p.height - 1)
                    guard x1 > x0, y1 > y0 else { continue }
                    var ink = 0
                    for y in y0...y1 { for x in x0...x1 { let c = p.rgb(x, y); if max(c.0, c.1, c.2) > 110 { ink += 1 } } }
                    // A digit of an 11 pt font inks about 25 pixels at 2x.
                    let glyphs = l.text.filter { $0 != " " }.count
                    XCTAssertGreaterThan(ink, glyphs * 6, "\(kind) \(Int(size.width)): \"\(l.text)\" at \(l.rect) is recorded but not painted")
                    if l.text.contains(where: \.isNumber) { numerals += 1 }
                }
                XCTAssertGreaterThan(numerals, 3, "\(kind): the panel shows numbers")
            }
        }
    }
}
