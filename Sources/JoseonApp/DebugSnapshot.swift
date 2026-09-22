import AppKit
import SwiftUI
import JoseonCore
import JoseonRender

/// Design-review aid. With the environment variable JOSEON_SNAPSHOT_DIR set, the app draws its own
/// windows into PNG files in that directory and quits. It needs no screen-recording permission,
/// because the app renders its own views. `cacheDisplay` does not see Metal layers, so every panel in the
/// picture is drawn again with `OffscreenRenderer` from the frames the app analyzed (same renderer, same
/// options, same size): the PNG shows the real look of the window.
/// The numbers and the stress flags in the pictures are measurements: the demo signal runs through the real
/// engine and the real headphone model (see `SnapshotDemoSource`), first offline for the long-term values
/// (integrated loudness, LRA, PLR), then live. JOSEON_SNAPSHOT_SIGNAL=hot feeds a loud, clipped variant of the
/// signal, so the real model has flags to raise: that checks the chip row.
enum DebugSnapshot {
    static var directory: URL? {
        guard let path = ProcessInfo.processInfo.environment["JOSEON_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The frames the panels saw, oldest first. The snapshot run fills it.
    static var frames: [AnalysisFrame] = []

    @discardableResult
    static func write(_ view: NSView?, name: String) -> Bool {
        guard let directory, let view, view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        drawPanels(in: view, into: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        let url = directory.appendingPathComponent(name + ".png")
        do { try data.write(to: url); print("snapshot \(url.path)"); return true } catch { print("snapshot failed: \(error)"); return false }
    }

    /// A SwiftUI view that normally lives in a popover: host it in an offscreen dark window and draw it.
    static func write<Content: View>(swiftUI content: Content, name: String) {
        let host = NSHostingView(rootView: content.background(Color.joseonBackground).environment(\.colorScheme, .dark))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        write(host, name: name)
    }

    static func write(_ image: NSImage, name: String) {
        guard let directory, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private static func panels(in view: NSView) -> [PanelView] {
        var found: [PanelView] = []
        for sub in view.subviews where !sub.isHidden {
            if let panel = sub as? PanelView { found.append(panel) } else { found += panels(in: sub) }
        }
        return found
    }

    private static func drawPanels(in view: NSView, into rep: NSBitmapImageRep) {
        let all = panels(in: view)
        guard !all.isEmpty, !frames.isEmpty, let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
        func toBitmap(_ rect: NSRect) -> NSRect {
            view.isFlipped ? NSRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
        }
        for panel in all where panel.bounds.width > 4 && panel.bounds.height > 4 {
            var settings = OffscreenRenderer.Settings()
            if let v = panel as? SpectrumView { settings.spectrum = v.options; settings.spectrumAutoRange = v.autoRange; settings.showStressBands = v.showStressBands }
            if let v = panel as? SpectrumView { settings.comparison = v.comparison; settings.comparisonLevelMatch = v.comparisonLevelMatch; settings.comparisonMode = v.comparisonMode; settings.liveTiltDBPerOctave = v.liveTiltDBPerOctave }
            if let v = panel as? MetersView { settings.comparison = v.comparison; settings.comparisonLevelMatch = v.comparisonLevelMatch; settings.liveTiltDBPerOctave = v.liveTiltDBPerOctave }
            if let v = panel as? SpectrogramView { settings.historySeconds = v.historySeconds }
            if let v = panel as? VectorscopeView { settings.vectorscopeMode = v.mode }
            if let v = panel as? MetersView { settings.targetLUFS = v.targetLUFS }
            if let v = panel as? JoseonRender.TimelineView {
                settings.session = v.sessionProvider()
                settings.timelineWindowSeconds = v.windowSeconds
                settings.timelineShowBands = v.showBands
                settings.targetLUFS = v.targetLUFS
            }
            guard let png = try? OffscreenRenderer.png(panel: panel.kind, frames: frames, size: panel.bounds.size, scale: scale,
                                                       theme: panel.theme, settings: settings),
                  let image = NSImage(data: png) else { continue }
            let rect = toBitmap(panel.convert(panel.bounds, to: view))
            NSGraphicsContext.saveGraphicsState()
            if let card = panel.superview as? PanelCardView {
                // The card clips its panel to the rounded corners.
                NSBezierPath(roundedRect: toBitmap(card.convert(card.bounds, to: view)).insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).addClip()
                Palette.panel.setFill()
                rect.fill()
            }
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: panel.alphaValue)
            // Views above the panel (the "Waiting for audio" plate) were painted over: draw them again.
            if let card = panel.superview, let index = card.subviews.firstIndex(of: panel) {
                for above in card.subviews[(index + 1)...] where !above.isHidden && above.frame.intersects(panel.frame) {
                    guard let plate = above.bitmapImageRepForCachingDisplay(in: above.bounds) else { continue }
                    above.cacheDisplay(in: above.bounds, to: plate)
                    plate.draw(in: toBitmap(above.convert(above.bounds, to: view)), from: .zero, operation: .sourceOver,
                               fraction: 1, respectFlipped: false, hints: nil)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// SNAPSHOT MODE ONLY (JOSEON_SNAPSHOT_DIR). A snapshot run measures about two and a half minutes of the demo signal:
/// the timeline strip and the events list would be almost empty in the review pictures. While the recorded session is
/// that short, this provider gives the made-up record of `SyntheticFrames.demoSession` in its place.
/// `AppModel` installs it only when `DebugSnapshot.directory` is set. A normal run (also demo mode) never sees it.
enum SnapshotOnlySessionSeed {
    /// Under this many recorded seconds the seed stands in.
    static let shortRecordSeconds = 600

    static func provider(recorded: @escaping SessionProvider) -> SessionProvider {
        precondition(DebugSnapshot.directory != nil, "the session seed is for snapshot runs only")
        return {
            let real = recorded()
            guard real.samples.count < shortRecordSeconds else { return real }
            return SyntheticFrames.demoSession(minutes: 25, endingAt: Date())
        }
    }
}

/// Collects the frames the panels see, so a snapshot can draw the panels again. Snapshot mode only.
final class SnapshotFrameRecorder {
    private var timer: Timer?
    private let provider: FrameProvider
    private var lastHostTime: TimeInterval = -1

    init(provider: @escaping FrameProvider) {
        self.provider = provider
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let frame = provider()
        guard frame.hostTime != lastHostTime else { return }
        lastHostTime = frame.hostTime
        DebugSnapshot.frames.append(frame)
        if DebugSnapshot.frames.count > 1500 { DebugSnapshot.frames.removeFirst(300) }
    }

    /// A measurement reset starts the meters again: the old frames would draw a history that is gone.
    func stop() { timer?.invalidate(); timer = nil }
}

/// The signal of a snapshot run: the demo signal of `TestSignals`, sample for sample. It is a pure function of
/// the sample position, so the offline pre-roll and the live part are one continuous signal.
///
/// JOSEON_SNAPSHOT_SIGNAL=hot: the same signal as a loud, bass-heavy, clipped master (+12 dB, a low shelf of
/// about +8 dB under 80 Hz, hard clip at full scale). Nothing else changes: the real analyzers measure it and
/// the real headphone model raises the flags it finds, with the numbers it measured. No flag is written by hand.
final class SnapshotSignal {
    static var isHot: Bool { ProcessInfo.processInfo.environment["JOSEON_SNAPSHOT_SIGNAL"] == "hot" }

    let sampleRate: Double = 48_000
    let hot: Bool
    private(set) var position = 0
    private var lowL: Float = 0, lowR: Float = 0

    init(hot: Bool = SnapshotSignal.isHot) { self.hot = hot }

    func next(_ count: Int) -> (left: [Float], right: [Float]) {
        var block = TestSignals.demoBlock(startSample: position, count: count, sampleRate: sampleRate)
        position += count
        guard hot else { return block }
        let a = Float(1 - exp(-2 * Double.pi * 80 / sampleRate))   // one-pole low-pass at 80 Hz
        let gain: Float = 3.98, shelf: Float = 1.5
        for i in 0..<count {
            lowL += a * (block.left[i] - lowL)
            lowR += a * (block.right[i] - lowR)
            block.left[i] = min(max((block.left[i] + shelf * lowL) * gain, -1), 1)
            block.right[i] = min(max((block.right[i] + shelf * lowR) * gain, -1), 1)
        }
        return block
    }
}

/// Snapshot mode, demo signal. `start()` only announces the stream. The app model first runs the signal through
/// the engine offline (`AnalysisEngine.processNow`, faster than real time), then calls `goLive()`: from there the
/// source writes the rest of the same signal into the ring in real time, like `DemoAudioSource`.
final class SnapshotDemoSource: AudioSource {
    private(set) var streamInfo: StreamInfo?
    let ringBuffer = StereoRingBuffer()
    var onStreamInfoChange: ((StreamInfo) -> Void)?
    private(set) var isRunning = false
    let signal = SnapshotSignal()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "joseon.snapshot.demo", qos: .userInteractive)

    func start() throws {
        guard !isRunning else { return }
        isRunning = true
        // The same stream facts as `DemoAudioSource`.
        streamInfo = StreamInfo(sampleRate: signal.sampleRate, channelCount: 2, deviceName: "Demo signal", bitDepth: 32, activeSources: ["Joseon demo"])
    }

    func goLive() {
        guard isRunning, timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        let block = Int(signal.sampleRate / 100)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let samples = self.signal.next(block)
            self.ringBuffer.write(left: samples.left, right: samples.right, count: block, sampleRate: self.signal.sampleRate)
        }
        timer = t
        t.resume()
    }

    func stop() { timer?.cancel(); timer = nil; isRunning = false }
}

/// Test source (JOSEON_DEBUG_SOURCE=silent or slow): digital silence while an "app" claims to play.
/// It exercises the silence path: 10 Hz engine tick, 1 Hz mini graph, panel pause, permission banner.
final class DebugSilentSource: AudioSource {
    private(set) var streamInfo: StreamInfo?
    let ringBuffer = StereoRingBuffer()
    var onStreamInfoChange: ((StreamInfo) -> Void)?
    private(set) var isRunning = false
    private var timer: DispatchSourceTimer?

    private static var mode: String? { ProcessInfo.processInfo.environment["JOSEON_DEBUG_SOURCE"] }
    /// "silent", or "slow": the same source, but `start()` blocks 6 s like a tap that waits on the macOS prompt.
    /// "slow" checks that the main thread stays free and the header shows the waiting state.
    /// "idle": silence and no app that plays. The state of a Mac where nothing plays: no permission banner applies.
    static var isRequested: Bool { mode == "silent" || mode == "slow" || mode == "idle" }

    func start() throws {
        guard !isRunning else { return }
        if Self.mode == "slow" { Thread.sleep(forTimeInterval: 6) }
        isRunning = true
        streamInfo = StreamInfo(sampleRate: 96_000, channelCount: 2, deviceName: "External Headphones", bitDepth: 24, activeSources: Self.mode == "idle" ? [] : ["Music"])
        let zeros = [Float](repeating: 0, count: 960)
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "joseon.debug.silence"))
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        t.setEventHandler { [weak self] in self?.ringBuffer.write(left: zeros, right: zeros, count: zeros.count, sampleRate: 96_000) }
        timer = t
        t.resume()
    }

    func stop() { timer?.cancel(); timer = nil; isRunning = false }
}

enum DebugLog {
    static let enabled = ProcessInfo.processInfo.environment["JOSEON_DEBUG_LOG"] == "1"
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(String(format: "[%.2f] %@\n", ProcessInfo.processInfo.systemUptime, message()).utf8))
    }
}
