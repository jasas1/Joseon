import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Renders every panel and the mini graph to PNG for the look-and-fix loop.
final class DesignReviewTests: XCTestCase {
    func testRenderAllPanelsForReview() throws {
        try RenderTestSupport.requireMetal()
        var o = SyntheticFrames.Options()
        o.includeHeadphone = true
        let frames = SyntheticFrames.sequence(count: 1200, options: o)
        let plain = SyntheticFrames.sequence(count: 600)
        let big = CGSize(width: 1200, height: 600)

        var hover = OffscreenRenderer.Settings()
        hover.hover = CGPoint(x: 700, y: 330)

        RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: plain, size: big), "spectrum.png")
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: frames, size: big, settings: hover), "spectrum-headphone-hover.png")
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrogram, frames: frames, size: big), "spectrogram.png")
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: plain, size: big), "vectorscope.png")
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: plain, size: big), "meters.png")

        // Card sizes, as in the app's bottom row.
        let card = CGSize(width: 420, height: 320)
        for kind in PanelKind.allCases {
            RenderTestSupport.write(try OffscreenRenderer.png(panel: kind, frames: plain, size: card), "card-\(kind.rawValue).png")
        }
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: plain, size: CGSize(width: 340, height: 160)), "popover-spectrum.png")

        RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: plain, size: CGSize(width: 900, height: 340)), "meters-900.png")
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .vectorscope, frames: plain, size: CGSize(width: 300, height: 420)), "vectorscope-tall.png")
        var hot = SyntheticFrames.Options(); hot.hot = true
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: SyntheticFrames.sequence(count: 300, options: hot), size: big), "meters-hot.png")
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .meters, frames: SyntheticFrames.silence(count: 10), size: big), "meters-silent.png")
        var hc = OffscreenRenderer.Settings(); hc.increaseContrast = true
        RenderTestSupport.write(try OffscreenRenderer.png(panel: .spectrum, frames: plain, size: big, settings: hc), "spectrum-high-contrast.png")

        // Mini graph: on a dark and a light menu bar, enlarged so the shape can be judged.
        let mini = MiniSpectrumRenderer()
        let image = mini.image(for: plain[plain.count - 1], size: CGSize(width: 64, height: 18), scale: 2)
        let silentImage = mini.image(for: SyntheticFrames.silence(count: 1)[0], size: CGSize(width: 64, height: 18), scale: 2)
        RenderTestSupport.write(Self.menuBarMock(images: [image, silentImage]), "mini.png")
    }

    /// Tints the template the way the menu bar does and lays it on dark and light strips.
    static func menuBarMock(images: [NSImage]) -> Data {
        let zoom: CGFloat = 2.8
        let w = 420, h = 200
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let strips: [(CGFloat, CGColor, CGColor)] = [
            (100, CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1), CGColor(gray: 1, alpha: 0.92)),
            (0, CGColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1), CGColor(gray: 0, alpha: 0.85)),
        ]
        for (y, bg, fg) in strips {
            ctx.setFillColor(bg)
            ctx.fill(CGRect(x: 0, y: y, width: CGFloat(w), height: 100))
            var x: CGFloat = 16
            for image in images {
                guard let cg = RenderTestSupport.cgImage(image) else { continue }
                let r = CGRect(x: x, y: y + 24, width: image.size.width * zoom, height: image.size.height * zoom)
                ctx.saveGState()
                ctx.clip(to: r, mask: cg)
                ctx.setFillColor(fg)
                ctx.fill(r)
                ctx.restoreGState()
                x += r.width + 24
            }
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
