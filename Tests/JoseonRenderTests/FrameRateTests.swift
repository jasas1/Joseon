import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

final class FrameRateTests: XCTestCase {
    func testHighRefreshDoesNotSpeedUpCameraOrScopeDecay() throws {
        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let waterfall = try XCTUnwrap(SpectrogramRenderer(ctx: ctx, theme: Theme()))
        waterfall.mode = .waterfall
        let scope = try XCTUnwrap(VectorscopeRenderer(ctx: ctx, theme: Theme()))
        var frame = SyntheticFrames().next()
        frame.isSilent = false
        frame.stereo.scopePoints = [SIMD2<Float>(0.2, 0.3)]
        frame.hostTime = 10
        scope.ingest(frame, animationDelta: 0)
        waterfall.ingest(frame, animationDelta: 0)
        frame.isSilent = true
        // 60 analysis updates and 120 display updates per second. After 2.5 seconds the scope
        // should still be fading (seven 0.45 s time constants), and the camera must count 2.5 s.
        for tick in 1...300 {
            if tick.isMultiple(of: 2) {
                frame.hostTime = 10 + Double(tick) / 120
                scope.ingest(frame, animationDelta: 1.0 / 120)
                waterfall.ingest(frame, animationDelta: 1.0 / 120)
            } else {
                scope.idle(dt: 1.0 / 120)
                waterfall.idle(dt: 1.0 / 120)
            }
        }
        XCTAssertEqual(waterfall.waterfall.clock, 2.5, accuracy: 1e-8)
        XCTAssertTrue(scope.isAnimating, "extra display ticks must not shorten scope persistence")
        scope.idle(dt: 0.7)
        XCTAssertFalse(scope.isAnimating)
    }

    func testDisplayAndAccessibilityCaps() {
        for (preferred, screen, reduced, expected) in [
            (120, 120, false, 120), (120, 60, false, 60),
            (60, 120, false, 60), (30, 120, false, 30),
            (120, 120, true, 30), (120, 24, true, 24),
            (10, 120, false, 10),
        ] {
            let range = PanelView.frameRateRange(preferred: preferred, screenMaximum: screen, reduceMotion: reduced)
            XCTAssertEqual(range.preferred, Float(expected))
            XCTAssertEqual(range.maximum, Float(expected))
            XCTAssertLessThanOrEqual(range.minimum, range.maximum)
        }
    }

    /// Read the actual CAMetalDisplayLink, not just the computed preference: the old implementation
    /// computed 30/60 correctly but assigned 120 to every link.
    func testModesReachTheLiveLinkAndSurviveWaterfallSwitches() throws {
        try RenderTestSupport.requireMetal()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let frame = SyntheticFrames().next()
        let spectrum = SpectrumView(frameProvider: { frame })
        let scope = VectorscopeView(frameProvider: { frame })
        let spectrogram = SpectrogramView(frameProvider: { frame })
        let meters = MetersView(frameProvider: { frame })
        let timeline = TimelineView(frameProvider: { frame }, sessionProvider: { SessionSnapshot() })
        let panels: [PanelView] = [spectrum, scope, spectrogram, meters, timeline]
        for panel in panels {
            panel.isPaused = true
            panel.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
            window.contentView!.addSubview(panel)
        }
        let screenMax = window.screen?.maximumFramesPerSecond ?? 60
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        func expect(_ panel: PanelView, _ fps: Int, file: StaticString = #filePath, line: UInt = #line) {
            let cap = Float(min(fps, screenMax, reduced ? 30 : 120))
            XCTAssertEqual(panel.displayLinkFrameRateRange?.maximum, cap, file: file, line: line)
            XCTAssertEqual(panel.displayLinkFrameRateRange?.preferred, cap, file: file, line: line)
        }
        expect(spectrum, 60); expect(scope, 60)
        expect(spectrogram, 30); expect(meters, 30); expect(timeline, 30)
        panels.forEach { $0.refreshMode = .highRefresh }
        expect(spectrum, 120); expect(scope, 120)
        expect(spectrogram, 30); expect(meters, 30); expect(timeline, 30)
        spectrogram.mode = .waterfall
        expect(spectrogram, 120)
        spectrogram.syncOptions()
        expect(spectrogram, 120, line: #line)
        spectrogram.refreshMode = .balanced
        expect(spectrogram, 60)
        spectrogram.mode = .flat
        expect(spectrogram, 30)
        panels.forEach { $0.refreshMode = .balanced }
        expect(spectrum, 60); expect(scope, 60)
    }
}
