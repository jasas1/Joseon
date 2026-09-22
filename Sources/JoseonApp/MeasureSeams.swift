import Foundation
import JoseonCapture
import JoseonHeadphones

// The seams of the measurement window. The controller talks to these protocols only, so the offline self-check
// and snapshot mode can drive the WHOLE controller with a fake input and a fake player (`MeasureFakes.swift`).
// The live types below are thin wrappers over `JoseonCapture`.

/// What one capture gave back.
struct MeasureRecording {
    var samples: [Float]
    var sampleRate: Double
    /// The input reported a sample at or over ±0.999.
    var clipped: Bool
    /// The recorder was full before the capture ended (the recording is the first part, without a gap).
    var overflowed: Bool
}

/// One open input channel that records into memory. Nothing here writes to disk.
protocol MeasureCapturing: AnyObject {
    /// Opens the input and starts to record. Synchronous; call it OFF the main thread. Throws `MeasurementInputError`.
    func start() throws
    /// Stops and hands the recording out. Safe to call when `start` failed or the capture stopped by itself.
    func stop() -> MeasureRecording
    /// 0 before the first IO cycle.
    var sampleRate: Double { get }
    var framesRecorded: Int { get }
    /// Level of the last 100 ms in dBFS. −infinity while stopped.
    var peakDB: Double { get }
    var rmsDB: Double { get }
    var clipped: Bool { get }
    /// Main queue. The capture stopped by itself: the device went away or its format changed.
    var onStop: ((MeasurementInputSession.StopReason) -> Void)? { get set }
}

protocol MeasureInputProviding: AnyObject {
    func devices() -> [MeasurementInputDevice]
    var permission: MicrophonePermission.Status { get }
    /// SHOWS THE macOS PROMPT when the status is `notDetermined`. The controller calls it from one place only:
    /// `MeasureController.requestPermissionFromButton`, which is the action of the "Allow microphone…" button.
    func requestPermission(_ completion: @escaping (Bool) -> Void)
    func openSystemSettings()
    func makeCapture(deviceUID: String, channel: Int, maxSeconds: Double) -> MeasureCapturing
}

// MARK: - Live

final class LiveMeasureInput: MeasureInputProviding {
    func devices() -> [MeasurementInputDevice] { MeasurementInput.devices() }
    var permission: MicrophonePermission.Status { MicrophonePermission.status }
    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        // Snapshot mode and the self-checks use the fake input. Should the live one ever be built there: no prompt.
        guard !TonePlayPermit.processIsOffline else { completion(false); return }
        MicrophonePermission.request(completion)
    }
    func openSystemSettings() { MicrophonePermission.openSystemSettings() }

    func makeCapture(deviceUID: String, channel: Int, maxSeconds: Double) -> MeasureCapturing {
        let rates = devices().first { $0.uid == deviceUID }.map { $0.availableSampleRates + [$0.nominalSampleRate] } ?? []
        // Room for the highest rate the device offers (capped at 192 kHz: 12 s are then 9 MB).
        let rate = min(192_000, max(48_000, rates.max() ?? 48_000))
        return LiveMeasureCapture(deviceUID: deviceUID, channel: channel, capacityFrames: Int(maxSeconds * rate))
    }
}

final class LiveMeasureCapture: MeasureCapturing {
    private let session: MeasurementInputSession
    private let recorder: MeasurementRecorder

    init(deviceUID: String, channel: Int, capacityFrames: Int) {
        // `preferredSampleRate: nil`: Joseon never changes the sample rate of the device (a system-wide setting).
        session = MeasurementInputSession(deviceUID: deviceUID, channel: channel, preferredSampleRate: nil)
        recorder = MeasurementRecorder(capacityFrames: capacityFrames)
    }

    var onStop: ((MeasurementInputSession.StopReason) -> Void)? {
        get { session.onStop }
        set { session.onStop = newValue }
    }

    func start() throws {
        recorder.reset()
        // Throws `permissionNotGranted` without the permission. It never shows the prompt.
        try session.start(handler: recorder.handler)
    }

    func stop() -> MeasureRecording {
        session.stop()
        return MeasureRecording(samples: recorder.recording(), sampleRate: recorder.sampleRate,
                                clipped: session.clippedSinceStart, overflowed: recorder.overflowed)
    }

    var sampleRate: Double { session.sampleRate }
    var framesRecorded: Int { recorder.frameCount }
    var peakDB: Double { session.peakDB }
    var rmsDB: Double { session.rmsDB }
    var clipped: Bool { session.clippedSinceStart }
}

// MARK: - The signal

/// The measurement stimulus, stated once so the played buffer and the analysis reference are the same signal.
enum MeasureSignal {
    static let sweepSeconds: Double = 5
    /// The sweep's own raised-cosine fade-in. It starts at 20 Hz, so 0.1 s is two cycles: no click. The analysis
    /// divides by the spectrum of these exact samples, fade included, so the fade does not bias the curve.
    static let fadeInSeconds: Double = 0.1
    static let fadeOutSeconds: Double = 0.02
    /// Play level steps, dBFS peak. The first run is forced to the first entry; the user goes up one step at a time.
    static let levelSteps: [Double] = [-30, -24, -18, -12, -6]
    /// Target zone for the input peak during the level check.
    static let inputTargetDBFS: ClosedRange<Double> = -18 ... -6
    /// Under this input peak nothing useful arrived: wrong channel, mic unplugged, gain at zero.
    static let inputFloorDBFS: Double = -50
    /// Every run is cut (or zero-padded) to the sweep plus this, so all runs share one analysis length.
    static let runPaddingSeconds: Double = 1.5

    /// The same continuous sweep at any sample rate. The output device and the input device may run at different
    /// rates: the player gets the sweep at the OUTPUT rate, the analysis gets it at the INPUT rate.
    static func sweep(sampleRate: Double, levelDBFS: Double, seconds: Double = sweepSeconds) -> SweepSignal {
        SweepSignal.exponentialSweep(sampleRate: sampleRate, seconds: seconds, levelDBFS: levelDBFS,
                                     fadeInSeconds: fadeInSeconds, fadeOutSeconds: fadeOutSeconds)
    }

    static func runFrames(sweepFrames: Int, sampleRate: Double) -> Int { sweepFrames + Int(runPaddingSeconds * sampleRate) }

    /// Cut or zero-pad to `frames`, as Double for the math module.
    static func fitted(_ samples: [Float], frames: Int) -> [Double] {
        var out = [Double](repeating: 0, count: frames)
        for i in 0..<min(frames, samples.count) { out[i] = Double(samples[i]) }
        return out
    }

    static func peakDB(_ samples: [Float]) -> Double {
        var p: Float = 0
        for x in samples { p = max(p, abs(x)) }
        return p > 0 ? 20 * log10(Double(p)) : -.infinity
    }

    static func rmsDB(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return -.infinity }
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        let mean = sum / Double(samples.count)
        return mean > 0 ? 10 * log10(mean) : -.infinity
    }
}
