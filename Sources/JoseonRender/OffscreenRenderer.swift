import AppKit
import Metal
import ImageIO
import UniformTypeIdentifiers
import JoseonCore

/// Renders a panel offscreen for a sequence of frames and returns PNG data. Used by tests and design review.
/// The drawing goes through the same `PanelRenderer` classes the on-screen views use. No window is needed.
public enum OffscreenRenderer {
    public enum RenderError: Error { case noMetalDevice, encodeFailed, notImplemented }

    /// Per-panel settings that the views expose as properties.
    public struct Settings: Sendable {
        public var spectrum = SpectrumViewOptions()
        public var historySeconds: Double = 20
        /// Cursor position in points, top-left origin. Draws the crosshair and the hover label.
        public var hover: CGPoint?
        public var increaseContrast = false
        /// `SpectrumView.autoRange`.
        public var spectrumAutoRange = true
        /// `VectorscopeView.mode`.
        public var vectorscopeMode = VectorscopeMode.lissajous
        /// `SpectrumView.showStressBands`.
        public var showStressBands = true
        /// `MetersView.targetLUFS`.
        public var targetLUFS: Float?
        /// `SpectrumView.levelAxis`.
        public var levelAxis = LevelAxis.dBFS
        /// `MetersView.doseStandard`.
        public var doseStandard = DoseStandard.nioshDaily
        /// A linked cursor without a window: the panel draws it as a view with a `cursorLink` does (hairline from its own
        /// axis, its own readout, a header row where the linked layout has one). Nil = an unlinked panel, as before.
        /// The panel whose kind is `cursor.source` puts the readout at `hover` when that is set and the cursor is not pinned.
        public var cursor: PanelCursor?
        /// `PanelCursorLink.historySlice`: the past spectrum of a timed cursor, for the spectrum's ghost trace.
        /// `OffscreenRenderer.historySlice(...)` makes one from frames.
        public var cursorHistorySlice: CursorHistorySlice?
        /// The record the timeline panel shows (`TimelineView.sessionProvider`). Nil = the empty state.
        public var session: SessionSnapshot?
        /// `TimelineView.windowSeconds`.
        public var timelineWindowSeconds = 900
        /// `TimelineView.showBands`.
        public var timelineShowBands = true
        /// `TimelineView.showLevelAtEar`.
        public var timelineShowLevelAtEar = false
        /// The time zone of the timeline's wall-clock labels. Nil = the current one.
        public var timelineTimeZone: TimeZone?
        /// `SpectrumView.comparison` and `MetersView.comparison`: the reference "A" of A/B compare.
        public var comparison: ComparisonSnapshot?
        /// `SpectrumView.comparisonLevelMatch` and `MetersView.comparisonLevelMatch`.
        public var comparisonLevelMatch = true
        /// `SpectrumView.comparisonMode`.
        public var comparisonMode = ComparisonMode.signal
        /// `SpectrumView.liveTiltDBPerOctave` and `MetersView.liveTiltDBPerOctave`.
        public var liveTiltDBPerOctave: Float = 0
        /// `SpectrumView.autoDeclutter`.
        public var spectrumAutoDeclutter = true
        public init() {}
    }

    /// Measured cost of one panel frame.
    public struct FrameCost: Sendable {
        /// CPU time to ingest a frame and encode the command buffer, milliseconds (median).
        public var cpuEncodeMS: Double
        /// GPU execution time of the command buffer, milliseconds (median).
        public var gpuMS: Double
        /// CPU time of one full text repaint, milliseconds (median). On screen this runs at most 10 times per second.
        public var textMS: Double
    }

    public static func png(panel: PanelKind, frames: [AnalysisFrame], size: CGSize, scale: CGFloat = 2, theme: Theme = Theme()) throws -> Data {
        try png(panel: panel, frames: frames, size: size, scale: scale, theme: theme, settings: Settings())
    }

    public static func png(panel: PanelKind, frames: [AnalysisFrame], size: CGSize, scale: CGFloat = 2, theme: Theme = Theme(),
                           settings: Settings) throws -> Data {
        let session = try Session(panel: panel, size: size, scale: scale, theme: theme, settings: settings)
        try session.feed(frames)
        return try session.snapshotPNG()
    }

    /// The column a spectrogram with this history publishes for a cursor `secondsAgo` old, after it saw `frames`. Nil when
    /// the time is outside the recorded history. For headless renders of a timed cursor with its ghost trace.
    public static func historySlice(frames: [AnalysisFrame], historySeconds: Double = 20, secondsAgo: Double) throws -> CursorHistorySlice? {
        var settings = Settings(); settings.historySeconds = historySeconds
        let session = try Session(panel: .spectrogram, size: CGSize(width: 400, height: 200), scale: 1, theme: Theme(), settings: settings)
        try session.feed(frames)
        return (session.renderer as? SpectrogramRenderer)?.historyColumn(secondsAgo: secondsAgo)?.slice
    }

    /// Steady-state frame cost: feeds `frames` once for history, then times `iterations` more frames.
    public static func measure(panel: PanelKind, frames: [AnalysisFrame], size: CGSize, scale: CGFloat = 2,
                               iterations: Int = 120, settings: Settings = Settings()) throws -> FrameCost {
        let session = try Session(panel: panel, size: size, scale: scale, theme: Theme(), settings: settings)
        try session.feed(frames)
        guard !frames.isEmpty else { throw RenderError.encodeFailed }
        var cpu: [Double] = [], gpu: [Double] = [], text: [Double] = []
        var hostTime = frames[frames.count - 1].hostTime
        for i in 0..<max(iterations, 1) {
            var f = frames[i % frames.count]
            hostTime += 1.0 / 60.0
            f.hostTime = hostTime
            let t0 = CFAbsoluteTimeGetCurrent()
            session.renderer.ingest(f)
            guard let cb = session.ctx.queue.makeCommandBuffer() else { throw RenderError.encodeFailed }
            session.renderer.encode(commandBuffer: cb, target: session.target)
            cb.commit()
            cpu.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            cb.waitUntilCompleted()
            gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
            if i % 6 == 0 {
                let t1 = CFAbsoluteTimeGetCurrent()
                session.renderer.refreshText(now: hostTime, force: true)
                text.append((CFAbsoluteTimeGetCurrent() - t1) * 1000)
            }
        }
        func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        return FrameCost(cpuEncodeMS: median(cpu), gpuMS: median(gpu), textMS: median(text))
    }

    // MARK: - Session

    final class Session {
        let ctx: RenderContext
        let renderer: PanelRenderer
        let target: MTLTexture
        let size: CGSize
        let scale: CGFloat
        let pixelWidth: Int
        let pixelHeight: Int

        init(panel: PanelKind, size: CGSize, scale: CGFloat, theme: Theme, settings: Settings) throws {
            guard let ctx = RenderContext.shared, let renderer = PanelRenderer.make(kind: panel, ctx: ctx, theme: theme) else {
                throw RenderError.noMetalDevice
            }
            self.ctx = ctx
            self.renderer = renderer
            self.size = size
            self.scale = scale
            pixelWidth = max(Int((size.width * scale).rounded()), 1)
            pixelHeight = max(Int((size.height * scale).rounded()), 1)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderContext.targetFormat, width: pixelWidth, height: pixelHeight, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = ctx.device.hasUnifiedMemory ? .shared : .managed
            guard let t = ctx.device.makeTexture(descriptor: d) else { throw RenderError.encodeFailed }
            target = t

            renderer.highContrast = settings.increaseContrast
            renderer.hover = settings.hover
            if let s = renderer as? SpectrumRenderer {
                s.options = settings.spectrum; s.autoRange = settings.spectrumAutoRange; s.showStressBands = settings.showStressBands; s.levelAxis = settings.levelAxis
                s.liveTiltDBPerOctave = settings.liveTiltDBPerOctave; s.comparisonLevelMatch = settings.comparisonLevelMatch
                s.comparisonMode = settings.comparisonMode; s.comparison = settings.comparison; s.autoDeclutter = settings.spectrumAutoDeclutter
            }
            if let s = renderer as? VectorscopeRenderer { s.mode = settings.vectorscopeMode }
            if let s = renderer as? MetersRenderer {
                s.targetLUFS = settings.targetLUFS; s.doseStandard = settings.doseStandard
                s.liveTiltDBPerOctave = settings.liveTiltDBPerOctave; s.comparisonLevelMatch = settings.comparisonLevelMatch; s.comparison = settings.comparison
            }
            if let s = renderer as? SpectrogramRenderer { s.historySeconds = settings.historySeconds }
            if let s = renderer as? TimelineRenderer {
                s.windowSeconds = settings.timelineWindowSeconds; s.targetLUFS = settings.targetLUFS; s.showBands = settings.timelineShowBands; s.showLevelAtEar = settings.timelineShowLevelAtEar
                if let tz = settings.timelineTimeZone { s.timeZone = tz }
                s.setSnapshot(settings.session ?? SessionSnapshot())
            }
            if let c = settings.cursor {
                renderer.cursorLinked = true
                renderer.cursor = c
                renderer.cursorSlice = settings.cursorHistorySlice
            }
            renderer.setLayout(size: size, scale: scale)
        }

        /// Feeds frames in order. History panels run their GPU pre-pass for every frame.
        func feed(_ frames: [AnalysisFrame]) throws {
            for (i, f) in frames.enumerated() {
                renderer.ingest(f)
                let last = i == frames.count - 1
                if renderer.needsPrePassPerFrame && !last {
                    guard let cb = ctx.queue.makeCommandBuffer() else { throw RenderError.encodeFailed }
                    renderer.encode(commandBuffer: cb, target: nil)
                    cb.commit()
                    // The arena has three buffers: never run ahead of the GPU by more than that.
                    if i % 2 == 1 { cb.waitUntilCompleted() }
                }
            }
        }

        func snapshotPNG() throws -> Data {
            // Text is part of the Metal pass (the same path the views use), so the snapshot is a plain read-back.
            renderer.refreshText(now: renderer.lastHostTime, force: true)
            guard let cb = ctx.queue.makeCommandBuffer() else { throw RenderError.encodeFailed }
            renderer.encode(commandBuffer: cb, target: target)
            if target.storageMode == .managed, let blit = cb.makeBlitCommandEncoder() {
                blit.synchronize(resource: target)
                blit.endEncoding()
            }
            cb.commit()
            cb.waitUntilCompleted()
            if cb.status == .error { throw RenderError.encodeFailed }
            renderer.lastGPUTime = cb.gpuEndTime - cb.gpuStartTime

            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
            guard let cg = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                                     space: cs, bitmapInfo: info), let data = cg.data else { throw RenderError.encodeFailed }
            target.getBytes(data, bytesPerRow: pixelWidth * 4, from: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight), mipmapLevel: 0)
            guard let image = cg.makeImage() else { throw RenderError.encodeFailed }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw RenderError.encodeFailed }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw RenderError.encodeFailed }
            return out as Data
        }
    }
}

/// The small label that follows the cursor. Shared by the view (own layer) and the offscreen renderer.
enum HoverLabel {
    static let font = Fonts.ui(11, .medium)
    static let lineHeight: CGFloat = 15
    static let padding: CGFloat = 8

    static func boxSize(_ o: OverlayContext, lines: [String]) -> CGSize {
        let w = lines.map { o.measure($0, font: font) }.max() ?? 0
        return CGSize(width: (w + padding * 2).rounded(.up), height: CGFloat(lines.count) * lineHeight + padding * 1.25)
    }

    /// Top-left origin for the box: right and below the cursor, flipped near the edges.
    /// `floor`: the box ends over this y (flipped above the pointer, then pushed up). Nil = the bottom of `bounds`.
    static func origin(anchor: CGPoint, box: CGSize, bounds: CGSize, floor: CGFloat? = nil) -> CGPoint {
        var x = anchor.x + 14, y = anchor.y + 14
        let bottom = min(floor ?? bounds.height - 4, bounds.height - 4)
        if x + box.width > bounds.width - 4 { x = anchor.x - 14 - box.width }
        if y + box.height > bottom { y = anchor.y - 14 - box.height }
        if floor != nil { y = min(y, bottom - box.height) }
        return CGPoint(x: max(x, 2), y: max(y, 2))
    }

    static func draw(_ o: OverlayContext, lines: [String], anchor: CGPoint, palette p: Palette, floor: CGFloat? = nil) {
        let box = boxSize(o, lines: lines)
        let org = origin(anchor: anchor, box: box, bounds: o.size, floor: floor)
        drawBox(o, lines: lines, rect: CGRect(origin: org, size: box), palette: p)
    }

    static func drawBox(_ o: OverlayContext, lines: [String], rect: CGRect, palette p: Palette) {
        o.fillRect(rect, color: p.background.withAlpha(0.90), radius: 6)
        o.strokeRect(rect.insetBy(dx: 0.5, dy: 0.5), color: p.gridStrong, radius: 6)
        for (i, line) in lines.enumerated() {
            o.text(line, x: rect.minX + padding, y: rect.minY + padding * 0.6 + CGFloat(i) * lineHeight + 10, font: font,
                   color: i == 0 ? p.text : p.textDim)
        }
    }
}
