import XCTest
import JoseonCore
@testable import JoseonRender

/// Critic r2 defect 10: the goniometer's core was near white and the trace touched both tips.
final class VectorscopeGainTests: XCTestCase {
    private func frame(amplitude a: Float, time: Double) -> AnalysisFrame {
        var f = AnalysisFrame(hostTime: time, spectrum: .silent(binCount: 64), isSilent: false)
        // Mono sine: x = 0, y = (L + R) / 2.
        let pts = (0..<1024).map { i in SIMD2<Float>(0, a * sin(Float(i) * 0.37)) }
        f.stereo = StereoReading(correlation: 1, scopePoints: pts)
        return f
    }

    func testGainPutsThePercentileAt85PercentAndNeverLetsTheTraceReachTheTips() throws {
        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let r = try XCTUnwrap(PanelRenderer.make(kind: .vectorscope, ctx: ctx, theme: Theme()) as? VectorscopeRenderer)
        r.setLayout(size: CGSize(width: 560, height: 360), scale: 2)
        var t = 0.0
        func feed(_ a: Float, seconds: Double) {
            for _ in 0..<Int(seconds * 60) {
                t += 1.0 / 60
                r.ingest(frame(amplitude: a, time: t))
                XCTAssertLessThanOrEqual(r.gain * a, 0.97, "the loudest sample stays inside the diamond (amplitude \(a))")
            }
        }
        feed(0.3, seconds: 1)
        XCTAssertEqual(r.gain * 0.3, 0.85, accuracy: 0.03, "99.5th percentile at 85 % of the radius")
        feed(0.9, seconds: 0.1)            // a kick: the gain falls in the same frame
        feed(0.3, seconds: 1.0)            // held: a gap between kicks does not pump the figure
        XCTAssertLessThanOrEqual(r.gain * 0.9, 0.97)
        feed(0.3, seconds: 12)             // then it opens up again
        XCTAssertEqual(r.gain * 0.3, 0.85, accuracy: 0.05)
    }

    func testTheDensityRampStopsAt90PercentLuminance() {
        let lut = Palette(theme: Theme(), highContrast: false).scopeLUT()
        let brightest = lut.map { 0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z }.max()!
        XCTAssertLessThanOrEqual(brightest, 0.905)
        XCTAssertGreaterThan(brightest, 0.85)
    }
}

/// Missing items 1 and 4 of critic r2: headphone stress on the plot, top peaks with note names, lowest strong content.
final class SpectrumAnnotationTests: XCTestCase {
    private func render(_ frames: [AnalysisFrame], stress: Bool = true) throws -> (pixels: RenderTestSupport.Pixels, labels: [String]) {
        var settings = OffscreenRenderer.Settings(); settings.showStressBands = stress
        let s = try OffscreenRenderer.Session(panel: .spectrum, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: settings)
        try s.feed(frames)
        let px = try RenderTestSupport.decode(png: s.snapshotPNG())
        return (px, s.renderer.textLayer.lastLabels.map { $0.text })
    }

    func testStressSpansAreShadedAndLabeledAndTheOptionTurnsThemOff() throws {
        try RenderTestSupport.requireMetal()
        let frames = RealFrames.annotated(Array(RealFrames.demo(seconds: 3).suffix(60)))
        let on = try render(frames), off = try render(frames, stress: false)
        // The flags of the fixture read their numbers from the fixture's curves: ask it for the labels.
        let flags = SyntheticFrames.demoStressFlags()
        let treble = try XCTUnwrap(flags.first { $0.id == "demo-treble" }), sub = try XCTUnwrap(flags.first { $0.id == "demo-sub" })
        let span = try XCTUnwrap(treble.frequencyRangeHz)
        let probeHz = (span.lowerBound * span.upperBound).squareRoot() * 1.06
        XCTAssertTrue(on.labels.contains(treble.plotLabel), "\(on.labels)")
        XCTAssertTrue(on.labels.contains(sub.plotLabel))
        XCTAssertFalse(off.labels.contains(treble.plotLabel))
        // The treble span is red-tinted where the plot is empty (30 % down the plot); 1 kHz is not.
        func x(_ hz: Float) -> Int { Int((44 + CGFloat(log(hz / 20) / log(Float(1000))) * (1200 - 44 - 40)) * 2) }
        let y = 2 * 200
        let inside = on.pixels.rgb(x(probeHz), y), insideOff = off.pixels.rgb(x(probeHz), y), outside = on.pixels.rgb(x(1000) + 9, y)
        XCTAssertGreaterThan(inside.0, insideOff.0 + 12, "red wash inside the span: \(inside) against \(insideOff)")
        XCTAssertLessThan(abs(outside.0 - off.pixels.rgb(x(1000) + 9, y).0), 4)
    }

    func testTopPeaksGetNoteNamesAndTheHeaderShowsTheLowestStrongContent() throws {
        try RenderTestSupport.requireMetal()
        let plain = Array(RealFrames.demo(seconds: 3).suffix(60))
        let annotated = RealFrames.annotated(plain)
        let last = try XCTUnwrap(annotated.last)
        XCTAssertGreaterThan(last.topPeaks.count, 2)
        let labels = try render(annotated).labels
        var drawn = 0
        for pk in last.topPeaks.dropFirst() where labels.contains(Fmt.prettyNote(pk.noteName)) { drawn += 1 }
        XCTAssertGreaterThanOrEqual(drawn, 2, "note names of the secondary peaks: \(labels)")
        XCTAssertTrue(labels.contains("lowest strong content:"))
        // Whole Hz since round 5: the measure is not finer than that ("32 Hz", not "32.4 Hz").
        XCTAssertTrue(labels.contains(SpectrumRenderer.wholeHz(last.lowestStrongHz)), "\(labels)")
        // Without the analyzer extras nothing is invented.
        let bare = try render(plain).labels
        XCTAssertFalse(bare.contains("lowest strong content:"))
    }

    func testFrequenciesHaveOneDecimal() {
        XCTAssertEqual(Fmt.hz(97.9049), "97.9 Hz")
        XCTAssertEqual(Fmt.hz(1046.5), "1046.5 Hz")
        XCTAssertEqual(Fmt.hz(12_543), "12.5 kHz")
    }
}
