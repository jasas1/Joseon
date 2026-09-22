import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Design loop renders, round 4: real pipeline frames (demo signal and a burst train through the analyzers), plus
/// `SyntheticFrames` for the stress flags and the top peaks the real pipeline does not fill in this worktree.
/// Set JOSEON_RENDER_OUT to choose the directory. JOSEON_R4_ONLY=spectrogram,spectrum... limits the panels.
final class Round4ReviewTests: XCTestCase {
    func testRenderForReview() throws {
        try RenderTestSupport.requireMetal()
        guard ProcessInfo.processInfo.environment["JOSEON_RENDER_OUT"] != nil else { throw XCTSkip("Set JOSEON_RENDER_OUT") }
        let only = ProcessInfo.processInfo.environment["JOSEON_R4_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        func want(_ k: String) -> Bool { only?.contains(k) ?? true }
        let frames = RealFrames.demo(seconds: 12)
        // Sizes: the large view, the card of the Essential layout, and the cards of a 900 pt wide window.
        let sizes: [(String, CGSize)] = [("", CGSize(width: 1200, height: 600)), ("card-", CGSize(width: 560, height: 360)),
                                         ("w900-", CGSize(width: 900, height: 420)), ("w900card-", CGSize(width: 290, height: 300)),
                                         ("small-", CGSize(width: 420, height: 300))]
        var pan = OffscreenRenderer.Settings(); pan.vectorscopeMode = .panSpectrum
        var target = OffscreenRenderer.Settings(); target.targetLUFS = -14

        for (name, size) in sizes {
            if want("spectrum") {
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: frames, size: size), "\(name)spectrum.png")
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: RealFrames.annotated(frames), size: size), "\(name)spectrum-headphone.png")
            }
            if want("spectrogram") {
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrogram, frames: frames, size: size), "\(name)spectrogram.png")
            }
            if want("vectorscope") {
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: frames, size: size), "\(name)vectorscope.png")
            }
            if want("pan") {
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: frames, size: size, settings: pan), "\(name)panspectrum.png")
            }
            if want("meters") {
                RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: frames, size: size, settings: target), "\(name)meters.png")
            }
        }
        if want("spectrogram") {
            let bursts = SpectrogramAlignmentTests.burstFrames(seconds: 8)
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrogram, frames: bursts, size: sizes[0].1), "spectrogram-bursts.png")
        }
        if want("pan") {
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: frames, size: CGSize(width: 320, height: 560), settings: pan), "tall-panspectrum.png")
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: frames, size: CGSize(width: 420, height: 640), settings: pan), "tall2-panspectrum.png")
        }
        if want("meters") {
            // The first seconds of a measurement: no M before 400 ms, no S before 3 s.
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: Array(frames.prefix(150)), size: sizes[0].1, settings: target), "meters-first-2s5.png")
        }
    }
}
