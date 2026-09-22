import AppKit
import Metal
import simd
import JoseonCore

final class SpectrumRenderer: PanelRenderer {
    var options = SpectrumViewOptions() { didSet { if options != oldValue { curvesValid = false; needsDisplay = true } } }
    /// Slow automatic dB range: a 72 dB window (or the options' span when that is smaller) whose top follows the music
    /// in 6 dB steps with hysteresis. Off = exactly `options.minDB ... options.maxDB`.
    var autoRange = true { didSet { if autoRange != oldValue { rangeSnapped = false; curvesValid = false; needsDisplay = true } } }
    /// Shades the frequency span of every headphone stress flag that has one, with its plot label.
    var showStressBands = true { didSet { if showStressBands != oldValue { annotationsValid = false; needsDisplay = true } } }
    /// `.dBSPL`: the third-octave levels at the eardrum (`frame.spl.bandLevelsEardrum`) as a stepped bar layer behind the
    /// curves, on a right-hand dB SPL axis. The curves stay in dBFS: see `drawSPLBands`.
    var levelAxis = LevelAxis.dBFS { didSet { if levelAxis != oldValue { splShown = false; layoutChanged(); needsDisplay = true } } }
    /// True while the SPL layer is drawn: `.dBSPL`, and the frame carries an SPL reading with its third-octave bands.
    private(set) var splShown = false
    /// dB SPL = dBFS + this, on the right-hand axis. Whole dB, from the reading (see `updateSPLAxis`).
    private(set) var splOffset: Float = 100
    /// Takes the traces away that the question on screen does not need (critic r6, D9): L and R while a reference is
    /// set; Peak hold and Long-term while a timed cursor shows its ghost trace; and any of L / R, Side, Peak hold and
    /// Long-term that the legend row had no room to name. Off = every trace of `options` is drawn, named or not.
    var autoDeclutter = true { didSet { if autoDeclutter != oldValue { curvesValid = false; needsDisplay = true } } }
    /// What the legend row named when the text was last laid out. The Metal pass reads it: a trace without a name is
    /// not drawn. Until the first layout nothing optional is named.
    private(set) var legendNamed: Set<Slot> = []
    private var legendNaming: Set<Slot> = []
    private func isNamed(_ slot: Slot) -> Bool { !autoDeclutter || legendNamed.contains(slot) }
    /// L and R are wanted: the option is on, and no reference asks "A against B".
    var wantsLeftRight: Bool { options.showLeftRight && !(autoDeclutter && comparison != nil) }
    /// Peak hold and Long-term are wanted: not while the ghost trace asks "then against now". With a reference the
    /// long-term curve is B and stays.
    var wantsPeakHold: Bool { options.showPeakHold && !(autoDeclutter && ghostSlice != nil) }
    var wantsLongTerm: Bool { options.showAverage && !(autoDeclutter && ghostSlice != nil) }
    /// The ghost trace: dashed 6 on, 4 off.
    static let ghostDash: (period: Float, duty: Float) = (10, 0.6)

    // MARK: A/B compare (see `SpectrumRenderer+Comparison.swift`)

    /// The reference "A". Nil = no comparison: nothing below is read, and the tick costs what it did before.
    var comparison: ComparisonSnapshot? { didSet { if !Self.sameComparison(comparison, oldValue) { comparisonChanged() } } }
    var comparisonLevelMatch = true { didSet { if comparisonLevelMatch != oldValue { curvesValid = false; needsDisplay = true } } }
    var comparisonMode = ComparisonMode.signal { didSet { if comparisonMode != oldValue { curvesValid = false; needsDisplay = true } } }
    /// The display tilt the live curves carry (dB per octave around 1 kHz).
    var liveTiltDBPerOctave: Float = 0 { didSet { if liveTiltDBPerOctave != oldValue { curvesValid = false; needsDisplay = true } } }
    let compare = ComparisonCurves()
    /// The difference lane is drawn: a comparison is set and the view is high enough for it.
    private(set) var laneShown = false
    /// The headphone overlay is wanted but not drawn: the lane has taken its room, or the panel has no room for the
    /// band's legend row and `dB rel` axis. The header says `headphone band hidden`.
    private(set) var hpHidden = false
    /// The lane with its label strip, and the part under the strip where the curve is drawn. Zero without a lane.
    private(set) var lane = CGRect.zero, laneBody = CGRect.zero
    /// Lane values per plot point (NaN = gap), rebuilt with the curves.
    var laneValues = [Float](repeating: .nan, count: SpectrumRenderer.maxPoints)
    var laneRuns: [Range<Int>] = []
    var referenceRun: Range<Int>?
    var referenceResponseRun: Range<Int>?
    var laneState = LaneState.none
    var bandHiddenNoteInStrip = false
    /// Ticks of the lane's axis: ±12 dB, or ±6 while the curve is small (see `laneAxes`).
    var laneAxisDB: Float = 12
    var comparisonSource: [Float] = []
    var lanePointIndex: [Float] = []
    var lanePointIndexKey: (Int, Int, Float, Float) = (0, 0, 0, 0)

    private static func sameComparison(_ a: ComparisonSnapshot?, _ b: ComparisonSnapshot?) -> Bool {
        a?.id == b?.id && a?.name == b?.name && a?.tiltDBPerOctave == b?.tiltDBPerOctave && a?.headphoneName == b?.headphoneName
            && a?.averageDB.count == b?.averageDB.count
    }

    private func comparisonChanged() {
        if comparison == nil { compare.clear() }
        layoutChanged()
        needsDisplay = true
    }

    /// Who gets the room. The lane needs a view of 240 pt or more AND a body of `laneMinimumBodyHeight` that takes no more
    /// than `laneMaximumFraction` of the plot: a lane without a scale is a line that says nothing, so a panel that cannot
    /// give the room draws no lane and says so in the header (`laneHiddenNotes`). Under 360 pt the lane wins over the
    /// headphone band. Returns true when something changed.
    @discardableResult
    private func resolveBands() -> Bool {
        let wantsHP = options.showHeadphoneOverlay && frame?.headphone != nil
        // The headphone band is drawn only with its words: the legend row over the plot and the `dB rel` axis beside it
        // (critic r6, D10). A compact card has neither; a narrow panel may have no room for the row's entries.
        var fit = (band: false, atEar: false)
        if wantsHP, let reading = frame?.headphone { fit = headphoneLegendFit(reading) }
        let bottom: CGFloat = compact ? 20 : 26
        let topWithRow = (compact ? 5 : 8) + headerHeight + (compact ? 0 : Self.headphoneRowHeight)
        // With the lane on Signal the question is "A against B": under 420 pt of plot the band gives its room to it (in
        // headphone mode the band is part of the question, and gives way only under 360 pt of view).
        let hpGivesWay = size.height < Self.bothBandsMinimumViewHeight
            || (comparisonMode == .signal && size.height - topWithRow - bottom < Self.bothBandsMinimumPlotHeight)
        var wantsLane = comparison != nil && size.height >= Self.laneMinimumViewHeight
        var tooSmall = comparison != nil && !wantsLane
        if wantsLane {
            // The plot as `layoutChanged` will make it with the lane on.
            let row = wantsHP && fit.band && !hpGivesWay
            let plotHeight = size.height - (row ? topWithRow : topWithRow - (compact ? 0 : Self.headphoneRowHeight)) - bottom
            if plotHeight * Self.laneMaximumFraction < Self.laneMinimumBodyHeight + laneStripHeight { wantsLane = false; tooSmall = true }
        }
        let forLane = wantsLane && hpGivesWay
        let hp = wantsHP && fit.band && !forLane
        let hidden = wantsHP && !hp
        let atEar = hp && fit.atEar
        let changed = wantsLane != laneShown || hidden != hpHidden || hp != hpShown || tooSmall != laneHiddenTooSmall || atEar != atEarShown
        laneShown = wantsLane; hpHidden = hidden; hpShown = hp; laneHiddenTooSmall = tooSmall; atEarShown = atEar
        return changed
    }
    /// With the lane on Signal, the headphone band needs a plot (music, band and lane) of this height.
    static let bothBandsMinimumPlotHeight: CGFloat = 420
    /// The "At ear" trace is drawn: the band is shown and the legend row has room for the trace's name.
    private(set) var atEarShown = false

    private var hpLegendFitKey = ""
    private var hpLegendFit = (band: false, atEar: false)
    /// Does the headphone legend row have room for the band's entries (name, Response, Target, Error), and for the at-ear
    /// entry after them? Measured once per headphone and width.
    private func headphoneLegendFit(_ hp: HeadphoneReading) -> (band: Bool, atEar: Bool) {
        guard !compact else { return (false, false) }
        let key = "\(hp.modelName)|\(hp.hasTarget)|\(referenceHeadphoneName ?? "")|\(size.width)"
        if key == hpLegendFitKey { return hpLegendFit }
        let o = OverlayContext(size: CGSize(width: 8, height: 8), pixelScale: 1)
        let entries = headphoneLegendEntries(hp)
        let limit = size.width - 6 - o.measure("dB rel", font: axisFont) - 10
        var x: CGFloat = 44 + 2, band = true, atEar = true
        for (i, e) in entries.enumerated() {
            let w = (e.swatch ? 21 : 0) + o.measure(e.label, font: Fonts.ui(11, e.bold ? .semibold : .regular))
            if x + w > limit { if i == entries.count - 1 { atEar = false } else { band = false } }
            x += w + 14
        }
        hpLegendFitKey = key; hpLegendFit = (band, band && atEar)
        return hpLegendFit
    }
    /// The entries of the headphone legend row, in order; the last one is the at-ear trace.
    private func headphoneLegendEntries(_ hp: HeadphoneReading) -> [(label: String, bold: Bool, swatch: Bool)] {
        var out: [(label: String, bold: Bool, swatch: Bool)] = []
        if let other = referenceHeadphoneName {
            out.append(("B \u{00B7} \(hp.modelName)", true, true)); out.append((ComparisonText.referenceHeadphone(other), false, true))
        } else {
            out.append((hp.modelName, true, false)); out.append(("Response", false, true))
        }
        if hp.hasTarget { out.append(("Target", false, true)); out.append(("Error", false, true)) }
        out.append((hp.hasTarget ? Self.atEarVsTargetLegend : Self.atEardrumLegend, false, true))
        return out
    }
    /// A comparison is set, but the panel cannot give the lane its 56 pt: no lane, and the header says so.
    private(set) var laneHiddenTooSmall = false
    private var laneStripHeight: CGFloat { compact ? 14 : 17 }
    /// The curve area of the lane is never lower than this: room for the zero line and a tick pair with their labels.
    static let laneMinimumBodyHeight: CGFloat = 56
    /// The lane (strip and body) never takes more of the plot than this.
    static let laneMaximumFraction: CGFloat = 0.42
    static let laneHiddenNotes = ["B \u{2212} A lane hidden (panel too small)", "B \u{2212} A lane hidden", "lane hidden"]
    static let laneFraction: CGFloat = 0.22
    static let laneMinimumViewHeight: CGFloat = 240
    static let bothBandsMinimumViewHeight: CGFloat = 360

    /// Compact mode uses smaller type and a slimmer header (menu bar popover, small cards).
    var compact: Bool { size.width < 460 || size.height < 200 }
    /// The peak readout lives in the header row at every size (critic r6): it used to jump into a card inside the plot from
    /// 1200 pt of width, and back when a headphone band came on. It never covers a curve.
    private let peakInHeader = true
    /// The headphone legend is a second header row over the plot (never a plate over the data). It needs room: hidden in compact mode.
    private var showsHeadphoneLegend: Bool { !compact && hpShown }
    /// Legends and readouts live in this row over the plot, at every size.
    private var headerHeight: CGFloat { compact ? 17 : 22 }
    private static let headphoneRowHeight: CGFloat = 18

    // The plot starts at 20 Hz: below that the analyzer has one or two bins, which drew an unlabeled shelf.
    let axis = LogAxis(minHz: 20, maxHz: 20_000)
    private var hueLUT: MTLTexture?
    private(set) var plot = CGRect.zero
    private(set) var pointCount = 2
    private(set) var hpShown = false

    // Auto range state.
    static let autoSpanDB: Float = 72
    private var rangeTop: Float = 0          // shown top, animated
    private var rangeTarget: Float = 0       // where the top is going
    private var rangeSnapped = false
    private var lowerFor: Double = 0, higherFor: Double = 0

    // Curves resampled to the plot, rebuilt once per analysis frame (not per display tick). Allocated once.
    enum Slot: Int, CaseIterable { case mid, side, average, left, right, peakHold, atEar, target, response, ghost, reference, referenceResponse, lane, lanePositive, laneNegative, laneZero }
    static let maxPoints = 2048
    private let store: UnsafeMutablePointer<Float>
    /// Four work rows of `maxPoints`.
    private let scratch: UnsafeMutablePointer<Float>
    /// The fill's reference line (plot heights at the left and the right end): a straight fit through the mid curve, slow in time.
    private var fillReference: (left: Float, right: Float) = (0.6, 0.3)
    private var fillReferenceSnapped = false
    var slotValid = [Bool](repeating: false, count: Slot.allCases.count)
    private(set) var curvesValid = false
    private(set) var table: ResampleTable?
    /// The ghost trace has its own bins (the rows of the spectrogram history), so its own table.
    private var ghostTable: ResampleTable?

    override var kind: PanelKind { .spectrum }
    override var makesPointerCursors: Bool { true }

    override init?(ctx: RenderContext, theme: Theme) {
        store = .allocate(capacity: Self.maxPoints * Slot.allCases.count)
        store.initialize(repeating: 0, count: Self.maxPoints * Slot.allCases.count)
        scratch = .allocate(capacity: Self.maxPoints * 4)
        scratch.initialize(repeating: 0, count: Self.maxPoints * 4)
        super.init(ctx: ctx, theme: theme)
    }

    deinit { store.deallocate(); scratch.deallocate() }

    /// Range of the music scale in dB.
    var musicRange: (min: Float, max: Float) {
        guard autoRange else { return (options.minDB, options.maxDB) }
        let span = min(options.maxDB - options.minDB, Self.autoSpanDB)
        return (rangeTop - span, rangeTop)
    }
    /// Range of the whole plot in dB. With the headphone overlay the top 25 % of the plot is the band of the headphone
    /// curves: the music scale keeps its range and takes the lower 75 %, so the two never share a pixel row by design.
    var shownRange: (min: Float, max: Float) {
        let m = musicRange
        guard hpShown else { return m }
        return (m.min, m.max + (m.max - m.min) * Self.hpBandFraction / (1 - Self.hpBandFraction))
    }
    private var lo: Float { shownRange.min }
    private var hi: Float { shownRange.max }
    private var musicTop: Float { musicRange.max }

    // Headphone curves: their own band, the top 25 % of the plot, with their own scale (+-14 dB over the band, ticks to +-12).
    static let hpBandFraction: Float = 0.25
    private static let hpAxisDB: Float = 12
    static let hpBandHalfSpanDB: Float = 14
    /// Response, target and error are drawn at 60 % of their colors: reference curves, not data of the music.
    static let hpBandAlpha: Float = 0.60
    var hpBand: CGRect { CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: plot.height * CGFloat(Self.hpBandFraction)) }
    /// y of a relative level (dB re 1 kHz) inside the headphone band.
    private func hpY(_ d: Float) -> Float {
        Float(hpBand.minY) + Float(hpBand.height) * (Self.hpBandHalfSpanDB - d) / (2 * Self.hpBandHalfSpanDB)
    }
    /// Ticks of the right axis that the band has room for.
    private var hpTicks: [Float] {
        let h = hpBand.height
        if h >= 84 { return [Self.hpAxisDB, Self.hpAxisDB / 2, 0, -Self.hpAxisDB / 2, -Self.hpAxisDB] }
        return h >= 44 ? [Self.hpAxisDB, 0, -Self.hpAxisDB] : [0]
    }
    /// At ear = Mid + (Response - Target) per bin, kept between frames (no allocation per frame).
    private var atEarSource: [Float] = []

    override func paletteChanged() {
        hueLUT = ctx.makeLUT((0..<256).map { Palette.spectrumColor(atHz: axis.frequency(Float($0) / 255)) })
    }

    override func layoutChanged() {
        resolveBands()
        let w = size.width, h = size.height
        let left: CGFloat = compact ? 32 : 44
        let right: CGFloat = splShown ? (compact ? 27 : 48) : (compact ? 8 : (hpShown ? 40 : 14))
        let top: CGFloat = (compact ? 5 : 8) + headerHeight + (showsHeadphoneLegend ? Self.headphoneRowHeight : 0)
        let bottom: CGFloat = compact ? 20 : 26
        plot = CGRect(x: left, y: top, width: max(w - left - right, 10), height: max(h - top - bottom, 10))
        if laneShown {
            // The lane is the bottom 22 % of the plot: a strip for its label, then its own small plot. The music scale
            // keeps its range and takes what is left, as it does under the headphone band.
            let strip = laneStripHeight
            let laneHeight = max((plot.height * Self.laneFraction).rounded(), Self.laneMinimumBodyHeight + strip)
            lane = CGRect(x: plot.minX, y: plot.maxY - laneHeight, width: plot.width, height: laneHeight)
            laneBody = CGRect(x: lane.minX, y: lane.minY + strip, width: lane.width, height: max(laneHeight - strip, 4))
            plot.size.height -= laneHeight
        } else {
            lane = .zero; laneBody = .zero
        }
        pointCount = min(max(Int(plot.width * scale / 2), 64), Self.maxPoints - 1)
        curvesValid = false
        annotationsValid = false
    }

    override var staticSignature: Int {
        var h = Hasher()
        h.combine(super.staticSignature); h.combine(Int(lo * 8)); h.combine(Int(hi * 8)); h.combine(hpShown); h.combine(laneShown); h.combine(laneHiddenTooSmall); h.combine(hpHidden); h.combine(atEarShown)
        if laneShown { ensureComparisonCurrent(); h.combine(Int(laneAxisDB)) }
        if splShown { h.combine(Int(splOffset)) }
        return h.finalize()
    }

    override var dynamicSignature: Int {
        var h = Hasher()
        if let f = frame {
            h.combine(Int(f.peak.frequencyHz * 10)); h.combine(Int(f.peak.levelDB * 10)); h.combine(Int(f.peak.cents))
            h.combine(f.headphone?.modelName); h.combine(f.headphone?.hasTarget); h.combine(f.peak.noteName)
            for pk in f.topPeaks { h.combine(Int(pk.frequencyHz * 4)); h.combine(Int(pk.levelDB * 2)); h.combine(pk.noteName) }
            h.combine(Int(f.lowestStrongHz * 10))
            for flag in f.headphone?.stressFlags ?? [] { h.combine(flag.id); h.combine(flag.plotLabel); h.combine(flag.severity.rawValue); h.combine(flag.frequencyRangeHz?.lowerBound) }
        }
        h.combine(showStressBands); h.combine(levelAxis); h.combine(splShown); h.combine(autoDeclutter); h.combine(ghostSlice != nil)
        h.combine(options.showLeftRight); h.combine(options.showMid); h.combine(options.showPeakHold)
        h.combine(options.showAverage); h.combine(options.showHeadphoneOverlay); h.combine(options.showSide)
        if let c = comparison { combineComparisonSignature(c, into: &h) }
        return h.finalize()
    }

    // MARK: State

    override func update(frame f: AnalysisFrame, dt: TimeInterval) {
        curvesValid = false
        annotationsValid = false
        if resolveBands() { layoutChanged(); needsDisplay = true }
        if levelAxis == .dBSPL || splShown { updateSPLAxis(f) }
        updateAutoRange(f, dt: dt)
    }

    /// The right-hand axis: dB SPL = dBFS + `splOffset`. The offset is what the reading itself says about a 1 kHz tone:
    /// band level at the eardrum minus band level in dBFS RMS (median over the bands with signal: the headphone response
    /// moves single bands, the median stands near its 0 dB), minus 3.01 dB, because the curves read a full-scale sine as
    /// 0 dBFS and the bands read it as -3.01 dBFS RMS. So the bar of a pure tone ends where the tone's peak stands. Whole
    /// dB, and it moves only with the calibration: the axis does not follow the music.
    private func updateSPLAxis(_ f: AnalysisFrame) {
        var on = false
        if levelAxis == .dBSPL, let s = f.spl, let t = f.thirdOctave {
            let n = min(s.bandLevelsEardrum.count, t.left.count, t.right.count, t.centersHz.count)
            on = n >= 3
            var count = 0
            for b in 0..<min(n, Self.maxBands) {
                let level = max(t.left[b], t.right[b])
                if level > -100, s.bandLevelsEardrum[b] > SPLReading.floorDB + 1 { splScratch[count] = s.bandLevelsEardrum[b] - level; count += 1 }
            }
            if count >= 3 {
                // Median by insertion sort: at most 31 values, no allocation.
                for i in 1..<count {
                    let v = splScratch[i]
                    var j = i - 1
                    while j >= 0, splScratch[j] > v { splScratch[j + 1] = splScratch[j]; j -= 1 }
                    splScratch[j + 1] = v
                }
                // Hysteresis: a median that stands at x.5 must not move the axis (and its labels) with every frame.
                let offset = splScratch[count / 2] - 3.01
                if abs(offset - splOffset) > 0.75 { splOffset = offset.rounded(); needsDisplay = true }
            }
        }
        if on != splShown { splShown = on; layoutChanged(); needsDisplay = true }
    }
    private static let maxBands = 48
    private var splScratch = [Float](repeating: 0, count: SpectrumRenderer.maxBands)

    private func updateAutoRange(_ f: AnalysisFrame, dt: TimeInterval) {
        guard autoRange else { return }
        let s = f.spectrum
        let n = min(s.peakHold.count, s.frequencies.count, s.mid.count)
        var peak: Float = -1000
        var i = 0
        while i < n {
            if s.frequencies[i] >= axis.minHz, s.frequencies[i] <= axis.maxHz { peak = max(peak, max(s.peakHold[i], s.mid[i])) }
            i += 2
        }
        let ceiling = min(options.maxDB, 0)
        guard peak > -110 else {
            if !rangeSnapped { rangeTop = min(-6, ceiling); rangeTarget = rangeTop }
            return
        }
        // 6 dB of air over the highest peak, on the 6 dB grid.
        let want = min(max(((peak + 6) / 6).rounded(.up) * 6, -48), ceiling)
        if !rangeSnapped {
            rangeSnapped = true
            rangeTop = want; rangeTarget = want
            return
        }
        // Up fast (the curve must not leave the plot), down only after the music stayed lower for a while.
        if want > rangeTarget { higherFor += dt; lowerFor = 0 } else if want < rangeTarget { lowerFor += dt; higherFor = 0 } else { higherFor = 0; lowerFor = 0 }
        if higherFor > 0.25 || lowerFor > 5 { rangeTarget = want; higherFor = 0; lowerFor = 0 }
        if rangeTop != rangeTarget {
            let k = Float(1 - exp(-dt / 0.22))
            rangeTop += (rangeTarget - rangeTop) * k
            if abs(rangeTarget - rangeTop) < 0.04 { rangeTop = rangeTarget }
        }
    }

    // MARK: Mapping

    func x(forHz hz: Float) -> Float { Float(plot.minX) + axis.position(hz) * Float(plot.width) }
    private func y(forDB db: Float) -> Float {
        Float(plot.maxY) - (db - lo) / (hi - lo) * Float(plot.height)
    }
    private var dbStep: Float {
        let range = hi - lo
        let minGap: Float = compact ? 22 : 34
        for step in [6, 12, 24, 48] as [Float] where Float(plot.height) * step / range >= minGap { return step }
        return 48
    }

    // MARK: Curves

    func pointer(_ slot: Slot) -> UnsafeMutablePointer<Float> { store + slot.rawValue * Self.maxPoints }

    func rebuildCurves(_ f: AnalysisFrame) {
        let s = f.spectrum
        let n = pointCount
        for i in slotValid.indices { slotValid[i] = false }
        if table == nil || !table!.matches(frequencies: s.frequencies, axis: axis, count: n) {
            table = ResampleTable(frequencies: s.frequencies, axis: axis, count: n)
        }
        guard let table else { curvesValid = true; return }
        let lo = self.lo, hi = self.hi
        func build(_ slot: Slot, _ src: [Float], offsetDB: Float = 0) {
            guard src.count >= table.sourceCount else { return }
            table.apply(src, minDB: lo, maxDB: hi, offsetDB: offsetDB, into: pointer(slot))
            slotValid[slot.rawValue] = true
        }
        if options.showMid {
            build(.mid, s.mid)
            updateFillReference(pointer(.mid), n)
        }
        if options.showSide {
            build(.side, s.side)
            _ = smoothHighs(pointer(.side), n)
        }
        if wantsLongTerm || comparison != nil { build(.average, s.average) }
        if wantsLeftRight {
            build(.left, s.left); build(.right, s.right)
            // Each channel finds its tones on its OWN curve, and with the other channel as the reference: a quiet tone in one
            // channel only is a few dB over that channel's noise (too little to call tonal on one curve), but it stands
            // clear over the other channel at the same frequency.
            smoothHighs(pointer(.left), n, other: pointer(.right))
            smoothHighs(pointer(.right), n, other: pointer(.left))
        }
        if wantsPeakHold {
            build(.peakHold, s.peakHold)
            // Display-side clamp: the long-term average holds old partials longer than the peak hold decays. A reader cannot
            // accept "average over peak", so peak hold is drawn as max(peak hold, average) in every column.
            if slotValid[Slot.peakHold.rawValue], slotValid[Slot.average.rawValue] {
                let pk = pointer(.peakHold), av = pointer(.average)
                for i in 0..<n where av[i] > pk[i] { pk[i] = av[i] }
            }
        }
        if options.showHeadphoneOverlay, let hp = f.headphone {
            if hp.hasTarget, hp.responseDB.count >= s.mid.count, hp.targetDB.count >= s.mid.count {
                // Against the target: the ear gain that every good headphone has (the 3 kHz rise) is in both curves and
                // drops out. What is left is what this headphone adds to or takes from the music.
                if atEarSource.count != s.mid.count { atEarSource = [Float](repeating: 0, count: s.mid.count) }
                for i in 0..<s.mid.count { atEarSource[i] = s.mid[i] + hp.responseDB[i] - hp.targetDB[i] }
                build(.atEar, atEarSource)
            } else {
                build(.atEar, hp.predictedAtEarDB)
            }
            // Display smoothing (about 1/6 octave) so the prediction reads as tonal balance and does not
            // retrace every partial of the mid curve.
            let v = pointer(.atEar)
            let r = max(n / 110, 1)
            Self.boxBlur(v, scratch, n, r)
            Self.boxBlur(scratch, v, n, r)
            // The band's scale: -14 dB at 75 % of the plot height, +14 dB at the top.
            func band(_ slot: Slot, _ src: [Float]) {
                guard src.count >= table.sourceCount else { return }
                let half = Self.hpBandHalfSpanDB, full = 2 * half / Self.hpBandFraction
                table.apply(src, minDB: half - full, maxDB: half, into: pointer(slot))
                slotValid[slot.rawValue] = true
            }
            if hp.hasTarget { band(.target, hp.targetDB) }
            band(.response, hp.responseDB)
        }
        if let slice = ghostSlice {
            if ghostTable == nil || !ghostTable!.matches(frequencies: slice.frequencies, axis: axis, count: n) {
                ghostTable = ResampleTable(frequencies: slice.frequencies, axis: axis, count: n)
            }
            if let ghostTable, slice.midDB.count >= ghostTable.sourceCount {
                ghostTable.apply(slice.midDB, minDB: lo, maxDB: hi, into: pointer(.ghost))
                slotValid[Slot.ghost.rawValue] = true
            }
        }
        if let c = comparison { rebuildComparison(c, f, table: table) } else { laneState = .none }
        curvesValid = true
    }

    /// The past spectrum of a timed cursor, while it is drawn: the panel is linked, the cursor has a time, the spectrogram
    /// published the column, and Mid (whose past it is) is shown.
    var ghostSlice: CursorHistorySlice? {
        guard cursorLinked, options.showMid, cursor?.secondsAgo != nil, let s = cursorSlice, s.frequencies.count >= 2 else { return nil }
        return s
    }
    override func cursorSliceChanged() { curvesValid = false; needsDisplay = true }

    /// The reference line of the fill: a least-squares line through the mid curve over x, so it cannot dip or rise beside a
    /// peak. It moves with a 0.8 s time constant. The fill is fully lit at and over this line and fades to the floor under it.
    private func updateFillReference(_ v: UnsafePointer<Float>, _ n: Int) {
        guard n >= 8 else { return }
        var sy: Float = 0, sxy: Float = 0
        for i in 0..<n { let x = Float(i) / Float(n - 1) - 0.5; sy += v[i]; sxy += x * v[i] }
        // sum of x^2 for x uniform in -0.5...0.5 is about n / 12.
        let mean = sy / Float(n), slope = sxy / (Float(n) / 12)
        let want = (left: min(max(mean - slope * 0.5, 0.18), 1), right: min(max(mean + slope * 0.5, 0.18), 1))
        if !fillReferenceSnapped { fillReferenceSnapped = true; fillReference = want; return }
        let k = Float(1 - exp(-frameDelta / 0.8))
        fillReference.left += (want.left - fillReference.left) * k
        fillReference.right += (want.right - fillReference.right) * k
    }

    /// L, R and Side above 2 kHz: about 1/6 octave of smoothing (fading in from 1.4 kHz), so the thin lines read as curves
    /// and not as hash. Only the noise residual is smoothed. A tonal peak (a local maximum 8 dB or more over its 1/6-octave
    /// surroundings) is taken out before the smoothing, so it does not lift a flat-topped box around itself, and is put
    /// back unsmoothed with its whole lobe (at least the peak and 2 points either side). The join is continuous: the result
    /// is the smoothed residual, or the raw curve where that is higher, with a 3-point taper at the feet of the lobe.
    ///
    /// With `other` (the opposite channel) a second kind of peak is kept: a local maximum that stands 4 dB or more over the
    /// other channel, where that difference is itself a bump (3 dB over the mean difference within 1/3 octave). Noise that
    /// the two channels share in level gives a difference near 0 dB, so this finds a one-sided tone only a few dB over
    /// its own channel's noise, which the 8 dB rule cannot see. Returns true when smoothing ran.
    @discardableResult
    private func smoothHighs(_ v: UnsafeMutablePointer<Float>, _ n: Int, other: UnsafePointer<Float>? = nil) -> Bool {
        let perOctave = Float(n - 1) / log2(axis.maxHz / axis.minHz)
        let rMax = max(Int((perOctave / 12).rounded()), 1)
        let from = Int(axis.position(1_400) * Float(n - 1)), full = Int(axis.position(2_800) * Float(n - 1))
        let m = min(n, Self.maxPoints - 1)
        let start = from - rMax - 4
        guard start >= 0, from < m - 2, full > from else { return false }
        let prefix = scratch, resid = scratch + Self.maxPoints, keep = scratch + Self.maxPoints * 2, diffPrefix = scratch + Self.maxPoints * 3
        @inline(__always) func mean(_ i: Int, _ r: Int) -> Float {
            let a = max(i - r, start), b = min(i + r, m - 1)
            return (prefix[b + 1] - prefix[a]) / Float(b - a + 1)
        }
        prefix[start] = 0
        for i in start..<m { prefix[i + 1] = prefix[i] + v[i]; resid[i] = v[i]; keep[i] = 0 }
        let eightDB = 8 / max(hi - lo, 1), fourDB = eightDB / 2, threeDB = eightDB * 3 / 8
        if let other {
            diffPrefix[start] = 0
            for i in start..<m { diffPrefix[i + 1] = diffPrefix[i] + (v[i] - other[i]) }
        }
        @inline(__always) func oneSided(_ i: Int) -> Bool {
            guard let other, v[i] - other[i] >= fourDB, v[i] > 0.02 else { return false }
            let a = max(i - rMax * 4, start), b = min(i + rMax * 4, m - 1)
            return (v[i] - other[i]) - (diffPrefix[b + 1] - diffPrefix[a]) / Float(b - a + 1) >= threeDB
        }
        let maxReach = max(rMax * 3, 4)
        var i = from
        while i < m - 1 {
            guard v[i] >= v[i - 1], v[i] > v[i + 1], v[i] - mean(i, rMax) >= eightDB || oneSided(i) else { i += 1; continue }
            // The lobe: downhill from the peak on both sides.
            var a = i, b = i
            while a > start + 1, i - a < maxReach, v[a - 1] < v[a] { a -= 1 }
            while b < m - 2, b - i < maxReach, v[b + 1] < v[b] { b += 1 }
            a = max(min(a, i - 2), start); b = min(max(b, i + 2), m - 1)
            // The noise under the lobe: a line between the mean levels just outside its feet.
            let ya = mean(max(a - rMax / 2 - 1, start), rMax / 2), yb = mean(min(b + rMax / 2 + 1, m - 1), rMax / 2)
            for j in a...b {
                resid[j] = min(ya + (yb - ya) * Float(j - a) / Float(max(b - a, 1)), v[j])
                keep[j] = 1
            }
            for t in 1...3 {
                let w = 1 - Float(t) / 4
                if a - t >= start { keep[a - t] = max(keep[a - t], w) }
                if b + t < m { keep[b + t] = max(keep[b + t], w) }
            }
            i = b + 1
        }
        prefix[start] = 0
        for j in start..<m { prefix[j + 1] = prefix[j] + resid[j] }
        for j in from..<m {
            let k = min(Float(j - from) / Float(full - from), 1)
            let r = Int((Float(rMax) * k * k * (3 - 2 * k)).rounded())
            let smooth = r > 0 ? mean(j, r) : resid[j]
            v[j] = smooth + max(v[j] - smooth, 0) * keep[j]
        }
        return true
    }
    /// True when the L / R curves go through the display smoothing at this plot size (the same condition `smoothHighs`
    /// checks before it runs): the legend says so.
    var leftRightSmoothed: Bool {
        let n = pointCount
        let rMax = max(Int((Float(n - 1) / log2(axis.maxHz / axis.minHz) / 12).rounded()), 1)
        let from = Int(axis.position(1_400) * Float(n - 1)), full = Int(axis.position(2_800) * Float(n - 1))
        return options.showLeftRight && from - rMax - 4 >= 0 && from < min(n, Self.maxPoints - 1) - 2 && full > from
    }
    static let leftRightSmoothingHint = "L/R 1/6 oct"

    /// Copies a cached curve into this frame's GPU arena.
    func upload(_ slot: Slot) -> (buffer: MTLBuffer, offset: Int, count: Int)? {
        guard slotValid[slot.rawValue], let a = arena.allocate(Float.self, count: pointCount) else { return nil }
        a.pointer.update(from: pointer(slot), count: pointCount)
        return (arena.buffer, a.offset, pointCount)
    }

    // MARK: Metal

    override func draw(_ enc: MTLRenderCommandEncoder, globals g: inout Globals) {
        let p = palette
        let px = Float(plot.minX), py = Float(plot.minY), pw = Float(plot.width), ph = Float(plot.height)

        // Plot field: deeper than the panel, a touch lighter toward the top for depth.
        batch.rect(px, py, pw, ph, top: mix(p.plot, p.panel, t: 0.55), bottom: p.plot, radius: 3)
        if laneShown {
            batch.rect(Float(laneBody.minX), Float(laneBody.minY), Float(laneBody.width), Float(laneBody.height), top: mix(p.plot, p.panel, t: 0.35), bottom: p.plot, radius: 3)
        }
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)

        guard let f = frame else {
            drawGrid(enc, &g)
            return
        }
        if !curvesValid { rebuildCurves(f) }
        let sc = Float(scale)
        let plotScissor = MTLScissorRect(x: Int(px * sc), y: Int(py * sc), width: max(Int(pw * sc), 1), height: max(Int(ph * sc), 1))
        let fullScissor = MTLScissorRect(x: 0, y: 0, width: max(Int(Float(size.width) * sc), 1), height: max(Int(Float(size.height) * sc), 1))
        if splShown, let s = f.spl, let t = f.thirdOctave {
            enc.setScissorRect(plotScissor)
            drawSPLBands(enc, &g, levels: s.bandLevelsEardrum, centers: t.centersHz)
            enc.setScissorRect(fullScissor)
        }

        let rect = SIMD4<Float>(px, py, pw, ph)
        // No vertical wall where the data ends: every curve fades over the last points of the plot.
        let fade: Float = compact ? 8 : 16
        func uniforms() -> CurveUniforms { var u = CurveUniforms(); u.rect = rect; u.fadeRight = fade; return u }

        let mid = upload(.mid)
        if let mid {
            enc.setScissorRect(plotScissor)
            // Fill: one polygon, one gradient. 55 % at the reference line, 0 % at the floor, so the grid reads through it.
            var u = uniforms(); u.mode = 1
            u.color = SIMD4(1, 1, 1, 1); u.fillTop = 0.55; u.fillBottom = 0.0
            drawCurveFill(enc, values: mid, referenceLeft: fillReference.left, referenceRight: fillReference.right, uniforms: u, lut: hueLUT, globals: &g)
            enc.setScissorRect(fullScissor)
        }
        drawGrid(enc, &g)
        enc.setScissorRect(plotScissor)
        drawStressBands(enc, &g, f)

        if let mid {
            // One soft glow under the line: 3 pt sigma, 30 % at most. The data edge stays the line, not the glow.
            var glow = uniforms(); glow.mode = 1
            glow.color = SIMD4(1, 1, 1, compact ? 0.22 : 0.30); glow.halfWidth = 0.4; glow.soft = compact ? 1.6 : 3
            drawCurveLine(enc, values: mid, uniforms: glow, additive: true, lut: hueLUT, globals: &g)
        }

        if comparison != nil { drawReferenceTrace(enc, &g, uniforms: uniforms()) }
        if comparison != nil || (wantsLongTerm && isNamed(.average)), let c = upload(.average) {
            // Solid, thin, cool grey at 60 %: it cannot fragment on steep slopes and cannot be taken for peak hold (warm white).
            // With a reference it is "B": as present as A, so the eye can follow the pair.
            var u = uniforms(); u.color = comparison != nil ? p.liveLongTerm : p.average; u.halfWidth = comparison != nil ? 0.6 : 0.5
            drawCurveLine(enc, values: c, uniforms: u, additive: false, lut: nil, globals: &g)
        }

        // L and R: 1 px, no glow, desaturated tints at 75 %, everywhere. Mid is the only curve with the hue of the frequency.
        if isNamed(.left), let c = upload(.right) {
            var u = uniforms(); u.color = p.spectrumRight; u.halfWidth = 0.5
            drawCurveLine(enc, values: c, uniforms: u, additive: false, lut: nil, globals: &g)
        }
        if isNamed(.left), let c = upload(.left) {
            var u = uniforms(); u.color = p.spectrumLeft; u.halfWidth = 0.5
            drawCurveLine(enc, values: c, uniforms: u, additive: false, lut: nil, globals: &g)
        }
        if isNamed(.side), let c = upload(.side) {
            var u = uniforms(); u.color = p.side; u.halfWidth = 0.45
            drawCurveLine(enc, values: c, uniforms: u, additive: false, lut: nil, globals: &g)
        }
        if isNamed(.peakHold), let c = upload(.peakHold) {
            // With a reference the question is "A against B", and peak hold is a third line beside them: it steps back.
            // (While the ghost trace shows it is not drawn at all: see `wantsPeakHold`.)
            var u = uniforms(); u.color = slotValid[Slot.ghost.rawValue] || comparison != nil ? p.peakHold.scaledAlpha(0.35) : p.peakHold; u.halfWidth = 0.5
            drawCurveLine(enc, values: c, uniforms: u, additive: false, lut: nil, globals: &g)
        }

        if let c = upload(.ghost) {
            // The spectrum at the time of the cursor: dashed (6 on, 4 off) in the cyan of the spectrogram it comes from,
            // no fill, no glow, under the live Mid outline. No other trace of the panel is dashed cyan.
            var u = uniforms(); u.color = p.cursorGhost; u.halfWidth = 0.6
            u.dashPeriod = Self.ghostDash.period; u.dashDuty = Self.ghostDash.duty
            drawCurveLine(enc, values: c, uniforms: u, additive: false, lut: nil, globals: &g)
        }

        if let mid {
            // The data: a 1.25 pt opaque line.
            var u = uniforms(); u.mode = 1
            u.color = SIMD4(1, 1, 1, 1); u.halfWidth = 0.625; u.whiten = 0.38
            drawCurveLine(enc, values: mid, uniforms: u, additive: false, lut: hueLUT, globals: &g)
        }

        if hpShown, let hp = f.headphone {
            if atEarShown, let c = upload(.atEar) {
                // As thin as Mid and lighter (1.25 pt, 70 %): a prediction, it must not compete with the measurement.
                var u = uniforms(); u.color = p.hpAtEar.withAlpha(0.70); u.halfWidth = 0.625
                drawCurveLine(enc, values: c, uniforms: u, additive: false, lut: nil, globals: &g)
            }
            // The band of the headphone curves: a hairline under it, the 0 line and the tick marks, in the response color.
            let a = Self.hpBandAlpha
            let bandBottom = Float(hpBand.maxY)
            batch.hline(px, px + pw, bandBottom, color: p.hpResponse.withAlpha(0.16))
            batch.hline(px, px + pw, hpY(0), color: p.hpResponse.withAlpha(0.30 * a))
            for d in hpTicks where d != 0 {
                batch.hline(px + pw - 7, px + pw, hpY(d), color: p.hpResponse.withAlpha(0.75))
            }
            batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
            // Nothing of the band's curves leaves the band (a response under -14 dB ends at the hairline).
            enc.setScissorRect(MTLScissorRect(x: Int(px * sc), y: Int(py * sc), width: max(Int(pw * sc), 1), height: max(Int((bandBottom - py) * sc), 1)))
            let response = upload(.response)
            if hp.hasTarget, let response, let target = upload(.target) {
                // Error area: where the headphone departs from the target.
                var u = uniforms(); u.color = p.hpResponse.withAlpha(0.17 * a); u.count = Float(pointCount)
                enc.setRenderPipelineState(ctx.curveBand)
                enc.setVertexBuffer(response.buffer, offset: response.offset, index: 0)
                enc.setVertexBuffer(target.buffer, offset: target.offset, index: 3)
                enc.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
                enc.setVertexBytes(&u, length: MemoryLayout<CurveUniforms>.stride, index: 2)
                enc.setFragmentBytes(&u, length: MemoryLayout<CurveUniforms>.stride, index: 2)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: pointCount * 2)
                // Dotted target.
                var t = uniforms(); t.color = p.hpTarget.withAlpha(p.hpTarget.w * a); t.halfWidth = 0.9; t.dashPeriod = 4.5; t.dashDuty = 0.36
                drawCurveLine(enc, values: target, uniforms: t, additive: false, lut: nil, globals: &g)
            }
            if comparison != nil { drawReferenceResponse(enc, &g, uniforms: uniforms()) }
            if let response {
                var u = uniforms(); u.color = p.hpResponse.withAlpha(a); u.halfWidth = 0.8
                drawCurveLine(enc, values: response, uniforms: u, additive: false, lut: nil, globals: &g)
            }
            enc.setScissorRect(plotScissor)
        }
        if laneShown {
            drawLane(enc, &g)
            enc.setScissorRect(plotScissor)
        }

        // Peak marker.
        if !Fmt.isFloor(f.peak.levelDB), f.peak.frequencyHz > axis.minHz, f.peak.frequencyHz < axis.maxHz, f.peak.levelDB > lo {
            let mx = x(forHz: f.peak.frequencyHz), my = y(forDB: min(f.peak.levelDB, hi))
            let hue = Palette.spectrumColor(atHz: f.peak.frequencyHz).rgba(1)
            batch.circle(mx, my, 6, color: hue.withAlpha(0.30), glow: 2.5)
            batch.flush(enc, pipeline: ctx.shapeAdd, globals: &g)
            batch.circle(mx, my, 3.2, color: SIMD4(1, 1, 1, 0.95), stroke: 1.1)
            batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
        }

        // Peaks 2 to 5: small rings on the curve. Their note names are in the text layer.
        for pk in secondaryPeaks(f) {
            let mx = x(forHz: pk.frequencyHz), my = y(forDB: min(pk.levelDB, hi))
            batch.circle(mx, my, 2.6, color: p.plot.withAlpha(0.85))
            batch.circle(mx, my, 2.6, color: mix(Palette.spectrumColor(atHz: pk.frequencyHz).rgba(1), SIMD4(1, 1, 1, 1), t: 0.45), stroke: 1)
        }
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)

        // The cursor runs through the plot and the lane: one frequency, both answers.
        if laneShown { enc.setScissorRect(fullScissor) }
        if cursorLinked {
            drawLinkedCursor(enc, &g, f)
        } else if let hv = hover, pointerArea(hv) != nil {
            // Hover crosshair.
            let c = p.text.withAlpha(0.38)
            batch.vline(Float(hv.x), py, py + ph, color: c)
            if laneShown { batch.vline(Float(hv.x), Float(laneBody.minY), Float(laneBody.maxY), color: c) }
            batch.hline(px, px + pw, Float(hv.y), color: c)
            batch.circle(Float(hv.x), Float(hv.y), 2.5, color: p.text)
            batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
        }
        enc.setScissorRect(fullScissor)
        // Lowest strong content: a small tick under the x axis at that frequency, in the neutral text color.
        if f.lowestStrongHz >= axis.minHz, f.lowestStrongHz <= axis.maxHz {
            let tx = x(forHz: f.lowestStrongHz)
            batch.rect(tx - 0.75, Float(axisBottom) + 1, 1.5, 5, color: p.text.withAlpha(0.9), radius: 0.5)
            batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
        }
    }

    /// The shared cursor: a hairline at its frequency, from this panel's own axis. The pointer's own crosshair (level line and
    /// dot) stays while the pointer is what moves the cursor here.
    private func drawLinkedCursor(_ enc: MTLRenderCommandEncoder, _ g: inout Globals, _ f: AnalysisFrame) {
        guard let c = cursor, c.frequencyHz >= axis.minHz, c.frequencyHz <= axis.maxHz else { return }
        let px = Float(plot.minX), py = Float(plot.minY), pw = Float(plot.width), ph = Float(plot.height)
        let cx = x(forHz: c.frequencyHz)
        if showsPointerReadout, let hv = hover, pointerArea(hv) != nil {
            batch.hline(px, px + pw, Float(hv.y), color: palette.text.withAlpha(0.38))
        }
        // Through the plot and through the lane, not through the words between them.
        drawCursorVertical(x: cx, top: py, bottom: py + ph)
        if laneShown { batch.vline(cx, Float(laneBody.minY), Float(laneBody.maxY), color: cursorLineColor) }
        if laneShown, let d = laneValue(atHz: c.frequencyHz) {
            // Where the hairline meets the lane's curve: the point the "B − A" number belongs to.
            let ly = laneY(d)
            batch.circle(cx, ly, 2.6, color: palette.plot.withAlpha(0.9))
            batch.circle(cx, ly, 2.6, color: palette.deltaLine.withAlpha(1), stroke: 1)
        }
        // Where the hairline meets Mid: the point the "Mid" number of the readout belongs to.
        if options.showMid, let m = CursorMath.level(of: f.spectrum.mid, frequencies: f.spectrum.frequencies, atHz: c.frequencyHz), m > lo {
            let my = y(forDB: min(m, hi))
            batch.circle(cx, my, 3, color: palette.plot.withAlpha(0.9))
            batch.circle(cx, my, 3, color: SIMD4(1, 1, 1, 0.95), stroke: 1.1)
        }
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
    }

    /// `frame.topPeaks` without the first (the peak marker and the PEAK readout show that one), inside the plot.
    /// Rebuilt once per analysis frame into storage that keeps its capacity: no allocation per frame.
    private var secondaryPeakCache: [PeakReading] = []
    private var stressSpanCache: [(flag: StressFlag, x0: CGFloat, x1: CGFloat)] = []
    private var annotationsValid = false

    private func rebuildAnnotations(_ f: AnalysisFrame) {
        annotationsValid = true
        secondaryPeakCache.removeAll(keepingCapacity: true)
        // Tonal entries only: an empty note name means "broad, not tonal" (a hump gets no ring and no note). The entry that is
        // `frame.peak` has its own marker: it is found by its frequency, wherever it stands in the list.
        // As many as the width can carry (about one label per 70 pt), not a fixed count.
        let cap = max(Int(plot.width / 70), 1)
        for pk in f.topPeaks where secondaryPeakCache.count < cap && !pk.noteName.isEmpty && !Self.isSamePeak(pk, f.peak)
            && !Fmt.isFloor(pk.levelDB) && pk.frequencyHz > axis.minHz && pk.frequencyHz < axis.maxHz && pk.levelDB > lo {
            secondaryPeakCache.append(pk)
        }
        stressSpanCache.removeAll(keepingCapacity: true)
        guard showStressBands, let flags = f.headphone?.stressFlags else { return }
        for flag in flags {
            guard let r = flag.frequencyRangeHz, r.upperBound > axis.minHz, r.lowerBound < axis.maxHz else { continue }
            let x0 = CGFloat(x(forHz: max(r.lowerBound, axis.minHz))), x1 = CGFloat(x(forHz: min(r.upperBound, axis.maxHz)))
            stressSpanCache.append((flag, x0, max(x1, x0 + 3)))
        }
    }

    private static func isSamePeak(_ a: PeakReading, _ b: PeakReading) -> Bool {
        b.frequencyHz > 0 && abs(a.frequencyHz - b.frequencyHz) <= b.frequencyHz * 0.003
    }

    private func secondaryPeaks(_ f: AnalysisFrame) -> [PeakReading] {
        if !annotationsValid { rebuildAnnotations(f) }
        return secondaryPeakCache
    }

    /// Stress flags that have a frequency span inside the plot: (flag, x0, x1) in points.
    private func stressSpans(_ f: AnalysisFrame) -> [(flag: StressFlag, x0: CGFloat, x1: CGFloat)] {
        if !annotationsValid { rebuildAnnotations(f) }
        return stressSpanCache
    }

    private func severityColor(_ s: StressFlag.Severity) -> SIMD4<Float> {
        switch s {
        case .info: return palette.accent
        case .watch: return palette.warn
        case .high: return palette.danger
        }
    }

    /// The span of each stress flag: a wash in the severity color that is strongest at the top, a bright top border, faint sides.
    private func drawStressBands(_ enc: MTLRenderCommandEncoder, _ g: inout Globals, _ f: AnalysisFrame) {
        let spans = stressSpans(f)
        guard !spans.isEmpty else { return }
        let py = Float(plot.minY), ph = Float(plot.height)
        for s in spans {
            let c = severityColor(s.flag.severity)
            let x0 = Float(s.x0), w = Float(s.x1 - s.x0)
            let strong: Float = s.flag.severity == .info ? 0.10 : 0.16
            batch.rect(x0, py, w, ph, top: c.withAlpha(strong), bottom: c.withAlpha(0.025), radius: 0)
            batch.rect(x0, py, w, 2, color: c.withAlpha(0.9), radius: 0)
            batch.vline(x0, py, py + ph, color: c.withAlpha(0.28))
            batch.vline(x0 + w, py, py + ph, color: c.withAlpha(0.28))
        }
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
    }

    /// Top of the SPL layer: under the headphone band when that is shown.
    private var splTopY: Float { hpShown ? Float(hpBand.maxY) : Float(plot.minY) }

    /// Third-octave levels at the eardrum: stepped bars behind the curves, read on the right-hand axis.
    ///
    /// The fine spectrum is NOT rescaled into SPL. Its calibration is for tones (a full-scale sine reads 0 dBFS in every
    /// bin it falls into), and a bin is a fraction of a band: the level of a bin says nothing about the sound pressure of
    /// broadband music, and a sum of bins depends on the window and the display smoothing. Band RMS is the quantity that
    /// converts to pressure, so only the bands stand on the SPL axis; the curves keep the dBFS axis on the left.
    private func drawSPLBands(_ enc: MTLRenderCommandEncoder, _ g: inout Globals, levels: [Float], centers: [Float]) {
        let c = palette.splBand
        let n = min(levels.count, centers.count)
        let count = pointCount
        guard n > 0, count >= 2, let a = arena.allocate(Float.self, count: count) else { return }
        // One staircase over the plot's points: one fill and one line, so there is no seam between two bands.
        let edge = pow(Float(2), 1.0 / 6)
        let range = max(hi - lo, 1)
        var b = 0
        for j in 0..<count {
            let hz = axis.frequency(Float(j) / Float(count - 1))
            // Nominal centers (31.5, 63, ...) are not exactly a third apart: a step changes half way between two centers.
            while b < n - 1, hz * hz > centers[b] * centers[b + 1] { b += 1 }
            let inside = hz >= centers[0] / edge && hz <= centers[n - 1] * edge
            a.pointer[j] = inside ? min(max((levels[b] - splOffset - lo) / range, 0), 1) : 0
        }
        let sc = Float(scale)
        let top = splTopY
        enc.setScissorRect(MTLScissorRect(x: Int(Float(plot.minX) * sc), y: Int(top * sc), width: max(Int(Float(plot.width) * sc), 1),
                                          height: max(Int((Float(plot.maxY) - top) * sc), 1)))
        var u = CurveUniforms()
        u.rect = SIMD4(Float(plot.minX), Float(plot.minY), Float(plot.width), Float(plot.height))
        u.color = c; u.fillTop = highContrast ? 0.34 : 0.26; u.fillBottom = 0.05
        drawCurveFill(enc, values: (arena.buffer, a.offset, count), uniforms: u, lut: nil, globals: &g)
        u.color = c.scaledAlpha(highContrast ? 0.85 : 0.55); u.halfWidth = 0.5
        drawCurveLine(enc, values: (arena.buffer, a.offset, count), uniforms: u, additive: false, lut: nil, globals: &g)
    }

    /// Top of the "dB SPL" unit on the right-hand axis: under the headphone band and under its lowest tick label.
    private var splUnitY: CGFloat {
        guard hpShown, let lowest = hpTicks.last else { return CGFloat(splTopY) + 2 }
        return max(CGFloat(splTopY) + 2, CGFloat(hpY(lowest)) + 9)
    }

    /// Ticks of the SPL axis: round values, 10 dB apart or 20 when the plot is low.
    private var splTicks: [Float] {
        guard splShown else { return [] }
        let perDB = Float(plot.height) / max(hi - lo, 1)
        let step: Float = perDB * 10 >= (compact ? 20 : 26) ? 10 : 20
        var out: [Float] = []
        var v = ((lo + splOffset) / step).rounded(.up) * step
        while v <= musicTop + splOffset {
            let yy = y(forDB: v - splOffset)
            // The unit stands at the top of the axis: the first tick keeps clear of it.
            if yy >= (compact ? splTopY + 8 : Float(splUnitY) + 18), yy <= Float(plot.maxY) - 6 { out.append(v) }
            v += step
        }
        return out
    }

    private func drawGrid(_ enc: MTLRenderCommandEncoder, _ g: inout Globals) {
        let p = palette
        let px = Float(plot.minX), py = Float(plot.minY), pw = Float(plot.width), ph = Float(plot.height)
        // Frequency grid: minor log lines 5 % white, labeled lines 12 %.
        for f in LogAxis.minor where f > axis.minHz && f < axis.maxHz {
            batch.vline(x(forHz: f), py, py + ph, color: p.gridMinor)
        }
        for f in LogAxis.labeled where f > axis.minHz && f < axis.maxHz {
            batch.vline(x(forHz: f), py, py + ph, color: p.gridMajor)
        }
        // dB grid.
        let step = dbStep
        var db = (musicTop / step).rounded(.down) * step
        while db >= lo - 0.01 {
            let strong = abs(db) < 0.01
            let yy = y(forDB: db)
            if yy >= py - 0.5, yy <= py + ph + 0.5 { batch.hline(px, px + pw, yy, color: strong ? p.gridStrong : p.gridMajor) }
            db -= step
        }
        // Tick marks of the SPL axis, at the right edge, in the color of the bars.
        for v in splTicks { batch.hline(px + pw - 7, px + pw, y(forDB: v - splOffset), color: p.splBand.withAlpha(0.8)) }
        if laneShown { addLaneGrid() }
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
    }

    private static func boxBlur(_ src: UnsafePointer<Float>, _ dst: UnsafeMutablePointer<Float>, _ n: Int, _ r: Int) {
        var sum: Float = 0
        var count = 0
        for i in 0..<min(r + 1, n) { sum += src[i]; count += 1 }
        for i in 0..<n {
            dst[i] = sum / Float(max(count, 1))
            let add = i + r + 1, drop = i - r
            if add < n { sum += src[add]; count += 1 }
            if drop >= 0 { sum -= src[drop]; count -= 1 }
        }
    }

    // MARK: Text

    var axisFont: CTFont { Fonts.mono(compact ? 10 : 11, .regular) }
    var captionFont: CTFont { Fonts.ui(compact ? 10 : 11, .semibold) }

    override func drawStatic(_ o: OverlayContext) {
        let p = palette
        let small = axisFont
        // Frequency labels, skipping any that would collide.
        var lastRight: CGFloat = -100
        for f in LogAxis.labeled where f >= axis.minHz && f <= axis.maxHz {
            let label = Fmt.axisHz(f)
            let w = o.measure(label, font: small)
            var cx = CGFloat(x(forHz: f))
            // The end labels sit inside the plot width.
            cx = min(max(cx, plot.minX + w / 2), plot.maxX - w / 2)
            guard cx - w / 2 > lastRight + 6 else { continue }
            o.text(label, x: cx, y: axisBottom + 7, font: small, color: p.textDim, h: .center, v: .top)
            lastRight = cx + w / 2
        }
        if !compact {
            o.text("Hz", x: plot.minX - 7, y: axisBottom + 7, font: small, color: p.textFaint, h: .right, v: .top)
        }

        let step = dbStep
        var db = (musicTop / step).rounded(.down) * step
        while db >= lo - 0.01 {
            let yy = CGFloat(y(forDB: db))
            if yy > plot.minY + 3, yy < plot.maxY - 3 || db <= lo + 0.01 {
                o.text(Fmt.number(db, digits: 0), x: plot.minX - 7, y: min(yy, plot.maxY - 4), font: small, color: p.textDim, h: .right, v: .middle)
            }
            db -= step
        }
        // With the headphone band the music scale starts under the band: its unit stands there.
        let unitY = hpShown ? CGFloat(y(forDB: musicTop)) - 18 : plot.minY + 1
        o.text(splShown ? "dBFS" : "dB", x: plot.minX - 7, y: unitY, font: small, color: p.textFaint, h: .right, v: .top)
        if splShown {
            // Right-hand axis of the band layer, in its color. The unit stands on the row of the Hz labels.
            let col = p.splBand.withAlpha(1)
            for v in splTicks {
                o.text(Fmt.number(v, digits: 0), x: plot.maxX + 5, y: CGFloat(y(forDB: v - splOffset)), font: small, color: col, v: .middle)
            }
            if !compact { o.text("dB SPL", x: size.width - 3, y: splUnitY, font: small, color: col, h: .right, v: .top) }
        }
        if laneShown { drawLaneAxis(o) }
    }

    override func drawDynamic(_ o: OverlayContext) {
        guard let f = frame else { return }
        let p = palette
        drawHeader(o, f)
        if showsHeadphoneLegend, let hp = f.headphone { drawHeadphoneLegend(o, hp) }

        if hpShown, !compact {
            // Right-hand axis of the headphone curves: dB relative to 1 kHz, in the response color.
            let font = axisFont
            let col = p.hpResponse
            for d in hpTicks {
                o.text(d == 0 ? "0" : Fmt.number(d, digits: 0, signed: true), x: plot.maxX + 5, y: CGFloat(hpY(d)), font: font, color: col, v: .middle)
            }
            // The axis name stands over the axis, at the right end of the headphone legend row.
            o.text("dB rel", x: size.width - 3, y: plot.minY - 4, font: font, color: col, h: .right, v: .bottom)
        }
        drawStressLabels(o, f)
        drawPeakLabels(o, f)
        if laneShown { drawLaneText(o, f) }
    }

    /// Peak values as text. Fixed column widths (see callers) so nothing shifts when digits change.
    private func peakTexts(_ f: AnalysisFrame) -> (has: Bool, hz: String, note: String, cents: String, db: String) {
        let has = !Fmt.isFloor(f.peak.levelDB) && f.peak.frequencyHz > 0
        // The analyzer names a note only for a tonal peak. No name = broad content: frequency and level, no note, no cents.
        // (Nothing is made up here from the frequency.)
        let note = Fmt.prettyNote(f.peak.noteName)
        return (has, has ? Fmt.hz(f.peak.frequencyHz) : Fmt.dash, has ? note : "",
                has && !note.isEmpty ? Fmt.cents(f.peak.cents) : "", has ? Fmt.db(f.peak.levelDB) + " dB" : Fmt.dash)
    }

    static func wholeHz(_ hz: Float) -> String { hz >= 10_000 ? String(format: "%.1f kHz", hz / 1000) : "\(Int(hz.rounded())) Hz" }

    var headerMidY: CGFloat { (compact ? 3 : 7) + headerHeight / 2 }

    /// The row over the plot, at every size: legend on the left; on the right the lowest strong content and, under 1200 pt,
    /// the peak readout. Priority when the row is short: peak, lowest strong content, then as many legend entries as fit.
    /// Without a peak the readout takes no room at all.
    private func drawHeader(_ o: OverlayContext, _ f: AnalysisFrame) {
        let p = palette
        let midY = headerMidY
        let cap = captionFont
        var right = size.width - 6

        let t = peakTexts(f)
        if showsHeaderReadout {
            // The cursor asks the question now: its answer takes the place of the peak readout and of the lowest strong
            // content. The legend keeps room for its first entry.
            // The legend keeps at least its first entry, and a third of the row when the row is long.
            var keep = max(compact ? 40 : 56, (right - plot.minX) * 0.32)
            // With a comparison the legend names A and B: the readout gives way, its least important parts first.
            if comparison != nil || hpHidden { keep = max(keep, minimumLegendWidth(o) + (hpHidden ? bandHiddenWidth(o, short: true) : 0)) }
            right = CursorHeader.draw(o, items: cursorItems(), right: right, left: plot.minX + 2 + keep, midY: midY,
                                      compact: compact, pinned: cursor?.isPinned == true, palette: p) - 20
        } else if peakInHeader, t.has, headerHasRoomForPeak(o, right: right) {
            // The large view gives the number a little more weight: it is the panel's headline, as the card was.
            let large = size.width >= 1200
            let num = Fonts.ui(compact ? 11 : (large ? 15 : 13), .medium), small = Fonts.ui(compact ? 10 : (large ? 13 : 12), .regular)
            let wDB = o.measure("\u{2212}00.0 dB", font: small), wCents = o.measure("+50 \u{00A2}", font: small)
            let wNote = o.measure("G\u{266F}8", font: small), wHz = o.measure("00000.0 Hz", font: num)
            let narrow = size.width < 640
            // With a reference the legend must name A and B: in a narrow card the note name gives way to them.
            let noteRoom = wDB + wNote + wHz + 7 + (compact ? 10 : 16) + (narrow ? 0 : wCents + 6)
            let showNote = !t.note.isEmpty && right - noteRoom - (plot.minX + 2) >= headerReserve(o)
            o.text(t.db, x: right, y: midY, font: small, color: p.text, h: .right, v: .middle); right -= wDB + (compact ? 5 : 8)
            if showNote {
                if !narrow { o.text(t.cents, x: right, y: midY, font: small, color: p.textDim, h: .right, v: .middle); right -= wCents + 6 }
                let hue = Palette.spectrumColor(atHz: f.peak.frequencyHz).rgba(1)
                o.text(t.note, x: right - wNote, y: midY, font: small, color: mix(hue, SIMD4(1, 1, 1, 1), t: 0.25), v: .middle); right -= wNote + (compact ? 5 : 8)
            }
            o.text(t.hz, x: right, y: midY, font: num, color: p.text, h: .right, v: .middle); right -= wHz + 7
            if size.width >= 560 {
                right -= o.text("PEAK", x: right, y: midY, font: cap, color: p.textFaint, h: .right, v: .middle, tracking: 1.0) + 16
            }
        }
        // The legend comes first in a short row: under 640 pt the lowest strong content is left to the large view.
        if f.lowestStrongHz > 0, size.width >= 640, !showsHeaderReadout {
            // Whole Hz (the measure is not finer), in the neutral text color: it is a fact about the music, not an alarm.
            let value = Self.wholeHz(f.lowestStrongHz)
            let label = size.width >= 900 ? "lowest strong content:" : "lowest"
            let vf = Fonts.ui(12, .medium), lf = Fonts.ui(11, .regular)
            let need = o.measure(value, font: vf) + 5 + o.measure(label, font: lf)
            if right - need > plot.minX + 90 {
                right -= o.text(value, x: right, y: midY, font: vf, color: p.text, h: .right, v: .middle) + 5
                right -= o.text(label, x: right, y: midY, font: lf, color: p.textDim, h: .right, v: .middle) + 16
            }
        }
        // The SPL layer names itself in the legend row, after the curves; its place is kept free first.
        var splLabel = ""
        if levelAxis == .dBSPL {
            let font = Fonts.ui(compact ? 10 : 11, .regular)
            let room = right - (plot.minX + 2)
            let names = splShown ? Self.splLegends : Self.notCalibratedNotes
            let swatch: CGFloat = splShown ? 21 : 0
            // A longer name only when the first curve of the legend still fits beside it; the shortest name always.
            splLabel = names.first { o.measure($0, font: font) + swatch + 60 <= room } ?? names[names.count - 1]
            if !splLabel.isEmpty { right -= o.measure(splLabel, font: font) + swatch + 14 }
        }
        // The lane has taken the room of the headphone band: the header says so, before any legend entry past A and B.
        var hiddenNote = ""
        if hpHidden {
            // Two notes in one narrow row: this one leaves the other the room of its shortest form.
            let other = laneHiddenTooSmall ? bandHiddenWidth(o, text: Self.laneHiddenNotes[Self.laneHiddenNotes.count - 1]) : 0
            let room = right - (plot.minX + 2) - minimumLegendWidth(o) - other
            hiddenNote = ComparisonText.bandHidden.first { bandHiddenWidth(o, text: $0) <= room } ?? ""
            if !hiddenNote.isEmpty { right -= bandHiddenWidth(o, text: hiddenNote) }
        }
        // The panel cannot give the lane its room: one line says so, before any legend entry past A and B.
        var laneNote = ""
        if laneHiddenTooSmall {
            let room = right - (plot.minX + 2) - minimumLegendWidth(o)
            laneNote = Self.laneHiddenNotes.first { bandHiddenWidth(o, text: $0) <= room } ?? ""
            if !laneNote.isEmpty { right -= bandHiddenWidth(o, text: laneNote) }
        }
        // No room in this row (a narrow card): the lane's strip says it.
        bandHiddenNoteInStrip = hpHidden && hiddenNote.isEmpty
        var x = drawLegendRow(o, y: midY, from: plot.minX + 2, to: right)
        if !hiddenNote.isEmpty {
            x += o.text(hiddenNote, x: x, y: midY, font: Fonts.ui(compact ? 10 : 11, .regular), color: mix(p.warn, p.textDim, t: 0.4), v: .middle) + (compact ? 9 : 14)
        }
        if !laneNote.isEmpty {
            x += o.text(laneNote, x: x, y: midY, font: Fonts.ui(compact ? 10 : 11, .regular), color: mix(p.warn, p.textDim, t: 0.4), v: .middle) + (compact ? 9 : 14)
        }
        guard !splLabel.isEmpty else { return }
        let col = p.splBand
        if splShown {
            _ = legendItem(o, splLabel, x: &x, y: midY, limit: size.width, draw: { x, y in
                // The swatch is two steps of the layer.
                o.fillRect(CGRect(x: x, y: y - 1, width: 8, height: 6), color: col.scaledAlpha(0.30))
                o.fillRect(CGRect(x: x + 8, y: y - 5, width: 8, height: 10), color: col.scaledAlpha(0.30))
                o.line(x, y - 1, x + 8, y - 1, color: col.scaledAlpha(0.9), width: 1)
                o.line(x + 8, y - 5, x + 16, y - 5, color: col.scaledAlpha(0.9), width: 1)
            })
        } else {
            o.text(splLabel, x: x, y: midY, font: Fonts.ui(compact ? 10 : 11, .regular), color: mix(p.warn, p.textDim, t: 0.4), v: .middle)
        }
    }

    /// A note that says what the panel does NOT show (the dropped lane) comes before the peak readout: in a card too
    /// narrow for both, the readout gives way.
    private func headerHasRoomForPeak(_ o: OverlayContext, right: CGFloat) -> Bool {
        let reserve = headerReserve(o)
        guard reserve > 0, comparison == nil || laneHiddenTooSmall || (hpHidden && !laneShown) else { return true }
        let num = Fonts.ui(compact ? 11 : 13, .medium), small = Fonts.ui(compact ? 10 : 12, .regular)
        let readout = o.measure("\u{2212}00.0 dB", font: small) + o.measure("00000.0 Hz", font: num) + (compact ? 5 : 8) + 7
        return right - readout - (plot.minX + 2) >= reserve
    }

    /// Room the row keeps on the left before the peak readout may take it: the first legend entries (Mid, and with a
    /// reference B and A) and the shortest forms of the notes that say what is hidden. Zero when there is nothing to keep.
    private func headerReserve(_ o: OverlayContext) -> CGFloat {
        var notes: CGFloat = 0
        if laneHiddenTooSmall, let shortest = Self.laneHiddenNotes.last { notes += bandHiddenWidth(o, text: shortest) }
        // (With a lane the strip can say it; without one only this row can.)
        if hpHidden, !laneShown { notes += bandHiddenWidth(o, short: true) }
        return comparison != nil || notes > 0 ? minimumLegendWidth(o) + notes : 0
    }

    static let splLegends = ["dB SPL at eardrum \u{00B7} 1/3 oct \u{00B7} \u{2248}", "SPL at eardrum \u{00B7} 1/3 oct \u{00B7} \u{2248}", "SPL 1/3 oct \u{2248}", "SPL \u{2248}"]
    static let notCalibratedNotes = ["dB SPL: not calibrated", "SPL: not calibrated", "not calibrated"]

    func legendStroke(_ o: OverlayContext, _ color: SIMD4<Float>, dash: [CGFloat] = [], width: CGFloat = 1.5, length: CGFloat = 16) -> (CGFloat, CGFloat) -> Void {
        { x, y in o.line(x, y, x + length, y, color: color, width: width, dash: dash) }
    }

    /// One legend entry. Returns false (and draws nothing) when it does not fit before `limit`.
    func legendItem(_ o: OverlayContext, _ label: String, x: inout CGFloat, y: CGFloat, limit: CGFloat, swatch: CGFloat = 16,
                            bold: Bool = false, draw: (CGFloat, CGFloat) -> Void) -> Bool {
        let font = Fonts.ui(compact ? 10 : 11, bold ? .semibold : .regular)
        let w = (swatch > 0 ? swatch + 5 : 0) + o.measure(label, font: font)
        guard x + w <= limit else { return false }
        if swatch > 0 { draw(x, y); x += swatch + 5 }
        x += o.text(label, x: x, y: y, font: font, color: bold ? palette.text : palette.textDim, v: .middle) + (compact ? 9 : 14)
        return true
    }

    /// Legend of the source curves, in the header. What does not fit is left out, from the end. Returns where the row ends.
    @discardableResult
    private func drawLegendRow(_ o: OverlayContext, y: CGFloat, from: CGFloat, to limit: CGFloat) -> CGFloat {
        let p = palette
        var xx = from
        legendBody(o, p, y: y, limit: limit, xx: &xx)
        return xx
    }

    private func legendBody(_ o: OverlayContext, _ p: Palette, y: CGFloat, limit: CGFloat, xx: inout CGFloat) {
        legendNaming.removeAll(keepingCapacity: true)
        defer {
            // The Metal pass draws what this row named: a change of the row is a change of the picture.
            if legendNaming != legendNamed { legendNamed = legendNaming; needsDisplay = true }
        }
        if options.showMid {
            guard legendItem(o, "Mid", x: &xx, y: y, limit: limit, draw: { x, y in
                for (k, hz) in [60, 700, 9000].enumerated() {
                    let x0 = x + CGFloat(k) * 16 / 3
                    o.line(x0, y, x0 + 16 / 3, y, color: Palette.spectrumColor(atHz: Float(hz)).rgba(1), width: 2.5)
                }
            }) else { return }
        }
        if let slice = ghostSlice {
            // Only while the ghost trace shows, right after the curve whose past it is.
            guard legendItem(o, "then (\(CursorMath.ago(slice.secondsAgo)))", x: &xx, y: y, limit: limit, draw: legendStroke(o, p.cursorGhost, dash: [6, 4], width: 1.25)) else { return }
        }
        if let c = comparison { guard drawComparisonLegend(o, c, x: &xx, y: y, limit: limit) else { return } }
        if wantsLeftRight {
            // L and R together or not at all: a legend that names only L would say there is no R curve.
            let font = Fonts.ui(compact ? 10 : 11, .regular)
            guard xx + 2 * (16 + 5) + o.measure("L", font: font) + o.measure("R", font: font) + (compact ? 9 : 14) <= limit else { return }
            guard legendItem(o, "L", x: &xx, y: y, limit: limit, draw: legendStroke(o, p.spectrumLeft.withAlpha(1), width: 1.5)) else { return }
            guard legendItem(o, "R", x: &xx, y: y, limit: limit, draw: legendStroke(o, p.spectrumRight.withAlpha(1), width: 1.5)) else { return }
            legendNaming.insert(.left)
        }
        if options.showSide {
            guard legendItem(o, "Side", x: &xx, y: y, limit: limit, draw: legendStroke(o, p.side, width: 1.25)) else { return }
            legendNaming.insert(.side)
        }
        // The swatches are the lines of the plot: warm white for peak hold, solid cool grey for the average.
        if wantsPeakHold {
            guard legendItem(o, "Peak hold", x: &xx, y: y, limit: limit, draw: legendStroke(o, comparison != nil ? p.peakHold.scaledAlpha(0.5) : p.peakHold, width: 1)) else { return }
            legendNaming.insert(.peakHold)
        }
        if wantsLongTerm, comparison == nil {
            guard legendItem(o, Self.averageLegend, x: &xx, y: y, limit: limit, draw: legendStroke(o, p.average, width: 1)) else { return }
            legendNaming.insert(.average)
        }
        // Mid is drawn as measured; L and R get about 1/6 octave of display smoothing above 2 kHz. Said only when it is so.
        if wantsLeftRight, leftRightSmoothed { _ = legendItem(o, Self.leftRightSmoothingHint, x: &xx, y: y, limit: limit, swatch: 0, draw: { _, _ in }) }
    }

    /// Legend of the headphone curves: the second header row, over the plot. No plate, nothing over the data.
    private func drawHeadphoneLegend(_ o: OverlayContext, _ hp: HeadphoneReading) {
        let p = palette
        let yy = headerMidY + headerHeight / 2 + Self.headphoneRowHeight / 2 - 1
        let limit = size.width - 6 - o.measure("dB rel", font: axisFont) - 10
        var xx = plot.minX + 2
        if let other = referenceHeadphoneName {
            // Two headphones: each response trace carries its name.
            guard legendItem(o, "B \u{00B7} \(hp.modelName)", x: &xx, y: yy, limit: limit, bold: true, draw: legendStroke(o, p.hpResponse)) else { return }
            guard legendItem(o, ComparisonText.referenceHeadphone(other), x: &xx, y: yy, limit: limit,
                             draw: legendStroke(o, p.hpResponse.withAlpha(0.85), dash: [2, 2.8], width: 1.6)) else { return }
        } else {
            guard legendItem(o, hp.modelName, x: &xx, y: yy, limit: limit, swatch: 0, bold: true, draw: { _, _ in }) else { return }
            guard legendItem(o, "Response", x: &xx, y: yy, limit: limit, draw: legendStroke(o, p.hpResponse)) else { return }
        }
        if hp.hasTarget {
            guard legendItem(o, "Target", x: &xx, y: yy, limit: limit, draw: legendStroke(o, p.hpTarget, dash: [1.8, 2.7], width: 1.8)) else { return }
            guard legendItem(o, "Error", x: &xx, y: yy, limit: limit, draw: { x, y in
                o.fillRect(CGRect(x: x, y: y - 4, width: 16, height: 8), color: p.hpResponse.withAlpha(0.22), radius: 1)
            }) else { return }
        }
        guard atEarShown else { return }
        _ = legendItem(o, hp.hasTarget ? Self.atEarVsTargetLegend : Self.atEardrumLegend, x: &xx, y: yy, limit: limit, draw: legendStroke(o, p.hpAtEar.withAlpha(0.8), width: 1.25))
    }

    /// The plot label of each stress span, at the top of the span. A label moves down a row when its place is taken, and is
    /// left out when no row is free: never text on text.
    private func drawStressLabels(_ o: OverlayContext, _ f: AnalysisFrame) {
        let font = Fonts.ui(compact ? 10 : 11, .semibold)
        let taken: [CGRect] = []
        for s in stressSpans(f) {
            let text = s.flag.plotLabel.isEmpty ? s.flag.title : s.flag.plotLabel
            let w = o.measure(text, font: font)
            guard w + 8 < plot.width else { continue }
            let cx = min(max((s.x0 + s.x1) / 2, plot.minX + w / 2 + 5), plot.maxX - w / 2 - 5)
            let color = mix(severityColor(s.flag.severity), SIMD4(1, 1, 1, 1), t: 0.30).withAlpha(1)
            for row in 0..<6 {
                let yy = (hpShown ? hpBand.maxY : plot.minY) + 7 + CGFloat(row) * 16
                guard yy + 14 < plot.maxY else { break }
                let box = o.textBounds(text, x: cx, y: yy, font: font, h: .center, v: .top)
                guard o.isFree(box, pad: 3, others: taken) else { continue }
                o.fillRect(box.insetBy(dx: -4, dy: -2.5), color: palette.plot.withAlpha(0.72), radius: 4)
                o.text(text, x: cx, y: yy, font: font, color: color, h: .center, v: .top)
                break
            }
        }
    }

    /// Where a note label went: its dot, its ink box and whether a leader line ties it to the dot. For tests.
    struct PeakLabelPlacement { let name: String; let dot: CGPoint; let box: CGRect; let leader: Bool }
    private(set) var peakLabelPlacements: [PeakLabelPlacement] = []

    /// Note names of the secondary peaks. A label sits directly above its own dot. When that place is taken it may move a
    /// little (higher, or up and to one side) WITH a 1 px leader line to its dot, and never onto or past the frequency of
    /// another peak of the list (labelled or not). When no such place is free the label is left out: a missing name is
    /// better than a name over the wrong peak.
    private func drawPeakLabels(_ o: OverlayContext, _ f: AnalysisFrame) {
        let font = Fonts.ui(10, .semibold)
        peakLabelPlacements.removeAll(keepingCapacity: true)
        let base: [CGRect] = []
        // Every peak of the list inside the plot, tonal or not, with or without a label: nothing sits on its marker.
        var dots: [(hz: Float, at: CGPoint)] = []
        for pk in f.topPeaks where !Fmt.isFloor(pk.levelDB) && pk.frequencyHz > axis.minHz && pk.frequencyHz < axis.maxHz {
            dots.append((pk.frequencyHz, CGPoint(x: CGFloat(x(forHz: pk.frequencyHz)), y: CGFloat(y(forDB: min(max(pk.levelDB, lo), hi))))))
        }
        if !Fmt.isFloor(f.peak.levelDB), f.peak.frequencyHz > axis.minHz, !dots.contains(where: { $0.hz == f.peak.frequencyHz }) {
            dots.append((f.peak.frequencyHz, CGPoint(x: CGFloat(x(forHz: f.peak.frequencyHz)), y: CGFloat(y(forDB: min(f.peak.levelDB, hi))))))
        }
        for pk in secondaryPeaks(f) {
            let name = Fmt.prettyNote(pk.noteName)
            guard !name.isEmpty else { continue }
            let mx = CGFloat(x(forHz: pk.frequencyHz)), my = CGFloat(y(forDB: min(pk.levelDB, hi)))
            let color = mix(Palette.spectrumColor(atHz: pk.frequencyHz).rgba(1), SIMD4(1, 1, 1, 1), t: 0.55)
            let others = dots.filter { $0.hz != pk.frequencyHz }
            let taken = base + others.map { CGRect(x: $0.at.x - 5, y: $0.at.y - 5, width: 10, height: 10) }
            // (center x, bottom y, leader)
            let tries: [(CGFloat, CGFloat, Bool)] = [(mx, my - 9, false), (mx, my - 21, true), (mx + 7, my - 17, true), (mx - 7, my - 17, true),
                                                   (mx + 10, my - 27, true), (mx - 10, my - 27, true)]
            for t in tries {
                let box = o.textBounds(name, x: t.0, y: t.1, font: font, h: .center, v: .bottom)
                guard box.minX > plot.minX + 2, box.maxX < plot.maxX - 2, box.minY > plot.minY + 2, o.isFree(box, pad: 2, others: taken) else { continue }
                // An offset label stays on its own side of every other peak.
                if t.2, others.contains(where: { $0.at.x > mx ? box.maxX >= $0.at.x - 1 : box.minX <= $0.at.x + 1 }) { continue }
                if t.2 { o.line(mx, my - 3.6, t.0, box.maxY + 1.5, color: color.withAlpha(0.75), width: 1) }
                // A small plate: the label stands on peak hold and L / R lines.
                o.fillRect(box.insetBy(dx: -2.5, dy: -1.5), color: palette.plot.withAlpha(0.62))
                o.text(name, x: t.0, y: t.1, font: font, color: color, h: .center, v: .bottom)
                peakLabelPlacements.append(PeakLabelPlacement(name: name, dot: CGPoint(x: mx, y: my), box: box, leader: t.2))
                break
            }
        }
    }

    static let atEarVsTargetLegend = "At ear vs target"
    static let atEardrumLegend = "At eardrum (incl. ear gain)"

    /// Legend name of the `average` curve: it is a long-term average, slower than the peak hold decay.
    static let averageLegend = "Long-term"

    /// A display curve in dB, one value per plot point, as drawn (after clamps and smoothing). Nil when it is not shown. For tests.
    func curveForTesting(_ name: String) -> [Float]? {
        guard let f = frame else { return nil }
        if !curvesValid { rebuildCurves(f) }
        guard let slot = Slot.allCases.first(where: { "\($0)" == name }), slotValid[slot.rawValue] else { return nil }
        let v = pointer(slot)
        return (0..<pointCount).map { v[$0] * (hi - lo) + lo }
    }

    /// Runs the L / R display smoothing over a curve given in dB (one value per plot point), for tests.
    func smoothHighsForTesting(_ db: [Float]) -> [Float] {
        let n = min(db.count, Self.maxPoints - 1)
        let tmp = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxPoints)
        defer { tmp.deallocate() }
        for i in 0..<n { tmp[i] = (db[i] - lo) / (hi - lo) }
        smoothHighs(tmp, n)
        return (0..<n).map { tmp[$0] * (hi - lo) + lo }
    }
    /// The same with the opposite channel as the reference.
    func smoothHighsForTesting(_ db: [Float], other: [Float]) -> [Float] {
        let n = min(db.count, other.count, Self.maxPoints - 1)
        let tmp = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxPoints * 2)
        defer { tmp.deallocate() }
        for i in 0..<n { tmp[i] = (db[i] - lo) / (hi - lo); tmp[Self.maxPoints + i] = (other[i] - lo) / (hi - lo) }
        smoothHighs(tmp, n, other: tmp + Self.maxPoints)
        return (0..<n).map { tmp[$0] * (hi - lo) + lo }
    }
    var pointCountForTesting: Int { pointCount }
    func frequencyForTesting(point i: Int) -> Float { axis.frequency(Float(i) / Float(max(pointCount - 1, 1))) }

    /// The band of the headphone curves in points (nil without the overlay), for tests.
    var headphoneBandForTesting: CGRect? { hpShown ? hpBand : nil }
    /// The plot rectangle in points, for tests.
    var plotRectForTesting: CGRect { plot }
    /// Labeled and minor grid frequencies inside the plot, for tests.
    var gridFrequenciesForTesting: [Float] { (LogAxis.labeled + LogAxis.minor).filter { $0 > axis.minHz && $0 < axis.maxHz } }

    // MARK: Hover

    override func cursor(at point: CGPoint) -> PanelCursor? {
        guard pointerArea(point) != nil, plot.width > 1 else { return nil }
        return PanelCursor(frequencyHz: axis.frequency(Float((point.x - plot.minX) / plot.width)), source: .spectrum)
    }

    override func isOnCursor(_ point: CGPoint) -> Bool {
        guard let c = cursor, pointerArea(point) != nil else { return false }
        return abs(CGFloat(x(forHz: c.frequencyHz)) - point.x) <= 5
    }

    /// x of the cursor hairline in points, nil without a cursor inside the axis. For tests.
    var cursorXForTesting: CGFloat? {
        guard cursorLinked, let c = cursor, c.frequencyHz >= axis.minHz, c.frequencyHz <= axis.maxHz else { return nil }
        return CGFloat(x(forHz: c.frequencyHz))
    }
    /// x of a frequency on this panel's axis, for tests.
    func xForTesting(hz: Float) -> CGFloat { CGFloat(x(forHz: hz)) }

    /// The values of the newest frame at the cursor frequency.
    struct CursorValues {
        var mid: Float?, left: Float?, right: Float?, side: Float?, atEar: Float?, atEarDelta: Float?, spl: (center: Float, level: Float)?, then: Float?
        /// A/B compare: A as drawn, B's long-term curve, and the lane's value (nil where the lane has a gap).
        var reference: Float?, liveAverage: Float?, delta: Float?
    }

    func cursorValues() -> CursorValues? {
        guard let c = cursor, let f = frame else { return nil }
        let s = f.spectrum, hz = c.frequencyHz
        var v = CursorValues()
        v.mid = CursorMath.level(of: s.mid, frequencies: s.frequencies, atHz: hz)
        // Not tied to the legend: the readout's width decides the legend's room, so that would be a loop.
        if wantsLeftRight {
            v.left = CursorMath.level(of: s.left, frequencies: s.frequencies, atHz: hz)
            v.right = CursorMath.level(of: s.right, frequencies: s.frequencies, atHz: hz)
        }
        if options.showSide { v.side = CursorMath.level(of: s.side, frequencies: s.frequencies, atHz: hz) }
        if hpShown, let hp = f.headphone, hp.hasTarget, let m = v.mid,
           let r = CursorMath.level(of: hp.responseDB, frequencies: s.frequencies, atHz: hz),
           let t = CursorMath.level(of: hp.targetDB, frequencies: s.frequencies, atHz: hz) {
            // The "At ear vs target" curve at this frequency, before its display smoothing: Mid + response - target.
            v.atEar = m + r - t; v.atEarDelta = r - t
        }
        if splShown, let e = f.spl, let t = f.thirdOctave, let b = CursorMath.thirdOctaveBand(centers: t.centersHz, containing: hz),
           b < e.bandLevelsEardrum.count, e.bandLevelsEardrum[b] > SPLReading.floorDB + 1 {
            v.spl = (t.centersHz[b], e.bandLevelsEardrum[b])
        }
        if let slice = ghostSlice { v.then = CursorMath.level(of: slice.midDB, frequencies: slice.frequencies, atHz: hz) }
        if comparison != nil {
            ensureComparisonCurrent()
            v.reference = compare.value(of: compare.referenceDrawn, atHz: hz)
            v.liveAverage = CursorMath.level(of: s.average, frequencies: s.frequencies, atHz: hz)
            v.delta = laneValue(atHz: hz)
        }
        return v
    }

    override func cursorItems() -> [CursorReadoutItem] {
        guard let c = cursor, let v = cursorValues() else { return [] }
        var items = [CursorReadoutItem(text: CursorMath.hz(c.frequencyHz), rank: CursorReadoutItem.hz)]
        if let n = CursorMath.note(c.frequencyHz) { items.append(.init(text: n, rank: CursorReadoutItem.note, tone: .dim)) }
        if let m = v.mid { items.append(.init(text: "Mid \(Fmt.db(m)) dB", rank: CursorReadoutItem.mid)) }
        if comparison != nil { items.append(contentsOf: comparisonCursorItems(v)) }
        if let l = v.left, let r = v.right { items.append(.init(text: "L \(Fmt.db(l))  R \(Fmt.db(r))", rank: CursorReadoutItem.leftRight, tone: .dim)) }
        if let sd = v.side { items.append(.init(text: "Side \(Fmt.db(sd))", rank: CursorReadoutItem.side, tone: .dim)) }
        if let a = v.atEarDelta { items.append(.init(text: "at ear vs target \(Fmt.number(a, signed: true)) dB", rank: CursorReadoutItem.atEar, tone: .dim)) }
        if let e = v.spl { items.append(.init(text: "1/3 oct \u{2248}\(Fmt.number(e.level, digits: 0)) dB SPL", rank: CursorReadoutItem.spl, tone: .dim)) }
        if let slice = ghostSlice, let t = v.then {
            let level = t <= Self.ghostFloorDB ? "under \(Fmt.number(Self.ghostFloorDB, digits: 0))" : Fmt.db(t)
            items.append(.init(text: "then \(level) dB (\(CursorMath.ago(slice.secondsAgo)))", rank: CursorReadoutItem.then, tone: .ghost))
        }
        return items
    }
    /// The spectrogram history holds nothing under its floor: a "then" level at or under it is "under -75", not a number.
    static let ghostFloorDB: Float = -75

    override func hoverLabel() -> (lines: [String], anchor: CGPoint)? {
        if cursorLinked {
            guard showsPointerReadout, let hv = hover, let area = pointerArea(hv), let c = cursor, let v = cursorValues() else { return nil }
            var first = CursorMath.hz(c.frequencyHz)
            if let n = CursorMath.note(c.frequencyHz) { first += "   \(n)" }
            var lines = [first]
            if let m = v.mid {
                var l = "Mid  \(Fmt.db(m)) dB"
                if let sd = v.side { l += "   Side  \(Fmt.db(sd)) dB" }
                lines.append(l)
            }
            if let l = v.left, let r = v.right { lines.append("L  \(Fmt.db(l)) dB   R  \(Fmt.db(r)) dB") }
            if let a = v.atEar, let d = v.atEarDelta { lines.append("at ear vs target  \(Fmt.db(a)) dB  (\(Fmt.number(d, signed: true)))") }
            if let e = v.spl { lines.append("1/3 oct \(Fmt.axisHz(e.center)) Hz  \u{2248}\(Fmt.number(e.level, digits: 0)) dB SPL at eardrum") }
            if comparison != nil { lines.append(contentsOf: comparisonHoverLines(v)) }
            lines.append(pointerLevelLine(hv, area))
            return (lines, hv)
        }
        guard let hv = hover, let area = pointerArea(hv) else { return nil }
        let t = Float((hv.x - plot.minX) / plot.width)
        let hz = axis.frequency(t)
        let db = lo + Float((plot.maxY - hv.y) / plot.height) * (hi - lo)
        // Every number says what it is: the cursor position, or a measured curve under the cursor.
        var first = "cursor  \(Fmt.hz(hz))"
        if let n = Fmt.note(forHz: hz) { first += "   \(n.name) \(Fmt.cents(n.cents))" }
        var lines = [first, area == .lane ? "cursor  \(ComparisonText.deltaName) \(Fmt.number(laneDB(atY: hv.y), signed: true)) dB" : "cursor  \(Fmt.number(db)) dB"]
        if let f = frame {
            let s = f.spectrum
            if let m = level(of: s.mid, frequencies: s.frequencies, atHz: hz) {
                var third = "Mid  \(Fmt.db(m)) dB"
                if let sd = level(of: s.side, frequencies: s.frequencies, atHz: hz) { third += "   Side  \(Fmt.db(sd)) dB" }
                lines.append(third)
            }
            if wantsLeftRight, let l = level(of: s.left, frequencies: s.frequencies, atHz: hz),
               let r = level(of: s.right, frequencies: s.frequencies, atHz: hz) {
                lines.append("L  \(Fmt.db(l)) dB   R  \(Fmt.db(r)) dB")
            }
            if comparison != nil {
                ensureComparisonCurrent()
                var v = CursorValues()
                v.reference = compare.value(of: compare.referenceDrawn, atHz: hz)
                v.liveAverage = CursorMath.level(of: s.average, frequencies: s.frequencies, atHz: hz)
                v.delta = laneValue(atHz: hz)
                lines.append(contentsOf: comparisonHoverLines(v))
            }
        }
        return (lines, hv)
    }

    private func level(of values: [Float], frequencies: [Float], atHz hz: Float) -> Float? {
        let n = min(values.count, frequencies.count)
        guard n >= 2, let f0 = frequencies.first, f0 > 0, frequencies[n - 1] > f0 else { return nil }
        let idx = log(hz / f0) / log(frequencies[n - 1] / f0) * Float(n - 1)
        guard idx >= 0, idx <= Float(n - 1) else { return nil }
        let i = min(Int(idx), n - 2)
        let t = idx - Float(i)
        return values[i] * (1 - t) + values[i + 1] * t
    }

    // MARK: Accessibility

    override var accessibilityLabelText: String { "Spectrum" }
    override var accessibilityValueText: String {
        guard let f = frame, !Fmt.isFloor(f.peak.levelDB) else { return "No signal" }
        var s = "Peak \(Fmt.hz(f.peak.frequencyHz))"
        if !f.peak.noteName.isEmpty { s += ", note \(f.peak.noteName), \(Int(f.peak.cents.rounded())) cents" }
        s += ", \(String(format: "%.1f", f.peak.levelDB)) dB"
        let others = f.topPeaks.filter { !$0.noteName.isEmpty && !Self.isSamePeak($0, f.peak) }.prefix(4).map { "\($0.noteName) at \(Fmt.hz($0.frequencyHz))" }
        if !others.isEmpty { s += ". Further peaks: " + others.joined(separator: ", ") }
        if f.lowestStrongHz > 0 { s += ". Lowest strong content \(Self.wholeHz(f.lowestStrongHz))" }
        if let c = comparison { s += comparisonAccessibilityText(c, f) }
        if hpHidden { s += ". Headphone band hidden" }
        if let hp = f.headphone {
            s += ". Headphone overlay: \(hp.modelName)"
            for flag in hp.stressFlags where showStressBands {
                guard let r = flag.frequencyRangeHz else { continue }
                s += ". \(flag.title), \(Fmt.hz(r.lowerBound)) to \(Fmt.hz(r.upperBound))" + (flag.plotLabel.isEmpty ? "" : ": \(flag.plotLabel)")
            }
        }
        return s
    }
}
