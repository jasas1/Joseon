import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Design review helper for the menu bar mini graph: renders it from consecutive synthetic frames
/// (so the ballistics show) and writes contact sheets. Set JOSEON_MINI_OUT to choose the directory.
final class MiniContactSheetTests: XCTestCase {
    static let orange = NSColor(srgbRed: 1.0, green: 0.37, blue: 0.04, alpha: 1)
    private let widths: [CGFloat] = [44, 64, 96]
    private let graphHeight: CGFloat = 18
    private let barHeight: CGFloat = 24
    private let scale: CGFloat = 2
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private var outputDirectory: URL {
        let env = ProcessInfo.processInfo.environment["JOSEON_MINI_OUT"]
        let url = env.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? RenderTestSupport.outputDirectory.appendingPathComponent("mini", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Shot { let image: CGImage; let widthPoints: CGFloat; let template: Bool }

    private func context(_ w: Int, _ h: Int) -> CGContext {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .none
        return c
    }

    /// Draws one shot the way the menu bar would: a template is tinted white (dark bar) or black (light bar).
    private func draw(_ shot: Shot, in c: CGContext, at origin: CGPoint, dark: Bool) {
        let rect = CGRect(x: origin.x, y: origin.y, width: CGFloat(shot.image.width), height: CGFloat(shot.image.height))
        guard shot.template else { c.draw(shot.image, in: rect); return }
        c.saveGState()
        c.clip(to: rect)
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        c.draw(shot.image, in: rect)
        c.setBlendMode(.sourceIn)
        c.setFillColor(dark ? CGColor(gray: 1, alpha: 0.9) : CGColor(gray: 0, alpha: 0.85))
        c.fill(rect)
        c.endTransparencyLayer()
        c.restoreGState()
    }

    private func barColor(dark: Bool) -> CGColor {
        dark ? CGColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1) : CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1)
    }

    /// One menu-bar-like strip per row, at 2x pixels.
    private func sheet(rows: [[Shot]], dark: Bool) -> CGImage {
        let gap: CGFloat = 12, margin: CGFloat = 8
        let rowWidth = rows.map { $0.reduce(margin * 2 - gap) { $0 + $1.widthPoints + gap } }.max() ?? 1
        let pw = Int(rowWidth * scale), rowPx = Int(barHeight * scale)
        let c = context(pw, rowPx * rows.count)
        c.setFillColor(barColor(dark: dark))
        c.fill(CGRect(x: 0, y: 0, width: pw, height: rowPx * rows.count))
        for (r, row) in rows.enumerated() {
            let y = CGFloat((rows.count - 1 - r) * rowPx)
            // Row separator, like the lower edge of the menu bar.
            c.setFillColor(dark ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 0.7, alpha: 1))
            c.fill(CGRect(x: 0, y: y, width: CGFloat(pw), height: 1))
            var x = margin * scale
            for shot in row {
                draw(shot, in: c, at: CGPoint(x: x, y: y + (barHeight - graphHeight) / 2 * scale), dark: dark)
                x += (shot.widthPoints + gap) * scale
            }
        }
        return c.makeImage()!
    }

    private func write(_ image: CGImage, upscale: Int, name: String) throws {
        var out = image
        if upscale > 1 {
            let c = context(image.width * upscale, image.height * upscale)
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width * upscale, height: image.height * upscale))
            out = c.makeImage()!
        }
        let rep = NSBitmapImageRep(cgImage: out)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = outputDirectory.appendingPathComponent(name)
        try data.write(to: url)
        print("MINISHEET \(url.path)")
    }

    /// Feeds every second 60 fps frame (the status item runs at 30 Hz) and keeps the images at `captureAt`.
    private func run(frames: [AnalysisFrame], width: CGFloat, accent: NSColor?, captureAt: [Int]) throws -> [Shot] {
        let renderer = MiniSpectrumRenderer()
        renderer.accentColor = accent
        var shots: [Shot] = []
        for k in stride(from: 1, to: frames.count, by: 2) {
            let image = renderer.image(for: frames[k], size: CGSize(width: width, height: graphHeight), scale: scale)
            if captureAt.contains(k) {
                shots.append(Shot(image: try XCTUnwrap(RenderTestSupport.cgImage(image)), widthPoints: width, template: accent == nil))
            }
        }
        return shots
    }

    func testWriteContactSheets() throws {
        // t = 2.0 s is a kick onset (120 bpm). The later shots show the release.
        let captures = [119, 125, 131, 141]
        let frames = SyntheticFrames.sequence(count: 150)
        var rows: [[Shot]] = []
        for accent in [nil, Self.orange] as [NSColor?] {
            let perWidth = try widths.map { try run(frames: frames, width: $0, accent: accent, captureAt: captures) }
            for s in 0..<captures.count { rows.append(perWidth.map { $0[s] }) }
        }
        // 3x on the 2x pixels = 6x on the point size.
        try write(sheet(rows: rows, dark: true), upscale: 3, name: "mini-sheet-dark.png")
        try write(sheet(rows: rows, dark: false), upscale: 3, name: "mini-sheet-light.png")
        // Actual 2x pixels, to judge it at a glance next to the Nyquist reference.
        try write(sheet(rows: [rows[4], rows[6]], dark: true), upscale: 1, name: "mini-actual-dark.png")
        try write(sheet(rows: [rows[0], rows[2]], dark: false), upscale: 1, name: "mini-actual-light.png")
    }

    func testWriteLevelSheet() throws {
        // Quiet to hot: the shape must stay visible and must not flatten against the top.
        var rows: [[Shot]] = []
        for (level, hot) in [(-40, false), (-20, false), (0, false), (0, true)] as [(Float, Bool)] {
            var o = SyntheticFrames.Options()
            o.levelDB = level
            o.hot = hot
            let frames = SyntheticFrames.sequence(count: 150, options: o)
            rows.append(try run(frames: frames, width: 64, accent: Self.orange, captureAt: [119, 131])
                        + run(frames: frames, width: 64, accent: nil, captureAt: [119, 131]))
        }
        try write(sheet(rows: rows, dark: true), upscale: 3, name: "mini-levels-dark.png")
    }
    /// The music-like spectrum of `MiniSpectrumTests.musicFrame` (a bed that falls 4.5 dB per octave, harmonic
    /// stacks): the check that real music is not a bass blob and a flat line. Row 2: the same data with the engine
    /// Tilt setting at 4.5 and the renderer tilt lowered by it, the way the app does: the same picture.
    func testWriteMusicSheet() throws {
        var rows: [[Shot]] = []
        for engineTilt in [0, 4.5] as [Float] {
            var row: [Shot] = []
            for accent in [Self.orange, nil] as [NSColor?] {
                for width in widths {
                    let renderer = MiniSpectrumRenderer()
                    renderer.accentColor = accent
                    renderer.tiltDBPerOctave = MiniSpectrumRenderer.tilt(engineTilt: engineTilt)
                    let image = renderer.image(for: MiniSpectrumTests.musicFrame(engineTilt: engineTilt),
                                               size: CGSize(width: width, height: graphHeight), scale: scale)
                    row.append(Shot(image: try XCTUnwrap(RenderTestSupport.cgImage(image)), widthPoints: width, template: accent == nil))
                }
            }
            rows.append(row)
        }
        try write(sheet(rows: rows, dark: true), upscale: 3, name: "mini-music-dark.png")
        try write(sheet(rows: rows, dark: true), upscale: 1, name: "mini-music-actual-dark.png")
    }

    /// A made-up test signal (pink bed, chord tones, kick and hat bursts at 120 bpm) through the real
    /// `AnalysisEngine`, so the sheet shows the real spectrum layout: multi-resolution FFT, the rising noise
    /// floor and whatever sits below 30 Hz. It is a test signal, not a measurement of music.
    private func analyzerFrames(seconds: Double, gain: Float = 1) -> [AnalysisFrame] {
        let sr = 48_000.0
        let total = Int(seconds * sr)
        let pink = TestSignals.pinkNoise(amplitude: 0.05, count: total)
        let white = TestSignals.whiteNoise(amplitude: 1, count: total, seed: 99)
        let tones: [(Double, Float)] = [(110, 0.10), (220, 0.07), (277.2, 0.05), (329.6, 0.05), (440, 0.04), (659.3, 0.03),
                                        (880, 0.02), (1318.5, 0.012), (2637, 0.006), (5274, 0.003)]
        var signal = [Float](repeating: 0, count: total)
        for i in 0..<total {
            let t = Double(i) / sr
            let beat = (t * 2).truncatingRemainder(dividingBy: 1) / 2, eighth = (t * 4).truncatingRemainder(dividingBy: 1) / 4
            var v = pink[i] * Float(1 + 0.3 * sin(2 * .pi * 0.4 * t))
            for (k, (hz, a)) in tones.enumerated() {
                v += a * Float(sin(2 * .pi * hz * t)) * Float(0.6 + 0.4 * sin(2 * .pi * (0.31 + 0.07 * Double(k)) * t))
            }
            v += 0.45 * Float(sin(2 * .pi * 58 * beat) * exp(-beat * 14)) + 0.08 * white[i] * Float(exp(-beat * 70))
            let hiss = i > 0 ? white[i] - white[i - 1] : 0                        // crude high-pass
            v += 0.03 * hiss * Float(exp(-eighth * 45))
            signal[i] = v * gain
        }
        let engine = AnalysisEngine()
        let block = Int(sr / 60)
        var frames: [AnalysisFrame] = []
        signal.withUnsafeBufferPointer { p in
            var k = 0
            while (k + 1) * block <= total {
                var f = engine.processNow(left: p.baseAddress! + k * block, right: p.baseAddress! + k * block, count: block, sampleRate: sr)
                f.hostTime = 1000 + Double(k + 1) / 60
                frames.append(f)
                k += 1
            }
        }
        return frames
    }

    func testWriteRealAnalyzerSheet() throws {
        let captures = [179, 185, 191, 201]          // t = 3.0 s is a kick onset
        let frames = analyzerFrames(seconds: 3.5)
        var rows: [[Shot]] = []
        for accent in [Self.orange, nil] as [NSColor?] {
            let perWidth = try widths.map { try run(frames: frames, width: $0, accent: accent, captureAt: captures) }
            for s in 0..<captures.count { rows.append(perWidth.map { $0[s] }) }
        }
        try write(sheet(rows: rows, dark: true), upscale: 3, name: "mini-analyzer-dark.png")
        try write(sheet(rows: [rows[0], rows[2], rows[3]], dark: true), upscale: 1, name: "mini-analyzer-actual-dark.png")
    }
}
