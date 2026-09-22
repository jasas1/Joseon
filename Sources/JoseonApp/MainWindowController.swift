import AppKit
import SwiftUI
import Combine
import JoseonCore
import JoseonRender

/// Window facts the SwiftUI header needs.
final class MainWindowState: ObservableObject {
    @Published var isFullScreen = false
}

/// Plain keys (Space, R, F) arrive here only when no focused control used them,
/// so full keyboard access keeps Space for the focused button.
final class MainWindow: NSWindow {
    var plainKeyHandler: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let blocked: NSEvent.ModifierFlags = [.command, .control, .option]
        if event.modifierFlags.intersection(blocked).isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased(),
           plainKeyHandler?(key) == true {
            return
        }
        super.keyDown(with: event)
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let settings: AppSettings
    private let windowState = MainWindowState()
    private var cancellables = Set<AnyCancellable>()

    private let spectrumView: SpectrumView
    private let spectrogramView: SpectrogramView
    private let vectorscopeView: VectorscopeView
    private let metersView: MetersView
    private let spectrumCard: PanelCardView
    private let spectrogramCard: PanelCardView
    private let vectorscopeCard: PanelCardView
    private let metersCard: PanelCardView
    /// "Spectrum" layout only: stereo placement beside the spectrogram. Both have frequency on the vertical axis.
    private let placementView: VectorscopeView
    /// One cursor shared by every panel of this window.
    private let cursorLink = PanelCursorLink()
    private let placementCard: PanelCardView
    /// The session timeline strip under the panels, in every layout (⌘5). See `TimelineStripSplitView`.
    private let timelineView: JoseonRender.TimelineView
    private let timelineCard: PanelCardView
    private var allCards: [PanelCardView] { [spectrumCard, spectrogramCard, vectorscopeCard, metersCard, placementCard, timelineCard] }
    /// "Scope | Placement" in the title row of the stereo card.
    private let stereoModeControl = NSSegmentedControl(labels: ["Scope", "Placement"], trackingMode: .selectOne, target: nil, action: nil)
    static let scopeTitle = "Vectorscope"
    static let placementTitle = "Stereo placement"

    private let root = NSView()
    private let body = NSView()
    private var builtLayoutKey: String?
    /// The app delegate sets this when the app quits.
    var isTerminating = false

    /// The shell asks this to decide the engine rate.
    var isContentVisible: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    init(model: AppModel, actions: ShellActions) {
        self.model = model
        self.settings = model.settings

        spectrumView = SpectrumView(frameProvider: model.frameProvider)
        spectrogramView = SpectrogramView(frameProvider: model.frameProvider)
        vectorscopeView = VectorscopeView(frameProvider: model.frameProvider)
        metersView = MetersView(frameProvider: model.frameProvider)
        spectrumCard = PanelCardView(title: "Spectrum", panel: spectrumView)
        spectrogramCard = PanelCardView(title: "Spectrogram", panel: spectrogramView)
        vectorscopeCard = PanelCardView(title: "Vectorscope", panel: vectorscopeView)
        metersCard = PanelCardView(title: "Loudness and peak", panel: metersView)
        placementView = VectorscopeView(frameProvider: model.frameProvider)
        placementView.mode = .panSpectrum
        placementCard = PanelCardView(title: Self.placementTitle, panel: placementView)
        placementCard.placeholderStyle = .titleRow
        timelineView = JoseonRender.TimelineView(frameProvider: model.frameProvider,
                                                 sessionProvider: model.sessionProvider)
        // A snapshot run draws a MADE-UP record in the strip (`SnapshotOnlySessionSeed`): the title says so, because
        // its clips and overs do not belong to the meters beside it. A normal run never sees the seed.
        timelineCard = PanelCardView(title: DebugSnapshot.directory != nil ? "Session timeline \u{00B7} demo record" : "Session timeline", panel: timelineView)
        for panel in [spectrumView, spectrogramView, vectorscopeView, metersView, placementView, timelineView] as [PanelView] {
            panel.cursorLink = cursorLink
        }
        // These two keep scales and readouts on screen at silence: the text goes beside the title.
        vectorscopeCard.placeholderStyle = .titleRow
        metersCard.placeholderStyle = .titleRow

        stereoModeControl.controlSize = .small
        stereoModeControl.font = .systemFont(ofSize: 10.5, weight: .medium)
        stereoModeControl.segmentStyle = .rounded
        stereoModeControl.setToolTip("Vectorscope: the left / right sample cloud. Mid is up, side is across.", forSegment: 0)
        stereoModeControl.setToolTip("Stereo placement: where each frequency sits between left and right. ⌘4 switches.", forSegment: 1)
        stereoModeControl.setAccessibilityLabel("Stereo view")
        stereoModeControl.setAccessibilityHelp("Scope shows the vectorscope. Placement shows the stereo position of each frequency. Command 4 switches.")
        stereoModeControl.sizeToFit()
        vectorscopeCard.accessoryView = stereoModeControl

        let window = MainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Joseon"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // An empty unified toolbar makes the title bar as tall as the header strip,
        // so the traffic lights sit on the header's center line.
        let toolbar = NSToolbar(identifier: "JoseonMainToolbar")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Palette.background
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 560)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.isRestorable = true
        window.identifier = NSUserInterfaceItemIdentifier("JoseonMainWindow")

        super.init(window: window)
        window.delegate = self
        window.plainKeyHandler = { [weak self] key in self?.handlePlainKey(key) ?? false }
        stereoModeControl.target = self
        stereoModeControl.action = #selector(stereoModeChanged(_:))

        buildContent(actions: actions)
        window.center()
        window.setFrameAutosaveName("JoseonMainWindow")

        configureMenus()
        applyPanelOptions()
        rebuildLayout()
        updatePauseState()

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyPanelOptions()
                self?.rebuildLayout()
            }
            .store(in: &cancellables)
        // A/B compare: a new active reference, a rename, another headphone (it decides the lane mode).
        model.comparison.$references.map { _ in () }
            .merge(with: model.comparison.$activeID.map { _ in () }, model.$headphoneModelName.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyComparison() }
            .store(in: &cancellables)
        model.$panelPlaceholder.combineLatest(model.$isFrozen)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, frozen in
                self?.applyPlaceholder()
                // A frozen display: the header has the one "Paused" pill. The cards only dim.
                self?.allCards.forEach { $0.isDimmed = frozen }
            }
            .store(in: &cancellables)
        model.$isIdle.combineLatest(model.$isFrozen)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePauseState() }
            .store(in: &cancellables)
        // One dose on every surface: the meters block gets the dose rule of the header and the SAME ledger figure
        // (stored, new every day / ISO week) the header ring shows. The header state changes with every shown percent.
        model.spl.$header
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyEarDose() }
            .store(in: &cancellables)
        applyEarDose()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Content

    private func buildContent(actions: ShellActions) {
        guard let window else { return }
        root.wantsLayer = true
        root.layer?.backgroundColor = Palette.background.cgColor

        let top = NSHostingView(rootView: TopAreaView(model: model, settings: settings, windowState: windowState, actions: actions))
        // The height comes from the model (header + banners + flag strip), not from SwiftUI:
        // SwiftUI must never drive the window size, and the view sits under the title bar.
        top.sizingOptions = []
        top.safeAreaRegions = []
        top.translatesAutoresizingMaskIntoConstraints = false
        let topHeight = top.heightAnchor.constraint(equalToConstant: TopAreaView.height(banners: 0))
        topHeight.isActive = true
        model.$captureError.map { $0 != nil }.combineLatest(model.$showPermissionBanner, model.spl.$doseBanner.map { $0 != nil })
            .receive(on: DispatchQueue.main)
            .sink { error, permission, dose in
                topHeight.constant = TopAreaView.height(banners: (error ? 1 : 0) + (permission ? 1 : 0) + (dose ? 1 : 0))
            }
            .store(in: &cancellables)

        body.translatesAutoresizingMaskIntoConstraints = false
        body.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(bodyFrameChanged), name: NSView.frameDidChangeNotification, object: body)
        root.addSubview(top)
        root.addSubview(body)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 1),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        window.contentView = root
    }

    /// Build the split tree for the current preset. Cards that are not in the preset leave the window.
    private func rebuildLayout() {
        let preset = settings.layoutPreset
        let withPlacement = preset == .spectrum && settings.spectrumShowsPlacement && placementFits
        let withTimeline = settings.showTimeline
        let key = preset.rawValue + (withPlacement ? "+placement" : "") + (withTimeline ? "+timeline" : "")
        guard key != builtLayoutKey else { return }
        builtLayoutKey = key
        body.subviews.forEach { $0.removeFromSuperview() }
        allCards.forEach { $0.removeFromSuperview() }

        let panels: NSView
        /// Smallest height of the panel area: the minimums of its rows and the gap between them. The timeline strip
        /// gives way under it.
        let panelsMinimum: CGFloat
        switch preset {
        case .essential:
            // Looked at in snapshots at 900, 1080 and 1280 pt: the stereo card needs about a third of the row, or
            // the scope is a thumbnail above its table. At 900 pt the row is 864 pt: 320 / 268 / 276.
            let bottom = PersistentSplitView(key: "essential.bottom", vertical: true,
                                             panes: [spectrogramCard, vectorscopeCard, metersCard], fractions: [0.37, 0.31, 0.32],
                                             minimums: [240, 260, 264])
            panels = PersistentSplitView(key: "essential.main", vertical: false, panes: [spectrumCard, bottom], fractions: [0.53, 0.47],
                                       // 229 + 228 pt: at the minimum window height (560 pt, 457 pt for the two rows) the
                                       // stereo panel keeps 200 pt, room for a scope of 120 pt and more above its correlation
                                       // row and band table, and the spectrum panel keeps the 200 pt its full layout needs
                                       // (under 200 pt the spectrum drops its legend row).
                                       minimums: [229, 228])
            panelsMinimum = 229 + 8 + 228
        case .spectrum:
            if withPlacement {
                let bottom = PersistentSplitView(key: "spectrum.bottom", vertical: true, panes: [spectrogramCard, placementCard], fractions: [0.68, 0.32],
                                                 minimums: [320, 280])
                panels = PersistentSplitView(key: "spectrum.withPlacement", vertical: false, panes: [spectrumCard, bottom],
                                             fractions: [1 - Self.placementRowShare, Self.placementRowShare],
                                             minimums: [200, Self.placementMinimumCardHeight])
                panelsMinimum = 200 + 8 + Self.placementMinimumCardHeight
            } else {
                // 200 pt: the spectrum keeps its legend row. 140 pt: the spectrogram keeps a readable frequency axis.
                panels = PersistentSplitView(key: "spectrum.main", vertical: false, panes: [spectrumCard, spectrogramCard], fractions: [0.55, 0.45],
                                             minimums: [200, 140])
                panelsMinimum = 200 + 8 + 140
            }
        case .metering:
            let side = PersistentSplitView(key: "metering.side", vertical: false, panes: [vectorscopeCard, spectrumCard], fractions: [0.58, 0.42],
                                           minimums: [230, 170])
            panels = PersistentSplitView(key: "metering.main", vertical: true, panes: [metersCard, side], fractions: [0.58, 0.42],
                                         minimums: [420, 340])
            panelsMinimum = 230 + 8 + 170
        }
        let tree: NSView
        if withTimeline {
            let split = TimelineStripSplitView(content: panels, strip: timelineCard, contentMinimum: panelsMinimum)
            // The strip hides when the window is too low for it: its panel pauses then.
            split.onStripVisibilityChange = { [weak self] in self?.updatePauseState() }
            tree = split
        } else {
            tree = panels
        }
        body.addSubview(tree)
        NSLayoutConstraint.activate([
            tree.topAnchor.constraint(equalTo: body.topAnchor),
            tree.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            tree.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            tree.trailingAnchor.constraint(equalTo: body.trailingAnchor),
        ])
        updatePauseState()
        applyPlaceholder()
        if let window, window.isVisible {
            NSAccessibility.post(element: window, notification: .layoutChanged)
        }
    }

    /// "Waiting for audio" shows once in the header. In the body, only the largest card of the layout
    /// repeats it, as one quiet plate. The other cards stay plain.
    private var placeholderCard: PanelCardView {
        settings.layoutPreset == .metering ? metersCard : spectrumCard
    }

    private func applyPlaceholder() {
        let text = model.panelPlaceholder?.text
        let target = placeholderCard
        for card in allCards { card.placeholderText = card === target ? text : nil }
    }

    /// "Spectrum" layout: the placement card shows only when it gets at least this height. Its frequency axis
    /// and the correlation table under it need the room (seen in snapshots: 361 pt at 1280×800 reads well, 277 pt
    /// at 1080×640 squeezes the field, 236 pt at 900×560 is a thumbnail). Under it the card is absent, and
    /// ⌘4 shows placement in "Essential".
    static let placementMinimumCardHeight: CGFloat = 300
    private static let placementRowShare: CGFloat = 0.52
    var placementFits: Bool {
        var bodyHeight = body.bounds.height
        if bodyHeight < 1 {
            let content = window?.contentView?.bounds.height ?? 800
            bodyHeight = content - TopAreaView.height(banners: 0) - 9
        }
        // With the timeline strip on, the card has to fit above the strip at its smallest. So the strip never comes
        // and goes as the window grows: a higher window first shows the strip, then the strip and the card.
        if settings.showTimeline { bodyHeight -= TimelineStripSplitView.smallestReserve }
        return (bodyHeight - 8) * Self.placementRowShare >= Self.placementMinimumCardHeight
    }

    func windowDidResize(_ notification: Notification) {
        if settings.layoutPreset == .spectrum { rebuildLayout() }
    }

    /// A banner takes height from the body: the placement card may have to go.
    @objc private func bodyFrameChanged() {
        if settings.layoutPreset == .spectrum { rebuildLayout() }
    }

    // MARK: Pause

    /// A panel draws only when it is in the window, the window is on screen,
    /// the display is not frozen, and the input is not idle-silent.
    private func updatePauseState() {
        model.consumersDidChange()
        let hidden = !isContentVisible || model.isFrozen || model.isIdle
        for card in allCards {
            let paused = hidden || card.window == nil || card.superview == nil || card.isHiddenOrHasHiddenAncestor
            if card.panel.isPaused != paused {
                card.panel.isPaused = paused
                DebugLog.log("panel \(card.panel.kind.rawValue) paused \(paused)")
            }
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        DebugLog.log("main window on screen \(isContentVisible)")
        updatePauseState()
    }
    func windowDidMiniaturize(_ notification: Notification) { updatePauseState() }
    func windowDidDeminiaturize(_ notification: Notification) { updatePauseState() }
    func windowWillClose(_ notification: Notification) {
        // AppKit also closes the window at quit (seen in the launch test): that is not a user close.
        if !isTerminating { settings.mainWindowWasOpen = false }
        DispatchQueue.main.async { [weak self] in self?.updatePauseState() }
    }
    func windowDidEnterFullScreen(_ notification: Notification) { windowState.isFullScreen = true }
    func windowWillExitFullScreen(_ notification: Notification) { windowState.isFullScreen = false }

    func show() {
        guard let window else { return }
        settings.mainWindowWasOpen = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updatePauseState()
        if DebugLog.enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak window] in
                guard let window else { return }
                DebugLog.log("main window: visible \(window.isVisible) key \(window.isKeyWindow) occlusionVisible \(window.occlusionState.contains(.visible)) appActive \(NSApp.isActive)")
            }
        }
    }

    @objc private func displayOptionsChanged() {
        window?.backgroundColor = Palette.background
        root.layer?.backgroundColor = Palette.background.cgColor
        allCards.forEach { $0.applyColors() }
    }

    @objc private func stereoModeChanged(_ sender: NSSegmentedControl) {
        settings.stereoPlacementMode = sender.selectedSegment == 1
    }

    // MARK: Keys

    private func handlePlainKey(_ key: String) -> Bool {
        switch key {
        case " ": model.toggleFreeze(); return true
        case "r": model.resetMeasurement(); return true
        case "f": window?.toggleFullScreen(nil); return true
        case "\u{1B}":   // Esc clears the linked cursor from anywhere in the window
            guard cursorLink.cursor != nil else { return false }
            cursorLink.clear(); return true
        default: return false
        }
    }

    // MARK: Panel options

    private func applyPanelOptions() {
        let options = settings.spectrumViewOptions
        if spectrumView.options != options {
            spectrumView.options = options
            spectrumView.needsDisplay = true
        }
        if spectrumView.autoRange != settings.spectrumAutoRange { spectrumView.autoRange = settings.spectrumAutoRange }
        let scopeMode: VectorscopeMode = settings.stereoPlacementMode ? .panSpectrum : .lissajous
        if vectorscopeView.mode != scopeMode { vectorscopeView.mode = scopeMode }
        let segment = settings.stereoPlacementMode ? 1 : 0
        if stereoModeControl.selectedSegment != segment { stereoModeControl.selectedSegment = segment }
        vectorscopeCard.title = settings.stereoPlacementMode ? Self.placementTitle : Self.scopeTitle
        if metersView.targetLUFS != settings.loudnessTarget.lufs { metersView.targetLUFS = settings.loudnessTarget.lufs }
        if timelineView.targetLUFS != settings.loudnessTarget.lufs { timelineView.targetLUFS = settings.loudnessTarget.lufs }
        if timelineView.windowSeconds != settings.timelineWindowSeconds { timelineView.windowSeconds = settings.timelineWindowSeconds }
        if timelineView.showBands != settings.timelineShowBands { timelineView.showBands = settings.timelineShowBands }
        if timelineView.showLevelAtEar != settings.timelineShowEarLane { timelineView.showLevelAtEar = settings.timelineShowEarLane }
        let history = Double(settings.spectrogramHistorySeconds)
        if spectrogramView.historySeconds != history {
            spectrogramView.historySeconds = history
            spectrogramView.needsDisplay = true
        }
        applyComparison()
    }

    private func applyEarDose() {
        let standard: JoseonRender.DoseStandard = model.spl.store.doseStandard == .nioshDaily ? .nioshDaily : .whoWeekly
        if metersView.doseStandard != standard { metersView.doseStandard = standard }
        metersView.setDoseLedger(EarDoseLedger(nioshToday: model.spl.doseToday, whoWeek: model.spl.doseWeek))
    }

    /// A/B compare: the active reference goes to the spectrum and the meters of this window. The compact spectrum of
    /// the menu bar popover gets no comparison.
    private func applyComparison() {
        let comparison = model.comparison
        let reference = comparison.active?.snapshot
        let levelMatch = settings.comparisonLevelMatch
        let mode = comparison.effectiveMode(currentHeadphone: model.headphoneModelName)
        let tilt = Float(settings.tiltDBPerOctave)
        if spectrumView.comparison?.id != reference?.id || spectrumView.comparison?.name != reference?.name { spectrumView.comparison = reference }
        if metersView.comparison?.id != reference?.id || metersView.comparison?.name != reference?.name { metersView.comparison = reference }
        if spectrumView.comparisonLevelMatch != levelMatch { spectrumView.comparisonLevelMatch = levelMatch }
        if metersView.comparisonLevelMatch != levelMatch { metersView.comparisonLevelMatch = levelMatch }
        if spectrumView.comparisonMode != mode { spectrumView.comparisonMode = mode }
        if spectrumView.liveTiltDBPerOctave != tilt { spectrumView.liveTiltDBPerOctave = tilt }
        if metersView.liveTiltDBPerOctave != tilt { metersView.liveTiltDBPerOctave = tilt }
    }

    private func configureMenus() {
        spectrumCard.menuProvider = { [weak self] in self?.spectrumMenu() ?? NSMenu() }
        spectrogramCard.menuProvider = { [weak self] in self?.spectrogramMenu() ?? NSMenu() }
        placementCard.menuProvider = { [weak self] in
            guard let self else { return NSMenu() }
            let s = self.settings
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(title: "Hide Stereo Placement  (⌘4)", checked: false) { s.spectrumShowsPlacement = false })
            menu.addItem(.separator())
            self.addCommonItems(to: menu)
            return menu
        }
        vectorscopeCard.menuProvider = { [weak self] in
            guard let self else { return NSMenu() }
            let s = self.settings
            let menu = NSMenu()
            menu.addItem(self.header("View"))
            menu.addItem(ClosureMenuItem(title: "Vectorscope", checked: !s.stereoPlacementMode) { s.stereoPlacementMode = false })
            let placement = ClosureMenuItem(title: "Stereo Placement (by frequency)", checked: s.stereoPlacementMode) { s.stereoPlacementMode = true }
            placement.toolTip = "⌘4 switches between the vectorscope and the stereo placement"
            menu.addItem(placement)
            menu.addItem(.separator())
            self.addCommonItems(to: menu)
            return menu
        }
        timelineCard.menuProvider = { [weak self] in self?.timelineMenu() ?? NSMenu() }
        metersView.onClipIndicatorClick = { [weak self] in self?.model.resetMeasurement() }
        metersCard.menuProvider = { [weak self] in
            guard let self else { return NSMenu() }
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(title: "Reset Measurement", checked: false) { [weak self] in self?.model.resetMeasurement() })
            menu.addItem(.separator())
            // The loudness target lives here. The strip above shows its control only while a target is set.
            menu.addItem(self.header("Loudness Target"))
            let s = self.settings
            for target in LoudnessTarget.allCases {
                let item = ClosureMenuItem(title: target.title, checked: s.loudnessTarget == target) { s.loudnessTarget = target }
                if target == .off { item.toolTip = "No target line in the meters, and no target control in the strip" }
                menu.addItem(item)
            }
            menu.addItem(.separator())
            self.addCommonItems(to: menu)
            return menu
        }
    }

    private func spectrumMenu() -> NSMenu {
        let s = settings
        let menu = NSMenu()
        menu.addItem(header("Traces"))
        menu.addItem(ClosureMenuItem(title: "Left and Right", checked: s.showLeftRight) { s.showLeftRight.toggle() })
        menu.addItem(ClosureMenuItem(title: "Mid", checked: s.showMid) { s.showMid.toggle() })
        let side = ClosureMenuItem(title: "Side (L\u{2212}R)", checked: s.showSide) { s.showSide.toggle() }
        side.toolTip = "What differs between left and right: the stereo part of the music"
        menu.addItem(side)
        menu.addItem(ClosureMenuItem(title: "Peak Hold", checked: s.showPeakHold) { s.showPeakHold.toggle() })
        menu.addItem(ClosureMenuItem(title: "Average", checked: s.showAverage) { s.showAverage.toggle() })
        menu.addItem(ClosureMenuItem(title: "Headphone Overlay", checked: s.showHeadphoneOverlay) { s.showHeadphoneOverlay.toggle() })
        ComparisonMenu.addToggles(to: menu, model: model, header: header("Compare"))
        menu.addItem(.separator())
        menu.addItem(header("Tilt"))
        for tilt in AppSettings.tiltChoices {
            menu.addItem(ClosureMenuItem(title: Self.tiltTitle(tilt), checked: s.tiltDBPerOctave == tilt) { s.tiltDBPerOctave = tilt })
        }
        menu.addItem(.separator())
        menu.addItem(header("Range"))
        menu.addItem(ClosureMenuItem(title: "Auto (follows the music)", checked: s.spectrumAutoRange) { s.spectrumAutoRange = true })
        for range in AppSettings.dbRangeChoices {
            menu.addItem(ClosureMenuItem(title: "\(range) dB", checked: !s.spectrumAutoRange && s.dbRange == range) { s.dbRange = range; s.spectrumAutoRange = false })
        }
        menu.addItem(.separator())
        addCommonItems(to: menu)
        return menu
    }

    static func tiltTitle(_ tilt: Double) -> String {
        tilt == 0 ? "0 dB per octave (raw)" : "\(tilt == tilt.rounded() ? String(Int(tilt)) : String(tilt)) dB per octave"
    }

    private func spectrogramMenu() -> NSMenu {
        let s = settings
        let menu = NSMenu()
        menu.addItem(header("History"))
        for seconds in AppSettings.historyChoices {
            menu.addItem(ClosureMenuItem(title: "\(seconds) seconds", checked: s.spectrogramHistorySeconds == seconds) { s.spectrogramHistorySeconds = seconds })
        }
        menu.addItem(.separator())
        if s.layoutPreset == .spectrum {
            menu.addItem(ClosureMenuItem(title: "Stereo Placement Beside the Spectrogram  (⌘4)", checked: s.spectrumShowsPlacement) { s.spectrumShowsPlacement.toggle() })
        }
        addCommonItems(to: menu)
        return menu
    }

    /// The tone lane needs a panel of this height (`TimelineView.showBands`).
    private static let toneLaneMinimumPanelHeight: CGFloat = 260

    private func timelineMenu() -> NSMenu {
        let s = settings
        let menu = NSMenu()
        menu.addItem(header("Window"))
        for seconds in AppSettings.timelineWindowChoices {
            menu.addItem(ClosureMenuItem(title: "\(seconds / 60) minutes", checked: s.timelineWindowSeconds == seconds) { s.timelineWindowSeconds = seconds })
        }
        menu.addItem(.separator())
        let tone = ClosureMenuItem(title: "Show Tone Lane", checked: s.timelineShowBands) { s.timelineShowBands.toggle() }
        if timelineView.bounds.height < Self.toneLaneMinimumPanelHeight {
            tone.toolTip = "The tone lane shows when the timeline is \(Int(Self.toneLaneMinimumPanelHeight)) pt high or more"
        }
        menu.addItem(tone)
        let ear = ClosureMenuItem(title: "Show Level at the Ear Lane", checked: s.timelineShowEarLane) { [weak self] in
            s.timelineShowEarLane.toggle()
            self?.timelineView.reloadSession()
        }
        ear.toolTip = model.spl.status.isCalibrated
            ? "A-weighted level at the ear per second, as a lane of its own"
            : "The lane has data when the level at the ear is set up (\"\(SPLPill.setUpTitle)\" in the strip above)"
        menu.addItem(ear)
        menu.addItem(.separator())
        let clear = ClosureMenuItem(title: "Clear Timeline", checked: false) { [weak self] in
            guard let self else { return }
            self.model.clearSessionRecord()
            self.timelineView.reloadSession()
        }
        clear.toolTip = "Forget the record of this session. It is in memory only."
        menu.addItem(clear)
        menu.addItem(.separator())
        addCommonItems(to: menu)
        return menu
    }

    private func commonMenu() -> NSMenu {
        let menu = NSMenu()
        addCommonItems(to: menu)
        return menu
    }

    private func addCommonItems(to menu: NSMenu) {
        menu.addItem(ClosureMenuItem(title: "Freeze Display", checked: model.isFrozen) { [weak self] in self?.model.toggleFreeze() })
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, checked: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
