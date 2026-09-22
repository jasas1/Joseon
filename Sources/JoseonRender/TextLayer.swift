import AppKit
import Metal

/// The text of a panel (axis labels, readouts, the hover label) as a GPU texture.
///
/// Core Graphics draws into a bitmap that lives in a shared `MTLBuffer`; a texture view of the same memory is drawn
/// in the panel's Metal pass, one small quad per text rectangle. Two bitmaps are made when the size changes and then
/// reused. A redraw paints into the bitmap the GPU does not read (front / back swap), so a frame in flight never sees
/// half-drawn glyphs, and it paints only what differs from that bitmap's own content: axis labels and captions once per
/// layout, a readout when its digits change.
///
/// Compared with `CALayer` text layers this avoids a full-size (wide color: 8 bytes per pixel) backing store allocation,
/// a round trip to the window server for every readout change, and the second compositing path.
final class TextLayer {
    private final class Slot {
        let buffer: MTLBuffer
        let texture: MTLTexture
        let cg: CGContext
        var rects: [CGRect] = []     // points, top-left origin, pixel aligned
        var items: [OverlayItem] = []  // what the bitmap holds
        init(buffer: MTLBuffer, texture: MTLTexture, cg: CGContext) { self.buffer = buffer; self.texture = texture; self.cg = cg }
    }

    private let device: MTLDevice
    private var slots: [Slot] = []
    private var front = 0
    private(set) var size = CGSize.zero
    private(set) var scale: CGFloat = 0
    /// Counts redraws (tests and the frame cost report).
    private(set) var redrawCount = 0
    /// Ink boxes of the text of the newest redraw (layout tests).
    private(set) var lastLabels: [(text: String, rect: CGRect)] = []

    init(device: MTLDevice) { self.device = device }

    var isReady: Bool { slots.count == 2 }
    /// Rectangles that hold text in the visible bitmap.
    var rects: [CGRect] { isReady ? slots[front].rects : [] }

    /// Allocates the two bitmaps. Call only when the size or scale changed.
    func resize(size newSize: CGSize, scale newScale: CGFloat) {
        guard newSize != size || newScale != scale || !isReady else { return }
        size = newSize
        scale = newScale
        slots.removeAll()
        let w = max(Int((newSize.width * newScale).rounded()), 1), h = max(Int((newSize.height * newScale).rounded()), 1)
        let format = MTLPixelFormat.bgra8Unorm
        let align = max(device.minimumLinearTextureAlignment(for: format), 4)
        let bytesPerRow = (w * 4 + align - 1) / align * align
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        for i in 0..<2 {
            guard let buffer = device.makeBuffer(length: bytesPerRow * h, options: .storageModeShared) else { slots.removeAll(); return }
            buffer.label = "Joseon text \(i)"
            memset(buffer.contents(), 0, buffer.length)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            guard let texture = buffer.makeTexture(descriptor: d, offset: 0, bytesPerRow: bytesPerRow),
                  let cg = CGContext(data: buffer.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                     space: cs, bitmapInfo: info) else { slots.removeAll(); return }
            cg.scaleBy(x: newScale, y: newScale)
            cg.setShouldAntialias(true)
            cg.setShouldSmoothFonts(false)
            cg.setAllowsFontSubpixelPositioning(true)
            cg.setShouldSubpixelPositionFonts(true)
            slots.append(Slot(buffer: buffer, texture: texture, cg: cg))
        }
        front = 0
    }

    /// Items painted by the newest redraw, and how many of them had to be painted (tests and the frame cost report).
    private(set) var lastItemCount = 0
    private(set) var lastPaintedCount = 0
    /// Rectangles of the items the newest redraw painted (tests).
    private(set) var lastPaintedRects: [CGRect] = []

    /// Brings the text up to date. `body` records its drawing with a top-left origin in points; only what differs from the
    /// bitmap is painted: changed items, and unchanged items that touch a rectangle that must be cleared. A static label is
    /// painted once per layout, a readout when its string changes.
    func redraw(_ o: OverlayContext) {
        guard isReady else { return }
        let back = slots[1 - front]
        let cg = back.cg
        let new = o.items
        let old = back.items

        // Same key = same pixels in the same place. Count the old items by key, then match the new ones against them.
        var available: [Int: Int] = [:]
        available.reserveCapacity(old.count)
        for item in old { available[item.key, default: 0] += 1 }
        var paint = [Bool](repeating: false, count: new.count)
        var dirty: [CGRect] = []
        for (i, item) in new.enumerated() {
            if let c = available[item.key], c > 0 { available[item.key] = c - 1 } else { paint[i] = true; dirty.append(item.rect) }
        }
        // Old items that are gone (or changed): their pixels must be cleared.
        var leftover = available
        for item in old.reversed() {
            if let c = leftover[item.key], c > 0 { leftover[item.key] = c - 1; dirty.append(item.rect) }
        }
        // An unchanged item that touches a cleared rectangle is painted again, and its own rectangle is cleared too.
        var grew = !dirty.isEmpty
        while grew {
            grew = false
            for (i, item) in new.enumerated() where !paint[i] {
                for d in dirty where d.intersects(item.rect) {
                    paint[i] = true; dirty.append(item.rect); grew = true
                    break
                }
            }
        }
        var painted = 0
        if !dirty.isEmpty {
            for r in dirty { cg.clear(CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)) }
            lastPaintedRects.removeAll(keepingCapacity: true)
            for (i, item) in new.enumerated() where paint[i] { item.draw(in: cg); painted += 1; lastPaintedRects.append(item.rect) }
        }
        back.items = new
        // Rectangles for the GPU pass: leave out what another rectangle covers (a box and the text inside it).
        back.rects.removeAll(keepingCapacity: true)
        for item in new {
            var covered = false
            for e in back.rects where e.contains(item.rect) { covered = true; break }
            if !covered { back.rects.append(item.rect) }
        }
        lastLabels = o.labels
        lastItemCount = new.count
        lastPaintedCount = painted
        front = 1 - front
        redrawCount &+= 1
    }

    /// Draws the text rectangles into the current pass.
    func draw(_ enc: MTLRenderCommandEncoder, ctx: RenderContext, arena: FrameArena, globals g: inout Globals) {
        guard isReady else { return }
        let slot = slots[front]
        let n = slot.rects.count
        guard n > 0, let a = arena.allocate(SIMD4<Float>.self, count: n) else { return }
        for (i, r) in slot.rects.enumerated() {
            a.pointer[i] = SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height))
        }
        enc.setRenderPipelineState(ctx.overlay)
        enc.setVertexBuffer(arena.buffer, offset: a.offset, index: 0)
        enc.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
        enc.setFragmentTexture(slot.texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
    }
}
