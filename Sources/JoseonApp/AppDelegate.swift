import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let settings = AppSettings()
    private lazy var model = AppModel(settings: settings)
    private var mainWindowController: MainWindowController!
    private var statusController: StatusItemController!
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private lazy var calibrationWindow = CalibrationWindowController(controller: model.spl)
    private lazy var measureWindow = MeasureWindowController(makeEnvironment: { [unowned self] in self.measureEnvironment() })
    private var cancellables = Set<AnyCancellable>()

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.processName = "Joseon"
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
        NSApp.mainMenu = buildMainMenu()

        let actions = ShellActions(
            openMainWindow: { [weak self] in self?.showMainWindow(nil) },
            openSettings: { [weak self] in self?.showSettings(nil) },
            openPrivacySettings: { Self.openPrivacySettings() },
            openCalibration: { [weak self] in self?.showCalibration(nil) },
            quit: { [weak self] in self?.quitApp(nil) })
        mainWindowController = MainWindowController(model: model, actions: actions)
        statusController = StatusItemController(model: model, actions: actions)

        // JOSEON_DEBUG_CONSUMERS=panels: run the engine as if the main window were on screen (60 Hz, stereo on).
        // For CPU measurements of the non-panel share from a shell, where the window may open behind other apps.
        // Snapshot mode also does: its window may open behind other apps, and the pictures need the stereo data.
        let forcePanels = ProcessInfo.processInfo.environment["JOSEON_DEBUG_CONSUMERS"] == "panels" || DebugSnapshot.directory != nil
        model.consumerLevel = { [weak self] in
            guard let self, !forcePanels else { return .panels }
            if self.statusController.isPopoverShown || self.mainWindowController.isContentVisible { return .panels }
            return self.statusController.isItemVisible ? .miniGraph : .none
        }
        model.onSignalActivityChange = { [weak self] active in self?.statusController.setActive(active) }
        // "Measure your headphone…" in the headphone menus and in Settings.
        model.openMeasure = { [weak self] in self?.showMeasure(nil) }
        // A sweep must not go on into another output device.
        model.spl.onOutputDeviceChange = { [weak self] in self?.measureWindow.outputDeviceChanged() }

        settings.$showDockIcon
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in self?.applyDockIcon(show) }
            .store(in: &cancellables)

        if settings.hasSeenWelcome {
            model.start()
            if settings.mainWindowWasOpen { mainWindowController.show() }
        } else {
            // First run: explain the permission first. Capture starts after "Continue".
            mainWindowController.show()
            showWelcome()
        }
        if DebugSnapshot.directory != nil { runSnapshots() }
    }

    /// Design-review mode (JOSEON_SNAPSHOT_DIR): draw every window into PNG files, then quit.
    /// Main window: three presets at 1280×800, 1080×640 and 900×560, the stereo placement view, the frozen state.
    /// Then the session and stress list popovers, the settings window, the menu bar popover and the mini graph.
    private func runSnapshots() {
        let original = settings.layoutPreset
        let originalTarget = settings.loudnessTarget
        let originalPlacement = settings.stereoPlacementMode
        let originalTimeline = settings.showTimeline
        // The pictures show the session timeline strip (its default). One picture below shows the window without it.
        settings.showTimeline = true
        // JOSEON_SNAPSHOT_LOUDNESS_TARGET=-14 shows the loudness delta text in the snapshots.
        if let raw = ProcessInfo.processInfo.environment["JOSEON_SNAPSHOT_LOUDNESS_TARGET"], let value = Int(raw),
           let target = LoudnessTarget(rawValue: value) {
            settings.loudnessTarget = target
        }
        let originalFrame = mainWindowController.window?.frame
        var recorder: SnapshotFrameRecorder?
        let mainView: () -> NSView? = { [weak self] in
            let content = self?.mainWindowController.window?.contentView
            return content?.superview ?? content
        }

        var steps: [(delay: Double, run: () -> Void)] = []
        if welcomeWindow != nil {
            steps.append((0.7, { [weak self] in
                let content = self?.welcomeWindow?.contentView
                DebugSnapshot.write(content?.superview ?? content, name: "app-welcome")
                // A sheet blocks terminate: close it the way "Continue" does, without the first-run flag.
                if let sheet = self?.welcomeWindow { self?.mainWindowController.window?.endSheet(sheet) }
                self?.welcomeWindow = nil
                self?.model.start()
            }))
        }
        // The demo signal first runs through the engine offline (two session tracks, then more than 40 s of the
        // track on screen): the pictures start when the live part runs. Other sources have no pre-roll.
        let gateIndex = steps.count
        let isReady: () -> Bool = { [weak self] in
            guard let self else { return true }
            return !(self.model.isDemo && !self.model.isSnapshotReady && self.model.captureError == nil)
        }
        steps.append((0.25, { [weak self] in
            guard let self else { return }
            // The panels in the pictures draw from the frames the app saw, from here on.
            DebugSnapshot.frames.removeAll()
            recorder = SnapshotFrameRecorder(provider: self.model.frameProvider)
        }))
        var wait = 21.0         // a full 20 s history for the spectrogram and the loudness plot
        // JOSEON_SNAPSHOT_ONLY=spl: only the pictures of the "level at the ear" feature (see `splSnapshotSteps`).
        // JOSEON_SNAPSHOT_ONLY=measure: only the pictures of the "Measure your headphone…" window (see `measureSnapshotSteps`).
        let onlyMeasure = ProcessInfo.processInfo.environment["JOSEON_SNAPSHOT_ONLY"] == "measure"
        let onlySPL = ProcessInfo.processInfo.environment["JOSEON_SNAPSHOT_ONLY"] == "spl" || onlyMeasure
        if onlySPL { wait = 4 }
        if onlyMeasure { wait = 1 }
        for size in onlySPL ? [] :  [NSSize(width: 1280, height: 800), NSSize(width: 1080, height: 640), NSSize(width: 900, height: 560)] {
            let tag = "\(Int(size.width))x\(Int(size.height))"
            for preset in LayoutPreset.allCases {
                steps.append((wait, { [weak self] in
                    self?.mainWindowController.window?.setContentSize(size)
                    self?.settings.stereoPlacementMode = false
                    self?.settings.layoutPreset = preset
                }))
                wait = 0.5
                steps.append((0.7, { DebugSnapshot.write(mainView(), name: "app-main-\(preset.rawValue)-\(tag)") }))
            }
            // The stereo card in placement mode (title row: the longer title, or the control alone).
            steps.append((0.3, { [weak self] in
                self?.settings.layoutPreset = .essential
                self?.settings.stereoPlacementMode = true
            }))
            steps.append((0.7, { DebugSnapshot.write(mainView(), name: "app-main-essential-placement-\(tag)") }))
            steps.append((0.3, { [weak self] in self?.settings.layoutPreset = .metering }))
            steps.append((0.7, { DebugSnapshot.write(mainView(), name: "app-main-metering-placement-\(tag)") }))
            // The frozen display: one pill in the header, dimmed cards.
            steps.append((0.3, { [weak self] in
                self?.settings.stereoPlacementMode = false
                self?.settings.layoutPreset = .essential
                self?.model.toggleFreeze()
            }))
            steps.append((0.7, { [weak self] in
                DebugSnapshot.write(mainView(), name: "app-main-essential-frozen-\(tag)")
                self?.model.toggleFreeze()
            }))
        }
        // The window without the session timeline strip (⌘5 off): the panels take the whole body again.
        if !onlySPL {
            steps.append((0.3, { [weak self] in
                self?.mainWindowController.window?.setContentSize(NSSize(width: 1280, height: 800))
                self?.settings.layoutPreset = .essential
                self?.settings.showTimeline = false
            }))
            steps.append((0.7, { [weak self] in
                DebugSnapshot.write(mainView(), name: "app-main-essential-notimeline-1280x800")
                self?.settings.showTimeline = true
            }))
        }
        if !onlyMeasure {
            steps += splSnapshotSteps(firstDelay: wait, mainView: mainView)
            steps += ComparisonSnapshotPictures.steps(model: model)   // only with JOSEON_SNAPSHOT_COMPARE
        }
        steps += measureSnapshotSteps(firstDelay: onlyMeasure ? wait : 0.3)
        if !onlySPL { steps.append((0.3, { [weak self] in
            guard let self else { return }
            DebugSnapshot.write(swiftUI: SessionView(model: self.model, isLive: false), name: "app-session-popover")
            if self.model.stressFlags.count > 2 {
                DebugSnapshot.write(swiftUI: StressFlagList(flags: Array(self.model.stressFlags.dropFirst(2)), modelName: self.model.headphoneModelName),
                                    name: "app-stress-list-popover")
            }
            self.showSettings(nil)
        }))
        steps.append((0.7, { [weak self] in
            DebugSnapshot.write(self?.settingsWindow?.contentView, name: "app-settings")
            self?.statusController.showPopoverForSnapshot()
        }))
        steps.append((0.9, { [weak self] in
            DebugSnapshot.write(self?.statusController.popoverContentView, name: "app-popover")
            self?.statusController.closePopover()
            if let image = self?.statusController.currentImage { DebugSnapshot.write(image, name: "app-mini-graph") }
            // The status bar button as AppKit draws it for its copies: shows that the graph layer is in place.
            DebugSnapshot.write(self?.statusController.buttonView, name: "app-mini-button")
        }))
        }
        steps.append((0.5, { [weak self] in
            recorder?.stop()
            self?.settings.layoutPreset = original
            self?.settings.loudnessTarget = originalTarget
            self?.settings.stereoPlacementMode = originalPlacement
            self?.settings.showTimeline = originalTimeline
            if let originalFrame { self?.mainWindowController.window?.setFrame(originalFrame, display: false) }
            NSApp.terminate(nil)
        }))
        // One after the other: a slow snapshot must not make the next steps run back to back, before the
        // settings reach the window.
        func run(_ index: Int) {
            guard index < steps.count else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + steps[index].delay) {
                if index == gateIndex, !isReady() { run(index); return }
                steps[index].run()
                run(index + 1)
            }
        }
        run(0)
    }

    /// Pictures of the "level at the ear" feature: the main window (header pill, dose banner) at 1280×800 and
    /// 900×560, the level popover, the session popover, the calibration window with each method at its default
    /// size and at its minimum size, and the settings section. The state comes from JOSEON_SNAPSHOT_SPL
    /// (see `SnapshotSPL`). The test tone can not start in snapshot mode.
    private func splSnapshotSteps(firstDelay: Double, mainView: @escaping () -> NSView?) -> [(delay: Double, run: () -> Void)] {
        var steps: [(delay: Double, run: () -> Void)] = []
        var delay = firstDelay
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 900, height: 560)] {
            let tag = "\(Int(size.width))x\(Int(size.height))"
            steps.append((delay, { [weak self] in
                self?.mainWindowController.window?.setContentSize(size)
                self?.settings.stereoPlacementMode = false
                self?.settings.layoutPreset = .essential
            }))
            delay = 0.5
            steps.append((0.9, { DebugSnapshot.write(mainView(), name: "spl-main-\(tag)") }))
        }
        steps.append((0.3, { [weak self] in
            guard let self else { return }
            DebugSnapshot.write(swiftUI: SPLPopoverView(controller: self.model.spl, openCalibration: {}, isLive: false), name: "spl-popover")
            DebugSnapshot.write(swiftUI: SessionView(model: self.model, isLive: false), name: "spl-session-popover")
            DebugSnapshot.write(swiftUI: Form { SPLSettingsSection(controller: self.model.spl, openCalibration: {}) }
                .formStyle(.grouped).scrollContentBackground(.hidden).tint(Color.joseonAccent).foregroundStyle(Color.joseonText)
                .frame(width: 460, height: 560), name: "spl-settings-section")
        }))
        for (tag, size) in [("default", NSSize(width: 620, height: 760)), ("min", NSSize(width: 560, height: 560))] {
            for method in CalibrationMethod.allCases {
                steps.append((0.3, { [weak self] in self?.calibrationWindow.show(method: method, prefill: true, size: size) }))
                steps.append((0.8, { [weak self] in
                    let content = self?.calibrationWindow.window?.contentView
                    DebugSnapshot.write(content?.superview ?? content, name: "spl-calibration-\(method.rawValue)-\(tag)")
                }))
            }
        }
        steps.append((0.2, { [weak self] in self?.calibrationWindow.window?.close() }))
        return steps
    }

    /// Pictures of "Measure your headphone…": every step at the default and at the minimum window size, plus the
    /// states a first run does not show (permission not asked / denied, no calibration file, sensitivity missing,
    /// both sides measured). Snapshot mode builds the window with FAKE seams (`measureEnvironment`): no input opens,
    /// nothing plays, and the window carries a "SNAPSHOT: fake" label on every picture.
    private func measureSnapshotSteps(firstDelay: Double) -> [(delay: Double, run: () -> Void)] {
        var steps: [(delay: Double, run: () -> Void)] = []
        func picture(_ name: String) {
            let content = measureWindow.window?.contentView
            DebugSnapshot.write(content?.superview ?? content, name: name)
        }
        var first = true
        for (tag, size) in [("default", MeasureWindowController.defaultSize), ("min", MeasureWindowController.minimumSize)] {
            steps.append((first ? firstDelay : 0.3, { [weak self] in
                self?.measureWindow.window?.close()
                self?.measureWindow.show(size: size)
            }))
            first = false
            for scene in MeasureSnapshotScene.allCases {
                steps.append((0.3, { [weak self] in
                    guard let self, let controller = self.measureWindow.controller else { return }
                    MeasureSnapshot.apply(scene, to: controller, link: self.measureFakeLink)
                }))
                steps.append((scene.settleSeconds, { [weak self] in
                    picture("measure-\(scene.rawValue)-\(tag)")
                    // Once per scene: the whole step without the scroll view, so every word can be read.
                    if tag == "default", let controller = self?.measureWindow.controller {
                        DebugSnapshot.write(swiftUI: MeasureView(controller: controller, onClose: {}, flat: true).frame(width: MeasureWindowController.defaultSize.width),
                                            name: "measure-\(scene.rawValue)-whole")
                    }
                }))
            }
        }
        steps.append((0.2, { [weak self] in self?.measureWindow.window?.close() }))
        return steps
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mainWindowController?.isTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        measureWindow.shutdown()
        statusController?.shutdown()
        model.shutdown()
    }

    /// Closing the main window keeps the app in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func applyDockIcon(_ show: Bool) {
        let mainWasVisible = mainWindowController.window?.isVisible ?? false
        let settingsWasVisible = settingsWindow?.isVisible ?? false
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        // A policy change can drop the app's windows behind other apps: bring them back.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            if mainWasVisible { self.mainWindowController.window?.orderFront(nil) }
            if settingsWasVisible { self.settingsWindow?.makeKeyAndOrderFront(nil) }
        }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Windows

    @objc func showMainWindow(_ sender: Any?) { mainWindowController.show() }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(model: model, settings: settings, openCalibration: { [weak self] in self?.showCalibration(nil) },
                                                                  openMeasure: { [weak self] in self?.showMeasure(nil) }))
            let window = NSWindow(contentViewController: host)
            window.title = "Joseon Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            // One app, one look: dark, the navy of the main window up to the top edge.
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = Palette.background
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("JoseonSettingsWindow")
            window.center()
            window.setFrameAutosaveName("JoseonSettingsWindow")
            window.setContentSize(NSSize(width: 460, height: 720))
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// "Calibrate level at the ear…": from the header level readout, the app menu and Settings.
    @objc func showCalibration(_ sender: Any?) { calibrationWindow.show() }

    /// "Measure your headphone…": from the app menu, Settings → Level at the ear, and the headphone menus.
    @objc func showMeasure(_ sender: Any?) { measureWindow.show() }

    /// The link between the fake player and the fake input. Snapshot mode only.
    private lazy var measureFakeLink = FakeAcousticLink()

    /// What the measurement window gets from the app. The headphone, the target and the level calibration are the
    /// ones at the moment the window opens: "Save as my curve" selects the new curve in the picker, and the window
    /// must go on comparing with the published one.
    private func measureEnvironment() -> MeasureEnvironment {
        let spl = model.spl
        let headphone = spl.headphone
        let target = model.targets.first { $0.name == model.currentTargetName }
        var environment = MeasureEnvironment(
            input: LiveMeasureInput(), player: SignalPlayer(),
            headphone: { headphone }, target: { target },
            playback: { [weak spl] in
                guard let spl, let headphone, let preset = spl.store.activePreset(device: spl.deviceName, headphone: headphone.name),
                      let calibration = spl.effectiveCalibration(preset) else { return nil }
                return (calibration, preset.deviceName)
            },
            knownImpedanceOhms: { [weak spl] in spl?.sensitivity?.impedanceOhms },
            importCurve: { [weak self] url in self?.model.importCurve(from: url) },
            curveExists: { [weak self] name in self?.model.curves.contains { $0.name == name } ?? false },
            storeSensitivity: { [weak spl] entry, name in spl?.store.setUserSensitivity(entry, headphone: name) },
            outputName: { [weak spl] in spl?.deviceName ?? "" })
        if TonePlayPermit.processIsOffline {
            // Snapshot mode: FAKE input and FAKE player, nothing is written to the curve folder.
            environment.input = FakeMeasureInput(link: measureFakeLink)
            environment.player = FakeSignalPlayer(link: measureFakeLink)
            environment.timing = .fake
            environment.importCurve = { _ in nil }
            environment.playback = { [measureFakeLink] in measureFakeLink.fakePlayback.map { ($0, "Snapshot DAC") } }
            environment.knownImpedanceOhms = { nil }
            environment.isLabelledFake = true
        }
        return environment
    }

    private func showWelcome() {
        guard let parent = mainWindowController.window, welcomeWindow == nil else { return }
        let host = NSHostingController(rootView: WelcomeView { [weak self] in self?.finishWelcome() })
        let sheet = NSWindow(contentViewController: host)
        sheet.styleMask = [.titled]
        sheet.title = "Welcome to Joseon"
        welcomeWindow = sheet
        parent.beginSheet(sheet) { _ in }
    }

    private func finishWelcome() {
        if let sheet = welcomeWindow { mainWindowController.window?.endSheet(sheet) }
        welcomeWindow = nil
        settings.hasSeenWelcome = true
        model.start()
    }

    // MARK: Menu actions

    @objc func selectPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let preset = LayoutPreset(rawValue: raw) else { return }
        settings.layoutPreset = preset
        showMainWindow(nil)
    }

    /// An open sheet blocks NSApp.terminate (seen in the launch test): close the welcome sheet first.
    @objc func quitApp(_ sender: Any?) {
        if let sheet = welcomeWindow {
            mainWindowController.window?.endSheet(sheet)
            welcomeWindow = nil
        }
        NSApp.terminate(nil)
    }

    /// ⌘4: stereo placement on or off. "Essential" and "Metering": the stereo card shows placement or the
    /// vectorscope. "Spectrum": the placement card beside the spectrogram shows or hides.
    @objc func toggleStereoPlacement(_ sender: Any?) {
        if settings.layoutPreset != .spectrum {
            settings.stereoPlacementMode.toggle()
        } else if mainWindowController.placementFits {
            settings.spectrumShowsPlacement.toggle()
        } else {
            // The window is too low for the card beside the spectrogram: show placement in "Essential".
            settings.stereoPlacementMode = true
            settings.layoutPreset = .essential
        }
        showMainWindow(nil)
    }

    /// ⌘5: the session timeline strip under the panels. A window too low for it shows no strip (and no notice).
    @objc func toggleTimeline(_ sender: Any?) {
        settings.showTimeline.toggle()
        showMainWindow(nil)
    }

    @objc func toggleFreeze(_ sender: Any?) { model.toggleFreeze() }
    @objc func resetMeasurement(_ sender: Any?) { model.resetMeasurement() }
    @objc func importCurve(_ sender: Any?) { model.runImportPanel() }
    @objc func restartCapture(_ sender: Any?) { model.restartSource() }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: "Real-time audio analyzer. Audio never leaves this Mac and is never recorded.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Joseon", .credits: credits])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectPreset(_:)):
            menuItem.state = (menuItem.representedObject as? String) == settings.layoutPreset.rawValue ? .on : .off
        case #selector(toggleFreeze(_:)):
            menuItem.state = model.isFrozen ? .on : .off
        case #selector(toggleStereoPlacement(_:)):
            let on = settings.layoutPreset == .spectrum
                ? settings.spectrumShowsPlacement && mainWindowController.placementFits : settings.stereoPlacementMode
            menuItem.state = on ? .on : .off
        case #selector(toggleTimeline(_:)):
            menuItem.state = settings.showTimeline ? .on : .off
        default:
            break
        }
        return true
    }

    // MARK: Main menu

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: "Joseon")
        appMenu.addItem(item("About Joseon", #selector(showAbout(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettings(_:)), key: ","))
        appMenu.addItem(item("Calibrate Level at the Ear…", #selector(showCalibration(_:))))
        appMenu.addItem(item("Measure Your Headphone…", #selector(showMeasure(_:))))
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Joseon", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Joseon", #selector(quitApp(_:)), key: "q"))
        main.addItem(submenuItem(appMenu))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("Import Headphone Curve…", #selector(importCurve(_:)), key: "i"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(submenuItem(fileMenu))

        let viewMenu = NSMenu(title: "View")
        for preset in LayoutPreset.allCases {
            let presetItem = item(preset.title, #selector(selectPreset(_:)), key: preset.keyEquivalent)
            presetItem.representedObject = preset.rawValue
            viewMenu.addItem(presetItem)
        }
        viewMenu.addItem(.separator())
        let placement = item("Stereo Placement", #selector(toggleStereoPlacement(_:)), key: "4")
        placement.toolTip = "Show where each frequency sits between left and right, in place of the vectorscope"
        viewMenu.addItem(placement)
        let timeline = item("Show Session Timeline", #selector(toggleTimeline(_:)), key: "5")
        timeline.toolTip = "The last minutes of loudness, peaks and events, under the panels. It needs a window high enough for the panels above it."
        viewMenu.addItem(timeline)
        viewMenu.addItem(.separator())
        // Space, R and F work in the main window (see MainWindow.keyDown). They are not menu key
        // equivalents: a menu equivalent would take Space away from a focused button.
        viewMenu.addItem(item("Freeze Display  (Space)", #selector(toggleFreeze(_:))))
        viewMenu.addItem(item("Reset Measurement  (R)", #selector(resetMeasurement(_:))))
        viewMenu.addItem(item("Restart Audio Capture", #selector(restartCapture(_:))))
        viewMenu.addItem(.separator())
        let fullScreen = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreen)
        main.addItem(submenuItem(viewMenu))

        main.addItem(submenuItem(ComparisonMenu.build(model: { [unowned self] in self.model })))   // A/B compare: ⌘B, ⇧⌘B

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Joseon", #selector(showMainWindow(_:)), key: "0"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        main.addItem(submenuItem(windowMenu))
        NSApp.windowsMenu = windowMenu

        return main
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        menuItem.submenu = menu
        return menuItem
    }
}
