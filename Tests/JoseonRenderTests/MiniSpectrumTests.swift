import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

final class MiniSpectrumTests: XCTestCase {
    private let size = CGSize(width: 64, height: 18)

    private func frame(levelDB: Float) -> AnalysisFrame {
        var o = SyntheticFrames.Options()
        o.levelDB = levelDB
        return SyntheticFrames.sequence(count: 30, options: o)[29]
    }

    private func alpha(_ image: NSImage) throws -> Int {
        RenderTestSupport.decode(try XCTUnwrap(RenderTestSupport.cgImage(image))).alphaSum
    }

    func testSizeAndTemplate() throws {
        let image = MiniSpectrumRenderer().image(for: frame(levelDB: 0), size: size, scale: 2)
        XCTAssertEqual(image.size, size)
        XCTAssertTrue(image.isTemplate)
        let cg = try XCTUnwrap(RenderTestSupport.cgImage(image))
        XCTAssertEqual(cg.width, 128)
        XCTAssertEqual(cg.height, 36)
    }

    func testAlphaCoverageGrowsWithLevel() throws {
        // Fixed range: louder = more ink. A fresh renderer per level, so no ballistics carry over.
        var last = -1
        for level in [-60, -40, -20, 0] as [Float] {
            let fixed = MiniSpectrumRenderer()
            fixed.adaptiveRange = false
            let a = try alpha(fixed.image(for: frame(levelDB: level), size: size, scale: 2))
            XCTAssertGreaterThan(a, last, "level \(level)")
            last = a
        }
        // Adaptive range: quiet music (40 dB down) still fills a good part of the picture, and music at any
        // normal level gives the same picture.
        let loud = try alpha(MiniSpectrumRenderer().image(for: frame(levelDB: 0), size: size, scale: 2))
        let mid = try alpha(MiniSpectrumRenderer().image(for: frame(levelDB: -20), size: size, scale: 2))
        let quiet = try alpha(MiniSpectrumRenderer().image(for: frame(levelDB: -40), size: size, scale: 2))
        XCTAssertEqual(Double(mid), Double(loud), accuracy: Double(loud) * 0.02)
        XCTAssertGreaterThan(Double(quiet), Double(loud) * 0.6)
    }

    func testAccentModeIsColoredAndNotATemplate() throws {
        let renderer = MiniSpectrumRenderer()
        renderer.accentColor = NSColor(srgbRed: 1, green: 0.4, blue: 0, alpha: 1)
        let image = renderer.image(for: frame(levelDB: 0), size: size, scale: 2)
        XCTAssertFalse(image.isTemplate)
        let px = RenderTestSupport.decode(try XCTUnwrap(RenderTestSupport.cgImage(image)))
        let (r, g, b) = px.rgb(64, 35)          // bottom row = hairline, always opaque
        XCTAssertEqual(r, 255, accuracy: 2)
        XCTAssertEqual(g, 102, accuracy: 3)
        XCTAssertEqual(b, 0, accuracy: 2)
        renderer.accentColor = nil
        XCTAssertTrue(renderer.image(for: frame(levelDB: 0), size: size, scale: 2).isTemplate)
    }

    func testColumnCountFollowsWidth() {
        let r = MiniSpectrumRenderer()
        // One column per device pixel: the column edges sit on whole pixels at 1x and at 2x.
        XCTAssertEqual(r.columnCount(widthPoints: 44, pixelWidth: 88), 88)
        XCTAssertEqual(r.columnCount(widthPoints: 64, pixelWidth: 128), 128)
        XCTAssertEqual(r.columnCount(widthPoints: 96, pixelWidth: 192), 192)
        XCTAssertEqual(r.columnCount(widthPoints: 44, pixelWidth: 44), 44)
        r.columnPixels = 2
        XCTAssertEqual(r.columnCount(widthPoints: 64, pixelWidth: 128), 64)
        r.scalesBandCountWithWidth = false
        r.bandCount = 60
        XCTAssertEqual(r.columnCount(widthPoints: 44, pixelWidth: 88), 60)
        XCTAssertEqual(r.columnCount(widthPoints: 44, pixelWidth: 44), 44)      // never more than one per pixel
    }

    /// A frame with a flat floor and chosen tones, on the log frequency grid of the analyzer.
    private func toneFrame(tones: [(hz: Float, db: Float)], floorDB: Float = -70, edgeShelfDB: Float? = nil) -> AnalysisFrame {
        let bins = 1024
        let freqs = (0..<bins).map { Float(10 * pow(2400.0, Double($0) / Double(bins - 1))) }
        var mid = [Float](repeating: floorDB, count: bins)
        for (hz, db) in tones {
            // A tone as the analyzer shows it: a main lobe about 3% wide with steep skirts.
            for i in 0..<bins {
                let cents = abs(1200 * log2(freqs[i] / hz))
                mid[i] = max(mid[i], db - cents * 0.35)
            }
        }
        if let edgeShelfDB { for i in 0..<bins where freqs[i] > 3000 { mid[i] = edgeShelfDB } }
        let spectrum = SpectrumReading(frequencies: freqs, left: mid, right: mid, mid: mid, side: mid, peakHold: mid, average: mid)
        return AnalysisFrame(hostTime: 500, spectrum: spectrum, isSilent: false)
    }

    private func heights(_ image: NSImage) throws -> (px: RenderTestSupport.Pixels, h: [Int]) {
        let px = RenderTestSupport.decode(try XCTUnwrap(RenderTestSupport.cgImage(image)))
        let h = (0..<px.width).map { x in (0..<px.height).filter { px.data[($0 * px.width + x) * 4 + 3] > 127 }.count }
        return (px, h)
    }

    func testShortShapePreservingTaperAtTheRightEdge() throws {
        // A bright top end up to the last column. The taper is two device pixels and it scales the data:
        // 1/3 and 2/3 of the shelf, then the shelf itself. No long ramp that looks the same on every picture.
        let f = toneFrame(tones: [(100, -20)], edgeShelfDB: -20)
        for scale in [1, 2] as [CGFloat] {
            let flat = MiniSpectrumRenderer()
            flat.tiltDBPerOctave = 0            // a level shelf stays level: the taper is the only slope
            let (px, h) = try heights(flat.image(for: f, size: size, scale: scale))
            let w = px.width, hair = Int(scale)
            let plateau = h[w - 1 - Int(8 * scale)] - hair
            XCTAssertGreaterThan(plateau, Int(10 * scale), "the shelf is high (scale \(scale))")
            XCTAssertEqual(Double(h[w - 1] - hair), Double(plateau) / 3, accuracy: 1.01, "last column (scale \(scale))")
            XCTAssertEqual(Double(h[w - 2] - hair), Double(plateau) * 2 / 3, accuracy: 1.01, "second last column (scale \(scale))")
            // From the third column on the picture is the data.
            for x in (w - Int(8 * scale))..<(w - 2) { XCTAssertEqual(h[x] - hair, plateau, accuracy: 1, "x \(x) scale \(scale)") }
            // No full-height wall at the border: no single step larger than half of the shelf.
            for x in (w - 3)..<w { XCTAssertLessThanOrEqual(h[x - 1] - h[x], plateau / 2 + 1, "x \(x) scale \(scale)") }
        }
    }

    func testTaperScalesTheDataItDoesNotReplaceIt() throws {
        // Two different top ends give two different endings: the last columns follow the data.
        let high = MiniSpectrumRenderer(), low = MiniSpectrumRenderer()
        high.adaptiveRange = false; low.adaptiveRange = false
        high.tiltDBPerOctave = 0; low.tiltDBPerOctave = 0
        _ = high.image(for: toneFrame(tones: [(100, -20)], edgeShelfDB: -20), size: size, scale: 2)
        _ = low.image(for: toneFrame(tones: [(100, -20)], edgeShelfDB: -50), size: size, scale: 2)
        for k in [127, 126] {
            XCTAssertEqual(high.shown[k] / high.shown[120], low.shown[k] / low.shown[120], accuracy: 0.01, "column \(k): the same gain on both")
            XCTAssertGreaterThan(high.shown[k], low.shown[k] * 1.5)
        }
        XCTAssertEqual(high.shown[125], high.shown[120], accuracy: 0.001, "the third column is not tapered")
    }

    /// A music-like spectrum on the analyzer grid, not the demo signal: a bed that falls 4.5 dB per octave from
    /// −20 dBFS at 60 Hz (steeper than pink noise, like most masters), a roll-off below 60 Hz, and three harmonic
    /// stacks 12 dB above the bed. `engineTilt` tilts the data the way the engine's Tilt setting does (pivot 1 kHz).
    static func musicFrame(engineTilt: Float = 0) -> AnalysisFrame {
        let bins = 1024
        let freqs = (0..<bins).map { Float(10 * pow(2400.0, Double($0) / Double(bins - 1))) }
        func bed(_ hz: Float) -> Float { hz >= 60 ? -20 - 4.5 * log2(hz / 60) : -20 - 12 * log2(60 / hz) }
        var mid = freqs.map(bed)
        for fundamental in [110, 196, 329.6] as [Float] {
            for k in 1...8 {
                let hz = fundamental * Float(k), top = bed(hz) + 12
                for i in 0..<bins { mid[i] = max(mid[i], top - abs(1200 * log2(freqs[i] / hz)) * 0.35) }
            }
        }
        for i in 0..<bins { mid[i] += engineTilt * log2(freqs[i] / 1000) }
        let spectrum = SpectrumReading(frequencies: freqs, left: mid, right: mid, mid: mid, side: mid, peakHold: mid, average: mid)
        return AnalysisFrame(hostTime: 500, spectrum: spectrum, isSilent: false)
    }

    func testMusicLikeSpectrumFillsTheTopOfTheBand() throws {
        // Critic round 4, defect 9: real music was a bass blob and a flat 2 px line for the top 60 % of the width.
        for scale in [1, 2] as [CGFloat] {
            let r = MiniSpectrumRenderer()
            let (px, h) = try heights(r.image(for: Self.musicFrame(), size: size, scale: scale))
            let n = px.width, hair = Int(scale), usable = px.height - 1 - hair
            let first2k = try XCTUnwrap((0..<n).first { r.minHz * pow(r.maxHz / r.minHz, (Float($0) + 0.5) / Float(n)) > 2000 })
            XCTAssertLessThan(first2k, n * 7 / 10, "2 kHz and up is more than 30 % of the width")
            // Every column above 2 kHz, except the two the edge taper scales down.
            for x in first2k..<(n - 2) {
                XCTAssertGreaterThanOrEqual(r.shown[x], 0.25, "column \(x) scale \(scale)")
                XCTAssertGreaterThanOrEqual(h[x] - hair, usable / 4, "pixel column \(x) scale \(scale)")
            }
            // The bass does not own the picture: the bed at 100 Hz and the bed at 8 kHz are about the same height.
            let at = { (hz: Float) in Int(Float(n) * log(hz / r.minHz) / log(r.maxHz / r.minHz)) }
            XCTAssertEqual(r.shown[at(8000)], r.shown[at(90)], accuracy: 0.12)
            // The last untapered columns are the data: the bed, not a ramp to the baseline.
            XCTAssertEqual(r.shown[n - 3], r.shown[n - 10], accuracy: 0.05)
        }
    }

    func testOwnTiltDoesNotStackOnTheEngineTilt() {
        // The engine tilt is in the data. The renderer tilt goes down by it: the same picture for every Tilt setting.
        XCTAssertEqual(MiniSpectrumRenderer().tiltDBPerOctave, 4.5)
        XCTAssertEqual(MiniSpectrumRenderer().adaptiveWindowDB, 48)
        let plain = MiniSpectrumRenderer()
        _ = plain.image(for: Self.musicFrame(), size: size, scale: 2)
        for engineTilt in [3, 4.5] as [Float] {
            let r = MiniSpectrumRenderer()
            r.tiltDBPerOctave = MiniSpectrumRenderer.tilt(engineTilt: engineTilt)
            XCTAssertEqual(r.tiltDBPerOctave + engineTilt, 4.5)
            _ = r.image(for: Self.musicFrame(engineTilt: engineTilt), size: size, scale: 2)
            for x in 0..<128 { XCTAssertEqual(r.shown[x], plain.shown[x], accuracy: 0.01, "column \(x) engine tilt \(engineTilt)") }
        }
    }

    func testAToneIsALobeNotABox() throws {
        // A tone between two columns: both may share the top, but the next columns are shoulders, not the floor
        // and not the top. Round 4 (maximum per column) gave a top of two or three equal columns with vertical sides.
        for hz in [220, 233, 440, 452, 1000, 1037] as [Float] {
            let r = MiniSpectrumRenderer()
            _ = r.image(for: toneFrame(tones: [(hz, -20)]), size: CGSize(width: 96, height: 18), scale: 2)
            let shown = Array(r.shown[0..<192])
            let peak = shown.max()!, c = shown.firstIndex(of: peak)!
            let atTop = shown.filter { $0 > peak * 0.97 }.count
            XCTAssertLessThanOrEqual(atTop, 2, "\(hz) Hz: \(atTop) columns at the top")
            let floor = shown[c + 12]
            for side in [c - 2, c + 2] {
                // Two columns from the top: a shoulder between the floor and the top.
                XCTAssertLessThan(shown[side], peak * 0.9, "\(hz) Hz")
            }
            let shoulders = [shown[c - 1], shown[c + 1]].max()!
            XCTAssertGreaterThan(shoulders, floor + (peak - floor) * 0.25, "\(hz) Hz: the lobe has a shoulder")
        }
    }

    func testAThinPeakStaysThinAndHasSlopedFlanks() throws {
        // The silhouette runs through the column centers: a tone is at most 3 device pixels wide at half of its
        // height above the floor, and its flanks are slopes (partly covered pixels), not the sides of a box.
        let f = toneFrame(tones: [(440, -20), (1000, -24), (3000, -30)])
        let (px, h) = try heights(MiniSpectrumRenderer().image(for: f, size: size, scale: 2))
        let floor = h[33]                       // 150 Hz: between the edge and the first tone
        for hz in [440, 1000, 3000] as [Float] {
            let c = Int(Float(px.width) * log(hz / 30) / log(20_000 / 30))
            let peak = h[(c - 2)...(c + 2)].max()!
            XCTAssertGreaterThan(peak, floor + 6)
            let half = floor + (peak - floor) / 2
            let wide = ((c - 8)...(c + 8)).filter { h[$0] > half }.count
            XCTAssertLessThanOrEqual(wide, 3, "\(hz) Hz is \(wide) px wide at half height")
            let partial = ((c - 3)...(c + 3)).reduce(0) { sum, x in
                sum + (0..<px.height).filter { let a = px.data[($0 * px.width + x) * 4 + 3]; return a > 8 && a < 247 }.count
            }
            XCTAssertGreaterThan(partial, 4, "\(hz) Hz: the flanks are antialiased slopes")
        }
    }

    func testNearbyTonesKeepAValleyAndTheirOwnTops() throws {
        // 220 / 277 / 330 Hz at almost the same level: three peaks, not one flat-topped box.
        let f = toneFrame(tones: [(220, -23), (277.2, -26), (329.6, -26)])
        for width in [44, 64, 96] as [CGFloat] {
            let (_, h) = try heights(MiniSpectrumRenderer().image(for: f, size: CGSize(width: width, height: 18), scale: 2))
            func x(_ hz: Float) -> Int { Int(Float(h.count) * log(hz / 30) / log(20_000 / 30)) }
            let p1 = h[(x(220) - 1)...(x(220) + 1)].max()!, p2 = h[(x(277.2) - 1)...(x(277.2) + 1)].max()!
            let valley = h[x(220)...x(277.2)].min()!
            XCTAssertLessThan(valley, min(p1, p2) - 6, "width \(width): valley \(valley), peaks \(p1) \(p2)")
            XCTAssertGreaterThan(p1, p2, "the louder tone is taller: the knee does not flatten the top")
        }
    }

    func testBitmapIsLayerNativeBGRA() throws {
        let renderer = MiniSpectrumRenderer()
        renderer.accentColor = NSColor(srgbRed: 1, green: 0.4, blue: 0, alpha: 1)
        let cg = try XCTUnwrap(renderer.cgImage(for: frame(levelDB: 0), size: size, scale: 2))
        XCTAssertEqual(cg.alphaInfo, .premultipliedFirst)
        XCTAssertEqual(cg.bitmapInfo.intersection(.byteOrderMask), .byteOrder32Little)
        // Memory order B, G, R, A on the opaque hairline (last row of the bitmap = bottom).
        let data = try XCTUnwrap(cg.dataProvider?.data as Data?)
        let o = (cg.height - 1) * cg.bytesPerRow + 64 * 4
        XCTAssertEqual(Int(data[o]), 0, accuracy: 2)
        XCTAssertEqual(Int(data[o + 1]), 102, accuracy: 3)
        XCTAssertEqual(Int(data[o + 2]), 255, accuracy: 2)
        XCTAssertEqual(data[o + 3], 255)
    }

    func testFastAttackAndAbout150msRelease() throws {
        let music = SyntheticFrames.sequence(count: 60)
        let renderer = MiniSpectrumRenderer()
        for k in stride(from: 1, to: 60, by: 2) { _ = renderer.image(for: music[k], size: size, scale: 2) }
        let before = renderer.shown.max() ?? 0
        XCTAssertGreaterThan(before, 0.5)
        // Silence from here on. The frame clock goes on at 30 Hz.
        var t = music[59].hostTime
        func silent() -> AnalysisFrame { t += 1.0 / 30; var f = SyntheticFrames.silence(count: 1)[0]; f.hostTime = t; return f }
        for _ in 0..<5 { _ = renderer.image(for: silent(), size: size, scale: 2) }          // 167 ms
        let after = renderer.shown.max() ?? 0
        XCTAssertEqual(after / before, exp(-0.1667 / 0.15), accuracy: 0.03)
        for _ in 0..<30 { _ = renderer.image(for: silent(), size: size, scale: 2) }         // one more second
        let image = renderer.image(for: silent(), size: size, scale: 2)
        XCTAssertEqual(try alpha(image), 128 * 2 * 255, "back to the hairline")
        // Attack: music after silence is at full height on the first frame.
        var first = music[59]
        first.hostTime = t + 1.0 / 30
        _ = renderer.image(for: first, size: size, scale: 2)
        XCTAssertGreaterThan(renderer.shown.max() ?? 0, 0.5)
    }

    func testAdaptiveRangeDoesNotPump() {
        let music = SyntheticFrames.sequence(count: 480)       // 8 s, kick every 0.5 s
        let renderer = MiniSpectrumRenderer()
        var lo: Float = 1000, hi: Float = -1000
        for k in stride(from: 1, to: 480, by: 2) {
            _ = renderer.image(for: music[k], size: size, scale: 2)
            if k > 180, let c = renderer.ceilingDB { lo = min(lo, c); hi = max(hi, c) }
        }
        print(String(format: "MINIRANGE ceiling %.2f ... %.2f dB", lo, hi))
        XCTAssertLessThan(hi - lo, 2.5)
    }

    func testNoFullHeightWallAtTheLeftEdge() throws {
        // A shelf below 30 Hz as high as the music: the first two columns are scaled to 1/3 and 2/3.
        var f = frame(levelDB: 0)
        let top = f.spectrum.mid.max() ?? -20
        for i in 0..<f.spectrum.mid.count where f.spectrum.frequencies[i] < 40 { f.spectrum.mid[i] = top }
        let renderer = MiniSpectrumRenderer()
        let px = RenderTestSupport.decode(try XCTUnwrap(RenderTestSupport.cgImage(renderer.image(for: f, size: size, scale: 2))))
        func height(_ x: Int) -> Int { (0..<36).filter { px.data[($0 * 128 + x) * 4 + 3] > 127 }.count - 2 }
        XCTAssertEqual(renderer.shown[0], renderer.shown[2] / 3, accuracy: 0.02)
        XCTAssertEqual(renderer.shown[1], renderer.shown[2] * 2 / 3, accuracy: 0.02)
        XCTAssertLessThan(height(0), height(1))
        XCTAssertLessThan(height(1), height(2))
        XCTAssertLessThanOrEqual(height(0), height(2) / 2)
    }

    func testSilenceIsAFlatHairline() throws {
        let image = MiniSpectrumRenderer().image(for: SyntheticFrames.silence(count: 1)[0], size: size, scale: 2)
        let px = RenderTestSupport.decode(try XCTUnwrap(RenderTestSupport.cgImage(image)))
        // Exactly the bottom point (2 pixel rows at 2x) is opaque, nothing else.
        XCTAssertEqual(px.alphaSum, 128 * 2 * 255)
        XCTAssertEqual(px.data[(35 * 128 + 5) * 4 + 3], 255)
        XCTAssertEqual(px.data[(10 * 128 + 5) * 4 + 3], 0)
    }

    func testRenderCost() {
        let renderer = MiniSpectrumRenderer()
        let f = frame(levelDB: 0)
        _ = renderer.image(for: f, size: size, scale: 2)
        let runs = 400
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<runs { _ = renderer.image(for: f, size: size, scale: 2) }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(runs)
        print(String(format: "MINICOST %.4f ms per call", ms))
        XCTAssertLessThan(ms, 0.1)
    }

    /// The real use: a new frame on every call (ballistics and range move), at the widest size, in accent mode.
    func testRenderCostOnMovingFrames() {
        let frames = SyntheticFrames.sequence(count: 240)
        let renderer = MiniSpectrumRenderer()
        renderer.accentColor = .orange
        let wide = CGSize(width: 96, height: 18)
        _ = renderer.image(for: frames[0], size: wide, scale: 2)
        let t0 = CFAbsoluteTimeGetCurrent()
        for round in 0..<4 {
            for k in 1..<240 {
                var f = frames[k]
                f.hostTime += Double(round) * 4
                _ = renderer.image(for: f, size: wide, scale: 2)
            }
        }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(4 * 239)
        print(String(format: "MINICOST-MOVING %.4f ms per call (96 pt, accent)", ms))
        XCTAssertLessThan(ms, 0.1)
    }

    func testRenderPerformance() {
        let renderer = MiniSpectrumRenderer()
        let f = frame(levelDB: 0)
        measure {
            for _ in 0..<100 { _ = renderer.image(for: f, size: size, scale: 2) }
        }
    }
}
