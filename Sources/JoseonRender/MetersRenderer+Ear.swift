import AppKit
import Metal
import simd
import JoseonCore

// "Level at the ear": the SPL estimate of `frame.spl` in the meters panel.
//
// Honesty rules of this block:
// - Every number is an estimate. It shows "≈" or stands under a header that says "estimate", and the block names the
//   calibration and its uncertainty. Whole dB only: a decimal would claim a precision the chain does not have.
// - The bar is the fast level, live. The pointer beside it is the slow level: the big numeral. The tick is the maximum.
// - One number, one text: the "±" prints through `EarUncertaintyText`, the function the header of the app prints with, and
//   the dose is the app's ledger (`EarDoseLedger`: stored, new every day / ISO week) whenever the app gives one, so
//   "DOSE · NIOSH DAY" is the figure of the header ring and not the running dose of the estimator.
// - The zones are about hearing dose (70 / 85 / 100 dB(A)), not about the signal. The 85 line carries its rule: 8 h.
// - The block never competes with the loudness numerals: it is the last column (or a strip, or the last row), its numeral
//   is one step smaller than M / S / I, and nothing of it is drawn while `frame.spl` is nil.

/// The ONE way a "±" figure of the level at the ear prints. The header pill, the popover, the calibration window and the
/// meters block all call it, so the same number reads the same on every surface.
public enum EarUncertaintyText {
    /// A TOTAL (voltage and sensitivity together): whole dB. 3.6 dB prints as "± 4 dB": no total here is known to a tenth.
    public static func total(_ db: Double, unit: Bool = true) -> String {
        "\u{00B1} " + String(format: "%.0f", max(db.isFinite ? db : 0, 0).rounded()) + (unit ? " dB" : "")
    }

    /// One TERM of the total (the voltage of a method, the sensitivity). The fixed terms are whole dB. A measured
    /// sensitivity brings a half step from the measurement window ("± 3.5 dB (rig-limited)"): it prints here as it
    /// printed there, never rounded a second time.
    public static func term(_ db: Double, unit: Bool = true) -> String {
        let half = (max(db.isFinite ? db : 0, 0) * 2).rounded() / 2
        return "\u{00B1} " + String(format: half == half.rounded() ? "%.0f" : "%.1f", half) + (unit ? " dB" : "")
    }
}

/// The hearing dose the APP keeps: it is stored, the daily share starts again at midnight and the weekly share with the
/// ISO week. The header ring shows these numbers; with `MetersView.setDoseLedger` the meters block shows the same ones.
/// 1.0 = 100 %.
public struct EarDoseLedger: Hashable, Sendable {
    public var nioshToday: Double
    public var whoWeek: Double
    public init(nioshToday: Double, whoWeek: Double) { self.nioshToday = nioshToday; self.whoWeek = whoWeek }
}

public extension MetersView {
    /// The app's dose ledger. While set, the percent, the ring and "time left at this level" of the block come from it, so
    /// "DOSE · NIOSH DAY" is the same daily figure as the header ring (and "DOSE · WHO WEEK" the same weekly one).
    /// Nil (offscreen review renders, the probe): the block falls back to the running dose of `SPLReading`, which
    /// starts at zero with every estimator and knows no midnight.
    func setDoseLedger(_ ledger: EarDoseLedger?) {
        guard let r = renderer as? MetersRenderer, r.doseLedger != ledger else { return }
        r.doseLedger = ledger
    }
}

/// What the text of the block shows: whole numbers, taken from the reading at most 4 times per second. Equal values =
/// equal text, so the text layer repaints only when a number changed.
struct EarShown: Hashable {
    static let none = Int.min
    var slow = none, fast = none, leqTrack = none, leqSession = none, maxFast = none
    var doseNIOSH = 0, doseWHO = 0
    /// Minutes, in the steps of `EarShown.timeText`. -1 = infinite, -2 = silent.
    var leftNIOSH = -2, leftWHO = -2
    var calibrationName = ""
    /// `EarUncertaintyText.total` of the reading's uncertainty: the text the header prints for the same number.
    var uncertaintyText = EarUncertaintyText.total(0)

    /// `ledger`: the dose the app keeps (see `EarDoseLedger`). Nil = the running dose of the reading.
    init(_ s: SPLReading, silent: Bool, ledger: EarDoseLedger? = nil) {
        func level(_ v: Float) -> Int { v.isFinite && v > SPLReading.floorDB + 0.5 ? Int(v.rounded()) : Self.none }
        func percent(_ d: Double) -> Int { d.isFinite ? Int((max(d, 0) * 100).rounded()) : 0 }
        slow = silent ? Self.none : level(s.levelASlow)
        fast = silent ? Self.none : level(s.levelAFast)
        leqTrack = level(s.leqATrack); leqSession = level(s.leqASession); maxFast = level(s.maxAFast)
        let niosh = ledger?.nioshToday ?? Double(s.doseNIOSH), who = ledger?.whoWeek ?? Double(s.doseWHOWeekly)
        doseNIOSH = percent(niosh); doseWHO = percent(who)
        calibrationName = s.calibrationName
        uncertaintyText = EarUncertaintyText.total(Double(s.uncertaintyDB))
        if slow == Self.none {
            leftNIOSH = -2; leftWHO = -2
        } else {
            if ledger == nil || !s.secondsToNIOSHLimit.isFinite {
                // Infinite = the estimator says this level uses up no allowance (under the NIOSH threshold).
                leftNIOSH = Self.steppedMinutes(s.secondsToNIOSHLimit)
            } else {
                // NIOSH: 85 dB(A) for 8 h, 3 dB exchange rate; the rest of TODAY's allowance at this level.
                let allowed = 8 * 3600 * pow(2, (85 - Double(s.levelASlow)) / 3)
                leftNIOSH = Self.steppedMinutes(max(1 - niosh, 0) * allowed)
            }
            // WHO / ITU H.870 adults: 80 dB(A) for 40 h, 3 dB exchange rate. More than a week of time left = no limit in reach.
            let allowed = 40 * 3600 * pow(2, (80 - Double(s.levelASlow)) / 3)
            let left = max(1 - who, 0) * allowed
            leftWHO = left > 168 * 3600 ? -1 : Self.steppedMinutes(left)
        }
    }

    /// Time left in minutes, in steps that fit an estimate (1 dB is 26 % of the time): 5 min under 2 h, 15 min under 10 h,
    /// then whole hours. -1 = infinite.
    static func steppedMinutes(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return -1 }
        let m = max(seconds, 0) / 60
        let step: Double = m < 120 ? 5 : (m < 600 ? 15 : 60)
        return Int((m / step).rounded(.down) * step)
    }

    /// h:mm, "∞" when infinite, a dash while silent.
    static func timeText(_ minutes: Int) -> String {
        if minutes == -1 { return "\u{221E}" }
        if minutes < 0 { return Fmt.dash }
        if minutes >= 100 * 60 { return "> 99 h" }
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    static func levelText(_ v: Int) -> String { v == none ? Fmt.dash : "\(v)" }
}

/// Where the parts of the ear column stand (points). Made in `layoutChanged`, so text and Metal agree.
struct EarPlan {
    var contentX: CGFloat = 0
    var captionY: CGFloat = 0, numeralBase: CGFloat = 0, numeralSize: CGFloat = 24
    /// Tops of the rows of the level table (at most 4: fast, max, Leq track, Leq session). The table flows down from the
    /// numeral and steps over the label of the 85 line.
    var rows: [CGFloat] = []
    var y85: CGFloat = 0
    var showsLabel85 = false
    var doseTop: CGFloat?
    static let rowHeight: CGFloat = 21
    static let ringRadius: CGFloat = 25
    static let doseHeight: CGFloat = 84
}

extension MetersRenderer {
    static let earColumnWidth: CGFloat = 226
    static let earStripHeight: CGFloat = 40
    static let earMin: Float = 40, earMax: Float = 110
    static let label85 = "85 dB(A) \u{00B7} 8 h"
    static let approx = "\u{2248}"

    // MARK: Zones

    /// Under 70 calm, 70 ... 85 neutral, 85 ... 100 amber, over 100 red. About hearing dose.
    func earZoneColor(_ db: Float) -> SIMD4<Float> {
        let p = palette
        if db >= 100 { return p.danger }
        if db >= 85 { return p.warn }
        // Calm and neutral speak the language of the other bars: deep blue, then the bright cyan of their upper part.
        if db >= 70 { return mix(p.accent, SIMD4<Float>(0.35, 0.95, 1, 1), t: 0.6).withAlpha(1) }
        return mix(p.accent, p.background, t: 0.18).withAlpha(1)
    }
    private static let zoneEdges: [Float] = [40, 70, 85, 100, 110]

    private var earStops: [(Float, SIMD4<Float>)] {
        var out: [(Float, SIMD4<Float>)] = []
        for i in 0..<4 {
            let c = earZoneColor(Self.zoneEdges[i])
            out.append((Self.zoneEdges[i] + (i == 0 ? 0 : 0.001), mix(c, palette.background, t: 0.25).withAlpha(1)))
            out.append((Self.zoneEdges[i + 1], c))
        }
        return out
    }

    var doseValue: (percent: Int, minutesLeft: Int) {
        guard let e = earShown else { return (0, -2) }
        return doseStandard == .nioshDaily ? (e.doseNIOSH, e.leftNIOSH) : (e.doseWHO, e.leftWHO)
    }
    var doseCaption: String { doseStandard == .nioshDaily ? "DOSE \u{00B7} NIOSH DAY" : "DOSE \u{00B7} WHO WEEK" }
    func doseColor(_ percent: Int) -> SIMD4<Float> {
        percent >= 100 ? palette.danger : (percent >= 80 ? palette.warn : mix(palette.accent, SIMD4(1, 1, 1, 1), t: 0.35).withAlpha(1))
    }
    func earNumeralColor(_ db: Int) -> SIMD4<Float> {
        // The zones and the dose carry the color. The numeral stays neutral until the red zone: 85 dB(A) is a matter of
        // hours, not an alarm, and an amber numeral of this size would outshout the loudness numerals.
        db == EarShown.none ? palette.textDim : (db >= 100 ? palette.danger : palette.text)
    }

    // MARK: Layout of the column

    func planEarColumn() -> EarPlan {
        var plan = EarPlan()
        plan.contentX = earBar.maxX + 18
        plan.numeralSize = bigFontSize >= 36 ? 30 : (bigFontSize >= 28 ? 24 : 20)
        let font = Fonts.ui(plan.numeralSize, .light)
        plan.captionY = ear.minY + 48
        plan.numeralBase = plan.captionY + 17 + CTFontGetCapHeight(font) + 4
        plan.y85 = CGFloat(yFor(85, Self.earMin, Self.earMax, in: earBar))
        let labelTop = plan.y85 - 17
        var y = plan.numeralBase + 14
        let bottom = earBar.maxY
        // Dose: at the foot of the column. It gives way only to the numeral.
        if bottom - EarPlan.doseHeight >= y + 6 { plan.doseTop = bottom - EarPlan.doseHeight }
        let floor = plan.doseTop.map { $0 - 8 } ?? bottom
        plan.showsLabel85 = labelTop >= y && plan.y85 + 4 <= floor
        // The level table: one block under the numeral. A row that would touch the 85 line or its label moves under the line.
        while plan.rows.count < 4 {
            if y < plan.y85 + 6, y + EarPlan.rowHeight > (plan.showsLabel85 ? labelTop - 3 : plan.y85 - 3) { y = plan.y85 + 7 }
            guard y + EarPlan.rowHeight <= floor else { break }
            plan.rows.append(y); y += EarPlan.rowHeight
        }
        return plan
    }

    /// Geometry of the strip's line of values. Widths come from the widest strings, so nothing moves when digits change.
    struct StripPlan {
        var caption = "", captionX: CGFloat = 0
        var numeralRight: CGFloat = 0
        var bar = CGRect.zero
        var timeRight: CGFloat?
        var doseRight: CGFloat = 0
        var lineY: CGFloat = 0
    }
    static let stripNumeralFont = Fonts.ui(17, .regular), stripApproxFont = Fonts.ui(13, .regular)
    static let stripUnitFont = Fonts.ui(10, .regular), stripDoseFont = Fonts.ui(13, .medium)

    func planEarStrip(_ o: OverlayContext) -> StripPlan {
        var plan = StripPlan()
        let x0 = ear.minX + 10, x1 = ear.maxX - 10
        plan.lineY = ear.minY + 27
        var x = x0
        let wApprox = o.measure(Self.approx, font: Self.stripApproxFont) + 3
        plan.numeralRight = x + wApprox + o.measure("000", font: Self.stripNumeralFont)
        x = plan.numeralRight + 4 + o.measure("dB(A)", font: Self.stripUnitFont)
        let cap = capFont
        let wDose = o.measure("DOSE", font: cap, tracking: 0.6) + 6 + wApprox + o.measure("100 %", font: Self.stripDoseFont)
        // Order: numeral, bar, dose, time left (what the dose means at this level). The bar comes before the time left.
        let wTime = o.measure("00:00", font: Self.stripDoseFont) + 4 + o.measure("h left", font: Self.stripUnitFont) + 14
        var room = x1 - wDose - 16 - (x + 16)
        if room >= 96 + wTime || (room < 96 && room >= wTime) { plan.timeRight = x1; room -= wTime }
        plan.doseRight = plan.timeRight == nil ? x1 : x1 - wTime
        if room >= 96 {
            let w = min(room, 260)
            plan.bar = CGRect(x: (x + 16 + (room - w) / 2).rounded(), y: ear.minY + 19, width: w.rounded(), height: 5)
        }
        return plan
    }

    private var stripPlanForMetal: StripPlan { planEarStrip(OverlayContext(size: size, pixelScale: scale)) }

    // MARK: Metal

    func drawEar(_ s: SPLReading) {
        let p = palette
        let silent = frame?.isSilent ?? false
        let fast: Float = silent ? 0 : s.levelAFast
        switch earMode {
        case .column:
            let b = earBar
            batch.vline(Float(ear.minX - 7), Float(ear.minY + 4), Float(ear.maxY - 4), color: p.gridMajor)
            let x = Float(b.minX), w = Float(b.width)
            track(x: x, width: w, rect: b)
            zonedBar(x: x, width: w, rect: b, value: fast, lo: Self.earMin, hi: Self.earMax, stops: earStops)
            // The zones, always readable beside the bar.
            for i in 0..<4 {
                let y1 = yFor(Self.zoneEdges[i], Self.earMin, Self.earMax, in: b), y0 = yFor(Self.zoneEdges[i + 1], Self.earMin, Self.earMax, in: b)
                batch.rect(x + w + 3, y0 + 0.5, 3, y1 - y0 - 1, color: earZoneColor(Self.zoneEdges[i]).scaledAlpha(i == 0 ? 0.55 : 0.75), radius: 1)
            }
            for v in [55, 70, 100] as [Float] {
                batch.hline(x - 3, x + w, yFor(v, Self.earMin, Self.earMax, in: b), color: p.gridMajor)
            }
            // The 85 line runs through the column: the level over it, the exposure under it.
            let y85 = Float(earPlan.y85)
            batch.hline(x - 3, Float(ear.maxX), y85, color: p.warn.withAlpha(earPlan.showsLabel85 ? 0.55 : 0.35))
            if fast > Self.earMin { caps.append(Cap(x: x, y: yFor(fast, Self.earMin, Self.earMax, in: b), w: w, color: mix(earZoneColor(fast), SIMD4(1, 1, 1, 1), t: 0.3))) }
            if let top = earPlan.doseTop { batch.hline(Float(earPlan.contentX), Float(ear.maxX), Float(top) - 1, color: p.gridMajor) }
            if s.maxAFast > Self.earMin {
                batch.hline(x, x + w, yFor(s.maxAFast, Self.earMin, Self.earMax, in: b), color: p.text.withAlpha(0.8), pixels: 2)
            }
            // Pointer of the slow level = the big numeral.
            if !silent, s.levelASlow > Self.earMin {
                let y = yFor(min(s.levelASlow, Self.earMax), Self.earMin, Self.earMax, in: b)
                batch.rect(x + w + 8, y - 1, 7, 2, color: p.text, radius: 1)
            }
        case .strip:
            batch.rect(Float(ear.minX), Float(ear.minY), Float(ear.width), Float(ear.height), color: p.plot, radius: 5)
            batch.rect(Float(ear.minX), Float(ear.minY), Float(ear.width), Float(ear.height), color: p.gridMinor, radius: 5, stroke: 1)
            let b = stripBar
            guard b.width > 0 else { return }
            let bx = Float(b.minX), by = Float(b.minY), bw = Float(b.width), bh = Float(b.height)
            func xFor(_ v: Float) -> Float { bx + min(max((v - Self.earMin) / (Self.earMax - Self.earMin), 0), 1) * bw }
            batch.rect(bx, by, bw, bh, color: p.track, radius: 1.5)
            for i in 0..<4 {
                let a = xFor(Self.zoneEdges[i]), e = xFor(Self.zoneEdges[i + 1])
                let c = earZoneColor(Self.zoneEdges[i])
                // Zone underlay, then the part the fast level covers.
                batch.rect(a + (i == 0 ? 0 : 0.5), by + bh + 1.5, e - a - (i == 0 ? 0 : 0.5), 1.5, color: c.scaledAlpha(0.7))
                let end = min(xFor(fast), e)
                if end > a { batch.rect(a, by, end - a, bh, color: c, radius: i == 0 ? 1.5 : 0) }
            }
            // The 85 line points down at its label; the maximum stands over the bar. The two never read as one mark.
            batch.vline(xFor(85), by, by + bh + 4, color: p.warn)
            if s.maxAFast > Self.earMin { batch.vline(xFor(s.maxAFast), by - 3, by + bh, color: p.text.withAlpha(0.85), pixels: 2) }
        case .row:
            // Hairline over the ear row of the readout column: under it stands an estimate, over it measurements.
            let y = Float(read.minY + read.height * 3 / 4)
            batch.hline(Float(read.minX), Float(read.maxX), y, color: p.gridMajor)
        case .none:
            break
        }
    }

    /// The strip's bar, cached per layout (the plan needs text widths).
    var stripBar: CGRect {
        if earMode != .strip { return .zero }
        if stripBarCacheKey != ear { stripBarCache = stripPlanForMetal.bar; stripBarCacheKey = ear }
        return stripBarCache
    }

    // MARK: Text

    func drawEarStatic(_ o: OverlayContext) {
        let p = palette
        let cap = capFont
        let small = Fonts.mono(compact ? 10 : 11)
        switch earMode {
        case .column:
            o.text("LEVEL AT THE EAR", x: ear.minX, y: ear.minY + 4, font: cap, color: p.textFaint, v: .top, tracking: 1.0)
            o.text("estimate \u{00B7} dB(A)", x: ear.minX, y: ear.minY + 20, font: small, color: p.textFaint, v: .top)
            var lastY: CGFloat = -100
            for v in [110, 100, 85, 70, 55, 40] as [Float] {
                let y = CGFloat(yFor(v, Self.earMin, Self.earMax, in: earBar))
                guard y - lastY > 13 else { continue }
                o.text(Fmt.number(v, digits: 0), x: earBar.minX - 7, y: y, font: small, color: v == 85 ? mix(p.warn, p.textDim, t: 0.35) : p.textDim, h: .right, v: .middle)
                lastY = y
            }
            o.text("fast", x: earBar.midX, y: earBar.maxY + 7, font: Fonts.ui(11, .medium), color: p.text, h: .center, v: .top)
            if earPlan.showsLabel85 {
                o.text(Self.label85, x: ear.maxX, y: earPlan.y85 - 4, font: small, color: mix(p.warn, p.textDim, t: 0.35), h: .right, v: .bottom)
            }
        case .strip:
            let plan = planEarStrip(o)
            let b = plan.bar
            guard b.width > 0 else { return }
            let f = Fonts.mono(9)
            let y = b.maxY + 5
            func xFor(_ v: CGFloat) -> CGFloat { b.minX + (v - 40) / 70 * b.width }
            o.text("40", x: b.minX, y: y, font: f, color: p.textFaint, v: .top)
            o.text("110", x: b.maxX, y: y, font: f, color: p.textFaint, h: .right, v: .top)
            let full = o.textBounds(Self.label85, x: xFor(85), y: y, font: f, h: .center, v: .top)
            let warn = mix(p.warn, p.textDim, t: 0.35)
            if o.isFree(full, pad: 5) {
                o.text(Self.label85, x: xFor(85), y: y, font: f, color: warn, h: .center, v: .top)
            } else {
                o.text("85", x: xFor(85), y: y, font: f, color: warn, h: .center, v: .top)
            }
        case .row, .none:
            break
        }
    }

    /// The name of the calibration and the uncertainty, cut to `width` with an ellipsis in the name.
    private func provenance(_ o: OverlayContext, _ e: EarShown, font: CTFont, width: CGFloat, prefix: String = "") -> String {
        let tail = " \u{00B7} " + e.uncertaintyText
        var name = e.calibrationName
        if name.isEmpty { return prefix + e.uncertaintyText }
        if o.measure(prefix + name + tail, font: font) <= width { return prefix + name + tail }
        while name.count > 4 {
            name.removeLast()
            let t = prefix + name.trimmingCharacters(in: .whitespaces) + "\u{2026}" + tail
            if o.measure(t, font: font) <= width { return t }
        }
        return o.measure(prefix + e.uncertaintyText, font: font) <= width ? prefix + e.uncertaintyText : e.uncertaintyText
    }

    func drawEarDynamic(_ o: OverlayContext, _ e: EarShown) {
        switch earMode {
        case .column: drawEarColumn(o, e)
        case .strip: drawEarStrip(o, e)
        case .row, .none: break     // the row is drawn with the readout column
        }
    }

    private func drawEarColumn(_ o: OverlayContext, _ e: EarShown) {
        let p = palette
        let plan = earPlan
        let cap = capFont
        let x = plan.contentX, right = ear.maxX
        let unitFont = Fonts.ui(11, .regular)

        // The numeral: slow level, whole dB, with its sign of an estimate and its uncertainty.
        o.text("SLOW \u{00B7} 1 s", x: x, y: plan.captionY, font: cap, color: p.textFaint, v: .top, tracking: 1.0)
        let big = Fonts.ui(plan.numeralSize, .light)
        let approxFont = Fonts.ui((plan.numeralSize * 0.62).rounded(), .light)
        let wApprox = o.measure(Self.approx, font: approxFont) + 5
        let numW = o.measure("000", font: big)
        let base = plan.numeralBase
        if e.slow == EarShown.none {
            o.text(Fmt.dash, x: x, y: base, font: Fonts.ui(15, .regular), color: p.textDim)
        } else {
            // The number keeps its right edge (the unit never moves); the sign stands directly before it.
            let w = o.text("\(e.slow)", x: x + wApprox + numW, y: base, font: big, color: earNumeralColor(e.slow), h: .right)
            o.text(Self.approx, x: x + wApprox + numW - w - 5, y: base - 1, font: approxFont, color: p.textDim, h: .right)
        }
        let ux = x + wApprox + numW + 7
        let wUnit = o.text("dB(A)", x: ux, y: base, font: unitFont, color: p.textDim)
        if CTFontGetCapHeight(big) >= 20 {
            // Over the unit, like the target over the LU delta.
            o.text(e.uncertaintyText, x: ux, y: base - CTFontGetCapHeight(big) + 1, font: Fonts.mono(11), color: p.textDim, v: .top)
        } else {
            // Small numerals: no room for two lines beside them.
            o.text(e.uncertaintyText, x: ux + wUnit + 8, y: base, font: Fonts.mono(11), color: p.textDim)
        }

        // Quiet rows: label left, whole dB right. They stand under "estimate · dB(A)".
        let rowFont = Fonts.ui(13, .regular)
        func row(_ label: String, _ value: Int, top: CGFloat) {
            let mid = top + EarPlan.rowHeight / 2
            o.text(label, x: x, y: mid, font: cap, color: p.textFaint, v: .middle, tracking: 0.6)
            let t = EarShown.levelText(value)
            o.text(t, x: right, y: mid, font: t == Fmt.dash ? Fonts.ui(12, .regular) : rowFont, color: value == EarShown.none ? p.textDim : p.text, h: .right, v: .middle)
        }
        // Reading order: fast, max, Leq track, Leq session. When not all fit, the averages stay: the bar shows the fast
        // level and its tick the maximum.
        let table: [(label: String, value: Int, priority: Int)] = [("FAST", e.fast, 3), ("MAX FAST", e.maxFast, 2), ("LEQ TRACK", e.leqTrack, 0), ("LEQ SESSION", e.leqSession, 1)]
        let shown = table.filter { $0.priority < plan.rows.count }
        for (item, top) in zip(shown, plan.rows) { row(item.label, item.value, top: top) }

        // Dose: ring with the percent, time left at this level.
        if let top = plan.doseTop {
            let dose = doseValue
            o.text(doseCaption, x: x, y: top + 7, font: cap, color: p.textFaint, v: .top, tracking: 0.6)
            let r = EarPlan.ringRadius, cx = x + r + 3, cy = top + 26 + r + 2
            let color = doseColor(dose.percent)
            o.arc(cx: cx, cy: cy, radius: r, start: 0, end: 2 * .pi - 0.0001, color: p.track, width: 5)
            let share = min(CGFloat(dose.percent) / 100, 1)
            if share > 0 { o.arc(cx: cx, cy: cy, radius: r, start: 0, end: max(share * 2 * .pi - 0.0001, 0.02), color: color, width: 5) }
            let pf = Fonts.ui(dose.percent > 999 ? 11 : 13, .medium)
            o.text(dose.percent > 999 ? "> 999 %" : "\(dose.percent) %", x: cx, y: cy, font: pf, color: dose.percent >= 80 ? color : p.text, h: .center, v: .middle)
            let tx = cx + r + 14
            o.text("TIME LEFT", x: tx, y: cy - r + 1, font: cap, color: p.textFaint, v: .top, tracking: 0.6)
            let tf = Fonts.ui(19, .regular)
            let t = EarShown.timeText(dose.minutesLeft)
            let tBase = cy - r + 17 + CTFontGetCapHeight(tf) + 3
            if t == Fmt.dash {
                o.text(t, x: tx, y: tBase, font: Fonts.ui(15, .regular), color: p.textDim)
            } else {
                let w = o.text(t, x: tx, y: tBase, font: tf, color: dose.minutesLeft == 0 ? p.danger : p.text)
                if t.contains(":") { o.text("h:mm", x: tx + w + 5, y: tBase, font: unitFont, color: p.textDim) }
            }
            o.text("at this level", x: tx, y: tBase + 8, font: unitFont, color: p.textFaint, v: .top)
        }

        // Provenance, on the row of the bar names.
        let pf = Fonts.ui(11, .regular)
        o.text(provenance(o, e, font: pf, width: right - x), x: right, y: earBar.maxY + 7, font: pf, color: p.textDim, h: .right, v: .top)
    }

    private func drawEarStrip(_ o: OverlayContext, _ e: EarShown) {
        let p = palette
        let plan = planEarStrip(o)
        let cap = capFont
        let x0 = ear.minX + 10, x1 = ear.maxX - 10
        // Line 1: what it is, and where the number comes from.
        let title = ear.width >= 300 ? "LEVEL AT THE EAR" : "AT THE EAR"
        let wTitle = o.text(title, x: x0, y: ear.minY + 6, font: cap, color: p.textFaint, v: .top, tracking: 1.0)
        let pf = Fonts.ui(10, .regular)
        let room = x1 - x0 - wTitle - 14
        var prov = provenance(o, e, font: pf, width: room, prefix: "estimate \u{00B7} ")
        if o.measure(prov, font: pf) > room { prov = "estimate" }
        o.text(prov, x: x1, y: ear.minY + 6, font: pf, color: p.textDim, h: .right, v: .top)

        // Line 2: the numeral, the bar (static labels), time left, dose.
        let base = ear.minY + 34
        // Left edge on the left edge of the title. The unit follows the number (the plan keeps room for three digits).
        let nx = x0 + o.measure(Self.approx, font: Self.stripApproxFont) + 3
        var ux = nx + o.measure("00", font: Self.stripNumeralFont)
        if e.slow == EarShown.none {
            o.text(Fmt.dash, x: x0, y: base, font: Fonts.ui(12, .regular), color: p.textDim)
        } else {
            o.text(Self.approx, x: x0, y: base - 1, font: Self.stripApproxFont, color: p.textDim)
            ux = max(ux, nx + o.text("\(e.slow)", x: nx, y: base, font: Self.stripNumeralFont, color: earNumeralColor(e.slow)))
        }
        o.text("dB(A)", x: ux + 4, y: base, font: Self.stripUnitFont, color: p.textDim)

        let dose = doseValue
        let color = doseColor(dose.percent)
        var x = plan.doseRight
        x -= o.text(dose.percent > 999 ? "> 999 %" : "\(dose.percent) %", x: x, y: base, font: Self.stripDoseFont, color: dose.percent >= 80 ? color : p.text, h: .right)
        x -= o.text(Self.approx, x: x - 3, y: base, font: Self.stripApproxFont, color: p.textDim, h: .right) + 3
        o.text("DOSE", x: x - 6, y: base, font: cap, color: p.textFaint, h: .right, tracking: 0.6)
        if let tr = plan.timeRight {
            var tx = tr
            // "h left": without the unit, 23:00 reads as a time of day.
            let t = EarShown.timeText(dose.minutesLeft)
            tx -= o.text(t.contains(":") ? "h left" : "left", x: tx, y: base, font: Self.stripUnitFont, color: p.textDim, h: .right) + 4
            o.text(t, x: tx, y: base, font: t == Fmt.dash ? Fonts.ui(12, .regular) : Self.stripDoseFont, color: t == Fmt.dash ? p.textDim : p.text, h: .right)
        }
    }

    /// The ear estimate as rows of the compact readout column (no band energy, so no strip). `y` = top of the row.
    func drawEarRow(_ o: OverlayContext, _ e: EarShown, x: CGFloat, y: CGFloat, width: CGFloat, rowHeight: CGFloat, numeralRight: CGFloat, font: CTFont, withDose: Bool) {
        let p = palette
        let cap = capFont
        let wCap = o.text("EAR", x: x, y: y + 4, font: cap, color: p.textFaint, v: .top, tracking: 1.0)
        let unit = Fonts.ui(10, .regular)
        if wCap + 6 + o.measure("dB(A)", font: unit) <= width { o.text("dB(A)", x: x + wCap + 6, y: y + 4, font: unit, color: p.textFaint, v: .top) }
        let base = y + 18 + CTFontGetCapHeight(font)
        let approxFont = Fonts.ui(12, .regular)
        let t = EarShown.levelText(e.slow)
        // Left edge on the left edge of M / S / I and of the dose line.
        let wApprox = o.measure(Self.approx, font: approxFont) + 4
        let right = x + wApprox + o.measure("000", font: font)
        if t == Fmt.dash {
            o.text(t, x: x, y: base, font: Fonts.ui(12, .regular), color: p.textDim)
        } else {
            o.text(Self.approx, x: x, y: base - 1, font: approxFont, color: p.textDim)
            o.text(t, x: x + wApprox, y: base, font: font, color: earNumeralColor(e.slow))
        }
        guard withDose else { return }
        let dose = doseValue
        let text = "\(Self.approx) \(min(dose.percent, 999)) %"
        let df = Fonts.ui(11, .regular)
        let color = dose.percent >= 80 ? doseColor(dose.percent) : p.textDim
        if rowHeight >= 46 {
            // Second line: the dose.
            let w = o.text("dose", x: x, y: base + 14, font: df, color: p.textFaint)
            o.text(text, x: x + w + 4, y: base + 14, font: df, color: color)
        } else if right + 10 + o.measure(text, font: df) <= x + width {
            o.text(text, x: x + width, y: base, font: df, color: color, h: .right)
        }
    }

    // MARK: Accessibility

    func earAccessibilityText(_ s: SPLReading, silent: Bool) -> String {
        let e = EarShown(s, silent: silent, ledger: doseLedger)
        let percent = doseStandard == .nioshDaily ? e.doseNIOSH : e.doseWHO
        let level = e.slow == EarShown.none ? "no level at the ear" : "about \(e.slow) dB A at the ear"
        return "\(level), dose \(percent) percent"
    }
}
