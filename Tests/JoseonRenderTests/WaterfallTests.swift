import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// The spectrogram as a 3-D field (docs/specs/waterfall.md).
final class WaterfallTests: XCTestCase {
    static let sizes = [CGSize(width: 560, height: 360), CGSize(width: 1200, height: 600),
                        CGSize(width: 1920, height: 1000), CGSize(width: 2560, height: 1400)]
    private lazy var frames = SyntheticFrames.sequence(count: 240)

    private func settings(_ mode: SpectrogramMode = .waterfall) -> OffscreenRenderer.Settings {
        var s = OffscreenRenderer.Settings()
        s.spectrogramMode = mode
        return s
    }

    func testRendersAtEverySize() throws {
        try RenderTestSupport.requireMetal()
        for size in Self.sizes {
            let scale: CGFloat = size.width > 2000 ? 1 : 2
            let data = try OffscreenRenderer.png(panel: .spectrogram, frames: frames, size: size, scale: scale, settings: settings())
            RenderTestSupport.write(data, "waterfall-\(Int(size.width))x\(Int(size.height)).png")
            let px = try RenderTestSupport.decode(png: data)
            XCTAssertEqual(px.width, Int(size.width * scale))
            XCTAssertEqual(px.height, Int(size.height * scale))
            XCTAssertGreaterThan(px.distinctColors, 200, "\(size) looks flat")
            let first = px.rgb(0, 0)
            var different = 0
            for y in stride(from: 0, to: px.height, by: 7) {
                for x in stride(from: 0, to: px.width, by: 7) where px.rgb(x, y) != first { different += 1 }
            }
            XCTAssertGreaterThan(different, 500, "\(size) is uniform")
        }
    }

    func testOutputFollowsTheFramesAndRepeats() throws {
        try RenderTestSupport.requireMetal()
        let size = CGSize(width: 1200, height: 600)
        var other = SyntheticFrames.Options()
        other.seed = 99
        other.levelDB = -18
        let a = try RenderTestSupport.decode(png: OffscreenRenderer.png(panel: .spectrogram, frames: frames, size: size, settings: settings()))
        let again = try RenderTestSupport.decode(png: OffscreenRenderer.png(panel: .spectrogram, frames: frames, size: size, settings: settings()))
        let b = try RenderTestSupport.decode(png: OffscreenRenderer.png(panel: .spectrogram, frames: SyntheticFrames.sequence(count: 240, options: other),
                                                                         size: size, settings: settings()))
        XCTAssertEqual(a.data, again.data, "same frames must give the same picture")
        var diff = 0
        for i in stride(from: 0, to: a.data.count, by: 4) where abs(Int(a.data[i + 1]) - Int(b.data[i + 1])) > 8 { diff += 1 }
        XCTAssertGreaterThan(diff, 2000)
    }

    func testFlatAndWaterfallShareTheAutomaticTop() throws {
        try RenderTestSupport.requireMetal()
        let size = CGSize(width: 1200, height: 600)
        let flat = try OffscreenRenderer.Session(panel: .spectrogram, size: size, scale: 2, theme: Theme(), settings: settings(.flat))
        let field = try OffscreenRenderer.Session(panel: .spectrogram, size: size, scale: 2, theme: Theme(), settings: settings())
        try flat.feed(frames)
        try field.feed(frames)
        let a = try XCTUnwrap(flat.renderer as? SpectrogramRenderer), b = try XCTUnwrap(field.renderer as? SpectrogramRenderer)
        XCTAssertEqual(a.topDB, b.topDB)
        XCTAssertEqual(a.floorDB, b.floorDB)
    }

    func testModeSwitchKeepsTheHistory() throws {
        try RenderTestSupport.requireMetal()
        let session = try OffscreenRenderer.Session(panel: .spectrogram, size: CGSize(width: 900, height: 420), scale: 2, theme: Theme(), settings: settings(.flat))
        try session.feed(frames)
        let before = try session.snapshotPNG()
        let r = try XCTUnwrap(session.renderer as? SpectrogramRenderer)
        r.mode = .waterfall
        let field = try session.snapshotPNG()
        r.mode = .flat
        let after = try session.snapshotPNG()
        XCTAssertEqual(before, after, "the flat picture must come back unchanged after the field")
        XCTAssertNotEqual(before, field)
    }

    /// Ten seconds of one tone: the field holds one tall bar at that frequency, in every row, and nothing at 300 Hz.
    func testOneToneStandsAtItsFrequency() throws {
        try RenderTestSupport.requireMetal()
        let size = CGSize(width: 1200, height: 600)
        let session = try OffscreenRenderer.Session(panel: .spectrogram, size: size, scale: 2, theme: Theme(), settings: settings())
        try session.feed(Self.toneFrames(hz: 1000, levelDB: -20, seconds: 10))
        let png = try session.snapshotPNG()
        RenderTestSupport.write(png, "waterfall-tone-1k.png")
        let r = try XCTUnwrap(session.renderer as? SpectrogramRenderer)
        // The automatic top sits on the 6 dB step over the tone (the resampler may add half a dB to the peak).
        XCTAssertTrue(r.topDB == -18 || r.topDB == -12, "top \(r.topDB)")
        let px = try RenderTestSupport.decode(png: png)
        func brightness(hz: Float, secondsAgo: Double, height: Float) throws -> Int {
            let p = try XCTUnwrap(r.projectForTesting(hz: hz, secondsAgo: secondsAgo, height: height))
            let c = px.rgb(min(max(Int(p.x * 2), 0), px.width - 1), min(max(Int(p.y * 2), 0), px.height - 1))
            return c.0 + c.1 + c.2
        }
        // On the front face of the newest bar, at 60 % of the scale: lit. In the air over 300 Hz at the same height: background.
        let newest = r.newestSecondsAgo
        XCTAssertGreaterThan(try brightness(hz: 1000, secondsAgo: newest, height: 0.6), 240)
        XCTAssertLessThan(try brightness(hz: 300, secondsAgo: newest, height: 0.6), 120)
        // Half way into the depth the tone is still there.
        XCTAssertGreaterThan(try brightness(hz: 1000, secondsAgo: newest + r.historySeconds * 0.4, height: 0.55), 160)
    }

    /// The pointer over the field names the frequency of the column and the time of the row under it.
    func testPointerCursorNamesFrequencyAndTime() throws {
        try RenderTestSupport.requireMetal()
        let session = try OffscreenRenderer.Session(panel: .spectrogram, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: settings())
        try session.feed(frames)
        _ = try session.snapshotPNG()
        let r = try XCTUnwrap(session.renderer as? SpectrogramRenderer)
        for (hz, ago) in [(Float(1000), 3.0), (Float(80), 1.0), (Float(6000), 3.5)] {
            let p = try XCTUnwrap(r.projectForTesting(hz: hz, secondsAgo: ago, height: 0.4))
            let c = try XCTUnwrap(r.cursor(at: p), "\(hz) Hz, \(ago) s")
            XCTAssertEqual(c.source, .spectrogram)
            XCTAssertLessThan(abs(log2(c.frequencyHz / hz)), 0.12, "\(hz) Hz read as \(c.frequencyHz)")
            XCTAssertEqual(try XCTUnwrap(c.secondsAgo), ago, accuracy: 0.6)
        }
        XCTAssertNil(r.cursor(at: CGPoint(x: 2, y: 2)), "outside the plot")
    }

    /// Pictures for the design review: the pointer over the field (its label and the lit column), a pinned timed cursor
    /// from the spectrogram, a cursor from the spectrum, and Increase Contrast. Every one keeps its labels.
    func testCursorPictures() throws {
        try RenderTestSupport.requireMetal()
        let size = CGSize(width: 1200, height: 600)
        let probe = try OffscreenRenderer.Session(panel: .spectrogram, size: size, scale: 2, theme: Theme(), settings: settings())
        try probe.feed(frames)
        _ = try probe.snapshotPNG()
        let r = try XCTUnwrap(probe.renderer as? SpectrogramRenderer)
        let over = try XCTUnwrap(r.projectForTesting(hz: 440, secondsAgo: 1.5, height: 0.4))
        var hover = settings(); hover.hover = over
        var linkedHover = hover; linkedHover.cursor = try XCTUnwrap(r.cursor(at: over))
        var pinned = settings(); pinned.cursor = PanelCursor(frequencyHz: 2_000, secondsAgo: 2.5, source: .spectrogram, isPinned: true)
        var other = settings(); other.cursor = PanelCursor(frequencyHz: 120, source: .spectrum)
        var contrast = settings(); contrast.increaseContrast = true
        for (name, s) in [("hover", hover), ("linked-hover", linkedHover), ("pinned", pinned), ("cursor-from-spectrum", other), ("contrast", contrast)] {
            let session = try OffscreenRenderer.Session(panel: .spectrogram, size: size, scale: 2, theme: Theme(), settings: s)
            try session.feed(frames)
            let png = try session.snapshotPNG()
            RenderTestSupport.write(png, "waterfall-\(name).png")
            XCTAssertFalse(session.renderer.textLayer.lastLabels.isEmpty, name)
        }
    }

    /// A drag turns the view, a reset brings the resting picture back; the cursor still names the cell under the pointer
    /// from any angle, also from behind.
    func testOrbitZoomAndResetAndTheCursorFromAnyAngle() throws {
        try RenderTestSupport.requireMetal()
        let session = try OffscreenRenderer.Session(panel: .spectrogram, size: CGSize(width: 1200, height: 600), scale: 2, theme: Theme(), settings: settings())
        try session.feed(frames)
        let r = try XCTUnwrap(session.renderer as? SpectrogramRenderer)
        let rest = try session.snapshotPNG()
        XCTAssertFalse(r.hasCustomView)
        r.orbit(yawBy: 2.4, elevationBy: -0.2)
        XCTAssertTrue(r.hasCustomView)
        let turned = try session.snapshotPNG()
        RenderTestSupport.write(turned, "waterfall-turned.png")
        XCTAssertNotEqual(rest, turned)
        r.zoom(by: 1.8)
        let zoomed = try session.snapshotPNG()
        RenderTestSupport.write(zoomed, "waterfall-zoomed.png")
        XCTAssertNotEqual(turned, zoomed)
        // Any yaw: the cursor under a projected cell names its frequency and time.
        for yaw in [Float(0.9), 1.6, 3.0, -2.2] {
            r.setView(yaw: yaw, elevation: 0.5)
            for (hz, ago) in [(Float(1000), 3.0), (Float(120), 1.0)] {
                let p = try XCTUnwrap(r.projectForTesting(hz: hz, secondsAgo: ago, height: 0.4), "yaw \(yaw)")
                let c = try XCTUnwrap(r.cursor(at: p), "yaw \(yaw), \(hz) Hz")
                XCTAssertLessThan(abs(log2(c.frequencyHz / hz)), 0.15, "yaw \(yaw): \(hz) Hz read as \(c.frequencyHz)")
                XCTAssertEqual(try XCTUnwrap(c.secondsAgo), ago, accuracy: 0.7, "yaw \(yaw)")
            }
        }
        // The elevation never goes under the floor.
        r.orbit(yawBy: 0, elevationBy: -5)
        XCTAssertGreaterThan(r.waterfall.elevation, 0.05)
        r.resetView()
        XCTAssertFalse(r.hasCustomView)
        XCTAssertEqual(try session.snapshotPNG(), rest, "the resting picture must come back")
    }

    func testGPUCostStaysInBudget() throws {
        #if DEBUG
        throw XCTSkip("Timing runs in release builds only")
        #else
        try RenderTestSupport.requireMetal()
        let cost = try OffscreenRenderer.measure(panel: .spectrogram, frames: frames, size: CGSize(width: 1200, height: 600), scale: 2,
                                                 iterations: 60, settings: settings())
        print("WATERFALL 1200x600@2x: gpu \(String(format: "%.2f", cost.gpuMS)) ms, cpu encode \(String(format: "%.2f", cost.cpuEncodeMS)) ms, text \(String(format: "%.2f", cost.textMS)) ms")
        XCTAssertLessThan(cost.gpuMS, 2.0)
        let big = try OffscreenRenderer.measure(panel: .spectrogram, frames: frames, size: CGSize(width: 2560, height: 1400), scale: 2,
                                                iterations: 30, settings: settings())
        print("WATERFALL 2560x1400@2x: gpu \(String(format: "%.2f", big.gpuMS)) ms, cpu encode \(String(format: "%.2f", big.cpuEncodeMS)) ms")
        XCTAssertLessThan(big.gpuMS, 4.0)
        #endif
    }

    /// Frames of one steady tone over a quiet floor, one per 60th of a second.
    static func toneFrames(hz: Float, levelDB: Float, seconds: Double) -> [AnalysisFrame] {
        let base = SyntheticFrames.sequence(count: 1)[0]
        let n = Int(seconds * 60)
        return (0..<n).map { k in
            var f = base
            f.hostTime = Double(k) / 60
            var mid = [Float](repeating: -95, count: f.spectrum.frequencies.count)
            if let i = f.spectrum.frequencies.firstIndex(where: { $0 >= hz }) {
                for j in max(i - 1, 0)...min(i + 1, mid.count - 1) { mid[j] = levelDB }
            }
            f.spectrum.mid = mid
            f.spectrum.left = mid
            f.spectrum.right = mid
            f.spectrum.peakHold = mid
            f.spectrum.average = mid
            f.spectrum.midLayers = []
            return f
        }
    }
}
