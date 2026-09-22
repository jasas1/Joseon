import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Opens a real window for a moment. Off by default: set JOSEON_LIVE_VIEW_TEST=1 to run it.
final class LiveViewTests: XCTestCase {
    func testPanelsDrawInAWindowAndPause() throws {
        guard ProcessInfo.processInfo.environment["JOSEON_LIVE_VIEW_TEST"] == "1" else { throw XCTSkip("Set JOSEON_LIVE_VIEW_TEST=1") }
        try RenderTestSupport.requireMetal()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        PanelView.ignoresOcclusionForTesting = true
        defer { PanelView.ignoresOcclusionForTesting = false }
        let generator = SyntheticFrames()
        var latest = generator.next()
        let provider: FrameProvider = { latest }
        let views: [PanelView] = [SpectrumView(frameProvider: provider), SpectrogramView(frameProvider: provider),
                                  VectorscopeView(frameProvider: provider), MetersView(frameProvider: provider)]
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 960, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 640))
        for (i, v) in views.enumerated() {
            v.frame = CGRect(x: CGFloat(i % 2) * 480, y: CGFloat(i / 2) * 320, width: 480, height: 320)
            content.addSubview(v)
        }
        window.contentView = content
        window.orderFrontRegardless()

        let end = Date().addingTimeInterval(1.5)
        while Date() < end {
            latest = generator.next()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(1.0 / 60.0))
        }
        print("LIVEVIEW occlusion visible:", window.occlusionState.contains(.visible), "isVisible:", window.isVisible, "screen:", window.screen?.localizedName ?? "nil", "debug:", views[0].debugRunState)
        let counts = views.map(\.drawnFrameCount)
        print("LIVEVIEW frames in 1.5 s:", counts, "gpu ms:", views.map { String(format: "%.3f", $0.lastGPUFrameTime * 1000) })
        if counts.allSatisfy({ $0 == 0 }) { window.close(); throw XCTSkip("No display link callbacks (no screen?)") }
        // A window that macOS reports as not visible gets throttled callbacks, so only the path is checked here, not the rate.
        for c in counts { XCTAssertGreaterThan(c, 2) }

        views.forEach { $0.isPaused = true }
        let before = views.map(\.drawnFrameCount)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(views.map(\.drawnFrameCount), before, "a paused panel must not draw")
        window.close()
    }

    /// Text is a texture inside the Metal pass (`TextLayer`). The readouts must be in the picture, light on dark,
    /// and a repaint must reuse its bitmaps: only the rectangles that hold text are drawn.
    func testTextIsPartOfTheMetalPass() throws {
        try RenderTestSupport.requireMetal()
        let frames = SyntheticFrames.sequence(count: 60)
        let session = try OffscreenRenderer.Session(panel: .meters, size: CGSize(width: 900, height: 360), scale: 2, theme: Theme(), settings: .init())
        try session.feed(frames)
        let px = try RenderTestSupport.decode(png: session.snapshotPNG())
        // Text is light on a dark ground: expect bright pixels in the top half (headers, big numbers).
        var bright = 0
        for y in stride(from: 0, to: px.height / 2, by: 2) { for x in stride(from: 0, to: px.width, by: 2) where px.rgb(x, y).1 > 150 { bright += 1 } }
        XCTAssertGreaterThan(bright, 300)

        let layer = session.renderer.textLayer
        XCTAssertTrue(layer.isReady)
        XCTAssertGreaterThan(layer.rects.count, 10)
        let covered = layer.rects.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        XCTAssertLessThan(covered, 900 * 360 * 0.35, "text rectangles must stay a small part of the panel")
        // Readouts repaint at most 10 times per second, and not at all when the numbers did not change.
        let before = layer.redrawCount
        XCTAssertFalse(session.renderer.refreshText(now: 100), "same frame, same text: no repaint")
        session.renderer.ingest(frames[10])
        XCTAssertTrue(session.renderer.refreshText(now: 100.2))
        session.renderer.ingest(frames[20])
        XCTAssertFalse(session.renderer.refreshText(now: 100.25), "inside the 100 ms window")
        XCTAssertTrue(session.renderer.refreshText(now: 100.31))
        XCTAssertEqual(layer.redrawCount, before + 2)
    }
}
