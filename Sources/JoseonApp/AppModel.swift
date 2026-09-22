import AppKit
import Combine
import JoseonCore
import JoseonCapture
import JoseonHeadphones
import JoseonRender

/// Hands frames to the panels. Returns the frozen frame while the display is frozen.
/// Panels may call this from a display link thread, so the frozen frame sits behind a lock.
final class FrameGate: @unchecked Sendable {
    private let engine: AnalysisEngine
    private let lock = NSLock()
    private var frozen: AnalysisFrame?

    init(engine: AnalysisEngine) { self.engine = engine }

    func current() -> AnalysisFrame {
        if let f = lock.withLock({ frozen }) { return f }
        return engine.latestFrame
    }

    func setFrozen(_ on: Bool) {
        let frame = on ? engine.latestFrame : nil
        lock.withLock { frozen = frame }
    }
}

/// The one phrase the app uses when no audio arrives: header, popover, panel placeholders.
let waitingForAudioText = "Waiting for audio"

enum SignalState: Equatable {
    case live, silent, demo
    /// The source start has not returned yet (macOS may show the "System Audio Recording" prompt).
    case waiting
    var label: String {
        switch self {
        case .live: return "Live"
        case .silent: return waitingForAudioText
        case .demo: return "Demo signal"
        case .waiting: return "Starting"
        }
    }
}

/// Text a panel card shows in its center when it has nothing to draw.
enum PanelPlaceholder: Equatable {
    case waitingForAudio
    var text: String { waitingForAudioText }
}

/// Integrated loudness against the loudness target, as text for the strip under the header.
struct LoudnessDeltaState: Equatable {
    enum Relation { case none, under, onTarget, over }
    var text: String
    var spoken: String
    var relation: Relation

    static func make(integratedLUFS: Float, target: LoudnessTarget) -> LoudnessDeltaState? {
        guard let targetLUFS = target.lufs else { return nil }
        let targetText = "\(NumberText.signed(target.rawValue)) LUFS"
        guard integratedLUFS.isFinite, integratedLUFS > -119 else {
            return LoudnessDeltaState(text: "I —", spoken: "Integrated loudness: no value yet. Target \(targetText).", relation: .none)
        }
        let integrated = "I " + signed(integratedLUFS, plus: false)
        let delta = ((integratedLUFS - targetLUFS) * 10).rounded() / 10
        if abs(delta) < 0.5 {
            return LoudnessDeltaState(text: "\(integrated) · on target", spoken: "Integrated loudness \(signed(integratedLUFS, plus: false)) LUFS, on the target of \(targetText).", relation: .onTarget)
        }
        let side = delta > 0 ? "over" : "under"
        return LoudnessDeltaState(
            text: "\(integrated) · \(signed(delta, plus: true)) LU \(side) target",
            spoken: "Integrated loudness \(signed(integratedLUFS, plus: false)) LUFS, \(NumberText.signed(abs(delta))) LU \(side) the target of \(targetText).",
            relation: delta > 0 ? .over : .under)
    }

    /// "−11.5", "+2.5": a real minus sign, one decimal.
    private static func signed(_ value: Float, plus: Bool) -> String { NumberText.signed(value, plus: plus) }
}

/// Text for the header strip. Published only when a value changes, so SwiftUI stays idle.
struct HeaderState: Equatable {
    /// Apps that play audio, for example "Qobuz". Empty when no app plays.
    var sources = ""
    var device = ""
    /// Replaces the stream facts while the source start is pending.
    var notice: String?
    var sampleRate = "—"
    var bitDepth = "—"
    var state: SignalState = .silent

    /// 96000 → "96 kHz", 44100 → "44.1 kHz".
    static func format(sampleRate: Double) -> String {
        guard sampleRate > 0 else { return "—" }
        let khz = sampleRate / 1000
        if abs(khz - khz.rounded()) < 0.001 { return "\(Int(khz.rounded())) kHz" }
        return String(format: "%.1f kHz", khz)
    }

    /// First line of the stream block: the apps that play, or the one no-audio phrase.
    /// Demo mode: "Demo signal", once. The state badge is then a mark without text, and the name the demo
    /// source gives itself as an "app" ("Joseon demo") does not show.
    var headline: String {
        if let notice { return notice }
        if state == .demo { return SignalState.demo.label }
        if state == .silent || sources.isEmpty { return waitingForAudioText }
        return sources
    }

    /// Second line: device · sample rate · bit depth. At silence the source apps lead the line.
    var facts: [String] {
        var parts: [String] = []
        if state == .silent, !sources.isEmpty { parts.append(sources) }
        // The demo source names its device "Demo signal": the state badge says that already. Say it once.
        if !device.isEmpty, !(state == .demo && device.caseInsensitiveCompare(SignalState.demo.label) == .orderedSame) { parts.append(device) }
        if sampleRate != "—" { parts.append(sampleRate) }
        if bitDepth != "—" { parts.append(bitDepth) }
        return parts
    }

    var spoken: String {
        if let notice { return notice }
        return ([headline] + facts).joined(separator: ", ")
    }
}

/// Owns the audio source, the analysis engine, the headphone model and the settings.
final class AppModel: ObservableObject {
    let settings: AppSettings
    let engine = AnalysisEngine()
    let library = HeadphoneLibrary()
    /// Opens "Measure your headphone…". The app delegate sets it; the headphone menus call it.
    var openMeasure: () -> Void = {}
    /// Sound level at the ear: calibration, sensitivity, estimator, dose.
    let spl: SPLController
    /// A/B compare: the references (memory only) and the active one.
    let comparison: ComparisonController
    let gate: FrameGate
    /// Goes to every panel in the main window.
    let frameProvider: FrameProvider
    /// Live frames (never frozen): menu bar mini graph and popover.
    let liveFrameProvider: FrameProvider
    /// The session record (memory only) for the timeline strip and the events list of the session popover.
    /// A normal run reads the engine's recorder. Only a snapshot run (JOSEON_SNAPSHOT_DIR) wraps it: see `SnapshotOnlySessionSeed`.
    let sessionProvider: SessionProvider
    /// The record the engine really made, in every mode. The Session popover reads THIS one, so its events always
    /// belong to the same measurement as its track cards and its table (a snapshot run's made-up record stays in
    /// the timeline strip, whose card title says "demo record").
    let recordedSessionProvider: SessionProvider

    private(set) var source: AudioSource?

    /// The track the player shows, read from its window. Nil when nothing is known (no player, no permission, no track).
    @Published private(set) var nowPlaying: NowPlaying?
    let nowPlayingSource: NowPlayingSource
    /// The Accessibility permission, as two seams so the app builds without the real reader.
    let nowPlayingTrust: NowPlayingTrust
    /// The shell's one explanation before the first trust request. Main queue, at most once per launch.
    var onNowPlayingTrustNeeded: (() -> Void)?
    private var nowPlayingStarted = false
    private var nowPlayingTrustAsked = false

    @Published private(set) var header = HeaderState()
    @Published private(set) var stressFlags: [StressFlag] = []
    @Published private(set) var hasHeadphoneModel = false
    /// Name of the active headphone model, for the stress strip.
    @Published private(set) var headphoneModelName: String?
    /// Nil when the loudness target is off.
    @Published private(set) var loudnessDelta: LoudnessDeltaState?
    /// What the panel cards show in their center. Nil while the panels have graphics to draw.
    @Published private(set) var panelPlaceholder: PanelPlaceholder?
    @Published private(set) var isFrozen = false
    @Published private(set) var isDemo = false
    /// Set when the capture source threw on start. The app shows it and runs the demo source.
    @Published private(set) var captureError: String?
    @Published private(set) var showPermissionBanner = false
    /// True from the source start request until the start returns. Not an error: macOS may wait for the user.
    @Published private(set) var isStartPending = false
    /// True when the input was silent long enough that all decays are over. Panels pause then.
    @Published private(set) var isIdle = false
    /// Finished tracks, newest first, at most `trackHistoryLimit`. In memory only: never written to disk.
    @Published private(set) var trackHistory: [TrackSummary] = []
    static let trackHistoryLimit = 20
    @Published private(set) var curves: [HeadphoneCurve] = []
    @Published private(set) var targets: [HeadphoneCurve] = []

    /// What is on screen now. It sets the engine tick rate.
    enum ConsumerLevel {
        /// Nothing shows analysis data.
        case none
        /// Only the menu bar mini graph (one picture per engine frame, 20 Hz): the everyday state.
        case miniGraph
        /// The main window or the popover: panels at display rate.
        case panels

        /// Engine ticks per second with signal. Fewer ticks also mean fewer FFTs: the spectrum analyzer
        /// transforms only the newest window of a tick.
        var engineRate: Double {
            switch self {
            case .none: return 10
            case .miniGraph: return 20
            case .panels: return 60
            }
        }
    }
    /// The shell sets this.
    var consumerLevel: () -> ConsumerLevel = { .panels }
    /// Called when the signal goes active (true) or silent (false). Drives the mini graph rate.
    var onSignalActivityChange: ((Bool) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var supervisor: Timer?
    private var engineRate: Double = 0
    private var stereoAnalysisOn = true
    private var lastSignalTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var sourceStartTime: TimeInterval = 0
    private var hasSignalSinceStart = false
    private var bannerDismissed = false
    private var signalActive = false
    private var started = false
    /// A stress flag stays on the strip this long after the model last raised it, so the user can read and click it.
    private static let flagHoldSeconds: TimeInterval = 4
    private var heldFlags: [String: (flag: StressFlag, lastSeen: TimeInterval, shownAt: TimeInterval)] = [:]
    /// Silence longer than this, then signal: a new track or album. See `autoResetAfterSilence`.
    private static let trackGapSeconds: TimeInterval = 2
    /// The running track: from the first signal after a reset to the next reset.
    private var trackStart: Date?
    private var trackEnd = Date()
    private var trackSource = ""
    private var trackLowestStrongHz: Float = 0
    /// Loudness of the last frame with signal. At an auto-reset this is the state before the silence gap.
    private var trackLoudness: LoudnessReading?
    /// Level at the ear of the running track. Nil without a calibration.
    private var trackSPL: TrackSPL?
    /// A shorter measurement is a system sound or a skipped track, not a track to keep.
    static var minimumTrackSeconds: Double = 10
    /// Uptime of the first silent frame the supervisor saw after signal. Nil while signal is present.
    private var observedSilenceStart: TimeInterval?
    private var appliedDemoMode: Bool
    /// Every source start and stop runs here, in order, never on the main thread:
    /// `SystemAudioTap.start()` and `stop()` can block about 90 s while the macOS prompt is pending.
    private let lifecycleQueue = DispatchQueue(label: "joseon.app.source-lifecycle", qos: .userInitiated)
    /// Goes up with every start request. A completion with an old number is stale.
    private var startGeneration = 0
    private var pendingSince: TimeInterval = 0
    /// After this long the header names the likely cause of the wait. A normal start is faster.
    private static let pendingNoticeSeconds: TimeInterval = 0.7

    init(settings: AppSettings, nowPlayingSource: NowPlayingSource? = nil, nowPlayingTrust: NowPlayingTrust? = nil) {
        self.settings = settings
        self.appliedDemoMode = settings.demoMode
        // The real reader (Accessibility API) unless a test or JOSEON_NOWPLAYING_FAKE=1 asks for the fake.
        let useFake = ProcessInfo.processInfo.environment["JOSEON_NOWPLAYING_FAKE"] == "1"
        self.nowPlayingSource = nowPlayingSource ?? (useFake ? FakeNowPlayingSource() : AccessibilityNowPlayingReader())
        self.nowPlayingTrust = nowPlayingTrust ?? (useFake ? .fake : NowPlayingTrust(
            isTrusted: { AccessibilityNowPlayingReader.isTrusted },
            requestTrust: { AccessibilityNowPlayingReader.requestTrust() }))
        let engine = self.engine
        let gate = FrameGate(engine: engine)
        self.gate = gate
        spl = SPLController(engine: engine)
        comparison = ComparisonController(engine: engine, settings: settings)
        frameProvider = { gate.current() }
        liveFrameProvider = { engine.latestFrame }
        let recorded: SessionProvider = { [engine] in engine.session.snapshot() }
        recordedSessionProvider = recorded
        sessionProvider = DebugSnapshot.directory != nil ? SnapshotOnlySessionSeed.provider(recorded: recorded) : recorded
        comparison.sourceName = { [weak self] in self?.comparisonSourceName ?? "" }
        self.nowPlayingSource.onChange = { [weak self] track in self?.nowPlaying = track }
        reloadLibrary()
        applyFirstRunHeadphone()
        applySettings()
        // @Published fires in willSet: hop to the next main-queue turn to read the new values.
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)
    }

    // MARK: Source lifecycle

    /// Start capture (or the demo source) and the supervisor. Safe to call again: it restarts the source.
    func start() {
        started = true
        startSource()
        applyNowPlaying()
        if supervisor == nil {
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.supervise() }
            t.tolerance = 0.03
            RunLoop.main.add(t, forMode: .common)
            supervisor = t
        }
    }

    func shutdown() {
        supervisor?.invalidate()
        supervisor = nil
        engine.stop()
        spl.shutdown()
        nowPlayingSource.stop()
        nowPlayingStarted = false
        engineRate = 0
        startGeneration += 1
        isStartPending = false
        guard let old = source else { return }
        source = nil
        old.onStreamInfoChange = nil
        // Stop off the main thread. Give a clean teardown a short time, then let the process exit:
        // the tap and its aggregate device are private to this process, so macOS removes them.
        let done = DispatchSemaphore(value: 0)
        lifecycleQueue.async { old.stop(); done.signal() }
        _ = done.wait(timeout: .now() + 0.5)
    }

    /// "Retry" in the banners: build a new source and start again.
    func restartSource() {
        guard started else { return }
        startSource()
    }

    /// Main thread. Returns at once: the old source stops and the new source starts in the background.
    /// The engine keeps its tick on the old ring until the new source runs. That ring gets no samples,
    /// so the engine publishes silent frames and the display falls, it does not freeze.
    private func startSource() {
        let old = source
        old?.onStreamInfoChange = nil
        source = nil
        captureError = nil
        showPermissionBanner = false
        bannerDismissed = false
        hasSignalSinceStart = false
        observedSilenceStart = nil
        lastSignalTime = ProcessInfo.processInfo.systemUptime
        sourceStartTime = lastSignalTime
        appliedDemoMode = settings.demoMode

        let newSource: AudioSource
        var demo = settings.demoMode
        if DebugSilentSource.isRequested {
            newSource = DebugSilentSource()
            demo = false
        } else if demo {
            // Snapshot mode measures the same demo signal offline first: see `runSnapshotPreroll`.
            newSource = DebugSnapshot.directory != nil ? SnapshotDemoSource() : DemoAudioSource()
        } else {
            newSource = SystemAudioTap()
        }
        begin(newSource, demo: demo, retiring: old)
    }

    private func begin(_ newSource: AudioSource, demo: Bool, retiring old: AudioSource?) {
        startGeneration += 1
        let generation = startGeneration
        newSource.onStreamInfoChange = { [weak self, weak newSource] info in
            guard let self, let newSource, self.source === newSource else { return }
            self.engine.streamInfo = info
        }
        source = newSource
        isDemo = demo
        isStartPending = true
        pendingSince = ProcessInfo.processInfo.systemUptime
        engine.streamInfo = nil
        DebugLog.log("source start requested (generation \(generation), demo \(demo))")

        lifecycleQueue.async { [weak self] in
            old?.stop()
            DispatchQueue.main.async {
                guard let self, generation == self.startGeneration else { return }
                newSource.startAsync { [weak self] error in
                    self?.sourceDidStart(newSource, demo: demo, generation: generation, error: error)
                }
            }
        }
        supervise()
    }

    /// Main thread: `startAsync` completed.
    private func sourceDidStart(_ newSource: AudioSource, demo: Bool, generation: Int, error: Error?) {
        guard generation == startGeneration, source === newSource else {
            // A newer request replaced this source while its start was pending.
            lifecycleQueue.async { newSource.stop() }
            return
        }
        isStartPending = false
        if let error {
            DebugLog.log("source start failed: \(error)")
            captureError = Self.describe(error)
            if demo {
                source = nil
                lifecycleQueue.async { newSource.stop() }
                supervise()
            } else {
                begin(DemoAudioSource(), demo: true, retiring: newSource)
            }
            return
        }
        DebugLog.log("source runs (generation \(generation))")
        let now = ProcessInfo.processInfo.systemUptime
        lastSignalTime = now
        sourceStartTime = now
        engine.streamInfo = newSource.streamInfo
        closeTrack()
        engine.resetMeasurement()
        if let snapshotSource = newSource as? SnapshotDemoSource {
            runSnapshotPreroll(snapshotSource, generation: generation)
            return
        }
        engineRate = 60
        engine.start(reading: newSource.ringBuffer, ticksPerSecond: 60)
        supervise()
    }

    // MARK: Snapshot pre-roll

    /// Snapshot mode: true when the offline part is over and the live signal runs.
    @Published private(set) var isSnapshotReady = false
    /// Seconds of signal per offline track, and before the pictures. More than 40 s: PLR and LRA are measurements then.
    static let snapshotTrackSeconds: [Double] = [42, 47]
    static let snapshotPrerollSeconds: Double = 50

    /// Runs the demo signal through the real engine and the real headphone model, offline: two whole "tracks"
    /// (each ends with a measurement reset, so the session list has real rows), then the track that is on
    /// screen in the pictures. Then the source goes live on the same signal and the engine reads its ring.
    private func runSnapshotPreroll(_ source: SnapshotDemoSource, generation: Int) {
        let engine = self.engine
        // `processNow` must not run beside the engine's own timer.
        engine.stop()
        engineRate = 0
        engine.analyzesStereo = true
        stereoAnalysisOn = true
        let started = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let block = 800   // 60 frames per second of signal
            func run(_ seconds: Double) {
                var left = Int(seconds * source.signal.sampleRate)
                while left > 0 {
                    let n = min(block, left)
                    let samples = source.signal.next(n)
                    samples.left.withUnsafeBufferPointer { l in
                        samples.right.withUnsafeBufferPointer { r in
                            _ = engine.processNow(left: l.baseAddress!, right: r.baseAddress!, count: n, sampleRate: source.signal.sampleRate)
                        }
                    }
                    left -= n
                }
            }
            for seconds in Self.snapshotTrackSeconds {
                run(seconds)
                DispatchQueue.main.sync {
                    guard let self, generation == self.startGeneration else { return }
                    self.supervise()            // the track summary takes the newest frame
                    self.resetMeasurement()
                }
            }
            run(Self.snapshotPrerollSeconds)
            DispatchQueue.main.async {
                guard let self, generation == self.startGeneration, self.source === source else { return }
                let total = Self.snapshotTrackSeconds.reduce(0, +) + Self.snapshotPrerollSeconds
                DebugLog.log(String(format: "snapshot pre-roll: %.0f s of signal in %.1f s", total, ProcessInfo.processInfo.systemUptime - started))
                self.engineRate = 60
                engine.start(reading: source.ringBuffer, ticksPerSecond: 60)
                source.goLive()
                self.comparison.seedForSnapshotIfRequested()   // snapshot runs only, and only with JOSEON_SNAPSHOT_COMPARE
                self.isSnapshotReady = true
                self.supervise()
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? CaptureError { return e.description }
        return error.localizedDescription
    }

    /// Changes the tick of the running engine. No stop/start, so the analyzers keep their state.
    private func setEngineRate(_ rate: Double) {
        guard engineRate > 0, rate != engineRate else { return }
        engineRate = rate
        DebugLog.log("engine tick rate \(Int(rate)) Hz")
        engine.setTickRate(rate)
    }

    // MARK: Supervisor (10 Hz, main thread)

    /// Seconds of silence before the panels pause: long enough for the peak hold to fall to the floor.
    private var idleAfterSeconds: Double { max(10, 110 / max(settings.peakDecayDBPerSecond, 1) + 2) }

    private func supervise() {
        guard source != nil || captureError != nil else { return }
        let frame = engine.latestFrame
        let now = ProcessInfo.processInfo.systemUptime
        // A frame from before the source start says nothing about the new source.
        if !frame.isSilent, frame.hostTime >= sourceStartTime {
            // Track change: audio is back after a gap. Start a new measurement, keep a frozen display frozen.
            // The gap counts from the first silent frame this supervisor saw. A main-thread stall (a modal panel,
            // a slow draw) has no silent frame: it is not a gap in the music and must not reset the measurement.
            let gap = observedSilenceStart.map { now - $0 } ?? 0
            if hasSignalSinceStart, gap > Self.trackGapSeconds, settings.autoResetAfterSilence {
                DebugLog.log("audio resumed after \(String(format: "%.1f", gap)) s of silence: reset measurement")
                closeTrack()
                engine.resetMeasurement()
            } else {
                // Not in the turn of a reset: that frame still carries the numbers of the old track.
                noteTrackProgress(frame)
            }
            lastSignalTime = now
            hasSignalSinceStart = true
            observedSilenceStart = nil
        } else if observedSilenceStart == nil, frame.isSilent {
            observedSilenceStart = now
        }
        let silentFor = now - lastSignalTime

        // Power: 60 Hz for the panels, 20 Hz for the mini graph alone, 10 Hz after 5 s of silence.
        // Stereo analysis only while something shows it (vectorscope, meters, popover correlation).
        let level = consumerLevel()
        setEngineRate(silentFor > 5 ? 10 : level.engineRate)
        let wantStereo = level == .panels
        if wantStereo != stereoAnalysisOn {
            stereoAnalysisOn = wantStereo
            engine.analyzesStereo = wantStereo
            DebugLog.log("stereo analysis \(wantStereo)")
        }

        let active = silentFor < 1.5
        if active != signalActive {
            signalActive = active
            DebugLog.log("signal active \(active)")
            onSignalActivityChange?(active)
        }
        let idle = silentFor > idleAfterSeconds
        if idle != isIdle { isIdle = idle; DebugLog.log("idle \(idle)") }

        // Header
        let info = frame.stream ?? source?.streamInfo
        var h = HeaderState()
        if let info {
            h.sources = info.activeSources.joined(separator: ", ")
            h.device = info.deviceName
            h.sampleRate = HeaderState.format(sampleRate: info.sampleRate)
            h.bitDepth = info.bitDepth.map { "\($0)-bit" } ?? "—"
        }
        h.state = isDemo ? .demo : (silentFor > 0.5 ? .silent : .live)
        if isStartPending {
            let pendingFor = now - pendingSince
            // A normal start takes a few milliseconds: keep the header as it is, do not flash a state.
            if pendingFor < Self.pendingNoticeSeconds { h = header } else {
                h = HeaderState()
                h.state = .waiting
                // A capture start that does not return waits for the user's answer to the macOS prompt.
                h.notice = isDemo ? "Starting the demo signal" : "Allow “System Audio Recording” in the macOS prompt"
            }
        }
        if h != header { header = h }

        let flags = heldStressFlags(current: frame.headphone?.stressFlags ?? [], now: now)
        if flags != stressFlags { stressFlags = flags }

        spl.update(frame: frame)
        comparison.update(frame: frame)

        let delta = LoudnessDeltaState.make(integratedLUFS: frame.loudness.integratedLUFS, target: settings.loudnessTarget)
        if delta != loudnessDelta { loudnessDelta = delta }

        // Permission hint: an app plays, but only silence arrives, and no signal was seen since the start.
        let sourcesActive = !(info?.activeSources.isEmpty ?? true)
        let wantBanner = !isDemo && !isStartPending && !hasSignalSinceStart && !bannerDismissed && silentFor > 3 && sourcesActive

        // Placeholder: only when the panels have nothing to draw (no signal yet, or all decays are over).
        var placeholder: PanelPlaceholder?
        // A frozen display says so once, in the header. The cards carry no text then.
        // The permission banner says why nothing arrives: the plate would be a third message, so it hides.
        if !isFrozen, !isStartPending, !wantBanner, silentFor > 0.5, idle || !hasSignalSinceStart {
            placeholder = .waitingForAudio
        }
        if placeholder != panelPlaceholder { panelPlaceholder = placeholder }
        if wantBanner != showPermissionBanner { showPermissionBanner = wantBanner; DebugLog.log("permission banner \(wantBanner)") }
    }

    /// Flags flicker with the music. Hold each one for a few seconds, highest severity first.
    /// The detail text of a held flag updates at most once per second, so SwiftUI stays quiet.
    private func heldStressFlags(current: [StressFlag], now: TimeInterval) -> [StressFlag] {
        for var flag in current {
            // One minus sign everywhere: the model's text may carry an ASCII hyphen.
            flag.title = NumberText.typographic(flag.title)
            flag.detail = NumberText.typographic(flag.detail)
            if let held = heldFlags[flag.id], held.flag.severity == flag.severity, held.flag.title == flag.title, now - held.shownAt < 1 {
                heldFlags[flag.id] = (held.flag, now, held.shownAt)
            } else {
                heldFlags[flag.id] = (flag, now, now)
            }
        }
        heldFlags = heldFlags.filter { now - $0.value.lastSeen <= Self.flagHoldSeconds }
        return heldFlags.values.map(\.flag).sorted {
            $0.severity.rawValue != $1.severity.rawValue ? $0.severity.rawValue > $1.severity.rawValue : $0.id < $1.id
        }
    }

    /// The shell calls this when a window or the popover opens or closes: the engine rate and the stereo
    /// analysis follow at once, not at the next supervisor turn.
    func consumersDidChange() { supervise() }

    func dismissPermissionBanner() {
        bannerDismissed = true
        showPermissionBanner = false
    }

    func dismissCaptureError() { captureError = nil }

    var isSignalActive: Bool { signalActive }

    // MARK: Actions

    func resetMeasurement() {
        closeTrack()
        engine.resetMeasurement()
        heldFlags.removeAll()
        if isFrozen { toggleFreeze() }
    }

    // MARK: Per-track summary

    /// 10 Hz, only while signal is present: a few small copies.
    private func noteTrackProgress(_ frame: AnalysisFrame) {
        if trackStart == nil {
            trackStart = Date()
            trackLowestStrongHz = 0
        }
        trackEnd = Date()
        trackLoudness = frame.loudness
        // Only a calibrated estimate goes into the summary. A new estimator inside a track starts its Leq again.
        trackSPL = spl.latestReading.flatMap { $0.leqATrack > 20 ? TrackSPL(leqA: $0.leqATrack, maxA: $0.maxAFast, uncertaintyDB: $0.uncertaintyDB) : nil }
        let sources = (frame.stream ?? source?.streamInfo)?.activeSources ?? []
        // Demo mode has one name in the whole app: "Demo signal".
        if isDemo { trackSource = SignalState.demo.label } else if !sources.isEmpty { trackSource = sources.joined(separator: ", ") }
        // A long-term value of the analyzer: the newest reading is the best one. 0 = unknown.
        if frame.lowestStrongHz > 0 { trackLowestStrongHz = frame.lowestStrongHz }
    }

    /// Name part of a new reference: the apps that play now, or "Demo signal".
    private var comparisonSourceName: String {
        if isDemo { return SignalState.demo.label }
        return (engine.latestFrame.stream ?? source?.streamInfo)?.activeSources.joined(separator: ", ") ?? ""
    }

    /// The measurement so far. Nil until the integrated loudness is a measurement.
    func currentTrackSummary() -> TrackSummary? {
        guard let start = trackStart, let loudness = trackLoudness else { return nil }
        return TrackSummary(loudness: loudness, start: start, end: trackEnd, source: trackSource, lowestStrongHz: trackLowestStrongHz, spl: trackSPL)
    }

    /// The reading a summary is made from: the newest one of the measurement that ends. The supervisor copies a
    /// reading every 100 ms; the engine can have a newer one of the SAME measurement (more seconds, and a clip count
    /// that did not fall). That one counts, so the clips of the last 100 ms are in the summary as they are in the
    /// session events. A reading with fewer seconds belongs to a measurement after a reset: it never replaces the copy.
    static func closingReading(cached: LoudnessReading, engineLatest: LoudnessReading) -> LoudnessReading {
        engineLatest.measuredSeconds >= cached.measuredSeconds && engineLatest.clipCount >= cached.clipCount && engineLatest.isIntegratedValid
            ? engineLatest : cached
    }

    /// Call BEFORE every `engine.resetMeasurement()`: keeps the summary of the track that ends. The order matters:
    /// after the reset the clip count of the engine is 0 again.
    private func closeTrack() {
        if let cached = trackLoudness { trackLoudness = Self.closingReading(cached: cached, engineLatest: engine.latestFrame.loudness) }
        if let summary = currentTrackSummary(), summary.durationSeconds >= Self.minimumTrackSeconds {
            trackHistory = Array(([summary] + trackHistory).prefix(Self.trackHistoryLimit))
            DebugLog.log("track summary kept: \(summary.oneLine), \(summary.durationText)")
        }
        trackStart = nil
        trackLoudness = nil
        trackSPL = nil
        trackLowestStrongHz = 0
    }

    func clearTrackHistory() { trackHistory = [] }

    /// Forget the session record (timeline and events). The caller reloads its timeline view.
    func clearSessionRecord() { engine.session.clear() }

    func toggleFreeze() {
        isFrozen.toggle()
        gate.setFrozen(isFrozen)
        supervise()
    }

    // MARK: Headphones

    func reloadLibrary() {
        curves = library.allCurves()
        targets = library.allTargets()
    }

    static let defaultHeadphoneName = "HiFiMAN Susvara Unveiled"
    static let defaultTargetName = "Harman over-ear 2018"

    /// First run only: the user never chose a headphone (also not "None"), so select the default pair.
    private func applyFirstRunHeadphone() {
        guard !settings.hasStoredHeadphoneChoice, curves.contains(where: { $0.name == Self.defaultHeadphoneName }) else { return }
        settings.headphoneName = Self.defaultHeadphoneName
        if settings.targetName.isEmpty, targets.contains(where: { $0.name == Self.defaultTargetName }) {
            settings.targetName = Self.defaultTargetName
        }
    }

    /// Nil selects "None".
    func selectHeadphone(named name: String?) { settings.headphoneName = name ?? "" }

    func selectTarget(named name: String?) { settings.targetName = name ?? "" }

    var currentTargetName: String? {
        if let t = targets.first(where: { $0.name == settings.targetName }) { return t.name }
        return targets.first?.name
    }

    /// Import a curve file. Returns an error text on failure.
    @discardableResult
    func importCurve(from url: URL) -> String? {
        do {
            let curve = try library.importCurve(from: url)
            reloadLibrary()
            if !curves.contains(where: { $0.name == curve.name }) { curves.append(curve) }
            appliedModelKey = "\u{0}"
            settings.headphoneName = curve.name
            return nil
        } catch {
            DebugLog.log("curve import failed: \(error)")
            return "Joseon could not read a frequency response from “\(url.lastPathComponent)”. Use an AutoEq CSV file or a text file with two columns: frequency in Hz, level in dB."
        }
    }

    /// Show the open panel for a curve file, then import it.
    func runImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import headphone curve"
        panel.message = "Choose an AutoEQ CSV or a two-column frequency response file."
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .tabSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let message = importCurve(from: url) {
            let alert = NSAlert()
            alert.messageText = "Import failed"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    // MARK: Settings → engine

    private var appliedModelKey = "\u{0}"
    private var appliedSpectrumSettings = SpectrumSettings()

    private func applySettings() {
        // The analysis thread owns `engine.spectrum.settings`: keep a main-thread copy, send changes through the engine.
        var s = appliedSpectrumSettings
        s.displayBins = settings.displayBins
        s.releaseSeconds = Float(settings.releaseSeconds)
        s.peakDecayDBPerSecond = Float(settings.peakDecayDBPerSecond)
        s.tiltDBPerOctave = Float(settings.tiltDBPerOctave)
        if s != appliedSpectrumSettings {
            appliedSpectrumSettings = s
            engine.updateSpectrumSettings(s)
        }

        let targetName = currentTargetName
        let key = settings.headphoneName + "\u{1}" + (targetName ?? "")
        if key != appliedModelKey {
            appliedModelKey = key
            if let curve = curves.first(where: { $0.name == settings.headphoneName }) {
                let target = targets.first(where: { $0.name == targetName })
                engine.headphoneModel = HeadphoneModel(curve: curve, target: target)
                hasHeadphoneModel = true
                headphoneModelName = curve.name
                spl.setHeadphone(curve)
            } else {
                spl.setHeadphone(nil)
                engine.headphoneModel = nil
                hasHeadphoneModel = false
                headphoneModelName = nil
            }
            heldFlags.removeAll()
        }

        if started, settings.demoMode != appliedDemoMode { startSource() }
        if started { applyNowPlaying() }
    }

    // MARK: Now playing

    /// Starts the reader when the setting is on and stops it when off. The first start without the Accessibility
    /// permission explains it once (the shell's alert), then asks macOS. The reader is cheap while the player is absent.
    private func applyNowPlaying() {
        let want = settings.showNowPlaying
        guard want != nowPlayingStarted else { return }
        nowPlayingStarted = want
        if want {
            if !nowPlayingTrust.isTrusted(), !nowPlayingTrustAsked {
                nowPlayingTrustAsked = true
                onNowPlayingTrustNeeded?()
                nowPlayingTrust.requestTrust()
            }
            nowPlayingSource.start()
            nowPlaying = nowPlayingSource.current
        } else {
            nowPlayingSource.stop()
            nowPlaying = nil
        }
    }
}

