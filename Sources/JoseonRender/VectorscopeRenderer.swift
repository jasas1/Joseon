import AppKit
import Metal
import simd
import JoseonCore

/// What the square field of the vectorscope panel shows.
public enum VectorscopeMode: String, CaseIterable, Sendable {
    /// Goniometer: the L / R sample cloud, mid up, side across.
    case lissajous
    /// Stereo placement by frequency: y = log frequency (20 Hz at the bottom, 20 kHz at the top), x = pan position of each
    /// analyzer bin, light = level, hue = the band hue of the frequency.
    case panSpectrum
}

/// Goniometer with persistence. Points add light into a half-float density texture; every frame the
/// texture fades by exp(-dt / tau). A log tone map turns density into color.
final class VectorscopeRenderer: PanelRenderer {
    var persistenceSeconds: Double = 0.45
    var mode = VectorscopeMode.lissajous { didSet { if mode != oldValue { modeChanged() } } }

    private var scopeLUT: MTLTexture?
    private var accum: MTLTexture?
    private var panAccum: MTLTexture?
    private var panHue: MTLTexture?
    let panField = PanField()
    /// Splats of the newest pan frame (for tests): pan, axis position 0...1, light, vertical sigma in pixels.
    private(set) var lastSplats: [SIMD4<Float>] = []
    var keepsSplatsForTesting = false
    private var accumNeedsClear = true
    private var pendingFade: Double = 0
    private var pendingPoints = false
    private var sinceLight: Double = 100
    private(set) var gain: Float = 1
    /// The automatic gain never zooms in further: beyond this the figure would be the noise floor, not the music.
    static let maxGain: Float = 8
    private var gainSnapped = false
    private var maxPoints = 4096
    private var panTopDB: Float = -20
    /// The light scale of the pan spectrum spans this many dB under its top (never under the gate of `PanField`).
    private static let panRangeDB: Float = 54
    /// Peak hold of the scope level for the automatic gain.
    private var heldLevel: Float = 0
    private var heldFor: Double = 0
    private let histogram: UnsafeMutablePointer<Int32>
    private static let histogramBins = 128

    // Layout.
    private var field = CGRect.zero        // the scope square
    private var corrBar = CGRect.zero
    private var widthBar = CGRect.zero
    private var bands = CGRect.zero
    private var corrHeader = CGPoint.zero
    private var sideBySide = false
    private var narrowTable = false
    /// Where the numbers go. The figure comes first: it takes the card height (or width), the numbers take what is left.
    enum Arrangement { case tableBeside, stripUnder, keysBeside, keysUnder }
    private(set) var arrangement = Arrangement.tableBeside
    /// Key numbers (correlation, width, balance) when there is no room for the band table: cells and the balance track.
    private var keyCells: [CGRect] = []
    private var balanceBar = CGRect.zero
    /// The scope square (or the pan field), for tests.
    var fieldForTesting: CGRect { field }

    // Smoothed display values.
    private var shownCorrelation: Float = 0

    /// The full-scale diamond reaches this part of the half field. The rest is room for the axis labels.
    private static let diamond: CGFloat = 0.86
    private let panAxis = LogAxis(minHz: 20, maxHz: 20_000)

    override init?(ctx: RenderContext, theme: Theme) {
        histogram = .allocate(capacity: Self.histogramBins)
        histogram.initialize(repeating: 0, count: Self.histogramBins)
        super.init(ctx: ctx, theme: theme)
    }

    deinit { histogram.deallocate() }

    override var kind: PanelKind { .vectorscope }
    override var makesPointerCursors: Bool { mode == .panSpectrum }
    override var needsPrePassPerFrame: Bool { true }
    /// The light keeps fading for a while after the last points.
    override var isAnimating: Bool { sinceLight < max(persistenceSeconds, 0.05) * 7 }

    override func paletteChanged() {
        scopeLUT = ctx.makeLUT(palette.scopeLUT())
        panHue = ctx.makeLUT((0..<256).map { Palette.spectrumColor(atHz: panAxis.frequency(Float($0) / 255)) })
    }

    private func modeChanged() {
        accumNeedsClear = true
        panField.reset()
        needsDisplay = true
        layoutChanged()
    }

    override func layoutChanged() {
        let w = size.width, h = size.height
        let pad: CGFloat = w < 340 || h < 240 ? 8 : 12
        let tallField = mode == .panSpectrum
        let strip: CGFloat = 104
        // Linked stereo placement keeps a header row over the field for the cursor readout (nothing covers the field, and
        // the field does not jump when a cursor comes and goes). The goniometer shows the cursor in its band rows: no row.
        let head: CGFloat = cursorLinked && tallField ? 16 : 0
        keyCells = []; balanceBar = .zero
        // The band table needs about 250 pt beside a figure that takes the card height. The pan field is not a square: it
        // gives way to the table.
        if w / h > 1.45 && w >= 520 && (tallField || w - (h - pad * 2) - 56 >= 250) {
            arrangement = .tableBeside
        } else if h - pad * 2 - strip >= (w - pad * 2) * 0.8 {
            arrangement = .stripUnder
        } else if w - (h - pad * 2) - pad * 3 >= 70 {
            arrangement = .keysBeside
        } else {
            arrangement = .keysUnder
        }
        sideBySide = arrangement == .tableBeside
        switch arrangement {
        case .tableBeside:
            let side = min(h - pad * 2, w * 0.46)
            // The pan spectrum is a frequency axis: it takes the whole height. The goniometer is a square.
            field = tallField ? CGRect(x: pad, y: pad + head, width: side, height: h - pad * 2 - head) : CGRect(x: pad, y: (h - side) / 2, width: side, height: side)
            let rx = field.maxX + 28
            let rw = max(w - rx - pad - 4, 60)
            narrowTable = rw < 330
            corrHeader = CGPoint(x: rx, y: field.minY - head + 2)
            corrBar = CGRect(x: rx, y: corrHeader.y + 68, width: rw, height: 10)
            let ww = min(rw * 0.24, 96)
            widthBar = CGRect(x: rx + rw - ww - (narrowTable ? 62 : 104), y: corrHeader.y + 47, width: ww, height: 4)
            let top = corrBar.maxY + 54
            bands = CGRect(x: rx, y: top, width: rw, height: max(field.maxY - top, 40))
        case .stripUnder:
            narrowTable = true
            let side = max(min(w - pad * 2, h - strip - pad * 2), 40)
            field = tallField ? CGRect(x: pad, y: pad + head, width: w - pad * 2, height: max(h - strip - pad * 2 - head, 40))
                : CGRect(x: (w - side) / 2, y: pad, width: side, height: side)
            let rx = pad + 2
            let rw = w - rx * 2
            corrHeader = CGPoint(x: rx, y: field.maxY + 16)
            corrBar = CGRect(x: rx + 44, y: field.maxY + 18, width: max(rw - 44 - 58, 40), height: 8)
            widthBar = .zero
            bands = CGRect(x: rx, y: corrBar.maxY + 18, width: rw, height: max(h - (corrBar.maxY + 22) - pad, 30))
        case .keysBeside:
            // The figure takes the card height. Correlation, width and balance stand in a column beside it.
            narrowTable = true
            let side = h - pad * 2
            let column = tallField ? min(max(w * 0.24, 70), 120) : min(w - side - pad * 3, 150)
            field = tallField ? CGRect(x: pad, y: pad + head, width: w - column - pad * 3, height: side - head) : CGRect(x: pad, y: pad, width: side, height: side)
            let x = field.maxX + pad + 2, cw = w - x - pad
            let cellH = min((h - pad * 2) / 3, 64)
            let top = field.midY - cellH * 1.5
            keyCells = (0..<3).map { CGRect(x: x, y: top + CGFloat($0) * cellH, width: cw, height: cellH) }
            let bars = cellH >= 52
            corrBar = bars ? CGRect(x: x, y: keyCells[0].minY + 40, width: cw, height: 5) : .zero
            widthBar = bars ? CGRect(x: x, y: keyCells[1].minY + 40, width: cw, height: 4) : .zero
            balanceBar = bars ? CGRect(x: x, y: keyCells[2].minY + 39, width: cw, height: 6) : .zero
            corrHeader = keyCells[0].origin
            bands = .zero
        case .keysUnder:
            narrowTable = true
            let row: CGFloat = 30
            let side = max(min(w - pad * 2, h - pad * 2 - row), 40)
            field = tallField ? CGRect(x: pad, y: pad + head, width: w - pad * 2, height: max(h - pad * 2 - row - head, 40))
                : CGRect(x: (w - side) / 2, y: pad, width: side, height: side)
            let cw = (w - pad * 2) / 3
            keyCells = (0..<3).map { CGRect(x: pad + CGFloat($0) * cw, y: field.maxY + 6, width: cw, height: row - 6) }
            corrBar = .zero; widthBar = .zero
            corrHeader = keyCells[0].origin
            bands = .zero
        }
        let px = max(Int(field.width * scale), 16)
        if mode == .lissajous, accum == nil || accum!.width != px {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderContext.accumFormat, width: px, height: px, mipmapped: false)
            d.usage = [.shaderRead, .renderTarget]
            d.storageMode = .private
            accum = ctx.device.makeTexture(descriptor: d)
            accum?.label = "Joseon scope density"
            accumNeedsClear = true
        }
        let py = max(Int(field.height * scale), 16)
        if mode == .panSpectrum, panAccum == nil || panAccum!.width != px || panAccum!.height != py {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderContext.panAccumFormat, width: px, height: py, mipmapped: false)
            d.usage = [.shaderRead, .renderTarget]
            d.storageMode = .private
            panAccum = ctx.device.makeTexture(descriptor: d)
            panAccum?.label = "Joseon pan spectrum light"
            accumNeedsClear = true
        }
        if mode != .panSpectrum { panAccum = nil }
    }

    override var staticSignature: Int {
        var h = Hasher()
        h.combine(super.staticSignature); h.combine(mode)
        return h.finalize()
    }

    override var dynamicSignature: Int {
        guard let f = frame else { return 0 }
        var h = Hasher()
        h.combine(Int(f.stereo.correlation * 100)); h.combine(Int(f.stereo.width * 100)); h.combine(Int(f.stereo.balance * 100))
        h.combine(Int(gain * 10)); h.combine(Int((panTopDB / 2).rounded()))
        h.combine(f.stereo.bandActive)
        for v in f.stereo.bandCorrelation { h.combine(Int(v * 100)) }
        for v in f.stereo.bandBalance { h.combine(Int(v * 100)) }
        return h.finalize()
    }

    // MARK: State

    override func update(frame f: AnalysisFrame, dt: TimeInterval) {
        pendingFade += dt
        let pts = f.stereo.scopePoints
        pendingPoints = !f.isSilent && (mode == .panSpectrum || !pts.isEmpty)
        if pendingPoints { sinceLight = 0 } else { sinceLight += dt }
        updateGain(pts, dt: dt)
        let kc = Float(1 - exp(-dt / 0.12))
        shownCorrelation += (f.stereo.correlation - shownCorrelation) * kc

        // Pan spectrum: the top of the light scale follows the loudest bin. Fast up, slow down.
        var peak: Float = -120
        var i = 0
        let mid = f.spectrum.mid
        while i < mid.count { peak = max(peak, mid[i]); i += 3 }
        if peak > -100 {
            let k = Float(1 - exp(-dt / (peak > panTopDB ? 0.15 : 2.5)))
            panTopDB += (peak - panTopDB) * k
        }
        if mode == .panSpectrum { panField.update(f.spectrum, dt: dt, sampleRate: f.stream?.sampleRate ?? 48_000) }
    }

    /// Automatic gain: the 99.5th percentile of the sample level sits at 85 % of the full-scale diamond, and the loudest
    /// sample stays inside 96 %, so the trace never touches the tips. A percentile, so a single stray sample does not shrink
    /// the figure. The level is held for 1.5 s and then released slowly: a kick drum must not find a gain that crept up
    /// in the gap before it. Down is instant (this frame's points are drawn with this frame's gain). The factor is on screen.
    private func updateGain(_ pts: [SIMD2<Float>], dt: TimeInterval) {
        guard pts.count >= 16 else { return }
        let bins = Self.histogramBins
        histogram.update(repeating: 0, count: bins)
        var top: Float = 0
        for p in pts {
            let d = abs(p.x) + abs(p.y)                      // = max(|L|, |R|) with x = (R - L) / 2, y = (L + R) / 2
            top = max(top, d)
            histogram[min(Int(d * Float(bins)), bins - 1)] += 1
        }
        let limit = Int32((Float(pts.count) * 0.005).rounded(.up))
        var above: Int32 = 0
        var bin = bins - 1
        while bin > 0 {
            above += histogram[bin]
            if above >= limit { break }
            bin -= 1
        }
        // The level the gain must fit: the percentile at 85 %, or the maximum at 96 %, whichever asks for less gain.
        let level = max((Float(bin) + 1) / Float(bins), top * (0.85 / 0.96))
        if level >= heldLevel {
            heldLevel = level; heldFor = 0
        } else {
            heldFor += dt
            if heldFor > 1.5 { heldLevel += (level - heldLevel) * Float(1 - exp(-dt / 2.5)) }
        }
        guard heldLevel > 0.004 else { return }              // under -48 dBFS: keep the gain, do not zoom into noise
        let want = min(max(0.85 / heldLevel, 0.85), Self.maxGain)
        if !gainSnapped || want < gain { gainSnapped = true; gain = want; return }
        gain += (want - gain) * Float(1 - exp(-dt / 1.0))
    }

    override func idle(dt: TimeInterval) { pendingFade += dt; sinceLight += dt }

    override func encodePrePass(_ cb: MTLCommandBuffer) {
        if mode == .panSpectrum { encodePanPrePass(cb); return }
        guard let accum else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = accum
        pass.colorAttachments[0].loadAction = accumNeedsClear ? .clear : .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Joseon scope accumulate"
        accumNeedsClear = false

        if pendingFade > 0 {
            let fade = exp(-pendingFade / max(persistenceSeconds, 0.01))
            enc.setRenderPipelineState(ctx.scopeFade)
            enc.setBlendColor(red: Float(fade), green: Float(fade), blue: Float(fade), alpha: Float(fade))
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            pendingFade = 0
        }

        if pendingPoints, let f = frame {
            let pts = f.stereo.scopePoints
            let n = min(pts.count, maxPoints)
            if n > 1, let a = arena.allocate(SIMD2<Float>.self, count: n) {
                pts.withUnsafeBufferPointer { src in
                    a.pointer.update(from: src.baseAddress! + (pts.count - n), count: n)
                }
                let tex = Float(accum.width)
                // A thin beam: filaments stay filaments. No wide halo pass: the log tone map lifts the faint light instead.
                let sigma = max(Float(scale) * 0.42, 0.6)
                // Energy per point scales with 1 / count so the picture keeps its brightness when the point count changes.
                // A small field packs the same trace into fewer pixels: the light scales with the field size.
                let energy = (1024 / Float(max(n, 64))) * Float(min(frameDelta * 60, 3)) * min(max(pow(tex / 1000, 1.6), 0.08), 2.5)
                var u = ScopeUniforms(center: SIMD2(tex / 2, tex / 2), radius: tex / 2 * Float(Self.diamond), gain: gain,
                                      pointSize: sigma, energy: energy, texSize: SIMD2(tex, tex))
                enc.setRenderPipelineState(ctx.scopePoints)
                enc.setVertexBuffer(arena.buffer, offset: a.offset, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<ScopeUniforms>.stride, index: 2)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n - 1)
            }
            pendingPoints = false
        }
        enc.endEncoding()
    }

    private func encodePanPrePass(_ cb: MTLCommandBuffer) {
        guard let panAccum else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = panAccum
        pass.colorAttachments[0].loadAction = accumNeedsClear ? .clear : .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Joseon pan spectrum accumulate"
        accumNeedsClear = false

        if pendingFade > 0 {
            // Short persistence: the cloud shimmers, it does not smear.
            let fade = exp(-pendingFade / max(persistenceSeconds * 0.6, 0.01))
            enc.setRenderPipelineState(ctx.panFade)
            enc.setBlendColor(red: Float(fade), green: Float(fade), blue: Float(fade), alpha: Float(fade))
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            pendingFade = 0
        }

        if pendingPoints, let f = frame, let panHue {
            let freqs = f.spectrum.frequencies
            let n = min(panField.count, freqs.count)
            if n >= 8, let a = arena.allocate(SIMD4<Float>.self, count: n) {
                let texW = Float(panAccum.width), texH = Float(panAccum.height)
                let axisTop = Float(panAxisRect.minY - field.minY) / Float(field.height)
                let axisHeight = Float(panAxisRect.height / field.height)
                // Splat size: sigma about 1.2 % of the pan span across, a third of that in height: a tone is a compact dot,
                // noise a smooth cloud. Bins lie closer than the splat is high: the energy is shared between them.
                let sigmaX = max(Float(panHalf * 2 * scale) * 0.012, 1.5)
                let sigmaY = max(sigmaX * 0.34, 1.2)
                let binsInAxis = Float(n - 1) * log(panAxis.maxHz / panAxis.minHz) / log(freqs[n - 1] / freqs[0])
                let pitch = texH * axisHeight / max(binsInAxis, 1)
                let top = panTopDB + 3, bottom = top - Self.panRangeDB
                var m = 0
                for i in 0..<n where freqs[i] >= panAxis.minHz && freqs[i] <= panAxis.maxHz {
                    let light = panField.light(i, topDB: top, bottomDB: bottom)
                    guard light > 0 else { continue }
                    // Under 150 Hz one FFT bin covers several display bins: the splat grows to the height of that FFT bin.
                    let sy = max(sigmaY, Float(panField.spread[i]) * pitch * 0.9)
                    // Louder = more light, steeply: a partial 30 dB down is a faint veil. Same light per height for every sigma.
                    a.pointer[m] = SIMD4(min(max(panField.pan[i], -1), 1), panAxis.position(freqs[i]), light * sqrt(light) * (sigmaY / sy), sy)
                    m += 1
                }
                if keepsSplatsForTesting { lastSplats = (0..<m).map { a.pointer[$0] } }
                if m > 0 {
                    let energy: Float = 0.30 * min(pitch / (sigmaY * 2.5), 1) * Float(min(frameDelta * 60, 3))
                    var u = PanUniforms(texSize: SIMD2(texW, texH), centerX: Float((panCenterX - field.minX) / field.width),
                                        halfX: Float(panHalf / field.width), top: axisTop, height: axisHeight, sigmaX: sigmaX, energy: energy)
                    enc.setRenderPipelineState(ctx.panPoints)
                    enc.setVertexBuffer(arena.buffer, offset: a.offset, index: 0)
                    enc.setVertexBytes(&u, length: MemoryLayout<PanUniforms>.stride, index: 2)
                    enc.setVertexTexture(panHue, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: m)
                }
            }
            pendingPoints = false
        }
        enc.endEncoding()
    }

    // MARK: Metal

    override func draw(_ enc: MTLRenderCommandEncoder, globals g: inout Globals) {
        let p = palette
        let fx = Float(field.minX), fy = Float(field.minY), fs = Float(field.width), fh = Float(field.height)

        // Field.
        batch.rect(fx, fy, fs, fh, top: mix(p.plot, p.panel, t: 0.5), bottom: p.plot, radius: 6)
        batch.rect(fx, fy, fs, fh, color: p.gridMajor, radius: 6, stroke: 1)
        if mode == .panSpectrum { drawPanGuides() } else { drawScopeGuides() }
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)

        // The light.
        var rect = SIMD4<Float>(fx, fy, fs, fh)
        enc.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
        if mode == .panSpectrum, let panAccum {
            // The light is clipped to the frequency axis (20 Hz ... 20 kHz): the splat of a sub-bass bin is as high as its
            // FFT bin, and its glow would stand under the 20 Hz line, where the axis has no frequency (critic r6).
            let sc = Float(scale)
            let clip = panAxisRect
            let cy = max(Int((Float(clip.minY) * sc).rounded()), 0), cx = max(Int((fx * sc).rounded()), 0)
            let fullW = max(Int(Float(size.width) * sc), 1), fullH = max(Int(Float(size.height) * sc), 1)
            enc.setScissorRect(MTLScissorRect(x: min(cx, fullW - 1), y: min(cy, fullH - 1), width: max(min(Int((fs * sc).rounded()), fullW - cx), 1),
                                              height: max(min(Int((Float(clip.height) * sc).rounded()), fullH - cy), 1)))
            defer { enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: fullW, height: fullH)) }
            let pk: Float = 30, pref: Float = 5
            var u = ScopeCompositeUniforms(k: pk, norm: 1 / log(1 + pk * pref))
            enc.setRenderPipelineState(ctx.panComposite)
            enc.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
            enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<ScopeCompositeUniforms>.stride, index: 3)
            enc.setFragmentTexture(panAccum, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        } else if mode == .lissajous, let accum, let scopeLUT {
            // log(1 + k d) / log(1 + k dRef): the reference density is far over what a music trace reaches in its core,
            // so the ramp's warm white end shows only where the beam really dwells.
            let k: Float = 22, ref: Float = 60
            var u = ScopeCompositeUniforms(k: k, norm: 1 / log(1 + k * ref))
            enc.setRenderPipelineState(ctx.scopeComposite)
            enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<ScopeCompositeUniforms>.stride, index: 3)
            enc.setFragmentTexture(accum, index: 0)
            enc.setFragmentTexture(scopeLUT, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        if mode == .panSpectrum, let legend = panLegendRect {
            // Intensity legend, hue-coded like the plot: the light scale from its bottom to its top in three hues of the
            // frequency axis (highs on top, like the axis). Hue = frequency, brightness = level.
            let lx = Float(legend.minX), ly = Float(legend.minY), lw = Float(legend.width), lh = Float(legend.height)
            // One step per device pixel: a smooth ramp, no bands (critic r6).
            let steps = Self.panLegendSteps(width: legend.width, scale: scale)
            let hues: [Float] = [9_000, 700, 60]
            let rowH = lh / Float(hues.count)
            for (row, hz) in hues.enumerated() {
                let hue = Palette.spectrumColor(atHz: hz)
                for k in 0..<steps {
                    let a = (Float(k) + 0.5) / Float(steps)
                    let v = 0.05 + 0.89 * a * sqrt(a)
                    // The brightest end drifts toward warm white, as the dense cores of the plot do.
                    let c = mix(hue.rgba(1), SIMD4(1, 0.96, 0.90, 1), t: max(a - 0.72, 0) / 0.28 * 0.6) * v
                    batch.rect(lx + lw * Float(k) / Float(steps), ly + rowH * Float(row), lw / Float(steps) + 0.5, rowH + 0.25, color: SIMD4(c.x, c.y, c.z, 1), radius: 0)
                }
            }
            batch.rect(lx - 0.5, ly - 0.5, lw + 1, lh + 1, color: p.gridMajor, radius: 1.5, stroke: 1)
            // Middle tick (-45 on a -70 ... -20 scale); its number is in the text layer.
            batch.vline(lx + lw / 2, ly + lh, ly + lh + 3, color: p.gridStrong)
            batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
        }

        drawLinkedCursor(enc, &g)
        drawCorrelationBar(enc, &g)
        drawBands(enc, &g)
    }

    private func drawScopeGuides() {
        let p = palette
        let fx = Float(field.minX), fy = Float(field.minY), fs = Float(field.width)
        let cx = fx + fs / 2, cy = fy + fs / 2
        let r = fs / 2 * Float(Self.diamond)
        // Full-scale diamond, half-scale diamond.
        diamond(cx, cy, r, color: p.gridMajor.scaledAlpha(1.5))
        diamond(cx, cy, r * 0.5, color: p.gridMinor.scaledAlpha(1.6))
        // M and S axes, L and R diagonals.
        batch.vline(cx, cy - r, cy + r, color: p.gridMajor.scaledAlpha(1.4))
        batch.hline(cx - r, cx + r, cy, color: p.gridMajor)
        let dg = r * 0.5
        batch.line(cx - dg, cy - dg, cx + dg, cy + dg, width: 1, color: p.gridMinor.scaledAlpha(1.8))
        batch.line(cx + dg, cy - dg, cx - dg, cy + dg, width: 1, color: p.gridMinor.scaledAlpha(1.8))
    }

    private func diamond(_ cx: Float, _ cy: Float, _ d: Float, color c: SIMD4<Float>) {
        batch.line(cx, cy - d, cx + d, cy, width: 1, color: c)
        batch.line(cx + d, cy, cx, cy + d, width: 1, color: c)
        batch.line(cx, cy + d, cx - d, cy, width: 1, color: c)
        batch.line(cx - d, cy, cx, cy - d, width: 1, color: c)
    }

    /// The pan spectrum keeps a gutter on the left for the frequency labels.
    private var panGutter: CGFloat { field.width < 300 ? 30 : 36 }
    private var panCenterX: CGFloat { field.minX + panGutter + (field.width - panGutter) / 2 }
    private var panHalf: CGFloat { (field.width - panGutter) / 2 * 0.90 }
    /// The frequency axis inside the field: room for the L / C / R row over 20 kHz and for the legend under 20 Hz.
    private var panAxisRect: CGRect {
        let top: CGFloat = 24, bottom: CGFloat = field.height < 220 ? 10 : 24
        return CGRect(x: field.minX, y: field.minY + top, width: field.width, height: max(field.height - top - bottom, 20))
    }
    /// Intensity legend, bottom right inside the field. Nil when the field is too small.
    private var panLegendRect: CGRect? {
        guard field.width >= 200, field.height >= 220 else { return nil }
        // Wide enough to read three numbers off it: the ends and the middle.
        let w: CGFloat = min(160, field.width * 0.34)
        return CGRect(x: field.maxX - 12 - 22 - w, y: field.maxY - 21, width: w, height: 8)
    }

    var panLegendForTesting: CGRect? { panLegendRect }
    static func panLegendSteps(width: CGFloat, scale: CGFloat) -> Int { min(max(Int((width * scale).rounded()), 12), 512) }
    /// The part of the field that carries light in placement mode, for tests.
    var panAxisRectForTesting: CGRect { panAxisRect }
    /// y of a frequency on the placement axis, for tests.
    func panYForTesting(hz: Float) -> CGFloat { CGFloat(panY(hz)) }
    /// Field, pan center and pan reach in points, for tests.
    var panGeometryForTesting: (field: CGRect, centerX: CGFloat, half: CGFloat) { (field, panCenterX, panHalf) }

    private func panY(_ hz: Float) -> Float { Float(panAxisRect.maxY) - panAxis.position(hz) * Float(panAxisRect.height) }

    private func drawPanGuides() {
        let p = palette
        let fx = Float(field.minX), fs = Float(field.width)
        let y0 = Float(panAxisRect.minY), y1 = Float(panAxisRect.maxY)
        let cx = Float(panCenterX)
        let half = Float(panHalf)
        for f in LogAxis.labeled where f >= panAxis.minHz && f <= panAxis.maxHz {
            batch.hline(fx + Float(panGutter) - 4, fx + fs - 1, panY(f), color: p.gridMinor.scaledAlpha(f == 20 || f == 20_000 ? 1.8 : 1.3))
        }
        batch.vline(cx, y0, y1, color: p.gridMajor.scaledAlpha(1.5))
        for k in [-1, -0.5, 0.5, 1] as [Float] {
            batch.vline(cx + k * half, y0, y1, color: abs(k) == 1 ? p.gridMajor : p.gridMinor.scaledAlpha(1.3))
        }
    }

    private func corrColor(_ c: Float) -> SIMD4<Float> {
        let p = palette
        if c < 0 { return p.danger }
        return mix(p.accent, p.good, t: min(max(c, 0), 1))
    }

    private func drawCorrelationBar(_ enc: MTLRenderCommandEncoder, _ g: inout Globals) {
        let p = palette
        let b = corrBar
        guard b.width > 0 else { return }
        let x0 = Float(b.minX), y0 = Float(b.minY), w = Float(b.width), h = Float(b.height)
        let mid = x0 + w / 2
        // Track: the negative half carries a faint red wash.
        batch.rect(x0, y0, w, h, color: p.track, radius: h / 2)
        batch.hgradient(x0, y0, w / 2, h, left: p.danger.withAlpha(0.30), right: p.danger.withAlpha(0.05), radius: h / 2)
        let c = min(max(shownCorrelation, -1), 1)
        let vx = mid + c * w / 2
        let col = corrColor(c)
        // Without signal there is no correlation: the track alone, no marker at a made-up zero.
        let empty = frame.map { Self.noSignal($0) } ?? true
        if empty {
            for t in [-1, -0.5, 0, 0.5, 1] as [Float] {
                let tx = x0 + (t + 1) / 2 * w
                batch.vline(tx, y0 + h + 2, y0 + h + (t == 0 ? 7 : 5), color: p.gridStrong)
            }
            if widthBar.width > 0 { batch.rect(Float(widthBar.minX), Float(widthBar.minY), Float(widthBar.width), Float(widthBar.height), color: p.track, radius: Float(widthBar.height) / 2) }
            batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
            return
        }
        if c >= 0 {
            batch.hgradient(mid, y0, max(vx - mid, 0.5), h, left: col.withAlpha(0.55), right: col, radius: 1)
        } else {
            batch.hgradient(vx, y0, max(mid - vx, 0.5), h, left: col, right: col.withAlpha(0.55), radius: 1)
        }
        for t in [-1, -0.5, 0, 0.5, 1] as [Float] {
            let tx = x0 + (t + 1) / 2 * w
            batch.vline(tx, y0 + h + 2, y0 + h + (t == 0 ? 7 : 5), color: p.gridStrong)
        }
        // Width: a 0...1 bar. Over 1 (more side than mid) the bar is full and turns to the warning color.
        if widthBar.width > 0, let f = frame {
            let wb = widthBar
            let wx = Float(wb.minX), wy = Float(wb.minY), ww = Float(wb.width), wh = Float(wb.height)
            batch.rect(wx, wy, ww, wh, color: p.track, radius: wh / 2)
            let v = min(max(f.stereo.width, 0), 1)
            if v > 0.005 { batch.rect(wx, wy, max(ww * v, wh), wh, color: f.stereo.width > 1 ? p.warn : p.accent, radius: wh / 2) }
        }
        if balanceBar.width > 0, let f = frame, !Self.noSignal(f) {
            // Balance: a dot on a track, like the rows of the band table.
            let bb = balanceBar
            let bx0 = Float(bb.minX), by = Float(bb.midY), bw = Float(bb.width)
            batch.rect(bx0, by - 1, bw, 2, color: p.track, radius: 1)
            batch.vline(bx0 + bw / 2, by - 4, by + 4, color: p.gridStrong)
            let bx = bx0 + bw / 2 + min(max(f.stereo.balance, -1), 1) * (bw / 2 - 4)
            batch.circle(bx, by, 3.5, color: p.accent)
            batch.circle(bx, by, 3.5, color: SIMD4(1, 1, 1, 0.85), stroke: 1)
        }
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
        batch.rect(vx - 5, y0 - 4, 10, h + 8, color: col.withAlpha(0.5), radius: 4, glow: 3)
        batch.flush(enc, pipeline: ctx.shapeAdd, globals: &g)
        batch.rect(vx - 1.25, y0 - 3, 2.5, h + 6, color: SIMD4(1, 1, 1, 1), radius: 1.25)
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
    }

    /// Row geometry for the band table (side by side) or column geometry for the strip (stacked).
    /// The table uses the whole height under the correlation bar.
    private func bandCell(_ i: Int) -> CGRect {
        if sideBySide {
            let rowH = min(bands.height / 8, 60)
            return CGRect(x: bands.minX, y: bands.minY + CGFloat(i) * rowH, width: bands.width, height: rowH)
        }
        let cw = bands.width / 8
        return CGRect(x: bands.minX + CGFloat(i) * cw, y: bands.minY, width: cw, height: bands.height)
    }

    private var tableLabelWidth: CGFloat { narrowTable ? 50 : 88 }
    private var tableValueWidth: CGFloat { narrowTable ? 0 : 48 }

    private func bandTracks(_ cell: CGRect) -> (corr: CGRect, bal: CGRect) {
        if sideBySide {
            let labelW = tableLabelWidth, valueW = tableValueWidth
            let gap: CGFloat = narrowTable ? 14 : 24
            let tw = max((cell.width - labelW - valueW * 2 - gap) / 2, 10)
            let c = CGRect(x: cell.minX + labelW, y: cell.midY - 3, width: tw, height: 6)
            let b = CGRect(x: c.maxX + valueW + gap, y: cell.midY - 3, width: tw, height: 6)
            return (c, b)
        }
        let inset: CGFloat = 5
        let c = CGRect(x: cell.minX + inset, y: cell.minY + 20, width: cell.width - inset * 2, height: 6)
        let b = CGRect(x: cell.minX + inset, y: cell.minY + 38, width: cell.width - inset * 2, height: 6)
        return (c, b)
    }

    private func drawBands(_ enc: MTLRenderCommandEncoder, _ g: inout Globals) {
        guard let f = frame, bands.width > 0 else { return }
        let p = palette
        if let b = cursorBand {
            // The band that holds the cursor frequency: a quiet plate behind its row, an accent edge.
            let cell = bandCell(b)
            let r = sideBySide ? cell.insetBy(dx: -6, dy: 1) : cell.insetBy(dx: 1, dy: -3)
            batch.rect(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height), color: p.accent.withAlpha(0.16), radius: 4)
            if sideBySide { batch.rect(Float(r.minX), Float(r.minY) + 3, 2, Float(r.height) - 6, color: p.accent, radius: 1) }
            else { batch.rect(Float(r.minX) + 3, Float(r.maxY) - 2, Float(r.width) - 6, 2, color: p.accent, radius: 1) }
        }
        for i in 0..<8 {
            let cell = bandCell(i)
            let t = bandTracks(cell)
            let corr = i < f.stereo.bandCorrelation.count ? min(max(f.stereo.bandCorrelation[i], -1), 1) : 0
            let bal = i < f.stereo.bandBalance.count ? min(max(f.stereo.bandBalance[i], -1), 1) : 0
            let hue = Palette.spectrumColor(atHz: (BandEnergy.edgesHz[i] * BandEnergy.edgesHz[i + 1]).squareRoot()).rgba(1)
            // A gated empty band has no measurement: its zeros are placeholders. Show grey tracks only.
            let active = i < f.stereo.bandActive.count ? f.stereo.bandActive[i] : true

            // Correlation: bipolar bar from the center.
            var x0 = Float(t.corr.minX), y0 = Float(t.corr.minY), w = Float(t.corr.width), h = Float(t.corr.height)
            var mid = x0 + w / 2
            batch.rect(x0, y0, w, h, color: active ? p.track : p.track.scaledAlpha(0.5), radius: h / 2)
            if sideBySide, i > 0 {
                batch.hline(Float(cell.minX), Float(cell.maxX), Float(cell.minY), color: p.gridMinor)
            }
            if !active {
                x0 = Float(t.bal.minX); y0 = Float(t.bal.minY); w = Float(t.bal.width); h = Float(t.bal.height)
                batch.rect(x0, y0 + h / 2 - 1, w, 2, color: p.track.scaledAlpha(0.5), radius: 1)
                // Hollow grey dot: "no value", different in shape from a centered balance.
                batch.circle(x0 + w / 2, y0 + h / 2, 3, color: p.textFaint, stroke: 1)
                continue
            }
            let vx = mid + corr * w / 2
            let col = corrColor(corr)
            if corr >= 0 { batch.rect(mid, y0, max(vx - mid, 0.5), h, color: col, radius: 1) }
            else { batch.rect(vx, y0, max(mid - vx, 0.5), h, color: col, radius: 1) }
            batch.vline(mid, y0 - 2, y0 + h + 2, color: p.gridStrong)

            // Balance: a dot on a track, tinted by the band's hue.
            x0 = Float(t.bal.minX); y0 = Float(t.bal.minY); w = Float(t.bal.width); h = Float(t.bal.height)
            mid = x0 + w / 2
            batch.rect(x0, y0 + h / 2 - 1, w, 2, color: p.track, radius: 1)
            batch.vline(mid, y0 - 2, y0 + h + 2, color: p.gridStrong)
            let bx = mid + bal * (w / 2 - 4)
            batch.circle(bx, y0 + h / 2, 4, color: hue)
            batch.circle(bx, y0 + h / 2, 4, color: SIMD4(1, 1, 1, 0.85), stroke: 1)
        }
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
    }

    // MARK: Text

    private static let shortNames = ["Sub", "Bass", "LoMid", "Mid", "UpMid", "Pres", "Brill", "Air"]

    override func drawStatic(_ o: OverlayContext) {
        let p = palette
        let f = Fonts.ui(11, .semibold)
        let cx = field.midX, cy = field.midY
        if mode == .panSpectrum {
            let small = Fonts.mono(field.width < 300 ? 10 : 11)
            let half = panHalf, pcx = panCenterX
            o.text("L", x: pcx - half, y: field.minY + 7, font: f, color: p.left, h: .center, v: .top)
            o.text("R", x: pcx + half, y: field.minY + 7, font: f, color: p.right, h: .center, v: .top)
            o.text("C", x: pcx, y: field.minY + 7, font: f, color: p.textDim, h: .center, v: .top)
            o.text("Hz", x: field.minX + panGutter - 7, y: field.minY + 7, font: small, color: p.textFaint, h: .right, v: .top)
            // Every labeled frequency from 20 Hz to 20 kHz; the ends always, the rest where there is room.
            var taken: [CGFloat] = []
            for hz in [20, 20_000] + LogAxis.labeled.filter({ $0 > 20 && $0 < 20_000 }) {
                let yy = CGFloat(panY(hz))
                if taken.contains(where: { abs($0 - yy) < 13 }) { continue }
                taken.append(yy)
                o.text(Fmt.axisHz(hz), x: field.minX + panGutter - 7, y: yy, font: small, color: p.textDim, h: .right, v: .middle)
            }
        } else {
            let r = field.width / 2 * Self.diamond
            // Under 160 pt the labels would pile up on the figure: the diamond alone still reads.
            if field.width >= 160 {
            // Labels stand 10 pt outside the diamond: the trace never runs through them.
            // "M" stands between the tip and the border: under 230 pt there is no room for it there.
            if field.width >= 230 { o.text("M", x: cx, y: cy - r - 5, font: f, color: p.textDim, h: .center, v: .bottom) }
            let off = r / 2 + 10 * 0.7071 + 3
            o.text("L", x: cx - off, y: cy - off, font: f, color: p.left, h: .right, v: .bottom)
            o.text("R", x: cx + off, y: cy - off, font: f, color: p.right, v: .bottom)
            o.text("+S", x: field.minX + 7, y: cy - 6, font: f, color: p.textFaint, v: .bottom)
            o.text("\(Fmt.minus)S", x: field.maxX - 7, y: cy - 6, font: f, color: p.textFaint, h: .right, v: .bottom)
            }
        }

        let small = Fonts.mono(11)
        for t in [-1, 0, 1] as [Float] where sideBySide {
            let tx = corrBar.minX + CGFloat((t + 1) / 2) * corrBar.width
            let label = t == 0 ? "0" : (t < 0 ? "\(Fmt.minus)1" : "+1")
            o.text(label, x: tx, y: corrBar.maxY + 10, font: small, color: p.textDim, h: t == 0 ? .center : (t < 0 ? .left : .right), v: .top)
        }

        let cap = Fonts.ui(11, .semibold)
        if sideBySide {
            o.text("CORRELATION", x: corrHeader.x, y: corrHeader.y, font: cap, color: p.textFaint, v: .top, tracking: 1.0)
            let first = bandTracks(bandCell(0))
            o.text("BAND", x: bands.minX, y: bands.minY - 7, font: cap, color: p.textFaint, v: .bottom, tracking: 1.0)
            o.text(narrowTable ? "CORR" : "CORRELATION", x: first.corr.minX, y: bands.minY - 7, font: cap, color: p.textFaint, v: .bottom, tracking: 1.0)
            o.text(narrowTable ? "BAL" : "BALANCE", x: first.bal.minX, y: bands.minY - 7, font: cap, color: p.textFaint, v: .bottom, tracking: 1.0)
            let nameFont = Fonts.ui(narrowTable ? 11 : 12)
            for i in 0..<8 {
                let cell = bandCell(i)
                o.text(narrowTable ? Self.shortNames[i] : BandEnergy.names[i], x: cell.minX, y: cell.midY, font: nameFont, color: p.text, v: .middle)
            }
        } else if !keyCells.isEmpty {
            let small = Fonts.ui(10, .semibold)
            for (i, name) in ["CORR", "WIDTH", "BAL"].enumerated() {
                let cell = keyCells[i]
                if arrangement == .keysBeside {
                    o.text(name, x: cell.minX, y: cell.minY + 3, font: small, color: p.textFaint, v: .top, tracking: 0.8)
                } else {
                    o.text(name, x: cell.minX + 2, y: cell.midY, font: small, color: p.textFaint, v: .middle, tracking: 0.6)
                }
            }
        } else {
            o.text("CORR", x: corrHeader.x, y: corrBar.midY, font: cap, color: p.textFaint, v: .middle, tracking: 1.0)
            let nameFont = Fonts.ui(bands.width / 8 < 40 ? 10 : 11)
            let names = BandLabels.fitting(o, font: nameFont, columnWidth: bands.width / 8, panelWidth: size.width)
            for i in 0..<8 {
                let cell = bandCell(i)
                o.text(names[i], x: cell.midX, y: cell.minY + 2, font: nameFont, color: p.textDim, h: .center, v: .top)
            }
        }
    }

    override func drawDynamic(_ o: OverlayContext) {
        guard let f = frame else { return }
        let p = palette
        let c = f.stereo.correlation
        let silent = Self.noSignal(f)
        let text = silent ? Fmt.dash : Fmt.number(c, digits: 2, signed: true)
        let col = silent ? p.textDim : mix(corrColor(c), SIMD4(1, 1, 1, 1), t: 0.25)
        if sideBySide {
            o.text(text, x: corrHeader.x, y: corrHeader.y + 44, font: Fonts.ui(narrowTable ? 24 : 30, .light), color: col)
            // Width and balance, right aligned on the same baseline.
            let cap = Fonts.ui(11, .semibold), val = Fonts.ui(15, .regular)
            let rx = corrBar.maxX
            o.text(narrowTable ? "BAL" : "BALANCE", x: rx, y: corrHeader.y, font: cap, color: p.textFaint, h: .right, v: .top, tracking: 1.0)
            o.text(balanceText(f.stereo.balance, silent: silent), x: rx, y: corrHeader.y + 38, font: val, color: p.text, h: .right)
            o.text("WIDTH", x: widthBar.maxX, y: corrHeader.y, font: cap, color: p.textFaint, h: .right, v: .top, tracking: 1.0)
            o.text(silent ? Fmt.dash : Fmt.number(f.stereo.width, digits: 2), x: widthBar.maxX, y: corrHeader.y + 38, font: val,
                   color: f.stereo.width > 1 ? p.warn : p.text, h: .right)
            if !narrowTable {
                let tiny = Fonts.mono(11)
                // The scale of the bar, at its ends.
                o.text("0", x: widthBar.minX - 5, y: widthBar.midY, font: tiny, color: p.textFaint, h: .right, v: .middle)
                o.text("1", x: widthBar.maxX + 5, y: widthBar.midY, font: tiny, color: p.textFaint, v: .middle)
            }

            if !narrowTable {
                let vf = Fonts.mono(11)
                for i in 0..<8 {
                    let t = bandTracks(bandCell(i))
                    let bc = i < f.stereo.bandCorrelation.count ? f.stereo.bandCorrelation[i] : 0
                    let bb = i < f.stereo.bandBalance.count ? f.stereo.bandBalance[i] : 0
                    let empty = silent || !(i < f.stereo.bandActive.count ? f.stereo.bandActive[i] : true)
                    let color = empty ? p.textFaint : p.textDim
                    o.text(empty ? Fmt.dash : Fmt.number(bc, digits: 2, signed: true), x: t.corr.maxX + 44, y: t.corr.midY, font: vf, color: color, h: .right, v: .middle)
                    o.text(balanceText(bb, silent: empty), x: t.bal.maxX + 44, y: t.bal.midY, font: vf, color: color, h: .right, v: .middle)
                }
            }
        } else if !keyCells.isEmpty {
            // The three key numbers: correlation, width, balance.
            let widthText = silent ? Fmt.dash : Fmt.number(f.stereo.width, digits: 2)
            let values = [text, widthText, balanceText(f.stereo.balance, silent: silent)]
            let colors = [col, f.stereo.width > 1 && !silent ? p.warn : p.text, p.text]
            for i in 0..<3 {
                let cell = keyCells[i]
                if arrangement == .keysBeside {
                    o.text(values[i], x: cell.minX, y: cell.minY + 33, font: Fonts.ui(i == 0 ? 19 : 16, i == 0 ? .light : .regular), color: colors[i])
                } else {
                    o.text(values[i], x: cell.maxX - 8, y: cell.midY, font: Fonts.ui(13, .regular), color: colors[i], h: .right, v: .middle)
                }
            }
        } else {
            o.text(text, x: corrBar.maxX + 54, y: corrBar.midY, font: Fonts.ui(15, .regular), color: col, h: .right, v: .middle)
        }
        if mode == .panSpectrum, let legend = panLegendRect {
            let tiny = Fonts.mono(10)
            let top = panTopDB + 3
            let bottom = max(top - Self.panRangeDB, panField.gateDB)
            o.text(Fmt.number((bottom / 2).rounded() * 2, digits: 0), x: legend.minX - 4, y: legend.midY, font: tiny, color: p.textFaint, h: .right, v: .middle)
            o.text(Fmt.number((top / 2).rounded() * 2, digits: 0), x: legend.maxX + 4, y: legend.midY, font: tiny, color: p.textFaint, v: .middle)
            let lo = (bottom / 2).rounded() * 2, hi = (top / 2).rounded() * 2
            o.text(Fmt.number(((lo + hi) / 2).rounded(), digits: 0), x: legend.midX, y: legend.maxY + 4, font: tiny, color: p.textFaint, h: .center, v: .top)
        }
        drawCursorText(o)
        // No gain label over an empty scope: it says how the figure on screen was scaled, and there is none.
        if mode == .lissajous, abs(gain - 1) > 0.05, !silent, !f.isSilent, heldLevel > 0.004, field.width >= 120 {
            o.text("gain \u{00D7}\(String(format: "%.1f", gain))", x: field.maxX - 8, y: field.maxY - 8, font: Fonts.mono(field.width < 260 ? 10 : 11), color: p.textFaint, h: .right, v: .bottom)
        }
    }

    // MARK: Linked cursor

    /// The listening band under the cursor: its row of the band table is highlighted (in both modes), or, under the
    /// goniometer without a table, the block under the key numbers shows it.
    private var cursorBand: Int? {
        guard cursorLinked, let c = cursor else { return nil }
        return CursorMath.band(containing: c.frequencyHz)
    }

    override func cursorChangeShows(from old: PanelCursor?) -> Bool {
        guard mode == .lissajous else { return true }
        return old.flatMap { CursorMath.band(containing: $0.frequencyHz) } != cursor.flatMap { CursorMath.band(containing: $0.frequencyHz) }
    }

    override func combineCursorSignature(_ c: PanelCursor, into h: inout Hasher) {
        if mode == .lissajous { h.combine(CursorMath.band(containing: c.frequencyHz)) } else { super.combineCursorSignature(c, into: &h) }
    }

    override func cursor(at point: CGPoint) -> PanelCursor? {
        guard mode == .panSpectrum, field.contains(point), point.y >= panAxisRect.minY, point.y <= panAxisRect.maxY else { return nil }
        return PanelCursor(frequencyHz: panAxis.frequency(Float((panAxisRect.maxY - point.y) / panAxisRect.height)), source: .vectorscope)
    }

    override func isOnCursor(_ point: CGPoint) -> Bool {
        guard mode == .panSpectrum, let c = cursor, field.contains(point) else { return false }
        return abs(CGFloat(panY(c.frequencyHz)) - point.y) <= 5
    }

    /// Pan of the analyzer bin at the cursor frequency, from the state the field is drawn from. Nil where the field shows
    /// no light (under the gate, or the skirt of a tone): there is no placement to read.
    func cursorPan() -> Float? {
        guard mode == .panSpectrum, let c = cursor, let f = frame,
              let i = CursorMath.nearestBin(frequencies: f.spectrum.frequencies, count: panField.count, atHz: c.frequencyHz) else { return nil }
        let top = panTopDB + 3
        guard panField.light(i, topDB: top, bottomDB: top - Self.panRangeDB) > 0 else { return nil }
        return min(max(panField.pan[i], -1), 1)
    }

    private func drawLinkedCursor(_ enc: MTLRenderCommandEncoder, _ g: inout Globals) {
        if let r = bandBlock {
            batch.rect(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height), color: palette.accent.withAlpha(0.16), radius: 4)
            batch.rect(Float(r.minX), Float(r.minY) + 3, 2, Float(r.height) - 6, color: palette.accent, radius: 1)
            batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
        }
        guard cursorLinked, mode == .panSpectrum, let c = cursor, c.frequencyHz >= panAxis.minHz, c.frequencyHz <= panAxis.maxHz else { return }
        let yy = panY(c.frequencyHz)
        drawCursorHorizontal(y: yy, left: Float(field.minX + panGutter) - 4, right: Float(field.maxX) - 1)
        if let pan = cursorPan() {
            // Where the sound of this row sits between left and right.
            let mx = Float(panCenterX) + pan * Float(panHalf)
            batch.circle(mx, yy, 4, color: palette.plot.withAlpha(0.85))
            batch.circle(mx, yy, 4, color: SIMD4(1, 1, 1, 0.95), stroke: 1.2)
        }
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
    }

    override func cursorItems() -> [CursorReadoutItem] {
        guard let c = cursor, let f = frame else { return [] }
        if mode == .lissajous {
            guard let b = CursorMath.band(containing: c.frequencyHz) else { return [] }
            let st = f.stereo
            let active = !Self.noSignal(f) && (b < st.bandActive.count ? st.bandActive[b] : true)
            let corr = b < st.bandCorrelation.count ? st.bandCorrelation[b] : 0, bal = b < st.bandBalance.count ? st.bandBalance[b] : 0
            return [.init(text: "\(BandEnergy.names[b]) \(CursorMath.bandRange(b))", rank: 0),
                    .init(text: "corr \(active ? Fmt.number(corr, digits: 2, signed: true) : Fmt.dash)", rank: 1),
                    .init(text: "bal \(balanceText(bal, silent: !active))", rank: 2)]
        }
        // In this panel the pan is the answer: it outranks the note.
        var items = [CursorReadoutItem(text: CursorMath.hz(c.frequencyHz), rank: 0)]
        if let n = CursorMath.note(c.frequencyHz) { items.append(.init(text: n, rank: 3, tone: .dim)) }
        items.append(.init(text: "pan \(cursorPan().map { balanceText($0, silent: false) } ?? Fmt.dash)", rank: 1))
        if let m = CursorMath.level(of: f.spectrum.mid, frequencies: f.spectrum.frequencies, atHz: c.frequencyHz) {
            items.append(.init(text: "Mid \(Fmt.db(m)) dB", rank: 2, tone: .dim))
        }
        return items
    }

    /// The block under the key numbers (no band table at this size): the band at the cursor, its correlation and balance.
    private var bandBlock: CGRect? {
        guard mode == .lissajous, cursorBand != nil, arrangement == .keysBeside, let last = keyCells.last else { return nil }
        let r = CGRect(x: last.minX - 4, y: last.maxY + 8, width: last.width + 8, height: 36)
        return r.maxY <= size.height - 8 && r.width >= 96 ? r : nil
    }

    private func drawCursorText(_ o: OverlayContext) {
        guard cursorLinked, cursor != nil else { return }
        if mode == .panSpectrum {
            guard showsHeaderReadout else { return }
            CursorHeader.draw(o, items: cursorItems(), right: field.maxX, left: field.minX, midY: field.minY - 9, compact: true,
                              pinned: cursor?.isPinned == true, palette: palette)
        } else if let r = bandBlock, let b = cursorBand {
            let items = cursorItems()
            guard items.count == 3 else { return }
            let cap = Fonts.ui(10, .semibold), val = Fonts.ui(11, .medium)
            // The name in capitals like the other captions; the unit keeps its case (kHz).
            let long = "\(BandEnergy.names[b].uppercased()) \(CursorMath.bandRange(b))"
            let name = o.measure(long, font: cap, tracking: 0.6) <= r.width - 10 ? long : "\(BandLabels.short[b].uppercased()) \(CursorMath.bandRange(b))"
            o.text(name, x: r.minX + 6, y: r.minY + 5, font: cap, color: mix(palette.accent, SIMD4(1, 1, 1, 1), t: 0.55), v: .top, tracking: 0.6)
            let line = "\(items[1].text)   \(items[2].text)"
            o.text(o.measure(line, font: val) <= r.width - 10 ? line : items[1].text, x: r.minX + 6, y: r.maxY - 7, font: val, color: palette.text)
        }
    }

    /// "R 19%": the share of the level difference, with its unit. "C" at the center, a dash without signal.
    func balanceText(_ b: Float, silent: Bool) -> String {
        if silent { return Fmt.dash }
        let pct = Int((abs(b) * 100).rounded())
        if pct == 0 { return "C" }
        return (b < 0 ? "L " : "R ") + "\(pct)%"
    }

    /// No signal = no stereo measurement. The analyzer marks silence with `isSilent` and still sends its (all zero) scope
    /// points and a correlation of 0: that 0 is a placeholder, not a reading. It is shown as a dash, with no marker on the bar.
    static func noSignal(_ f: AnalysisFrame) -> Bool { f.isSilent || f.stereo.scopePoints.isEmpty }

    /// Cursor readout of the pan spectrum: frequency and pan position under the cursor.
    override func hoverLabel() -> (lines: [String], anchor: CGPoint)? {
        if cursorLinked {
            guard mode == .panSpectrum, showsPointerReadout, let hv = hover, field.contains(hv), let c = cursor else { return nil }
            var first = CursorMath.hz(c.frequencyHz)
            if let n = CursorMath.note(c.frequencyHz) { first += "   \(n)" }
            let rest = cursorItems().filter { $0.rank == 1 || $0.rank == 2 }.map(\.text).joined(separator: "   ")
            return ([first, rest], hv)
        }
        guard mode == .panSpectrum, let hv = hover, field.contains(hv) else { return nil }
        let hz = panAxis.frequency(min(max(Float((panAxisRect.maxY - hv.y) / panAxisRect.height), 0), 1))
        let pan = Float((hv.x - panCenterX) / panHalf)
        var first = "cursor  \(Fmt.hz(hz))"
        if let n = Fmt.note(forHz: hz) { first += "   \(n.name)" }
        return ([first, "cursor  pan \(balanceText(min(max(pan, -1), 1), silent: false))"], hv)
    }

    override var accessibilityLabelText: String { mode == .panSpectrum ? "Stereo placement by frequency" : "Stereo vectorscope" }
    override var accessibilityValueText: String {
        guard let f = frame, !Self.noSignal(f) else { return "No signal" }
        let b = f.stereo.balance
        let bal = abs(b) < 0.005 ? "centered" : "\(Int((abs(b) * 100).rounded())) percent \(b < 0 ? "left" : "right")"
        return "Correlation \(String(format: "%+.2f", f.stereo.correlation)), width \(String(format: "%.2f", f.stereo.width)), balance \(bal)"
    }
}
