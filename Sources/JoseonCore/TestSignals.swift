import Foundation

/// Synthetic signals for tests, the probe, and demo mode.
public enum TestSignals {
    /// Sine at `hz`, peak amplitude `amplitude` (1.0 = 0 dBFS), optional phase in radians.
    public static func sine(hz: Double, amplitude: Float, sampleRate: Double, seconds: Double, phase: Double = 0) -> [Float] {
        let n = Int(sampleRate * seconds)
        return (0..<n).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / sampleRate + phase)) }
    }

    /// Deterministic white noise in -amplitude...amplitude.
    public static func whiteNoise(amplitude: Float, count: Int, seed: UInt64 = 0x4A6F73656F6E) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Float(state >> 40) / Float(1 << 24)
            return (u * 2 - 1) * amplitude
        }
    }

    /// Pink-ish noise (Paul Kellet filter) from the deterministic white noise.
    public static func pinkNoise(amplitude: Float, count: Int, seed: UInt64 = 0x4A6F73656F6E) -> [Float] {
        let white = whiteNoise(amplitude: 1, count: count, seed: seed)
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        var out = [Float](repeating: 0, count: count)
        var peak: Float = 1e-9
        for i in 0..<count {
            b0 = 0.99765 * b0 + white[i] * 0.0990460
            b1 = 0.96300 * b1 + white[i] * 0.2965164
            b2 = 0.57000 * b2 + white[i] * 1.0526913
            out[i] = b0 + b1 + b2 + white[i] * 0.1848
            peak = max(peak, abs(out[i]))
        }
        let g = amplitude / peak
        return out.map { $0 * g }
    }

    // MARK: Demo signal

    /// Pink noise table of the demo signal. Built once.
    private static let demoNoise: [Float] = pinkNoise(amplitude: 0.08, count: 1 << 16)

    /// The music-like demo signal: a kick every half second, a four-chord loop (2 s per chord) that
    /// pans slowly, two quiet one-sided tones, and a pink noise bed. It is a pure function of the
    /// sample position, so an offline render and `DemoAudioSource` give the same samples.
    ///
    /// The one-sided tones are honest stereo content, not a trick: a 6.2 kHz shimmer in the **right**
    /// channel only and a 3.1 kHz tone in the **left** channel only, both gently amplitude modulated.
    /// Round 2 had the shimmer as +L / -R, which is pure side: mid really does read 24 dB below left
    /// and right there, and a reviewer read that correct number as a bug in the mid curve. A tone in
    /// one channel puts energy in mid, side, and that channel, which is what a stereo view is for.
    /// - Parameter startSample: index of the first sample since the start of the signal.
    public static func demoBlock(startSample: Int, count: Int, sampleRate: Double = 48_000) -> (left: [Float], right: [Float]) {
        var l = [Float](repeating: 0, count: max(count, 0)), r = l
        let noise = demoNoise
        for i in 0..<l.count {
            let sample = startSample + i
            let time = Double(sample) / sampleRate
            let beat = time.truncatingRemainder(dividingBy: 0.5)
            let kick = Float(exp(-beat * 18) * sin(2 * .pi * (48 + 60 * exp(-beat * 30)) * beat)) * 0.5
            let root = [110.0, 130.81, 146.83, 98.0][Int(time / 2) % 4]
            var chord: Float = 0
            for (k, m) in [1.0, 1.5, 2.0, 2.52, 3.0, 4.0].enumerated() { chord += Float(sin(2 * .pi * root * m * time)) * 0.07 / Float(k + 1) }
            let pan = Float(sin(time * 0.7))
            // Right only, about 10 dB below the round 2 shimmer, modulated between half and full depth
            // so it breathes instead of sitting still.
            let shimmer = Float(sin(2 * .pi * 6_200 * time) * (0.75 + 0.25 * sin(2 * .pi * 3 * time))) * 0.0047
            // Left only, quieter again, at a different rate so the two never line up.
            let sparkle = Float(sin(2 * .pi * 3_100 * time) * (0.75 + 0.25 * sin(2 * .pi * 1.7 * time))) * 0.0030
            let ni = ((sample % noise.count) + noise.count) % noise.count
            l[i] = kick + chord * (1 - 0.4 * pan) + sparkle + noise[ni] * 0.5
            r[i] = kick + chord * (1 + 0.4 * pan) + shimmer + noise[(ni + 4002) % noise.count] * 0.5
        }
        return (l, r)
    }

    /// The same, addressed by time in seconds since the start of the signal.
    public static func demoBlock(startTime: Double, count: Int, sampleRate: Double = 48_000) -> (left: [Float], right: [Float]) {
        demoBlock(startSample: Int((startTime * sampleRate).rounded()), count: count, sampleRate: sampleRate)
    }
}

/// A looping synthetic AudioSource: music-like demo signal. Used when capture is not possible.
public final class DemoAudioSource: AudioSource {
    public private(set) var streamInfo: StreamInfo?
    public let ringBuffer = StereoRingBuffer()
    public var onStreamInfoChange: ((StreamInfo) -> Void)?
    public private(set) var isRunning = false
    private var timer: DispatchSourceTimer?
    private let sampleRate: Double = 48_000

    public init() {}

    public func start() throws {
        guard !isRunning else { return }
        isRunning = true
        let info = StreamInfo(sampleRate: sampleRate, channelCount: 2, deviceName: "Demo signal", bitDepth: 32, activeSources: ["Joseon demo"])
        streamInfo = info
        DispatchQueue.main.async { [weak self] in self?.onStreamInfoChange?(info) }
        let src = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "joseon.demo", qos: .userInteractive))
        src.schedule(deadline: .now(), repeating: .milliseconds(10))
        let block = Int(sampleRate / 100)
        let rate = sampleRate
        var position = 0   // timer queue only
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let samples = TestSignals.demoBlock(startSample: position, count: block, sampleRate: rate)
            position += block
            self.ringBuffer.write(left: samples.left, right: samples.right, count: block, sampleRate: rate)
        }
        timer = src
        src.resume()
    }

    public func stop() { timer?.cancel(); timer = nil; isRunning = false }
}
