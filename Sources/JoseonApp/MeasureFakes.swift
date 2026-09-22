import Foundation
import JoseonCore
import JoseonCapture

// FAKE seams for the measurement window. Offline self-check (JOSEON_MEASURE_SELFCHECK) and snapshot mode
// (JOSEON_SNAPSHOT_DIR) ONLY: `MeasureWindowController` builds them only when `TonePlayPermit.processIsOffline`.
// Nothing here opens a device, plays a sound, asks for a permission or touches AVFoundation or Core Audio.
// A "played" sweep is rendered into memory; a "recording" is that sweep through a simulated headphone:
//
//     played samples → headphone filters → gain → delay → clamp to ±1 (the converter) → + noise
//
// It mirrors the simulator of the math module's tests (`Tests/JoseonHeadphonesTests/MeasurementTestSupport.swift`):
// the same three filters, the same 3 733-sample delay, a closed-form truth to compare with.

/// One RBJ-cookbook biquad. `process` is the real filter; `responseDB` is its exact magnitude.
struct SimBiquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    static func highPass(hz: Double, q: Double, sampleRate: Double) -> SimBiquad {
        let w = 2 * Double.pi * hz / sampleRate, alpha = sin(w) / (2 * q), cosw = cos(w), a0 = 1 + alpha
        return SimBiquad(b0: (1 + cosw) / 2 / a0, b1: -(1 + cosw) / a0, b2: (1 + cosw) / 2 / a0, a1: -2 * cosw / a0, a2: (1 - alpha) / a0)
    }

    static func peaking(hz: Double, gainDB: Double, q: Double, sampleRate: Double) -> SimBiquad {
        let a = pow(10, gainDB / 40), w = 2 * Double.pi * hz / sampleRate, alpha = sin(w) / (2 * q), cosw = cos(w), a0 = 1 + alpha / a
        return SimBiquad(b0: (1 + alpha * a) / a0, b1: -2 * cosw / a0, b2: (1 - alpha * a) / a0, a1: -2 * cosw / a0, a2: (1 - alpha / a) / a0)
    }

    func responseDB(atHz hz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        let nRe = b0 + b1 * cos(w) + b2 * cos(2 * w), nIm = -(b1 * sin(w) + b2 * sin(2 * w))
        let dRe = 1 + a1 * cos(w) + a2 * cos(2 * w), dIm = -(a1 * sin(w) + a2 * sin(2 * w))
        let d = (dRe * dRe + dIm * dIm).squareRoot()
        return d > 0 ? 20 * log10((nRe * nRe + nIm * nIm).squareRoot() / d) : 0
    }
}

/// The simulated headphone: bass roll-off under 35 Hz, +6 dB at 3 kHz, −8 dB at 8 kHz. `tiltDB` moves the two
/// peaks a little, so a simulated "right side" differs from the "left side".
struct SimulatedHeadphone {
    var stages: [SimBiquad]
    var sampleRate: Double

    init(sampleRate: Double, variation: Double = 0, leakHz: Double = 35) {
        self.sampleRate = sampleRate
        stages = [
            .highPass(hz: leakHz, q: 0.707, sampleRate: sampleRate),
            .peaking(hz: 3_000, gainDB: 6 + variation, q: 2, sampleRate: sampleRate),
            .peaking(hz: 8_000, gainDB: -8 - variation, q: 3, sampleRate: sampleRate),
        ]
    }

    func process(_ x: [Float]) -> [Double] {
        var y = x.map(Double.init)
        for s in stages {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<y.count {
                let input = y[i]
                let output = s.b0 * input + s.b1 * x1 + s.b2 * x2 - s.a1 * y1 - s.a2 * y2
                x2 = x1; x1 = input; y2 = y1; y1 = output
                y[i] = output
            }
        }
        return y
    }

    func responseDB(atHz hz: Double) -> Double { stages.reduce(0) { $0 + $1.responseDB(atHz: hz, sampleRate: sampleRate) } }

    /// The truth, normalized the way the module normalizes: mean over 800–1250 Hz = 0 dB.
    func normalizedResponseDB(onGrid grid: [Double]) -> [Double] {
        let raw = grid.map(responseDB(atHz:))
        let inBand = zip(grid, raw).filter { $0.0 >= 800 && $0.0 <= 1250 }.map(\.1)
        let reference = inBand.isEmpty ? 0 : inBand.reduce(0, +) / Double(inBand.count)
        return raw.map { $0 - reference }
    }
}

/// What connects the fake player to the fake input, and the knobs the self-check turns.
final class FakeAcousticLink {
    enum Fault { case deviceRemoved, formatChanged, playerNeverFinishes, inputDeliversNothing, startFails }

    var sampleRate = 48_000.0
    /// Everything linear between the digital output and the digital input, in dB at 1 kHz.
    var gainDB = 3.0
    var delaySamples = 3_733
    var noiseDBFS = -78.0
    var headphoneVariation = 0.0
    /// Pictures only: each "seat" moves the two peaks by up to this many dB, so the agreement number is not zero.
    var seatJitterDB = 0.0
    /// Corner of the bass roll-off. 35 Hz = a good seal; pictures use a higher one, a leaky seal.
    var leakHz = 35.0
    /// Pictures only: low-frequency room rumble (white noise through a 25 Hz low-pass), RMS in dBFS. Nil = none.
    var rumbleDBFS: Double?
    var fault: Fault?
    var permission = MicrophonePermission.Status.authorized
    var deviceList: [MeasurementInputDevice] = FakeAcousticLink.snapshotDevices
    /// The "active level calibration" the fake environment reports. Nil = none.
    var fakePlayback: PlaybackCalibration?

    // Counters for the self-check.
    private(set) var permissionRequests = 0
    private(set) var playCount = 0
    private(set) var capturesOpened = 0
    private(set) var lastPlayedPeakDB = -Double.infinity

    fileprivate var played: [Float]?
    fileprivate weak var openCapture: FakeMeasureCapture?
    private var seed: UInt64 = 0x5EED

    var headphone: SimulatedHeadphone { SimulatedHeadphone(sampleRate: sampleRate, variation: headphoneVariation, leakHz: leakHz) }

    fileprivate func notePermissionRequest() { permissionRequests += 1 }
    fileprivate func noteCapture() { capturesOpened += 1 }
    fileprivate func notePlay(_ samples: [Float]) {
        playCount += 1
        played = samples
        lastPlayedPeakDB = MeasureSignal.peakDB(samples)
    }

    /// A fake recording: the played signal through the chain, or the room alone when nothing played.
    fileprivate func takeRecording(idleSeconds: Double) -> [Float] {
        let tail = Int(0.25 * sampleRate)
        var out: [Float]
        var rng = FakeRandom(seed: seed)
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        if let played {
            self.played = nil
            let seat = SimulatedHeadphone(sampleRate: sampleRate, variation: headphoneVariation + seatJitterDB * (2 * rng.unit() - 1), leakHz: leakHz)
            let y = seat.process(played)
            let gain = pow(10, gainDB / 20)
            out = [Float](repeating: 0, count: delaySamples + y.count + tail)
            for i in 0..<y.count { out[delaySamples + i] = Float(max(-1, min(1, y[i] * gain))) }
        } else {
            out = [Float](repeating: 0, count: Int(idleSeconds * sampleRate))
        }
        // White Gaussian room noise, seeded: every recording gets its own stretch of it.
        let rms = Float(pow(10, noiseDBFS / 20))
        if let rumbleDBFS {
            // One-pole low-pass at 25 Hz; its output RMS for unit white noise is sqrt(a / (2 − a)).
            let a = Float(1 - exp(-2 * Double.pi * 25 / sampleRate))
            let scale = Float(pow(10, rumbleDBFS / 20)) / (a / (2 - a)).squareRoot()
            var low: Float = 0
            for i in 0..<out.count {
                let white = rng.gaussian()
                low += a * (white - low)
                out[i] = max(-1, min(1, out[i] + rms * white + scale * low))
            }
        } else {
            for i in 0..<out.count { out[i] = max(-1, min(1, out[i] + rms * rng.gaussian())) }
        }
        return out
    }

    /// Labelled FAKE devices for the pictures. Not a list of anybody's hardware.
    static let snapshotDevices: [MeasurementInputDevice] = [
        MeasurementInputDevice(uid: "fake-usb-mic", name: "SNAPSHOT USB measurement mic (fake)", channelCount: 1, nominalSampleRate: 48_000,
                               availableSampleRates: [44_100, 48_000], transport: .usb, isDefaultInput: false),
        MeasurementInputDevice(uid: "fake-interface", name: "SNAPSHOT audio interface (fake)", channelCount: 2, nominalSampleRate: 96_000,
                               availableSampleRates: [44_100, 48_000, 96_000], transport: .usb, isDefaultInput: false),
        MeasurementInputDevice(uid: "fake-builtin", name: "SNAPSHOT built-in microphone (fake)", channelCount: 1, nominalSampleRate: 48_000,
                               availableSampleRates: [48_000], transport: .builtIn, isDefaultInput: true),
        MeasurementInputDevice(uid: "fake-virtual", name: "SNAPSHOT loopback device (fake)", channelCount: 2, nominalSampleRate: 48_000,
                               availableSampleRates: [48_000], transport: .virtual, isDefaultInput: false),
    ]
}

private struct FakeRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    mutating func gaussian() -> Float {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return Float((-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2))
    }
}

final class FakeMeasureInput: MeasureInputProviding {
    let link: FakeAcousticLink
    init(link: FakeAcousticLink) { self.link = link }

    func devices() -> [MeasurementInputDevice] { link.deviceList }
    var permission: MicrophonePermission.Status { link.permission }

    /// No prompt, no AVFoundation: the fake only counts the call and grants.
    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        link.notePermissionRequest()
        link.permission = .authorized
        DispatchQueue.main.async { completion(true) }
    }

    func openSystemSettings() {}

    func makeCapture(deviceUID: String, channel: Int, maxSeconds: Double) -> MeasureCapturing {
        FakeMeasureCapture(link: link, maxSeconds: maxSeconds)
    }
}

final class FakeMeasureCapture: MeasureCapturing {
    private let link: FakeAcousticLink
    private let maxSeconds: Double
    private var started = false
    private var stopped = false
    var onStop: ((MeasurementInputSession.StopReason) -> Void)?

    init(link: FakeAcousticLink, maxSeconds: Double) { self.link = link; self.maxSeconds = maxSeconds }

    func start() throws {
        if link.permission != .authorized { throw MeasurementInputError.permissionNotGranted(link.permission) }
        if link.fault == .startFails { throw MeasurementInputError.deviceNotAlive(uid: "fake") }
        link.noteCapture()
        link.openCapture = self
        started = true
    }

    func stop() -> MeasureRecording {
        guard started, !stopped else { return MeasureRecording(samples: [], sampleRate: 0, clipped: false, overflowed: false) }
        stopped = true
        let samples = link.takeRecording(idleSeconds: maxSeconds)
        return MeasureRecording(samples: samples, sampleRate: link.sampleRate, clipped: samples.contains { abs($0) >= 0.999 }, overflowed: false)
    }

    var sampleRate: Double { started ? link.sampleRate : 0 }
    /// A fake second has no length: everything "arrived" as soon as the capture is open.
    var framesRecorded: Int { started && !stopped && link.fault != .inputDeliversNothing ? Int(maxSeconds * link.sampleRate) : 0 }
    var peakDB: Double { -.infinity }
    var rmsDB: Double { -.infinity }
    var clipped: Bool { false }

    fileprivate func fail(_ reason: MeasurementInputSession.StopReason) {
        DispatchQueue.main.async { [weak self] in self?.onStop?(reason) }
    }
}

/// Renders the buffer with the REAL `BufferGenerator` (fade-in, hard limit) into memory. It makes no sound.
final class FakeSignalPlayer: SignalPlaying {
    let link: FakeAcousticLink
    private var onEnd: ((SignalPlayEnd) -> Void)?
    private(set) var stopReasons: [String] = []

    init(link: FakeAcousticLink) { self.link = link }

    var outputSampleRate: Double { link.sampleRate }
    var isPlaying: Bool { onEnd != nil }

    func play(_ samples: [Float], permit: TonePlayPermit, onEnd: @escaping (SignalPlayEnd) -> Void) -> String? {
        // The same checks as the real player, except "this process is offline": here that is the point.
        if !permit.isFresh(within: SignalPlayer.maxPermitAgeSeconds) { return "The button press is too old. Press the button again." }
        if let refusal = SignalPlayer.refusal(samples: samples, sampleRate: link.sampleRate) { return refusal }
        link.notePlay(BufferGenerator.renderAll(samples, sampleRate: link.sampleRate))
        self.onEnd = onEnd
        switch link.fault {
        case .deviceRemoved: link.openCapture?.fail(.deviceRemoved)
        case .formatChanged: link.openCapture?.fail(.formatChanged)
        case .playerNeverFinishes: break
        default:
            DispatchQueue.main.async { [weak self] in
                guard let self, let end = self.onEnd else { return }
                self.onEnd = nil
                end(.completed)
            }
        }
        return nil
    }

    func stop(reason: String) {
        guard let end = onEnd else { return }
        onEnd = nil
        stopReasons.append(reason)
        DispatchQueue.main.async { end(.stopped(reason)) }
    }
}
