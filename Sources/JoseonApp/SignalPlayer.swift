import AVFoundation
import AppKit

// The measurement sweep player: the SECOND use of the permit pattern (the first is `TonePlayer`).
// It plays one prepared buffer once, through the default output, and only with a `TonePlayPermit`.

/// A prepared signal in memory the audio thread can read: allocated once, never resized, never written again.
final class PreparedBuffer: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Float>
    let count: Int
    /// Largest |sample|.
    let peak: Float

    init(_ samples: [Float]) {
        count = samples.count
        pointer = .allocate(capacity: max(1, samples.count))
        pointer.initialize(repeating: 0, count: max(1, samples.count))
        var p: Float = 0
        for (i, x) in samples.enumerated() { pointer[i] = x; p = max(p, abs(x)) }
        peak = p
    }

    deinit { pointer.deallocate() }
}

/// The prepared buffer as a pure function of the sample position: a raised-cosine fade-in on top of whatever the
/// buffer holds, a hard end, and a short raised-cosine fade-out when a stop comes early or the buffer is longer than
/// the hard limit. No allocation, no lock, no clock: the audio thread calls `render`, the self-check and the fake
/// player render the same code offline.
struct BufferGenerator {
    let sampleRate: Double
    let buffer: PreparedBuffer
    let fadeInSamples: Int
    let fadeOutSamples: Int
    /// Nothing but zeros from this sample on.
    let hardEndSample: Int

    private(set) var position = 0
    private(set) var fadeOutStart: Int
    private var fadeOutFrom: Double = 1

    /// The player's own fade-in. It is there so that NO buffer can start with a step. It is short next to the 100 ms
    /// fade the sweep carries itself (see `MeasureSignal`): it changes only the first 10 ms, where the sweep is still
    /// under 3% of its level, by less than −36 dB relative to the sweep peak. The self-check measures that, and its
    /// 0.5 dB curve check runs on the signal as THIS generator renders it.
    static let fadeInSeconds = 0.01
    static let fadeOutSeconds = 0.05

    init(sampleRate: Double, buffer: PreparedBuffer, maxSeconds: Double = SignalPlayer.maxSeconds) {
        self.sampleRate = sampleRate
        self.buffer = buffer
        fadeInSamples = max(1, Int(Self.fadeInSeconds * sampleRate))
        fadeOutSamples = max(1, Int(Self.fadeOutSeconds * sampleRate))
        let limit = Int(maxSeconds * sampleRate)
        if buffer.count > limit {
            // Too long: fade out before the hard limit instead of cutting the signal with a step.
            hardEndSample = limit
            fadeOutStart = max(0, limit - fadeOutSamples)
        } else {
            hardEndSample = buffer.count
            fadeOutStart = buffer.count          // the buffer ends by itself: no fade-out from here
        }
    }

    var isFinished: Bool { position >= min(hardEndSample, fadeOutStart + fadeOutSamples) }
    var secondsPlayed: Double { Double(min(position, hardEndSample)) / sampleRate }

    private func fadeInGain(at n: Int) -> Double {
        n >= fadeInSamples ? 1 : 0.5 * (1 - cos(Double.pi * Double(n) / Double(fadeInSamples)))
    }

    func envelope(at n: Int) -> Double {
        if n >= hardEndSample { return 0 }
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

    mutating func render(into out: UnsafeMutablePointer<Float>, count: Int) {
        let source = buffer.pointer
        for i in 0..<count {
            let n = position + i
            out[i] = n < hardEndSample ? Float(Double(source[n]) * envelope(at: n)) : 0
        }
        position += count
    }

    /// The whole played signal, offline. What the fake player "plays" and what the self-check inspects.
    static func renderAll(_ samples: [Float], sampleRate: Double, maxSeconds: Double = SignalPlayer.maxSeconds, block: Int = 512) -> [Float] {
        var g = BufferGenerator(sampleRate: sampleRate, buffer: PreparedBuffer(samples), maxSeconds: maxSeconds)
        let total = g.hardEndSample
        var out = [Float](repeating: 0, count: total)
        var done = 0
        out.withUnsafeMutableBufferPointer { p in
            while done < total {
                let n = min(block, total - done)
                g.render(into: p.baseAddress! + done, count: n)
                done += n
            }
        }
        return out
    }
}

/// How a play ended. Delivered on the main queue, once per accepted `play`.
enum SignalPlayEnd: Equatable {
    /// The whole buffer went out.
    case completed
    /// It ended early. The text says why, in words for the user.
    case stopped(String)
}

/// The seam between the measurement controller and the sound output. The app uses `SignalPlayer`; the self-check
/// and snapshot mode use a fake that renders into memory.
protocol SignalPlaying: AnyObject {
    /// Sample rate the buffer must have. 0 when there is no output.
    var outputSampleRate: Double { get }
    var isPlaying: Bool { get }
    /// Plays `samples` once. Returns nil when it started, or the reason it did not, in words for the user.
    /// `onEnd` runs on the main queue exactly once when nil was returned, and never otherwise.
    func play(_ samples: [Float], permit: TonePlayPermit, onEnd: @escaping (SignalPlayEnd) -> Void) -> String?
    /// Fade out and stop. `onEnd` gets `.stopped(reason)`.
    func stop(reason: String)
}

/// Plays one prepared buffer once through the default output. Same rules as `TonePlayer`:
/// - it starts ONLY with a fresh, non-offline `TonePlayPermit` (a press of a `PermitButton` with the checkbox ticked);
/// - never in snapshot mode or in a self-check; only while Joseon is the front app;
/// - fade-in, hard length limit (`maxSeconds`), hard level limit (`maxPeak`);
/// - it stops when the app goes to the background, when the output device or its format changes, when the app ends,
///   and when the measurement window closes (the window's controller calls `stop`).
final class SignalPlayer: SignalPlaying {
    /// Hard length limit. The longest sweep the math module makes is 10 s.
    static let maxSeconds: Double = 12
    /// Hard level limit: −6 dBFS peak, with a hair of rounding room. A louder buffer is refused.
    static let maxPeak: Float = Float(pow(10, -6.0 / 20)) * 1.001
    /// The controller opens the input between the button press and the start of the sound; that takes a moment.
    static let maxPermitAgeSeconds: TimeInterval = 6

    private var engine: AVAudioEngine?
    private var shared: ToneShared?
    private var buffer: PreparedBuffer?
    private var poll: Timer?
    private var observers: [NSObjectProtocol] = []
    private var onEnd: ((SignalPlayEnd) -> Void)?
    private var stopReason: String?

    var isPlaying: Bool { engine != nil }

    /// Reads the format of the default output. It starts nothing and plays nothing.
    var outputSampleRate: Double {
        guard !TonePlayPermit.processIsOffline else { return 0 }
        return AVAudioEngine().outputNode.outputFormat(forBus: 0).sampleRate
    }

    /// The same node graph for the real player and for the offline self-check: source node -> output node.
    static func makeSourceNode(sampleRate: Double, buffer: PreparedBuffer, shared: ToneShared) -> (node: AVAudioSourceNode, format: AVAudioFormat)? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return nil }
        var generator = BufferGenerator(sampleRate: sampleRate, buffer: buffer)
        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let count = Int(frameCount)
            guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let done = generator.isFinished
            if shared.exchange(envelope: Float(generator.envelope(at: generator.position)), seconds: generator.secondsPlayed, finished: done) {
                generator.requestStop()
            }
            generator.render(into: first, count: count)
            for other in buffers.dropFirst() {
                if let p = other.mData?.assumingMemoryBound(to: Float.self) { p.update(from: first, count: count) }
            }
            if done { isSilence.pointee = true }
            return noErr
        }
        return (node, format)
    }

    /// Why this permit starts nothing, or nil. Pure: the self-check calls it. `play` asks this FIRST, before it
    /// touches AVFoundation.
    static func permitRefusal(_ permit: TonePlayPermit) -> String? {
        if permit.isOffline || TonePlayPermit.processIsOffline { return "This run of Joseon can not play sound (snapshot mode or self-check)." }
        if !permit.isFresh(within: maxPermitAgeSeconds) { return "The button press is too old. Press the button again." }
        return nil
    }

    static func refusal(samples: [Float], sampleRate: Double) -> String? {
        if samples.isEmpty || sampleRate <= 0 { return "There is no signal to play." }
        if Double(samples.count) > maxSeconds * sampleRate { return "The signal is longer than \(Int(maxSeconds)) s. Joseon does not play it." }
        var peak: Float = 0
        for x in samples { if !x.isFinite { return "The signal is damaged. Joseon does not play it." }; peak = max(peak, abs(x)) }
        if peak > maxPeak { return "The signal is louder than \(NumberText.signed(-6)) dBFS. Joseon does not play it." }
        return nil
    }

    func play(_ samples: [Float], permit: TonePlayPermit, onEnd: @escaping (SignalPlayEnd) -> Void) -> String? {
        if let refusal = Self.permitRefusal(permit) { return refusal }
        guard engine == nil else { return "A signal plays already." }
        guard NSApp != nil, NSApp.isActive else { return "Joseon must be the front app to play the sweep." }
        let engine = AVAudioEngine()
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if let refusal = Self.refusal(samples: samples, sampleRate: sampleRate) { return refusal }
        let prepared = PreparedBuffer(samples)
        let shared = ToneShared()
        guard let source = Self.makeSourceNode(sampleRate: sampleRate, buffer: prepared, shared: shared) else {
            return "The output device gave no audio format."
        }
        engine.attach(source.node)
        engine.connect(source.node, to: engine.outputNode, format: source.format)
        do { try engine.start() } catch { return "The sweep did not start: \(error.localizedDescription)" }
        self.engine = engine
        self.shared = shared
        self.buffer = prepared
        self.onEnd = onEnd
        stopReason = nil

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.stop(reason: "Joseon went to the background, so the sweep stopped. Keep Joseon in front during a run.")
            },
            center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                self?.finish(.stopped("Joseon quit."))
            },
            // The output device or its format changed: the engine has stopped already.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.finish(.stopped("The output device changed during the run, so the sweep stopped."))
            },
        ]
        let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        poll = t
        return nil
    }

    func stop(reason: String) {
        guard engine != nil else { return }
        if stopReason == nil { stopReason = reason }
        shared?.requestStop()
    }

    private func tick() {
        guard let shared, shared.read().finished else { return }
        finish(stopReason.map(SignalPlayEnd.stopped) ?? .completed)
    }

    private func finish(_ end: SignalPlayEnd) {
        guard engine != nil else { return }
        poll?.invalidate(); poll = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        engine?.stop()
        engine = nil
        shared = nil
        buffer = nil
        let callback = onEnd
        onEnd = nil
        callback?(end)
    }

    deinit { engine?.stop() }
}
