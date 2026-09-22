import AppKit
import simd
import JoseonCore

// The "A vs B" table of the meters: the reference's numbers, the live numbers, and the difference. Δ is always B − A.
//
// Honest numbers:
// - A number that is not a measurement yet is a dash (integrated before the first gated block, the range before 30 s),
//   and so is every Δ that would use it.
// - Δ is the difference of the two numbers as printed (one decimal), so a reader who subtracts finds the same value.
// - The band bars do NOT compare `snapshot.bands` with `frame.bands`: those are band levels of one moment (the analyzer's
//   band meter follows the music), and the difference of two moments says nothing about two masters. The bars come from
//   the two long-term spectra (`ComparisonCurves.bandDeltas`): the same curves, tilt handling and level offset as the
//   spectrum's difference lane. They wait for 5 s of B like the lane does.
// - Level match moves the band bars and nothing else. The footer says `bands level-matched` when it is on.

extension MetersRenderer {
    /// How much of the table fits into the room it gets.
    struct ComparePlan: Equatable {
        enum Chart { case none, bars, full }
        var rows = 0
        var chart = Chart.none
        var wide = true
        var height: CGFloat = 0
        var barsHeight: CGFloat = 0

        var titleHeight: CGFloat { wide ? 19 : 15 }
        var headerHeight: CGFloat { wide ? 18 : 14 }
        var rowHeight: CGFloat { wide ? 16 : 12.5 }
        var gap: CGFloat { wide ? 10 : 5 }
        var captionHeight: CGFloat { wide && chart == .full ? 16 : 0 }
        var namesHeight: CGFloat { chart == .full ? (wide ? 14 : 11) : 0 }
        var numbersHeight: CGFloat { wide && chart == .full ? 13 : 0 }
        var footerHeight: CGFloat { chart == .none ? 0 : (wide ? 16 : 12) }
        var chartHeight: CGFloat { chart == .none ? 0 : captionHeight + barsHeight + namesHeight + numbersHeight + footerHeight }

        /// The most that fits into `height`: all rows and the full band chart, then the chart without names, then fewer
        /// rows (never under two with a chart), then rows only.
        static func make(height: CGFloat, wide: Bool, rowsWanted: Int) -> ComparePlan {
            var best = ComparePlan()
            for minimumRows in [min(3, rowsWanted), 2] {
                for chart in [Chart.full, .bars] {
                    var p = ComparePlan(rows: 0, chart: chart, wide: wide)
                    p.barsHeight = wide ? 48 : 22
                    let fixed = p.titleHeight + p.headerHeight + p.gap + p.chartHeight
                    let n = Int(((height - fixed) / p.rowHeight).rounded(.down))
                    guard n >= minimumRows else { continue }
                    p.rows = min(n, rowsWanted)
                    // A compact card gives what is left to the bars.
                    if !wide { p.barsHeight = min(p.barsHeight + height - fixed - CGFloat(p.rows) * p.rowHeight, 40) }
                    p.height = p.titleHeight + p.headerHeight + CGFloat(p.rows) * p.rowHeight + p.gap + p.chartHeight
                    return p
                }
            }
            best.wide = wide
            let n = Int(((height - best.titleHeight - best.headerHeight) / best.rowHeight).rounded(.down))
            if n >= 1 {
                best.rows = min(n, rowsWanted)
                best.height = best.titleHeight + best.headerHeight + CGFloat(best.rows) * best.rowHeight
            }
            return best
        }
    }

    /// What the table shows, as text: equal values = no repaint.
    struct CompareShown: Hashable {
        struct Row: Hashable { var kind: Int; var a: String; var b: String; var delta: String }
        var rows: [Row] = []
        /// B − A per band in tenths of a dB. Nil = no value.
        var bands: [Int?] = []
        var measuring = false
        var measuredSeconds = 0
        var offsetTenths: Int?
        var bandScale: Float = 6
        var levelMatch = true
    }

    // Row kinds, in display order. `unit`: the unit of the difference (LUFS against LUFS differ by LU, dBTP by dB). `priority`: what stays when the room is short (low = stays).
    static let compareLabels: [(long: String, short: String, unit: String, priority: Int)] = [
        ("Integrated", "I", "LU", 0), ("Range LRA", "LRA", "LU", 3), ("PLR", "PLR", "dB", 2), ("True peak max", "TP max", "dB", 1),
        ("Leq dB(A) \u{2248}", "Leq A", "dB", 4), ("Lowest strong", "Lowest", "Hz", 5),
    ]
    /// Scale of the band bars: the smallest of ±3, ±6, ±12 dB that holds every bar, with hysteresis (it grows when a bar
    /// passes it, it shrinks when every bar is under 80 % of the next smaller one). The chart says which one it is.
    static let compareBandScales: [Float] = [3, 6, 12]
    static func bandScale(current: Float, bands: [Int?]) -> Float {
        let reach = bands.compactMap { $0.map { abs(Float($0)) / 10 } }.max() ?? 0
        let fit = compareBandScales.first { reach <= $0 } ?? 12
        if fit >= current { return fit }
        let relaxed = compareBandScales.first { reach <= $0 * 0.8 } ?? 12
        return min(max(relaxed, fit), current)
    }

    /// Rows the table can have: five, and the Leq row when the reference carries one and the frames carry SPL.
    var compareRowsWanted: Int { 5 + (comparison?.leqA != nil && earMode != .none ? 1 : 0) }

    func makeCompareShown(_ c: ComparisonSnapshot, _ f: AnalysisFrame) -> CompareShown {
        var out = CompareShown()
        out.levelMatch = comparisonLevelMatch
        let la = c.loudness, lb = f.loudness

        func row(_ kind: Int, _ a: Float?, _ b: Float?, digits: Int = 1, signed: Bool = false) {
            func shown(_ v: Float?) -> Float? { v.map { let p = pow(10, Float(digits)); return ($0 * p).rounded() / p } }
            let ra = shown(a), rb = shown(b)
            out.rows.append(.init(kind: kind, a: ra.map { Fmt.number($0, digits: digits, signed: signed) } ?? Fmt.dash,
                                  b: rb.map { Fmt.number($0, digits: digits, signed: signed) } ?? Fmt.dash,
                                  delta: ra.flatMap { a in rb.map { Fmt.number($0 - a, digits: digits, signed: true) } } ?? Fmt.dash))
        }
        func program(_ l: LoudnessReading) -> Bool { l.isIntegratedValid && !Fmt.isFloor(l.integratedLUFS) }
        func value(_ v: Float, _ ok: Bool = true) -> Float? { ok && !Fmt.isFloor(v) ? v : nil }
        let minRange = Self.loudnessRangeMinimumSeconds
        row(0, value(la.integratedLUFS, program(la)), value(lb.integratedLUFS, program(lb)))
        row(1, value(la.loudnessRangeLU, program(la) && c.measuredSeconds >= minRange), value(lb.loudnessRangeLU, program(lb) && lb.measuredSeconds >= minRange))
        row(2, value(la.plrDB, program(la) && !Fmt.isFloor(la.truePeakMaxDBTP)), value(lb.plrDB, program(lb) && !Fmt.isFloor(lb.truePeakMaxDBTP)))
        row(3, value(la.truePeakMaxDBTP), value(lb.truePeakMaxDBTP), signed: true)
        if let leqA = c.leqA, let e = f.spl {
            row(4, leqA > SPLReading.floorDB + 1 ? leqA : nil, e.leqATrack > SPLReading.floorDB + 1 && !f.isSilent ? e.leqATrack : nil)
        }
        row(5, c.lowestStrongHz > 0 ? c.lowestStrongHz : nil, f.lowestStrongHz > 0 ? f.lowestStrongHz : nil, digits: 0)

        out.measuring = lb.measuredSeconds < ComparisonCurves.minimumSecondsB
        out.measuredSeconds = out.measuring ? Int(lb.measuredSeconds) : 0
        let s = f.spectrum
        if !out.measuring, s.frequencies.count >= 2, s.average.count >= s.frequencies.count {
            compare.setReference(c, liveFrequencies: s.frequencies)
            compare.update(liveAverage: s.average, liveTilt: liveTiltDBPerOctave, levelMatch: comparisonLevelMatch, displayFloorDB: SpectrumReading.floorDB)
            out.bands = compare.bandDeltas.map { $0.map { Int(($0 * 10).rounded()) } }
            out.offsetTenths = compare.levelOffsetDB.map { Int(($0 * 10).rounded()) }
            out.bandScale = Self.bandScale(current: compareShown?.bandScale ?? 3, bands: out.bands)
        } else {
            out.bands = [Int?](repeating: nil, count: 8)
        }
        return out
    }

    /// The display can stand still (frozen) while a comparison is set: the table then reads the frame that is there.
    func ensureCompareShown() {
        if compareShown == nil, let c = comparison, let f = frame { compareShown = makeCompareShown(c, f) }
    }

    func drawCompareTable(_ o: OverlayContext, _ c: ComparisonSnapshot, _ f: AnalysisFrame) {
        ensureCompareShown()
        guard let shown = compareShown, comparePlan.rows > 0 else { return }
        let p = palette
        let plan = comparePlan
        let r = compareRect
        let wide = plan.wide
        let cap = capFont
        let small: CGFloat = wide ? 11 : 10
        let labelFont = Fonts.ui(small, .regular), numFont = Fonts.mono(small), deltaFont = Fonts.mono(small, .medium)
        let gold = mix(p.reference.withAlpha(1), p.text, t: 0.15)

        // Title: what this is, and which reference.
        var y = r.minY
        let titleW = o.text("A VS B", x: r.minX, y: y + 4, font: cap, color: p.textFaint, v: .top, tracking: 1.0)
        let nameFont = Fonts.ui(small, .regular)
        let nameRoom = r.width - titleW - 14
        let name = ComparisonText.referenceLegends(c.name).first { o.measure($0, font: nameFont) <= nameRoom }
        if let name, name != "A" { o.text(name, x: r.maxX, y: y + 4, font: nameFont, color: gold, h: .right, v: .top) }
        y += plan.titleHeight

        // Columns, right-aligned: A, B, B − A, and the unit in a wide panel.
        let wNum = o.measure("\(Fmt.minus)00.0", font: numFont)
        let unitW: CGFloat = wide ? o.measure("dBTP", font: Fonts.ui(10)) + 6 : 0
        let colGap: CGFloat = wide ? max(min((r.width - unitW - wNum * 3 - 96) / 2, 22), 8) : 8
        let xDelta = r.maxX - unitW, xB = xDelta - wNum - colGap - (wide ? 4 : 0), xA = xB - wNum - colGap
        let headY = y + plan.headerHeight / 2 - 0.5
        o.text("A", x: xA, y: headY, font: cap, color: gold, h: .right, v: .middle)
        o.text("B", x: xB, y: headY, font: cap, color: p.textDim, h: .right, v: .middle)
        o.text(ComparisonText.deltaName, x: xDelta, y: headY, font: cap, color: p.text, h: .right, v: .middle)
        y += plan.headerHeight
        o.line(r.minX, y + 0.5, r.maxX, y + 0.5, color: p.gridMajor, width: 1)
        y += 2

        // The rows that fit, by priority, in display order.
        let keep = Set(shown.rows.map(\.kind).sorted { Self.compareLabels[$0].priority < Self.compareLabels[$1].priority }.prefix(plan.rows))
        let labelRoom = xA - wNum - 6 - r.minX
        for row in shown.rows where keep.contains(row.kind) {
            let info = Self.compareLabels[row.kind]
            let midY = y + plan.rowHeight / 2
            let label = o.measure(info.long, font: labelFont) <= labelRoom ? info.long : info.short
            o.text(label, x: r.minX, y: midY, font: labelFont, color: p.textDim, v: .middle)
            o.text(row.a, x: xA, y: midY, font: numFont, color: row.a == Fmt.dash ? p.textFaint : gold, h: .right, v: .middle)
            o.text(row.b, x: xB, y: midY, font: numFont, color: row.b == Fmt.dash ? p.textFaint : p.text, h: .right, v: .middle)
            o.text(row.delta, x: xDelta, y: midY, font: deltaFont, color: row.delta == Fmt.dash ? p.textFaint : p.text, h: .right, v: .middle)
            if wide { o.text(info.unit, x: xDelta + 6, y: midY, font: Fonts.ui(10), color: p.textFaint, v: .middle) }
            y += plan.rowHeight
        }
        guard plan.chart != .none else { return }
        y += plan.gap

        // Band chart: B − A of the eight listening bands from the two long-term spectra, ±6 dB around a zero line.
        let scale = shown.bandScale
        if plan.captionHeight > 0 {
            o.text("BANDS  \(ComparisonText.deltaName.uppercased())", x: r.minX, y: y + 2, font: cap, color: p.textFaint, v: .top, tracking: 1.0)
            o.text("long-term \u{00B7} \u{00B1}\(Int(scale)) dB", x: r.maxX, y: y + 2, font: Fonts.ui(10), color: p.textFaint, h: .right, v: .top)
            y += plan.captionHeight
        }
        let bars = CGRect(x: r.minX, y: y, width: r.width, height: plan.barsHeight)
        let zeroY = bars.midY
        let cw = bars.width / 8
        let barW = min(cw * 0.5, 16)
        o.line(bars.minX, bars.minY, bars.maxX, bars.minY, color: p.gridMinor, width: 1)
        o.line(bars.minX, bars.maxY, bars.maxX, bars.maxY, color: p.gridMinor, width: 1)
        if shown.measuring {
            o.text(ComparisonText.measuring(seconds: f.loudness.measuredSeconds), x: bars.midX, y: zeroY, font: labelFont, color: p.textDim, h: .center, v: .middle)
        } else {
            for (i, v) in shown.bands.enumerated() where i < 8 {
                guard let v else { continue }
                let d = Float(v) / 10
                let h = CGFloat(min(abs(d), scale) / scale) * bars.height / 2
                guard h >= 0.5 else { continue }
                let x = bars.minX + CGFloat(i) * cw + (cw - barW) / 2
                let up = d > 0
                o.fillRect(CGRect(x: x, y: up ? zeroY - h : zeroY, width: barW, height: h), color: up ? p.deltaAbove.withAlpha(0.85) : p.deltaBelow.withAlpha(0.95), radius: 1)
                // Past the scale: a bright end, so a clipped bar cannot be taken for "exactly 6 dB".
                if abs(d) > scale { o.fillRect(CGRect(x: x, y: up ? zeroY - h : zeroY + h - 2, width: barW, height: 2), color: p.warn) }
            }
        }
        if !shown.measuring { o.line(bars.minX, zeroY, bars.maxX, zeroY, color: p.gridStrong, width: 1) }
        y += plan.barsHeight
        if plan.namesHeight > 0 {
            let nameFont = Fonts.ui(10)
            let names = BandLabels.fitting(o, font: nameFont, columnWidth: cw, gap: 4, panelWidth: wide ? .infinity : min(size.width, 479))
            for i in 0..<8 { o.text(names[i], x: bars.minX + CGFloat(i) * cw + cw / 2, y: y + 2, font: nameFont, color: p.textDim, h: .center, v: .top) }
            y += plan.namesHeight
        }
        if plan.numbersHeight > 0 {
            let f10 = Fonts.mono(10)
            for (i, v) in shown.bands.enumerated() where i < 8 && !shown.measuring {
                let text = v.map { Fmt.number(Float($0) / 10, signed: true) } ?? Fmt.dash
                o.text(text, x: bars.minX + CGFloat(i) * cw + cw / 2, y: y + 1, font: f10, color: v == nil ? p.textFaint : p.text, h: .center, v: .top)
            }
            y += plan.numbersHeight
        }
        // Footer: what was done to the bars.
        let footFont = Fonts.ui(10)
        let footY = y + plan.footerHeight / 2 + 1
        var right = r.maxX
        if plan.captionHeight == 0 {
            right -= o.text("\u{00B1}\(Int(scale)) dB", x: right, y: footY, font: footFont, color: p.textFaint, h: .right, v: .middle) + 8
        }
        do {
            let state = shown.levelMatch ? "bands level-matched" : "bands not level-matched"
            var forms = [state]
            if let t = shown.offsetTenths { forms.insert("\(state) \u{00B7} \(ComparisonText.louder(Float(t) / 10))", at: 0) }
            if let text = forms.first(where: { r.minX + o.measure($0, font: footFont) <= right }) {
                o.text(text, x: r.minX, y: footY, font: footFont, color: p.textDim, v: .middle)
            }
        }
    }

    func compareAccessibilityText(_ c: ComparisonSnapshot, _ f: AnalysisFrame) -> String {
        ensureCompareShown()
        guard let shown = compareShown else { return "" }
        func plain(_ s: String) -> String { s == Fmt.dash ? "no value" : s.replacingOccurrences(of: Fmt.minus, with: "-") }
        var parts = ["compared with reference \(ComparisonText.referenceLegends(c.name)[0]), B minus A"]
        for row in shown.rows { parts.append("\(Self.compareLabels[row.kind].long.replacingOccurrences(of: " \u{2248}", with: "")) \(plain(row.delta)) \(Self.compareLabels[row.kind].unit)") }
        if shown.measuring {
            parts.append("bands: measuring B")
        } else {
            let bands = shown.bands.enumerated().compactMap { i, v in v.map { "\(BandEnergy.names[i]) \(String(format: "%+.1f", Float($0) / 10))" } }
            if !bands.isEmpty { parts.append("bands\(shown.levelMatch ? ", level-matched" : ""): " + bands.joined(separator: ", ") + " dB") }
        }
        return parts.joined(separator: ", ")
    }
}
