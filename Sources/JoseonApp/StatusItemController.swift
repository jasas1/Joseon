import AppKit
import SwiftUI
import Combine
import JoseonCore
import JoseonRender

/// Menu bar mini graph + popover.
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let settings: AppSettings
    private let actions: ShellActions
    private let item: NSStatusItem
    private let renderer = MiniSpectrumRenderer()
    private let popover = NSPopover()
    private let popoverSpectrum: SpectrumView
    private let readouts: PopoverReadouts
    private var timer: Timer?
    private var active = false
    private var cancellables = Set<AnyCancellable>()
    private let graphHeight: CGFloat = 18
    /// The graph goes into this layer, not into `button.image`. Measured (sample, 30 Hz): a new button image
    /// costs about 2 ms of main-thread time per update — the button cell draws, AppKit updates the status
    /// item scene, and it draws the item again for its replicants. New layer contents cost one small commit.
    private let graphView = MiniGraphLayerView()
    /// The now-playing text to the right of the graph. Hidden, and the item no wider than before, while no track is known.
    private let nowPlayingView = NowPlayingView(style: .menuBar)
    /// Room after the marquee, so the text does not touch the next menu bar item.
    private static let marqueeTrailing: CGFloat = 4
    /// JOSEON_MINI_MODE=image selects the old `button.image` path (for A/B measurements).
    private let usesLayer = ProcessInfo.processInfo.environment["JOSEON_MINI_MODE"] != "image"
    private var lastImage: NSImage?
    private var lastCGImage: CGImage?
    private var lastImageSize = CGSize.zero
    private var lastBitmap: CFData?
    private var lastDrawKey = DrawKey()
    private var lastReplicantRefresh: TimeInterval = 0
    private var lastDrawTime: TimeInterval = 0
    /// Everything but the frame that changes the picture.
    private struct DrawKey: Equatable {
        var hostTime: TimeInterval = -1
        var width = 0
        var scale: CGFloat = 0
        var darkMenuBar = false
        var color = MiniGraphColor.template
        var engineTilt = 0.0
    }
    /// The mini renderer's own display tilt: fixed at +4.5 dB per octave, whatever the Tilt setting says. The
    /// engine-side spectrum tilt is in the data already, so the renderer tilt goes down by that amount (never
    /// below 0): the total stays +4.5.
    static func miniTilt(engineTilt: Double) -> Float { MiniSpectrumRenderer.tilt(engineTilt: Float(engineTilt)) }

    var isPopoverShown: Bool { popover.isShown }
    /// For design-review snapshots.
    var popoverContentView: NSView? { popover.contentViewController?.view }
    var buttonView: NSView? { item.button }
    var currentImage: NSImage? {
        if let lastCGImage { return NSImage(cgImage: lastCGImage, size: lastImageSize) }
        return lastImage ?? item.button?.image
    }
    func showPopoverForSnapshot() { if !popover.isShown { togglePopover() } }
    func closePopover() { popover.performClose(nil) }
    var isItemVisible: Bool { item.isVisible }

    init(model: AppModel, actions: ShellActions) {
        self.model = model
        self.settings = model.settings
        self.actions = actions
        item = NSStatusBar.system.statusItem(withLength: CGFloat(model.settings.miniGraphWidth) + 8)
        popoverSpectrum = SpectrumView(frameProvider: model.liveFrameProvider)
        readouts = PopoverReadouts(frameProvider: model.liveFrameProvider)
        super.init()

        item.autosaveName = "JoseonMiniGraph"
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Joseon"
            button.setAccessibilityLabel("Joseon mini spectrum")
            button.setAccessibilityHelp("Shows the spectrum of the audio this Mac plays. Press to open the Joseon popover.")
            if usesLayer {
                graphView.frame = button.bounds
                graphView.autoresizingMask = [.height]
                graphView.onAppearanceChange = { [weak self] in self?.redraw() }
                button.addSubview(graphView)
                nowPlayingView.frame = NSRect(x: button.bounds.width, y: 0, width: 0, height: button.bounds.height)
                nowPlayingView.autoresizingMask = [.height]
                nowPlayingView.isHidden = true
                button.addSubview(nowPlayingView)
            }
        }

        var options = SpectrumViewOptions()
        options.showLeftRight = false
        options.showAverage = false
        options.showHeadphoneOverlay = false
        popoverSpectrum.options = options
        // 120 pt of graph: the stress spans and their labels belong to the main window.
        popoverSpectrum.showStressBands = false
        popoverSpectrum.theme = Palette.current
        popoverSpectrum.isPaused = true
        popoverSpectrum.setAccessibilityElement(true)
        popoverSpectrum.setAccessibilityRole(.image)
        popoverSpectrum.setAccessibilityLabel("Spectrum graph")

        popover.behavior = .transient
        popover.animates = !Palette.reduceMotion
        popover.delegate = self
        popover.appearance = NSAppearance(named: .darkAqua)
        let content = PopoverView(model: model, settings: model.settings, readouts: readouts, spectrum: popoverSpectrum, actions: ShellActions(
            openMainWindow: { [weak self] in self?.popover.performClose(nil); actions.openMainWindow() },
            openSettings: { [weak self] in self?.popover.performClose(nil); actions.openSettings() },
            openPrivacySettings: actions.openPrivacySettings,
            quit: actions.quit))
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        // The item's length and its two parts: the graph slot, and the now-playing text while a track is known.
        Publishers.CombineLatest4(settings.$miniGraphWidth, settings.$showNowPlaying, settings.$nowPlayingInMenuBar, settings.$nowPlayingMenuBarWidth)
            .map { _ in () }
            .merge(with: model.$nowPlaying.map { _ in () }, settings.$nowPlayingShowsHiRes.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateLayout() }
            .store(in: &cancellables)
        settings.$miniGraphColor.map { _ in () }
            .merge(with: settings.$tiltDBPerOctave.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.redraw() }
            .store(in: &cancellables)

        reschedule()
        redraw()
    }

    /// Signal present: look for a new frame 40 times per second (20 with Reduce Motion) and draw each new
    /// frame once. With only the mini graph on screen the engine makes 20 frames per second, so the graph
    /// draws at 20 Hz; a turn without a new frame costs a few microseconds. Silence: 1 Hz.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        reschedule()
        redraw()
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
    }

    /// The status item: the graph slot (graph width + 8) and, while a track is known and the settings allow, the
    /// now-playing text to its right. Without a track the item is as wide as it was before the feature.
    private func updateLayout() {
        let track = model.nowPlaying
        let showMarquee = usesLayer && track != nil && settings.showNowPlaying && settings.nowPlayingInMenuBar
        let graphSlot = CGFloat(settings.miniGraphWidth) + 8
        let marqueeWidth: CGFloat = showMarquee ? CGFloat(settings.nowPlayingMenuBarWidth) : 0
        let length = graphSlot + (showMarquee ? marqueeWidth + Self.marqueeTrailing : 0)
        if item.length != length { item.length = length }
        let text = showMarquee ? track.map { NowPlayingMarquee.displayText(for: $0, showsHiRes: settings.nowPlayingShowsHiRes) } ?? "" : ""
        if let button = item.button {
            let height = button.bounds.height
            graphView.frame = NSRect(x: 0, y: 0, width: graphSlot, height: height)
            nowPlayingView.frame = NSRect(x: graphSlot, y: 0, width: marqueeWidth, height: height)
            // The marquee passes clicks and tooltips to the button: the button carries the full text.
            button.toolTip = text.isEmpty ? "Joseon" : "Joseon \u{2014} \(text)"
            button.setAccessibilityLabel(text.isEmpty ? "Joseon mini spectrum" : "Joseon mini spectrum. Now playing: \(text)")
        }
        nowPlayingView.showsHiRes = settings.nowPlayingShowsHiRes
        nowPlayingView.nowPlaying = showMarquee ? track : nil
        nowPlayingView.isHidden = !showMarquee
        redraw()
    }

    private func reschedule() {
        timer?.invalidate()
        let interval: TimeInterval = active ? (Palette.reduceMotion ? 1.0 / 20.0 : 1.0 / 40.0) : 1.0
        DebugLog.log("mini graph interval \(interval) s")
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.redraw() }
        t.tolerance = active ? 0.008 : 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func redraw() {
        guard let button = item.button else { return }
        let size = CGSize(width: CGFloat(settings.miniGraphWidth), height: graphHeight)
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let frame = model.liveFrameProvider()
        let dark = graphView.isDarkMenuBar(fallback: button)
        let key = DrawKey(hostTime: frame.hostTime, width: settings.miniGraphWidth, scale: scale, darkMenuBar: dark,
                          color: settings.miniGraphColor, engineTilt: settings.tiltDBPerOctave)
        // The picture depends only on the frame and on these settings: nothing new, nothing to draw.
        guard key != lastDrawKey else { return }
        // At most 20 pictures per second (10 with Reduce Motion), also while the engine runs at 60 Hz for the
        // panels. A settings change draws at once.
        let now = ProcessInfo.processInfo.systemUptime
        var sameSettings = key
        sameSettings.hostTime = lastDrawKey.hostTime
        if sameSettings == lastDrawKey, now - lastDrawTime < (Palette.reduceMotion ? 0.095 : 0.045) { return }
        lastDrawKey = key
        lastDrawTime = now

        renderer.tiltDBPerOctave = Self.miniTilt(engineTilt: settings.tiltDBPerOctave)
        switch settings.miniGraphColor {
        case .template:
            // The layer path gets no template tint from the menu bar: draw in the menu bar's text color.
            renderer.accentColor = usesLayer ? (dark ? .white : .black) : nil
        case .orange: renderer.accentColor = Palette.miniGraphOrange
        case .accent: renderer.accentColor = Palette.accent
        }
        guard usesLayer else {
            var image = renderer.image(for: frame, size: size, scale: scale)
            // A renderer that draws nothing (the stub) would make the status item invisible.
            if image.representations.isEmpty { image = FallbackMiniGraph.image(for: frame, size: size) }
            lastImage = image
            graphView.isHidden = true
            button.image = image
            return
        }
        // The renderer makes the bitmap in the layer-native format (BGRA, premultiplied first): it goes to the
        // layer as it is. No NSImage, no channel swap, no color match on commit.
        guard let cgImage = renderer.cgImage(for: frame, size: size, scale: scale) else { return }
        // Same pixels as the last update (steady tone, silence): no commit at all.
        let bitmap = cgImage.dataProvider?.data
        if let bitmap, let lastBitmap, CFEqual(bitmap, lastBitmap), graphView.graphSize == size { return }
        lastBitmap = bitmap
        lastCGImage = cgImage
        lastImageSize = size
        graphView.show(cgImage, size: size, scale: scale)

        // AppKit keeps copies of the item ("replicants") for other menu bars and draws them from the button.
        // Once per second is enough for those, and costs little.
        if now - lastReplicantRefresh >= 1 {
            lastReplicantRefresh = now
            button.needsDisplay = true
        }
    }

    // MARK: Click

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            readouts.start()
            popoverSpectrum.isPaused = false
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            model.consumersDidChange()
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverSpectrum.isPaused = true
        readouts.stop()
        model.consumersDidChange()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Open Joseon", checked: false, handler: actions.openMainWindow))
        menu.addItem(ClosureMenuItem(title: "Reset Measurement", checked: false) { [weak self] in self?.model.resetMeasurement() })
        menu.addItem(ClosureMenuItem(title: "Settings…", checked: false, handler: actions.openSettings))
        menu.addItem(ClosureMenuItem(title: "Now Playing in Menu Bar", checked: settings.nowPlayingInMenuBar) { [weak self] in
            self?.settings.nowPlayingInMenuBar.toggle()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit Joseon", checked: false, handler: actions.quit))
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
}

/// Shows the mini graph as layer contents, centered in the status bar button. Clicks go to the button.
final class MiniGraphLayerView: NSView {
    private let imageLayer = CALayer()
    private(set) var graphSize = CGSize.zero
    var onAppearanceChange: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(imageLayer)
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        // No implicit 0.25 s crossfade between two pictures.
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "contentsScale": NSNull()]
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ image: CGImage, size: CGSize, scale: CGFloat) {
        if size != graphSize || imageLayer.contentsScale != scale {
            graphSize = size
            imageLayer.contentsScale = scale
            needsLayout = true
        }
        imageLayer.contents = image
    }

    override func layout() {
        super.layout()
        // Whole pixels, so the bitmap maps 1:1.
        let scale = max(imageLayer.contentsScale, 1)
        let x = ((bounds.width - graphSize.width) / 2 * scale).rounded() / scale
        let y = ((bounds.height - graphSize.height) / 2 * scale).rounded() / scale
        imageLayer.frame = CGRect(x: x, y: y, width: graphSize.width, height: graphSize.height)
    }

    private var darkMenuBar: Bool?

    /// The menu bar is dark or light with the wallpaper. Cached: the lookup is not free at 20 Hz.
    func isDarkMenuBar(fallback: NSView) -> Bool {
        if let darkMenuBar { return darkMenuBar }
        let appearance = superview == nil ? fallback.effectiveAppearance : effectiveAppearance
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        darkMenuBar = dark
        return dark
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        darkMenuBar = nil
        onAppearanceChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        darkMenuBar = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Plain bar graph for the menu bar. Used only when MiniSpectrumRenderer returns an empty image.
enum FallbackMiniGraph {
    static func image(for frame: AnalysisFrame, size: CGSize) -> NSImage {
        let mid = frame.spectrum.mid
        let freqs = frame.spectrum.frequencies
        let barCount = max(Int(size.width / 3), 4)
        var levels = [CGFloat](repeating: 0, count: barCount)
        if mid.count == freqs.count, !mid.isEmpty {
            let lo = log10(Float(30)), hi = log10(Float(18_000))
            for i in 0..<mid.count where freqs[i] >= 30 && freqs[i] <= 18_000 {
                let pos = (log10(freqs[i]) - lo) / (hi - lo)
                let bar = min(barCount - 1, max(0, Int(pos * Float(barCount))))
                let level = CGFloat(min(max((mid[i] + 84) / 72, 0), 1))
                levels[bar] = max(levels[bar], level)
            }
        }
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            // Baseline: the item stays visible at silence.
            NSRect(x: 0, y: 1, width: rect.width, height: 1).fill()
            let step = rect.width / CGFloat(barCount)
            for (i, level) in levels.enumerated() where level > 0 {
                NSRect(x: CGFloat(i) * step, y: 2, width: max(step - 1, 1), height: level * (rect.height - 3)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Popover

/// Numbers for the popover. The timer runs only while the popover is open.
final class PopoverReadouts: ObservableObject {
    struct Values: Equatable {
        var momentary = "—"
        var integrated = "—"
        var truePeak = "—"
        var correlation = "—"
        var truePeakOver = false
    }

    @Published private(set) var values = Values()
    /// True while the popover is open. The now-playing marquee runs its timer only then.
    @Published private(set) var isRunning = false
    private let frameProvider: FrameProvider
    private var timer: Timer?

    init(frameProvider: @escaping FrameProvider) { self.frameProvider = frameProvider }

    func start() {
        stop()
        isRunning = true
        update()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.update() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    /// A level at the floor means "no measurement yet": show a dash, not a number.
    static func level(_ value: Float) -> String {
        value <= -119 || !value.isFinite ? "—" : TrackSummary.signed(value)
    }

    private func update() {
        let frame = frameProvider()
        var v = Values()
        v.momentary = Self.level(frame.loudness.momentaryLUFS)
        v.integrated = frame.loudness.isIntegratedValid ? Self.level(frame.loudness.integratedLUFS) : "—"
        let tp = max(frame.loudness.truePeakLeftDBTP, frame.loudness.truePeakRightDBTP)
        v.truePeak = tp <= -119 || !tp.isFinite ? "—" : NumberText.signed(tp, plus: true)
        v.truePeakOver = tp > -1
        // Correlation has no meaning without signal.
        let noStereoData = frame.stereo.scopePoints.isEmpty && frame.stereo.correlation == 0
        v.correlation = (frame.isSilent || noStereoData) ? "—" : NumberText.signed(frame.stereo.correlation, decimals: 2, plus: true)
        if v != values { values = v }
    }
}

struct PanelHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var readouts: PopoverReadouts
    let spectrum: SpectrumView
    var actions: ShellActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StateBadge(state: model.header.state)
                // The track title after the source name ("Qobuz"), small and grey; it scrolls when it does not fit.
                StreamBlock(header: model.header,
                            nowPlaying: settings.showNowPlaying ? model.nowPlaying : nil,
                            showsHiRes: settings.nowPlayingShowsHiRes,
                            marqueeActive: readouts.isRunning)
                Spacer(minLength: 0)

            }

            PanelHost(view: spectrum)
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: Palette.cardBorder), lineWidth: 1))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.joseonPanel))

            HStack(spacing: 0) {
                Readout(title: "LUFS M", value: readouts.values.momentary, spoken: "Loudness momentary, LUFS")
                Readout(title: "LUFS I", value: readouts.values.integrated, spoken: "Loudness integrated, LUFS")
                Readout(title: "TRUE PEAK", value: readouts.values.truePeak, spoken: "True peak, dB TP",
                        color: readouts.values.truePeakOver ? .joseonDanger : nil)
                Readout(title: "CORR", value: readouts.values.correlation, spoken: "Phase correlation")
            }

            HStack(spacing: 6) {
                Button("Open Joseon", action: actions.openMainWindow)
                    .keyboardShortcut(.defaultAction)
                Button("Reset") { model.resetMeasurement() }
                    .accessibilityLabel("Reset measurement")
                Spacer(minLength: 0)
                Button("Settings…", action: actions.openSettings)
                Button("Quit", action: actions.quit)
                    .accessibilityLabel("Quit Joseon")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 340)
        .background(Color.joseonBackground)
        .foregroundStyle(Color.joseonText)
    }
}

struct Readout: View {
    var title: String
    var value: String
    var spoken: String
    var color: Color?

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .medium).monospacedDigit())
                .foregroundStyle(color ?? Color.primary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityValue(value == "—" ? "no value" : value)
    }
}
