import AVFoundation
import AppKit
import os

/// The calibration test tone as a pure function of the sample position: a sine with a raised-cosine fade-in,
/// a raised-cosine fade-out, and a hard end. No allocation, no lock, no clock: the audio thread calls `render`,
/// and the self-check renders the same code offline.
struct ToneGenerator {
    let sampleRate: Double
    let frequency: Double
    /// Peak of the sine, linear. −20 dBFS = 0.1, so the RMS is −23.01 dBFS.
    let peak: Double
    let fadeInSamples: Int
    let fadeOutSamples: Int
    /// The tone is over at this sample, fade-out included. Nothing but zeros after it.
    let hardEndSample: Int

    private(set) var position = 0
    /// Sample at which the fade-out starts. Set by `requestStop`, or by the hard limit.
    private(set) var fadeOutStart: Int
    /// Envelope value at `fadeOutStart` (smaller than 1 when the stop came inside the fade-in).
    private var fadeOutFrom: Double = 1

    init(sampleRate: Double, frequency: Double = SPLMath.toneFrequencyHz, levelDBFS: Double = SPLMath.toneLevelDBFS,
         fadeInSeconds: Double = 0.5, fadeOutSeconds: Double = 0.1, maxSeconds: Double = 60) {
        self.sampleRate = sampleRate
        self.frequency = frequency
        peak = pow(10, levelDBFS / 20)
        fadeInSamples = max(1, Int(fadeInSeconds * sampleRate))
        fadeOutSamples = max(1, Int(fadeOutSeconds * sampleRate))
        hardEndSample = Int(maxSeconds * sampleRate)
        fadeOutStart = hardEndSample - fadeOutSamples
    }

    var isFinished: Bool { position >= fadeOutStart + fadeOutSamples }
    var secondsPlayed: Double { Double(min(position, fadeOutStart + fadeOutSamples)) / sampleRate }

    private func fadeInGain(at n: Int) -> Double {
        n >= fadeInSamples ? 1 : 0.5 * (1 - cos(Double.pi * Double(n) / Double(fadeInSamples)))
    }

    /// Envelope 0...1 at sample `n`.
    func envelope(at n: Int) -> Double {
        if n < fadeOutStart { return fadeInGain(at: n) }
        let t = n - fadeOutStart
        if t >= fadeOutSamples { return 0 }
        return fadeOutFrom * 0.5 * (1 + cos(Double.pi * Double(t) / Double(fadeOutSamples)))
    }

    /// Start the fade-out at the current position. A second call changes nothing.
    mutating func requestStop() {
        guard position < fadeOutStart else { return }
        fadeOutFrom = fadeInGain(at: position)
        fadeOutStart = position
    }

    /// Writes `count` samples and moves on. The phase comes from the sample position, so blocks join without a step.
    mutating func render(into out: UnsafeMutablePointer<Float>, count: Int) {
        let step = 2 * Double.pi * frequency / sampleRate
        let end = fadeOutStart + fadeOutSamples
        for i in 0..<count {
            let n = position + i
            out[i] = n >= end ? 0 : Float(peak * envelope(at: n) * sin(step * Double(n)))
        }
        position += count
    }
}

/// State the audio thread and the main thread share. The audio thread only TRIES the lock: it never waits.
final class ToneShared: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var stopRequested = false
    private var envelope: Float = 0
    private var seconds: Double = 0
    private var finished = false

    func requestStop() { os_unfair_lock_lock(&lock); stopRequested = true; os_unfair_lock_unlock(&lock) }

    func read() -> (envelope: Float, seconds: Double, finished: Bool) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return (envelope, seconds, finished)
    }

    /// Audio thread. Returns true when a stop was requested. A missed try is fine: the next block sees it (about 10 ms).
    func exchange(envelope e: Float, seconds s: Double, finished f: Bool) -> Bool {
        guard os_unfair_lock_trylock(&lock) else { return false }
        envelope = e; seconds = s; finished = f
        let stop = stopRequested
        os_unfair_lock_unlock(&lock)
        return stop
    }
}

/// Plays the calibration tone through the default output. Starts ONLY with a `TonePlayPermit`: that type lives in
/// `PlayPermit.swift` with a fileprivate init, so only a press of a `PermitButton` (safety checkbox ticked) can make one.
/// Stops by itself: after 60 s, when the output device changes, when the app goes to the background, and when the
/// calibration window closes (the window calls `stop`). Snapshot mode and the self-check can never start it.
final class TonePlayer: ObservableObject {
    enum State: Equatable { case idle, playing, failed(String) }

    @Published private(set) var state: State = .idle
    /// Level of the tone now in dBFS (peak), for the meter. −120 when silent.
    @Published private(set) var levelDBFS: Double = -120
    @Published private(set) var secondsLeft: Double = 0

    static let maxSeconds: Double = 60

    private var engine: AVAudioEngine?
    private var shared: ToneShared?
    private var poll: Timer?
    private var observers: [NSObjectProtocol] = []

    /// The same node graph for the real player and for the offline self-check: source node -> output node,
    /// no mixer gain in between, both channels carry the same samples.
    static func makeSourceNode(sampleRate: Double, shared: ToneShared) -> (node: AVAudioSourceNode, format: AVAudioFormat)? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return nil }
        var generator = ToneGenerator(sampleRate: sampleRate, maxSeconds: maxSeconds)
        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let count = Int(frameCount)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let done = generator.isFinished
            if shared.exchange(envelope: Float(generator.envelope(at: generator.position)), seconds: generator.secondsPlayed, finished: done) {
                generator.requestStop()
            }
            generator.render(into: first, count: count)
            for buffer in buffers.dropFirst() {
                if let p = buffer.mData?.assumingMemoryBound(to: Float.self) { p.update(from: first, count: count) }
            }
            if done { isSilence.pointee = true }
            return noErr
        }
        return (node, format)
    }

    func start(permit: TonePlayPermit) {
        // A permit is fresh: a stored one does not start a tone later.
        guard permit.isFresh(), state != .playing else { return }
        // Snapshot mode and the offline self-checks never make sound, and an offline permit starts nothing.
        guard !permit.isOffline, !TonePlayPermit.processIsOffline else { return }
        guard NSApp.isActive else { state = .failed("Joseon must be the front app to play the test tone."); return }

        let engine = AVAudioEngine()
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let shared = ToneShared()
        guard sampleRate > 0, let source = Self.makeSourceNode(sampleRate: sampleRate, shared: shared) else {
            state = .failed("The output device gave no audio format.")
            return
        }
        engine.attach(source.node)
        engine.connect(source.node, to: engine.outputNode, format: source.format)
        do { try engine.start() } catch {
            state = .failed("The test tone did not start: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        self.shared = shared
        state = .playing
        secondsLeft = Self.maxSeconds

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.stop() },
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.stopNow() },
            // The output device or its format changed: the engine has stopped already.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in self?.stopNow() },
        ]
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    /// Fade out (0.1 s), then stop the engine.
    func stop() {
        guard state == .playing else { return }
        shared?.requestStop()
    }

    /// No fade: the device is gone, or the app ends.
    func stopNow() {
        poll?.invalidate(); poll = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine?.stop()
        engine = nil
        shared = nil
        levelDBFS = -120
        secondsLeft = 0
        if state == .playing { state = .idle }
    }

    /// The default output device changed (from `OutputVolumeMonitor`).
    func outputDeviceChanged() { if state == .playing { stopNow() } }

    private func tick() {
        guard let shared else { return }
        let now = shared.read()
        if now.finished { stopNow(); return }
        levelDBFS = now.envelope > 0 ? SPLMath.toneLevelDBFS + 20 * log10(Double(now.envelope)) : -120
        secondsLeft = max(0, Self.maxSeconds - now.seconds)
    }

    deinit { engine?.stop() }
}
