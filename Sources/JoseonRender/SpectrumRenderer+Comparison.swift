import AppKit
import Metal
import simd
import JoseonCore

// A/B compare in the spectrum: the calm reference trace "A", the difference lane `B − A` under the plot, the second
// headphone response, and the words that go with them. The math is `ComparisonCurves`; the rules are listed in `Comparison.swift`.

/// What the difference lane shows right now.
enum LaneState: Hashable {
    case none
    /// `B − A` of the long-term spectra.
    case signal
    /// `response_B − response_A`.
    case headphone
    /// B has under 5 s of long-term data: no curve yet.
    case measuring
    /// Headphone mode without two headphones to compare: the lane says why and draws no curve.
    case unavailable(String)
}

extension SpectrumRenderer {
    // The lane's own scale: ±12 dB ticks on ±14 dB of room, like the headphone band. Two masters of one track differ by
    // 1 to 3 dB, which is a hairline on ±12: while the whole curve stays inside ±4.5 dB the axis is ±6 (it goes back to ±12
    // when the curve passes ±5.5). The tick labels say which one it is.
    static let laneAxes: [Float] = [6, 12]
    /// A is a 1.5 pt line.
    static let referenceHalfWidth: Float = 0.75
    var laneHalfSpanDB: Float { laneAxisDB * 14 / 12 }

    /// Where the x axis stands: under the lane when there is one.
    var axisBottom: CGFloat { laneShown ? laneBody.maxY : plot.maxY }
    /// The cursor hairline runs through the plot and the lane.
    var cursorBottom: CGFloat { axisBottom }

    enum PointerArea { case plot, lane }
    /// The part of the panel with a frequency axis under a point.
    func pointerArea(_ p: CGPoint) -> PointerArea? {
        if plot.contains(p) { return .plot }
        return laneShown && laneBody.contains(p) ? .lane : nil
    }

    func laneY(_ d: Float) -> Float {
        Float(laneBody.minY) + Float(laneBody.height) * (laneHalfSpanDB - d) / (2 * laneHalfSpanDB)
    }
    func laneDB(atY y: CGFloat) -> Float {
        laneHalfSpanDB - Float((y - laneBody.minY) / max(laneBody.height, 1)) * 2 * laneHalfSpanDB
    }
    var laneTicks: [Float] {
        let h = laneBody.height, a = laneAxisDB
        if h >= 84 { return [a, a / 2, 0, -a / 2, -a] }
        // A low lane: the zero line and one tick pair at half the axis (±3 on the ±6 axis, ±6 on ±12), which stands
        // clear of the lane's edges. The lane is never lower than `laneMinimumBodyHeight`, so it never has no scale.
        return [a / 2, 0, -a / 2]
    }

    /// The reference's headphone, when the band shows it as a second trace: A has a response, and the live headphone is
    /// another model.
    var referenceHeadphoneName: String? {
        guard let c = comparison, let name = c.headphoneName, c.responseDB != nil, let hp = frame?.headphone, hp.modelName != name else { return nil }
        return name
    }

    /// The lane's value at a frequency: the array the lane draws, so the readout and the curve cannot disagree.
    func laneValue(atHz hz: Float) -> Float? {
        switch laneState {
        case .signal: return compare.value(of: compare.difference, atHz: hz)
        case .headphone: return compare.value(of: compare.responseDifference, atHz: hz)
        default: return nil
        }
    }

    /// The text reads numbers of the comparison: they must belong to the newest frame (offscreen renders paint the text
    /// before the first draw).
    func ensureComparisonCurrent() {
        if !curvesValid, let f = frame { rebuildCurves(f) }
    }

    // MARK: Curves

    func rebuildComparison(_ c: ComparisonSnapshot, _ f: AnalysisFrame, table: ResampleTable) {
        let s = f.spectrum
        let n = pointCount, bins = s.frequencies.count
        referenceRun = nil; referenceResponseRun = nil
        laneRuns.removeAll(keepingCapacity: true)
        guard bins >= 2, s.average.count >= bins else { laneState = .none; return }
        compare.setReference(c, liveFrequencies: s.frequencies)
        compare.update(liveAverage: s.average, liveTilt: liveTiltDBPerOctave, levelMatch: comparisonLevelMatch, displayFloorDB: musicRange.min)

        // A, on the plot's points: through the same table as B's long-term curve, so the two are drawn alike. Only the
        // points whose source bins all lie inside A's frequency range are drawn.
        var run: Range<Int>?
        if let ov = compare.overlap, ov.count >= 4 {
            let binsPerOctave = Float(bins - 1) / log2(s.frequencies[bins - 1] / s.frequencies[0])
            let pointsPerOctave = Float(n - 1) / log2(axis.maxHz / axis.minHz)
            let margin = max(Int((binsPerOctave / pointsPerOctave / 2).rounded(.up)) + 1, 2)
            let first = min(ov.lowerBound + (ov.lowerBound == 0 ? 0 : margin), ov.upperBound)
            let last = max(ov.upperBound - (ov.upperBound == bins - 1 ? 0 : margin), ov.lowerBound)
            let a = max(Int((axis.position(s.frequencies[first]) * Float(n - 1)).rounded(.up)), 0)
            let b = min(Int((axis.position(s.frequencies[last]) * Float(n - 1)).rounded(.down)), n - 1)
            if b - a >= 2 { run = a..<(b + 1) }
        }
        if let run {
            if comparisonSource.count != bins { comparisonSource = [Float](repeating: -1000, count: bins) }
            let lo = shownRange.min, hi = shownRange.max
            for i in 0..<bins { let v = compare.referenceDrawn[i]; comparisonSource[i] = v.isFinite ? v : -1000 }
            table.apply(comparisonSource, minDB: lo, maxDB: hi, into: pointer(.reference))
            slotValid[Slot.reference.rawValue] = true
            referenceRun = run
            if hpShown, referenceHeadphoneName != nil, compare.referenceResponse.count == bins {
                for i in 0..<bins { let v = compare.referenceResponse[i]; comparisonSource[i] = v.isFinite ? v : -1000 }
                let half = Self.hpBandHalfSpanDB, full = 2 * half / Self.hpBandFraction
                table.apply(comparisonSource, minDB: half - full, maxDB: half, into: pointer(.referenceResponse))
                slotValid[Slot.referenceResponse.rawValue] = true
                referenceResponseRun = run
            }
        }

        // The lane.
        var source: [Float] = []
        switch comparisonMode {
        case .signal:
            if f.loudness.measuredSeconds < ComparisonCurves.minimumSecondsB { laneState = .measuring } else { laneState = .signal; source = compare.difference }
        case .headphone:
            if c.responseDB == nil || c.headphoneName == nil {
                laneState = .unavailable("no headphone in A")
            } else if let hp = f.headphone {
                if hp.modelName == c.headphoneName {
                    laneState = .unavailable("same headphone in A and B")
                } else {
                    compare.updateHeadphone(liveResponse: hp.responseDB)
                    laneState = compare.responseDifference.isEmpty ? .unavailable("no headphone response") : .headphone
                    source = compare.responseDifference
                }
            } else {
                laneState = .unavailable("no headphone set for B")
            }
        }
        guard source.count == bins else { return }
        // Fractional bin index of every plot point (the bins are uniform on a log axis), kept while the layout stands.
        let f0 = s.frequencies[0], fN = s.frequencies[bins - 1]
        if lanePointIndexKey.0 != n || lanePointIndexKey.1 != bins || lanePointIndexKey.2 != f0 || lanePointIndexKey.3 != fN {
            lanePointIndexKey = (n, bins, f0, fN)
            let span = log(fN / f0)
            lanePointIndex = (0..<n).map { log(axis.frequency(Float($0) / Float(n - 1)) / f0) / span * Float(bins - 1) }
        }
        let value = pointer(.lane), positive = pointer(.lanePositive), negative = pointer(.laneNegative), zero = pointer(.laneZero)
        var reach: Float = 0
        source.withUnsafeBufferPointer { src in
            for j in 0..<n {
                let idx = lanePointIndex[j]
                var d = Float.nan
                if idx >= 0, idx <= Float(bins - 1) {
                    let i = min(Int(idx), bins - 2)
                    let t = idx - Float(i)
                    d = src[i] * (1 - t) + src[i + 1] * t
                }
                laneValues[j] = d
                if d.isFinite { reach = max(reach, abs(d)) }
            }
        }
        let axisDB: Float = laneAxisDB <= 6 ? (reach > 5.5 ? 12 : 6) : (reach < 4.5 ? 6 : 12)
        if axisDB != laneAxisDB { laneAxisDB = axisDB; needsDisplay = true }
        let half = laneHalfSpanDB
        var start = -1
        do {
            for j in 0..<n {
                let d = laneValues[j]
                zero[j] = 0.5
                if d.isFinite {
                    let v = min(max((d + half) / (2 * half), 0), 1)
                    value[j] = v; positive[j] = max(v, 0.5); negative[j] = min(v, 0.5)
                    if start < 0 { start = j }
                } else {
                    value[j] = 0.5; positive[j] = 0.5; negative[j] = 0.5
                    if start >= 0 { if j - start >= 2 { laneRuns.append(start..<j) }; start = -1 }
                }
            }
        }
        if start >= 0, n - start >= 2 { laneRuns.append(start..<n) }
    }

    // MARK: Metal

    private func uploadRun(_ slot: Slot, _ run: Range<Int>) -> (buffer: MTLBuffer, offset: Int, count: Int)? {
        guard let a = arena.allocate(Float.self, count: run.count) else { return nil }
        a.pointer.update(from: pointer(slot) + run.lowerBound, count: run.count)
        return (arena.buffer, a.offset, run.count)
    }

    /// The rect a run of plot points covers, inside `area`.
    private func runRect(_ run: Range<Int>, in area: CGRect) -> SIMD4<Float> {
        let n = Float(max(pointCount - 1, 1))
        return SIMD4(Float(area.minX) + Float(area.width) * Float(run.lowerBound) / n, Float(area.minY),
                     Float(area.width) * Float(run.count - 1) / n, Float(area.height))
    }

    /// A: a 1.5 pt line in saturated gold at 90 %, no fill, no glow. It is a reference, not data of the moment.
    func drawReferenceTrace(_ enc: MTLRenderCommandEncoder, _ g: inout Globals, uniforms base: CurveUniforms) {
        guard let run = referenceRun, slotValid[Slot.reference.rawValue], let values = uploadRun(.reference, run) else { return }
        var u = base
        u.rect = runRect(run, in: plot)
        u.color = palette.reference; u.halfWidth = Self.referenceHalfWidth
        if run.upperBound < pointCount { u.fadeRight = 0 }
        // Nothing of A enters the headphone band.
        let sc = Float(scale)
        let top = hpShown ? hpBand.maxY : plot.minY
        enc.setScissorRect(MTLScissorRect(x: Int(Float(plot.minX) * sc), y: Int(Float(top) * sc), width: max(Int(Float(plot.width) * sc), 1),
                                          height: max(Int(Float(plot.maxY - top) * sc), 1)))
        drawCurveLine(enc, values: values, uniforms: u, additive: false, lut: nil, globals: &g)
        enc.setScissorRect(MTLScissorRect(x: Int(Float(plot.minX) * sc), y: Int(Float(plot.minY) * sc), width: max(Int(Float(plot.width) * sc), 1),
                                          height: max(Int(Float(plot.height) * sc), 1)))
    }

    /// The response of A's headphone in the band: dotted amber, under the solid response of the live headphone.
    func drawReferenceResponse(_ enc: MTLRenderCommandEncoder, _ g: inout Globals, uniforms base: CurveUniforms) {
        guard let run = referenceResponseRun, slotValid[Slot.referenceResponse.rawValue], let values = uploadRun(.referenceResponse, run) else { return }
        var u = base
        u.rect = runRect(run, in: plot)
        u.color = palette.hpResponse.withAlpha(0.85 * Self.hpBandAlpha + 0.25); u.halfWidth = 0.85; u.dashPeriod = 5; u.dashDuty = 0.42
        if run.upperBound < pointCount { u.fadeRight = 0 }
        drawCurveLine(enc, values: values, uniforms: u, additive: false, lut: nil, globals: &g)
    }

    /// Grid of the lane: the frequency lines of the plot, the zero line, ±6 and ±12.
    func addLaneGrid() {
        let p = palette
        let top = Float(laneBody.minY), bottom = Float(laneBody.maxY), left = Float(laneBody.minX), right = Float(laneBody.maxX)
        for f in LogAxis.minor where f > axis.minHz && f < axis.maxHz { batch.vline(x(forHz: f), top, bottom, color: p.gridMinor) }
        for f in LogAxis.labeled where f > axis.minHz && f < axis.maxHz { batch.vline(x(forHz: f), top, bottom, color: p.gridMajor) }
        for d in laneTicks where d != 0 { batch.hline(left, right, laneY(d), color: abs(d) == laneAxisDB || laneTicks.count <= 3 ? p.gridMajor : p.gridMinor) }
        batch.hline(left, right, laneY(0), color: p.gridStrong)
    }

    /// The difference: filled toward zero (light where B has more, darker where B has less), a thin line on top. Gaps
    /// where there is no value.
    func drawLane(_ enc: MTLRenderCommandEncoder, _ g: inout Globals) {
        guard !laneRuns.isEmpty else { return }
        let p = palette
        let sc = Float(scale)
        enc.setScissorRect(MTLScissorRect(x: Int(Float(laneBody.minX) * sc), y: Int(Float(laneBody.minY) * sc), width: max(Int(Float(laneBody.width) * sc), 1),
                                          height: max(Int(Float(laneBody.height) * sc), 1)))
        let fade: Float = compact ? 8 : 16
        for run in laneRuns {
            guard let positive = uploadRun(.lanePositive, run), let negative = uploadRun(.laneNegative, run), let zero = uploadRun(.laneZero, run) else { continue }
            var u = CurveUniforms()
            u.rect = runRect(run, in: laneBody)
            u.count = Float(run.count)
            u.fadeRight = run.upperBound >= pointCount ? fade : 0
            for (values, color) in [(positive, p.deltaAbove.withAlpha(highContrast ? 0.62 : 0.48)), (negative, p.deltaBelow.withAlpha(highContrast ? 0.70 : 0.55))] {
                u.color = color
                enc.setRenderPipelineState(ctx.curveBand)
                enc.setVertexBuffer(values.buffer, offset: values.offset, index: 0)
                enc.setVertexBuffer(zero.buffer, offset: zero.offset, index: 3)
                enc.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
                enc.setVertexBytes(&u, length: MemoryLayout<CurveUniforms>.stride, index: 2)
                enc.setFragmentBytes(&u, length: MemoryLayout<CurveUniforms>.stride, index: 2)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: run.count * 2)
            }
        }
        // The zero line again, over the fills and under the curve.
        batch.hline(Float(laneBody.minX), Float(laneBody.maxX), laneY(0), color: p.gridStrong)
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
        for run in laneRuns {
            guard let values = uploadRun(.lane, run) else { continue }
            var u = CurveUniforms()
            u.rect = runRect(run, in: laneBody)
            u.color = p.deltaLine; u.halfWidth = 0.6
            u.fadeRight = run.upperBound >= pointCount ? fade : 0
            drawCurveLine(enc, values: values, uniforms: u, additive: false, lut: nil, globals: &g)
        }
    }

    // MARK: Text

    /// Tick labels of the lane, on the left like the music scale: signed, so they cannot be taken for levels.
    func drawLaneAxis(_ o: OverlayContext) {
        let font = axisFont
        for d in laneTicks {
            o.text(d == 0 ? "0" : Fmt.number(d, digits: 0, signed: true), x: plot.minX - 7, y: CGFloat(laneY(d)), font: font, color: palette.textDim, h: .right, v: .middle)
        }
    }

    private var laneStripMidY: CGFloat { (lane.minY + laneBody.minY) / 2 + 0.5 }

    /// The strip over the lane: its legend (`B − A`), what was done to the levels, and the smoothing. The `measuring B…`
    /// state and the reasons of the headphone mode stand in the empty lane.
    func drawLaneText(_ o: OverlayContext, _ f: AnalysisFrame) {
        ensureComparisonCurrent()
        let p = palette
        let y = laneStripMidY
        let size: CGFloat = compact ? 10 : 11
        var x = plot.minX + 2
        // Swatch: the two tones of the fill around a zero line.
        o.fillRect(CGRect(x: x, y: y - 5, width: 16, height: 5), color: p.deltaAbove.withAlpha(0.55))
        o.fillRect(CGRect(x: x, y: y, width: 16, height: 5), color: p.deltaBelow.withAlpha(0.75))
        o.line(x, y, x + 16, y, color: p.deltaLine, width: 1)
        x += 21
        x += o.text(ComparisonText.deltaName, x: x, y: y, font: Fonts.ui(size, .semibold), color: p.text, v: .middle) + (compact ? 7 : 10)

        var right = plot.maxX - 2
        let detailFont = Fonts.ui(size, .regular)
        let forms = laneDetailForms(f)
        if bandHiddenNoteInStrip, let note = ComparisonText.bandHidden.last {
            // The header had no room for it: the strip gives up its detail before this goes unsaid.
            let w = o.measure(note, font: detailFont)
            if x + w <= right {
                o.text(note, x: right, y: y, font: detailFont, color: mix(p.warn, p.textDim, t: 0.4), h: .right, v: .middle)
                right -= w + 12
            }
        } else if !compact, laneState == .signal || laneState == .headphone {
            let note = "1/6 oct"
            let w = o.measure(note, font: detailFont)
            if let shortest = forms.last, x + o.measure(shortest, font: detailFont) + 16 + w <= right {
                o.text(note, x: right, y: y, font: detailFont, color: p.textFaint, h: .right, v: .middle)
                right -= w + 16
            }
        }
        if laneState == .signal, comparisonLevelMatch, compare.levelOffsetDB != nil, let shortest = forms.last {
            // The plot shows the two curves as played; only the lane is level-matched. Said once, here, and before the
            // long form of the detail: it is what keeps the plot and the lane from contradicting each other.
            let room = right - (x + o.measure(shortest, font: detailFont) + 16)
            if let note = ComparisonText.asPlayedNotes.first(where: { o.measure($0, font: detailFont) <= room }) {
                o.text(note, x: right, y: y, font: detailFont, color: p.textDim, h: .right, v: .middle)
                right -= o.measure(note, font: detailFont) + 16
            }
        }
        if let text = forms.first(where: { x + o.measure($0, font: detailFont) <= right }) {
            o.text(text, x: x, y: y, font: detailFont, color: p.textDim, v: .middle)
        }

        var center = ""
        switch laneState {
        case .measuring: center = ComparisonText.measuring(seconds: f.loudness.measuredSeconds)
        case .unavailable(let why): center = why
        default: break
        }
        if !center.isEmpty, o.measure(center, font: detailFont) + 12 <= laneBody.width {
            o.text(center, x: laneBody.midX, y: laneBody.midY, font: detailFont, color: p.textDim, h: .center, v: .middle)
        }
    }

    /// What the strip says after `B − A`, longest form first.
    func laneDetailForms(_ f: AnalysisFrame) -> [String] {
        switch laneState {
        case .signal:
            guard let offset = compare.levelOffsetDB else { return ["no common content in 100 Hz\u{2013}10 kHz", "no common content"] }
            let long = ComparisonText.louder(offset), short = ComparisonText.louderShort(offset)
            return comparisonLevelMatch ? ["level-matched, \(long)", "matched, \(short)", short] : ["not level-matched, \(long)", "not matched, \(short)", "not matched"]
        case .headphone:
            let b = f.headphone?.modelName ?? "B", a = comparison?.headphoneName ?? "A"
            return ["headphone response: \(b) \u{2212} \(a)", "headphone: \(b) \u{2212} \(a)", "headphone response", "headphone"]
        case .unavailable:
            return ["headphone response", "headphone"]
        case .measuring, .none:
            return []
        }
    }

    func combineComparisonSignature(_ c: ComparisonSnapshot, into h: inout Hasher) {
        ensureComparisonCurrent()
        h.combine(c.id); h.combine(c.name); h.combine(c.headphoneName); h.combine(comparisonLevelMatch); h.combine(comparisonMode == .headphone)
        h.combine(hpHidden); h.combine(laneShown); h.combine(laneHiddenTooSmall); h.combine(laneState)
        if let o = compare.levelOffsetDB { h.combine(Int((o * 10).rounded())) }
        if laneState == .measuring, let f = frame { h.combine(Int(f.loudness.measuredSeconds)) }
    }

    // MARK: Legend

    private func legendFont() -> CTFont { Fonts.ui(compact ? 10 : 11, .regular) }
    private func legendWidth(_ o: OverlayContext, _ label: String) -> CGFloat { 21 + o.measure(label, font: legendFont()) + (compact ? 9 : 14) }

    /// Room the legend needs for "Mid", "B" and "A" in their shortest forms.
    func minimumComparisonLegendWidth(_ o: OverlayContext) -> CGFloat {
        (options.showMid ? legendWidth(o, "Mid") : 0) + legendWidth(o, "B") + legendWidth(o, "A")
    }

    /// Room the legend keeps before a "hidden" note: Mid, and with a reference B and A.
    func minimumLegendWidth(_ o: OverlayContext) -> CGFloat {
        comparison != nil ? minimumComparisonLegendWidth(o) : (options.showMid ? legendWidth(o, "Mid") : 0)
    }

    func bandHiddenWidth(_ o: OverlayContext, short: Bool = false, text: String? = nil) -> CGFloat {
        o.measure(text ?? (short ? ComparisonText.bandHidden[ComparisonText.bandHidden.count - 1] : ComparisonText.bandHidden[0]), font: legendFont()) + (compact ? 9 : 14)
    }

    /// "B · long-term" and "A · name", together: the longest pair of forms that fits. False when not even "B" and "A" fit.
    func drawComparisonLegend(_ o: OverlayContext, _ c: ComparisonSnapshot, x: inout CGFloat, y: CGFloat, limit: CGFloat) -> Bool {
        let p = palette
        var aForms = ComparisonText.referenceLegends(c.name)
        // A long name (the user can rename a reference) is cut, with an ellipsis, at 200 pt.
        aForms[0] = Self.truncated(o, aForms[0], font: legendFont(), width: 200)
        let shortA = aForms[aForms.count - 1]
        var pairs = aForms.map { (ComparisonText.liveLegend, $0) }
        pairs.append(("B", shortA))
        let gap: CGFloat = compact ? 9 : 14
        guard let pair = pairs.first(where: { x + legendWidth(o, $0.0) + legendWidth(o, $0.1) - gap <= limit }) else { return false }
        // The swatches are the lines of the plot: B is the long-term curve (cool grey), A the saturated gold.
        guard legendItem(o, pair.0, x: &x, y: y, limit: limit, draw: legendStroke(o, p.liveLongTerm, width: 1.25)) else { return false }
        return legendItem(o, pair.1, x: &x, y: y, limit: limit, draw: legendStroke(o, p.reference, width: 1.5))
    }

    static func truncated(_ o: OverlayContext, _ s: String, font: CTFont, width: CGFloat) -> String {
        guard o.measure(s, font: font) > width else { return s }
        var t = s
        while t.count > 2, o.measure(t + "\u{2026}", font: font) > width { t.removeLast() }
        return t.trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    // MARK: Cursor

    /// `A −47.0 dB · B−A +2.1 dB`. A dash where the lane has no value (a gap, or B still measuring).
    func comparisonCursorItems(_ v: CursorValues) -> [CursorReadoutItem] {
        var out: [CursorReadoutItem] = []
        if let a = v.reference { out.append(.init(text: "A \(Fmt.db(a)) dB", rank: CursorReadoutItem.reference, tone: .reference)) }
        guard laneState != .none else { return out }
        let name = (laneState == .headphone ? "hp " : "") + "B\u{2212}A"
        out.append(.init(text: v.delta.map { "\(name) \(Fmt.number($0, signed: true)) dB" } ?? "\(name) \(Fmt.dash)", rank: CursorReadoutItem.delta))
        return out
    }

    /// The same in the box at the pointer, with what the number is.
    func comparisonHoverLines(_ v: CursorValues) -> [String] {
        var lines: [String] = []
        if let a = v.reference, let b = v.liveAverage { lines.append("A  \(Fmt.db(a)) dB   B long-term  \(Fmt.db(b)) dB") }
        switch laneState {
        case .signal:
            let how = comparisonLevelMatch ? "level-matched, 1/6 oct" : "1/6 oct"
            lines.append(v.delta.map { "\(ComparisonText.deltaName)  \(Fmt.number($0, signed: true)) dB  (\(how))" } ?? "\(ComparisonText.deltaName)  \(Fmt.dash)  (a curve is at the display floor)")
        case .headphone:
            lines.append(v.delta.map { "\(ComparisonText.deltaName)  \(Fmt.number($0, signed: true)) dB  (headphone response)" } ?? "\(ComparisonText.deltaName)  \(Fmt.dash)")
        case .measuring:
            lines.append("\(ComparisonText.deltaName)  \(Fmt.dash)  (\(ComparisonText.measuring))")
        case .unavailable, .none:
            break
        }
        return lines
    }

    func pointerLevelLine(_ hv: CGPoint, _ area: PointerArea) -> String {
        switch area {
        case .plot:
            let r = shownRange
            return "pointer level  \(Fmt.number(r.min + Float((plot.maxY - hv.y) / plot.height) * (r.max - r.min))) dB"
        case .lane:
            return "pointer \(ComparisonText.deltaName)  \(Fmt.number(laneDB(atY: hv.y), signed: true)) dB"
        }
    }

    // MARK: Accessibility

    func comparisonAccessibilityText(_ c: ComparisonSnapshot, _ f: AnalysisFrame) -> String {
        ensureComparisonCurrent()
        var s = ". Compared with reference \(ComparisonText.referenceLegends(c.name)[0])"
        switch laneState {
        case .measuring: s += ": measuring B"
        case .signal:
            if let o = compare.levelOffsetDB { s += ": \(ComparisonText.louder(o).replacingOccurrences(of: Fmt.minus, with: "-")) over 100 Hz to 10 kHz" }
            s += comparisonLevelMatch ? ", difference lane level-matched" : ", difference lane not level-matched"
        case .headphone: s += ": difference lane shows headphone response, \(f.headphone?.modelName ?? "B") minus \(c.headphoneName ?? "A")"
        case .unavailable(let why): s += ": \(why)"
        case .none: break
        }
        if laneHiddenTooSmall { s += ". Difference lane hidden: the panel is too small" }
        return s
    }

    // MARK: Tests

    /// The lane's values in dB per plot point, NaN where the lane draws nothing. Empty without a curve.
    var laneValuesForTesting: [Float] {
        ensureComparisonCurrent()
        guard laneState == .signal || laneState == .headphone else { return [] }
        return Array(laneValues.prefix(pointCount))
    }
    var laneRectForTesting: CGRect { lane }
    var laneBodyForTesting: CGRect { laneBody }
    var laneStateForTesting: LaneState { ensureComparisonCurrent(); return laneState }
    var headphoneBandHiddenForTesting: Bool { hpHidden }
    /// Share of the whole plot height (plot and lane) that the music scale keeps.
    var musicFractionForTesting: CGFloat {
        let total = plot.height + lane.height
        return total > 0 ? (plot.height - (hpShown ? hpBand.height : 0)) / total : 0
    }
    /// The reference trace in dB per plot point, nil where it is not drawn.
    var referenceTraceForTesting: [Float?] {
        ensureComparisonCurrent()
        guard let run = referenceRun else { return [] }
        let r = shownRange
        return (0..<pointCount).map { run.contains($0) ? pointer(.reference)[$0] * (r.max - r.min) + r.min : nil }
    }
}
