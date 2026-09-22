import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Design loop renders from REAL pipeline frames (demo signal through the analyzers).
/// Set JOSEON_RENDER_OUT to choose the directory. Large and card sizes, every panel and mode.
final class Round2ReviewTests: XCTestCase {
    func testRenderRealFramesForReview() throws {
        try RenderTestSupport.requireMetal()
        guard ProcessInfo.processInfo.environment["JOSEON_RENDER_OUT"] != nil else { throw XCTSkip("Set JOSEON_RENDER_OUT") }
        let frames = RealFrames.demo(seconds: 12)
        let hp = RealFrames.demo(seconds: 12, headphone: true)
        let big = CGSize(width: 1200, height: 600), card = CGSize(width: 560, height: 360)

        var pan = OffscreenRenderer.Settings(); pan.vectorscopeMode = .panSpectrum
        var target = OffscreenRenderer.Settings(); target.targetLUFS = -14
        var hover = OffscreenRenderer.Settings(); hover.hover = CGPoint(x: 905, y: 330)
        var gramHover = OffscreenRenderer.Settings(); gramHover.hover = CGPoint(x: 900, y: 418)
        var fixed = OffscreenRenderer.Settings(); fixed.spectrumAutoRange = false

        for (name, size) in [("", big), ("card-", card)] {
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: frames, size: size), "\(name)spectrum.png")
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: hp, size: size, settings: hover), "\(name)spectrum-headphone.png")
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrogram, frames: frames, size: size, settings: size == big ? gramHover : .init()), "\(name)spectrogram.png")
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: frames, size: size), "\(name)vectorscope.png")
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: frames, size: size, settings: pan), "\(name)panspectrum.png")
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: frames, size: size, settings: target), "\(name)meters.png")
        }
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: frames, size: big, settings: fixed), "spectrum-96dB.png")
        // The app's smaller card and a tall scope.
        let small = CGSize(width: 420, height: 320)
        for kind in PanelKind.allCases {
            RenderTestSupport.write(try OffscreenRenderer.png(panel: kind, frames: frames, size: small), "small-\(kind.rawValue).png")
        }
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: frames, size: CGSize(width: 320, height: 440), settings: pan), "tall-panspectrum.png")
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: frames, size: CGSize(width: 340, height: 160)), "popover-spectrum.png")
        var hot = SyntheticFrames.Options(); hot.hot = true
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: SyntheticFrames.sequence(count: 300, options: hot), size: big, settings: target), "meters-hot.png")
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: SyntheticFrames.silence(count: 10), size: big), "meters-silent.png")
    }
}
