import AppKit
import Metal
import simd
import JoseonCore

/// The session timeline: the last minutes of listening as lanes over one time axis.
///
/// Lanes, top to bottom: Loudness (short-term as a soft band, the momentary maximum as a thin line, the target dotted),
/// Peak (true peak per second as stems, 0 dBTP in red, overs red, clip ticks on the top edge), At the ear (only with data),
/// Tone (the 8 band energies as a hue strip, only on tall panels). Under the lanes: the stress-flag span bars. Over them: a
/// narrow row for the track flags. Nothing is drawn over a trace except hairlines.
///
/// X is AUDIO time (see `TimelineModel`), newest at the right. Labels are wall-clock times at round minutes, looked up
/// from the samples; a jump of the wall clock draws a gap mark on the axis.
///
/// Cost: the picture depends on the snapshot, the layout and the cursor only. Analysis frames are not read
/// (`usesAnalysisFrames` is false), so a display tick with the same snapshot revision and the same cursor draws nothing.
final class TimelineRenderer: PanelRenderer {
    // MARK: Options (the view and the offscreen renderer set them)

    var windowSeconds = 900 { didSet { if windowSeconds != oldValue { rebuild() } } }
    var targetLUFS: Float? { didSet { if targetLUFS != oldValue { rebuild() } } }
    /// The Tone lane is allowed. It shows from 260 pt of height.
    var showBands = true { didSet { if showBands != oldValue { relayout() } } }
    /// The "At the ear" lane is allowed (it still needs samples with a level). Off by default: the number stays in the readout.
    var showLevelAtEar = false { didSet { if showLevelAtEar != oldValue { relayout() } } }
    var timeZone = TimeZone.current { didSet { if timeZone != oldValue { bump() } } }
    /// False when the newest sample is older than "now" (the audio clock stands still): the right end of the axis then
    /// carries the time of that sample instead of "now".
    var isLive = true { didSet { if isLive != oldValue { bump() } } }

    private(set) var model = TimelineModel(snapshot: SessionSnapshot(), windowSeconds: 900)
    private var snapshot = SessionSnapshot()
    private var hasSnapshot = false
    /// Counts what the picture depends on (snapshot, options). Part of the text signature.
    private(set) var contentVersion = 0
    /// Snapshots that were taken in (tests: an unchanged revision must not count).
    private(set) var rebuildCount = 0

    /// Takes a snapshot in. Equal revision = nothing to do.
    func setSnapshot(_ s: SessionSnapshot) {
        if hasSnapshot, s.revision == snapshot.revision { return }
        snapshot = s
        hasSnapshot = true
        rebuild()
    }

    private func rebuild() {
        let rowsBefore = model.spanRows, earBefore = model.hasLevelA
        model = TimelineModel(snapshot: snapshot, windowSeconds: windowSeconds)
        rebuildCount &+= 1
        updateLoudnessRange()
        if model.spanRows != rowsBefore || model.hasLevelA != earBefore { computeLayout() }
        bump()
    }

    private func relayout() { computeLayout(); bump() }
    private func bump() { contentVersion &+= 1; needsDisplay = true; labelCache = nil }

    // MARK: Panel plumbing

    override var kind: PanelKind { .timeline }
    override var makesPointerCursors: Bool { true }
    override var usesAnalysisFrames: Bool { false }
    override var cursorReadoutFollowsFrames: Bool { false }
    override var accessibilityLabelText: String { "Session timeline" }
    override var accessibilityValueText: String { model.accessibilityValue }

    override var staticSignature: Int {
        var h = Hasher()
        h.combine(super.staticSignature); h.combine(model.hasLevelA); h.combine(showLevelAtEar); h.combine(showBands); h.combine(model.spanRows)
        return h.finalize()
    }
    override var dynamicSignature: Int {
        var h = Hasher()
        h.combine(contentVersion); h.combine(focusIndex)
        return h.finalize()
    }

    // MARK: Layout

    enum LaneKind { case loudness, peak, ear, tone }
    struct Lane { var kind: LaneKind; var rect: CGRect; var captionY: CGFloat }

    private(set) var lanes: [Lane] = []
    /// x range of every lane.
    private(set) var plotX: ClosedRange<CGFloat> = 0...1
    private var headerMidY: CGFloat = 10
    private var flagRowY: CGFloat = 20
    private var lanesBottom: CGFloat = 0
    private var spansTop: CGFloat = 0
    private var axisY: CGFloat = 0
    /// Names and numbers stand in a column right of the lanes. Narrow panels put them over each lane.
    private var wide: Bool { size.width >= 760 }
    /// A low strip: span bars without titles.
    private var strip: Bool { size.height < 180 }
    private var spanRowHeight: CGFloat { strip ? 5 : 15 }
    private var spanBarHeight: CGFloat { strip ? 3 : 13 }
    private var showsTone: Bool { showBands && size.height >= 260 }

    override func layoutChanged() { computeLayout(); labelCache = nil }

    private func computeLayout() {
        let left: CGFloat = 36
        let right: CGFloat = wide ? 122 : 12
        let header: CGFloat = strip ? 18 : 24
        let flagRow: CGFloat = 8
        let axis: CGFloat = strip ? 18 : 22
        let rows = CGFloat(max(model.spanRows, 1))
        let spansHeight = rows * spanRowHeight + 3
        let caption: CGFloat = wide ? 0 : 15
        let gap: CGFloat = wide ? (strip ? 3 : 5) : 3

        var kinds: [(LaneKind, CGFloat)] = [(.loudness, 1.0), (.peak, 0.5)]
        // A low strip shows loudness and peak only; the level at the ear stays in the readout.
        if model.hasLevelA, showLevelAtEar, !strip { kinds.append((.ear, 0.5)) }
        if showsTone { kinds.append((.tone, 0.42)) }

        plotX = left...max(size.width - right, left + 10)
        headerMidY = header / 2 + 1
        // The flag row stands directly over the first lane (under that lane's caption on narrow panels).
        flagRowY = header + caption
        let top = header
        let bottom = size.height - axis - spansHeight
        let free = max(bottom - top - flagRow - CGFloat(kinds.count) * caption - CGFloat(kinds.count - 1) * gap, 8)
        let weights = kinds.reduce(0) { $0 + $1.1 }
        var y = top
        var out: [Lane] = []
        for (i, (k, w)) in kinds.enumerated() {
            let h = (free * w / weights).rounded(.down)
            y += caption
            let captionY = y - 4
            if i == 0 { y += flagRow }
            out.append(Lane(kind: k, rect: CGRect(x: plotX.lowerBound, y: y, width: plotX.upperBound - plotX.lowerBound, height: max(h, 4)), captionY: captionY))
            y += h + gap
        }
        lanes = out
        lanesBottom = (out.last?.rect.maxY ?? top)
        spansTop = lanesBottom + 3
        axisY = size.height - axis
        needsDisplay = true
    }

    private func lane(_ k: LaneKind) -> Lane? { lanes.first { $0.kind == k } }
    private var plotWidth: CGFloat { plotX.upperBound - plotX.lowerBound }
    private var pointsPerSecond: CGFloat { plotWidth / CGFloat(model.windowSeconds) }

    func x(forTime t: Double) -> CGFloat { plotX.upperBound - CGFloat(model.newestTime - t) * pointsPerSecond }
    func x(forSecondsAgo ago: Double) -> CGFloat { plotX.upperBound - CGFloat(ago) * pointsPerSecond }

    // MARK: Scales

    private(set) var loudnessRange: (top: Float, bottom: Float) = (0, -36)
    /// +3 ... -12 dBTP: what matters of a true peak happens near 0. A quieter second keeps a cap on the lane's floor.
    static let peakRange: (top: Float, bottom: Float) = (3, -12)
    static let earRange: (top: Float, bottom: Float) = (110, 40)
    static let toneRange: (top: Float, bottom: Float) = (-10, -58)

    /// The LUFS window: the top follows the loudest momentary value on a 6 LU grid, the bottom the quiet passages, between
    /// 24 and 48 LU under it. Steps of 6 LU: the scale stays put while the music plays.
    private func updateLoudnessRange() {
        var hi: Float = -.infinity, values: [Float] = []
        for s in model.samples where !s.isSilent {
            if TimelineModel.isMeasured(s.momentaryMaxLUFS) { hi = max(hi, s.momentaryMaxLUFS) }
            if TimelineModel.isMeasured(s.shortTermLUFS) { hi = max(hi, s.shortTermLUFS); values.append(s.shortTermLUFS) }
        }
        guard hi.isFinite else { loudnessRange = (0, -36); return }
        if let t = targetLUFS { hi = max(hi, t) }
        let top = min(((hi + 1) / 6).rounded(.up) * 6, 6)
        values.sort()
        let low = values.isEmpty ? top - 30 : values[values.count / 50]          // 2nd percentile: a fade-out does not set the scale
        var bottom = ((low - 3) / 6).rounded(.down) * 6
        if let t = targetLUFS { bottom = min(bottom, ((t - 3) / 6).rounded(.down) * 6) }
        bottom = min(max(bottom, top - 48), top - 24)
        loudnessRange = (top, bottom)
    }

    @inline(__always) private func unit(_ v: Float, _ r: (top: Float, bottom: Float)) -> Float { min(max((v - r.bottom) / (r.top - r.bottom), 0), 1) }
    private func y(_ v: Float, _ r: (top: Float, bottom: Float), in rect: CGRect) -> CGFloat { rect.maxY - CGFloat(unit(v, r)) * rect.height }

    /// Scale values to label, most important first. The text pass places them top-down by this order and leaves out what
    /// would stand closer than 12 pt to one already placed.
    private func scaleValues(_ k: LaneKind, height: CGFloat) -> [Float] {
        switch k {
        case .loudness:
            let r = loudnessRange
            let perLU = height / CGFloat(r.top - r.bottom)
            let step: Float = perLU * 6 >= 14 ? 6 : (perLU * 12 >= 14 ? 12 : 24)
            var out: [Float] = []
            var v = (r.top / step).rounded(.down) * step
            while v >= r.bottom - 0.01 { out.append(v); v -= step }
            return out
        case .peak: return [0, -12, -6, 3]
        case .ear: return [85, 55, 100, 70, 40]
        case .tone: return []
        }
    }

    // MARK: Focus (the second under the cursor)

    /// True when `p` is over the lanes (the flag row and the span rows included).
    private func overLanes(_ p: CGPoint) -> Bool {
        p.x >= plotX.lowerBound && p.x <= plotX.upperBound && p.y >= flagRowY && p.y <= axisY
    }

    /// Seconds before the newest sample that the cursor stands at. Linked: the shared cursor's `secondsAgo`. Not linked: the pointer.
    ///
    /// The spectrogram counts `secondsAgo` on the wall clock inside its short history; the timeline counts audio seconds back
    /// from the newest sample. The two agree while audio plays without a break, which is the case inside the few seconds the
    /// spectrogram shows; across a pause they differ by the length of the pause, and the timeline's audio axis is the one
    /// that has a place for every recorded second.
    private var focusSecondsAgo: Double? {
        if cursorLinked { return cursor?.secondsAgo }
        guard let hv = hover, overLanes(hv), !model.isEmpty else { return nil }
        return Double((plotX.upperBound - hv.x) / pointsPerSecond)
    }

    /// The sample the readout reads, nil outside the record.
    var focusIndex: Int? {
        guard let ago = focusSecondsAgo, ago <= Double(model.windowSeconds) + 0.5 else { return nil }
        return model.sampleIndex(atTime: model.newestTime - ago)
    }

    /// x of the hairline: the exact time of a cursor from another panel, the middle of the second for the timeline's own.
    private var focusX: CGFloat? {
        guard let ago = focusSecondsAgo else { return nil }
        let xx = x(forSecondsAgo: ago)
        return xx >= plotX.lowerBound - 0.5 && xx <= plotX.upperBound + 0.5 ? min(max(xx, plotX.lowerBound), plotX.upperBound) : nil
    }

    override func cursor(at point: CGPoint) -> PanelCursor? {
        guard overLanes(point), !model.isEmpty, plotWidth > 1 else { return nil }
        let t = model.newestTime - Double((plotX.upperBound - point.x) / pointsPerSecond)
        guard let i = model.sampleIndex(atTime: t) else { return nil }
        // The cursor keeps the frequency it has (the timeline has no frequency axis); without one: the peak of the frame.
        return PanelCursor(frequencyHz: cursor?.frequencyHz ?? fallbackFrequencyHz, secondsAgo: max(model.newestTime - model.samples[i].time, 0), source: .timeline)
    }

    /// The frequency a cursor made here starts with: the view sets it from the newest frame.
    var fallbackFrequencyHz: Float = 1000

    override func isOnCursor(_ point: CGPoint) -> Bool {
        guard let fx = focusX, overLanes(point) else { return false }
        return abs(point.x - fx) <= 5
    }

    /// Only the time and the pin show here: a cursor that moves along a frequency axis elsewhere repaints nothing.
    override func cursorChangeShows(from old: PanelCursor?) -> Bool {
        func shown(_ c: PanelCursor?) -> [Double]? {
            guard let c, let ago = c.secondsAgo else { return nil }
            return [ago, c.isPinned ? 1 : 0, c.source == .timeline ? 1 : 0]
        }
        return shown(old) != shown(cursor)
    }

    override func cursorShowsInText(_ c: PanelCursor) -> Bool { c.secondsAgo != nil }

    override func combineCursorSignature(_ c: PanelCursor, into h: inout Hasher) {
        h.combine(c.secondsAgo); h.combine(c.secondsAgo == nil ? false : c.isPinned); h.combine(showsPointerReadout)
    }

    // MARK: Metal

    private lazy var bulk = ShapeBatch(arena: arena, capacity: 8192)
    private lazy var bandHues: [SIMD4<Float>] = (0..<8).map {
        Palette.spectrumColor(atHz: (BandEnergy.edgesHz[$0] * BandEnergy.edgesHz[$0 + 1]).squareRoot()).rgba(1)
    }

    private func dotted(_ x0: Float, _ x1: Float, _ y: Float, color: SIMD4<Float>, on: Float = 4, period: Float = 8) {
        var x = x0
        while x < x1 - 0.5 { batch.hline(x, min(x + on, x1), y, color: color); x += period }
    }

    private func dashedV(_ x: Float, _ y0: Float, _ y1: Float, color: SIMD4<Float>, on: Float = 3, period: Float = 6) {
        var y = y0
        while y < y1 - 0.5 { batch.vline(x, y, min(y + on, y1), color: color); y += period }
    }

    /// A vertical mark through the lanes: the flag row and every lane, never the caption rows between lanes (no line
    /// through a text).
    private func vertical(_ x: Float, color: SIMD4<Float>, dashed: Bool = false, toAxis: Bool = false) {
        var parts: [(Float, Float)] = [(Float(flagRowY) + 1, Float(lanes.first?.rect.minY ?? flagRowY))]
        for l in lanes { parts.append((Float(l.rect.minY), Float(l.rect.maxY))) }
        if wide {
            // Lanes stand close together here and nothing is written between them: one line.
            parts = [(Float(flagRowY) + 1, Float(lanesBottom))]
        }
        if toAxis { parts.append((Float(lanesBottom), Float(axisY))) }
        for (a, b) in parts where b > a { if dashed { dashedV(x, a, b, color: color) } else { batch.vline(x, a, b, color: color) } }
    }

    /// Runs of neighbor samples that hold a value: a curve breaks at silence, at a missing second and at a gap.
    private func runs(_ value: (SessionSample) -> Float?, _ body: (_ first: Int, _ values: [Float]) -> Void) {
        let s = model.samples
        let gapStarts = Set(model.gaps.map(\.sampleAfter))
        var i = 0
        var current: [Float] = []
        var first = 0
        func close() { if current.count >= 2 { body(first, current) }; current.removeAll(keepingCapacity: true) }
        while i < s.count {
            let v = s[i].isSilent ? nil : value(s[i])
            let broken = i > 0 && (gapStarts.contains(i) || s[i].time - s[i - 1].time > 1.5)
            if broken { close() }
            if let v { if current.isEmpty { first = i }; current.append(v) } else { close() }
            i += 1
        }
        close()
    }

    private func setScissor(_ enc: MTLRenderCommandEncoder, _ r: CGRect?) {
        let sc = Float(scale)
        let full = CGRect(origin: .zero, size: size)
        let rr = (r ?? full).intersection(full)
        guard !rr.isNull, rr.width >= 1, rr.height >= 1 else { return }
        let x = Int((Float(rr.minX) * sc).rounded()), yy = Int((Float(rr.minY) * sc).rounded())
        let maxW = Int(Float(size.width) * sc), maxH = Int(Float(size.height) * sc)
        enc.setScissorRect(MTLScissorRect(x: min(x, max(maxW - 1, 0)), y: min(yy, max(maxH - 1, 0)),
                                          width: max(min(Int((Float(rr.width) * sc).rounded()), maxW - x), 1),
                                          height: max(min(Int((Float(rr.height) * sc).rounded()), maxH - yy), 1)))
    }

    override func draw(_ enc: MTLRenderCommandEncoder, globals g: inout Globals) {
        let p = palette
        bulk.beginFrame(scale: Float(scale))
        let x0 = Float(plotX.lowerBound), x1 = Float(plotX.upperBound)
        let samples = model.samples
        let pps = Float(pointsPerSecond)
        let marks = minuteMarks()

        // ---- Lane beds, grids, silence.
        for l in lanes {
            let r = l.rect
            let ry = Float(r.minY), rh = Float(r.height)
            batch.rect(x0, ry, x1 - x0, rh, color: p.plot, radius: 2)
            switch l.kind {
            case .loudness:
                let range = loudnessRange
                var v = (range.top / 6).rounded(.down) * 6
                while v > range.bottom + 0.01 {
                    if v < range.top - 0.01 { batch.hline(x0, x1, Float(y(v, range, in: r)), color: Int(v) % 12 == 0 ? p.gridMajor.scaledAlpha(0.7) : p.gridMinor) }
                    v -= 6
                }
            case .peak:
                let zeroY = Float(y(0, Self.peakRange, in: r))
                batch.rect(x0, ry, x1 - x0, zeroY - ry, color: p.danger.withAlpha(0.13))
                for v in [-6, -3, -9] as [Float] { batch.hline(x0, x1, Float(y(v, Self.peakRange, in: r)), color: v == -6 ? p.gridMajor.scaledAlpha(0.7) : p.gridMinor) }
            case .ear:
                for v in [55, 70, 100] as [Float] { batch.hline(x0, x1, Float(y(v, Self.earRange, in: r)), color: p.gridMinor) }
            case .tone: break
            }
            for m in marks where m.labeled {
                let mx = Float(m.x)
                if mx > x0 + 1, mx < x1 - 1 { batch.vline(mx, ry, ry + rh, color: p.gridMinor) }
            }
            // Digital silence: a neutral wash, so "no sound" does not look like "no record".
            for s in model.silences {
                let sx0 = max(Float(x(forTime: s.lowerBound)), x0), sx1 = min(Float(x(forTime: s.upperBound)), x1)
                if sx1 > sx0 { batch.rect(sx0, ry, sx1 - sx0, rh, color: SIMD4(1, 1, 1, highContrast ? 0.11 : 0.06)) }
            }
        }
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)

        // ---- Tone cells and peak stems: many small quads, in their own batch.
        if let tone = lane(.tone), !samples.isEmpty { drawTone(tone.rect, pps: pps) }
        if let peak = lane(.peak), !samples.isEmpty { drawPeakStems(peak.rect, pps: pps) }
        bulk.flush(enc, pipeline: ctx.shapeOver, globals: &g)

        // ---- Curves.
        if let l = lane(.loudness), samples.count >= 2 {
            setScissor(enc, l.rect)
            let range = loudnessRange
            let inner = l.rect.insetBy(dx: 0, dy: 1)
            var u = CurveUniforms()
            func rect(_ first: Int, _ n: Int) -> SIMD4<Float> {
                let a = Float(x(forTime: samples[first].time)), b = Float(x(forTime: samples[first + n - 1].time))
                return SIMD4(a, Float(inner.minY), b - a, Float(inner.height))
            }
            func buffer(_ values: [Float]) -> (buffer: MTLBuffer, offset: Int, count: Int)? {
                guard let a = arena.allocate(Float.self, count: values.count) else { return nil }
                for (k, v) in values.enumerated() { a.pointer[k] = unit(v, range) }
                return (arena.buffer, a.offset, values.count)
            }
            let shortTerm: (SessionSample) -> Float? = { TimelineModel.isMeasured($0.shortTermLUFS) ? $0.shortTermLUFS : nil }
            let momentary: (SessionSample) -> Float? = { TimelineModel.isMeasured($0.momentaryMaxLUFS) ? $0.momentaryMaxLUFS : nil }
            runs(shortTerm) { first, values in
                guard let b = buffer(values) else { return }
                u.rect = rect(first, values.count)
                u.color = p.accent.withAlpha(highContrast ? 0.62 : 0.50); u.fillTop = 1; u.fillBottom = 0.35
                drawCurveFill(enc, values: b, uniforms: u, lut: nil, globals: &g)
            }
            runs(momentary) { first, values in
                guard let b = buffer(values) else { return }
                u.rect = rect(first, values.count)
                u.color = mix(p.accent, SIMD4(1, 1, 1, 1), t: 0.15).withAlpha(0.62); u.halfWidth = 0.5
                drawCurveLine(enc, values: b, uniforms: u, additive: false, lut: nil, globals: &g)
            }
            runs(shortTerm) { first, values in
                guard let b = buffer(values) else { return }
                u.rect = rect(first, values.count)
                u.color = mix(p.accent, SIMD4(1, 1, 1, 1), t: 0.72); u.halfWidth = 0.8
                drawCurveLine(enc, values: b, uniforms: u, additive: false, lut: nil, globals: &g)
            }
        }
        if let l = lane(.ear), samples.count >= 2 {
            let range = Self.earRange
            let inner = l.rect.insetBy(dx: 0, dy: 1)
            let level: (SessionSample) -> Float? = { s in s.levelA.flatMap { $0 > SPLReading.floorDB + 1 ? $0 : nil } }
            let line85 = y(85, range, in: l.rect)
            var u = CurveUniforms()
            runs(level) { first, values in
                guard let a = arena.allocate(Float.self, count: values.count) else { return }
                for (k, v) in values.enumerated() { a.pointer[k] = unit(v, range) }
                let b = (arena.buffer, a.offset, values.count)
                let xa = Float(x(forTime: samples[first].time)), xb = Float(x(forTime: samples[first + values.count - 1].time))
                u.rect = SIMD4(xa, Float(inner.minY), xb - xa, Float(inner.height))
                // Time over 85 dB(A): the part of the area over the line, in the warning color.
                setScissor(enc, CGRect(x: l.rect.minX, y: l.rect.minY, width: l.rect.width, height: line85 - l.rect.minY))
                u.color = p.warn.withAlpha(0.55); u.fillTop = 1; u.fillBottom = 1
                drawCurveFill(enc, values: b, uniforms: u, lut: nil, globals: &g)
                setScissor(enc, l.rect)
                u.color = p.splBand.withAlpha(0.13); u.fillTop = 1; u.fillBottom = 0.4
                drawCurveFill(enc, values: b, uniforms: u, lut: nil, globals: &g)
                u.color = p.splBand.withAlpha(0.95); u.halfWidth = 0.7
                drawCurveLine(enc, values: b, uniforms: u, additive: false, lut: nil, globals: &g)
            }
        }
        setScissor(enc, nil)

        // ---- Reference lines over the traces.
        if let l = lane(.loudness), let t = targetLUFS, t > loudnessRange.bottom, t < loudnessRange.top {
            dotted(x0, x1, Float(y(t, loudnessRange, in: l.rect)), color: p.good.withAlpha(0.9), on: 3, period: 7)
        }
        if let l = lane(.peak) { batch.hline(x0, x1, Float(y(0, Self.peakRange, in: l.rect)), color: p.danger.withAlpha(0.95)) }
        // Solid and quiet: the trace runs close to this line for hours, and dots on a line read as noise.
        if let l = lane(.ear) { batch.hline(x0, x1, Float(y(85, Self.earRange, in: l.rect)), color: p.warn.withAlpha(highContrast ? 0.9 : 0.6)) }
        for l in lanes {
            batch.rect(x0 - 0.5, Float(l.rect.minY) - 0.5, x1 - x0 + 1, Float(l.rect.height) + 1, color: p.gridMajor, radius: 2, stroke: 1)
        }

        // ---- Events.
        let bottom = Float(lanesBottom)
        for e in model.events {
            let ex = Float(x(forTime: e.time))
            guard ex >= x0 - 0.5, ex <= x1 + 0.5 else { continue }
            switch e.kind {
            case .trackStart:
                // A pole through every lane and a small flag over them.
                let top = Float(flagRowY) + 1
                vertical(ex, color: p.textFaint.withAlpha(highContrast ? 0.8 : 0.5))
                batch.rect(batch.snap(ex) + 0.5, top, 6, 4.5, color: p.text.withAlpha(0.85), radius: 1)
            case .clip:
                guard let l = lane(.peak) else { continue }
                // A tick that stands on the top edge of the Peak lane: visible over the red zone and over a full-height stem.
                let w = max(2 / Float(scale), min(pps, 2))
                batch.rect(batch.snap(ex - w / 2), Float(l.rect.minY) - 3, w, 8, color: p.danger.withAlpha(1))
            case .interSampleOver:
                guard let l = lane(.peak) else { continue }
                batch.circle(ex, Float(l.rect.minY) + 0.5, 3, color: p.danger.withAlpha(1), stroke: 1.2)
            default: break
            }
        }

        // Stress spans: bars under the lanes. The contract carries no severity, so every span is of the amber family; each
        // kind of flag has its own hue of it, so two kinds can be told apart where the bars have no room for a title.
        for s in model.spans {
            let hue = spanColor(s.flagID)
            let sx0 = max(Float(x(forTime: s.start)), x0), sx1 = min(Float(x(forTime: s.end)), x1)
            guard sx1 > sx0 else { continue }
            let sy = Float(spansTop + CGFloat(s.row) * spanRowHeight)
            let w = max(sx1 - sx0, 2)
            if strip {
                batch.rect(sx0, sy, w, Float(spanBarHeight), color: hue.withAlpha(0.95), radius: 1.5)
            } else {
                batch.rect(sx0, sy, w, Float(spanBarHeight), color: hue.withAlpha(highContrast ? 0.34 : 0.22), radius: 2)
                batch.rect(sx0, sy, 2, Float(spanBarHeight), color: hue.withAlpha(1), radius: 1)
                if !s.isOpen { batch.rect(sx1 - 1, sy, 1, Float(spanBarHeight), color: hue.withAlpha(0.7)) }
            }
        }

        // ---- Time axis: a base line with ticks at the round minutes; a zig-zag where the wall clock jumped.
        let ay = Float(axisY)
        var from = x0
        let gapXs = model.gaps.map { Float(x(forTime: $0.time)) }.filter { $0 > x0 + 6 && $0 < x1 - 6 }.sorted()
        for gx in gapXs {
            batch.hline(from, gx - 5, ay, color: p.gridStrong)
            from = gx + 5
            let c = p.textDim
            batch.line(gx - 5, ay, gx - 2.5, ay - 3.5, width: 1.2, color: c)
            batch.line(gx - 2.5, ay - 3.5, gx + 2.5, ay + 3.5, width: 1.2, color: c)
            batch.line(gx + 2.5, ay + 3.5, gx + 5, ay, width: 1.2, color: c)
            vertical(gx, color: p.textFaint.withAlpha(0.55), dashed: true)
        }
        batch.hline(from, x1, ay, color: p.gridStrong)
        for m in marks {
            let mx = Float(m.x)
            guard mx >= x0 - 0.5, mx <= x1 + 0.5, !gapXs.contains(where: { abs($0 - mx) < 6 }) else { continue }
            batch.vline(mx, ay, ay + (m.labeled ? 5 : 3), color: m.labeled ? p.textFaint : p.gridStrong)
        }
        batch.vline(x1, ay, ay + 5, color: p.textFaint)

        // ---- Cursor: a hairline through every lane, with a dot on each trace at that second.
        if let fx = focusX {
            let top = Float(flagRowY) + 1
            let xx = Float(fx)
            vertical(xx, color: cursorLinked ? cursorLineColor : SIMD4(1, 1, 1, 0.5), toAxis: true)
            if cursorLinked, cursor?.isPinned == true { drawPinHead(x: xx, y: top + 3.5) }
            if let i = focusIndex, !samples[i].isSilent {
                let s = samples[i]
                let sx = Float(x(forTime: s.time))
                func dot(_ yy: CGFloat, _ c: SIMD4<Float>) {
                    batch.circle(sx, Float(yy), 3, color: p.plot.withAlpha(1))
                    batch.circle(sx, Float(yy), 3, color: c, stroke: 1.5)
                }
                if let l = lane(.loudness), TimelineModel.isMeasured(s.shortTermLUFS) { dot(y(s.shortTermLUFS, loudnessRange, in: l.rect), mix(p.accent, SIMD4(1, 1, 1, 1), t: 0.72)) }
                if let l = lane(.peak), TimelineModel.isMeasured(s.truePeakDBTP) { dot(y(s.truePeakDBTP, Self.peakRange, in: l.rect), s.truePeakDBTP > 0 ? p.danger : p.text) }
                if let l = lane(.ear), let a = s.levelA, a > SPLReading.floorDB + 1 { dot(y(a, Self.earRange, in: l.rect), p.splBand) }
            }
        }
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
    }

    /// Columns of at least `minWidth` points: `k` samples per column, anchored to the audio clock so the grouping does not
    /// change while the record scrolls.
    private func columns(minWidth: Float, pps: Float, _ body: (_ range: Range<Int>, _ x0: Float, _ x1: Float) -> Void) {
        let samples = model.samples
        let k = max(Int((minWidth / max(pps, 1e-4)).rounded(.up)), 1)
        let left = Float(plotX.lowerBound), right = Float(plotX.upperBound)
        var i = 0
        while i < samples.count {
            let group = Int((samples[i].time - 0.5).rounded(.down)) / k
            var j = i + 1
            while j < samples.count, Int((samples[j].time - 0.5).rounded(.down)) / k == group, samples[j].time - samples[j - 1].time < 1.5 { j += 1 }
            let a = Float(x(forTime: samples[i].time - 1)), b = Float(x(forTime: samples[j - 1].time))
            if b > left, a < right { body(i..<j, max(a, left), min(b, right)) }
            i = j
        }
    }

    private func drawPeakStems(_ r: CGRect, pps: Float) {
        let p = palette
        let range = Self.peakRange
        let zeroY = Float(y(0, range, in: r))
        let base = Float(r.maxY)
        let body = mix(p.accent, SIMD4(1, 1, 1, 1), t: 0.30)
        let gap: Float = pps >= 3 ? 1 / Float(scale) : 0
        columns(minWidth: 1 / Float(scale) * 2, pps: pps) { range_, a, b in
            var tp: Float = -.infinity
            for i in range_ where !model.samples[i].isSilent { tp = max(tp, model.samples[i].truePeakDBTP) }
            guard TimelineModel.isMeasured(tp) else { return }
            let xa = bulk.snap(a), w = max(bulk.snap(b) - xa - gap, 1 / Float(scale))
            // Under the lane's floor: the cap stands on the floor ("there was sound, far from the top").
            let top = min(Float(y(tp, range, in: r)), base - 1.5)
            // A calm body with a bright cap: the caps read as a step line, the body says "up to here". Only an over is red:
            // a modern master stands at -0.2 dBTP all day, and that is not an alarm.
            let bodyTop = max(top, zeroY)
            bulk.rect(xa, bodyTop, w, base - bodyTop, top: body.withAlpha(0.34), bottom: body.withAlpha(0.10))
            bulk.rect(xa, bodyTop, w, 1.5, color: body.withAlpha(0.95))
            if tp > 0 { bulk.rect(xa - 0.5, top, w + 1, zeroY - top, color: p.danger.withAlpha(1)) }
        }
    }

    private func drawTone(_ r: CGRect, pps: Float) {
        let range = Self.toneRange
        let rowH = Float(r.height) / 8
        columns(minWidth: 1.5, pps: pps) { range_, a, b in
            var sum = [Float](repeating: 0, count: 8)
            var n: Float = 0
            for i in range_ where !model.samples[i].isSilent && model.samples[i].bands.count >= 8 {
                for k in 0..<8 { sum[k] += model.samples[i].bands[k] }
                n += 1
            }
            guard n > 0 else { return }
            let xa = bulk.snap(a), w = max(bulk.snap(b) - xa, 1 / Float(scale))
            for k in 0..<8 {
                let t = unit(sum[k] / n, range)
                guard t > 0.01 else { continue }
                // Hue = the band's place on the frequency axis (the color system of every panel), brightness = level.
                let light = 0.05 + 0.95 * pow(t, 2.2)
                let hue = bandHues[k]
                let yy = Float(r.maxY) - Float(k + 1) * rowH
                bulk.rect(xa, yy, w, rowH, color: SIMD4(hue.x * light, hue.y * light, hue.z * light, 1))
            }
        }
    }

    // MARK: Wall-clock marks

    struct AxisMark { var x: CGFloat; var date: Date; var labeled: Bool }

    /// Round minutes on the axis. Every minute gets a tick when there is room; labels stand at a step that keeps them apart.
    func minuteMarks() -> [AxisMark] {
        guard !model.isEmpty else { return [] }
        let pps = pointsPerSecond
        let labelStep = [1, 2, 5, 10, 15, 30].first { CGFloat($0 * 60) * pps >= 80 } ?? 30
        let tickStep = [1, 5, 10].first { CGFloat($0 * 60) * pps >= 7 } ?? labelStep
        let step = min(tickStep, labelStep)
        return model.minuteMarks(stepMinutes: step, timeZone: timeZone).map { m in
            let local = Int(m.date.timeIntervalSince1970.rounded()) + timeZone.secondsFromGMT(for: m.date)
            return AxisMark(x: x(forTime: m.time), date: m.date, labeled: (local / 60) % labelStep == 0)
        }
    }

    // MARK: Text

    private var numberFont: CTFont { Fonts.mono(10) }
    private var capFont: CTFont { Fonts.ui(10, .semibold) }
    private var statFont: CTFont { Fonts.ui(10.5, .medium) }

    private func laneUnit(_ k: LaneKind) -> String {
        switch k {
        case .loudness: return "LUFS"
        case .peak: return "dBTP"
        case .ear: return "dB(A)"
        case .tone: return ""
        }
    }

    private func laneName(_ k: LaneKind) -> String {
        switch k {
        case .loudness: return "LOUDNESS"
        case .peak: return "TRUE PEAK"
        case .ear: return "AT THE EAR"
        case .tone: return "TONE"
        }
    }

    override func drawStatic(_ o: OverlayContext) {
        let p = palette
        for l in lanes {
            if wide {
                let w = o.text(laneName(l.kind), x: plotX.upperBound + 12, y: l.rect.minY + 1, font: capFont, color: p.textFaint, v: .top, tracking: 1.0)
                o.text(laneUnit(l.kind), x: plotX.upperBound + 12 + w + 6, y: l.rect.minY + 1, font: statFont, color: p.textFaint, v: .top)
            } else {
                let w = o.text(laneName(l.kind), x: plotX.lowerBound, y: l.captionY, font: capFont, color: p.textFaint, v: .bottom, tracking: 1.0)
                o.text(laneUnit(l.kind), x: plotX.lowerBound + w + 6, y: l.captionY, font: statFont, color: p.textFaint, v: .bottom)
            }
            if l.kind == .tone, l.rect.height >= 30 {
                o.text("Air", x: plotX.lowerBound - 6, y: l.rect.minY + 5, font: numberFont, color: p.textFaint, h: .right, v: .middle)
                o.text("Sub", x: plotX.lowerBound - 6, y: l.rect.maxY - 5, font: numberFont, color: p.textFaint, h: .right, v: .middle)
            }
        }
    }

    /// One stat line of a lane: an optional swatch (what the trace looks like), a caption and a value.
    private struct Stat { enum Swatch { case none, band, line }; var swatch = Swatch.none; var caption: String; var value: String; var color: SIMD4<Float> }

    private func stats(_ k: LaneKind) -> [Stat] {
        let p = palette, st = model.stats
        switch k {
        case .loudness:
            var out: [Stat] = []
            if let lo = st.shortTermLow, let hi = st.shortTermHigh {
                out.append(Stat(swatch: .band, caption: Self.shortTermRangeCaption, value: "\(Fmt.number(lo, digits: 0))\u{2026}\(Fmt.number(hi, digits: 0))", color: p.text))
            }
            if let m = st.momentaryMax { out.append(Stat(swatch: .line, caption: "M max", value: Fmt.number(m), color: p.textDim)) }
            return out
        case .peak:
            guard let tp = st.truePeakMax else { return [] }
            return [Stat(caption: "max", value: Fmt.number(tp, digits: 1, signed: true), color: tp > 0 ? p.danger : p.text)]
        case .ear:
            guard let a = st.levelAMax else { return [] }
            return [Stat(caption: "max \u{2248}", value: Fmt.number(a, digits: 0), color: a >= 85 ? p.warn : p.text)]
        case .tone: return []
        }
    }

    override func drawDynamic(_ o: OverlayContext) {
        let p = palette
        let small = numberFont

        // ---- Scales in the left gutter.
        for l in lanes {
            let range: (top: Float, bottom: Float)
            switch l.kind {
            case .loudness: range = loudnessRange
            case .peak: range = Self.peakRange
            case .ear: range = Self.earRange
            case .tone: continue
            }
            var placed: [CGFloat] = []
            for v in scaleValues(l.kind, height: l.rect.height) {
                let yy = min(max(y(v, range, in: l.rect), l.rect.minY + 4), l.rect.maxY - 4)
                guard !placed.contains(where: { abs($0 - yy) < 12 }) else { continue }
                placed.append(yy)
                let special = (l.kind == .peak && v == 0) || (l.kind == .ear && v == 85)
                o.text(Fmt.number(v, digits: 0), x: plotX.lowerBound - 6, y: yy, font: small,
                       color: special ? (l.kind == .peak ? mix(p.danger, p.text, t: 0.35) : mix(p.warn, p.text, t: 0.25)) : p.textDim, h: .right, v: .middle)
            }
        }

        // ---- Lane numbers: what the window held. Right column on wide panels, the caption row on narrow ones.
        for l in lanes {
            let list = stats(l.kind)
            if wide {
                let lx = plotX.upperBound + 12
                for (k, s) in list.enumerated() {
                    let yy = l.rect.minY + 1 + CGFloat(k + 1) * 14
                    guard yy + 10 <= l.rect.maxY + 3 else { break }
                    var xx = lx
                    xx += drawSwatch(o, s.swatch, x: xx, midY: yy + 4.5)
                    xx += o.text(s.caption + " ", x: xx, y: yy, font: statFont, color: p.textFaint, v: .top)
                    o.text(s.value, x: xx, y: yy, font: statFont, color: s.color, v: .top)
                }
            } else {
                var right = plotX.upperBound
                let nameEnd = plotX.lowerBound + o.measure(laneName(l.kind), font: capFont, tracking: 1.0) + o.measure(laneUnit(l.kind), font: statFont) + 20
                for s in list.reversed() {
                    let w = o.measure(s.value, font: statFont) + o.measure(s.caption + " ", font: statFont) + (s.swatch == .none ? 0 : 14)
                    guard right - w >= nameEnd else { continue }
                    right -= o.text(s.value, x: right, y: l.captionY, font: statFont, color: s.color, h: .right, v: .bottom)
                    right -= o.text(s.caption + " ", x: right, y: l.captionY, font: statFont, color: p.textFaint, h: .right, v: .bottom)
                    if s.swatch != .none { right -= 14; _ = drawSwatch(o, s.swatch, x: right, midY: l.captionY - 4) }
                    right -= 12
                }
            }
        }

        drawHeader(o)
        drawSpanTitles(o)
        drawTimeLabels(o)

        if model.isEmpty, let first = lanes.first {
            let text = "The timeline fills as you listen"
            let font = Fonts.ui(strip ? 12 : 13, .medium)
            let cx = (plotX.lowerBound + plotX.upperBound) / 2
            let cy = lanes.count > 1 && first.rect.height < 40 ? (first.rect.minY + lanesBottom) / 2 : first.rect.midY
            let w = o.measure(text, font: font)
            o.fillRect(CGRect(x: cx - w / 2 - 10, y: cy - 10, width: w + 20, height: 20), color: p.plot, radius: 4)
            o.text(text, x: cx, y: cy, font: font, color: p.textDim, h: .center, v: .middle)
        }
    }

    /// Returns the width used.
    private func drawSwatch(_ o: OverlayContext, _ s: Stat.Swatch, x: CGFloat, midY: CGFloat) -> CGFloat {
        let p = palette
        switch s {
        case .none: return 0
        case .band:
            o.fillRect(CGRect(x: x, y: midY - 2.5, width: 10, height: 6), color: p.accent.withAlpha(0.40), radius: 1)
            o.line(x, midY - 2.5, x + 10, midY - 2.5, color: mix(p.accent, SIMD4(1, 1, 1, 1), t: 0.72), width: 1.5)
        case .line:
            o.line(x, midY, x + 10, midY, color: mix(p.accent, SIMD4(1, 1, 1, 1), t: 0.15).withAlpha(0.9), width: 1)
        }
        return 14
    }

    // MARK: Header

    /// "S range −20…−9": the span of the short-term loudness in the window.
    static let shortTermRangeCaption = "S range"
    /// Seconds of the window that hold clipped samples (a clip event is one second with one or more clipped runs).
    static func clipCountText(_ seconds: Int) -> String { seconds == 0 ? "no clipped samples" : "\(seconds) s with clipped samples" }
    /// Seconds whose true peak went over 0 dBTP without a clipped sample.
    static func overCountText(_ n: Int) -> String { "\(n) true-peak over\(n == 1 ? "" : "s")" }

    private func drawHeader(_ o: OverlayContext) {
        let p = palette
        let y = headerMidY
        var x = plotX.lowerBound
        x += o.text("SESSION", x: x, y: y, font: capFont, color: p.textFaint, v: .middle, tracking: 1.0) + 8
        let minutes = model.windowSeconds >= 60 ? "\(Int((model.windowSeconds / 60).rounded())) min" : "\(Int(model.windowSeconds)) s"
        x += o.text(minutes, x: x, y: y, font: statFont, color: p.textDim, v: .middle) + 18
        let right = wide ? size.width - 12 : plotX.upperBound

        if readoutInHeader {
            let items = cursorItems()
            if !items.isEmpty {
                CursorHeader.draw(o, items: items, right: right, left: x, midY: y, compact: strip || !wide, pinned: cursor?.isPinned == true, palette: p)
                return
            }
        }
        guard !model.isEmpty else { return }
        // What the window holds, each count with the mark that stands for it in the lanes: the legend of the event marks.
        let st = model.stats
        enum Glyph { case clip, over, flag, track, pause }
        var parts: [(Glyph, String, SIMD4<Float>)] = []
        parts.append((.clip, Self.clipCountText(st.clipEvents), st.clipEvents == 0 ? p.textDim : mix(p.danger, p.text, t: 0.35)))
        if st.overs > 0 { parts.append((.over, Self.overCountText(st.overs), mix(p.danger, p.text, t: 0.35))) }
        if st.flags > 0 { parts.append((.flag, "\(st.flags) flag\(st.flags == 1 ? "" : "s")", mix(p.warn, p.text, t: 0.25))) }
        if st.tracks > 0 { parts.append((.track, "\(st.tracks) track start\(st.tracks == 1 ? "" : "s")", p.textDim)) }
        if !model.gaps.isEmpty { parts.append((.pause, "\(model.gaps.count) pause\(model.gaps.count == 1 ? "" : "s")", p.textDim)) }
        for (glyph, text, color) in parts {
            let w = o.measure(text, font: statFont)
            guard x + 12 + w <= right else { break }
            switch glyph {
            case .clip: o.fillRect(CGRect(x: x + 3, y: y - 4.5, width: 2, height: 9), color: st.clipEvents == 0 ? p.textFaint : p.danger)
            case .over: o.arc(cx: x + 4, cy: y, radius: 3, start: 0, end: 2 * .pi, color: p.danger, width: 1.2)
            case .flag: o.fillRect(CGRect(x: x, y: y - 2, width: 8, height: 4), color: p.warn.withAlpha(0.9), radius: 1.5)
            case .track:
                o.line(x + 1, y - 5, x + 1, y + 5, color: p.text.withAlpha(0.6), width: 1)
                o.fillRect(CGRect(x: x + 1.5, y: y - 5, width: 6, height: 4.5), color: p.text.withAlpha(0.85), radius: 1)
            case .pause:
                o.line(x, y, x + 2.5, y - 3.5, color: p.textDim, width: 1.2)
                o.line(x + 2.5, y - 3.5, x + 6.5, y + 3.5, color: p.textDim, width: 1.2)
                o.line(x + 6.5, y + 3.5, x + 9, y, color: p.textDim, width: 1.2)
            }
            x += 13
            x += o.text(text, x: x, y: y, font: statFont, color: color, v: .middle) + 18
        }
    }

    // MARK: Spans and the axis

    /// Hues of the flag kinds: the warning amber first, then a yellow, an orange and a sand. All warm: a flag bar is never
    /// taken for a trace (blue) or an over (red).
    static let spanHues: [SIMD4<Float>] = [SIMD4(0, 0, 0, 0), SIMD4(0.96, 0.87, 0.32, 1), SIMD4(0.97, 0.50, 0.22, 1), SIMD4(0.86, 0.74, 0.58, 1)]
    /// The kinds of flag in the window, in alphabetical order of their ids: the index picks the hue.
    private var spanKinds: [String] { Array(Set(model.spans.map(\.flagID))).sorted() }
    func spanColor(_ flagID: String) -> SIMD4<Float> {
        let k = (spanKinds.firstIndex(of: flagID) ?? 0) % Self.spanHues.count
        return k == 0 ? palette.warn.withAlpha(1) : Self.spanHues[k]
    }

    private func drawSpanTitles(_ o: OverlayContext) {
        guard !strip else { return }
        let p = palette
        let font = Fonts.ui(10, .medium)
        for s in model.spans {
            let sx0 = max(x(forTime: s.start), plotX.lowerBound), sx1 = min(x(forTime: s.end), plotX.upperBound)
            let room = sx1 - sx0 - 12
            guard room > 24 else { continue }
            let midY = spansTop + CGFloat(s.row) * spanRowHeight + spanBarHeight / 2
            // The longest form of the title that fits in its own bar: the full title, or its first words.
            var words = s.title.split(separator: " ").map(String.init)
            var text = s.title
            while !words.isEmpty, o.measure(text, font: font) > room {
                words.removeLast()
                text = words.joined(separator: " ") + "\u{2026}"
            }
            guard !words.isEmpty else { continue }
            o.text(text, x: sx0 + 7, y: midY, font: font, color: mix(spanColor(s.flagID), SIMD4(1, 1, 1, 1), t: 0.45), v: .middle)
        }
        if model.hiddenSpans > 0 {
            let text = "+\(model.hiddenSpans)"
            let yy = spansTop + CGFloat(TimelineModel.maxSpanRows - 1) * spanRowHeight + spanBarHeight / 2
            let xx = wide ? plotX.upperBound + 12 : plotX.upperBound - 4
            let r = o.textBounds(text, x: xx, y: yy, font: font, h: wide ? .left : .right, v: .middle)
            if o.isFree(r) { o.text(text, x: xx, y: yy, font: font, color: p.warn, h: wide ? .left : .right, v: .middle) }
        }
    }

    private func drawTimeLabels(_ o: OverlayContext) {
        let p = palette
        let font = numberFont
        let ly = axisY + 8
        // The right end: "now" while the record is live, else the time of the newest sample.
        var rightText = "now"
        if let last = model.samples.last, !isLive { rightText = TimelineFormat.clock(last.date, seconds: true, timeZone: timeZone) }
        let rightRect = o.textBounds(rightText, x: plotX.upperBound, y: ly, font: font, h: .right, v: .top)
        o.text(rightText, x: plotX.upperBound, y: ly, font: font, color: isLive ? p.text : p.textDim, h: .right, v: .top)
        var taken = [rightRect]
        // Newest first: near "now" the labels matter most, so they win the room.
        for m in minuteMarks().reversed() where m.labeled {
            let text = TimelineFormat.clock(m.date, seconds: false, timeZone: timeZone)
            let r = o.textBounds(text, x: m.x, y: ly, font: font, h: .center, v: .top)
            guard r.minX >= plotX.lowerBound - 14, r.maxX <= plotX.upperBound, !taken.contains(where: { $0.insetBy(dx: -10, dy: 0).intersects(r) }) else { continue }
            o.text(text, x: m.x, y: ly, font: font, color: p.textDim, h: .center, v: .top)
            taken.append(r)
        }
    }

    // MARK: Readout

    private var labelCache: (index: Int, lines: [String])?

    /// The second under the cursor, line by line: time, loudness, peak and correlation, the level at the ear, the events.
    func readoutLines(_ i: Int) -> [String] {
        if let c = labelCache, c.index == i { return c.lines }
        let s = model.samples[i]
        var lines = [TimelineFormat.clock(s.date, seconds: true, timeZone: timeZone) + "   " + TimelineFormat.ago(model.newestTime - s.time)]
        if s.isSilent {
            lines.append("digital silence")
        } else {
            lines.append("S \(Fmt.db(s.shortTermLUFS))   M max \(Fmt.db(s.momentaryMaxLUFS)) LUFS")
            lines.append("TP \(Fmt.db(s.truePeakDBTP, signed: true)) dBTP   corr \(Fmt.number(s.correlation, digits: 2, signed: true))")
            if let a = s.levelA, a > SPLReading.floorDB + 1 { lines.append("at the ear \u{2248} \(Fmt.number(a, digits: 0)) dB(A)") }
        }
        lines.append(contentsOf: eventTexts(i))
        labelCache = (i, lines)
        return lines
    }

    /// What happened in the second of sample `i`, in words.
    func eventTexts(_ i: Int) -> [String] {
        var out: [String] = []
        if let g = model.gap(before: i) { out.append("after a pause of \(TimelineFormat.duration(g.skippedSeconds))") }
        for e in model.events(ofSample: i) {
            switch e.kind {
            case .trackStart: out.append("track start")
            case .clip: out.append("clipped \u{00D7}\(max(Int(e.value.rounded()), 1))")
            case .interSampleOver: out.append("true peak over \(Fmt.number(e.value, digits: 1, signed: true)) dBTP")
            case .stressFlagRaised: out.append("flag raised: \(e.label)")
            case .stressFlagCleared: out.append("flag cleared: \(e.label)")
            case .silenceStart: out.append("silence starts")
            case .silenceEnd: out.append("silence ends")
            }
        }
        let changed = Set(model.events(ofSample: i).filter { $0.kind == .stressFlagRaised || $0.kind == .stressFlagCleared }.map { $0.detail.isEmpty ? $0.label : $0.detail })
        for s in model.spans(atSample: i) where !changed.contains(s.flagID) { out.append("flag up: \(s.title)") }
        return out
    }

    /// The bar hue of every line of `eventTexts(i)`: nil for what is not a flag.
    func eventHues(_ i: Int) -> [SIMD4<Float>?] {
        var out: [SIMD4<Float>?] = []
        if model.gap(before: i) != nil { out.append(nil) }
        let events = model.events(ofSample: i)
        for e in events {
            let isFlag = e.kind == .stressFlagRaised || e.kind == .stressFlagCleared
            out.append(isFlag ? spanColor(e.detail.isEmpty ? e.label : e.detail) : nil)
        }
        let changed = Set(events.filter { $0.kind == .stressFlagRaised || $0.kind == .stressFlagCleared }.map { $0.detail.isEmpty ? $0.label : $0.detail })
        for s in model.spans(atSample: i) where !changed.contains(s.flagID) { out.append(spanColor(s.flagID)) }
        return out
    }

    /// A low strip has no room for a box at the pointer that does not cover the lanes: its readout is always the header row.
    override var showsPointerReadout: Bool { strip || boxTooTall ? false : super.showsPointerReadout }
    private var readoutInHeader: Bool { cursorLinked ? showsHeaderReadout : ((strip || boxTooTall) && focusIndex != nil) }
    /// The box at the pointer stays over the time axis: it never covers the axis labels (it flips above the pointer, see
    /// `hoverLabelFloor`). A readout with more lines than the lanes are high goes into the header row.
    override var hoverLabelFloor: CGFloat? { axisY - 2 }
    private var boxTooTall: Bool {
        guard let i = focusIndex else { return false }
        return CGFloat(readoutLines(i).count) * HoverLabel.lineHeight + HoverLabel.padding * 1.25 > axisY - 6
    }

    override func hoverLabel() -> (lines: [String], anchor: CGPoint)? {
        guard !strip, !boxTooTall, let hv = hover, let i = focusIndex, let fx = focusX else { return nil }
        if cursorLinked { guard showsPointerReadout else { return nil } } else { guard overLanes(hv) else { return nil } }
        return (readoutLines(i), CGPoint(x: fx, y: hv.y))
    }

    override func cursorItems() -> [CursorReadoutItem] {
        guard let ago = focusSecondsAgo else { return [] }
        guard let i = focusIndex else {
            return [CursorReadoutItem(text: TimelineFormat.ago(ago), rank: 0, tone: .ghost), CursorReadoutItem(text: "outside the record", rank: 1, tone: .dim)]
        }
        let s = model.samples[i]
        var items = [CursorReadoutItem(text: TimelineFormat.clock(s.date, seconds: true, timeZone: timeZone), rank: 0),
                     CursorReadoutItem(text: TimelineFormat.ago(model.newestTime - s.time), rank: 5, tone: .ghost)]
        if s.isSilent {
            items.append(CursorReadoutItem(text: "digital silence", rank: 1, tone: .dim))
        } else {
            items.append(CursorReadoutItem(text: "S \(Fmt.db(s.shortTermLUFS)) LUFS", rank: 1))
            items.append(CursorReadoutItem(text: "M max \(Fmt.db(s.momentaryMaxLUFS))", rank: 4))
            items.append(CursorReadoutItem(text: "TP \(Fmt.db(s.truePeakDBTP, signed: true)) dBTP", rank: 2))
            items.append(CursorReadoutItem(text: "corr \(Fmt.number(s.correlation, digits: 2, signed: true))", rank: 7))
            if let a = s.levelA, a > SPLReading.floorDB + 1 { items.append(CursorReadoutItem(text: "at the ear \u{2248} \(Fmt.number(a, digits: 0)) dB(A)", rank: 6)) }
        }
        // A flag's words carry the hue of its bar: on a low strip this row is the legend of the bars.
        let hues = eventHues(i)
        for (k, t) in eventTexts(i).enumerated() { items.append(CursorReadoutItem(text: t, rank: 3 + k * 5, tone: .accent, swatch: hues[k])) }
        return items
    }

    // MARK: Test seams

    var lanesForTesting: [Lane] { lanes }
    var axisYForTesting: CGFloat { axisY }
    var spansTopForTesting: CGFloat { spansTop }
}
