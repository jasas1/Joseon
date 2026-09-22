import Foundation

// MARK: - Joseon contracts (L0)
//
// Every module talks through the types in this file. The file is frozen for
// module workers: change it only in an integration round.
//
// Data flow:
//   AudioSource (JoseonCapture) -> StereoRingBuffer -> AnalysisEngine (JoseonCore)
//   -> AnalysisFrame -> renderers (JoseonRender) + app shell (JoseonApp)
//   HeadphoneModel (JoseonHeadphones) adds the predicted at-ear curve to a frame.

/// Facts about the stream that the capture layer sees.
public struct StreamInfo: Equatable, Sendable {
    public var sampleRate: Double
    public var channelCount: Int
    /// Output device name, for example "Woo Audio WA33" or "MacBook Pro Speakers".
    public var deviceName: String
    /// Device nominal bit depth when Core Audio reports it.
    public var bitDepth: Int?
    /// Names of the processes that make sound now, for example ["Qobuz"].
    public var activeSources: [String]

    public init(sampleRate: Double, channelCount: Int, deviceName: String, bitDepth: Int? = nil, activeSources: [String] = []) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.deviceName = deviceName
        self.bitDepth = bitDepth
        self.activeSources = activeSources
    }
}

/// What the source app plays now, read from its own player UI (Qobuz first). Text only; never audio.
public struct NowPlaying: Equatable, Sendable {
    public var title: String
    public var artist: String
    /// Empty when the player shows none.
    public var album: String
    /// The app it was read from, for example "Qobuz".
    public var source: String
    /// The player marks the stream as hi-res.
    public var isHiRes: Bool

    public init(title: String, artist: String, album: String = "", source: String, isHiRes: Bool = false) {
        self.title = title
        self.artist = artist
        self.album = album
        self.source = source
        self.isHiRes = isHiRes
    }

    /// "Artist – Title", or just the one that is known.
    public var line: String {
        [artist, title].filter { !$0.isEmpty }.joined(separator: " \u{2013} ")
    }
}

/// A reader of `NowPlaying`. JoseonCapture implements it with the Accessibility API; tests use a fake.
public protocol NowPlayingSource: AnyObject {
    /// Nil when nothing is known (no player, no permission, no track).
    var current: NowPlaying? { get }
    /// Called on the main queue whenever `current` changes, including to nil.
    var onChange: ((NowPlaying?) -> Void)? { get set }
    /// Starts polling. Cheap when the player is absent.
    func start()
    func stop()
}

/// A source of stereo float audio. JoseonCapture implements this with a process tap.
/// Tests and the probe implement it with synthetic signals.
public protocol AudioSource: AnyObject {
    /// Nil until the source runs.
    var streamInfo: StreamInfo? { get }
    /// The source writes every captured buffer here. Real-time safe.
    var ringBuffer: StereoRingBuffer { get }
    /// Called on the main queue when streamInfo changes (device switch, rate change).
    var onStreamInfoChange: ((StreamInfo) -> Void)? { get set }
    /// Synchronous start. May block for a long time: `SystemAudioTap.start()` blocks about 90 s while
    /// the macOS "System Audio Recording" prompt waits for an answer. Never call it on the main thread
    /// in an app. Use `startAsync`.
    func start() throws
    /// Non-blocking start. `completion` runs on the main queue, with nil on success.
    /// The default implementation calls `start()` on a background queue.
    func startAsync(completion: @escaping (Error?) -> Void)
    /// May block like `start()` (a tap that waits on the permission prompt). Call it off the main thread in an app.
    func stop()
    var isRunning: Bool { get }
}

public extension AudioSource {
    func startAsync(completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try self.start() } catch { failure = error }
            DispatchQueue.main.async { completion(failure) }
        }
    }
}

// MARK: - Analysis output

/// Log-spaced display spectrum. All arrays have the same count as `frequencies`.
public struct SpectrumReading: Sendable {
    /// Center frequency of each display bin in Hz, log spaced, low to high.
    public var frequencies: [Float]
    /// Level in dBFS per display bin. Floor is `SpectrumReading.floorDB`.
    public var left: [Float]
    public var right: [Float]
    /// Mid = (L+R)/2.
    public var mid: [Float]
    /// Side = (L-R)/2.
    public var side: [Float]
    /// Slow-decay peak hold of `mid`.
    public var peakHold: [Float]
    /// Long-term average of `mid` since the last reset (track tonal balance).
    public var average: [Float]

    /// Optional: the mid curve per FFT resolution, before the analyzer blends them. The live spectrum uses the
    /// blended `mid` (lowest latency). The spectrogram uses the layers so it can delay each one to a common
    /// time and blend after that (no bent transients inside the crossfade zones). Empty = not provided.
    public var midLayers: [SpectrumLayer] = []

    public static let floorDB: Float = -120

    public init(frequencies: [Float], left: [Float], right: [Float], mid: [Float], side: [Float], peakHold: [Float], average: [Float]) {
        self.frequencies = frequencies
        self.left = left
        self.right = right
        self.mid = mid
        self.side = side
        self.peakHold = peakHold
        self.average = average
    }

    public static func silent(binCount: Int, minHz: Float = 10, maxHz: Float = 24_000) -> SpectrumReading {
        let n = max(binCount, 2)
        let ratio = maxHz / minHz
        let freqs = (0..<n).map { minHz * pow(ratio, Float($0) / Float(n - 1)) }
        let floor = [Float](repeating: floorDB, count: n)
        return SpectrumReading(frequencies: freqs, left: floor, right: floor, mid: floor, side: floor, peakHold: floor, average: floor)
    }
}

/// One FFT resolution of the mid channel on the display bins. See `SpectrumReading.midLayers`.
public struct SpectrumLayer: Sendable {
    /// Level in dBFS per display bin, same calibration and smoothing as `SpectrumReading.mid`.
    public var levelsDB: [Float]
    /// Blend weight per display bin, 0...1. Over all layers the weights sum to 1 in every bin.
    /// The analyzer blends in the power domain with these weights.
    public var weights: [Float]
    /// Time from an event in the audio to the center of this layer's analysis window, in seconds
    /// (half the window length). The longest layer has the largest value.
    public var latencySeconds: Float

    public init(levelsDB: [Float], weights: [Float], latencySeconds: Float) {
        self.levelsDB = levelsDB; self.weights = weights; self.latencySeconds = latencySeconds
    }
}

/// The strongest spectral peak, with musical note.
public struct PeakReading: Equatable, Sendable {
    public var frequencyHz: Float
    public var levelDB: Float
    /// For example "G#4". Empty when there is no clear peak.
    public var noteName: String
    /// Offset from the equal-tempered note, -50...+50.
    public var cents: Float

    public init(frequencyHz: Float = 0, levelDB: Float = SpectrumReading.floorDB, noteName: String = "", cents: Float = 0) {
        self.frequencyHz = frequencyHz
        self.levelDB = levelDB
        self.noteName = noteName
        self.cents = cents
    }
}

/// Energy per listening band in dBFS (RMS of the band).
///
/// Measured on the mid channel, (L+R)/2, so the numbers agree with `SpectrumReading.mid`:
/// a full-scale mono sine inside a band reads 0 dB. Content that is only in the side channel
/// (out of phase between left and right) does not show here.
public struct BandEnergy: Equatable, Sendable {
    public var subBass: Float   // 20–60 Hz
    public var bass: Float      // 60–250 Hz
    public var lowMid: Float    // 250–500 Hz
    public var mid: Float       // 500–2k Hz
    public var upperMid: Float  // 2k–4k Hz
    public var presence: Float  // 4k–6k Hz
    public var brilliance: Float // 6k–12k Hz
    public var air: Float       // 12k–20k+ Hz

    public init(subBass: Float = -120, bass: Float = -120, lowMid: Float = -120, mid: Float = -120, upperMid: Float = -120, presence: Float = -120, brilliance: Float = -120, air: Float = -120) {
        self.subBass = subBass; self.bass = bass; self.lowMid = lowMid; self.mid = mid
        self.upperMid = upperMid; self.presence = presence; self.brilliance = brilliance; self.air = air
    }

    public static let names = ["Sub", "Bass", "Low mid", "Mid", "Upper mid", "Presence", "Brilliance", "Air"]
    public static let edgesHz: [Float] = [20, 60, 250, 500, 2_000, 4_000, 6_000, 12_000, 24_000]
    public var values: [Float] { [subBass, bass, lowMid, mid, upperMid, presence, brilliance, air] }
}

/// ITU-R BS.1770-4 / EBU R128 loudness plus peak and dynamics numbers.
public struct LoudnessReading: Equatable, Sendable {
    public var momentaryLUFS: Float      // 400 ms
    public var shortTermLUFS: Float      // 3 s
    public var integratedLUFS: Float     // gated, since reset
    public var momentaryMaxLUFS: Float
    public var shortTermMaxLUFS: Float
    public var loudnessRangeLU: Float    // EBU Tech 3342
    /// Inter-sample true peak per channel: 4x oversampled up to 96 kHz, 2x from 176.4 kHz, 1x from 352.8 kHz.
    /// This is a display value with meter ballistics: instant attack, about 1.5 s hold, then a fall of
    /// about 20 dB per second. It is not the peak of the last block. Use `truePeakMaxDBTP` for the measurement.
    public var truePeakLeftDBTP: Float
    public var truePeakRightDBTP: Float
    /// Highest true peak of both channels since reset. No ballistics.
    public var truePeakMaxDBTP: Float
    public var rmsLeftDB: Float          // 300 ms window
    public var rmsRightDB: Float
    /// Peak-to-loudness ratio: truePeakMax - integrated. A per-track dynamics number.
    /// 0 until `isIntegratedValid`.
    public var plrDB: Float
    /// Peak-to-short-term loudness ratio, live dynamics.
    public var psrDB: Float
    /// Count of clip events since reset, both channels together. One event = a run of 3 or more
    /// consecutive samples in one channel with |x| >= 0.9999 (full scale within 0.001 dB; a 16-bit
    /// full-scale sample is 0.99997). A longer run still counts as one event. Sample values, not true peak.
    public var clipCount: Int
    /// Seconds of audio measured since reset.
    public var measuredSeconds: Double
    /// True when at least one 400 ms block has passed the BS.1770 gates since reset, so `integratedLUFS`
    /// is a measurement. While false, `integratedLUFS` is `silenceLUFS`, and `loudnessRangeLU` and `plrDB`
    /// are 0: consumers show "—" for I, LRA and PLR.
    public var isIntegratedValid: Bool

    public static let silenceLUFS: Float = -120

    public init() {
        momentaryLUFS = Self.silenceLUFS; shortTermLUFS = Self.silenceLUFS; integratedLUFS = Self.silenceLUFS
        momentaryMaxLUFS = Self.silenceLUFS; shortTermMaxLUFS = Self.silenceLUFS; loudnessRangeLU = 0
        truePeakLeftDBTP = -120; truePeakRightDBTP = -120; truePeakMaxDBTP = -120
        rmsLeftDB = -120; rmsRightDB = -120; plrDB = 0; psrDB = 0; clipCount = 0; measuredSeconds = 0
        isIntegratedValid = false
    }
}

/// Stereo field numbers and the vectorscope point cloud.
public struct StereoReading: Sendable {
    /// Phase correlation, -1 (out of phase) ... +1 (mono).
    public var correlation: Float
    /// Balance, -1 (all left) ... +1 (all right), from RMS.
    public var balance: Float
    /// Side RMS / mid RMS: 0 mono, 1 hard-panned, max 4.
    public var width: Float
    /// Correlation per band, same band order as BandEnergy. 0 where `bandActive` is false.
    public var bandCorrelation: [Float]
    /// Balance per band, same band order as BandEnergy. 0 where `bandActive` is false.
    public var bandBalance: [Float]
    /// Per band: false = gated empty band (under -100 dBFS, or more than 80 dB under the broadband level).
    /// Its correlation and balance are neutral zeros, not measurements: consumers grey the band out.
    public var bandActive: [Bool]
    /// Vectorscope points, newest last, each in -1...1: x = (R - L) / 2 (positive = right),
    /// y = (L + R) / 2 (mid), so |x| + |y| = max(|L|, |R|): full scale is the diamond with tips at ±1. The points are evenly decimated samples of the last 50 ms, at most
    /// `StereoAnalyzing.scopePointCount` of them: above 40 kHz x 0.05 s / count they are NOT consecutive
    /// samples. A renderer may join neighbours that are close, but a line between two far points is a
    /// chord across the figure, not the path of the signal: draw far points as dots.
    public var scopePoints: [SIMD2<Float>]

    public init(correlation: Float = 0, balance: Float = 0, width: Float = 0, bandCorrelation: [Float] = [Float](repeating: 0, count: 8), bandBalance: [Float] = [Float](repeating: 0, count: 8), bandActive: [Bool] = [Bool](repeating: false, count: 8), scopePoints: [SIMD2<Float>] = []) {
        self.correlation = correlation
        self.balance = balance
        self.width = width
        self.bandCorrelation = bandCorrelation
        self.bandBalance = bandBalance
        self.bandActive = bandActive
        self.scopePoints = scopePoints
    }
}

/// Predicted at-ear result from a headphone model. Nil arrays mean "no model loaded".
public struct HeadphoneReading: Sendable {
    public var modelName: String
    /// Headphone magnitude response in dB on the frame's display bins, normalized to 0 dB at 1 kHz.
    public var responseDB: [Float]
    /// Target curve (for example Harman over-ear 2018) on the same bins, normalized to 0 dB at 1 kHz.
    /// All zeros when `hasTarget` is false.
    public var targetDB: [Float]
    /// False when the model has no target curve: `targetDB` is then a placeholder, and consumers
    /// hide the target line and its legend entry.
    public var hasTarget: Bool
    /// Source mid spectrum + responseDB: what the headphone is predicted to deliver at the ear.
    public var predictedAtEarDB: [Float]
    /// Flags that the user can read, for example "Sub-bass load high: -9 dBFS below 40 Hz".
    public var stressFlags: [StressFlag]

    public init(modelName: String, responseDB: [Float], targetDB: [Float], hasTarget: Bool = true, predictedAtEarDB: [Float], stressFlags: [StressFlag]) {
        self.modelName = modelName
        self.responseDB = responseDB
        self.targetDB = targetDB
        self.hasTarget = hasTarget
        self.predictedAtEarDB = predictedAtEarDB
        self.stressFlags = stressFlags
    }
}

public struct StressFlag: Equatable, Sendable, Identifiable {
    public enum Severity: Int, Sendable { case info = 0, watch = 1, high = 2 }
    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String
    /// The frequency span the flag is about, when it has one (for example 20...40 for sub-bass
    /// under-delivery). Panels shade this span on the spectrum. Nil for whole-signal flags (overs, dense master).
    public var frequencyRangeHz: ClosedRange<Float>?
    /// Short number for the plot label, for example "−7 dB vs target". Empty when there is none.
    public var plotLabel: String

    public init(id: String, severity: Severity, title: String, detail: String, frequencyRangeHz: ClosedRange<Float>? = nil, plotLabel: String = "") {
        self.id = id; self.severity = severity; self.title = title; self.detail = detail
        self.frequencyRangeHz = frequencyRangeHz; self.plotLabel = plotLabel
    }
}

/// One analysis result. The engine makes about 60 of these per second.
public struct AnalysisFrame: Sendable {
    public var hostTime: TimeInterval
    public var stream: StreamInfo?
    public var spectrum: SpectrumReading
    public var peak: PeakReading
    public var bands: BandEnergy
    public var loudness: LoudnessReading
    public var stereo: StereoReading
    public var headphone: HeadphoneReading?
    /// True when the input was digital silence for the whole frame.
    public var isSilent: Bool
    /// The strongest tonal peaks of mid, strongest first, at most 5. `peak` is the first of them
    /// when the analyzer provides the list. Empty when the analyzer does not (see `TopPeaksProviding`).
    public var topPeaks: [PeakReading] = []
    /// Lowest frequency with strong sustained content (within 30 dB of the long-term average maximum), in Hz. 0 = unknown.
    public var lowestStrongHz: Float = 0
    /// Third-octave band levels per channel. Nil when the spectrum analyzer does not provide them.
    public var thirdOctave: ThirdOctaveReading?
    /// Estimated sound level at the ear. Nil when there is no SPL estimator (no calibration or no headphone sensitivity).
    public var spl: SPLReading?

    public init(hostTime: TimeInterval = 0, stream: StreamInfo? = nil, spectrum: SpectrumReading, peak: PeakReading = PeakReading(), bands: BandEnergy = BandEnergy(), loudness: LoudnessReading = LoudnessReading(), stereo: StereoReading = StereoReading(), headphone: HeadphoneReading? = nil, isSilent: Bool = true) {
        self.hostTime = hostTime
        self.stream = stream
        self.spectrum = spectrum
        self.peak = peak
        self.bands = bands
        self.loudness = loudness
        self.stereo = stereo
        self.headphone = headphone
        self.isSilent = isSilent
    }
}

// MARK: - Analyzer contracts
//
// Each analyzer takes deinterleaved stereo float blocks at `sampleRate`.
// `process` is called from one analysis thread. `reset` starts a new measurement.

public struct SpectrumSettings: Equatable, Sendable {
    /// Number of log-spaced display bins.
    public var displayBins: Int = 1024
    public var minHz: Float = 10
    public var maxHz: Float = 24_000
    /// Release time of the display smoothing in seconds (attack is instant).
    public var releaseSeconds: Float = 0.25
    /// Peak-hold decay in dB per second.
    public var peakDecayDBPerSecond: Float = 12
    /// Spectral slope for display in dB per octave (4.5 makes pink-ish music look flat). 0 = raw.
    public var tiltDBPerOctave: Float = 0
    public init() {}
}

public protocol SpectrumAnalyzing: AnyObject {
    var settings: SpectrumSettings { get set }
    /// Feed new samples. The analyzer keeps its own history for long FFT windows.
    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, sampleRate: Double)
    /// Current display spectrum, peak and bands.
    func read() -> (spectrum: SpectrumReading, peak: PeakReading, bands: BandEnergy)
    func reset()
}

public protocol LoudnessMetering: AnyObject {
    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, sampleRate: Double)
    func read() -> LoudnessReading
    func reset()
}

public protocol StereoAnalyzing: AnyObject {
    /// Max points in `scopePoints`.
    var scopePointCount: Int { get set }
    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int, sampleRate: Double)
    func read() -> StereoReading
    func reset()
}

/// JoseonHeadphones implements this. The engine calls it once per frame.
public protocol HeadphoneModeling: AnyObject {
    var modelName: String { get }
    func evaluate(spectrum: SpectrumReading, bands: BandEnergy, loudness: LoudnessReading) -> HeadphoneReading
    /// New measurement: drop state that spans frames (flag hysteresis). The engine calls it on the
    /// analysis thread when the measurement resets. Default: nothing.
    func reset()
}

public extension HeadphoneModeling {
    func reset() {}
}

/// Optional analyzer extra. `AnalysisEngine` copies these into each frame when the spectrum analyzer conforms.
public protocol TopPeaksProviding: AnyObject {
    /// Strongest tonal peaks of mid, strongest first, at most 5. Same gate as `PeakReading` (above −80 dBFS, 10 dB over the local median).
    var topPeaks: [PeakReading] { get }
    /// Lowest frequency with strong sustained content, in Hz. 0 = unknown.
    var lowestStrongHz: Float { get }
}

// MARK: - Sound level at the ear (SPL estimate)
//
// Chain: ThirdOctaveReading (signal, dBFS RMS per band and channel, from the spectrum analyzer)
//   + PlaybackCalibration (volts at the headphone for a full-scale sine)
//   + HeadphoneSensitivity (dB SPL per volt at 1 kHz) + the measured headphone response
//   -> SPL at the eardrum per band -> diffuse-field equivalent -> A-weighted level, Leq, dose.
// Joseon can not know the amplifier gain, so every SPL number is an estimate that depends on the calibration.

/// RMS level per third-octave band (IEC 61260 nominal centers, 20 Hz ... 20 kHz, 31 bands), in dBFS RMS
/// where a full-scale SINE reads -3.01 dBFS. Integration time about 125 ms ("fast"). Floor -140.
public struct ThirdOctaveReading: Sendable {
    public var centersHz: [Float]
    public var left: [Float]
    public var right: [Float]

    public static let nominalCentersHz: [Float] = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
        1_000, 1_250, 1_600, 2_000, 2_500, 3_150, 4_000, 5_000, 6_300, 8_000, 10_000, 12_500, 16_000, 20_000]
    public static let floorDB: Float = -140

    public init(centersHz: [Float] = ThirdOctaveReading.nominalCentersHz, left: [Float], right: [Float]) {
        self.centersHz = centersHz; self.left = left; self.right = right
    }
}

/// Optional analyzer extra. `AnalysisEngine` copies it into each frame when the spectrum analyzer conforms.
public protocol ThirdOctaveProviding: AnyObject {
    var thirdOctave: ThirdOctaveReading? { get }
}

/// How loud the chain plays: the voltage at the headphone terminals for a full-scale (0 dBFS peak) sine.
public struct PlaybackCalibration: Equatable, Sendable, Codable {
    public enum Method: String, Sendable, Codable {
        case measuredVoltage   // the user measured a test tone with a meter
        case enteredSpecs      // from DAC / amplifier data
        case systemVolume      // macOS controls the volume of a known output (for example the Mac headphone jack)
    }
    /// For example "WA33 at 10 o'clock".
    public var name: String
    public var method: Method
    /// RMS volts at the headphone for a 0 dBFS sine. With `.systemVolume` this is the value at the current volume setting.
    public var fullScaleVrms: Double
    /// Estimated uncertainty of the final SPL in dB (one side), shown to the user. About 2 for a measured voltage, 4 or more for specs.
    public var uncertaintyDB: Double

    public init(name: String, method: Method, fullScaleVrms: Double, uncertaintyDB: Double) {
        self.name = name; self.method = method; self.fullScaleVrms = fullScaleVrms; self.uncertaintyDB = uncertaintyDB
    }
}

/// Headphone sensitivity at 1 kHz.
public struct HeadphoneSensitivity: Equatable, Sendable, Codable {
    /// dB SPL at the eardrum simulator for 1 V RMS at 1 kHz.
    public var dbSPLPerVolt: Double
    public var impedanceOhms: Double
    /// Where the numbers come from, for example "HiFiMAN product page, 86 dB/mW, 45 Ω". "User" when typed in.
    public var source: String

    public init(dbSPLPerVolt: Double, impedanceOhms: Double, source: String) {
        self.dbSPLPerVolt = dbSPLPerVolt; self.impedanceOhms = impedanceOhms; self.source = source
    }

    /// dB/mW -> dB/V: add 10·log10(1000 / Z).
    public static func fromDBPerMilliwatt(_ dbPerMW: Double, impedanceOhms z: Double, source: String) -> HeadphoneSensitivity {
        HeadphoneSensitivity(dbSPLPerVolt: dbPerMW + 10 * log10(1000 / z), impedanceOhms: z, source: source)
    }
}

/// Estimated level at the ear. All levels are dB SPL re 20 µPa. "DF" = diffuse-field equivalent (ISO 11904 idea:
/// eardrum level minus the diffuse-field ear response), the level that noise-dose limits refer to.
public struct SPLReading: Sendable {
    /// For example "WA33 at 10 o'clock".
    public var calibrationName: String
    public var uncertaintyDB: Float
    /// A-weighted, DF equivalent, fast (125 ms), louder ear.
    public var levelAFast: Float
    /// A-weighted, DF equivalent, slow (1 s), louder ear.
    public var levelASlow: Float
    /// Unweighted (Z) level at the eardrum, slow, louder ear.
    public var levelZEardrum: Float
    /// A-weighted equivalent continuous level since the measurement reset (track), and since the dose reset (session / day).
    public var leqATrack: Float
    public var leqASession: Float
    /// Highest `levelAFast` since the measurement reset.
    public var maxAFast: Float
    /// Level per third-octave band at the eardrum (unweighted, louder ear), same centers as ThirdOctaveReading.
    public var bandLevelsEardrum: [Float]
    /// Noise dose since the dose reset, 1.0 = 100%. NIOSH: 85 dBA for 8 h, 3 dB exchange rate.
    public var doseNIOSH: Float
    /// WHO / ITU H.870 weekly allowance for adults: 80 dBA for 40 h, 3 dB exchange rate. 1.0 = the whole week used.
    public var doseWHOWeekly: Float
    /// Seconds of listening counted in the dose (time with signal).
    public var doseSeconds: Double
    /// At the current `levelASlow`, the time until `doseNIOSH` reaches 1.0, in seconds. Infinite when the level is low.
    public var secondsToNIOSHLimit: Double

    public static let floorDB: Float = 0

    public init(calibrationName: String, uncertaintyDB: Float, levelAFast: Float, levelASlow: Float, levelZEardrum: Float, leqATrack: Float, leqASession: Float, maxAFast: Float, bandLevelsEardrum: [Float], doseNIOSH: Float, doseWHOWeekly: Float, doseSeconds: Double, secondsToNIOSHLimit: Double) {
        self.calibrationName = calibrationName; self.uncertaintyDB = uncertaintyDB
        self.levelAFast = levelAFast; self.levelASlow = levelASlow; self.levelZEardrum = levelZEardrum
        self.leqATrack = leqATrack; self.leqASession = leqASession; self.maxAFast = maxAFast
        self.bandLevelsEardrum = bandLevelsEardrum
        self.doseNIOSH = doseNIOSH; self.doseWHOWeekly = doseWHOWeekly; self.doseSeconds = doseSeconds
        self.secondsToNIOSHLimit = secondsToNIOSHLimit
    }
}

/// JoseonHeadphones implements this. The engine calls it once per frame on the analysis thread.
public protocol SPLEstimating: AnyObject {
    /// `dt` = seconds of audio since the previous call (0 when no new audio arrived). `isSilent` = digital silence.
    func evaluate(thirdOctave: ThirdOctaveReading, dt: Double, isSilent: Bool) -> SPLReading
    /// New track: clears `leqATrack` and `maxAFast`. The dose keeps running.
    func resetMeasurement()
    /// Clears the dose and the session Leq.
    func resetDose()
}

// MARK: - Session timeline
//
// A rolling record of the last minutes of listening: one sample per second plus events.
// Memory only. Nothing here is ever written to disk. No audio is kept, only numbers.

/// One second of listening, summarized.
public struct SessionSample: Sendable, Equatable {
    /// Seconds of audio time since the recorder started (monotonic; pauses while there is no audio).
    public var time: Double
    /// Wall-clock time of the sample, for labels.
    public var date: Date
    /// Maximum momentary and the short-term loudness in this second (LUFS). Floor = LoudnessReading.silenceLUFS.
    public var momentaryMaxLUFS: Float
    public var shortTermLUFS: Float
    /// Highest true peak in this second (dBTP, louder channel).
    public var truePeakDBTP: Float
    /// Mean phase correlation in this second, −1…+1.
    public var correlation: Float
    /// Mean band energy in this second, the 8 bands of `BandEnergy` (dBFS).
    public var bands: [Float]
    /// Mean A-weighted level at the ear in this second (dB SPL, DF equivalent). Nil when not calibrated.
    public var levelA: Float?
    /// True when the whole second was digital silence.
    public var isSilent: Bool

    public init(time: Double, date: Date, momentaryMaxLUFS: Float, shortTermLUFS: Float, truePeakDBTP: Float, correlation: Float, bands: [Float], levelA: Float?, isSilent: Bool) {
        self.time = time; self.date = date; self.momentaryMaxLUFS = momentaryMaxLUFS; self.shortTermLUFS = shortTermLUFS
        self.truePeakDBTP = truePeakDBTP; self.correlation = correlation; self.bands = bands; self.levelA = levelA; self.isSilent = isSilent
    }
}

public struct SessionEvent: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case trackStart          // the measurement was reset (auto after silence, or manual)
        case clip                // new clipped-sample runs in this second; `value` = count
        case interSampleOver     // true peak went over 0 dBTP; `value` = dBTP
        case stressFlagRaised    // `label` = flag title, `detail` = flag id
        case stressFlagCleared
        case silenceStart
        case silenceEnd
    }
    public var id: Int
    public var kind: Kind
    /// Same clock as `SessionSample.time`.
    public var time: Double
    public var date: Date
    public var label: String
    public var detail: String
    public var value: Float

    public init(id: Int, kind: Kind, time: Double, date: Date, label: String = "", detail: String = "", value: Float = 0) {
        self.id = id; self.kind = kind; self.time = time; self.date = date; self.label = label; self.detail = detail; self.value = value
    }
}

/// A copy of the record, cheap to take about once per second from the main thread.
public struct SessionSnapshot: Sendable {
    /// Oldest first. At most `capacitySeconds` entries.
    public var samples: [SessionSample]
    /// Oldest first. Events older than the oldest sample are dropped.
    public var events: [SessionEvent]
    /// Changes whenever samples or events change; panels compare it to skip redraws.
    public var revision: Int

    public init(samples: [SessionSample] = [], events: [SessionEvent] = [], revision: Int = 0) {
        self.samples = samples; self.events = events; self.revision = revision
    }
}

/// JoseonCore implements this (`SessionRecorder`). The engine feeds it; panels and the app read snapshots.
public protocol SessionRecording: AnyObject {
    /// Length of the record in seconds (default 1800).
    var capacitySeconds: Int { get }
    /// Analysis thread: called once per published frame. `dt` = seconds of audio since the previous call.
    func ingest(_ frame: AnalysisFrame, dt: Double)
    /// Analysis thread: the measurement was reset (a new track).
    func noteTrackStart()
    /// Any thread.
    func snapshot() -> SessionSnapshot
    /// Any thread: forget everything.
    func clear()
}

// MARK: - A/B compare
//
// A `ComparisonSnapshot` is a frozen summary of what was playing: the long-term spectrum and the measurement numbers.
// The user captures "A", then looks at the live signal ("B") against it: another master of the same track, another
// track, or the same music through another headphone curve. Memory only; nothing is written to disk; no audio is kept.

public struct ComparisonSnapshot: Sendable, Identifiable {
    public var id: UUID
    /// Shown in the UI, for example "A · 21:42 · Qobuz".
    public var name: String
    public var date: Date
    /// Seconds of audio the long-term values cover.
    public var measuredSeconds: Double
    /// Long-term (since reset) mid spectrum on the display bins, dBFS, WITH the display tilt that was active
    /// at capture (`tiltDBPerOctave`). To compare with a live frame under another tilt, remove both tilts first.
    public var frequencies: [Float]
    public var averageDB: [Float]
    /// Peak hold at the moment of capture, same bins.
    public var peakHoldDB: [Float]
    public var bands: BandEnergy
    public var loudness: LoudnessReading
    /// Correlation, width and balance at capture (300 ms values) — coarse, shown as context only.
    public var correlation: Float
    public var width: Float
    public var balance: Float
    /// Headphone model at capture, when one was set: name and curves on the same bins (normalized 0 dB at 1 kHz).
    public var headphoneName: String?
    public var responseDB: [Float]?
    public var targetDB: [Float]?
    /// A-weighted Leq of the track at capture (dB SPL, DF equivalent) when calibrated.
    public var leqA: Float?
    public var lowestStrongHz: Float
    /// Display tilt (dB per octave, pivot 1 kHz) that `averageDB` and `peakHoldDB` carry. The app sets it after capture.
    public var tiltDBPerOctave: Float = 0

    public init(id: UUID = UUID(), name: String, date: Date, measuredSeconds: Double, frequencies: [Float], averageDB: [Float], peakHoldDB: [Float], bands: BandEnergy, loudness: LoudnessReading, correlation: Float, width: Float, balance: Float, headphoneName: String?, responseDB: [Float]?, targetDB: [Float]?, leqA: Float?, lowestStrongHz: Float) {
        self.id = id; self.name = name; self.date = date; self.measuredSeconds = measuredSeconds
        self.frequencies = frequencies; self.averageDB = averageDB; self.peakHoldDB = peakHoldDB
        self.bands = bands; self.loudness = loudness
        self.correlation = correlation; self.width = width; self.balance = balance
        self.headphoneName = headphoneName; self.responseDB = responseDB; self.targetDB = targetDB
        self.leqA = leqA; self.lowestStrongHz = lowestStrongHz
    }

    /// Capture from a live frame. The frame's long-term spectrum (`spectrum.average`) must be valid
    /// (a few seconds measured); the caller checks `loudness.measuredSeconds`.
    public static func capture(from frame: AnalysisFrame, name: String, date: Date = Date()) -> ComparisonSnapshot {
        ComparisonSnapshot(
            name: name, date: date, measuredSeconds: frame.loudness.measuredSeconds,
            frequencies: frame.spectrum.frequencies, averageDB: frame.spectrum.average, peakHoldDB: frame.spectrum.peakHold,
            bands: frame.bands, loudness: frame.loudness,
            correlation: frame.stereo.correlation, width: frame.stereo.width, balance: frame.stereo.balance,
            headphoneName: frame.headphone?.modelName,
            responseDB: frame.headphone?.responseDB,
            targetDB: (frame.headphone?.hasTarget ?? false) ? frame.headphone?.targetDB : nil,
            leqA: frame.spl?.leqATrack, lowestStrongHz: frame.lowestStrongHz
        )
    }
}
