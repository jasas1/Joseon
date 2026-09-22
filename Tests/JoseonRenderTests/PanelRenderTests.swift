import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

final class PanelRenderTests: XCTestCase {
    private let size = CGSize(width: 480, height: 300)
    private lazy var frames = SyntheticFrames.sequence(count: 90)

    func testEveryPanelRendersAPNGOfTheRightSizeWithRealContent() throws {
        try RenderTestSupport.requireMetal()
        for kind in PanelKind.allCases {
            let data = try OffscreenRenderer.png(panel: kind, frames: frames, size: size, scale: 2)
            XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "\(kind) is not a PNG")
            let px = try RenderTestSupport.decode(png: data)
            XCTAssertEqual(px.width, 960, "\(kind)")
            XCTAssertEqual(px.height, 600, "\(kind)")
            XCTAssertGreaterThan(px.distinctColors, 200, "\(kind) looks flat")
            let first = px.rgb(0, 0)
            var different = 0
            for y in stride(from: 0, to: px.height, by: 7) {
                for x in stride(from: 0, to: px.width, by: 7) where px.rgb(x, y) != first { different += 1 }
            }
            XCTAssertGreaterThan(different, 500, "\(kind) is uniform")
        }
    }

    func testScaleOneGivesPointSizedImage() throws {
        try RenderTestSupport.requireMetal()
        let px = try RenderTestSupport.decode(png: OffscreenRenderer.png(panel: .meters, frames: frames, size: size, scale: 1))
        XCTAssertEqual(px.width, 480)
        XCTAssertEqual(px.height, 300)
    }

    func testSpectrogramOutputFollowsTheFrames() throws {
        try RenderTestSupport.requireMetal()
        var other = SyntheticFrames.Options()
        other.seed = 99
        other.levelDB = -18
        let a = try RenderTestSupport.decode(png: OffscreenRenderer.png(panel: .spectrogram, frames: frames, size: size))
        let again = try RenderTestSupport.decode(png: OffscreenRenderer.png(panel: .spectrogram, frames: frames, size: size))
        let b = try RenderTestSupport.decode(png: OffscreenRenderer.png(panel: .spectrogram, frames: SyntheticFrames.sequence(count: 90, options: other), size: size))
        XCTAssertEqual(a.data, again.data, "same frames must give the same picture")
        var diff = 0
        for i in stride(from: 0, to: a.data.count, by: 4) where abs(Int(a.data[i + 1]) - Int(b.data[i + 1])) > 8 { diff += 1 }
        XCTAssertGreaterThan(diff, 2000)
    }

    func testSpectrogramHistoryScrolls() throws {
        try RenderTestSupport.requireMetal()
        // More frames fill more of the time axis: the left part stays empty with a short history.
        let short = try RenderTestSupport.decode(png: OffscreenRenderer.png(panel: .spectrogram, frames: Array(frames.prefix(30)), size: size))
        let long = try RenderTestSupport.decode(png: OffscreenRenderer.png(panel: .spectrogram, frames: SyntheticFrames.sequence(count: 900), size: size))
        func lit(_ p: RenderTestSupport.Pixels) -> Int {
            var n = 0
            let y = p.height / 2
            for x in 0..<p.width { let c = p.rgb(x, y); if c.0 + c.1 + c.2 > 120 { n += 1 } }
            return n
        }
        XCTAssertGreaterThan(lit(long), lit(short) * 4)
    }

    func testVectorscopePersistenceNeedsHistory() throws {
        try RenderTestSupport.requireMetal()
        func light(_ count: Int) throws -> Int {
            let p = try RenderTestSupport.decode(png: OffscreenRenderer.png(panel: .vectorscope, frames: Array(frames.prefix(count)), size: CGSize(width: 300, height: 300)))
            var sum = 0
            for y in stride(from: 20, to: 360, by: 2) { for x in stride(from: 120, to: 480, by: 2) { sum += p.rgb(x, y).2 } }
            return sum
        }
        XCTAssertGreaterThan(try light(40), try light(1), "accumulated light must grow with the frames fed")
    }

    /// Contract: scope x = (R - L) / 2, positive = right. A right-only signal leans to the "R" label.
    func testVectorscopePutsARightOnlySignalOnTheRight() throws {
        try RenderTestSupport.requireMetal()
        var frame = frames[0]
        let points = (0..<1024).map { i -> SIMD2<Float> in
            let r = 0.6 * sin(Float(i) * 0.05)
            return SIMD2(r * 0.5, r * 0.5)
        }
        frame.stereo = StereoReading(correlation: 0, balance: 1, width: 1, bandActive: [Bool](repeating: false, count: 8), scopePoints: points)
        let sequence = (0..<30).map { k -> AnalysisFrame in var f = frame; f.hostTime += Double(k) / 60; return f }
        let session = try OffscreenRenderer.Session(panel: .vectorscope, size: CGSize(width: 300, height: 300), scale: 2, theme: Theme(), settings: .init())
        try session.feed(sequence)
        let png = try session.snapshotPNG()
        RenderTestSupport.write(png, "vectorscope-right-only.png")
        let p = try RenderTestSupport.decode(png: png)
        // Trace pixels (near white: not the grid, not the blue "L" or the orange "R") above the scope centre, left and
        // right of it. The field's place depends on the layout: ask the renderer.
        let field = try XCTUnwrap(session.renderer as? VectorscopeRenderer).fieldForTesting
        let cx = Int(field.midX * 2), cy = Int(field.midY * 2), half = Int(field.width)
        func light(_ xs: Range<Int>) -> Int {
            var sum = 0
            // The ramp is capped at 90 % luminance (critic r2 defect 10): the core is a light cyan, not white.
            for y in (cy - half * 7 / 10)..<(cy - 6) { for x in xs { let c = p.rgb(x, y); if c.0 > 60, c.1 > 185, c.2 > 200 { sum += 1 } } }
            return sum
        }
        XCTAssertEqual(p.width, 600)
        let left = light((cx - half * 8 / 10)..<(cx - 15)), right = light((cx + 15)..<(cx + half * 8 / 10))
        XCTAssertGreaterThan(right, 100, "the trace must be visible")
        XCTAssertGreaterThan(right, left * 10 + 10, "right-only signal drew left \(left), right \(right)")
    }

    func testMetersShowDashesUntilIntegratedIsValid() throws {
        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let r = try XCTUnwrap(PanelRenderer.make(kind: .meters, ctx: ctx, theme: Theme()))
        var f = frames[frames.count - 1]
        r.ingest(f)
        XCTAssertFalse(r.accessibilityValueText.contains("integrated no value"))
        f.loudness.isIntegratedValid = false
        f.hostTime += 1
        r.ingest(f)
        XCTAssertTrue(r.accessibilityValueText.contains("integrated no value"), r.accessibilityValueText)
        XCTAssertTrue(r.accessibilityValueText.contains("range no value"))
        XCTAssertTrue(r.accessibilityValueText.contains("PLR no value"))
    }

    func testSilenceShowsDashesNotMinus120() throws {
        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let r = try XCTUnwrap(PanelRenderer.make(kind: .meters, ctx: ctx, theme: Theme()))
        r.ingest(SyntheticFrames.silence(count: 1)[0])
        XCTAssertFalse(r.accessibilityValueText.contains("120"))
        XCTAssertEqual(Fmt.db(-120), Fmt.dash)
        XCTAssertEqual(Fmt.db(-14.23), "\u{2212}14.2")
    }

    func testAccessibilityValuesCarryTheNumbers() throws {
        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let f = frames[frames.count - 1]
        for kind in PanelKind.allCases {
            let r = try XCTUnwrap(PanelRenderer.make(kind: kind, ctx: ctx, theme: Theme()))
            r.ingest(f)
            XCTAssertFalse(r.accessibilityLabelText.isEmpty)
            XCTAssertTrue(r.accessibilityValueText.contains(where: \.isNumber), "\(kind): \(r.accessibilityValueText)")
        }
    }

    /// WCAG contrast ratio of two opaque sRGB colors.
    static func contrast(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        func lum(_ c: SIMD4<Float>) -> Float {
            func lin(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.x) + 0.7152 * lin(c.y) + 0.0722 * lin(c.z)
        }
        let la = lum(a), lb = lum(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testIncreaseContrastStrengthensGridAndText() {
        let normal = Palette(theme: Theme(), highContrast: false), strong = Palette(theme: Theme(), highContrast: true)
        XCTAssertGreaterThan(strong.grid.w, normal.grid.w * 1.5)
        // Secondary text is opaque in both; Increase Contrast makes it lighter. Both keep 7:1 on the background.
        XCTAssertGreaterThan(strong.textDim.y, normal.textDim.y)
        XCTAssertGreaterThan(strong.gridMajor.w, normal.gridMajor.w * 1.5)
        for c in [normal.textDim, normal.textFaint] { XCTAssertGreaterThanOrEqual(Self.contrast(c, normal.background), 7) }
        XCTAssertEqual(strong.text, SIMD4<Float>(1, 1, 1, 1))
    }

    func testViewsKeepTheirPublicSurface() {
        let provider: FrameProvider = { AnalysisFrame(spectrum: .silent(binCount: 64)) }
        let views: [PanelView] = [SpectrumView(frameProvider: provider), SpectrogramView(frameProvider: provider),
                                  VectorscopeView(frameProvider: provider), MetersView(frameProvider: provider)]
        XCTAssertEqual(views.map(\.kind), [.spectrum, .spectrogram, .vectorscope, .meters])
        for v in views {
            v.frame = CGRect(x: 0, y: 0, width: 400, height: 240)
            v.isPaused = true
            v.theme = Theme()
            XCTAssertTrue(v.isAccessibilityElement())
            XCTAssertNotNil(v.accessibilityLabel())
            XCTAssertNotNil(v.accessibilityValue())
        }
    }

    func testNoteNames() {
        XCTAssertEqual(Fmt.note(forHz: 440)?.name, "A4")
        XCTAssertEqual(Fmt.note(forHz: 415.3)?.name, "G\u{266F}4")
        XCTAssertEqual(Fmt.note(forHz: 261.63)?.name, "C4")
        XCTAssertEqual(Fmt.note(forHz: 445)!.cents, 19.56, accuracy: 0.1)
    }

    func testResamplerIsSmoothBetweenBins() {
        // 64 bins onto 1024 points: no two neighbors may jump like a stair step.
        let s = SpectrumReading.silent(binCount: 64)
        let values = (0..<64).map { -60 + 25 * sin(Float($0) * 0.35) }
        var out = [Float](repeating: 0, count: 1024)
        out.withUnsafeMutableBufferPointer {
            CurveResampler.resample(values, frequencies: s.frequencies, axis: LogAxis(minHz: 10, maxHz: 24_000), minDB: -96, maxDB: 0, into: $0.baseAddress!, count: 1024)
        }
        var maxStep: Float = 0
        for i in 1..<1024 { maxStep = max(maxStep, abs(out[i] - out[i - 1])) }
        XCTAssertLessThan(maxStep, 0.012)
    }

    func testFrameCostIsWithinBudget() throws {
        try RenderTestSupport.requireMetal()
        var o = SyntheticFrames.Options()
        o.includeHeadphone = true     // worst case for the spectrum: every curve is on
        let many = SyntheticFrames.sequence(count: 120, options: o)
        for kind in PanelKind.allCases {
            let cost = try OffscreenRenderer.measure(panel: kind, frames: many, size: CGSize(width: 1200, height: 600), scale: 2, iterations: 90)
            print(String(format: "FRAMECOST %@ gpu %.3f ms  cpu-encode %.3f ms  text %.3f ms", kind.rawValue, cost.gpuMS, cost.cpuEncodeMS, cost.textMS))
            XCTAssertLessThan(cost.gpuMS, 2.0, "\(kind) GPU time over the 2 ms budget")
        }
    }
}
