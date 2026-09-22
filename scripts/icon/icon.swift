import AppKit
import CoreGraphics

// Joseon icon variants. Usage: swift icon.swift <outDir>
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size = 1024

func hue(_ t: CGFloat, _ a: CGFloat = 1, light: CGFloat = 1) -> CGColor {
    // warm lows -> yellow -> green -> cyan -> violet highs (the app's hue-by-frequency system)
    let stops: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
        (0.00, (1.00, 0.42, 0.36)), (0.22, (1.00, 0.70, 0.25)), (0.42, (0.93, 0.92, 0.35)),
        (0.58, (0.35, 0.90, 0.55)), (0.76, (0.25, 0.80, 1.00)), (1.00, (0.70, 0.52, 1.00))]
    var c = stops.last!.1
    for i in 0..<(stops.count - 1) where t >= stops[i].0 && t <= stops[i + 1].0 {
        let u = (t - stops[i].0) / (stops[i + 1].0 - stops[i].0)
        let a0 = stops[i].1, b0 = stops[i + 1].1
        c = (a0.0 + (b0.0 - a0.0) * u, a0.1 + (b0.1 - a0.1) * u, a0.2 + (b0.2 - a0.2) * u)
    }
    return CGColor(red: c.0 * light, green: c.1 * light, blue: c.2 * light, alpha: a)
}

/// A music-like spectrum: bass hump, harmonic peaks, falling highs. x in 0...1 -> height 0...1
func spectrum(_ x: CGFloat, peaks: Bool) -> CGFloat {
    var y = 0.62 * exp(-pow((x - 0.16) / 0.13, 2)) + 0.30 * (1 - x) + 0.06
    if peaks {
        for (px, h, w) in [(0.30, 0.34, 0.012), (0.40, 0.30, 0.011), (0.48, 0.24, 0.010), (0.55, 0.20, 0.009), (0.80, 0.22, 0.008)] as [(CGFloat, CGFloat, CGFloat)] {
            y += h * exp(-pow((x - px) / w, 2))
        }
    }
    y += 0.018 * sin(x * 70) * x
    let rise = min(max(x / 0.10, 0), 1); let fall = min(max((1 - x) / 0.05, 0), 1)
    y *= (rise * rise * (3 - 2 * rise)) * (0.35 + 0.65 * fall * fall * (3 - 2 * fall))
    return min(max(y, 0.0), 0.97)
}

func makeContext() -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func plate(_ ctx: CGContext) -> CGRect {
    let r = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: r, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
    ctx.addPath(path); ctx.setFillColor(CGColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.075, green: 0.10, blue: 0.19, alpha: 1), CGColor(red: 0.025, green: 0.035, blue: 0.075, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    return r
}

func finishPlate(_ ctx: CGContext, _ r: CGRect) {
    ctx.restoreGState()
    let path = CGPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.addPath(path); ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10)); ctx.setLineWidth(3); ctx.strokePath()
}

func grid(_ ctx: CGContext, _ r: CGRect) {
    ctx.setStrokeColor(CGColor(red: 0.6, green: 0.7, blue: 0.9, alpha: 0.10)); ctx.setLineWidth(2)
    for i in 1..<5 { let y = r.minY + r.height * CGFloat(i) / 5; ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y)) }
    for f in [0.18, 0.36, 0.54, 0.72, 0.90] as [CGFloat] { let x = r.minX + r.width * f; ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY)) }
    ctx.strokePath()
}

func drawSpectrum(_ ctx: CGContext, in r: CGRect, peaks: Bool, base: CGFloat, height: CGFloat, line: CGFloat) {
    let n = 400
    // fill: vertical slices in the frequency hue, fading to the floor
    for i in 0..<n {
        let t = CGFloat(i) / CGFloat(n - 1)
        let x = r.minX + r.width * t
        let top = base + height * spectrum(t, peaks: peaks)
        let g = CGGradient(colorsSpace: nil, colors: [hue(t, 0.62), hue(t, 0.0)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.clip(to: CGRect(x: x, y: base, width: r.width / CGFloat(n) + 1, height: top - base))
        ctx.drawLinearGradient(g, start: CGPoint(x: x, y: top), end: CGPoint(x: x, y: base), options: [])
        ctx.restoreGState()
    }
    // outline: glow then crisp line, segment by segment for the hue
    for pass in 0..<2 {
        for i in 0..<(n - 1) {
            let t0 = CGFloat(i) / CGFloat(n - 1), t1 = CGFloat(i + 1) / CGFloat(n - 1)
            let p0 = CGPoint(x: r.minX + r.width * t0, y: base + height * spectrum(t0, peaks: peaks))
            let p1 = CGPoint(x: r.minX + r.width * t1, y: base + height * spectrum(t1, peaks: peaks))
            ctx.saveGState()
            if pass == 0 { ctx.setShadow(offset: .zero, blur: 18, color: hue(t0, 0.75)); ctx.setStrokeColor(hue(t0, 0.35)); ctx.setLineWidth(line) }
            else { ctx.setStrokeColor(hue(t0, 1, light: 1.0)); ctx.setLineWidth(line) }
            ctx.setLineCap(.round)
            ctx.move(to: p0); ctx.addLine(to: p1); ctx.strokePath()
            ctx.restoreGState()
        }
    }
}

func save(_ ctx: CGContext, _ name: String) {
    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}

// A: the spectrum with harmonic peaks, faint grid
do { let c = makeContext(); let r = plate(c); grid(c, r); drawSpectrum(c, in: r.insetBy(dx: 70, dy: 0), peaks: true, base: r.minY + 170, height: 540, line: 13); finishPlate(c, r); save(c, "icon-A") }
// B: smooth silhouette only, no grid, bolder line (reads best small)
do { let c = makeContext(); let r = plate(c); drawSpectrum(c, in: r.insetBy(dx: 80, dy: 0), peaks: false, base: r.minY + 200, height: 560, line: 20); finishPlate(c, r); save(c, "icon-B") }
// C: hue bars (menu-bar-graph motif): 9 rounded bars
do {
    let c = makeContext(); let r = plate(c)
    let n = 9, gap: CGFloat = 26, inset: CGFloat = 120
    let w = (r.width - inset * 2 - gap * CGFloat(n - 1)) / CGFloat(n)
    for i in 0..<n {
        let t = CGFloat(i) / CGFloat(n - 1)
        let h = 110 + 470 * spectrum(t, peaks: false)
        let bar = CGRect(x: r.minX + inset + CGFloat(i) * (w + gap), y: r.minY + 170, width: w, height: h)
        let p = CGPath(roundedRect: bar, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)
        c.saveGState(); c.setShadow(offset: .zero, blur: 30, color: hue(t, 0.7)); c.addPath(p); c.setFillColor(hue(t, 1)); c.fillPath(); c.restoreGState()
        c.saveGState(); c.addPath(p); c.clip()
        let g = CGGradient(colorsSpace: nil, colors: [hue(t, 1, light: 1.0), hue(t, 1, light: 0.55)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(g, start: CGPoint(x: bar.midX, y: bar.maxY), end: CGPoint(x: bar.midX, y: bar.minY), options: [])
        c.restoreGState()
    }
    finishPlate(c, r); save(c, "icon-C")
}
print("ok")
