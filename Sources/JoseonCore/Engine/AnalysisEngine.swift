import Accelerate
import Foundation

/// Pulls audio from a StereoRingBuffer, runs the analyzers, publishes AnalysisFrame.
/// Runs on its own queue at a fixed tick. The consumer reads `latestFrame` (for example from a display link).
public final class AnalysisEngine: @unchecked Sendable {
    /// Owned by the analysis queue while the engine runs. Do not change `spectrum.settings` from another
    /// thread: use `updateSpectrumSettings(_:)`.
    public let spectrum: SpectrumAnalyzing
    public let loudness: LoudnessMetering
    public let stereo: StereoAnalyzing
    /// Rolling record of the last minutes of listening, one sample per second of audio time.
    /// The engine feeds it from the analysis thread; panels read `snapshot()` from any thread.
    public let session: SessionRecording
    /// Optional. Set or clear at any time from the main thread.
    public var headphoneModel: HeadphoneModeling? {
        get { stateLock.withLock { _headphoneModel } }
        set { stateLock.withLock { _headphoneModel = newValue } }
    }
    /// Optional. Set or clear at any time from the main thread. Needs a spectrum analyzer that is `ThirdOctaveProviding`.
    public var splEstimator: SPLEstimating? {
        get { stateLock.withLock { _splEstimator } }
        set { stateLock.withLock { _splEstimator = newValue } }
    }
    /// Stream facts to stamp on frames. The app sets this from AudioSource.onStreamInfoChange.
    public var streamInfo: StreamInfo? {
        get { stateLock.withLock { _streamInfo } }
        set { stateLock.withLock { _streamInfo = newValue } }
    }

    /// Off: the stereo analyzer does not run and frames carry an empty `StereoReading`. The app turns it off
    /// while no vectorscope or stereo readout is on screen (menu bar only): the stereo analyzer has no
    /// long-term state, so nothing is lost, and its 16 band filters are a quarter of the analysis cost.
    /// On again: the analyzer starts from a reset. Thread-safe.
    public var analyzesStereo: Bool {
        get { stateLock.withLock { _analyzesStereo } }
        set { stateLock.withLock { _analyzesStereo = newValue } }
    }

    private var _analyzesStereo = true
    private var _headphoneModel: HeadphoneModeling?
    private var _splEstimator: SPLEstimating?
    /// `LoudnessReading.measuredSeconds` at the last published frame: the audio clock the SPL estimator
    /// and the session recorder share. Analysis thread only.
    private var lastPublishedAudioTime: TimeInterval = 0
    private var _streamInfo: StreamInfo?
    private var _latest: AnalysisFrame
    /// Guards `_headphoneModel`, `_streamInfo`, `_latest`, `pendingReset`, `pendingSettings`.
    private let stateLock = NSLock()
    /// Guards `timer`: `start`, `stop`, `setTickRate` and `deinit` are safe from any thread.
    private let controlLock = NSLock()
    private let queue = DispatchQueue(label: "joseon.analysis", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>
    /// Input copies with every non-finite sample set to 0. Used only when a block has a NaN or an Inf.
    private let cleanL: UnsafeMutablePointer<Float>
    private let cleanR: UnsafeMutablePointer<Float>
    private let zeros: UnsafeMutablePointer<Float>
    private let scratchCapacity = 1 << 15
    private var pendingReset = false
    private var pendingSettings: SpectrumSettings?

    /// No samples for longer than this → the input is stale: the engine feeds zeros, so the spectrum
    /// releases, the meters fall, and frames say `isSilent`.
    public static let staleAfterSeconds: TimeInterval = 0.25
    /// Digital silence for this long, and a frame with every level at its floor → the engine sleeps:
    /// it still drains the ring and looks for signal, but it does not run the analyzers on zeros.
    /// The first non-zero sample wakes it. A silent source then costs almost no CPU.
    public static let sleepAfterSilentSeconds: TimeInterval = 4

    private static let maxReadsPerTick = 4

    // Analysis queue only (or the `processNow` caller while the timer is stopped).
    private var ring: StereoRingBuffer?
    private var lastSampleTime: TimeInterval = 0
    private var lastTickTime: TimeInterval = 0
    private var lastSampleRate: Double = 48_000
    private var tickInterval: TimeInterval = 1.0 / 60
    /// Seconds of audio in the current run of digital silence.
    private var silentRunSeconds: Double = 0
    /// Uptime of the first block of that run. A DEBUG build can analyze slower than real time (true peak
    /// at 96 kHz): audio seconds then pass slowly, the clock does not.
    private var silentRunStart: TimeInterval?
    private var asleep = false
    private var stereoOn = true
    private var sleepAllowed = true
    /// True while every block since the last publish was digital silence.
    private var silentSincePublish = true
    private var analyzedSincePublish = false
    private var lastFrameSilent = true
    private var publishedModel: HeadphoneModeling?
    /// Blocks that had a NaN or an Inf sample. For tests and diagnostics.
    private(set) var sanitizedBlockCount = 0
    /// For tests: the analyzers do not run now.
    var isAsleep: Bool { asleep }
    /// For tests: `processNow` never sleeps by default, so offline runs analyze every block.
    var sleepsInProcessNow = false

    public init(spectrum: SpectrumAnalyzing = SpectrumAnalyzer(), loudness: LoudnessMetering = LoudnessMeter(), stereo: StereoAnalyzing = StereoAnalyzer(), session: SessionRecording = SessionRecorder()) {
        self.spectrum = spectrum
        self.loudness = loudness
        self.stereo = stereo
        self.session = session
        scratchL = .allocate(capacity: scratchCapacity); scratchL.initialize(repeating: 0, count: scratchCapacity)
        scratchR = .allocate(capacity: scratchCapacity); scratchR.initialize(repeating: 0, count: scratchCapacity)
        cleanL = .allocate(capacity: scratchCapacity); cleanL.initialize(repeating: 0, count: scratchCapacity)
        cleanR = .allocate(capacity: scratchCapacity); cleanR.initialize(repeating: 0, count: scratchCapacity)
        zeros = .allocate(capacity: scratchCapacity); zeros.initialize(repeating: 0, count: scratchCapacity)
        _latest = AnalysisFrame(spectrum: .silent(binCount: spectrum.settings.displayBins))
    }

    deinit {
        // A resumed dispatch source must be cancelled before its last release. The timer is never
        // suspended, so cancel + release is safe. The handler holds `self` weakly: no tick runs now.
        timer?.cancel()
        timer = nil
        scratchL.deallocate(); scratchR.deallocate(); cleanL.deallocate(); cleanR.deallocate(); zeros.deallocate()
    }

    /// Newest frame. Cheap to call from the render loop.
    public var latestFrame: AnalysisFrame { stateLock.withLock { _latest } }

    /// Start (or restart on a new ring). Safe from any thread, but not from inside an analyzer callback.
    public func start(reading ring: StereoRingBuffer, ticksPerSecond: Double = 60) {
        controlLock.lock()
        defer { controlLock.unlock() }
        timer?.cancel()
        timer = nil
        let interval = 1.0 / max(ticksPerSecond, 1)
        // A tick of the old timer may still run: swap the ring on the analysis queue, after that tick.
        queue.sync {
            self.ring = ring
            let now = ProcessInfo.processInfo.systemUptime
            lastSampleTime = now
            lastTickTime = now
            tickInterval = interval
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: Self.leeway(for: interval))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    /// Stop the tick. A tick that runs now still ends; no tick starts after it. Safe to call twice.
    public func stop() {
        controlLock.lock()
        defer { controlLock.unlock() }
        timer?.cancel()
        timer = nil
    }

    /// Change the tick rate of a running engine. No stop/start: the analyzers and the ring stay as they are.
    /// Does nothing when the engine is stopped.
    public func setTickRate(_ ticksPerSecond: Double) {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard let timer else { return }
        let interval = 1.0 / max(ticksPerSecond, 1)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: Self.leeway(for: interval))
        queue.async { [weak self] in self?.tickInterval = interval }
    }

    /// A tenth of the interval, 1...10 ms: a slow tick lets the kernel group the wake-up with others.
    private static func leeway(for interval: TimeInterval) -> DispatchTimeInterval {
        .microseconds(Int(min(max(interval / 10, 0.001), 0.010) * 1_000_000))
    }

    /// Start a new measurement (integrated loudness, max values, average spectrum, headphone flag hold).
    public func resetMeasurement() { stateLock.withLock { pendingReset = true } }

    /// Thread-safe settings change. Applies on the analysis queue before the next tick's analysis.
    /// When the engine is stopped, it applies on the next `start` tick or the next `processNow`.
    public func updateSpectrumSettings(_ settings: SpectrumSettings) {
        stateLock.withLock { pendingSettings = settings }
    }

    /// Analysis thread: take the pending settings and the pending reset.
    private func applyPending() {
        let (doReset, newSettings, model, wantStereo): (Bool, SpectrumSettings?, HeadphoneModeling?, Bool) = stateLock.withLock {
            let r = (pendingReset, pendingSettings, _headphoneModel, _analyzesStereo)
            pendingReset = false
            pendingSettings = nil
            return r
        }
        if wantStereo != stereoOn {
            stereoOn = wantStereo
            if wantStereo { stereo.reset() }    // its state is from before the pause
        }
        if let newSettings, newSettings != spectrum.settings {
            spectrum.settings = newSettings
            asleep = false      // the frame must show the new settings
        }
        if doReset {
            spectrum.reset(); loudness.reset(); stereo.reset(); model?.reset()
            stateLock.withLock { _splEstimator }?.resetMeasurement()
            session.noteTrackStart()
            // The meters start from 0 again: the next frame's audio time is not a step from this one.
            lastPublishedAudioTime = 0
            asleep = false
        }
    }

    /// Run one analysis step now on the caller's thread. Used by tests and the probe. Not while the timer runs.
    public func processNow(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, sampleRate: Double) -> AnalysisFrame {
        applyPending()
        sleepAllowed = sleepsInProcessNow
        if !sleepAllowed { asleep = false }
        analyze(left: left, right: right, count: count, sampleRate: sampleRate)
        return publish(force: true)
    }

    private func tick() {
        guard let ring else { return }
        sleepAllowed = true
        applyPending()
        let now = ProcessInfo.processInfo.systemUptime
        let sinceLastTick = min(max(now - lastTickTime, 0), 0.25)
        lastTickTime = now
        var n = ring.read(left: scratchL, right: scratchR, maxCount: scratchCapacity)
        if n > 0 {
            lastSampleTime = now
            // At most one ring of audio per tick (4 reads of 32768 frames). Analysis that is slower than real
            // time (a DEBUG build at 96 kHz) would otherwise never leave this loop: the ring fills again while
            // the block is analyzed, so the tick never ends, no frame is published and the engine cannot sleep.
            var reads = 0
            while n > 0 {
                if ring.sampleRate > 0 { lastSampleRate = ring.sampleRate }
                analyze(left: scratchL, right: scratchR, count: n, sampleRate: lastSampleRate)
                reads += 1
                if reads >= Self.maxReadsPerTick { break }
                n = ring.read(left: scratchL, right: scratchR, maxCount: scratchCapacity)
            }
        } else if now - lastSampleTime > Self.staleAfterSeconds {
            // The source stalled (stopped tap, device gone, start pending). Feed the time that passed as
            // digital silence: the analyzers decay with their own ballistics, and the frame says `isSilent`.
            // Never more than 1.5 ticks of zeros per tick: a late tick (slow DEBUG analyzers, a busy Mac)
            // must not get a longer block, run later again, and so hold the thread at 100 %.
            let seconds = min(sinceLastTick, tickInterval * 1.5)
            let count = min(scratchCapacity, Int(lastSampleRate * seconds))
            if count > 0 { analyze(left: zeros, right: zeros, count: count, sampleRate: lastSampleRate) }
        }
        publish(force: false)
    }

    /// One block: sanitize, look for signal, run the analyzers (not while asleep).
    private func analyze(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard count > 0, sampleRate > 0, sampleRate.isFinite else { return }
        // One finite check for all analyzers. A sum is finite only when every sample is finite
        // (a sum of finite floats that overflows is sanitized for nothing: harmless).
        var sumL: Float = 0, sumR: Float = 0
        vDSP_sve(left, 1, &sumL, vDSP_Length(count))
        vDSP_sve(right, 1, &sumR, vDSP_Length(count))
        if !(sumL + sumR).isFinite {
            sanitizedBlockCount += 1
            var offset = 0
            while offset < count {
                let n = min(scratchCapacity, count - offset)
                for i in 0..<n {
                    let l = left[offset + i], r = right[offset + i]
                    cleanL[i] = l.isFinite ? l : 0
                    cleanR[i] = r.isFinite ? r : 0
                }
                analyzeFinite(left: cleanL, right: cleanR, count: n, sampleRate: sampleRate)
                offset += n
            }
        } else {
            analyzeFinite(left: left, right: right, count: count, sampleRate: sampleRate)
        }
    }

    private func analyzeFinite(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        var peakL: Float = 0, peakR: Float = 0
        vDSP_maxmgv(left, 1, &peakL, vDSP_Length(count))
        vDSP_maxmgv(right, 1, &peakR, vDSP_Length(count))
        if peakL == 0 && peakR == 0 {
            silentRunSeconds += Double(count) / sampleRate
            if silentRunStart == nil { silentRunStart = ProcessInfo.processInfo.systemUptime }
        } else {
            silentRunSeconds = 0
            silentRunStart = nil
            silentSincePublish = false
            asleep = false
        }
        if asleep { return }
        analyzedSincePublish = true
        spectrum.process(left: left, right: right, count: count, sampleRate: sampleRate)
        loudness.process(left: left, right: right, count: count, sampleRate: sampleRate)
        if stereoOn { stereo.process(left: left, right: right, count: count, sampleRate: sampleRate) }
    }

    /// `force`: build a frame also when no block was analyzed since the last one (`processNow`).
    @discardableResult
    private func publish(force: Bool) -> AnalysisFrame {
        let (model, info, previous) = stateLock.withLock { (_headphoneModel, _streamInfo, _latest) }
        let modelChanged = model !== publishedModel
        if !analyzedSincePublish && !force && !modelChanged {
            // No new audio went through the analyzers (the ring was empty, or the engine sleeps): the
            // readings did not change. Keep the frame and its `hostTime`, so consumers see "no new frame".
            // Only the stream facts can change (a new device, an app that starts to play).
            if previous.stream != info {
                stateLock.withLock { _latest.stream = info }
            }
            return previous
        }
        // `isSilent` = digital silence in every block since the last frame, not only in the last block.
        if analyzedSincePublish || force { lastFrameSilent = silentSincePublish }
        silentSincePublish = true
        analyzedSincePublish = false
        publishedModel = model

        let s = spectrum.read()
        let l = loudness.read()
        var frame = AnalysisFrame(
            hostTime: ProcessInfo.processInfo.systemUptime,
            stream: info,
            spectrum: s.spectrum,
            peak: s.peak,
            bands: s.bands,
            loudness: l,
            stereo: stereoOn ? stereo.read() : StereoReading(),
            headphone: nil,
            isSilent: lastFrameSilent
        )
        if let extra = spectrum as? TopPeaksProviding {
            frame.topPeaks = extra.topPeaks
            frame.lowestStrongHz = extra.lowestStrongHz
        }
        frame.headphone = model?.evaluate(spectrum: s.spectrum, bands: s.bands, loudness: l)
        // Seconds of audio since the previous published frame, from measured audio time: the dose and the
        // session timeline count audio, not wall time. A reset makes `measuredSeconds` fall: that is 0, not
        // a step back. One computation, two consumers.
        let audioNow = l.measuredSeconds
        let dt = max(0, min(audioNow - lastPublishedAudioTime, 1))
        lastPublishedAudioTime = audioNow
        if let bands = (spectrum as? ThirdOctaveProviding)?.thirdOctave {
            frame.thirdOctave = bands
            if let estimator = stateLock.withLock({ _splEstimator }) {
                frame.spl = estimator.evaluate(thirdOctave: bands, dt: dt, isSilent: frame.isSilent)
            }
        }
        stateLock.withLock { _latest = frame }
        session.ingest(frame, dt: dt)
        if sleepAllowed, !asleep, Self.isAtRest(frame) {
            let silentByClock = silentRunStart.map { frame.hostTime - $0 } ?? 0
            if max(silentRunSeconds, silentByClock) >= Self.sleepAfterSilentSeconds { asleep = true }
        }
        return frame
    }

    /// True when nothing in the frame can still move without new signal: the spectrum, the peak hold and
    /// the meters are at their floors and no stress flag is up.
    static func isAtRest(_ frame: AnalysisFrame) -> Bool {
        guard frame.isSilent else { return false }
        if let flags = frame.headphone?.stressFlags, !flags.isEmpty { return false }
        let l = frame.loudness
        let meterFloor = LoudnessReading.silenceLUFS + 1
        guard l.momentaryLUFS <= meterFloor, l.shortTermLUFS <= meterFloor,
              l.rmsLeftDB <= meterFloor, l.rmsRightDB <= meterFloor else { return false }
        let floor = SpectrumReading.floorDB + 0.5
        for trace in [frame.spectrum.peakHold, frame.spectrum.mid, frame.spectrum.left, frame.spectrum.right, frame.spectrum.side] {
            var top: Float = -.infinity
            trace.withUnsafeBufferPointer { p in
                if let base = p.baseAddress, p.count > 0 { vDSP_maxv(base, 1, &top, vDSP_Length(p.count)) }
            }
            if top > floor { return false }
        }
        return !frame.stereo.bandActive.contains(true)
    }
}
