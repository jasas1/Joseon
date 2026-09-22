import AppKit
import Metal
import QuartzCore
import JoseonCore

/// Base class of the panels. One `CAMetalLayer`, driven by a `CAMetalDisplayLink`.
/// Text (axis labels, readouts, the cursor label) is a texture inside the same Metal pass: see `TextLayer`.
///
/// Cost control: the link runs at `preferredFramesPerSecond` (30 under Reduce Motion), and a tick draws nothing when
/// the analysis frame is the one already on screen and nothing animates.
open class PanelView: NSView, CAMetalDisplayLinkDelegate, CALayerDelegate {
    public let kind: PanelKind
    public var frameProvider: FrameProvider
    public var theme = Theme() { didSet { renderer?.theme = theme; applyAccessibilityDisplayOptions() } }
    /// Pause drawing (window hidden). Panels must stop their display link when true.
    public var isPaused = false { didSet { updateRunState() } }
    /// Upper limit of the redraw rate. Default 60 (the analysis engine makes about 60 frames per second); the meters and the
    /// spectrogram default to 30, which is as smooth as their content moves. Reduce Motion caps every panel at 30.
    public var preferredFramesPerSecond: Int { didSet { if preferredFramesPerSecond != oldValue { applyFrameRate() } } }

    /// The cursor this panel shares with the other panels of its window (one link per window, the same object in every
    /// panel). Nil (default) = the per-panel hover of before, unchanged. With a link: the pointer in the spectrum, the
    /// spectrogram or the stereo placement field writes the cursor, a click pins it, every panel draws it with its own
    /// readout, and the panel accepts first responder for the keyboard (arrows, Return, Esc).
    public var cursorLink: PanelCursorLink? { didSet { if cursorLink !== oldValue { relink(from: oldValue) } } }

    /// GPU time of the most recent frame in seconds (0 until the first frame completes).
    public private(set) var lastGPUFrameTime: Double = 0
    /// Frames drawn since the view was created.
    public private(set) var drawnFrameCount = 0
    /// Display link callbacks since the view was created.
    public private(set) var tickCount = 0
    /// Display link ticks that drew nothing because the picture had not changed.
    public private(set) var skippedFrameCount = 0

    let renderer: PanelRenderer?
    private let metalLayer = CAMetalLayer()
    private var displayLink: CAMetalDisplayLink?
    private var inFlight = 0
    private var lastFrameHostTime: TimeInterval = -1
    private var lastTick: CFTimeInterval = 0
    private var reduceMotion = false
    private var observers: [NSObjectProtocol] = []
    private var tracking: NSTrackingArea?

    public init(kind: PanelKind, frameProvider: @escaping FrameProvider) {
        self.kind = kind
        self.frameProvider = frameProvider
        preferredFramesPerSecond = (kind == .meters || kind == .spectrogram) ? 30 : 60
        if let ctx = RenderContext.shared {
            renderer = PanelRenderer.make(kind: kind, ctx: ctx, theme: Theme())
        } else {
            renderer = nil
        }
        super.init(frame: .zero)
        buildLayers()
        applyAccessibilityDisplayOptions()
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyAccessibilityDisplayOptions()
        })
    }

    @available(*, unavailable) public required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let cursorObserver { cursorLink?.removeObserver(cursorObserver) }
        pendingAnnouncement?.cancel()
        displayLink?.invalidate()
        for o in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
            NotificationCenter.default.removeObserver(o)
        }
    }

    // MARK: Layers

    private func buildLayers() {
        let root = CALayer()
        root.backgroundColor = theme.background.cgColor
        layer = root
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        metalLayer.device = RenderContext.shared?.device
        metalLayer.pixelFormat = RenderContext.targetFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        root.addSublayer(metalLayer)
    }

    /// No implicit animations on the panel's layers.
    public func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
    /// Kept for source compatibility. Text is no longer drawn through Core Animation layers: see `TextLayer`.
    public func draw(_ layer: CALayer, in ctx: CGContext) {}

    open override func layout() {
        super.layout()
        syncLayerGeometry()
    }

    open override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayerGeometry()
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func syncLayerGeometry() {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        let sc = backingScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = b
        metalLayer.contentsScale = sc
        metalLayer.drawableSize = CGSize(width: (b.width * sc).rounded(), height: (b.height * sc).rounded())
        CATransaction.commit()
        renderer?.setLayout(size: b.size, scale: sc)
    }

    // MARK: Run state

    open override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let nc = NotificationCenter.default
        for o in observers.dropFirst() { nc.removeObserver(o) }
        observers = Array(observers.prefix(1))
        displayLink?.invalidate()
        displayLink = nil
        guard let window, renderer != nil else { return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.updateRunState() })
        }
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        link.preferredFrameLatency = 1
        link.add(to: .main, forMode: .common)
        displayLink = link
        syncLayerGeometry()
        applyFrameRate()
        updateRunState()
    }

    open override func viewDidHide() { super.viewDidHide(); updateRunState() }
    open override func viewDidUnhide() { super.viewDidUnhide(); updateRunState() }

    /// Display link state, for diagnostics.
    public var debugRunState: String {
        guard let link = displayLink else { return "no display link" }
        return "link paused=\(link.isPaused) inFlight=\(inFlight) drawable=\(metalLayer.drawableSize) ticks=\(tickCount) drawn=\(drawnFrameCount) skipped=\(skippedFrameCount) gpu=\(String(format: "%.2f", lastGPUFrameTime * 1000)) ms"
    }

    /// Test seam: a window made by a command line test process never reports `.visible`.
    static var ignoresOcclusionForTesting = false

    private func updateRunState() {
        guard let link = displayLink else { return }
        let visible = window.map { ($0.occlusionState.contains(.visible) || Self.ignoresOcclusionForTesting) && !$0.isMiniaturized } ?? false
        link.isPaused = isPaused || !visible || isHiddenOrHasHiddenAncestor
        if !link.isPaused {
            lastTick = 0
            renderer?.needsDisplay = true
        }
    }

    /// The rate the display link asks for: `preferredFramesPerSecond`, at most 30 under Reduce Motion.
    public var effectiveFramesPerSecond: Int {
        let top = min(max(preferredFramesPerSecond, 1), 120)
        return reduceMotion ? min(top, 30) : top
    }

    private func applyFrameRate() {
        let top = Float(effectiveFramesPerSecond)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
    }

    private func applyAccessibilityDisplayOptions() {
        let ws = NSWorkspace.shared
        reduceMotion = ws.accessibilityDisplayShouldReduceMotion
        renderer?.highContrast = ws.accessibilityDisplayShouldIncreaseContrast
        layer?.backgroundColor = theme.background.cgColor
        applyFrameRate()
    }

    // MARK: Frame

    public func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        tickCount &+= 1
        guard let renderer, inFlight < FrameArena.inFlight else { return }
        let now = update.targetTimestamp
        let dt = lastTick > 0 ? min(max(now - lastTick, 0), 0.25) : 1.0 / 60.0
        lastTick = now

        syncOptions()
        var changed = false
        if renderer.usesAnalysisFrames {
            let frame = frameProvider()
            if frame.hostTime != lastFrameHostTime || renderer.frame == nil {
                lastFrameHostTime = frame.hostTime
                renderer.ingest(frame)
                changed = renderer.frameChanged
            } else {
                renderer.idle(dt: dt)
            }
        }
        if cursorLink != nil { publishHistorySliceIfNeeded(now: now) }
        if renderer.refreshText(now: now) { changed = true }
        // Nothing new to show: leave the last picture on screen. The unused drawable goes back to the layer.
        guard changed || renderer.needsDisplay || renderer.isAnimating else {
            skippedFrameCount &+= 1
            return
        }
        renderer.needsDisplay = false

        guard let cb = renderer.ctx.queue.makeCommandBuffer() else { return }
        let drawable = update.drawable
        renderer.encode(commandBuffer: cb, target: drawable.texture)
        cb.present(drawable)
        inFlight += 1
        cb.addCompletedHandler { [weak self] done in
            let gpu = done.gpuEndTime - done.gpuStartTime
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight -= 1
                self.lastGPUFrameTime = gpu
                self.renderer?.lastGPUTime = gpu
            }
        }
        cb.commit()
        drawnFrameCount &+= 1
    }

    /// Subclasses copy their public options into the renderer.
    func syncOptions() {}

    // MARK: Hover

    open override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    open override func mouseMoved(with event: NSEvent) { setHover(convert(event.locationInWindow, from: nil)) }
    open override func mouseEntered(with event: NSEvent) { setHover(convert(event.locationInWindow, from: nil)) }
    open override func mouseExited(with event: NSEvent) { setHover(nil) }

    func topLeftPoint(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y) }

    private func setHover(_ p: NSPoint?) {
        guard let renderer else { return }
        let point = p.map(topLeftPoint)
        renderer.hover = point
        // Linked: the local hover is "this panel is the cursor source". The frequency (and the time) come from the panel's
        // own axes; the link ignores the move while a cursor is pinned.
        guard let link = cursorLink, renderer.makesPointerCursors else { return }
        if let point, let c = renderer.cursor(at: point) { link.set(c) } else { link.hoverEnded(from: kind) }
    }

    // MARK: Linked cursor

    private var cursorObserver: UUID?
    private var lastSliceKey: (id: Int?, ago: Double)?
    private var lastSliceTime: CFTimeInterval = -1
    private var lastAnnouncementTime: CFTimeInterval = -1
    private var pendingAnnouncement: DispatchWorkItem?
    /// Test seam: receives the announcements instead of VoiceOver.
    var announcementSink: ((String) -> Void)?
    /// At most this many seconds between two announcements of the cursor readout (2 per second).
    static let announcementInterval: CFTimeInterval = 0.5

    private func relink(from old: PanelCursorLink?) {
        if let cursorObserver { old?.removeObserver(cursorObserver) }
        cursorObserver = cursorLink?.addObserver { [weak self] in self?.syncCursor() }
        lastSliceKey = nil
        renderer?.cursorLinked = cursorLink != nil
        syncCursor()
    }

    /// A change of the link only copies state and marks the renderer dirty: the drawing happens on the next display tick,
    /// once, however many times the cursor moved since the last one.
    private func syncCursor() {
        guard let renderer else { return }
        renderer.cursor = cursorLink?.cursor
        renderer.cursorSlice = cursorLink?.historySlice
    }

    /// The spectrogram publishes the history column under a timed cursor: only when the column (or the cursor's time)
    /// changed, and at most 30 times per second. Runs on the display tick; the history scrolls under a cursor that stands
    /// still, so the column changes while music plays and stays while the display is frozen.
    func publishHistorySliceIfNeeded(now: CFTimeInterval) {
        guard let link = cursorLink, let r = renderer as? SpectrogramRenderer else { return }
        guard let ago = link.cursor?.secondsAgo else { lastSliceKey = nil; return }
        let id = r.historyColumnID(secondsAgo: ago)
        if let last = lastSliceKey, last.id == id, last.ago == ago, (id == nil) == (link.historySlice == nil) { return }
        guard lastSliceTime < 0 || now - lastSliceTime >= 1.0 / 30.0 || now < lastSliceTime else { return }
        lastSliceKey = (id, ago)
        lastSliceTime = now
        link.publish(historySlice: id == nil ? nil : r.historyColumn(secondsAgo: ago)?.slice)
    }

    open override var acceptsFirstResponder: Bool { cursorLink != nil }

    open override func mouseDown(with event: NSEvent) {
        guard cursorLink != nil else { super.mouseDown(with: event); return }
        window?.makeFirstResponder(self)
        if !handleCursorClick(at: topLeftPoint(convert(event.locationInWindow, from: nil))) { super.mouseDown(with: event) }
    }

    /// A click over a plot with a frequency axis pins the cursor there. A click on a pinned cursor clears it (the hover
    /// cursor of the pointer takes over at once). Returns false when the click was not for the cursor.
    @discardableResult
    func handleCursorClick(at point: CGPoint) -> Bool {
        guard let link = cursorLink, let renderer, renderer.makesPointerCursors, var c = renderer.cursor(at: point) else { return false }
        if link.cursor?.isPinned == true, renderer.isOnCursor(point) {
            link.clear()
            renderer.hover = point
            link.set(c)
            return true
        }
        c.isPinned = true
        link.set(c)
        announceCursor()
        return true
    }

    enum CursorKey { case left, right, up, down, pin, escape }

    open override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        let key: CursorKey?
        switch event.keyCode {
        case 123: key = .left
        case 124: key = .right
        case 125: key = .down
        case 126: key = .up
        case 36, 76: key = .pin
        case 53: key = .escape
        default: key = nil
        }
        guard cursorLink != nil, plain, let key, handleCursorKey(key, shift: event.modifierFlags.contains(.shift)) else {
            super.keyDown(with: event)
            return
        }
    }

    /// Frequency range of the keyboard cursor: the axis every panel shows.
    static let cursorRangeHz: ClosedRange<Float> = 20...20_000

    /// Keyboard control of the shared cursor. Left / right: one semitone (Shift: one octave). Up / down, spectrogram only:
    /// one history column toward now / into the past (Shift: 1 s). Return pins or unpins. Esc clears. With no cursor the
    /// first arrow key puts one at the frame's peak frequency. Returns false when the key did nothing (it then goes up the
    /// responder chain: Esc without a cursor stays the window's Esc).
    @discardableResult
    func handleCursorKey(_ key: CursorKey, shift: Bool) -> Bool {
        guard let link = cursorLink, let renderer else { return false }
        switch key {
        case .escape:
            guard link.cursor != nil else { return false }
            link.clear()
            return true
        case .pin:
            guard var c = link.cursor else { return false }
            if c.isPinned {
                // The link replaces a pinned cursor only by a pinned one: unpin = clear, then the same place as a hover cursor.
                link.clear()
                c.isPinned = false; c.source = kind
                link.set(c)
            } else {
                c.isPinned = true
                link.set(c)
            }
            announceCursor()
            return true
        case .left, .right, .up, .down:
            let timeKey = key == .up || key == .down
            let spectrogram = renderer as? SpectrogramRenderer
            if timeKey, spectrogram == nil { return false }
            var c: PanelCursor
            if let current = link.cursor {
                c = current
                if let s = spectrogram, timeKey {
                    let newest = s.newestSecondsAgo
                    let step = shift ? 1.0 : s.columnSeconds
                    let ago = (c.secondsAgo ?? newest) + (key == .down ? step : -step)
                    c.secondsAgo = min(max(ago, newest), newest + s.historySeconds)
                } else if !timeKey {
                    c.frequencyHz = CursorMath.step(c.frequencyHz, semitones: (key == .right ? 1 : -1) * (shift ? 12 : 1), in: Self.cursorRangeHz)
                }
            } else {
                let f = renderer.frame ?? frameProvider()
                let peak = !Fmt.isFloor(f.peak.levelDB) && f.peak.frequencyHz > 0 ? f.peak.frequencyHz : 1000
                c = PanelCursor(frequencyHz: min(max(peak, Self.cursorRangeHz.lowerBound), Self.cursorRangeHz.upperBound),
                                secondsAgo: timeKey ? spectrogram?.newestSecondsAgo : nil, source: kind)
            }
            c.source = kind
            link.set(c)
            announceCursor()
            return true
        }
    }

    /// Posts this panel's cursor readout to VoiceOver: after a pin and after a keyboard move, at most 2 per second. A burst
    /// (key repeat) ends with the readout of where the cursor came to rest.
    func announceCursor() {
        pendingAnnouncement?.cancel()
        pendingAnnouncement = nil
        let now = CACurrentMediaTime()
        let wait = lastAnnouncementTime < 0 ? 0 : lastAnnouncementTime + Self.announcementInterval - now
        if wait <= 0 { postAnnouncement(); return }
        let item = DispatchWorkItem { [weak self] in self?.postAnnouncement() }
        pendingAnnouncement = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    private func postAnnouncement() {
        pendingAnnouncement = nil
        guard let text = renderer?.cursorAccessibilityText, !text.isEmpty else { return }
        lastAnnouncementTime = CACurrentMediaTime()
        if let announcementSink { announcementSink(text); return }
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    // MARK: Accessibility

    open override func isAccessibilityElement() -> Bool { true }
    open override func accessibilityRole() -> NSAccessibility.Role? { kind == .meters ? .levelIndicator : .image }
    open override func accessibilityRoleDescription() -> String? {
        switch kind {
        case .spectrum: return "spectrum graph"
        case .spectrogram: return "spectrogram"
        case .vectorscope: return "vectorscope"
        case .meters: return "level meters"
        case .timeline: return "session timeline"
        }
    }
    open override func accessibilityLabel() -> String? { renderer?.accessibilityLabelText ?? kind.rawValue }
    open override func accessibilityValue() -> Any? {
        guard let renderer else { return "Metal is not available" }
        // A paused panel still answers with the newest numbers.
        if renderer.frame == nil || isPaused { renderer.ingest(frameProvider()) }
        let cursorText = renderer.cursorAccessibilityText
        return cursorText.isEmpty ? renderer.accessibilityValueText : renderer.accessibilityValueText + ". " + cursorText
    }
    /// The same string the VoiceOver value uses. Handy for tests and for a status line.
    public var accessibilitySummary: String { (accessibilityValue() as? String) ?? "" }
}

/// The level axis of the spectrum.
public enum LevelAxis: Sendable {
    /// dBFS only (default).
    case dBFS
    /// dBFS curves as before, plus the third-octave levels at the eardrum on a right-hand dB SPL axis. Needs `frame.spl`
    /// and `frame.thirdOctave`; without them the header says "not calibrated" and nothing else changes.
    case dBSPL
}

public final class SpectrumView: PanelView {
    /// The headphone overlay (`showHeadphoneOverlay`) is drawn only where the panel has room for its words: the legend row
    /// (name, Response, Target, Error) and the `dB rel` axis. A compact card (under 460 pt wide or 200 pt high) or a row
    /// too narrow for the entries hides the band and the at-ear trace, and the header says `headphone band hidden`.
    public var options = SpectrumViewOptions()
    /// Slow automatic dB range (default on): a 72 dB window, or the span of `options` when that is smaller, whose top
    /// follows the music in 6 dB steps with hysteresis. Set false to show exactly `options.minDB ... options.maxDB`.
    public var autoRange = true
    /// Shades the frequency span of each headphone stress flag that has one (`StressFlag.frequencyRangeHz`) and writes its
    /// `plotLabel` at the top of the span. Default on. Independent of `options.showHeadphoneOverlay`; needs `frame.headphone`.
    public var showStressBands = true
    /// `.dBSPL` adds the estimated third-octave levels at the eardrum (stepped bars, right-hand axis). Default `.dBFS`.
    public var levelAxis = LevelAxis.dBFS
    /// A/B compare: the reference "A". The live signal "B" is drawn against it: A's long-term curve as a calm trace, the
    /// long-term curve of B renamed `B · long-term`, and a difference lane `B − A` in the bottom 22 % of the plot. Nil (default)
    /// = no comparison, nothing changes. With the lane on `.signal` and a plot under 420 pt high (or a view under 360 pt in
    /// either mode) the lane takes the room of the headphone band (the header
    /// says `headphone band hidden`). The lane's curve area is never lower than 56 pt (zero line and a ± tick pair): a panel that
    /// cannot give that (under about 250 pt of height) draws no lane, only the trace, and its header says
    /// `B − A lane hidden (panel too small)`.
    public var comparison: ComparisonSnapshot?
    /// Takes the broadband level difference out of the lane (power mean over 100 Hz ... 10 kHz) and prints it in the lane's
    /// label (`level-matched, B is +2.3 dB louder`). Default on. Off: the lane shows the difference as played.
    public var comparisonLevelMatch = true
    /// What the lane shows: the difference of the music (`.signal`, default) or of the two headphone responses (`.headphone`).
    public var comparisonMode = ComparisonMode.signal
    /// The display tilt of the live curves in dB per octave around 1 kHz (the analyzer's tilt setting). The comparison
    /// takes it out of B, and `comparison.tiltDBPerOctave` out of A, before the difference; A is drawn with the live tilt.
    public var liveTiltDBPerOctave: Float = 0
    /// Default on: the panel takes away the traces that the question on screen does not need. While `comparison` is set,
    /// L and R are not drawn. While a timed cursor shows its ghost trace (dashed cyan), Peak hold and Long-term are not
    /// drawn. And L / R, Side, Peak hold or Long-term are never drawn without their name in the legend row (a small card
    /// has no room for every name). Off: every trace of `options` is drawn.
    public var autoDeclutter = true
    public init(frameProvider: @escaping FrameProvider) { super.init(kind: .spectrum, frameProvider: frameProvider) }
    override func syncOptions() {
        guard let r = renderer as? SpectrumRenderer else { return }
        r.options = options
        r.autoRange = autoRange
        r.showStressBands = showStressBands
        r.levelAxis = levelAxis
        r.liveTiltDBPerOctave = liveTiltDBPerOctave
        r.comparisonLevelMatch = comparisonLevelMatch
        r.comparisonMode = comparisonMode
        r.comparison = comparison
        r.autoDeclutter = autoDeclutter
    }
}

public final class SpectrogramView: PanelView {
    /// Seconds of history across the view width.
    public var historySeconds: Double = 20
    public init(frameProvider: @escaping FrameProvider) { super.init(kind: .spectrogram, frameProvider: frameProvider) }
    override func syncOptions() { (renderer as? SpectrogramRenderer)?.historySeconds = max(historySeconds, 1) }
}

public final class VectorscopeView: PanelView {
    /// Seconds for the light to fade to 1/e.
    public var persistenceSeconds: Double = 0.45
    /// What the square field shows: the L / R goniometer (default) or stereo placement by frequency.
    public var mode = VectorscopeMode.lissajous
    public init(frameProvider: @escaping FrameProvider) { super.init(kind: .vectorscope, frameProvider: frameProvider) }
    override func syncOptions() {
        guard let r = renderer as? VectorscopeRenderer else { return }
        r.persistenceSeconds = persistenceSeconds
        r.mode = mode
    }
}

public final class MetersView: PanelView {
    /// Loudness target in LUFS, for example -14 (streaming), -16 (Apple Music) or -23 (EBU R128). Shows a tick on the
    /// I bar, a line in the loudness history, and the distance of integrated loudness to the target in LU. Nil = no target.
    public var targetLUFS: Float?
    /// Called on a click on the clip indicator. The clip count is a measurement since the last reset, so clearing it
    /// means resetting the measurement: the app decides.
    public var onClipIndicatorClick: (() -> Void)?
    /// Dose rule of the "Level at the ear" block (shown only while `frame.spl` is not nil): NIOSH daily (85 dB(A), 8 h) or
    /// WHO weekly (80 dB(A), 40 h). Selects the percent, the ring and "time left at this level". Default NIOSH daily.
    public var doseStandard = DoseStandard.nioshDaily
    /// A/B compare: the reference "A". While set, an "A vs B" table takes the place of the loudness history (a panel that
    /// is high enough keeps the history under it): integrated loudness, range, PLR, true peak max, Leq dB(A) when both
    /// have it, lowest strong content, and `B − A` of the eight listening bands as small ± bars. Δ is always B − A.
    public var comparison: ComparisonSnapshot?
    /// Takes the level offset the spectrum prints out of the band bars (and out of nothing else). Default on.
    public var comparisonLevelMatch = true
    /// The display tilt of the live curves (see `SpectrumView.liveTiltDBPerOctave`): the band bars come from the two
    /// long-term curves, and the level offset must be the number the spectrum shows.
    public var liveTiltDBPerOctave: Float = 0
    public init(frameProvider: @escaping FrameProvider) { super.init(kind: .meters, frameProvider: frameProvider) }
    override func syncOptions() {
        guard let r = renderer as? MetersRenderer else { return }
        r.targetLUFS = targetLUFS
        r.doseStandard = doseStandard
        r.liveTiltDBPerOctave = liveTiltDBPerOctave
        r.comparisonLevelMatch = comparisonLevelMatch
        r.comparison = comparison
    }

    public override func mouseDown(with event: NSEvent) {
        let p = topLeftPoint(convert(event.locationInWindow, from: nil))
        if let r = renderer as? MetersRenderer, r.clipIndicatorRect.contains(p), let onClipIndicatorClick {
            onClipIndicatorClick()
        } else {
            super.mouseDown(with: event)
        }
    }
}
