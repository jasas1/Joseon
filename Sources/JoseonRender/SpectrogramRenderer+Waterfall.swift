import AppKit
import Metal
import simd
import JoseonCore

/// The spectrogram as a 3-D field: frequency across, time into the depth, level as height.
public enum SpectrogramMode: String, CaseIterable, Sendable {
    /// The scrolling heat map.
    case flat
    /// Bars in perspective, the newest row in front, the past receding into the fog. Same history, same dB scale.
    case waterfall
}

/// Everything the waterfall adds to the spectrogram renderer: the field texture, the pictures, the camera.
final class WaterfallState {
    /// Frequency columns of the field.
    var bins = 160
    /// Time rows of the field: the whole history, newest in front.
    var depth = 160
    /// bins × depth, R16: the ring folded (max over the rows a column covers, mean over the columns a row covers).
    var field: MTLTexture?
    /// The picture of the field at the plot's pixel size, resolved from the multisampled pass.
    var color: MTLTexture?
    var msaaColor: MTLTexture?
    var msaaDepth: MTLTexture?
    var pixelSize = (width: 0, height: 0)
    var hueLUT: MTLTexture?
    /// The camera: a slow sway, and the pointer tilts it a little. A drag orbits it freely (any yaw, over the floor),
    /// a scroll or a pinch zooms, and a reset goes back to the resting view.
    var yaw: Float = 0
    var elevation: Float = 0.56
    var tilt = SIMD2<Float>(0, 0)
    var tiltTarget = SIMD2<Float>(0, 0)
    var clock: Double = 0
    /// The view the user turned to. Nil = the resting view with its sway.
    var userView: (yaw: Float, elevation: Float)?
    var zoom: Float = 1
    /// False when the dB scale's numbers would land on other labels (a view from the side): the scale is left out.
    var scaleShown = true
    static let restYaw: Float = -14 * .pi / 180
    static let elevationRange: ClosedRange<Float> = 0.10...1.48
    static let zoomRange: ClosedRange<Float> = 0.6...2.6
    var viewProj = matrix_identity_float4x4
    var invViewProj = matrix_identity_float4x4
    /// World units between two time rows; the cells are one unit wide.
    var depthStep: Float = 0.8
    /// World units of a bar at the top of the scale. A low plot gets shorter bars, so the field keeps its width.
    var height: Float = 20
    /// The camera's angle over the floor at rest: flatter for a low, wide plot.
    var baseElevation: Float = 0.56
    /// Camera distance that fits the near row into the plot, found for the resting camera (no sway, no tilt).
    var distance: Float = 120
    static let fieldOfView: Float = 0.72
    static let tallElevation: Float = 0.56
    static let lowElevation: Float = 0.40
    static let swayAmplitude: Float = 3.5 * .pi / 180
    static let swayPeriod: Double = 60
    static let tiltYaw: Float = 12 * .pi / 180
    static let tiltElevation: Float = 4 * .pi / 180
}

extension SpectrogramRenderer {
    // MARK: Camera

    /// Moves the camera: the sway with the clock, the tilt toward the pointer with a 150 ms time constant.
    func stepCamera(dt: TimeInterval) {
        guard mode == .waterfall else { return }
        let w = waterfall
        let before = (w.yaw, w.elevation)
        w.clock += max(dt, 0)
        if let hv = hover, plot.width > 1, plot.height > 1, !reduceMotion {
            let x = Float((hv.x - plot.midX) / (plot.width / 2)), y = Float((hv.y - plot.midY) / (plot.height / 2))
            w.tiltTarget = SIMD2(min(max(x, -1), 1), min(max(y, -1), 1))
        } else {
            w.tiltTarget = .zero
        }
        let k = reduceMotion ? 1 : Float(1 - exp(-dt / 0.15))
        w.tilt += (w.tiltTarget - w.tilt) * k
        if simd_length(w.tilt - w.tiltTarget) < 0.002 { w.tilt = w.tiltTarget }
        let sway = reduceMotion || w.userView != nil ? 0 : Float(sin(w.clock * 2 * .pi / WaterfallState.swayPeriod)) * WaterfallState.swayAmplitude
        let base = w.userView ?? (yaw: WaterfallState.restYaw, elevation: w.baseElevation)
        w.yaw = base.yaw + sway + w.tilt.x * WaterfallState.tiltYaw
        w.elevation = min(max(base.elevation - w.tilt.y * WaterfallState.tiltElevation, 0.06), 1.52)
        updateCamera()
        if before != (w.yaw, w.elevation) { needsDisplay = true }
    }

    /// True while the camera moves on its own or still eases toward the pointer.
    var waterfallAnimating: Bool {
        guard mode == .waterfall else { return false }
        return (!reduceMotion && waterfall.userView == nil) || waterfall.tilt != waterfall.tiltTarget
    }

    /// Turns the view by the angles (radians). The elevation stays over the floor; the yaw is free.
    func orbit(yawBy dYaw: Float, elevationBy dElevation: Float) {
        guard mode == .waterfall else { return }
        let w = waterfall
        let current = w.userView ?? (yaw: w.yaw - w.tilt.x * WaterfallState.tiltYaw, elevation: w.elevation + w.tilt.y * WaterfallState.tiltElevation)
        var yaw = (current.yaw + dYaw).truncatingRemainder(dividingBy: 2 * .pi)
        if yaw > .pi { yaw -= 2 * .pi } else if yaw < -.pi { yaw += 2 * .pi }
        let elevation = min(max(current.elevation + dElevation, WaterfallState.elevationRange.lowerBound), WaterfallState.elevationRange.upperBound)
        w.userView = (yaw, elevation)
        stepCamera(dt: 0)
        needsDisplay = true
    }

    /// Multiplies the zoom (2 = twice as close).
    func zoom(by factor: Float) {
        guard mode == .waterfall, factor.isFinite, factor > 0 else { return }
        let w = waterfall
        w.zoom = min(max(w.zoom * factor, WaterfallState.zoomRange.lowerBound), WaterfallState.zoomRange.upperBound)
        stepCamera(dt: 0)
        needsDisplay = true
    }

    /// Back to the resting view, with its sway.
    func resetView() {
        let w = waterfall
        w.userView = nil
        w.zoom = 1
        stepCamera(dt: 0)
        needsDisplay = true
    }

    /// True when the user turned or zoomed the view.
    var hasCustomView: Bool { waterfall.userView != nil || waterfall.zoom != 1 }

    /// Sets the view outright (offscreen renders and tests). Nil = the resting view.
    func setView(yaw: Float?, elevation: Float?, zoom: Float = 1) {
        let w = waterfall
        if let yaw, let elevation { w.userView = (yaw, elevation) } else { w.userView = nil }
        w.zoom = min(max(zoom, WaterfallState.zoomRange.lowerBound), WaterfallState.zoomRange.upperBound)
        stepCamera(dt: 0)
    }

    func updateCamera() {
        let w = waterfall
        w.distance = fittedDistance(yaw: w.yaw, elevation: w.elevation) / w.zoom
        w.viewProj = cameraMatrix(yaw: w.yaw, elevation: w.elevation, distance: w.distance)
        w.invViewProj = w.viewProj.inverse
    }

    /// The view-projection of a camera on the orbit: `distance` from the aim point, which sits a little over the floor
    /// in the middle of the depth.
    private func cameraMatrix(yaw: Float, elevation: Float, distance: Float) -> simd_float4x4 {
        let w = waterfall
        let aspect = Float(max(plot.width, 1) / max(plot.height, 1))
        let at = SIMD3<Float>(0, w.height * 0.12, -Float(w.depth) * w.depthStep * 0.5)
        let eye = at + SIMD3<Float>(sin(yaw) * distance * cos(elevation), sin(elevation) * distance, cos(yaw) * distance * cos(elevation))
        let proj = Self.perspective(fovY: WaterfallState.fieldOfView, aspect: aspect, near: 1, far: distance * 4 + Float(w.depth) * w.depthStep)
        return proj * Self.lookAt(eye: eye, at: at, up: SIMD3(0, 1, 0))
    }

    /// The nearest camera distance at which the field fits the plot from this angle: the near row with its labels and a
    /// bar of full height stay inside; the far corners may leave the top a little (the fog takes them anyway). A card
    /// too narrow for the whole width shows the middle of the field (the distance is capped).
    func fittedDistance(yaw: Float, elevation: Float) -> Float {
        let w = waterfall
        let bins = Float(w.bins), far = -(Float(w.depth) + 1) * w.depthStep
        let near: [SIMD3<Float>] = [SIMD3(-bins * 0.5 - 4, 0, 2.2), SIMD3(bins * 0.5 + 4, 0, 2.2),
                                   SIMD3(0, w.height, 0), SIMD3(bins * 0.5 + 3, w.height, 0.3), SIMD3(-bins * 0.5 - 3, w.height, 0.3)]
        let farCorners: [SIMD3<Float>] = [SIMD3(-bins * 0.5 - 2, 0, far), SIMD3(bins * 0.5 + 2, 0, far)]
        // The row of frequency labels under the near edge needs 26 pt of the plot, whatever its height.
        let bottom = -1 + Float(2 * 26 / max(plot.height, 60))
        let checks = near.map { ($0, Float(0.93), Float(0.97)) } + farCorners.map { ($0, Float(1.0), Float(1.12)) }
        func fits(_ d: Float) -> Bool {
            let m = cameraMatrix(yaw: yaw, elevation: elevation, distance: d)
            for (p, xBound, yTop) in checks {
                let c = m * SIMD4(p, 1)
                guard c.w > 1e-4 else { return false }
                let nx = c.x / c.w, ny = c.y / c.w
                if abs(nx) > xBound || ny < bottom || ny > yTop { return false }
            }
            return true
        }
        var lo = bins * 0.3, hi = bins * 3
        if fits(lo) { return lo }
        if !fits(hi) { return hi }
        for _ in 0..<22 {
            let mid = (lo + hi) / 2
            if fits(mid) { hi = mid } else { lo = mid }
        }
        return min(hi, bins * 1.8)
    }

    /// Metal clip space: z from 0 (near) to 1 (far).
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let f = 1 / tan(fovY / 2)
        return simd_float4x4(columns: (SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0),
                                       SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)))
    }

    static func lookAt(eye: SIMD3<Float>, at: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - at), x = simd_normalize(simd_cross(up, z)), y = simd_cross(z, x)
        return simd_float4x4(columns: (SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0), SIMD4(x.z, y.z, z.z, 0),
                                       SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
    }

    /// A world point of the field in panel points (top-left origin). Nil behind the camera.
    func project(_ p: SIMD3<Float>) -> CGPoint? {
        let c = waterfall.viewProj * SIMD4(p, 1)
        guard c.w > 1e-4 else { return nil }
        let nx = c.x / c.w, ny = c.y / c.w
        return CGPoint(x: plot.minX + CGFloat(nx + 1) / 2 * plot.width, y: plot.minY + CGFloat(1 - ny) / 2 * plot.height)
    }

    /// The field cell under a point of the plot: the ray through the point meets the plane of the bar tops at 40 % of the
    /// scale. Nil outside the field.
    func fieldCell(at point: CGPoint) -> (bin: Int, row: Int, x: Float, z: Float)? {
        guard plot.contains(point), plot.width > 1, plot.height > 1 else { return nil }
        let w = waterfall
        let nx = Float((point.x - plot.minX) / plot.width) * 2 - 1
        let ny = 1 - Float((point.y - plot.minY) / plot.height) * 2
        let a = w.invViewProj * SIMD4(nx, ny, 0, 1), b = w.invViewProj * SIMD4(nx, ny, 1, 1)
        guard abs(a.w) > 1e-6, abs(b.w) > 1e-6 else { return nil }
        let p0 = SIMD3(a.x, a.y, a.z) / a.w, p1 = SIMD3(b.x, b.y, b.z) / b.w
        let d = p1 - p0
        guard abs(d.y) > 1e-6 else { return nil }
        let t = (w.height * 0.4 - p0.y) / d.y
        guard t > 0 else { return nil }
        let x = p0.x + d.x * t, z = p0.z + d.z * t
        let bin = Int((x + Float(w.bins) * 0.5).rounded(.down))
        let row = Int((-z / w.depthStep + 0.5).rounded(.down))
        guard bin >= 0, bin < w.bins, row >= 0, row < w.depth else { return nil }
        return (bin, row, x, z)
    }

    /// World x of a frequency and world z of a time, on the field's own axes.
    func fieldX(hz: Float) -> Float { axis.position(hz) * Float(waterfall.bins) - Float(waterfall.bins) * 0.5 }
    func fieldRow(secondsAgo ago: Double) -> Float { Float((ago - latencySeconds) / historySeconds) * Float(waterfall.depth) - 0.5 }
    func fieldZ(secondsAgo ago: Double) -> Float { -fieldRow(secondsAgo: ago) * waterfall.depthStep }
    func fieldBin(hz: Float) -> Float { axis.position(hz) * Float(waterfall.bins) - 0.5 }

    // MARK: Textures

    func waterfallLayoutChanged() {
        let w = waterfall
        guard mode == .waterfall else { return }
        let wanted = plot.width > 1200 ? 240 : 160
        if w.depth != wanted { w.depth = wanted; w.field = nil }
        // A low plot: shorter bars and a flatter camera, so the field spreads across the width instead of shrinking.
        let plotHeight = Float(plot.height), aspect = plotHeight / Float(max(plot.width, 1))
        w.height = 20 * min(max(plotHeight / 420, 0.5), 1)
        let k = min(max((aspect - 0.2) / 0.2, 0), 1)
        w.baseElevation = WaterfallState.lowElevation + (WaterfallState.tallElevation - WaterfallState.lowElevation) * k
        let pw = max(Int((plot.width * scale).rounded()), 1), ph = max(Int((plot.height * scale).rounded()), 1)
        if w.color == nil || w.pixelSize.width != pw || w.pixelSize.height != ph {
            w.pixelSize = (pw, ph)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderContext.targetFormat, width: pw, height: ph, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            w.color = ctx.device.makeTexture(descriptor: d)
            w.color?.label = "Joseon waterfall"
            let m = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderContext.targetFormat, width: pw, height: ph, mipmapped: false)
            m.textureType = .type2DMultisample
            m.sampleCount = RenderContext.waterfallSamples
            m.usage = .renderTarget
            m.storageMode = .memoryless
            w.msaaColor = ctx.device.makeTexture(descriptor: m)
            let z = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderContext.waterfallDepthFormat, width: pw, height: ph, mipmapped: false)
            z.textureType = .type2DMultisample
            z.sampleCount = RenderContext.waterfallSamples
            z.usage = .renderTarget
            z.storageMode = .memoryless
            w.msaaDepth = ctx.device.makeTexture(descriptor: z)
        }
        if w.field == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderContext.fieldFormat, width: w.bins, height: w.depth, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            w.field = ctx.device.makeTexture(descriptor: d)
            w.field?.label = "Joseon waterfall field"
        }
        if w.hueLUT == nil { waterfallPaletteChanged() }
        stepCamera(dt: 0)
    }

    func waterfallPaletteChanged() {
        waterfall.hueLUT = ctx.makeLUT(palette.spectrumLUT())
    }

    /// Hue LUT positions of the field's lowest and highest frequency (the LUT runs 10 Hz ... 24 kHz).
    private var huePositions: (lo: Float, hi: Float) {
        let lo = log(axis.minHz / 10) / log(Float(2400)), hi = log(axis.maxHz / 10) / log(Float(2400))
        return (min(max(lo, 0), 1), min(max(hi, 0), 1))
    }

    // MARK: Passes

    /// The lit column and row: the shared cursor when there is one, else the pointer.
    private var litCell: (bin: Float, row: Float) {
        if cursorLinked {
            guard let c = cursor, c.frequencyHz >= axis.minHz, c.frequencyHz <= axis.maxHz else { return (-100, -1) }
            let row = c.secondsAgo.map { fieldRow(secondsAgo: $0) } ?? -1
            return (fieldBin(hz: c.frequencyHz), row >= 0 && row < Float(waterfall.depth) ? row : -1)
        }
        guard let hv = hover, let cell = fieldCell(at: hv) else { return (-100, -1) }
        return (Float(cell.bin), Float(cell.row))
    }

    /// Folds the ring into the field texture, then draws the bars into the multisampled picture.
    func encodeWaterfallPasses(_ cb: MTLCommandBuffer, ring: MTLTexture, head: Int) {
        let w = waterfall
        if w.color == nil || w.field == nil { waterfallLayoutChanged() }
        guard let field = w.field, let color = w.color, let msaaColor = w.msaaColor, let msaaDepth = w.msaaDepth, let hue = w.hueLUT else { return }

        // 1. The field: one fragment per cell.
        let fold = MTLRenderPassDescriptor()
        fold.colorAttachments[0].texture = field
        fold.colorAttachments[0].loadAction = .dontCare
        fold.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: fold) {
            enc.label = "Joseon waterfall field"
            var u = WaterfallSampleUniforms(head: Float(head), columns: Float(Self.columns), rows: Float(Self.rows), bins: Float(w.bins),
                                            depth: Float(w.depth), columnsPerRow: Float(Self.columns) / Float(w.depth))
            enc.setRenderPipelineState(ctx.waterfallSample)
            enc.setFragmentBytes(&u, length: MemoryLayout<WaterfallSampleUniforms>.stride, index: 3)
            enc.setFragmentTexture(ring, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }

        // 2. The bars, with depth, four samples per pixel, resolved into the picture.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaaColor
        pass.colorAttachments[0].resolveTexture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        let bg = palette.plot
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: 1)
        pass.depthAttachment.texture = msaaDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "Joseon waterfall bars"
        let lit = litCell
        let hues = huePositions
        var u = WaterfallUniforms(viewProj: w.viewProj, fog: SIMD4(bg.x, bg.y, bg.z, 1), floorV: ringValue(floorDB), topV: ringValue(topDB),
                                  bins: Float(w.bins), depth: Float(w.depth), height: w.height, depthStep: w.depthStep,
                                  hoverBin: lit.bin, hoverRow: lit.row, hueLo: hues.lo, hueHi: hues.hi, fogStart: 0.45,
                                  contrast: palette.highContrast ? 1 : 0)
        enc.setDepthStencilState(ctx.depthLess)
        enc.setVertexBytes(&u, length: MemoryLayout<WaterfallUniforms>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<WaterfallUniforms>.stride, index: 2)
        enc.setRenderPipelineState(ctx.waterfallFloor)
        enc.setCullMode(.none)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.setRenderPipelineState(ctx.waterfallBars)
        enc.setCullMode(.back)
        enc.setFrontFacing(.counterClockwise)
        enc.setVertexTexture(field, index: 0)
        enc.setVertexTexture(hue, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 30, instanceCount: w.bins * w.depth)
        enc.endEncoding()
    }

    // MARK: Main pass

    /// The picture into the plot, the dB scale at the near right corner, the frame.
    func drawWaterfall(_ enc: MTLRenderCommandEncoder, globals g: inout Globals) {
        let p = palette
        let px = Float(plot.minX), py = Float(plot.minY), pw = Float(plot.width), ph = Float(plot.height)
        if let color = waterfall.color {
            var rect = SIMD4<Float>(px, py, pw, ph)
            enc.setRenderPipelineState(ctx.texturedRect)
            enc.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
            enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            enc.setFragmentTexture(color, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if let scale = dbScaleEnds, waterfall.scaleShown {
            let c = p.textFaint
            batch.line(Float(scale.bottom.x), Float(scale.bottom.y), Float(scale.top.x), Float(scale.top.y), width: 1, color: c)
            batch.hline(Float(scale.top.x) - 3, Float(scale.top.x) + 3, Float(scale.top.y), color: c)
            batch.hline(Float(scale.bottom.x) - 3, Float(scale.bottom.x) + 3, Float(scale.bottom.y), color: c)
        }
        batch.rect(px - 0.5, py - 0.5, pw + 1, ph + 1, color: p.gridMajor, radius: 2, stroke: 1)
        batch.flush(enc, pipeline: ctx.shapeOver, globals: &g)
    }

    /// The dB scale: a vertical line at the near right corner of the field, floor at its foot, the top at its head.
    /// Nil when the corner projects outside the plot (a narrow card).
    var dbScaleEnds: (bottom: CGPoint, top: CGPoint)? {
        let w = waterfall
        let x = Float(w.bins) * 0.5 + 2.5
        guard let bottom = project(SIMD3(x, 0, 0.3)), let top = project(SIMD3(x, w.height, 0.3)) else { return nil }
        let inside = plot.insetBy(dx: 2, dy: 2)
        guard inside.contains(bottom), inside.contains(top) else { return nil }
        return (bottom, top)
    }

    // MARK: Text

    func drawWaterfallStatic(_ o: OverlayContext) {
        let p = palette
        let small = Fonts.mono(compact ? 10 : 11)
        let w = waterfall
        let inside = plot.insetBy(dx: 1, dy: 1)
        // Frequency decades along the near edge, in the order of the axis; a label that would touch the one before gives way.
        var placed: [CGRect] = []
        for f in LogAxis.labeled where f >= axis.minHz && f <= axis.maxHz {
            guard let pt = project(SIMD3(fieldX(hz: f), 0, 1.6)) else { continue }
            let text = Fmt.axisHz(f)
            let width = o.measure(text, font: small)
            let left = pt.x - width / 2, y = pt.y + 3
            guard left >= inside.minX, left + width <= inside.maxX, y >= inside.minY, y + 12 <= inside.maxY else { continue }
            let box = o.textBounds(text, x: pt.x, y: y, font: small, h: .center, v: .top).insetBy(dx: -3, dy: -2)
            guard !placed.contains(where: { $0.intersects(box) }) else { continue }
            o.text(text, x: pt.x, y: y, font: small, color: p.textDim, h: .center, v: .top)
            placed.append(box)
        }
        // Time into the depth, at the left edge of the field. "now" at the near corner. Never on a frequency label.
        let step = timeStep
        var t = 0.0
        var lastTop = CGFloat.greatestFiniteMagnitude
        let leftX = -Float(w.bins) * 0.5 - 2.5
        while t < historySeconds + 0.001 {
            let z = t == 0 ? Float(0.3) : fieldZ(secondsAgo: t)
            if let pt = project(SIMD3(leftX, 0, z)) {
                let text = t == 0 ? "now" : "\(Fmt.minus)\(Int(t)) s"
                let width = o.measure(text, font: small)
                let x = pt.x - 4
                let box = o.textBounds(text, x: x, y: pt.y, font: small, h: .right, v: .middle)
                if lastTop - pt.y > 13, x - width >= inside.minX, x <= inside.maxX, pt.y - 7 >= inside.minY, pt.y + 7 <= inside.maxY,
                   !placed.contains(where: { $0.intersects(box) }) {
                    o.text(text, x: x, y: pt.y, font: small, color: t == 0 ? p.text : p.textDim, h: .right, v: .middle)
                    placed.append(box)
                    lastTop = pt.y
                }
            }
            t += step
        }
        // The dB scale: top value at the head of the line, the floor at its foot. From the side its corner meets the
        // frequency labels: then the scale is left out, line and all.
        w.scaleShown = false
        if let ends = dbScaleEnds, !compact {
            let top = Fmt.number(topDB.rounded(), digits: 0), floor = Fmt.number(floorDB, digits: 0)
            let x = ends.top.x + 6
            let wTop = o.measure(top, font: small), wFloor = o.measure(floor, font: small)
            let topBox = o.textBounds(top, x: x, y: ends.top.y, font: small, v: .middle).insetBy(dx: -3, dy: -2)
            let floorBox = o.textBounds(floor, x: x, y: ends.bottom.y, font: small, v: .middle).insetBy(dx: -3, dy: -2)
            let lineBox = CGRect(x: min(ends.top.x, ends.bottom.x) - 4, y: min(ends.top.y, ends.bottom.y),
                                 width: abs(ends.top.x - ends.bottom.x) + 8, height: abs(ends.top.y - ends.bottom.y))
            if x + max(wTop, wFloor) <= inside.maxX, ends.bottom.y - ends.top.y > 26,
               !placed.contains(where: { $0.intersects(topBox) || $0.intersects(floorBox) || $0.intersects(lineBox) }) {
                w.scaleShown = true
                o.text(top, x: x, y: ends.top.y, font: small, color: p.text, v: .middle)
                o.text(floor, x: x, y: ends.bottom.y, font: small, color: p.textDim, v: .middle)
                if ends.bottom.y - ends.top.y > 44 {
                    o.text("dB", x: x, y: (ends.top.y + ends.bottom.y) / 2, font: small, color: p.textFaint, v: .middle)
                }
            }
        }
    }

    // MARK: Cursor

    func waterfallCursor(at point: CGPoint) -> PanelCursor? {
        guard let cell = fieldCell(at: point) else { return nil }
        let hz = axis.frequency((Float(cell.bin) + 0.5) / Float(waterfall.bins))
        let ago = (Double(cell.row) + 0.5) / Double(waterfall.depth) * historySeconds + latencySeconds
        return PanelCursor(frequencyHz: hz, secondsAgo: ago, source: .spectrogram)
    }

    func waterfallIsOnCursor(_ point: CGPoint) -> Bool {
        guard let c = cursor, let cell = fieldCell(at: point) else { return false }
        guard abs(Float(cell.bin) - fieldBin(hz: c.frequencyHz)) <= 1.5 else { return false }
        if let ago = c.secondsAgo { return abs(Float(cell.row) - fieldRow(secondsAgo: ago)) <= 1.5 }
        return true
    }

    /// The point of a frequency and time on the plot, at `height` (0 = the floor, 1 = the top of the scale). For tests.
    func projectForTesting(hz: Float, secondsAgo: Double, height: Float) -> CGPoint? {
        project(SIMD3(fieldX(hz: hz), waterfall.height * height, fieldZ(secondsAgo: secondsAgo)))
    }
}
