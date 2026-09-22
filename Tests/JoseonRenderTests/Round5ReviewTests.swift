import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Design loop renders, round 5 (trust round): every panel and mode at 1200x600, 560x360, 460x330 and 300x220 from real
/// pipeline frames (demo signal through `AnalysisEngine.processNow`), plus synthetic frames for what the real pipeline does
/// not fill in this worktree: spectrum layers, stress flags, top peaks. Set JOSEON_RENDER_OUT to choose the directory.
/// JOSEON_R5_ONLY=spectrum,spectrogram,vectorscope,pan,meters,states limits the panels.
final class Round5ReviewTests: XCTestCase {
    static let sizes: [(String, CGSize)] = [("1200x600", CGSize(width: 1200, height: 600)), ("560x360", CGSize(width: 560, height: 360)),
                                            ("460x330", CGSize(width: 460, height: 330)), ("300x220", CGSize(width: 300, height: 220))]

    func testRenderForReview() throws {
        try RenderTestSupport.requireMetal()
        guard ProcessInfo.processInfo.environment["JOSEON_RENDER_OUT"] != nil else { throw XCTSkip("Set JOSEON_RENDER_OUT") }
        let only = ProcessInfo.processInfo.environment["JOSEON_R5_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        func want(_ k: String) -> Bool { only?.contains(k) ?? true }
        let frames = RealFrames.demo(seconds: 12)
        var pan = OffscreenRenderer.Settings(); pan.vectorscopeMode = .panSpectrum
        var target = OffscreenRenderer.Settings(); target.targetLUFS = -14
        var side = OffscreenRenderer.Settings(); side.spectrum.showSide = true

        for (name, size) in Self.sizes {
            if want("spectrum") {
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: frames, size: size), "spectrum-\(name).png")
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: frames, size: size, settings: side), "spectrum-side-\(name).png")
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: RealFrames.annotated(frames), size: size), "spectrum-headphone-\(name).png")
            }
            if want("spectrogram") {
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrogram, frames: frames, size: size), "spectrogram-\(name).png")
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrogram, frames: SyntheticFrames.layeredClicks(seconds: 8), size: size), "spectrogram-layers-\(name).png")
            }
            if want("vectorscope") {
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: frames, size: size), "vectorscope-\(name).png")
            }
            if want("pan") {
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: frames, size: size, settings: pan), "placement-\(name).png")
            }
            if want("meters") {
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: frames, size: size, settings: target), "meters-\(name).png")
            }
            if want("states") {
                // Silent / empty state, and the first seconds of a measurement.
                let silence = SyntheticFrames.silence(count: 90)
                for (kind, label, settings) in [(PanelKind.spectrum, "spectrum", OffscreenRenderer.Settings()), (.vectorscope, "vectorscope", .init()),
                                                (.vectorscope, "placement", pan), (.meters, "meters", target), (.spectrogram, "spectrogram", .init())] {
                    RenderTestSupport.write(try OffscreenRenderer.png(panel: kind, frames: silence, size: size, settings: settings), "silent-\(label)-\(name).png")
                }
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: Array(frames.prefix(420)), size: size, settings: target), "meters-first-7s-\(name).png")
            }
        }
        if want("spectrogram") {
            let bursts = SpectrogramAlignmentTests.burstFrames(seconds: 8)
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrogram, frames: bursts, size: Self.sizes[0].1), "spectrogram-bursts-1200x600.png")
            // The first two seconds: the left edge of the history at startup.
            var short = OffscreenRenderer.Settings(); short.historySeconds = 5
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrogram, frames: Array(frames.prefix(200)), size: Self.sizes[0].1, settings: short), "spectrogram-startup-1200x600.png")
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrogram, frames: SyntheticFrames.layeredClicks(seconds: 3), size: Self.sizes[0].1, settings: short), "spectrogram-layers-startup-1200x600.png")
        }
        if want("pan") {
            // One second into a chord (the 12 s render ends on a chord change, where the old partials die away).
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: Array(frames.prefix(660)), size: Self.sizes[0].1, settings: pan), "placement-midchord-1200x600.png")
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: frames, size: CGSize(width: 320, height: 560), settings: pan), "placement-320x560.png")
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: frames, size: CGSize(width: 290, height: 300), settings: pan), "placement-290x300.png")
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: frames, size: CGSize(width: 290, height: 300)), "vectorscope-290x300.png")
        }
    }
}
