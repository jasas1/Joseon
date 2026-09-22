import AppKit
import Metal
import simd
import JoseonCore

/// Which noise-dose rule the "Level at the ear" block shows.
public enum DoseStandard: Sendable {
    /// NIOSH: 85 dB(A) for 8 h is 100 %, 3 dB exchange rate. `SPLReading.doseNIOSH`.
    case nioshDaily
    /// WHO / ITU H.870, adults: 80 dB(A) for 40 h per week is 100 %, 3 dB exchange rate. `SPLReading.doseWHOWeekly`.
    case whoWeekly
}

/// Loudness (M / S / I), true peak + RMS per channel, numeric readouts, a 60 s loudness history, band energy.
/// With `frame.spl`: the "Level at the ear" block (see `MetersRenderer+Ear.swift`). Without it the layout is unchanged.
///
/// Trust rule: a bar and the number next to it come from one value. There is no display smoothing here. The loudness
/// values are windowed measurements already, and the true peak values carry the meter ballistics of the contract.
final class MetersRenderer: PanelRenderer {
    /// Loudness target in LUFS (for example -14, -16, -23). Draws a tick on the I bar and the delta in LU. Nil = none.
    var targetLUFS: Float? { didSet { if targetLUFS != oldValue { needsDisplay = true } } }

    /// Dose rule of the "Level at the ear" block.
    var doseStandard = DoseStandard.nioshDaily { didSet { if doseStandard != oldValue { needsDisplay = true } } }
    /// The dose the app keeps (persisted, new every day / ISO week): the figure of the header ring. Nil = the running dose
    /// of the reading. See `MetersView.setDoseLedger`.
    var doseLedger: EarDoseLedger? {
        didSet {
            // The text is taken again only when a shown percent changes: the levels keep their 4 Hz latch.
            guard doseLedger != oldValue, let shown = earShown, let f = frame, let s = f.spl else { return }
            let e = EarShown(s, silent: f.isSilent, ledger: doseLedger)
            if e.doseNIOSH != shown.doseNIOSH || e.doseWHO != shown.doseWHO { earShown = e; needsDisplay = true }
        }
    }

    // MARK: A/B compare (see `MetersRenderer+Compare.swift`)

    /// The reference "A". Nil = no comparison: the layout and the tick cost are what they were.
    var comparison: ComparisonSnapshot? {
        didSet {
            guard comparison?.id != oldValue?.id || comparison?.name != oldValue?.name || comparison?.tiltDBPerOctave != oldValue?.tiltDBPerOctave else { return }
            compareShown = nil; layoutChanged(); needsDisplay = true
        }
    }
    var comparisonLevelMatch = true { didSet { if comparisonLevelMatch != oldValue { compareShown = nil; needsDisplay = true } } }
    var liveTiltDBPerOctave: Float = 0 { didSet { if liveTiltDBPerOctave != oldValue { compareShown = nil; needsDisplay = true } } }
    let compare = ComparisonCurves()
    /// Where the table stands (zero = no room for it) and what it shows, taken from the frames 4 times per second.
    var compareRect = CGRect.zero
    var comparePlan = ComparePlan()
    var compareShown: CompareShown?
    var compareLatchTime: TimeInterval = 0

    // Scales. The loudness bars and the peak bars share one scale, so their grid lines run through both groups.
    private let levelMin: Float = -60, levelMax: Float = 3
    private let bandMin: Float = -78, bandMax: Float = -6

    // Layout (points).
    private(set) var loud = CGRect.zero, read = CGRect.zero, peak = CGRect.zero, band = CGRect.zero
    private var loudBars = CGRect.zero, peakBars = CGRect.zero
    private(set) var bandBars = CGRect.zero
    private(set) var spark = CGRect.zero
    private(set) var compact = false

    // Level at the ear. `earMode` is `.none` while the frames carry no SPL reading: nothing of the block takes room then.
    enum EarMode { case none, column, strip, row }
    private(set) var earMode = EarMode.none
    /// Column (wide), strip (card with band energy) or zero (the row mode lives inside the readout column).
    var ear = CGRect.zero
    /// The level bar of the block: vertical in the column, horizontal in the strip, zero when there is none.
    var earBar = CGRect.zero
    var earPlan = EarPlan()
    private var hasSPL = false
    /// What the block's text shows: whole numbers, taken from the reading at most 4 times per second.
    private(set) var earShown: EarShown?
    private var earLatchTime: TimeInterval = 0
    static let earTextInterval: TimeInterval = 0.25
    var stripBarCache = CGRect.zero, stripBarCacheKey = CGRect.null
    private var compactSparkWidth: CGFloat = 0
    /// LRA needs a stretch of program: EBU Tech 3342 works on 3 s blocks, and a number from a few of them is noise.
    static let loudnessRangeMinimumSeconds = 30.0
    private var showBands = true
    private(set) var bigFontSize: CGFloat = 30
    private var bigRowHeight: CGFloat = 80
    private var smallRowHeight: CGFloat = 50
    private var smallTop: CGFloat = 0

    // Loudness history: M and S every 100 ms, 60 s.
    private static let historySlots = 600
    private static let historyStep = 0.1
    private let historyM: UnsafeMutablePointer<Float>
    private let historyS: UnsafeMutablePointer<Float>
    private var historyCount = 0
    private var historyHead = 0
    private var historyBank = 0.0
    private var slotMaxM: Float = MetersRenderer.noValue
    private var lastMeasuredSeconds = 0.0
    /// Marks a history slot without a measurement.
    static let noValue: Float = -1000
    static let momentaryWindow = 0.4, shortTermWindow = 3.0

    // Bar colors, rebuilt with the palette (not per frame).
    private var levelStops: [(Float, SIMD4<Float>)] = []
    private var rmsStops: [(Float, SIMD4<Float>)] = []
    private var bandStops: [[(Float, SIMD4<Float>)]] = []
    private(set) var capColor = SIMD4<Float>(1, 1, 1, 1)

    override init?(ctx: RenderContext, theme: Theme) {
        historyM = .allocate(capacity: Self.historySlots); historyM.initialize(repeating: Self.noValue, count: Self.historySlots)
        historyS = .allocate(capacity: Self.historySlots); historyS.initialize(repeating: Self.noValue, count: Self.historySlots)
        super.init(ctx: ctx, theme: theme)
        caps.reserveCapacity(24)
    }

    deinit { historyM.deallocate(); historyS.deallocate() }

    override func paletteChanged() {
        let p = palette
        let deep = mix(p.accent, p.background, t: 0.55).withAlpha(1)
        let bright = mix(p.accent, SIMD4<Float>(0.35, 0.95, 1, 1), t: 0.6)
        let lime = SIMD4<Float>(0.72, 0.95, 0.42, 1)
        capColor = bright
        levelStops = [(levelMin, deep), (-30, p.accent), (-12, bright), (-6, lime), (-2, p.warn), (0, p.danger), (levelMax, p.danger)]
        // RMS is a quiet slate: it must not compete with the true peak bar next to it.
        rmsStops = [(levelMin, mix(p.rms, p.background, t: 0.45).withAlpha(1)), (-12, p.rms), (levelMax, mix(p.rms, SIMD4(1, 1, 1, 1), t: 0.35))]
        bandStops = (0..<8).map { i in
            let hue = Palette.spectrumColor(atHz: (BandEnergy.edgesHz[i] * BandEnergy.edgesHz[i + 1]).squareRoot()).rgba(1)
            return [(bandMin, mix(hue, p.background, t: 0.72).withAlpha(1)), (bandMax, hue)]
        }
    }

    override func layoutChanged() {
        let w = size.width, h = size.height
        let pad: CGFloat = 14
        // The ear column needs 214 pt beside the readouts: with an SPL reading the wide layout starts at 820 pt.
        compact = w < (hasSPL ? 820 : 760)
        ear = .zero; earBar = .zero
        let header: CGFloat = compact ? 30 : 66
        let footer: CGFloat = 22
        let scaleW: CGFloat = compact ? 26 : 32
        if !compact {
            let aW: CGFloat = 150, cW: CGFloat = 150
            // With the ear column the readouts share what is left of the width: band energy keeps room for its names.
            let bW: CGFloat = min(max((w - aW - cW - pad * 5 - (hasSPL ? Self.earColumnWidth + pad : 0)) * 0.40, 250), 340)
            loud = CGRect(x: pad, y: pad, width: aW, height: h - pad * 2)
            // The peak bars stand next to the loudness bars: one scale, one set of grid lines.
            peak = CGRect(x: loud.maxX + 10, y: pad, width: cW - scaleW + 14, height: h - pad * 2)
            read = CGRect(x: peak.maxX + pad + 8, y: pad, width: bW, height: h - pad * 2)
            band = CGRect(x: read.maxX + pad, y: pad, width: max(w - read.maxX - pad * 2, 80), height: h - pad * 2)
            earMode = hasSPL ? .column : .none
            if hasSPL {
                // The estimate stands apart from the measurements: the last column, behind its own divider.
                let earW = min(band.width, Self.earColumnWidth)
                if band.width - earW - pad >= 220 {
                    ear = CGRect(x: band.maxX - earW, y: pad, width: earW, height: h - pad * 2)
                    band.size.width -= earW + pad
                } else {
                    ear = CGRect(x: band.minX, y: pad, width: earW, height: h - pad * 2)
                    band.size.width = 0
                }
                earBar = CGRect(x: ear.minX + scaleW, y: ear.minY + header, width: 12, height: ear.height - header - footer)
            }
            showBands = band.width >= 220
            loudBars = CGRect(x: loud.minX + scaleW, y: loud.minY + header, width: loud.width - scaleW, height: loud.height - header - footer)
            peakBars = CGRect(x: peak.minX + 14, y: peak.minY + header, width: peak.width - 14, height: peak.height - header - footer)
        } else {
            showBands = h >= 250
            earMode = hasSPL ? (showBands ? .strip : .row) : .none
            // The strip stands between the two rows of the card, 8 pt from each.
            let stripH: CGFloat = earMode == .strip ? Self.earStripHeight : 0
            let topH = showBands ? (h - pad * 3 - (stripH > 0 ? stripH + 16 - pad : 0)) * 0.58 : h - pad * 2
            let aW: CGFloat = min(124, w * 0.26), cW: CGFloat = min(124, w * 0.26)
            loud = CGRect(x: pad, y: pad, width: aW, height: topH)
            peak = CGRect(x: w - pad - cW, y: pad, width: cW, height: topH)
            read = CGRect(x: loud.maxX + pad, y: pad, width: max(peak.minX - loud.maxX - pad * 2, 60), height: topH)
            if stripH > 0 { ear = CGRect(x: pad, y: loud.maxY + 8, width: w - pad * 2, height: stripH) }
            let bandTop = stripH > 0 ? ear.maxY + 8 : loud.maxY + pad
            band = CGRect(x: pad, y: bandTop, width: w - pad * 2, height: max(h - bandTop - pad, 10))
            // The loudness history shares the lower row with the band energy (42 % of it) from 400 pt of width: no card
            // size leaves a dead zone, and the Metering and Essential cards show where the loudness came from.
            compactSparkWidth = showBands && w >= 400 ? ((w - pad * 2) * (w >= 520 ? 0.38 : 0.42)).rounded() : 0
            if compactSparkWidth > 0 { band.size.width -= compactSparkWidth + 10 }
            loudBars = CGRect(x: loud.minX + scaleW, y: loud.minY + header, width: loud.width - scaleW, height: loud.height - header - footer)
            peakBars = CGRect(x: peak.minX + scaleW, y: peak.minY + header, width: peak.width - scaleW, height: peak.height - header - footer)
        }
        let bandHeader: CGFloat = compact ? 32 : header
        bandBars = CGRect(x: band.minX + scaleW, y: band.minY + bandHeader, width: band.width - scaleW, height: band.height - bandHeader - footer)

        // Readout column: three big numbers, a 2 x 2 grid, and the loudness history in what is left.
        spark = .zero
        if !compact {
            let r = read
            bigFontSize = r.height > 520 ? 36 : (r.height > 440 ? 28 : 22)
            // Small numerals stand closer together: the loudness history under them keeps a useful height.
            bigRowHeight = bigFontSize * 0.74 + (bigFontSize < 28 ? 36 : 46)
            smallRowHeight = 50
            smallTop = r.minY + bigRowHeight * 3 + 6
            var sparkTop = smallTop + smallRowHeight * 2 + 12
            compareRect = .zero
            if comparison != nil {
                // The table stands where the history stood. A column that is high enough keeps the history under it.
                let area = CGRect(x: r.minX + 6, y: sparkTop, width: r.width - 16, height: r.maxY - sparkTop)
                comparePlan = ComparePlan.make(height: area.height, wide: true, rowsWanted: compareRowsWanted)
                if comparePlan.rows > 0 {
                    compareRect = CGRect(x: area.minX, y: area.minY, width: area.width, height: comparePlan.height)
                    sparkTop += comparePlan.height + 14
                }
            }
            if r.maxY - sparkTop >= 64, compareRect == .zero || r.maxY - sparkTop >= 100 {
                spark = CGRect(x: r.minX + 6, y: sparkTop + 18, width: r.width - 16 - 30, height: r.maxY - sparkTop - 18 - 18)
            }
        } else if compactSparkWidth > 0 {
            // Beside the band bars, on their rows: caption over it, time labels on the row of the band names.
            let x = band.maxX + 18
            compareRect = .zero
            if comparison != nil {
                let area = CGRect(x: x - 4, y: band.minY, width: size.width - pad - x + 4, height: band.height)
                comparePlan = ComparePlan.make(height: area.height, wide: false, rowsWanted: compareRowsWanted)
                if comparePlan.rows > 0 { compareRect = area }
            }
            if compareRect == .zero { spark = CGRect(x: x, y: bandBars.minY - 8, width: size.width - pad - x - 24, height: bandBars.height + 8) }
        } else {
            compareRect = .zero
        }
        earPlan = earMode == .column ? planEarColumn() : EarPlan()
        stripBarCacheKey = .null
    }

    override var staticSignature: Int {
        var h = Hasher()
        h.combine(super.staticSignature); h.combine(hasSPL); h.combine(doseStandard)
        h.combine(compareRect.width > 0); h.combine(spark.width > 0)
        return h.finalize()
    }

    override var dynamicSignature: Int {
        guard let f = frame else { return 0 }
        let l = f.loudness
        var h = Hasher()
        for v in [l.momentaryLUFS, l.shortTermLUFS, l.integratedLUFS, l.loudnessRangeLU, l.truePeakMaxDBTP, l.plrDB, l.psrDB,
                  l.truePeakLeftDBTP, l.truePeakRightDBTP, l.rmsLeftDB, l.rmsRightDB] { h.combine(Int((v * 10).rounded())) }
        for v in f.bands.values { h.combine(Int(v.rounded())) }
        h.combine(l.clipCount); h.combine(l.isIntegratedValid); h.combine(targetLUFS)
        h.combine(l.measuredSeconds < Self.loudnessRangeMinimumSeconds)
        h.combine(Int(sparkRange.top))
        if let e = earShown { h.combine(e); h.combine(doseStandard) }
        if comparison != nil {
            ensureCompareShown()
            if let c = compareShown { h.combine(c) }
        }
        return h.finalize()
    }

    // MARK: State

    override func update(frame f: AnalysisFrame, dt: TimeInterval) {
        if (f.spl != nil) != hasSPL { hasSPL = f.spl != nil; layoutChanged(); needsDisplay = true }
        if let s = f.spl {
            // The numbers of the block are taken 4 times per second: an estimate with 2 dB of uncertainty does not need more,
            // and the text is repainted only when one of the whole numbers changed. The bar shows the live value.
            if earShown == nil || f.hostTime - earLatchTime >= Self.earTextInterval || f.hostTime < earLatchTime {
                earShown = EarShown(s, silent: f.isSilent, ledger: doseLedger)
                earLatchTime = f.hostTime
            }
        } else if earShown != nil {
            earShown = nil
        }
        if let c = comparison {
            if compareShown == nil || f.hostTime - compareLatchTime >= Self.earTextInterval || f.hostTime < compareLatchTime {
                compareShown = makeCompareShown(c, f)
                compareLatchTime = f.hostTime
            }
        } else if compareShown != nil {
            compareShown = nil; compare.clear()
        }
        // Loudness history, one slot per 100 ms: the loudest momentary value of the slot, the short-term value at its end.
        // M is a 400 ms window and S a 3 s window: before the window has filled once the value is not a measurement yet
        // (it climbs from silence, which drew a spike at the start of the plot). Those slots stay empty.
        let measured = f.loudness.measuredSeconds
        if measured < lastMeasuredSeconds - 0.05 { slotMaxM = Self.noValue }       // the measurement was reset
        lastMeasuredSeconds = measured
        if measured >= Self.momentaryWindow { slotMaxM = max(slotMaxM, f.loudness.momentaryLUFS) }
        historyBank += dt
        var guardCount = 0
        while historyBank >= Self.historyStep, guardCount < 20 {
            historyBank -= Self.historyStep
            guardCount += 1
            historyM[historyHead] = slotMaxM
            historyS[historyHead] = measured >= Self.shortTermWindow ? f.loudness.shortTermLUFS : Self.noValue
            historyHead = (historyHead + 1) % Self.historySlots
            historyCount = min(historyCount + 1, Self.historySlots)
            slotMaxM = Self.noValue
        }
        if historyBank > 2 { historyBank = 0 }
    }

    /// dB window of the history plot: 30 LU under a top that follows the loudest value, on a 6 LU grid.
    private var sparkRange: (top: Float, bottom: Float) {
        var m: Float = -120
        for i in 0..<Self.historySlots { m = max(m, max(historyM[i], historyS[i])) }
        if let t = targetLUFS { m = max(m, t) }
        let top = m < -100 ? Float(-6) : min(((m + 1) / 6).rounded(.up) * 6, 0)
        return (top, top - 30)
    }

    // MARK: Geometry helpers

    func yFor(_ v: Float, _ lo: Float, _ hi: Float, in r: CGRect) -> Float {
        let t = min(max((v - lo) / (hi - lo), 0), 1)
        return Float(r.maxY) - t * Float(r.height)
    }

    /// A vertical bar whose color depends on height: `stops` are (value, color) pairs, low to high.
    func zonedBar(x: Float, width: Float, rect r: CGRect, value: Float, lo: Float, hi: Float, stops: [(Float, SIMD4<Float>)]) {
        guard value > lo, stops.count >= 2 else { return }
        let v = min(value, hi)
        func color(at s: Float) -> SIMD4<Float> {
            if s <= stops[0].0 { return stops[0].1 }
            for i in 1..<stops.count where s <= stops[i].0 {
                let t = (s - stops[i - 1].0) / max(stops[i].0 - stops[i - 1].0, 1e-6)
                return mix(stops[i - 1].1, stops[i].1, t: t)
            }
            return stops[stops.count - 1].1
        }
        var from = lo
        func segment(to e: Float) {
            let yTop = yFor(e, lo, hi, in: r), yBot = yFor(from, lo, hi, in: r)
            if yBot - yTop > 0.01 {
                batch.rect(x, yTop, width, yBot - yTop, top: color(at: e), bottom: color(at: from), radius: 0)
            }
            from = e
        }
        for s in stops where s.0 > lo && s.0 < v { segment(to: s.0) }
        segment(to: v)
    }

    func track(x: Float, width: Float, rect r: CGRect) {
        batch.rect(x, Float(r.minY), width, Float(r.height), top: palette.track, bottom: palette.track.scaledAlpha(0.75), radius: 2)
    }

    struct Cap { var x: Float; var y: Float; var w: Float; var color: SIMD4<Float> }
    var caps: [Cap] = []

    private var loudGap: CGFloat { compact ? 6 : 8 }
    private func loudBar(_ i: Int) -> (x: CGFloat, w: CGFloat) {
        let bw = (loudBars.width - loudGap * 2) / 3
        return (loudBars.minX + CGFloat(i) * (bw + loudGap), bw)
    }
    private var channelGap: CGFloat { compact ? 8 : 12 }
    /// True peak bar and RMS bar of one channel.
    private func channelBars(_ ch: Int) -> (x: CGFloat, tpW: CGFloat, rmsX: CGFloat, rmsW: CGFloat, width: CGFloat) {
        let chW = (peakBars.width - channelGap) / 2
        let rmsW = max(chW * 0.34, 6)
        let tpW = chW - rmsW - 3
        let x = peakBars.minX + CGFloat(ch) * (chW + channelGap)
        return (x, tpW, x + tpW + 3, rmsW, chW)
    }

    // MARK: Metal

    override func draw(_ enc: MTLRenderCommandEncoder, globals g: inout Globals) {
        guard let f = frame else { return }
        let p = palette
        let l = f.loudness
        caps.removeAll(keepingCapacity: true)

        let lb = loudBars, pb = peakBars

        // ---- Loudness M / S / I. Bar = the number in the readout column.
        let integrated: Float = l.isIntegratedValid ? l.integratedLUFS : -120
        for i in 0..<3 {
            let v = i == 0 ? l.momentaryLUFS : (i == 1 ? l.shortTermLUFS : integrated)
            let bar = loudBar(i)
            let x = Float(bar.x), bw = Float(bar.w)
            track(x: x, width: bw, rect: lb)
            zonedBar(x: x, width: bw, rect: lb, value: v, lo: levelMin, hi: levelMax, stops: levelStops)
            if v > levelMin { caps.append(Cap(x: x, y: yFor(v, levelMin, levelMax, in: lb), w: bw, color: capColor)) }
        }
        // Max hold ticks for M and S.
        for i in 0..<2 {
            let m = i == 0 ? l.momentaryMaxLUFS : l.shortTermMaxLUFS
            guard m > levelMin else { continue }
            let bar = loudBar(i)
            batch.hline(Float(bar.x), Float(bar.x + bar.w), yFor(m, levelMin, levelMax, in: lb), color: p.text.withAlpha(0.8), pixels: 2)
        }
        // Loudness target on the I bar.
        if let t = targetLUFS, t > levelMin, t < levelMax {
            let bar = loudBar(2)
            let y = yFor(t, levelMin, levelMax, in: lb)
            batch.hline(Float(bar.x) - 3, Float(bar.x + bar.w) + 3, y, color: p.good, pixels: 2)
            if !compact { batch.rect(Float(bar.x + bar.w) + 2, y - 3, 6, 6, color: p.good, radius: 3) }
        }

        // ---- True peak + RMS per channel. Bar = the number over it.
        let zeroY = yFor(0, levelMin, levelMax, in: pb)
        for ch in 0..<2 {
            let c = channelBars(ch)
            let x = Float(c.x)
            track(x: x, width: Float(c.tpW), rect: pb)
            track(x: Float(c.rmsX), width: Float(c.rmsW), rect: pb)
            // Red zone over 0 dBTP.
            batch.rect(x, Float(pb.minY), Float(c.tpW), zeroY - Float(pb.minY), color: p.danger.withAlpha(0.26), radius: 2)
            let tp = ch == 0 ? l.truePeakLeftDBTP : l.truePeakRightDBTP
            let rms = ch == 0 ? l.rmsLeftDB : l.rmsRightDB
            zonedBar(x: x, width: Float(c.tpW), rect: pb, value: tp, lo: levelMin, hi: levelMax, stops: levelStops)
            zonedBar(x: Float(c.rmsX), width: Float(c.rmsW), rect: pb, value: rms, lo: levelMin, hi: levelMax, stops: rmsStops)
            if tp > levelMin { caps.append(Cap(x: x, y: yFor(tp, levelMin, levelMax, in: pb), w: Float(c.tpW), color: tp > -1 ? p.danger : capColor)) }
        }
        // ---- Shared level grid: one scale through the loudness and the peak bars, drawn over them so it reads everywhere.
        if compact {
            gridLines(from: lb.minX - 3, to: lb.maxX, rect: lb, lo: levelMin, hi: levelMax, step: 12)
            gridLines(from: pb.minX - 3, to: pb.maxX, rect: pb, lo: levelMin, hi: levelMax, step: 12)
        } else {
            gridLines(from: lb.minX - 3, to: pb.maxX, rect: lb, lo: levelMin, hi: levelMax, step: 6)
        }
        batch.hline(Float(pb.minX) - 3, Float(pb.maxX), zeroY, color: p.danger.withAlpha(0.7))
        if l.truePeakMaxDBTP > levelMin {
            let y = yFor(l.truePeakMaxDBTP, levelMin, levelMax, in: pb)
            for ch in 0..<2 {
                let c = channelBars(ch)
                batch.hline(Float(c.x), Float(c.x + c.tpW), y, color: p.text.withAlpha(0.8), pixels: 2)
            }
        }

        // ---- Band energy: its own scale, behind a divider, with its own tick labels.
        if showBands {
            let bb = bandBars
            let cw = bb.width / 8
            if let b = cursorBand {
                // The band that holds the cursor frequency: a quiet plate behind its bar, its value and its name; an accent foot.
                let up: CGFloat = compact ? 4 : 18
                let r = CGRect(x: bb.minX + CGFloat(b) * cw + 1, y: bb.minY - up, width: cw - 2, height: bb.height + up + 20)
                batch.rect(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height), color: p.accent.withAlpha(0.22), radius: 4)
                batch.rect(Float(r.minX) + 3, Float(r.maxY) - 2, Float(r.width) - 6, 2, color: p.accent, radius: 1)
            }
            gridLines(from: bb.minX - 3, to: bb.maxX, rect: bb, lo: bandMin, hi: bandMax, step: 12)
            let barW = min(cw * 0.5, 30)
            let values = f.bands
            for i in 0..<8 {
                let x = Float(bb.minX + CGFloat(i) * cw + (cw - barW) / 2)
                track(x: x, width: Float(barW), rect: bb)
                let v = Self.band(values, i)
                zonedBar(x: x, width: Float(barW), rect: bb, value: v, lo: bandMin, hi: bandMax, stops: bandStops[i])
                if v > bandMin { caps.append(Cap(x: x, y: yFor(v, bandMin, bandMax, in: bb), w: Float(barW), color: mix(bandStops[i][1].1, SIMD4(1, 1, 1, 1), t: 0.35))) }
            }
        }

        // ---- Clip indicator: a lamp, not a button. Dark ring when clean, latched red with the count after a clip.
        let lamp = clipLampCenter
        let clipped = l.clipCount > 0
        if clipped {
            batch.circle(Float(lamp.x), Float(lamp.y), 4.5, color: p.danger)
        } else {
            batch.circle(Float(lamp.x), Float(lamp.y), 4.5, color: p.track)
            batch.circle(Float(lamp.x), Float(lamp.y), 4.5, color: p.textFaint.withAlpha(0.7), stroke: 1)
        }

        // Section dividers.
        if !compact {
            for x in [read.minX - 10, band.minX - 7] where showBands || x < band.minX - 8 {
                batch.vline(Float(x), Float(loud.minY + 4), Float(loud.maxY - 4), color: p.gridMajor)
            }
        }
        if let s = f.spl, earMode != .none { drawEar(s) }
        if spark.width > 0 { drawSparkFrame() }
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)

        if spark.width > 0 { drawSparkCurves(enc, &g) }

        // Bar caps: a bright line with a soft additive halo.
        let halo: Float = compact ? 2.2 : 3.0
        for c in caps { batch.rect(c.x, c.y - 1.5, c.w, 3, color: c.color.withAlpha(0.34), radius: 1.5, glow: halo) }
        if clipped { batch.circle(Float(lamp.x), Float(lamp.y), 5, color: p.danger.withAlpha(0.55), glow: 4) }
        batch.flush(enc, pipeline: ctx.shapeAdd, globals: &g)
        for c in caps { batch.rect(c.x, c.y - 0.75, c.w, 1.5, color: mix(c.color, SIMD4(1, 1, 1, 1), t: 0.6), radius: 0.75) }
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
    }

    static func band(_ b: BandEnergy, _ i: Int) -> Float {
        switch i {
        case 0: return b.subBass
        case 1: return b.bass
        case 2: return b.lowMid
        case 3: return b.mid
        case 4: return b.upperMid
        case 5: return b.presence
        case 6: return b.brilliance
        default: return b.air
        }
    }

    // MARK: Loudness history

    private func drawSparkFrame() {
        let p = palette
        let r = spark
        batch.rect(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height), color: p.plot, radius: 3)
        let range = sparkRange
        var v = range.top
        while v >= range.bottom - 0.01 {
            batch.hline(Float(r.minX), Float(r.maxX), yFor(v, range.bottom, range.top, in: r), color: v == range.top || v == range.bottom ? p.gridMajor : p.gridMinor)
            v -= 6
        }
        for s in [15, 30, 45] as [CGFloat] {
            batch.vline(Float(r.maxX - r.width * s / 60), Float(r.minY), Float(r.maxY), color: p.gridMinor)
        }
        if let t = targetLUFS, t > range.bottom, t < range.top {
            let y = yFor(t, range.bottom, range.top, in: r)
            var x = Float(r.minX)
            while x < Float(r.maxX) - 1 {
                batch.hline(x, min(x + 5, Float(r.maxX)), y, color: p.good.withAlpha(0.9))
                x += 9
            }
        }
    }

    private func drawSparkCurves(_ enc: MTLRenderCommandEncoder, _ g: inout Globals) {
        let n = historyCount
        guard n >= 2 else { return }
        let range = sparkRange
        let start = (historyHead - n + Self.historySlots) % Self.historySlots
        let r = spark
        let sc = Float(scale)
        enc.setScissorRect(MTLScissorRect(x: Int(Float(r.minX) * sc), y: Int(Float(r.minY) * sc), width: max(Int(Float(r.width) * sc), 1), height: max(Int(Float(r.height) * sc), 1)))
        let dx = Float(r.width) / Float(Self.historySlots - 1)
        // Runs of slots that hold a measurement. Newest slot at the right edge; a short history fills only its share of the 60 s.
        func runs(_ h: UnsafeMutablePointer<Float>, _ body: ((buffer: MTLBuffer, offset: Int, count: Int), SIMD4<Float>) -> Void) {
            var i = 0
            while i < n {
                while i < n, h[(start + i) % Self.historySlots] <= Self.noValue + 1 { i += 1 }
                let first = i
                while i < n, h[(start + i) % Self.historySlots] > Self.noValue + 1 { i += 1 }
                let count = i - first
                guard count >= 2, let a = arena.allocate(Float.self, count: count) else { continue }
                for k in 0..<count {
                    a.pointer[k] = min(max((h[(start + first + k) % Self.historySlots] - range.bottom) / (range.top - range.bottom), 0), 1)
                }
                let x0 = Float(r.maxX) - Float(n - 1 - first) * dx
                body((arena.buffer, a.offset, count), SIMD4(x0, Float(r.minY) + 1, Float(count - 1) * dx, Float(r.height) - 2))
            }
        }
        var u = CurveUniforms()
        runs(historyS) { values, rect in
            u.rect = rect
            u.color = palette.accent.withAlpha(0.22); u.fillTop = 1; u.fillBottom = 0.15
            drawCurveFill(enc, values: values, uniforms: u, lut: nil, globals: &g)
        }
        runs(historyM) { values, rect in
            u.rect = rect
            u.color = palette.accent.withAlpha(0.75); u.halfWidth = 0.5
            drawCurveLine(enc, values: values, uniforms: u, additive: false, lut: nil, globals: &g)
        }
        runs(historyS) { values, rect in
            u.rect = rect
            u.color = mix(palette.accent, SIMD4(1, 1, 1, 1), t: 0.65); u.halfWidth = 0.9
            drawCurveLine(enc, values: values, uniforms: u, additive: false, lut: nil, globals: &g)
        }
        enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: max(Int(Float(size.width) * sc), 1), height: max(Int(Float(size.height) * sc), 1)))
    }

    /// History values, oldest first, `noValue` where there was no measurement yet. For tests.
    var historyForTesting: (momentary: [Float], shortTerm: [Float]) {
        let start = (historyHead - historyCount + Self.historySlots) % Self.historySlots
        let idx = (0..<historyCount).map { (start + $0) % Self.historySlots }
        return (idx.map { historyM[$0] }, idx.map { historyS[$0] })
    }

    /// One color rule for the distance to the loudness target, at every size of the panel (critic r6, D5): over the
    /// target (more than +1 LU) = amber, within ±1 LU = the neutral text color, under = the calm green-cyan of the target.
    static func targetDeltaColor(_ deltaLU: Float, _ p: Palette) -> SIMD4<Float> {
        // The rule reads the number as it is printed (one decimal): "+1.0 LU" is never amber.
        let d = (deltaLU * 10).rounded() / 10
        if d > 1 { return p.warn }
        return d >= -1 ? p.text : p.good
    }

    /// Center of the clip lamp (points, top-left origin).
    var clipLampCenter: CGPoint {
        CGPoint(x: peak.maxX - 5, y: peak.minY + (compact ? 9 : 27))
    }
    /// Click target of the clip indicator.
    var clipIndicatorRect: CGRect {
        CGRect(x: peak.maxX - 74, y: clipLampCenter.y - 10, width: 74, height: 20)
    }

    private func gridLines(from x0: CGFloat, to x1: CGFloat, rect r: CGRect, lo: Float, hi: Float, step: Float) {
        var v = (hi / step).rounded(.down) * step
        while v >= lo - 0.01 {
            let major = (v / 12).rounded() * 12 == v
            batch.hline(Float(x0), Float(x1), yFor(v, lo, hi, in: r), color: major ? palette.gridMajor : palette.gridMinor)
            v -= step
        }
    }

    // MARK: Text

    var capFont: CTFont { Fonts.ui(compact ? 10 : 11, .semibold) }

    override func drawStatic(_ o: OverlayContext) {
        let p = palette
        let cap = capFont
        let small = Fonts.mono(compact ? 10 : 11)
        let label = Fonts.ui(11, .medium)

        func scale(_ r: CGRect, lo: Float, hi: Float, step: Float) {
            var v = (hi / step).rounded(.down) * step
            var lastY: CGFloat = -100
            while v >= lo - 0.01 {
                let y = CGFloat(yFor(v, lo, hi, in: r))
                if y - lastY > 13 {
                    o.text(Fmt.number(v, digits: 0), x: r.minX - 7, y: y, font: small, color: p.textDim, h: .right, v: .middle)
                    lastY = y
                }
                v -= step
            }
        }

        o.text(compact ? "LUFS" : "LOUDNESS", x: loud.minX, y: loud.minY + 4, font: cap, color: p.textFaint, v: .top, tracking: 1.0)
        if !compact { o.text("LUFS", x: loud.minX, y: loud.minY + 20, font: small, color: p.textFaint, v: .top) }
        scale(loudBars, lo: levelMin, hi: levelMax, step: 12)
        for (i, name) in ["M", "S", "I"].enumerated() {
            let bar = loudBar(i)
            o.text(name, x: bar.x + bar.w / 2, y: loudBars.maxY + 7, font: label, color: p.text, h: .center, v: .top)
        }

        // A narrow card has room for the clip indicator and two letters.
        // The caption of the peak group is drawn with the clip indicator (`drawDynamic`): the two share one row and are
        // measured together, so they never touch.
        if compact { scale(peakBars, lo: levelMin, hi: levelMax, step: 12) }
        for (i, name) in ["L", "R"].enumerated() {
            let c = channelBars(i)
            o.text(name, x: c.x + c.width / 2, y: peakBars.maxY + 7, font: label, color: i == 0 ? p.left : p.right, h: .center, v: .top)
        }
        if !compact {
            // Row tags of the two numbers over each channel, in the color of their bar.
            let tagX = peakBars.minX - 4
            o.text("TP", x: tagX, y: peakBars.minY - 24, font: small, color: mix(capColor, SIMD4(1, 1, 1, 1), t: 0.3), h: .right, v: .middle)
            o.text("RMS", x: tagX, y: peakBars.minY - 9, font: small, color: rmsTextColor, h: .right, v: .middle)
        }

        if showBands {
            o.text(compact ? "BAND ENERGY  dB" : "BAND ENERGY", x: band.minX, y: band.minY + 4, font: cap, color: p.textFaint, v: .top, tracking: 1.0)
            if !compact { o.text("dB RMS, mid channel", x: band.minX, y: band.minY + 20, font: small, color: p.textFaint, v: .top) }
            scale(bandBars, lo: bandMin, hi: bandMax, step: compact ? 24 : 12)
            let cw = bandBars.width / 8
            let tiny = cw < 44
            let nameFont = Fonts.ui(tiny ? 10 : 11)
            let names = BandLabels.fitting(o, font: nameFont, columnWidth: cw, gap: 4, panelWidth: size.width)
            for i in 0..<8 {
                o.text(names[i], x: bandBars.minX + CGFloat(i) * cw + cw / 2, y: bandBars.maxY + 7, font: nameFont, color: p.textDim, h: .center, v: .top)
            }
        }

        if earMode != .none { drawEarStatic(o) }

        if spark.width > 0 {
            let wide = spark.width >= 190
            o.text(wide ? "LOUDNESS HISTORY" : "HISTORY", x: spark.minX, y: spark.minY - 7, font: cap, color: p.textFaint, v: .bottom, tracking: 1.0)
            for (s, t) in [(CGFloat(60), "\(Fmt.minus)60 s"), (30, "\(Fmt.minus)30 s"), (0, "now")] where wide || s != 30 {
                let x = spark.maxX - spark.width * s / 60
                o.text(t, x: x, y: spark.maxY + (compact ? 7 : 5), font: small, color: s == 0 ? p.text : p.textDim, h: s == 60 ? .left : (s == 0 ? .right : .center), v: .top)
            }
            // Legend: M thin, S bold.
            var x = spark.maxX
            x -= o.text("S", x: x, y: spark.minY - 7, font: small, color: p.textDim, h: .right, v: .bottom) + 4
            o.line(x - 14, spark.minY - 11, x, spark.minY - 11, color: mix(p.accent, SIMD4(1, 1, 1, 1), t: 0.65), width: 2)
            x -= 24
            x -= o.text("M", x: x, y: spark.minY - 7, font: small, color: p.textDim, h: .right, v: .bottom) + 4
            o.line(x - 14, spark.minY - 11, x, spark.minY - 11, color: p.accent.withAlpha(0.85), width: 1)
        }
    }

    // MARK: Linked cursor

    override var kind: PanelKind { .meters }

    /// The band-energy bar under the cursor, while the bars are shown.
    private var cursorBand: Int? {
        guard cursorLinked, showBands, let c = cursor else { return nil }
        return CursorMath.band(containing: c.frequencyHz)
    }

    override func cursorChangeShows(from old: PanelCursor?) -> Bool {
        old.flatMap { CursorMath.band(containing: $0.frequencyHz) } != cursor.flatMap { CursorMath.band(containing: $0.frequencyHz) }
    }

    override func combineCursorSignature(_ c: PanelCursor, into h: inout Hasher) { h.combine(CursorMath.band(containing: c.frequencyHz)) }

    override func cursorItems() -> [CursorReadoutItem] {
        guard let c = cursor, let f = frame, let b = CursorMath.band(containing: c.frequencyHz) else { return [] }
        return [.init(text: "\(BandEnergy.names[b]) \(CursorMath.bandRange(b))", rank: 0),
                .init(text: "\(Fmt.db(Self.band(f.bands, b))) dB", rank: 1)]
    }

    /// The caption of the highlighted band, on the row of the "BAND ENERGY" caption, right-aligned: the longest form that
    /// stands clear of what is already there.
    private func drawCursorCaption(_ o: OverlayContext) {
        guard let b = cursorBand, let f = frame else { return }
        let font = Fonts.ui(compact ? 10 : 11, .medium)
        let range = CursorMath.bandRange(b), level = "\(Fmt.db(Self.band(f.bands, b))) dB"
        let forms = ["\(BandEnergy.names[b]) \(range)   \(level)", "\(BandEnergy.names[b]) \(range)", "\(BandLabels.short[b]) \(range)", range]
        let x = bandBars.maxX, y = band.minY + 4
        for text in forms {
            let box = o.textBounds(text, x: x, y: y, font: font, h: .right, v: .top)
            guard box.minX >= band.minX, o.isFree(box, pad: 3) else { continue }
            o.text(text, x: x, y: y, font: font, color: mix(palette.accent, SIMD4(1, 1, 1, 1), t: 0.55), h: .right, v: .top)
            return
        }
    }

    private var rmsTextColor: SIMD4<Float> { mix(palette.rms, SIMD4(1, 1, 1, 1), t: 0.55) }

    override func drawDynamic(_ o: OverlayContext) {
        guard let f = frame else { return }
        let p = palette
        let l = f.loudness
        let cap = capFont
        // I, LRA and PLR are measurements only after the first gated block.
        let noProgram = !l.isIntegratedValid || Fmt.isFloor(l.integratedLUFS)
        // The loudness range of the first seconds is not a range yet: a dash until 30 s are measured.
        let noRange = l.measuredSeconds < Self.loudnessRangeMinimumSeconds

        struct Item { var label: String; var value: String; var unit: String; var color: SIMD4<Float> }
        let tpColor: SIMD4<Float> = l.truePeakMaxDBTP > 0 ? p.danger : (l.truePeakMaxDBTP > -1 ? p.warn : p.text)
        let bigItems = [
            Item(label: "MOMENTARY", value: Fmt.db(l.momentaryLUFS), unit: "LUFS", color: p.text),
            Item(label: "SHORT TERM", value: Fmt.db(l.shortTermLUFS), unit: "LUFS", color: p.text),
            Item(label: "INTEGRATED", value: noProgram ? Fmt.dash : Fmt.db(l.integratedLUFS), unit: "LUFS", color: mix(p.accent, SIMD4(1, 1, 1, 1), t: 0.45)),
        ]
        let tpFloor = Fmt.isFloor(l.truePeakMaxDBTP)
        // PSR here is the contract's number: the live true peak (the higher of the two bars) minus short-term loudness.
        // It is not "true peak max minus S": the caption says which peak it uses.
        let smallItems = [
            Item(label: "RANGE  LRA", value: noProgram || noRange ? Fmt.dash : Fmt.number(l.loudnessRangeLU), unit: "LU", color: p.text),
            Item(label: "TRUE PEAK MAX", value: Fmt.db(l.truePeakMaxDBTP, signed: true), unit: "dBTP", color: tpColor),
            Item(label: "PLR  TP MAX \(Fmt.minus) I", value: noProgram || tpFloor ? Fmt.dash : Fmt.number(l.plrDB), unit: "dB", color: p.text),
            Item(label: "PSR  LIVE TP \(Fmt.minus) S", value: Fmt.isFloor(l.shortTermLUFS) || tpFloor ? Fmt.dash : Fmt.number(l.psrDB), unit: "dB", color: p.text),
        ]

        let r = read
        // A value that is not there: a short dash under the left edge of its caption, in the dim color, the same in every
        // cell. (Right-aligned dashes in the size of each numeral stood at a different place and weight in every cell.)
        func dash(_ x: CGFloat, _ base: CGFloat) { o.text(Fmt.dash, x: x, y: base, font: Fonts.ui(compact ? 12 : 15, .regular), color: p.textDim) }
        if !compact {
            let bigFont = Fonts.ui(bigFontSize, .light)
            let unitFont = Fonts.ui(11, .regular)
            var y = r.minY + 2
            let numW = o.measure("\(Fmt.minus)00.0", font: bigFont)
            for (i, it) in bigItems.enumerated() {
                o.text(it.label, x: r.minX + 6, y: y + 2, font: cap, color: p.textFaint, v: .top, tracking: 1.0)
                let base = y + 18 + CTFontGetCapHeight(bigFont) + 6
                if it.value == Fmt.dash { dash(r.minX + 6, base) } else { o.text(it.value, x: r.minX + 6 + numW, y: base, font: bigFont, color: it.color, h: .right) }
                o.text(it.unit, x: r.minX + 6 + numW + 7, y: base, font: unitFont, color: p.textDim)
                if i == 2, let t = targetLUFS {
                    // Distance to the loudness target.
                    let x = r.minX + 6 + numW + 48
                    if CTFontGetCapHeight(bigFont) >= 24 {
                        o.text("TARGET \(Fmt.number(t, digits: 0))", x: x, y: base - CTFontGetCapHeight(bigFont) + 1, font: Fonts.mono(11), color: p.good, v: .top)
                    } else {
                        // Small numerals: no room for two lines beside them. The target goes on the caption row.
                        o.text("TARGET \(Fmt.number(t, digits: 0))", x: r.maxX - 12, y: y + 2, font: Fonts.mono(11), color: p.good, h: .right, v: .top)
                    }
                    if !noProgram {
                        let d = l.integratedLUFS - t
                        o.text("\(Fmt.number(d, digits: 1, signed: true)) LU", x: x, y: base, font: Fonts.ui(14, .medium), color: Self.targetDeltaColor(d, p))
                    }
                }
                y += bigRowHeight
            }
            // Secondary numbers: a 2 x 2 grid.
            let top = smallTop
            let colW = r.width / 2
            let medFont = Fonts.ui(19, .regular)
            let mW = o.measure("+00.0", font: medFont)
            o.line(r.minX + 6, top - 4, r.maxX - 10, top - 4, color: p.gridMajor, width: 1)
            for (i, it) in smallItems.enumerated() {
                let x = r.minX + 6 + CGFloat(i % 2) * colW
                let yy = top + CGFloat(i / 2) * smallRowHeight + 5
                o.text(it.label, x: x, y: yy, font: cap, color: p.textFaint, v: .top, tracking: 0.6)
                let base = yy + 16 + CTFontGetCapHeight(medFont) + 5
                if it.value == Fmt.dash { dash(x, base) } else { o.text(it.value, x: x + mW, y: base, font: medFont, color: it.color, h: .right) }
                o.text(it.unit, x: x + mW + 5, y: base, font: unitFont, color: p.textDim)
            }
        } else {
            // Compact: M / S / I on the left, the four secondary numbers on the right.
            let twoCols = r.width >= 150
            // Without band energy the ear estimate is a fourth row under M / S / I (and the dose a fifth small number).
            let earRow = earMode == .row
            let rowH = r.height / (earRow ? 4 : 3)
            let bigFont = Fonts.ui((earRow ? rowH >= 56 : r.height > 150) ? 19 : 15, .regular)
            let numW = o.measure("\(Fmt.minus)00.0", font: bigFont)
            for (i, it) in bigItems.enumerated() {
                let y = r.minY + CGFloat(i) * rowH
                o.text(["M", "S", "I"][i], x: r.minX, y: y + 4, font: cap, color: p.textFaint, v: .top, tracking: 1.0)
                let base = y + 18 + CTFontGetCapHeight(bigFont)
                if it.value == Fmt.dash { dash(r.minX, base) } else { o.text(it.value, x: r.minX + numW, y: base, font: bigFont, color: it.color, h: .right) }
                if i == 2, let t = targetLUFS, !noProgram, r.width >= 150 || !twoCols {
                    let d = l.integratedLUFS - t
                    o.text("\(Fmt.number(d, digits: 1, signed: true)) LU", x: r.minX + 14, y: y + 4, font: Fonts.mono(10), color: Self.targetDeltaColor(d, p), v: .top)
                }
            }
            // The two columns share the width evenly: no dead zone beside them in a wide card.
            let x = max(r.minX + numW + 18, r.minX + (r.width * 0.52).rounded())
            if earRow, let e = earShown {
                drawEarRow(o, e, x: r.minX, y: r.minY + 3 * rowH, width: twoCols ? x - r.minX - 10 : r.width, rowHeight: rowH,
                           numeralRight: r.minX + numW, font: bigFont, withDose: !twoCols)
            }
            if twoCols {
                let f2 = Fonts.ui(12, .regular)
                let rh = r.height / (earRow ? 5 : 4)
                let w2 = o.measure("+00.0", font: f2)
                for (i, it) in smallItems.enumerated() {
                    let y = r.minY + CGFloat(i) * rh
                    let short = ["LRA", "TP MAX", "PLR", "PSR live"][i]
                    o.text(short, x: x, y: y + 4, font: cap, color: p.textFaint, v: .top, tracking: 0.6)
                    if it.value == Fmt.dash { dash(x, y + 17 + CTFontGetCapHeight(f2)) } else { o.text(it.value, x: x + w2, y: y + 17 + CTFontGetCapHeight(f2), font: f2, color: it.color, h: .right) }
                }
                if earRow, earShown != nil {
                    // The dose of the ear estimate: the fifth small number.
                    let y = r.minY + 4 * rh
                    let dose = doseValue
                    o.text("DOSE", x: x, y: y + 4, font: cap, color: p.textFaint, v: .top, tracking: 0.6)
                    o.text("\(Self.approx) \(min(dose.percent, 999)) %", x: x, y: y + 17 + CTFontGetCapHeight(f2), font: f2, color: dose.percent >= 80 ? doseColor(dose.percent) : p.text)
                }
            }
        }

        if let e = earShown, earMode != .none { drawEarDynamic(o, e) }

        if spark.width > 0 {
            let range = sparkRange
            let f11 = Fonts.mono(compact ? 10 : 11)
            o.text(Fmt.number(range.top, digits: 0), x: spark.maxX + 4, y: spark.minY, font: f11, color: p.textDim, v: .top)
            o.text(Fmt.number(range.bottom, digits: 0), x: spark.maxX + 4, y: spark.maxY, font: f11, color: p.textDim, v: .bottom)
            // Inner ticks on the 12 LU lines (-24 and -36 on a -12 ... -42 window), where they keep 13 pt from the end labels.
            var v = (range.top / 12).rounded(.down) * 12
            while v > range.bottom {
                let y = CGFloat(yFor(v, range.bottom, range.top, in: spark))
                if v < range.top, y - spark.minY > 17, spark.maxY - y > 17 {
                    o.text(Fmt.number(v, digits: 0), x: spark.maxX + 4, y: y, font: f11, color: p.textFaint, v: .middle)
                }
                v -= 12
            }
        }

        // Bar-side numbers.
        let vf = Fonts.mono(compact ? 10 : 11)
        if showBands {
            let cw = bandBars.width / 8
            for (i, v) in f.bands.values.enumerated() where i < 8 {
                o.text(Fmt.db(v, digits: 0), x: bandBars.minX + CGFloat(i) * cw + cw / 2, y: bandBars.minY - 5, font: vf, color: p.textDim, h: .center, v: .bottom)
            }
        }
        if !compact {
            // Live true peak and RMS per channel, over the bars: the same values the bars show.
            for ch in 0..<2 {
                let c = channelBars(ch)
                let tp = ch == 0 ? l.truePeakLeftDBTP : l.truePeakRightDBTP
                let rms = ch == 0 ? l.rmsLeftDB : l.rmsRightDB
                o.text(Fmt.db(tp, signed: true), x: c.x + c.width / 2, y: peakBars.minY - 24, font: vf, color: p.text, h: .center, v: .middle)
                o.text(Fmt.db(rms), x: c.x + c.width / 2, y: peakBars.minY - 9, font: vf, color: rmsTextColor, h: .center, v: .middle)
            }
        }

        // Clip indicator text: count of clipped runs since the last reset.
        let lamp = clipLampCenter
        let clipped = l.clipCount > 0
        let count = clipped ? (l.clipCount > 999 ? "999+" : "\(l.clipCount)") : "0"
        let clipFont = Fonts.ui(compact ? 10 : 11, clipped ? .bold : .medium)
        let clipColor = clipped ? p.danger : p.textFaint
        if compact {
            // One row: caption left, clip indicator right. At least 10 pt between them: the caption shortens first
            // (TRUE PEAK, TP, none), then the clip text loses its COUNT. The word and the lamp stay: a bare "999+" beside a
            // red dot says nothing to a reader who has not seen the large layout (critic r6, D5).
            let left = peak.minX, right = lamp.x - 9
            let room = right - left
            var clipText = "CLIP \(count)"
            var caption = ""
            let wFull = o.measure(clipText, font: clipFont, tracking: 0.6)
            // The column is TRUE PEAK, or TP where that is too long: one name, never "PEAK" (critic r6).
            for c in ["TRUE PEAK", "TP"] where o.measure(c, font: cap, tracking: 1.0) + 10 + wFull <= room { caption = c; break }
            if caption.isEmpty, wFull > room { clipText = "CLIP" }
            if !caption.isEmpty { o.text(caption, x: left, y: lamp.y, font: cap, color: p.textFaint, v: .middle, tracking: 1.0) }
            o.text(clipText, x: right, y: lamp.y, font: clipFont, color: clipColor, h: .right, v: .middle, tracking: 0.6)
        } else {
            o.text("TRUE PEAK", x: peakBars.minX, y: peak.minY + 4, font: cap, color: p.textFaint, v: .top, tracking: 1.0)
            o.text("CLIP \(count)", x: lamp.x - 9, y: lamp.y, font: clipFont, color: clipColor, h: .right, v: .middle, tracking: 0.6)
        }
        if compareRect.width > 0, let c = comparison { drawCompareTable(o, c, f) }
        // Last: it takes the longest form that stands clear of everything above.
        drawCursorCaption(o)
    }

    override var accessibilityLabelText: String { "Loudness and level meters" }
    override var accessibilityValueText: String {
        guard let f = frame else { return "No signal" }
        let l = f.loudness
        func s(_ v: Float, _ unit: String) -> String { Fmt.isFloor(v) ? "no value" : String(format: "%.1f ", v) + unit }
        let valid = l.isIntegratedValid
        var parts = ["Momentary \(s(l.momentaryLUFS, "LUFS"))", "short term \(s(l.shortTermLUFS, "LUFS"))",
                     "integrated \(valid ? s(l.integratedLUFS, "LUFS") : "no value")",
                     "range \(valid && l.measuredSeconds >= Self.loudnessRangeMinimumSeconds ? String(format: "%.1f LU", l.loudnessRangeLU) : "no value")",
                     "true peak max \(s(l.truePeakMaxDBTP, "dBTP"))",
                     "PLR \(valid && !Fmt.isFloor(l.truePeakMaxDBTP) ? String(format: "%.1f dB", l.plrDB) : "no value")",
                     "PSR \(String(format: "%.1f", l.psrDB)) dB"]
        if let t = targetLUFS, valid { parts.append(String(format: "%+.1f LU against the %.0f LUFS target", l.integratedLUFS - t, t)) }
        if l.clipCount > 0 { parts.append("\(l.clipCount) clipped runs") }
        if let s = f.spl { parts.append(earAccessibilityText(s, silent: f.isSilent)) }
        if let c = comparison { parts.append(compareAccessibilityText(c, f)) }
        return parts.joined(separator: ", ")
    }
}
