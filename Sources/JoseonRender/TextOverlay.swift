import AppKit
import CoreText
import JoseonCore

/// Fonts for the overlay. SF Pro with tabular digits for readouts, SF Mono for axis numbers.
enum Fonts {
    private static var cache: [String: CTFont] = [:]

    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> CTFont {
        cached("u\(size)-\(weight.rawValue)") { NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) }
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> CTFont {
        cached("m\(size)-\(weight.rawValue)") { NSFont.monospacedSystemFont(ofSize: size, weight: weight) }
    }

    private static func cached(_ key: String, _ make: () -> NSFont) -> CTFont {
        if let f = cache[key] { return f }
        let f = make() as CTFont
        cache[key] = f
        return f
    }
}

enum HAlign { case left, center, right }
enum VAlign { case top, middle, baseline, bottom }

/// One drawing of the text layer: what to paint, the pixel-aligned rectangle it may touch (points, top-left origin),
/// and a key that is equal exactly when the painted pixels are equal.
struct OverlayItem {
    enum Op {
        case text(CTLine, CGPoint)                                   // position in bottom-left coordinates
        case glyphs(CTFont, [CGGlyph], [CGPoint], CGColor)           // positions in bottom-left coordinates
        case fill(CGRect, CGColor, CGFloat)                          // rect in bottom-left coordinates, radius
        case stroke(CGRect, CGColor, CGFloat, CGFloat)               // rect, radius, line width
        case line(CGPoint, CGPoint, CGColor, CGFloat, [CGFloat])
        case arc(CGPoint, CGFloat, CGFloat, CGFloat, CGColor, CGFloat) // center (bottom-left), radius, start, end (radians, clockwise from 12 o'clock), width
    }
    var op: Op
    var rect: CGRect
    var key: Int

    func draw(in cg: CGContext) {
        switch op {
        case let .text(line, position):
            cg.textPosition = position
            CTLineDraw(line, cg)
        case let .glyphs(font, glyphs, positions, color):
            cg.setFillColor(color)
            cg.textMatrix = .identity
            cg.setTextDrawingMode(.fill)
            CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, cg)
        case let .fill(r, color, radius):
            cg.setFillColor(color)
            if radius > 0 {
                cg.addPath(CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil))
                cg.fillPath()
            } else {
                cg.fill(r)
            }
        case let .stroke(r, color, radius, width):
            cg.setStrokeColor(color)
            cg.setLineWidth(width)
            cg.addPath(CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil))
            cg.strokePath()
        case let .line(a, b, color, width, dash):
            cg.setStrokeColor(color)
            cg.setLineWidth(width)
            cg.setLineDash(phase: 0, lengths: dash)
            cg.move(to: a)
            cg.addLine(to: b)
            cg.strokePath()
            cg.setLineDash(phase: 0, lengths: [])
        case let .arc(center, radius, start, end, color, width):
            cg.setStrokeColor(color)
            cg.setLineWidth(width)
            cg.setLineCap(.butt)
            // The bitmap has a bottom-left origin: 12 o'clock is +90 degrees, and clockwise on screen is a falling angle.
            cg.addArc(center: center, radius: radius, startAngle: .pi / 2 - start, endAngle: .pi / 2 - end, clockwise: true)
            cg.strokePath()
        }
    }
}

/// Records Core Graphics drawing in view points with a top-left origin, the same space the Metal code uses. Nothing is
/// painted here: `TextLayer` compares the recorded items with what its bitmap already holds and paints only what changed.
final class OverlayContext {
    let size: CGSize
    let pixelScale: CGFloat
    private(set) var items: [OverlayItem] = []

    init(size: CGSize, pixelScale: CGFloat = 2) {
        self.size = size
        self.pixelScale = pixelScale
        items.reserveCapacity(128)
    }

    /// Starts from items and labels recorded earlier (the static labels of a panel, which change only with the layout).
    func preload(items: [OverlayItem], labels: [(text: String, rect: CGRect)]) {
        self.items = items
        self.labels = labels
    }

    @inline(__always) private func flipY(_ y: CGFloat) -> CGFloat { size.height - y }

    /// The pixel-aligned rectangle (points, top-left origin) that a drawing with these bounds may touch.
    private func aligned(_ r: CGRect, pad: CGFloat = 1.5) -> CGRect? {
        let s = pixelScale
        let x0 = max(((r.minX - pad) * s).rounded(.down) / s, 0), y0 = max(((r.minY - pad) * s).rounded(.down) / s, 0)
        let x1 = min(((r.maxX + pad) * s).rounded(.up) / s, size.width), y1 = min(((r.maxY + pad) * s).rounded(.up) / s, size.height)
        guard x1 > x0, y1 > y0 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    fileprivate func record(_ op: OverlayItem.Op, bounds: CGRect, pad: CGFloat, key: Int) { add(op, bounds: bounds, pad: pad, key: key) }

    private func add(_ op: OverlayItem.Op, bounds: CGRect, pad: CGFloat, key: Int) {
        guard let rect = aligned(bounds, pad: pad) else { return }
        items.append(OverlayItem(op: op, rect: rect, key: key))
    }

    // Numbers change at every redraw, and typesetting a fresh `CTLine` for each new number was a third of the text cost.
    // The leading numeric part of a string ("-23.7" of "-23.7 dB") is laid out from a per-font table instead: every
    // character of `fastCharacters` is typeset ONCE per font (alone, so the font's tabular-digit feature is applied), and a
    // number is a row of those glyphs at their advances. Digits, signs and the point do not kern. What follows the number
    // (" dB", " Hz") is an ordinary cached line.
    private struct GlyphTable { var glyphs: [UniChar: (glyph: CGGlyph, advance: CGFloat)] }
    private static var glyphTables: [ObjectIdentifier: GlyphTable] = [:]
    private static let fastCharacters: [UniChar] = Array("0123456789.+\u{2212}-".utf16)

    private static func glyphTable(_ font: CTFont) -> GlyphTable {
        let id = ObjectIdentifier(font as AnyObject)
        if let t = glyphTables[id] { return t }
        var table = GlyphTable(glyphs: [:])
        for ch in fastCharacters {
            let str = String(utf16CodeUnits: [ch], count: 1)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: str, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], runs.count == 1, CTRunGetGlyphCount(runs[0]) == 1 else { continue }
            // Only when the run uses this very font (no fallback font): the glyph index belongs to it.
            let attrs = CTRunGetAttributes(runs[0]) as NSDictionary
            guard let runFont = attrs[kCTFontAttributeName as String], CFEqual(runFont as CFTypeRef, font) else { continue }
            var g = CGGlyph(0)
            CTRunGetGlyphs(runs[0], CFRange(location: 0, length: 1), &g)
            table.glyphs[ch] = (g, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        glyphTables[id] = table
        return table
    }

    /// Length (UTF-16) of the leading part of `string` that the glyph table can lay out. 0 = none.
    private static func fastPrefix(_ units: [UniChar], table: GlyphTable) -> Int {
        var n = 0
        while n < units.count, table.glyphs[units[n]] != nil { n += 1 }
        // A lone sign or point is not worth a second item, and a string must hold a digit to be a number.
        guard n >= 2, units[..<n].contains(where: { $0 >= 48 && $0 <= 57 }) else { return 0 }
        return n
    }

    // Text lines are cached: the same labels and a bounded set of numbers come back every redraw.
    private struct LineKey: Hashable { var string: String; var font: ObjectIdentifier; var color: SIMD4<Float>; var tracking: CGFloat }
    private struct CachedLine {
        /// Nil when the whole string is a number from the glyph table.
        var line: CTLine?
        var width: CGFloat; var ascent: CGFloat; var descent: CGFloat; var id: Int
        /// The leading number: glyphs and their x offsets, and its width (the line starts after it).
        var glyphs: [CGGlyph] = []
        var offsets: [CGFloat] = []
        var glyphWidth: CGFloat = 0
    }
    private static var lineCache: [LineKey: CachedLine] = [:]
    private static var nextLineID = 1
    /// Lines that had to be typeset (not found in the cache), since launch. For the frame cost report.
    private(set) static var lineCacheMisses = 0

    private func line(_ string: String, font: CTFont, color: SIMD4<Float>, tracking: CGFloat) -> CachedLine {
        let key = LineKey(string: string, font: ObjectIdentifier(font as AnyObject), color: color, tracking: tracking)
        if let c = Self.lineCache[key] { return c }
        if tracking == 0 {
            let units = Array(string.utf16)
            let table = Self.glyphTable(font)
            let n = Self.fastPrefix(units, table: table)
            if n > 0 {
                var glyphs: [CGGlyph] = [], offsets: [CGFloat] = []
                glyphs.reserveCapacity(n); offsets.reserveCapacity(n)
                var x: CGFloat = 0
                for u in units[..<n] { let g = table.glyphs[u]!; glyphs.append(g.glyph); offsets.append(x); x += g.advance }
                // The rest (a unit) is a line of its own, from this cache.
                var rest: CachedLine?
                if n < units.count { rest = line(String(utf16CodeUnits: Array(units[n...]), count: units.count - n), font: font, color: color, tracking: 0) }
                let c = CachedLine(line: rest?.line, width: x + (rest?.width ?? 0), ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font),
                                   id: Self.nextLineID, glyphs: glyphs, offsets: offsets, glyphWidth: x)
                Self.nextLineID &+= 1
                if Self.lineCache.count > 2048 { Self.lineCache.removeAll(keepingCapacity: true) }
                Self.lineCache[key] = c
                return c
            }
        }
        Self.lineCacheMisses &+= 1
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        if tracking != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = tracking }
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(l, &ascent, &descent, &leading))
        // Line ids are never reused: a cache flush cannot make two different lines look equal to the differ.
        let c = CachedLine(line: l, width: width, ascent: ascent, descent: descent, id: Self.nextLineID)
        Self.nextLineID &+= 1
        if Self.lineCache.count > 2048 { Self.lineCache.removeAll(keepingCapacity: true) }
        Self.lineCache[key] = c
        return c
    }

    /// Every text drawn so far with its ink box (cap height plus a little, in points, top-left origin): what a reader sees
    /// as "the label". Optional labels ask `isFree` first; the layout tests check that no two boxes intersect.
    private(set) var labels: [(text: String, rect: CGRect)] = []

    /// The ink box `text(...)` would record for these arguments.
    func textBounds(_ string: String, x: CGFloat, y: CGFloat, font: CTFont, h: HAlign = .left, v: VAlign = .baseline, tracking: CGFloat = 0) -> CGRect {
        let width = measure(string, font: font, tracking: tracking)
        var px = x
        switch h {
        case .left: break
        case .center: px -= width / 2
        case .right: px -= width
        }
        let capHeight = CTFontGetCapHeight(font)
        var base = y
        switch v {
        case .baseline: break
        case .top: base = y + capHeight
        case .middle: base = y + capHeight / 2
        case .bottom: base = y - CTFontGetDescent(font)
        }
        return CGRect(x: px, y: base - capHeight - 1, width: width, height: capHeight + 2.5)
    }

    /// True when `rect` (grown by `pad`) touches no label drawn so far and none of `others`.
    func isFree(_ rect: CGRect, pad: CGFloat = 2, others: [CGRect] = []) -> Bool {
        let r = rect.insetBy(dx: -pad, dy: -pad)
        for l in labels where l.rect.intersects(r) { return false }
        for o in others where o.intersects(r) { return false }
        return true
    }

    @discardableResult
    func text(_ string: String, x: CGFloat, y: CGFloat, font: CTFont, color: SIMD4<Float>,
              h: HAlign = .left, v: VAlign = .baseline, tracking: CGFloat = 0) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let cached = line(string, font: font, color: color, tracking: tracking)
        let width = cached.width, ascent = cached.ascent, descent = cached.descent
        var px = x
        switch h {
        case .left: break
        case .center: px -= width / 2
        case .right: px -= width
        }
        // Baseline in top-left coordinates.
        var base = y
        let capHeight = CTFontGetCapHeight(font)
        switch v {
        case .baseline: break
        case .top: base = y + capHeight
        case .middle: base = y + capHeight / 2
        case .bottom: base = y - descent
        }
        labels.append((string, CGRect(x: px, y: base - capHeight - 1, width: width, height: capHeight + 2.5)))
        var k = Hasher()
        k.combine(0); k.combine(cached.id); k.combine(px); k.combine(base)
        let key = k.finalize()
        if !cached.glyphs.isEmpty {
            let y = flipY(base)
            add(.glyphs(font, cached.glyphs, cached.offsets.map { CGPoint(x: px + $0, y: y) }, color.cgColor),
                bounds: CGRect(x: px, y: base - ascent, width: cached.glyphWidth, height: ascent + descent), pad: 2, key: key)
        }
        if let line = cached.line {
            let lx = px + cached.glyphWidth
            add(.text(line, CGPoint(x: lx, y: flipY(base))), bounds: CGRect(x: lx, y: base - ascent, width: width - cached.glyphWidth, height: ascent + descent), pad: 2, key: key &+ 1)
        }
        return width
    }

    func measure(_ string: String, font: CTFont, tracking: CGFloat = 0) -> CGFloat {
        line(string, font: font, color: SIMD4(1, 1, 1, 1), tracking: tracking).width
    }

    func fillRect(_ r: CGRect, color: SIMD4<Float>, radius: CGFloat = 0) {
        let rr = CGRect(x: r.minX, y: flipY(r.maxY), width: r.width, height: r.height)
        var k = Hasher()
        k.combine(1); k.combine(r.minX); k.combine(r.minY); k.combine(r.width); k.combine(r.height); k.combine(color); k.combine(radius)
        add(.fill(rr, color.cgColor, radius), bounds: r, pad: 1.5, key: k.finalize())
    }

    func strokeRect(_ r: CGRect, color: SIMD4<Float>, radius: CGFloat = 0, width: CGFloat = 1) {
        let rr = CGRect(x: r.minX, y: flipY(r.maxY), width: r.width, height: r.height)
        var k = Hasher()
        k.combine(2); k.combine(r.minX); k.combine(r.minY); k.combine(r.width); k.combine(r.height); k.combine(color); k.combine(radius); k.combine(width)
        add(.stroke(rr, color.cgColor, radius, width), bounds: r, pad: 1.5 + width, key: k.finalize())
    }

    func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, color: SIMD4<Float>, width: CGFloat = 1, dash: [CGFloat] = []) {
        var k = Hasher()
        k.combine(3); k.combine(x0); k.combine(y0); k.combine(x1); k.combine(y1); k.combine(color); k.combine(width); k.combine(dash)
        add(.line(CGPoint(x: x0, y: flipY(y0)), CGPoint(x: x1, y: flipY(y1)), color.cgColor, width, dash),
            bounds: CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)), pad: 1.5 + width, key: k.finalize())
    }
}

extension OverlayContext {
    /// A circular arc, clockwise from `start` to `end` (radians, 0 = 12 o'clock). A ring is 0 ... 2 pi.
    func arc(cx: CGFloat, cy: CGFloat, radius: CGFloat, start: CGFloat, end: CGFloat, color: SIMD4<Float>, width: CGFloat) {
        guard end > start, radius > 0 else { return }
        var k = Hasher()
        k.combine(4); k.combine(cx); k.combine(cy); k.combine(radius); k.combine(start); k.combine(end); k.combine(color); k.combine(width)
        record(.arc(CGPoint(x: cx, y: size.height - cy), radius, start, end, color.cgColor, width),
               bounds: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2), pad: 1.5 + width, key: k.finalize())
    }
}

// MARK: - Band names

/// Names of the 8 listening bands in three lengths. Columns get the longest set that fits with air between neighbours.
enum BandLabels {
    static let short = ["Sub", "Bass", "LoMid", "Mid", "UpMid", "Pres", "Brill", "Air"]
    static let two = ["Su", "Ba", "LM", "Mi", "UM", "Pr", "Br", "Ai"]

    /// Under 480 pt of panel width the two-letter set, always: eight longer names in a narrow card read as one word.
    static func fitting(_ o: OverlayContext, font: CTFont, columnWidth: CGFloat, gap: CGFloat = 6, panelWidth: CGFloat = .infinity) -> [String] {
        if panelWidth < 480 { return two }
        for set in [BandEnergy.names, short] where (set.map { o.measure($0, font: font) }.max() ?? 0) + gap <= columnWidth { return set }
        return two
    }
}

// MARK: - Number and note formatting

enum Fmt {
    static let minus = "\u{2212}"
    static let dash = "\u{2014}"

    /// Floor values read as an em dash, not as -120.
    static func isFloor(_ v: Float) -> Bool { !v.isFinite || v <= -119 }

    static func db(_ v: Float, digits: Int = 1, signed: Bool = false) -> String {
        if isFloor(v) { return dash }
        return number(v, digits: digits, signed: signed)
    }

    static func number(_ v: Float, digits: Int = 1, signed: Bool = false) -> String {
        guard v.isFinite else { return dash }
        let p = pow(10, Float(digits))
        var r = (v * p).rounded() / p
        if r == 0 { r = 0 }   // no negative zero
        let body = String(format: "%.\(digits)f", abs(r))
        if r < 0 { return minus + body }
        return signed && r > 0 ? "+" + body : body
    }

    static func hz(_ f: Float) -> String {
        guard f.isFinite, f > 0 else { return dash }
        // One decimal: the analyzer does not resolve more, and more digits would claim it does.
        if f >= 10_000 { return String(format: "%.1f kHz", f / 1000) }
        return String(format: "%.1f Hz", f)
    }

    static func axisHz(_ f: Float) -> String {
        if f >= 1000 {
            let k = f / 1000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(f))"
    }

    private static let noteNames = ["C", "C\u{266F}", "D", "D\u{266F}", "E", "F", "F\u{266F}", "G", "G\u{266F}", "A", "A\u{266F}", "B"]

    /// Equal-tempered note for a frequency, A4 = 440 Hz.
    static func note(forHz f: Float) -> (name: String, cents: Float)? {
        guard f.isFinite, f >= 8, f <= 30_000 else { return nil }
        let n = 69 + 12 * log2(f / 440)
        let nearest = n.rounded()
        let idx = Int(nearest)
        guard idx >= 0 else { return nil }
        let name = noteNames[idx % 12] + "\(idx / 12 - 1)"
        return (name, (n - nearest) * 100)
    }

    /// Contract note names use "#"; show the real sharp sign.
    static func prettyNote(_ s: String) -> String { s.replacingOccurrences(of: "#", with: "\u{266F}") }

    static func cents(_ c: Float) -> String {
        let r = c.rounded()
        if r == 0 { return "\u{00B1}0 \u{00A2}" }
        return (r > 0 ? "+" : minus) + "\(Int(abs(r))) \u{00A2}"
    }
}
