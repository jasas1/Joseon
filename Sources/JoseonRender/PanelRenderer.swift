import AppKit
import Metal
import JoseonCore

/// Draws one panel into any BGRA8 texture. `PanelView` (on screen) and `OffscreenRenderer` (PNG)
/// both drive this class, so the two outputs come from the same drawing code.
///
/// Per frame: `ingest(frame)` updates state (history, smoothing), `encode(...)` records the Metal work,
/// `drawStatic` / `drawDynamic` paint the Core Graphics text layers.
class PanelRenderer {
    let ctx: RenderContext
    let arena: FrameArena
    let batch: ShapeBatch

    var theme: Theme { didSet { rebuildPalette() } }
    var highContrast = false { didSet { if highContrast != oldValue { rebuildPalette() } } }
    private(set) var palette: Palette
    private(set) var paletteVersion = 0

    /// Cursor position in points (top-left origin), nil when the cursor is outside.
    var hover: CGPoint? { didSet { if hover != oldValue { needsDisplay = true } } }

    // MARK: Linked cursor (see `CursorReadout.swift`)

    /// Which panel this is: a cursor whose `source` is this kind came from here.
    var kind: PanelKind { .spectrum }
    /// True when the panel shares a cursor (`PanelView.cursorLink` is set, or an offscreen render carries a cursor). False =
    /// the per-panel hover of before, unchanged: nothing below is read.
    var cursorLinked = false { didSet { if cursorLinked != oldValue { needsDisplay = true; if size.width > 1 { layoutChanged() } } } }
    /// The shared cursor, copied from the link.
    var cursor: PanelCursor? { didSet { if cursor != oldValue, cursorChangeShows(from: oldValue) { needsDisplay = true } } }
    /// The past spectrum under a timed cursor, copied from the link.
    var cursorSlice: CursorHistorySlice? { didSet { if cursorSlice != oldValue { cursorSliceChanged() } } }
    /// False when a move of the cursor changes nothing this panel draws (a band highlight whose band stays the same).
    func cursorChangeShows(from old: PanelCursor?) -> Bool { true }
    func cursorSliceChanged() {}
    /// False when this cursor changes nothing in the panel's text (the timeline shows only cursors that have a time).
    func cursorShowsInText(_ c: PanelCursor) -> Bool { true }
    /// What of the cursor this panel's text shows. Equal hashes = no text repaint.
    func combineCursorSignature(_ c: PanelCursor, into h: inout Hasher) {
        h.combine(c.frequencyHz); h.combine(c.secondsAgo); h.combine(c.isPinned); h.combine(c.source); h.combine(showsPointerReadout)
    }
    /// True when the pointer makes cursors in this panel (a plot with a frequency axis). The meters and the goniometer only show one.
    var makesPointerCursors: Bool { false }
    /// The cursor a pointer at `point` (points, top-left origin) stands for, from this panel's own axes. Nil = not over a plot
    /// with a frequency axis.
    func cursor(at point: CGPoint) -> PanelCursor? { nil }
    /// True when `point` is on the drawn cursor (a click there clears a pinned cursor).
    func isOnCursor(_ point: CGPoint) -> Bool { false }
    /// This panel's answer at the cursor, in reading order.
    func cursorItems() -> [CursorReadoutItem] { [] }
    /// The readout as one plain sentence (VoiceOver value and announcements). Empty without a cursor.
    var cursorAccessibilityText: String {
        guard cursorLinked, let c = cursor else { return "" }
        let items = cursorItems()
        guard !items.isEmpty else { return "" }
        return (c.isPinned ? "Pinned cursor: " : "Cursor: ") + items.map(\.text).joined(separator: ", ")
    }
    /// The readout follows the pointer: a hover cursor that this panel made, with the pointer still over it.
    var showsPointerReadout: Bool {
        guard cursorLinked, let hv = hover, let c = cursor, !c.isPinned, c.source == kind else { return false }
        // A keyboard move leaves the pointer where it was: the cursor is no longer under it.
        return self.cursor(at: hv) == c
    }
    /// The readout stands in the header row: every other panel, and the source panel of a pinned or keyboard cursor.
    var showsHeaderReadout: Bool { cursorLinked && cursor != nil && !showsPointerReadout }

    /// Set when something other than a new analysis frame changed the picture (layout, theme, options, cursor).
    /// The owner clears it after a draw.
    var needsDisplay = true
    /// False when the newest frame carries the same picture as the one before it (a paused or silent source).
    private(set) var frameChanged = true
    private var lastFrameDigest = 0
    /// True while the panel moves without new frames (fading light). The owner keeps drawing.
    var isAnimating: Bool { false }
    /// False for a panel whose picture does not come from analysis frames (the session timeline reads snapshots): the view
    /// then does not pull or ingest frames on its display ticks.
    var usesAnalysisFrames: Bool { true }
    /// True when the cursor readout carries numbers of the newest frame and so follows every frame (at the 10 Hz of the text).
    var cursorReadoutFollowsFrames: Bool { true }

    /// Text as a GPU texture, drawn at the end of the main pass.
    let textLayer: TextLayer
    private var lastStaticSignature = 0
    private var staticItems: [OverlayItem] = []
    private var staticLabels: [(text: String, rect: CGRect)] = []
    private var staticItemsSignature = 0
    private var lastDynamicSignature = 0
    private var lastHoverSignature = 0
    private var lastTextTime: CFTimeInterval = -1
    private var lastHoverTime: CFTimeInterval = -1
    /// Readouts repaint at most this often.
    static let textInterval: CFTimeInterval = 0.1

    private(set) var frame: AnalysisFrame?
    private(set) var size = CGSize(width: 1, height: 1)
    private(set) var scale: CGFloat = 2
    private(set) var lastHostTime: TimeInterval = 0
    private(set) var frameDelta: TimeInterval = 1.0 / 60.0
    private(set) var ingestCount = 0

    /// GPU seconds of the last completed command buffer (set by the owner).
    var lastGPUTime: Double = 0

    init?(ctx: RenderContext, theme: Theme) {
        guard let arena = FrameArena(device: ctx.device) else { return nil }
        self.ctx = ctx
        self.arena = arena
        self.batch = ShapeBatch(arena: arena)
        self.textLayer = TextLayer(device: ctx.device)
        self.theme = theme
        self.palette = Palette(theme: theme, highContrast: false)
        paletteChanged()
    }

    static func make(kind: PanelKind, ctx: RenderContext, theme: Theme) -> PanelRenderer? {
        switch kind {
        case .spectrum: return SpectrumRenderer(ctx: ctx, theme: theme)
        case .spectrogram: return SpectrogramRenderer(ctx: ctx, theme: theme)
        case .vectorscope: return VectorscopeRenderer(ctx: ctx, theme: theme)
        case .meters: return MetersRenderer(ctx: ctx, theme: theme)
        case .timeline: return TimelineRenderer(ctx: ctx, theme: theme)
        }
    }

    private func rebuildPalette() {
        palette = Palette(theme: theme, highContrast: highContrast)
        paletteVersion &+= 1
        needsDisplay = true
        paletteChanged()
    }

    // MARK: Subclass hooks

    /// Rebuild lookup textures.
    func paletteChanged() {}
    /// Size or scale changed.
    func layoutChanged() {}
    /// A new analysis frame arrived. `dt` is the host time since the frame before it.
    func update(frame: AnalysisFrame, dt: TimeInterval) {}
    /// Passes that run before the main pass (history and accumulation textures).
    func encodePrePass(_ cb: MTLCommandBuffer) {}
    /// Draw into the main pass.
    func draw(_ enc: MTLRenderCommandEncoder, globals: inout Globals) {}
    /// Labels that change only with size, theme or options.
    func drawStatic(_ o: OverlayContext) {}
    /// The box at the pointer stays over this y (points, top-left origin): what stands under it (a time axis) is never covered. Nil = the panel's height.
    var hoverLabelFloor: CGFloat? { nil }
    /// Readouts. Redrawn at most 10 times per second, and only when `dynamicSignature` changes.
    func drawDynamic(_ o: OverlayContext) {}
    /// Small label that follows the cursor. Return nil for none. Origin = top-left of the label, points.
    func hoverLabel() -> (lines: [String], anchor: CGPoint)? { nil }
    var staticSignature: Int {
        var h = Hasher()
        h.combine(Int(size.width * 4)); h.combine(Int(size.height * 4)); h.combine(paletteVersion)
        if cursorLinked { h.combine(true) }
        return h.finalize()
    }
    var dynamicSignature: Int { ingestCount }
    var accessibilityLabelText: String { "" }
    var accessibilityValueText: String { "" }

    // MARK: Driving

    func ingest(_ f: AnalysisFrame) {
        var dt = frame == nil ? 1.0 / 60.0 : f.hostTime - lastHostTime
        if !(dt > 0) || dt > 0.5 { dt = 1.0 / 60.0 }
        frameDelta = dt
        lastHostTime = f.hostTime
        frame = f
        ingestCount &+= 1
        let digest = Self.digest(f)
        frameChanged = digest != lastFrameDigest || ingestCount <= 2
        lastFrameDigest = digest
        update(frame: f, dt: dt)
    }

    /// Cheap fingerprint of what a panel can show: sparse samples, no allocation. Equal digests = same picture.
    private static func digest(_ f: AnalysisFrame) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        @inline(__always) func add(_ v: Float) { h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3 }
        let s = f.spectrum
        let n = min(s.mid.count, s.peakHold.count, s.left.count, s.right.count, s.average.count)
        var i = 0
        while i < n {
            add(s.mid[i]); add(s.peakHold[i]); add(s.left[i]); add(s.right[i]); add(s.average[i])
            i += 17
        }
        let l = f.loudness
        add(l.momentaryLUFS); add(l.shortTermLUFS); add(l.integratedLUFS); add(l.truePeakLeftDBTP)
        add(l.truePeakRightDBTP); add(l.rmsLeftDB); add(l.rmsRightDB); add(Float(l.clipCount)); add(l.loudnessRangeLU)
        add(f.bands.bass); add(f.bands.mid); add(f.bands.air)
        let pts = f.stereo.scopePoints
        add(Float(pts.count))
        if let a = pts.first, let b = pts.last { add(a.x); add(a.y); add(b.x); add(b.y) }
        add(f.stereo.correlation)
        add(Float(f.headphone?.stressFlags.count ?? -1)); add(Float(f.headphone?.modelName.utf8.count ?? -1))
        add(f.peak.frequencyHz)
        // Level at the ear: only when a calibration is set (nil costs one test).
        if let e = f.spl {
            add(e.levelAFast); add(e.levelASlow); add(e.maxAFast); add(e.doseNIOSH); add(e.doseWHOWeekly); add(Float(e.calibrationName.utf8.count))
            if let a = e.bandLevelsEardrum.first, let b = e.bandLevelsEardrum.last { add(a); add(b); add(e.bandLevelsEardrum[e.bandLevelsEardrum.count / 2]) }
        }
        return Int(truncatingIfNeeded: h)
    }

    /// Repaints the text texture when a signature changed. Readouts: at most 10 Hz. Cursor label: at most 30 Hz.
    /// `force` ignores the rate limits (offscreen snapshots). Returns true when the texture changed.
    @discardableResult
    func refreshText(now: CFTimeInterval, force: Bool = false) -> Bool {
        textLayer.resize(size: size, scale: scale)
        let s = staticSignature
        var dirty = s != lastStaticSignature || force
        // With a cursor the readout carries numbers of the newest frame: they follow every frame, at the 10 Hz of the text.
        let hasCursor = cursorLinked && (cursor.map(cursorShowsInText) ?? false)
        let dynamic = hasCursor && cursorReadoutFollowsFrames ? dynamicSignature ^ (ingestCount &* 0x9E3779B1) : dynamicSignature
        if force || now - lastTextTime >= Self.textInterval || now < lastTextTime {
            if dynamic != lastDynamicSignature { dirty = true }
        }
        let label = hoverLabel()
        var hs = 0
        if label != nil || hasCursor {
            var h = Hasher()
            if let label { h.combine(label.lines); h.combine(Int(label.anchor.x * 2)); h.combine(Int(label.anchor.y * 2)) }
            // A moved cursor repaints the readout of every linked panel, at most 30 times per second (the rate of the label).
            if let c = cursor, cursorLinked { combineCursorSignature(c, into: &h) }
            hs = h.finalize()
        }
        if hs != lastHoverSignature, force || now - lastHoverTime >= 1.0 / 30.0 || now < lastHoverTime { dirty = true }
        guard dirty else { return false }
        lastStaticSignature = s
        lastDynamicSignature = dynamic
        lastHoverSignature = hs
        lastTextTime = now
        lastHoverTime = now
        // The static labels are recorded once per layout / theme and reused: their layout code does not run at 10 Hz.
        if staticItemsSignature != s || force || staticItems.isEmpty {
            let so = OverlayContext(size: size, pixelScale: scale)
            drawStatic(so)
            staticItems = so.items; staticLabels = so.labels; staticItemsSignature = s
        }
        let o = OverlayContext(size: size, pixelScale: scale)
        o.preload(items: staticItems, labels: staticLabels)
        drawDynamic(o)
        if let label { HoverLabel.draw(o, lines: label.lines, anchor: label.anchor, palette: palette, floor: hoverLabelFloor) }
        textLayer.redraw(o)
        return true
    }

    func setLayout(size newSize: CGSize, scale newScale: CGFloat) {
        let s = CGSize(width: max(newSize.width, 1), height: max(newSize.height, 1))
        if s != size || newScale != scale {
            size = s
            scale = newScale
            needsDisplay = true
            layoutChanged()
        }
    }

    /// True when the panel keeps GPU history that needs one pre-pass per analysis frame.
    var needsPrePassPerFrame: Bool { false }
    /// Display tick without a new analysis frame (persistence still fades).
    func idle(dt: TimeInterval) {}

    /// Records every pass for this panel. The caller commits the command buffer.
    /// With `target` nil only the history pre-pass runs (offscreen rendering feeds many frames, draws once).
    func encode(commandBuffer cb: MTLCommandBuffer, target: MTLTexture?) {
        arena.beginFrame()
        batch.beginFrame(scale: Float(scale))
        encodePrePass(cb)
        guard let target else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = palette.background
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Joseon panel"
        var g = Globals(viewSize: SIMD2(Float(size.width), Float(size.height)), scale: Float(scale), time: Float(lastHostTime.truncatingRemainder(dividingBy: 3600)))
        draw(enc, globals: &g)
        let sc = Float(scale)
        enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: max(Int(Float(size.width) * sc), 1), height: max(Int(Float(size.height) * sc), 1)))
        textLayer.draw(enc, ctx: ctx, arena: arena, globals: &g)
        enc.endEncoding()
    }

    // MARK: Shared drawing helpers

    func drawCurveLine(_ enc: MTLRenderCommandEncoder, values: (buffer: MTLBuffer, offset: Int, count: Int), uniforms: CurveUniforms,
                       additive: Bool, lut: MTLTexture?, globals: inout Globals) {
        guard values.count >= 2 else { return }
        var u = uniforms
        u.count = Float(values.count)
        // How many segments a pixel must test: the reach of the line and its glow, in point spacings.
        let spacing = max(u.rect.z / Float(max(values.count - 1, 1)), 0.05)
        let reach = u.halfWidth + u.soft * 3 + 1.5 / Float(scale)
        u.pad0 = min((reach / spacing).rounded(.up) + 1, 48)
        enc.setRenderPipelineState(additive ? ctx.curveLineAdd : ctx.curveLineOver)
        enc.setVertexBuffer(values.buffer, offset: values.offset, index: 0)
        enc.setFragmentBuffer(values.buffer, offset: values.offset, index: 0)
        enc.setVertexBytes(&globals, length: MemoryLayout<Globals>.stride, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<CurveUniforms>.stride, index: 2)
        enc.setFragmentBytes(&globals, length: MemoryLayout<Globals>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<CurveUniforms>.stride, index: 2)
        enc.setFragmentTexture(lut ?? ctx.whiteLUT, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: values.count * 2)
    }

    /// The area under a curve: one strip, one gradient. `referenceLeft` / `referenceRight`: the plot height (0...1) where the
    /// fill reaches `fillTop`, as a straight line from the left end to the right end. The shading never reads the curve.
    func drawCurveFill(_ enc: MTLRenderCommandEncoder, values: (buffer: MTLBuffer, offset: Int, count: Int), referenceLeft: Float = 1,
                       referenceRight: Float = 1, uniforms: CurveUniforms, lut: MTLTexture?, globals: inout Globals) {
        guard values.count >= 2 else { return }
        var u = uniforms
        u.count = Float(values.count)
        u.pad0 = referenceLeft; u.pad2 = referenceRight
        enc.setRenderPipelineState(ctx.curveFill)
        enc.setVertexBuffer(values.buffer, offset: values.offset, index: 0)
        enc.setVertexBytes(&globals, length: MemoryLayout<Globals>.stride, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<CurveUniforms>.stride, index: 2)
        enc.setFragmentBytes(&globals, length: MemoryLayout<Globals>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<CurveUniforms>.stride, index: 2)
        enc.setFragmentTexture(lut ?? ctx.whiteLUT, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: values.count * 2)
    }
}

// MARK: - Log frequency axis

struct LogAxis {
    var minHz: Float
    var maxHz: Float
    @inline(__always) func position(_ hz: Float) -> Float { log(max(hz, 1e-3) / minHz) / log(maxHz / minHz) }
    @inline(__always) func frequency(_ t: Float) -> Float { minHz * pow(maxHz / minHz, t) }

    static let labeled: [Float] = [20, 30, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]
    static let minor: [Float] = [10, 40, 60, 70, 80, 90, 300, 400, 600, 700, 800, 900, 3000, 4000, 6000, 7000, 8000, 9000]
}

/// The fixed part of a resampling job: for every output point the four source bins and their Catmull-Rom weights, or the
/// range of bins to take the maximum of. Bins, axis and point count stay the same from frame to frame, so the table is
/// built once and a frame costs four multiply-adds per point. Same results as `CurveResampler.resample`.
final class ResampleTable {
    let count: Int
    let sourceCount: Int
    private let key: (Float, Float, Float, Float)
    private let index: UnsafeMutablePointer<Int32>     // 4 per point: p0 p1 p2 p3, or lo hi - - in max mode; -1 = outside
    private let weight: UnsafeMutablePointer<Float>    // 4 per point
    private let maxMode: Bool

    func matches(frequencies: [Float], axis: LogAxis, count c: Int) -> Bool {
        let n = frequencies.count
        return c == count && n == sourceCount && n >= 2 && key == (frequencies[0], frequencies[n - 1], axis.minHz, axis.maxHz)
    }

    init?(frequencies: [Float], axis: LogAxis, count: Int) {
        let n = frequencies.count
        guard n >= 2, count >= 2, frequencies[0] > 0, frequencies[n - 1] > frequencies[0] else { return nil }
        self.count = count
        sourceCount = n
        key = (frequencies[0], frequencies[n - 1], axis.minHz, axis.maxHz)
        index = .allocate(capacity: count * 4)
        weight = .allocate(capacity: count * 4)
        let lnF0 = log(frequencies[0]), lnSpan = log(frequencies[n - 1]) - lnF0
        let lnA = log(axis.minHz), lnASpan = log(axis.maxHz) - lnA
        let binsPerPoint = (lnASpan / Float(count - 1)) / (lnSpan / Float(n - 1))
        maxMode = binsPerPoint > 1.25
        for j in 0..<count {
            let lnF = lnA + lnASpan * Float(j) / Float(count - 1)
            let idx = (lnF - lnF0) / lnSpan * Float(n - 1)
            let o = j * 4
            if idx < -0.5 || idx > Float(n) - 0.5 {
                for k in 0..<4 { index[o + k] = -1; weight[o + k] = 0 }
            } else if maxMode {
                var lo = max(Int((idx - binsPerPoint * 0.5).rounded(.up)), 0)
                var hi = min(Int((idx + binsPerPoint * 0.5).rounded(.down)), n - 1)
                if lo > hi { lo = min(max(Int(idx.rounded()), 0), n - 1); hi = lo }
                index[o] = Int32(lo); index[o + 1] = Int32(hi); index[o + 2] = 0; index[o + 3] = 0
                for k in 0..<4 { weight[o + k] = 0 }
            } else {
                let c = min(max(idx, 0), Float(n - 1))
                let i1 = min(Int(c), n - 2)
                let t = c - Float(i1)
                index[o] = Int32(max(i1 - 1, 0)); index[o + 1] = Int32(i1); index[o + 2] = Int32(i1 + 1); index[o + 3] = Int32(min(i1 + 2, n - 1))
                let t2 = t * t, t3 = t2 * t
                weight[o] = 0.5 * (-t + 2 * t2 - t3)
                weight[o + 1] = 0.5 * (2 - 5 * t2 + 3 * t3)
                weight[o + 2] = 0.5 * (t + 4 * t2 - 3 * t3)
                weight[o + 3] = 0.5 * (-t2 + t3)
            }
        }
    }

    deinit { index.deallocate(); weight.deallocate() }

    /// Writes `count` values, 0 (minDB) ... 1 (maxDB).
    func apply(_ src: [Float], minDB: Float, maxDB: Float, offsetDB: Float = 0, into out: UnsafeMutablePointer<Float>) {
        guard src.count >= sourceCount else { for j in 0..<count { out[j] = 0 }; return }
        let scale = 1 / (maxDB - minDB)
        let bias = offsetDB - minDB
        src.withUnsafeBufferPointer { s in
            if maxMode {
                for j in 0..<count {
                    let lo = Int(index[j * 4]), hi = Int(index[j * 4 + 1])
                    if lo < 0 { out[j] = 0; continue }
                    var db = s[lo]
                    if hi > lo { for k in (lo + 1)...hi { db = max(db, s[k]) } }
                    out[j] = min(max((db + bias) * scale, 0), 1)
                }
            } else {
                for j in 0..<count {
                    let o = j * 4
                    let i0 = Int(index[o])
                    if i0 < 0 { out[j] = 0; continue }
                    let p1 = s[Int(index[o + 1])], p2 = s[Int(index[o + 2])]
                    var db = weight[o] * s[i0] + weight[o + 1] * p1 + weight[o + 2] * p2 + weight[o + 3] * s[Int(index[o + 3])]
                    // No overshoot past the local range: keeps peaks honest.
                    db = min(max(db, min(p1, p2) - 0.5), max(p1, p2) + 0.5)
                    out[j] = min(max((db + bias) * scale, 0), 1)
                }
            }
        }
    }
}

/// Resamples a log-spaced spectrum onto `count` points that are uniform on a log axis.
/// More points than bins: Catmull-Rom (smooth, never stair-stepped). Fewer: max of the covered bins (peaks survive).
enum CurveResampler {
    static func resample(_ src: [Float], frequencies: [Float], axis: LogAxis, minDB: Float, maxDB: Float,
                         offsetDB: Float = 0, into out: UnsafeMutablePointer<Float>, count: Int) {
        let n = min(src.count, frequencies.count)
        guard n >= 2, count >= 2, let f0 = frequencies.first, frequencies[n - 1] > f0, f0 > 0 else {
            for i in 0..<count { out[i] = 0 }
            return
        }
        let lnF0 = log(f0), lnSpan = log(frequencies[n - 1]) - lnF0
        let lnA = log(axis.minHz), lnASpan = log(axis.maxHz) - lnA
        let binsPerPoint = (lnASpan / Float(count - 1)) / (lnSpan / Float(n - 1))
        let range = maxDB - minDB
        src.withUnsafeBufferPointer { s in
            for j in 0..<count {
                let lnF = lnA + lnASpan * Float(j) / Float(count - 1)
                let idx = (lnF - lnF0) / lnSpan * Float(n - 1)
                var db: Float
                if idx < -0.5 || idx > Float(n) - 0.5 {
                    db = -1000
                } else if binsPerPoint > 1.25 {
                    let lo = max(Int((idx - binsPerPoint * 0.5).rounded(.up)), 0)
                    let hi = min(Int((idx + binsPerPoint * 0.5).rounded(.down)), n - 1)
                    db = -1000
                    if lo <= hi { for k in lo...hi { db = max(db, s[k]) } } else { db = s[min(max(Int(idx.rounded()), 0), n - 1)] }
                } else {
                    let c = min(max(idx, 0), Float(n - 1))
                    let i1 = min(Int(c), n - 2)
                    let t = c - Float(i1)
                    let p0 = s[max(i1 - 1, 0)], p1 = s[i1], p2 = s[i1 + 1], p3 = s[min(i1 + 2, n - 1)]
                    let a = 2 * p1
                    let b = p2 - p0
                    let cc = 2 * p0 - 5 * p1 + 4 * p2 - p3
                    let d = -p0 + 3 * p1 - 3 * p2 + p3
                    db = 0.5 * (a + b * t + cc * t * t + d * t * t * t)
                    // No overshoot past the local range: keeps peaks honest.
                    let lo = min(p1, p2), hi = max(p1, p2)
                    db = min(max(db, lo - 0.5), hi + 0.5)
                }
                out[j] = min(max((db + offsetDB - minDB) / range, 0), 1)
            }
        }
    }
}
