import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Design review of the linked cursor: every panel with the same cursor, from real pipeline frames, plus a contact sheet
/// in the app's "Essential" arrangement so the link shows at a glance. Set JOSEON_CURSOR_OUT to choose the directory.
final class LinkedCursorReviewTests: XCTestCase {
    static var outputDirectory: URL {
        let env = ProcessInfo.processInfo.environment["JOSEON_CURSOR_OUT"]
        let url = env.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? RenderTestSupport.outputDirectory.appendingPathComponent("cursor", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    struct Scenario {
        var name: String
        var cursor: PanelCursor
    }

    static let scenarios = [
        Scenario(name: "hover-392", cursor: PanelCursor(frequencyHz: 392, source: .spectrum)),
        Scenario(name: "pinned-3k1", cursor: PanelCursor(frequencyHz: 3_100, source: .spectrum, isPinned: true)),
        Scenario(name: "timed-3s2", cursor: PanelCursor(frequencyHz: 392, secondsAgo: 3.2, source: .spectrogram)),
    ]

    struct PanelCase { var name: String; var kind: PanelKind; var mode = VectorscopeMode.lissajous }
    static let panels = [PanelCase(name: "spectrum", kind: .spectrum), PanelCase(name: "spectrogram", kind: .spectrogram),
                         PanelCase(name: "vectorscope", kind: .vectorscope), PanelCase(name: "placement", kind: .vectorscope, mode: .panSpectrum),
                         PanelCase(name: "meters", kind: .meters)]

    static func frames() -> [AnalysisFrame] { RealFrames.demo(seconds: 8) }

    /// Renders one panel with a linked cursor. The source panel of a hover cursor gets the pointer on the cursor.
    static func render(_ p: PanelCase, size: CGSize, cursor: PanelCursor, slice: CursorHistorySlice?, frames: [AnalysisFrame],
                       configure: (inout OffscreenRenderer.Settings) -> Void = { _ in }) throws -> (png: Data, session: OffscreenRenderer.Session) {
        var settings = OffscreenRenderer.Settings()
        settings.vectorscopeMode = p.mode
        settings.cursor = cursor
        settings.cursorHistorySlice = slice
        configure(&settings)
        let s = try OffscreenRenderer.Session(panel: p.kind, size: size, scale: 2, theme: Theme(), settings: settings)
        try s.feed(frames)
        if !cursor.isPinned, cursor.source == p.kind, let point = pointerPoint(s.renderer, cursor) {
            // As the view does it: the pointer makes the cursor, from this panel's own axes.
            s.renderer.hover = point
            s.renderer.cursor = s.renderer.cursor(at: point)
        }
        return (try s.snapshotPNG(), s)
    }

    /// Where the pointer stands in the source panel for a cursor (the inverse of `cursor(at:)`).
    static func pointerPoint(_ r: PanelRenderer, _ c: PanelCursor) -> CGPoint? {
        if let s = r as? SpectrumRenderer {
            let plot = s.plotRectForTesting
            return CGPoint(x: s.xForTesting(hz: c.frequencyHz), y: plot.minY + plot.height * 0.42)
        }
        if let s = r as? SpectrogramRenderer {
            return CGPoint(x: s.xForTesting(secondsAgo: c.secondsAgo ?? s.newestSecondsAgo), y: s.yForTesting(hz: c.frequencyHz))
        }
        if let v = r as? VectorscopeRenderer, v.mode == .panSpectrum {
            return CGPoint(x: v.panGeometryForTesting.centerX + 30, y: v.panYForTesting(hz: c.frequencyHz))
        }
        return nil
    }

    static func slice(for cursor: PanelCursor, frames: [AnalysisFrame]) throws -> CursorHistorySlice? {
        guard let ago = cursor.secondsAgo else { return nil }
        return try OffscreenRenderer.historySlice(frames: frames, secondsAgo: ago)
    }

    func testRenderLinkedCursorReviewImages() throws {
        try RenderTestSupport.requireMetal()
        let frames = Self.frames()
        let sizes = [CGSize(width: 1200, height: 600), CGSize(width: 560, height: 360), CGSize(width: 460, height: 330)]
        for sc in Self.scenarios {
            let slice = try Self.slice(for: sc.cursor, frames: frames)
            if sc.cursor.secondsAgo != nil { XCTAssertNotNil(slice, "the history holds the column at -3.2 s") }
            for p in Self.panels {
                for size in sizes {
                    let out = try Self.render(p, size: size, cursor: sc.cursor, slice: slice, frames: frames)
                    try out.png.write(to: Self.outputDirectory.appendingPathComponent("\(sc.name)-\(p.name)-\(Int(size.width))x\(Int(size.height)).png"))
                }
            }
            // The smallest card of the layout test, to look at what is left of the readouts there.
            for p in Self.panels {
                let out = try Self.render(p, size: CGSize(width: 300, height: 220), cursor: sc.cursor, slice: slice, frames: frames)
                try out.png.write(to: Self.outputDirectory.appendingPathComponent("\(sc.name)-\(p.name)-300x220.png"))
            }
            // The spectrum with everything on: headphone overlay with a target, the dB SPL axis, the Side trace.
            var o = SyntheticFrames.Options(); o.includeHeadphone = true; o.includeSPL = true
            let full = SyntheticFrames.sequence(count: 480, options: o)
            let fullSlice = try Self.slice(for: sc.cursor, frames: full)
            let out = try Self.render(Self.panels[0], size: CGSize(width: 1200, height: 600), cursor: sc.cursor, slice: fullSlice, frames: full) {
                $0.levelAxis = .dBSPL; $0.spectrum.showSide = true
            }
            try out.png.write(to: Self.outputDirectory.appendingPathComponent("\(sc.name)-spectrum-full-1200x600.png"))
        }
    }

    /// The four cards as the "Essential" layout places them: the spectrum over a row of spectrogram, stereo, meters.
    func testRenderEssentialContactSheets() throws {
        try RenderTestSupport.requireMetal()
        let frames = Self.frames()
        let card = CGSize(width: 460, height: 330), gap: CGFloat = 10, scale: CGFloat = 2
        let wide = CGSize(width: card.width * 3 + gap * 2, height: card.height)
        for sc in Self.scenarios {
            let slice = try Self.slice(for: sc.cursor, frames: frames)
            for stereo in [Self.panels[3], Self.panels[2]] {
                let order: [(PanelCase, CGSize, CGPoint)] = [
                    (Self.panels[0], wide, CGPoint(x: gap, y: gap)),
                    (Self.panels[1], card, CGPoint(x: gap, y: gap * 2 + card.height)),
                    (stereo, card, CGPoint(x: gap * 2 + card.width, y: gap * 2 + card.height)),
                    (Self.panels[4], card, CGPoint(x: gap * 3 + card.width * 2, y: gap * 2 + card.height)),
                ]
                let total = CGSize(width: wide.width + gap * 2, height: card.height * 2 + gap * 3)
                let cg = CGContext(data: nil, width: Int(total.width * scale), height: Int(total.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                cg.setFillColor(CGColor(srgbRed: 0.015, green: 0.02, blue: 0.04, alpha: 1))
                cg.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                for (p, size, origin) in order {
                    let png = try Self.render(p, size: size, cursor: sc.cursor, slice: slice, frames: frames).png
                    guard let src = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                    cg.draw(image, in: CGRect(x: origin.x * scale, y: (total.height - origin.y - size.height) * scale, width: size.width * scale, height: size.height * scale))
                }
                guard let image = cg.makeImage() else { return XCTFail("no sheet") }
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(to: Self.outputDirectory.appendingPathComponent("sheet-essential-\(sc.name)-\(stereo.name).png"))
            }
        }
    }
}
