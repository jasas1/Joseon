import Foundation
import Metal
import simd

/// Shared Metal state: device, queue, the compiled shader library and every pipeline.
/// Compiled once per process. Nil when there is no Metal device.
final class RenderContext {
    static let shared: RenderContext? = RenderContext()

    static let targetFormat: MTLPixelFormat = .bgra8Unorm
    static let accumFormat: MTLPixelFormat = .r16Float
    static let panAccumFormat: MTLPixelFormat = .rgba16Float

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary

    let shapeOver: MTLRenderPipelineState
    let shapeAdd: MTLRenderPipelineState
    let shapeLUT: MTLRenderPipelineState
    let curveLineOver: MTLRenderPipelineState
    let curveLineAdd: MTLRenderPipelineState
    let curveFill: MTLRenderPipelineState
    let spectrogram: MTLRenderPipelineState
    let scopeFade: MTLRenderPipelineState
    let scopePoints: MTLRenderPipelineState
    let scopeComposite: MTLRenderPipelineState
    let curveBand: MTLRenderPipelineState
    let panFade: MTLRenderPipelineState
    let panPoints: MTLRenderPipelineState
    let panComposite: MTLRenderPipelineState
    let overlay: MTLRenderPipelineState

    /// Bound when a shader declares a LUT but the draw does not use one.
    lazy var whiteLUT: MTLTexture? = makeLUT([SIMD3<Float>(1, 1, 1), SIMD3<Float>(1, 1, 1)])

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let options = MTLCompileOptions()
            library = try device.makeLibrary(source: ShaderSource.metal, options: options)
            let lib = library

            enum Blend { case over, add, none, multiplyByBlendColor }
            func pipeline(_ v: String, _ f: String, _ blend: Blend, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.label = "\(v)+\(f)"
                d.vertexFunction = lib.makeFunction(name: v)
                d.fragmentFunction = lib.makeFunction(name: f)
                let a = d.colorAttachments[0]!
                a.pixelFormat = format
                switch blend {
                case .none:
                    a.isBlendingEnabled = false
                case .over:
                    a.isBlendingEnabled = true
                    a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                case .add:
                    a.isBlendingEnabled = true
                    a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = .one
                    a.sourceAlphaBlendFactor = .zero; a.destinationAlphaBlendFactor = .one
                case .multiplyByBlendColor:
                    a.isBlendingEnabled = true
                    a.sourceRGBBlendFactor = .zero; a.destinationRGBBlendFactor = .blendColor
                    a.sourceAlphaBlendFactor = .zero; a.destinationAlphaBlendFactor = .blendAlpha
                }
                return try device.makeRenderPipelineState(descriptor: d)
            }

            let t = Self.targetFormat, acc = Self.accumFormat
            shapeOver = try pipeline("shape_vertex", "shape_fragment", .over, format: t)
            shapeAdd = try pipeline("shape_vertex", "shape_fragment", .add, format: t)
            shapeLUT = try pipeline("shape_vertex", "shape_lut_fragment", .over, format: t)
            curveLineOver = try pipeline("curve_line_vertex", "curve_line_fragment", .over, format: t)
            curveLineAdd = try pipeline("curve_line_vertex", "curve_line_fragment", .add, format: t)
            curveFill = try pipeline("curve_fill_vertex", "curve_fill_fragment", .over, format: t)
            spectrogram = try pipeline("rect_vertex", "spectrogram_fragment", .none, format: t)
            scopeFade = try pipeline("fullscreen_vertex", "scope_fade_fragment", .multiplyByBlendColor, format: acc)
            scopePoints = try pipeline("scope_point_vertex", "scope_point_fragment", .add, format: acc)
            scopeComposite = try pipeline("rect_vertex", "scope_composite_fragment", .add, format: t)
            curveBand = try pipeline("curve_band_vertex", "curve_band_fragment", .over, format: t)
            panFade = try pipeline("fullscreen_vertex", "scope_fade_fragment", .multiplyByBlendColor, format: Self.panAccumFormat)
            panPoints = try pipeline("pan_point_vertex", "pan_point_fragment", .add, format: Self.panAccumFormat)
            panComposite = try pipeline("rect_vertex", "pan_composite_fragment", .add, format: t)
            overlay = try pipeline("overlay_vertex", "overlay_fragment", .over, format: t)
        } catch {
            NSLog("Joseon render: shader build failed: \(error)")
            return nil
        }
    }

    /// 256 x 1 RGBA8 lookup texture.
    func makeLUT(_ colors: [SIMD3<Float>]) -> MTLTexture? {
        let n = colors.count
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: n, height: 1, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        var bytes = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n {
            let c = simd_clamp(colors[i], SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
            bytes[i * 4] = UInt8(c.x * 255 + 0.5); bytes[i * 4 + 1] = UInt8(c.y * 255 + 0.5); bytes[i * 4 + 2] = UInt8(c.z * 255 + 0.5)
        }
        bytes.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, n, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: n * 4)
        }
        return tex
    }
}

// MARK: - GPU structs (layout matches Shaders.swift)

struct Globals {
    var viewSize: SIMD2<Float>
    var scale: Float
    var time: Float
}

struct ShapeInstance {
    var rect: SIMD4<Float>
    var color0: SIMD4<Float>
    var color1: SIMD4<Float>
    var params: SIMD4<Float>
}

struct CurveUniforms {
    var rect: SIMD4<Float> = .zero
    var color: SIMD4<Float> = .one
    var halfWidth: Float = 0.5
    var soft: Float = 0
    var count: Float = 0
    var mode: Float = 0
    var dashPeriod: Float = 0
    var dashDuty: Float = 0.5
    var whiten: Float = 0
    var fillTop: Float = 0.6
    var fillBottom: Float = 0.1
    var pad0: Float = 0
    /// Points over which the curve fades out at the right end of the plot. 0 = no fade.
    var fadeRight: Float = 0
    var pad2: Float = 0
}

struct SpectrogramUniforms {
    var rect: SIMD4<Float>
    var head: Float
    var columns: Float
    var floorV: Float
    var gamma: Float
    var topV: Float
    var pad2: Float = 0
    var pad0: Float = 0, pad1: Float = 0
}

struct ScopeUniforms {
    var center: SIMD2<Float>
    var radius: Float
    var gain: Float
    var pointSize: Float
    var energy: Float
    var texSize: SIMD2<Float>
}

struct ScopeCompositeUniforms {
    var k: Float
    var norm: Float
    var pad1: Float = 0, pad2: Float = 0
}

struct PanUniforms {
    var texSize: SIMD2<Float>
    /// Pan 0 and the reach of pan 1, as fractions of the texture width.
    var centerX: Float
    var halfX: Float
    /// y of 20 kHz and the height down to 20 Hz, as fractions of the texture height.
    var top: Float
    var height: Float
    /// Horizontal sigma of a splat, pixels.
    var sigmaX: Float
    var energy: Float
}

// MARK: - Per-frame buffer arena

/// Three big shared buffers used round-robin, with a bump allocator. No per-frame allocation:
/// a frame writes into one buffer while the GPU may still read the two before it.
final class FrameArena {
    static let inFlight = 3
    private let buffers: [MTLBuffer]
    private var index = 0
    private var offset = 0
    let capacity: Int

    init?(device: MTLDevice, capacity: Int = 1 << 20) {
        var list: [MTLBuffer] = []
        for i in 0..<Self.inFlight {
            guard let b = device.makeBuffer(length: capacity, options: .storageModeShared) else { return nil }
            b.label = "Joseon arena \(i)"
            list.append(b)
        }
        buffers = list
        self.capacity = capacity
    }

    func beginFrame() {
        index = (index + 1) % buffers.count
        offset = 0
    }

    var buffer: MTLBuffer { buffers[index] }

    /// Reserve `count` elements of `T`. Returns nil when the arena is full (the draw is skipped).
    func allocate<T>(_ type: T.Type, count: Int) -> (pointer: UnsafeMutablePointer<T>, offset: Int)? {
        let align = 16
        let start = (offset + align - 1) / align * align
        let bytes = MemoryLayout<T>.stride * count
        guard start + bytes <= capacity else { return nil }
        offset = start + bytes
        let p = (buffers[index].contents() + start).bindMemory(to: T.self, capacity: count)
        return (p, start)
    }
}

// MARK: - Shape batch

/// Collects instanced quads and draws them in order. Storage comes from the frame arena.
final class ShapeBatch {
    private let arena: FrameArena
    private var base: UnsafeMutablePointer<ShapeInstance>?
    private var baseOffset = 0
    private var count = 0
    private var flushed = 0
    private let capacity: Int
    var scale: Float = 2

    init(arena: FrameArena, capacity: Int = 4096) {
        self.arena = arena
        self.capacity = capacity
    }

    func beginFrame(scale: Float) {
        self.scale = scale
        count = 0; flushed = 0
        if let a = arena.allocate(ShapeInstance.self, count: capacity) {
            base = a.pointer; baseOffset = a.offset
        } else {
            base = nil
        }
    }

    @inline(__always) private func push(_ s: ShapeInstance) {
        guard let base, count < capacity else { return }
        base[count] = s
        count += 1
    }

    @inline(__always) func snap(_ v: Float) -> Float { (v * scale).rounded() / scale }

    func rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float, top: SIMD4<Float>, bottom: SIMD4<Float>, radius: Float = 0, glow: Float = 0, stroke: Float = 0) {
        push(ShapeInstance(rect: SIMD4(x, y, w, h), color0: top, color1: bottom, params: SIMD4(radius, glow, 0, stroke)))
    }

    func rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float, color: SIMD4<Float>, radius: Float = 0, glow: Float = 0, stroke: Float = 0) {
        rect(x, y, w, h, top: color, bottom: color, radius: radius, glow: glow, stroke: stroke)
    }

    func hgradient(_ x: Float, _ y: Float, _ w: Float, _ h: Float, left: SIMD4<Float>, right: SIMD4<Float>, radius: Float = 0) {
        push(ShapeInstance(rect: SIMD4(x, y, w, h), color0: left, color1: right, params: SIMD4(radius, 0, 2, 0)))
    }

    /// Pixel-snapped one-pixel horizontal line.
    func hline(_ x0: Float, _ x1: Float, _ y: Float, color: SIMD4<Float>, pixels: Float = 1) {
        let t = pixels / scale
        rect(snap(x0), snap(y - t * 0.5), snap(x1) - snap(x0), t, color: color)
    }

    /// Pixel-snapped one-pixel vertical line.
    func vline(_ x: Float, _ y0: Float, _ y1: Float, color: SIMD4<Float>, pixels: Float = 1) {
        let t = pixels / scale
        rect(snap(x - t * 0.5), snap(y0), t, snap(y1) - snap(y0), color: color)
    }

    func line(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, width: Float, color: SIMD4<Float>, endColor: SIMD4<Float>? = nil, glow: Float = 0) {
        push(ShapeInstance(rect: SIMD4(x0, y0, x1, y1), color0: color, color1: endColor ?? color, params: SIMD4(width * 0.5, glow, 1, 0)))
    }

    func circle(_ cx: Float, _ cy: Float, _ r: Float, color: SIMD4<Float>, stroke: Float = 0, glow: Float = 0) {
        rect(cx - r, cy - r, r * 2, r * 2, color: color, radius: r, glow: glow, stroke: stroke)
    }

    /// Draw everything added since the last flush with the given pipeline.
    func flush(_ enc: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, globals: inout Globals, lut: MTLTexture? = nil) {
        let n = count - flushed
        guard n > 0, base != nil else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(arena.buffer, offset: baseOffset + flushed * MemoryLayout<ShapeInstance>.stride, index: 0)
        enc.setVertexBytes(&globals, length: MemoryLayout<Globals>.stride, index: 1)
        enc.setFragmentBytes(&globals, length: MemoryLayout<Globals>.stride, index: 1)
        if let lut { enc.setFragmentTexture(lut, index: 0) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
        flushed = count
    }
}
