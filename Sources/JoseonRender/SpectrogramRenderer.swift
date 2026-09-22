import Accelerate
import AppKit
import Metal
import JoseonCore

/// Scrolling spectrogram. History lives in a GPU ring texture: each analysis frame adds one column with a
/// small blit. The texture is never uploaded again as a whole; the shader rotates it by the head index.
///
/// The ring holds plain dB (0...1 = -120...0 dB). The color mapping happens in the shader, so a change of the
/// automatic top re-colors the whole history at once and the picture stays consistent.
final class SpectrogramRenderer: PanelRenderer {
    var historySeconds: Double = 20 { didSet { if historySeconds != oldValue { resetHistory() } } }
    /// At or under this level a cell is background: no navy haze over silence or the noise floor.
    var floorDB: Float = -75
    /// Exponent of the color map position. 1 = the map is linear in dB: a noise floor at -65 dB is a dark navy, and a tone
    /// 20 dB over it is a bright cyan-blue (see `Palette.heatLUT`).
    var gamma: Float = 1.0

    static let columns = 1200
    /// One row per display bin of the analyzer between 20 Hz and 20 kHz (about 890 of the 1024), and a few to spare:
    /// the full resolution of the frame. Partials stay as thin as the analyzer resolved them.
    static let rows = 1024
    private static let maxPending = 16

    private let axis = LogAxis(minHz: 20, maxHz: 20_000)
    private var ring: MTLTexture?
    private var heatLUT: MTLTexture?
    private var head = 0                       // next column to write on the GPU
    private var needsClear = true
    private var plot = CGRect.zero
    private var legend = CGRect.zero

    // Automatic top of the color scale.
    private(set) var topDB: Float = -12
    private var topTarget: Float = -12
    private var topSnapped = false
    private var lowerFor: Double = 0, higherFor: Double = 0

    // CPU staging, allocated once.
    private let rowScratch: UnsafeMutablePointer<Float>
    private let composed: UnsafeMutablePointer<Float>
    private let aligner = SpectrogramTimeAligner(rows: SpectrogramRenderer.rows)
    /// Per-resolution history (`SpectrumReading.midLayers`): every layer is delayed on its own, then the column is blended.
    private var layers: [LayerState] = []
    private(set) var usesLayers = false
    private var weightsDigest = 0
    private let blendScratch: UnsafeMutablePointer<Float>      // rows * 2
    /// Column time from which the history has data in every row. Columns before it stay empty; after it the picture fades in.
    private var historyStart: Double?
    static let fadeInSeconds = 0.2
    private var validColumns = 0
    static let maxLayers = 4
    private var clock: Double = 0
    private var nextColumnTime: Double = 0
    /// Seconds between the newest analysis frame and the newest column: the wait for the window center of the lows.
    private(set) var latencySeconds: Double = 0
    private let pending: UnsafeMutablePointer<UInt16>   // maxPending columns
    private var pendingCount = 0
    private var table: ResampleTable?
    /// CPU mirror of the ring for the cursor readout.
    private let mirror: UnsafeMutablePointer<UInt16>
    private var mirrorHead = 0
    private var emittedColumns = 0
    /// Columns since one held anything over the floor. A blank history does not need to scroll.
    private var blankColumns = SpectrogramRenderer.columns

    override init?(ctx: RenderContext, theme: Theme) {
        rowScratch = .allocate(capacity: Self.rows); rowScratch.initialize(repeating: 0, count: Self.rows)
        composed = .allocate(capacity: Self.rows); composed.initialize(repeating: 0, count: Self.rows)
        pending = .allocate(capacity: Self.rows * Self.maxPending); pending.initialize(repeating: 0, count: Self.rows * Self.maxPending)
        mirror = .allocate(capacity: Self.rows * Self.columns); mirror.initialize(repeating: 0, count: Self.rows * Self.columns)
        blendScratch = .allocate(capacity: Self.rows * 2); blendScratch.initialize(repeating: 0, count: Self.rows * 2)
        super.init(ctx: ctx, theme: theme)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: Self.columns, height: Self.rows, mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .private
        ring = ctx.device.makeTexture(descriptor: d)
        ring?.label = "Joseon spectrogram ring"
    }

    deinit { rowScratch.deallocate(); composed.deallocate(); pending.deallocate(); mirror.deallocate(); blendScratch.deallocate() }

    override var kind: PanelKind { .spectrogram }
    override var makesPointerCursors: Bool { true }
    override var needsPrePassPerFrame: Bool { true }
    /// The history scrolls with time, also while the source repeats one frame, until nothing visible is left.
    override var isAnimating: Bool { pendingCount > 0 }

    override func paletteChanged() { heatLUT = ctx.makeLUT(palette.heatLUT()) }

    private var compact: Bool { size.width < 380 || size.height < 170 }

    override func layoutChanged() {
        let left: CGFloat = compact ? 32 : 44
        let right: CGFloat = compact ? 10 : 58
        // A linked panel keeps a header row over the plot for the cursor readout: nothing of it ever covers the history, and
        // the plot does not jump when a cursor comes and goes.
        let top: CGFloat = cursorLinked ? (compact ? 19 : 24) : (compact ? 8 : 12)
        let bottom: CGFloat = compact ? 20 : 26
        plot = CGRect(x: left, y: top, width: max(size.width - left - right, 10), height: max(size.height - top - bottom, 10))
        legend = CGRect(x: plot.maxX + 10, y: plot.minY, width: 14, height: plot.height)
    }

    override var staticSignature: Int {
        var h = Hasher()
        h.combine(super.staticSignature); h.combine(historySeconds); h.combine(floorDB); h.combine(Int(topDB * 4)); h.combine(Int(latencySeconds * 10))
        return h.finalize()
    }
    override var dynamicSignature: Int { 0 }

    private func resetHistory() {
        needsClear = true
        head = 0; pendingCount = 0; mirrorHead = 0; emittedColumns = 0; blankColumns = Self.columns
        aligner.reset(); nextColumnTime = 0
        layers.removeAll(); usesLayers = false; historyStart = nil; weightsDigest = 0; validColumns = 0
        mirror.update(repeating: 0, count: Self.rows * Self.columns)
        needsDisplay = true
    }

    @inline(__always) private func ringValue(_ db: Float) -> Float { min(max((db + 120) / 120, 0), 1) }

    // MARK: History

    override func update(frame f: AnalysisFrame, dt: TimeInterval) {
        let rows = Self.rows
        // Row centers are uniform on the log axis from minHz to maxHz. More rows than bins: interpolation, no smoothing.
        if table == nil || !table!.matches(frequencies: f.spectrum.frequencies, axis: axis, count: rows) {
            table = ResampleTable(frequencies: f.spectrum.frequencies, axis: axis, count: rows)
        }
        if let table, f.spectrum.mid.count >= table.sourceCount {
            table.apply(f.spectrum.mid, minDB: -120, maxDB: 0, into: rowScratch)
        } else {
            rowScratch.update(repeating: 0, count: rows)
        }
        var peak: Float = 0
        vDSP_maxv(rowScratch, 1, &peak, vDSP_Length(rows))
        updateTop(peakDB: peak * 120 - 120, dt: dt)

        // The panel's own clock: host time steps, without the jumps of a paused source.
        clock += dt
        let columnSeconds = historySeconds / Double(Self.columns)
        let minBox = min(max(columnSeconds, 1.0 / 60.0), 0.1)
        let hold = min(dt, 0.05) / 2

        let provided = f.spectrum.midLayers
        let layered = !provided.isEmpty && provided.count <= Self.maxLayers && table != nil
            && provided.allSatisfy { $0.levelsDB.count >= table!.sourceCount && $0.weights.count >= table!.sourceCount }
        if layered != usesLayers || (layered && provided.count != layers.count) {
            // The source changed its kind of data: the delay lines start again. The picture that is drawn stays.
            usesLayers = layered
            layers = layered ? provided.map { _ in LayerState(rows: rows) } : []
            aligner.reset(); weightsDigest = 0
            if historyStart != nil { historyStart = clock; validColumns = 0 }
        }
        if layered, let table {
            pushLayers(provided, table: table, dt: dt, hold: hold)
            latencySeconds = layers.map { $0.aligner.latency(minBox: minBox) }.max() ?? 0
            // Every layer must have shown data once (the long window fills 0.7 s after the start): one left edge, no staircase.
            if historyStart == nil, layers.allSatisfy({ $0.started }) {
                historyStart = layers.compactMap { $0.aligner.earliestCenter(minBox: minBox) }.max()
            }
        } else {
            aligner.configure(minHz: axis.minHz, maxHz: axis.maxHz, sampleRate: f.stream?.sampleRate ?? 48_000)
            aligner.frameHold += (hold - aligner.frameHold) * 0.05
            aligner.push(rowScratch, time: clock)
            latencySeconds = aligner.latency(minBox: minBox)
            if historyStart == nil, peak > 0.004, let first = aligner.firstTime {
                // The analyzer shows its long window only when that has filled once: before that the lows have no data.
                let timing = SpectrumTiming(sampleRate: f.stream?.sampleRate ?? 48_000)
                historyStart = max(aligner.earliestCenter(minBox: minBox) ?? first, first + timing.window.0 / 2 + timing.hop.0)
            }
        }

        // Columns are composed at their own time, all rows on one window-center time.
        let ready = clock - latencySeconds
        if nextColumnTime > ready + columnSeconds * 2 || nextColumnTime < ready - columnSeconds * 8 { nextColumnTime = ready }
        let floorV = ringValue(floorDB)
        while nextColumnTime <= ready {
            let t = nextColumnTime
            nextColumnTime += columnSeconds
            if let start = historyStart, t >= start {
                if layered { composeLayers(centerTime: t, minBox: minBox) } else { aligner.compose(centerTime: t, minBox: minBox, into: composed) }
                // The fade counts the valid columns, not their time: while the layers still measure their hop the latency
                // grows and the column time steps back once. A fade by time started twice: a bright line, a dark gap, then
                // the picture. By count it rises once, from the first valid column.
                validColumns = min(validColumns + 1, 1 << 30)
                let ramp = (Double(validColumns) - 0.5) * columnSeconds / Self.fadeInSeconds
                if ramp < 1 {
                    // Fade in from the floor: v = floor + (v - floor) * k
                    let c = Float(max(ramp, 0)), k = c * c * (3 - 2 * c)
                    var scale = k, offset = floorV * 0.98 * (1 - k)
                    vDSP_vsmsa(composed, 1, &scale, &offset, composed, 1, vDSP_Length(rows))
                }
            } else {
                composed.update(repeating: 0, count: rows)
            }
            var lit = false
            for r in stride(from: 0, to: rows, by: 4) where composed[r] > floorV { lit = true; break }
            blankColumns = lit ? 0 : min(blankColumns + 1, Self.columns * 2)
            // A history with nothing over the floor looks the same after a scroll: skip the work.
            if blankColumns > Self.columns { continue }
            if pendingCount == Self.maxPending {
                // The GPU side fell behind: drop the oldest staged column.
                pending.update(from: pending + rows, count: rows * (Self.maxPending - 1))
                pendingCount -= 1
            }
            let dst = pending + pendingCount * rows
            var lo: Float = 0, hi: Float = 1, k: Float = 65535
            vDSP_vclip(composed, 1, &lo, &hi, composed, 1, vDSP_Length(rows))
            vDSP_vsmul(composed, 1, &k, composed, 1, vDSP_Length(rows))
            vDSP_vfixu16(composed, 1, dst, 1, vDSP_Length(rows))
            pendingCount += 1
            (mirror + mirrorHead * rows).update(from: dst, count: rows)
            mirrorHead = (mirrorHead + 1) % Self.columns
            emittedColumns += 1
        }
    }

    // MARK: Layers

    /// One FFT resolution of the analyzer: its own delay line, its blend weights on the rows, and the measured time between
    /// two of its transforms.
    private final class LayerState {
        let aligner: SpectrogramTimeAligner
        let weights: UnsafeMutablePointer<Float>
        let composed: UnsafeMutablePointer<Float>
        let rows: Int
        var started = false
        var hop = 0.0
        var lastDigest = 0
        var lastChange = -1.0
        var changes = 0
        init(rows: Int) {
            self.rows = rows
            aligner = SpectrogramTimeAligner(rows: rows, capacity: 64)
            weights = .allocate(capacity: rows); weights.initialize(repeating: 0, count: rows)
            composed = .allocate(capacity: rows); composed.initialize(repeating: 0, count: rows)
        }
        deinit { weights.deallocate(); composed.deallocate() }
    }

    private static func sparseDigest(_ v: [Float], step: Int) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        var i = 0
        while i < v.count { h = (h ^ UInt64(v[i].bitPattern)) &* 0x100000001b3; i += step }
        return Int(truncatingIfNeeded: h)
    }

    private func pushLayers(_ provided: [SpectrumLayer], table: ResampleTable, dt: Double, hold: Double) {
        let rows = Self.rows
        // Blend weights on the rows. They change only when the analyzer is reconfigured.
        var wd = provided.count
        for l in provided { wd = wd &* 31 &+ Self.sparseDigest(l.weights, step: 29) }
        if wd != weightsDigest {
            weightsDigest = wd
            for (k, l) in provided.enumerated() { table.apply(l.weights, minDB: 0, maxDB: 1, into: layers[k].weights) }
            // Rows must sum to 1 after the resampling too. A row without any weight takes the last (finest) layer.
            for r in 0..<rows {
                var sum: Float = 0
                for l in layers { sum += l.weights[r] }
                if sum > 1e-4 { for l in layers { l.weights[r] /= sum } } else { for (k, l) in layers.enumerated() { l.weights[r] = k == layers.count - 1 ? 1 : 0 } }
            }
        }
        for (k, l) in provided.enumerated() {
            let state = layers[k]
            table.apply(l.levelsDB, minDB: -120, maxDB: 0, into: rowScratch)
            if !state.started {
                var top: Float = 0
                vDSP_maxv(rowScratch, 1, &top, vDSP_Length(rows))
                guard top > 0.004 else { continue }          // nothing over the floor yet: this resolution has no data
                state.started = true
            }
            // Time between two transforms of this resolution, from the data: the levels stand still between transforms.
            let digest = Self.sparseDigest(l.levelsDB, step: 37)
            if digest != state.lastDigest {
                if state.lastChange >= 0 {
                    let interval = min(clock - state.lastChange, 0.25)
                    state.changes += 1
                    state.hop += (interval - state.hop) / Double(min(state.changes, 8))
                }
                state.lastDigest = digest; state.lastChange = clock
            }
            let latency = Double(max(l.latencySeconds, 0))
            let hop = (min(max(state.hop, dt), max(latency, dt)) * 500).rounded() / 500
            // A frame shows the newest transform, which is half a hop old on average.
            state.aligner.configureUniform(lag: latency + hop / 2, hop: hop)
            state.aligner.frameHold += (hold - state.aligner.frameHold) * 0.05
            state.aligner.push(rowScratch, time: clock)
        }
    }

    /// One column at `centerTime`: every layer at its own delay, blended in the power domain with the layer weights.
    private func composeLayers(centerTime: Double, minBox: Double) {
        let rows = Self.rows, vn = vDSP_Length(rows)
        var cnt = Int32(rows)
        let acc = blendScratch, tmp = blendScratch + rows
        vDSP_vclr(acc, 1, vn)
        // Ring value v (0...1 = -120...0 dB) to power: exp(ln 10 * 12 * (v - 1)).
        var a = Float(M_LN10 * 12), b = -Float(M_LN10 * 12)
        for l in layers {
            l.aligner.compose(centerTime: centerTime, minBox: minBox, into: l.composed)
            vDSP_vsmsa(l.composed, 1, &a, &b, tmp, 1, vn)
            vvexpf(tmp, tmp, &cnt)
            vDSP_vma(tmp, 1, l.weights, 1, acc, 1, acc, 1, vn)
        }
        var tiny: Float = 1e-13
        vDSP_vthr(acc, 1, &tiny, acc, 1, vn)
        vvlogf(composed, acc, &cnt)
        var inv = 1 / Float(M_LN10 * 12), one: Float = 1
        vDSP_vsmsa(composed, 1, &inv, &one, composed, 1, vn)
    }

    /// The top of the color scale follows the loudest partial: up fast, down slowly, on a 6 dB grid.
    private func updateTop(peakDB: Float, dt: TimeInterval) {
        guard peakDB > floorDB else { return }
        let want = min(max(((peakDB + 2) / 6).rounded(.up) * 6, -42), 0)
        if !topSnapped { topSnapped = true; topDB = want; topTarget = want; return }
        if want > topTarget { higherFor += dt; lowerFor = 0 } else if want < topTarget { lowerFor += dt; higherFor = 0 } else { higherFor = 0; lowerFor = 0 }
        if higherFor > 0.4 || lowerFor > 8 { topTarget = want; higherFor = 0; lowerFor = 0 }
        if topDB != topTarget {
            topDB += (topTarget - topDB) * Float(1 - exp(-dt / 0.5))
            if abs(topTarget - topDB) < 0.05 { topDB = topTarget }
            needsDisplay = true
        }
    }

    override func encodePrePass(_ cb: MTLCommandBuffer) {
        guard let ring else { return }
        if needsClear {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = ring
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            needsClear = false
        }
        guard pendingCount > 0 else { return }
        let rows = Self.rows
        guard let staged = arena.allocate(UInt16.self, count: rows * pendingCount),
              let blit = cb.makeBlitCommandEncoder() else { return }
        staged.pointer.update(from: pending, count: rows * pendingCount)
        for i in 0..<pendingCount {
            blit.copy(from: arena.buffer, sourceOffset: staged.offset + i * rows * 2, sourceBytesPerRow: 2,
                      sourceBytesPerImage: rows * 2, sourceSize: MTLSize(width: 1, height: rows, depth: 1),
                      to: ring, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: head, y: 0, z: 0))
            head = (head + 1) % Self.columns
        }
        blit.endEncoding()
        pendingCount = 0
    }

    // MARK: Metal

    private func y(forHz hz: Float) -> Float { Float(plot.maxY) - axis.position(hz) * Float(plot.height) }

    private var timeStep: Double {
        for s in [1, 2, 5, 10, 15, 30, 60] as [Double] where historySeconds / s <= (compact ? 4 : 8) { return s }
        return 120
    }

    override func draw(_ enc: MTLRenderCommandEncoder, globals g: inout Globals) {
        let p = palette
        let px = Float(plot.minX), py = Float(plot.minY), pw = Float(plot.width), ph = Float(plot.height)
        guard let ring, let heatLUT else { return }

        var rect = SIMD4<Float>(px, py, pw, ph)
        var u = SpectrogramUniforms(rect: rect, head: Float(head), columns: Float(Self.columns), floorV: ringValue(floorDB),
                                    gamma: gamma, topV: ringValue(topDB))
        enc.setRenderPipelineState(ctx.spectrogram)
        enc.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
        enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<SpectrogramUniforms>.stride, index: 3)
        enc.setFragmentTexture(ring, index: 0)
        enc.setFragmentTexture(heatLUT, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Reading lines over the heat map: light enough to vanish behind bright content.
        let line = SIMD4<Float>(1, 1, 1, p.highContrast ? 0.22 : 0.07)
        for f in LogAxis.labeled where f > axis.minHz && f < axis.maxHz {
            batch.hline(px, px + pw, y(forHz: f), color: line)
        }
        let step = timeStep
        var t = step
        while t < historySeconds - 0.001 {
            let tx = px + pw * Float(1 - (t - latencySeconds) / historySeconds)
            if tx < px + pw - 1 { batch.vline(tx, py, py + ph, color: line) }
            t += step
        }
        // Frame.
        batch.rect(px - 0.5, py - 0.5, pw + 1, ph + 1, color: p.gridMajor, radius: 2, stroke: 1)

        if cursorLinked {
            // The shared cursor: the frequency as a horizontal hairline from this panel's axis; the time, when it has one.
            if let c = cursor, c.frequencyHz >= axis.minHz, c.frequencyHz <= axis.maxHz {
                // Over a heat map a 1 px line of any one color is lost somewhere: a dark 3 px bed under it keeps it readable
                // on yellow and on blue.
                let bed = SIMD4<Float>(0, 0, 0, 0.38), yy = y(forHz: c.frequencyHz)
                let tx = cursorTimeX(c).map { Float($0) }
                if let tx { batch.vline(tx, py, py + ph, color: bed, pixels: 3) }
                batch.hline(px, px + pw, yy, color: bed, pixels: 3)
                if let tx { batch.vline(tx, py, py + ph, color: cursorLineColor) }
                drawCursorHorizontal(y: yy, left: px, right: px + pw)
            }
        } else if let hv = hover, plot.contains(hv) {
            let c = SIMD4<Float>(1, 1, 1, 0.6)
            batch.vline(Float(hv.x), py, py + ph, color: c)
            batch.hline(px, px + pw, Float(hv.y), color: c)
        }
        if !compact {
            // Ticks of the color bar.
            for db in legendTicks {
                let yy = Float(legendY(db))
                batch.hline(Float(legend.maxX), Float(legend.maxX) + 4, yy, color: p.textFaint)
            }
            batch.hline(Float(legend.maxX), Float(legend.maxX) + 4, Float(legend.minY) + 0.5, color: p.textFaint)
        }
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)

        if !compact {
            batch.rect(Float(legend.minX), Float(legend.minY), Float(legend.width), Float(legend.height),
                       top: SIMD4(1, 1, 1, 1), bottom: SIMD4(gamma, 0, 0, 1), radius: 2)
            batch.flush(enc, pipeline: ctx.shapeLUT, globals: &g, lut: heatLUT)
            batch.rect(Float(legend.minX) - 0.5, Float(legend.minY) - 0.5, Float(legend.width) + 1, Float(legend.height) + 1, color: p.gridMajor, radius: 2, stroke: 1)
            batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
        }
    }

    /// Ticks on the color bar: multiples of 15 dB only (-75, -60, -45, -30, -15, 0), evenly spaced. The automatic top is
    /// not a tick of its own: an odd number between two even ones made the scale hard to read.
    private var legendTicks: [Float] {
        var out: [Float] = []
        var db = (floorDB / 15).rounded(.up) * 15
        while db <= topDB + 0.01, out.count < 8 { out.append(db); db += 15 }
        return out
    }
    private func legendY(_ db: Float) -> CGFloat {
        legend.maxY - CGFloat((db - floorDB) / max(topDB - floorDB, 1)) * legend.height
    }

    // MARK: Text

    override func drawStatic(_ o: OverlayContext) {
        let p = palette
        let small = Fonts.mono(compact ? 10 : 11)
        var lastTop = CGFloat.greatestFiniteMagnitude
        for f in LogAxis.labeled where f >= axis.minHz && f <= axis.maxHz {
            var yy = CGFloat(y(forHz: f))
            yy = min(max(yy, plot.minY + 5), plot.maxY - 5)
            guard lastTop - yy > 13 else { continue }
            o.text(Fmt.axisHz(f), x: plot.minX - 7, y: yy, font: small, color: p.textDim, h: .right, v: .middle)
            lastTop = yy
        }
        if !compact { o.text("Hz", x: plot.minX - 7, y: plot.maxY + 7, font: small, color: p.textFaint, h: .right, v: .top) }
        let step = timeStep
        var t = 0.0
        while t < historySeconds + 0.001 {
            // The newest column is `latencySeconds` old (the wait for the window center of the lows): ticks sit at true times.
            let xx = t == 0 ? plot.maxX : plot.minX + plot.width * CGFloat(1 - (t - latencySeconds) / historySeconds)
            let label = t == 0 ? "now" : "\(Fmt.minus)\(Int(t)) s"
            let align: HAlign = t == 0 ? .right : .center
            // Not on top of the "Hz" corner label.
            if xx > plot.minX + 34 || t == 0 {
                o.text(label, x: t == 0 ? plot.maxX : xx, y: plot.maxY + 7, font: small, color: t == 0 ? p.text : p.textDim, h: align, v: .top)
            }
            t += step
        }
        if !compact {
            let lx = legend.maxX + 7
            // The top of the scale has its own label (the level of the brightest color). A 15 dB tick too close to it gives way.
            let topY = legend.minY + 5
            o.text(Fmt.number(topDB.rounded(), digits: 0), x: lx, y: topY, font: small, color: p.text, v: .middle)
            for db in legendTicks {
                let yy = min(max(legendY(db), legend.minY + 5), legend.maxY - 5)
                guard yy - topY > 13 else { continue }
                o.text(Fmt.number(db, digits: 0), x: lx, y: yy, font: small, color: p.textDim, v: .middle)
            }
            o.text("dB", x: legend.minX, y: plot.maxY + 7, font: small, color: p.textFaint, v: .top)
        }
    }

    // MARK: Linked cursor

    /// x of the cursor's time inside the plot, nil without a time or outside the history shown.
    private func cursorTimeX(_ c: PanelCursor) -> CGFloat? {
        guard let ago = c.secondsAgo, plot.width > 1 else { return nil }
        let x = plot.maxX - CGFloat((ago - latencySeconds) / historySeconds) * plot.width
        return x >= plot.minX - 0.5 && x <= plot.maxX + 0.5 ? min(max(x, plot.minX), plot.maxX) : nil
    }

    /// Seconds between two columns of the history.
    var columnSeconds: Double { historySeconds / Double(Self.columns) }
    /// Age of the newest column: a timed cursor cannot be newer.
    var newestSecondsAgo: Double { latencySeconds }

    override func cursor(at point: CGPoint) -> PanelCursor? {
        guard plot.contains(point), plot.width > 1 else { return nil }
        let hz = axis.frequency(Float((plot.maxY - point.y) / plot.height))
        let ago = Double((plot.maxX - point.x) / plot.width) * historySeconds + latencySeconds
        return PanelCursor(frequencyHz: hz, secondsAgo: ago, source: .spectrogram)
    }

    override func isOnCursor(_ point: CGPoint) -> Bool {
        guard let c = cursor, plot.contains(point) else { return false }
        if abs(CGFloat(y(forHz: c.frequencyHz)) - point.y) <= 5 { return true }
        if let tx = cursorTimeX(c), abs(tx - point.x) <= 5 { return true }
        return false
    }

    /// Frequencies of the history rows: uniform on the log axis, 20 Hz ... 20 kHz.
    private(set) lazy var rowFrequencies: [Float] = (0..<Self.rows).map { axis.frequency(Float($0) / Float(Self.rows - 1)) }

    /// Columns between the newest column and the one `secondsAgo` old. Nil outside the recorded history.
    private func columnsBack(secondsAgo: Double) -> Int? {
        let back = Int(((secondsAgo - latencySeconds) / historySeconds * Double(Self.columns - 1)).rounded())
        guard back >= 0, back < emittedColumns, back < Self.columns else { return nil }
        return back
    }

    /// The column under a time, from the CPU copy of the history. `id` counts columns since the start: equal ids = the same
    /// column. The copy holds the ROWS of the ring texture (1024 rows uniform on the log axis, a little finer than the
    /// analyzer's display bins, already time-aligned and blended from the resolution layers). The frames' own bins are not
    /// kept, so the slice carries the rows with the row frequencies.
    func historyColumn(secondsAgo: Double) -> (id: Int, slice: CursorHistorySlice)? {
        guard let back = columnsBack(secondsAgo: secondsAgo) else { return nil }
        let col = ((mirrorHead - 1 - back) % Self.columns + Self.columns) % Self.columns
        let src = mirror + col * Self.rows
        let db = (0..<Self.rows).map { Float(src[$0]) / 65535 * 120 - 120 }
        return (emittedColumns - 1 - back, CursorHistorySlice(secondsAgo: secondsAgo, frequencies: rowFrequencies, midDB: db))
    }
    /// The id alone (no copy): the view asks every tick and copies only a new column.
    func historyColumnID(secondsAgo: Double) -> Int? { columnsBack(secondsAgo: secondsAgo).map { emittedColumns - 1 - $0 } }

    /// Mid level at the cursor: with a time, from the history column (the same interpolation the spectrum's "then" number
    /// uses on the published slice); without, from the newest frame, like every other panel.
    private func cursorLevel(_ c: PanelCursor) -> (db: Float?, hasData: Bool) {
        guard let ago = c.secondsAgo else {
            guard let f = frame else { return (nil, false) }
            return (CursorMath.level(of: f.spectrum.mid, frequencies: f.spectrum.frequencies, atHz: c.frequencyHz), true)
        }
        guard let back = columnsBack(secondsAgo: ago) else { return (nil, false) }
        let col = ((mirrorHead - 1 - back) % Self.columns + Self.columns) % Self.columns
        let pos = axis.position(c.frequencyHz) * Float(Self.rows - 1)
        guard pos >= 0, pos <= Float(Self.rows - 1) else { return (nil, true) }
        let i = min(Int(pos), Self.rows - 2), t = pos - Float(i)
        let a = Float(mirror[col * Self.rows + i]) / 65535 * 120 - 120, b = Float(mirror[col * Self.rows + i + 1]) / 65535 * 120 - 120
        return (a * (1 - t) + b * t, true)
    }

    private func levelText(_ c: PanelCursor) -> String {
        let l = cursorLevel(c)
        guard l.hasData, let db = l.db else { return "no data" }
        return c.secondsAgo != nil && db <= floorDB ? "Mid under \(Fmt.number(floorDB, digits: 0)) dB" : "Mid \(Fmt.db(db)) dB"
    }

    override func cursorItems() -> [CursorReadoutItem] {
        guard let c = cursor else { return [] }
        // In this panel the time is the second most important part: it is what the panel adds.
        var items = [CursorReadoutItem(text: CursorMath.hz(c.frequencyHz), rank: 0)]
        if let n = CursorMath.note(c.frequencyHz) { items.append(.init(text: n, rank: 3, tone: .dim)) }
        if let ago = c.secondsAgo { items.append(.init(text: CursorMath.ago(ago), rank: 1, tone: .ghost)) }
        items.append(.init(text: levelText(c), rank: 2))
        return items
    }

    override func drawDynamic(_ o: OverlayContext) {
        guard showsHeaderReadout else { return }
        CursorHeader.draw(o, items: cursorItems(), right: plot.maxX, left: plot.minX, midY: plot.minY - (compact ? 9 : 11), compact: compact,
                          pinned: cursor?.isPinned == true, palette: palette)
    }

    /// y of a frequency on this panel's axis and the plot, for tests.
    func yForTesting(hz: Float) -> CGFloat { CGFloat(y(forHz: hz)) }
    var plotRectForTesting: CGRect { plot }
    func xForTesting(secondsAgo: Double) -> CGFloat { plot.maxX - CGFloat((secondsAgo - latencySeconds) / historySeconds) * plot.width }

    /// Level of the history cell under a point of the plot, nil where nothing was recorded yet.
    func historyLevel(at point: CGPoint) -> Float? {
        guard plot.contains(point), plot.width > 1 else { return nil }
        let ago = Double((plot.maxX - point.x) / plot.width) * Double(Self.columns - 1)
        let back = Int(ago.rounded())
        guard back < emittedColumns, back < Self.columns else { return nil }
        let col = ((mirrorHead - 1 - back) % Self.columns + Self.columns) % Self.columns
        let t = Float((plot.maxY - point.y) / plot.height)
        let row = min(max(Int((t * Float(Self.rows - 1)).rounded()), 0), Self.rows - 1)
        // A pixel of the view covers a few cells: report the strongest, like the eye does.
        var v: UInt16 = 0
        for r in max(row - 1, 0)...min(row + 1, Self.rows - 1) { v = max(v, mirror[col * Self.rows + r]) }
        return Float(v) / 65535 * 120 - 120
    }

    /// Tick values of the color bar, for tests.
    var legendTicksForTesting: [Float] { legendTicks }
    /// The color a level gets with the current floor, top and gamma (same math as the shader), for tests.
    func colorForTesting(db: Float) -> SIMD3<Float> {
        let lut = palette.heatLUT()
        let t = db <= floorDB ? 0 : pow(min(max((db - floorDB) / max(topDB - floorDB, 1e-3), 0), 1), gamma)
        return lut[min(Int((t * 255).rounded()), 255)]
    }

    /// Window-center time of the newest column on the panel's clock (which starts at 0 and adds the frame steps). For tests.
    var newestColumnTime: Double { nextColumnTime - historySeconds / Double(Self.columns) }

    /// Level in dB of a history cell: `columnsBack` = 0 is the newest column. Nil where nothing was recorded. For tests.
    func historyLevel(columnsBack back: Int, hz: Float) -> Float? {
        guard back >= 0, back < emittedColumns, back < Self.columns else { return nil }
        let col = ((mirrorHead - 1 - back) % Self.columns + Self.columns) % Self.columns
        let row = min(max(Int((axis.position(hz) * Float(Self.rows - 1)).rounded()), 0), Self.rows - 1)
        return Float(mirror[col * Self.rows + row]) / 65535 * 120 - 120
    }

    override func hoverLabel() -> (lines: [String], anchor: CGPoint)? {
        if cursorLinked {
            guard showsPointerReadout, let hv = hover, plot.contains(hv), let c = cursor else { return nil }
            var first = CursorMath.hz(c.frequencyHz)
            if let n = CursorMath.note(c.frequencyHz) { first += "   \(n)" }
            return ([first, (c.secondsAgo.map { CursorMath.ago($0) + "   " } ?? "") + levelText(c)], hv)
        }
        guard let hv = hover, plot.contains(hv) else { return nil }
        let hz = axis.frequency(Float((plot.maxY - hv.y) / plot.height))
        let ago = Double((plot.maxX - hv.x) / plot.width) * historySeconds + latencySeconds
        var first = "cursor  \(Fmt.hz(hz))"
        if let n = Fmt.note(forHz: hz) { first += "   \(n.name) \(Fmt.cents(n.cents))" }
        let time = ago < 0.05 ? "now" : "\(Fmt.minus)\(String(format: "%.1f", ago)) s"
        var second = "time  \(time)"
        if let level = historyLevel(at: hv) {
            second += level <= floorDB ? "   Mid  under \(Fmt.number(floorDB, digits: 0)) dB" : "   Mid  \(Fmt.db(level)) dB"
        } else {
            second += "   no data"
        }
        return ([first, second], hv)
    }

    override var accessibilityLabelText: String { "Spectrogram" }
    override var accessibilityValueText: String {
        guard let f = frame, !f.isSilent, !Fmt.isFloor(f.peak.levelDB) else { return "\(Int(historySeconds)) seconds of history. No signal" }
        return "\(Int(historySeconds)) seconds of history. Strongest now: \(Fmt.hz(f.peak.frequencyHz)) at \(String(format: "%.1f", f.peak.levelDB)) dB"
    }
}
