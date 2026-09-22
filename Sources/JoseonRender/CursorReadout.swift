import AppKit
import CoreText
import simd
import JoseonCore

// The linked cursor: what every panel shares. The numbers, the one-line readout of the header row, the hairline.
// Linked cursor: one frequency, the same place on every panel. A panel without a link never gets here: `PanelRenderer.cursorLinked` is false.

/// One part of a cursor readout ("392.0 Hz", "G4 +0 ¢", "Mid −41.2 dB"). `rank`: 0 = the most important. A row that is
/// too short drops the highest ranks first; the parts that stay keep their reading order.
struct CursorReadoutItem: Equatable {
    enum Tone { case value, dim, accent, ghost, reference }
    var text: String
    var rank: Int
    var tone = Tone.value
    /// A small bar in this color before the text: the legend of a mark that has no room for words (timeline flag bars).
    var swatch: SIMD4<Float>? = nil
    static let swatchWidth: CGFloat = 12

    // Order of importance (linked-cursor brief): Hz, note, Mid dB, pan, L/R, at-ear, then. The optional extras (the SPL of the
    // band, the Side trace) go first when the row is short. With a comparison set, "B − A" and "A" come right after Mid:
    // they are the question on screen.
    static let hz = 0, note = 1, mid = 2, delta = 3, reference = 4, pan = 5, leftRight = 6, atEar = 7, then = 8, spl = 9, side = 10
}

enum CursorMath {
    /// One decimal under 1 kHz, `x.xx kHz` from 1 kHz, `xx.x kHz` from 10 kHz.
    static func hz(_ f: Float) -> String {
        guard f.isFinite, f > 0 else { return Fmt.dash }
        if f >= 9_995 { return String(format: "%.1f kHz", f / 1000) }
        if f >= 999.95 { return String(format: "%.2f kHz", f / 1000) }
        return String(format: "%.1f Hz", f)
    }

    /// "A4 +3 ¢": the equal-tempered note of a frequency (A4 = 440 Hz). Nil outside the range of note names.
    static func note(_ f: Float) -> String? {
        guard let n = Fmt.note(forHz: f) else { return nil }
        return "\(n.name) \(Fmt.cents(n.cents))"
    }

    /// "−3.2 s", or "now".
    static func ago(_ seconds: Double) -> String {
        seconds < 0.05 ? "now" : "\(Fmt.minus)\(String(format: "%.1f", seconds)) s"
    }

    /// Level of a display array at a frequency: linear interpolation in dB between the two bins around it (the bins are
    /// uniform on a log axis). Nil outside the bins. Every panel reads its number through this one function, so two panels
    /// that show "Mid" at the cursor show the same number.
    static func level(of values: [Float], frequencies: [Float], atHz hz: Float) -> Float? {
        let n = min(values.count, frequencies.count)
        guard n >= 2, hz > 0, let f0 = frequencies.first, f0 > 0, frequencies[n - 1] > f0 else { return nil }
        let idx = log(hz / f0) / log(frequencies[n - 1] / f0) * Float(n - 1)
        guard idx >= 0, idx <= Float(n - 1) else { return nil }
        let i = min(Int(idx), n - 2)
        let t = idx - Float(i)
        return values[i] * (1 - t) + values[i + 1] * t
    }

    /// Index of the bin nearest to a frequency, nil outside the bins.
    static func nearestBin(frequencies: [Float], count: Int, atHz hz: Float) -> Int? {
        let n = min(count, frequencies.count)
        guard n >= 2, hz > 0, frequencies[0] > 0, frequencies[n - 1] > frequencies[0] else { return nil }
        let idx = log(hz / frequencies[0]) / log(frequencies[n - 1] / frequencies[0]) * Float(n - 1)
        guard idx >= -0.5, idx <= Float(n) - 0.5 else { return nil }
        return min(max(Int(idx.rounded()), 0), n - 1)
    }

    /// The listening band (0...7, `BandEnergy.edgesHz`) that contains a frequency. Nil outside 20 Hz ... 24 kHz.
    static func band(containing hz: Float) -> Int? {
        let e = BandEnergy.edgesHz
        guard hz >= e[0], hz <= e[e.count - 1] else { return nil }
        for i in 0..<(e.count - 1) where hz < e[i + 1] { return i }
        return e.count - 2
    }

    /// "4–6 kHz", "60–250 Hz", "500 Hz–2 kHz".
    static func bandRange(_ i: Int) -> String {
        let e = BandEnergy.edgesHz
        let lo = e[i], hi = e[i + 1]
        func n(_ v: Float) -> String { v >= 1000 ? Fmt.axisHz(v).replacingOccurrences(of: "k", with: "") : "\(Int(v))" }
        if lo >= 1000 { return "\(n(lo))\u{2013}\(n(hi)) kHz" }
        if hi < 1000 { return "\(n(lo))\u{2013}\(n(hi)) Hz" }
        return "\(n(lo)) Hz\u{2013}\(n(hi)) kHz"
    }

    /// The third-octave band that contains a frequency: a step changes half way (geometric) between two centers, the same
    /// rule the SPL layer of the spectrum draws with.
    static func thirdOctaveBand(centers: [Float], containing hz: Float) -> Int? {
        let n = centers.count
        guard n >= 2 else { return nil }
        let edge = pow(Float(2), 1.0 / 6)
        guard hz >= centers[0] / edge, hz <= centers[n - 1] * edge else { return nil }
        var b = 0
        while b < n - 1, hz * hz > centers[b] * centers[b + 1] { b += 1 }
        return b
    }

    /// One semitone (or `semitones`) up or down, kept inside the axis.
    static func step(_ hz: Float, semitones: Float, in range: ClosedRange<Float>) -> Float {
        min(max(hz * pow(2, semitones / 12), range.lowerBound), range.upperBound)
    }
}

/// The one-line cursor readout of a header row: right-aligned, parts separated by a middle dot, the least important parts
/// left out when the row is short. A small glyph stands before it: a ring for a hover cursor, a pin for a pinned one.
enum CursorHeader {
    static let separator = "  \u{00B7}  "
    static let tightSeparator = " \u{00B7} "
    static let glyphWidth: CGFloat = 13

    /// The parts that fit into `width`, in reading order. Always keeps the first part when it alone fits.
    static func fit(_ o: OverlayContext, _ items: [CursorReadoutItem], width: CGFloat, font: CTFont, separator: String) -> [CursorReadoutItem] {
        var kept = items
        let sep = o.measure(separator, font: font)
        func total(_ v: [CursorReadoutItem]) -> CGFloat {
            v.reduce(glyphWidth) { $0 + o.measure($1.text, font: font) + ($1.swatch == nil ? 0 : CursorReadoutItem.swatchWidth) } + sep * CGFloat(max(v.count - 1, 0))
        }
        while !kept.isEmpty, total(kept) > width {
            guard let worst = kept.indices.max(by: { kept[$0].rank < kept[$1].rank }) else { break }
            kept.remove(at: worst)
        }
        return kept
    }

    /// Draws the row with its right end at `right`. Returns the x where it starts (equal to `right` when nothing fits).
    @discardableResult
    static func draw(_ o: OverlayContext, items all: [CursorReadoutItem], right: CGFloat, left: CGFloat, midY: CGFloat, compact: Bool,
                     pinned: Bool, palette p: Palette) -> CGFloat {
        let font = Fonts.ui(compact ? 10 : 11, .medium)
        let separator = compact ? tightSeparator : Self.separator
        let items = fit(o, all, width: right - left, font: font, separator: separator)
        guard !items.isEmpty else { return right }
        var x = right
        for (i, item) in items.enumerated().reversed() {
            let color: SIMD4<Float>
            switch item.tone {
            case .value: color = p.text
            case .dim: color = p.textDim
            case .accent: color = mix(p.accent, SIMD4(1, 1, 1, 1), t: 0.45)
            case .ghost: color = p.cursorGhost.withAlpha(1)
            case .reference: color = p.reference.withAlpha(1)
            }
            x -= o.text(item.text, x: x, y: midY, font: font, color: color, h: .right, v: .middle)
            if let c = item.swatch {
                x -= CursorReadoutItem.swatchWidth
                o.fillRect(CGRect(x: x, y: midY - 2, width: 8, height: 4), color: c, radius: 1.5)
            }
            if i > 0 { x -= o.text(separator, x: x, y: midY, font: font, color: p.textFaint, h: .right, v: .middle) }
        }
        // The glyph: what this row is. It is not text, so it cannot be taken for a measured value.
        let gx = x - glyphWidth + 4
        if pinned {
            let c = mix(p.accent, SIMD4(1, 1, 1, 1), t: 0.25)
            o.fillRect(CGRect(x: gx - 2.5, y: midY - 5, width: 5, height: 5), color: c, radius: 2.5)
            o.line(gx, midY, gx, midY + 5, color: c, width: 1)
        } else {
            o.line(gx, midY - 5, gx, midY + 5, color: p.text.withAlpha(0.55), width: 1)
            o.line(gx - 3, midY, gx + 3, midY, color: p.text.withAlpha(0.55), width: 1)
        }
        return x - glyphWidth
    }
}

extension PanelRenderer {
    /// Hover cursor: 1 px, 50 % white. Pinned: 1 px, the accent color.
    var cursorLineColor: SIMD4<Float> {
        guard let c = cursor, c.isPinned else { return SIMD4(1, 1, 1, 0.5) }
        return palette.accent.withAlpha(highContrast ? 1 : 0.95)
    }

    /// A vertical hairline over a plot; a pinned cursor carries a small pin head at its top.
    func drawCursorVertical(x: Float, top: Float, bottom: Float) {
        batch.vline(x, top, bottom, color: cursorLineColor)
        if cursor?.isPinned == true { drawPinHead(x: x, y: top + 3.5) }
    }

    /// A horizontal hairline (frequency on a vertical axis). The pin head stands at its axis end.
    func drawCursorHorizontal(y: Float, left: Float, right: Float) {
        batch.hline(left, right, y, color: cursorLineColor)
        if cursor?.isPinned == true { drawPinHead(x: left + 3.5, y: y) }
    }

    func drawPinHead(x: Float, y: Float) {
        let c = palette.accent
        batch.circle(x, y, 3.5, color: c.withAlpha(1))
        batch.circle(x, y, 3.5, color: SIMD4(1, 1, 1, 0.9), stroke: 1)
    }
}
