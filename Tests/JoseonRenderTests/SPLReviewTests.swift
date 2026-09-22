import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Renders the meters ("Level at the ear") and the spectrum (dB SPL axis) at the four review sizes, from `SyntheticFrames`
/// with a made-up SPL reading. Set JOSEON_RENDER_OUT to choose the directory.
final class SPLReviewTests: XCTestCase {
    static let sizes = [CGSize(width: 1200, height: 600), CGSize(width: 560, height: 360), CGSize(width: 460, height: 330), CGSize(width: 300, height: 220)]

    func testRenderSPLForReview() throws {
        try RenderTestSupport.requireMetal()
        var o = SyntheticFrames.Options()
        o.includeSPL = true
        let frames = SyntheticFrames.sequence(count: 1200, options: o)
        var hp = o; hp.includeHeadphone = true
        let withHeadphone = SyntheticFrames.sequence(count: 600, options: hp)
        var hotOptions = o; hotOptions.hot = true
        let hot = SyntheticFrames.sequence(count: 600, options: hotOptions)

        var meters = OffscreenRenderer.Settings(); meters.targetLUFS = -14
        var who = meters; who.doseStandard = .whoWeekly
        var spl = OffscreenRenderer.Settings(); spl.levelAxis = .dBSPL
        for size in Self.sizes {
            let tag = "\(Int(size.width))x\(Int(size.height))"
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: frames, size: size, settings: meters), "spl-meters-\(tag).png")
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: frames, size: size, settings: spl), "spl-spectrum-\(tag).png")
        }
        let big = Self.sizes[0]
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: hot, size: big, settings: who), "spl-meters-hot-who-1200x600.png")
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: hot, size: Self.sizes[1], settings: meters), "spl-meters-hot-560x360.png")
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: frames, size: CGSize(width: 900, height: 420), settings: meters), "spl-meters-900x420.png")
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: withHeadphone, size: big, settings: spl), "spl-spectrum-headphone-1200x600.png")
        let plain = SyntheticFrames.sequence(count: 300)
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: plain, size: Self.sizes[1], settings: spl), "spl-spectrum-not-calibrated-560x360.png")
        // Worst case for the layout: a long calibration name, the red zone, a dose far over 100 %.
        var extreme = hot
        for i in extreme.indices {
            extreme[i].spl?.calibrationName = "Woo Audio WA33 Elite, volume knob at 10 o'clock, high gain"
            extreme[i].spl?.doseNIOSH = 1.34; extreme[i].spl?.levelASlow = 102; extreme[i].spl?.levelAFast = 103; extreme[i].spl?.maxAFast = 106
            extreme[i].spl?.secondsToNIOSHLimit = 0; extreme[i].spl?.uncertaintyDB = 4.5
        }
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: extreme, size: big, settings: meters), "spl-meters-extreme-1200x600.png")
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: extreme, size: Self.sizes[1], settings: meters), "spl-meters-extreme-560x360.png")
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: extreme, size: Self.sizes[3], settings: meters), "spl-meters-extreme-300x220.png")
        let silent = SyntheticFrames.addingDemoSPL(to: SyntheticFrames.silence(count: 10))
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: silent, size: big, settings: meters), "spl-meters-silent-1200x600.png")
    }
}
