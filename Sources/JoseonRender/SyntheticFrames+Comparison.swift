import Foundation
import JoseonCore

// Demo data of A/B compare: a believable reference "A" made from a frame, and two made-up headphone curves.
// A drawing aid, like the rest of `SyntheticFrames`: plausible, deterministic, synthetic. Not measurements.

extension SyntheticFrames {
    /// Made-up headphone curves for the demo and for design review. The names say "-like": these are smooth sketches of
    /// the character of such a headphone (dB re 1 kHz), not measurements of one.
    public enum DemoHeadphone: Sendable, CaseIterable {
        /// A planar in the manner of a Susvara: bass flat to 20 Hz, a full ear-gain rise, even treble.
        case susvaraLike
        /// A dynamic open-back in the manner of an HD 800 S: bass that rolls off under 60 Hz, a shallower ear-gain rise, a 6 kHz peak.
        case hd800sLike

        public var name: String {
            switch self {
            case .susvaraLike: return "Susvara-like"
            case .hd800sLike: return "HD 800 S-like"
            }
        }

        /// Response in dB relative to 1 kHz.
        public func responseDB(atHz hz: Float) -> Float { raw(log2(max(hz, 1))) - raw(log2(1000)) }

        private func raw(_ lf: Float) -> Float {
            func bump(_ at: Float, _ gain: Float, _ widthOct: Float) -> Float { let d = (lf - log2(at)) / widthOct; return gain * exp(-0.5 * d * d) }
            switch self {
            case .susvaraLike:
                return bump(28, 0.6, 1.2) + bump(1_700, -1.6, 0.5) + bump(3_200, 9.2, 0.68) + bump(5_400, -2.0, 0.2) + bump(9_800, 3.0, 0.28) + bump(18_500, -6.5, 0.45)
            case .hd800sLike:
                return -5.5 / (1 + pow(2, (lf - log2(38)) * 2.4)) + bump(150, 1.2, 1.0) + bump(3_400, 7.0, 0.62) + bump(6_100, 5.2, 0.17) + bump(11_000, 2.2, 0.3) + bump(19_000, -7.5, 0.4)
            }
        }
    }

    /// A `HeadphoneReading` of a demo headphone for a spectrum: response, the demo target, predicted at ear. No stress flags.
    public static func demoHeadphoneReading(_ headphone: DemoHeadphone, for s: SpectrumReading) -> HeadphoneReading {
        let response = s.frequencies.map { headphone.responseDB(atHz: $0) }
        let target = s.frequencies.map { demoTarget(log2Hz: log2($0)) }
        return HeadphoneReading(modelName: headphone.name, responseDB: response, targetDB: target,
                                predictedAtEarDB: zip(s.mid, response).map { $0 + $1 }, stressFlags: [])
    }

    /// A believable reference "A" for a live frame "B": the frame's own long-term curve, reshaped as another master of
    /// the same music would be. Default: 2 dB quieter, less air, more sub-bass, a little less presence; `brighter` turns
    /// the tonal change around (more air, less sub-bass). The measurement numbers move with it.
    /// - Parameters:
    ///   - frame: the live frame (its long-term spectrum should be valid: a few seconds measured).
    ///   - louderDB: level of A against the frame, dB. Negative = A is quieter than B.
    ///   - headphone: A's headphone, nil = the frame's own reading (or none).
    ///   - tiltDBPerOctave: the display tilt the frame's curves carry (stamped on the snapshot, as the app does).
    public static func demoComparison(from frame: AnalysisFrame, brighter: Bool = false, louderDB: Float = -2, headphone: DemoHeadphone? = nil,
                                      name: String = "A \u{00B7} 21:42 \u{00B7} Qobuz", tiltDBPerOctave: Float = 0) -> ComparisonSnapshot {
        let s = frame.spectrum
        let sign: Float = brighter ? -1 : 1
        func shape(_ hz: Float) -> Float {
            let lf = log2(max(hz, 1))
            func bump(_ at: Float, _ gain: Float, _ w: Float) -> Float { let d = (lf - log2(at)) / w; return gain * exp(-0.5 * d * d) }
            let air = -3.2 / (1 + pow(2, (log2(Float(9_000)) - lf) * 2.2))      // a shelf: less air above 9 kHz
            let sub = 2.6 / (1 + pow(2, (lf - log2(Float(55))) * 2.4))          // a shelf: more under 55 Hz
            // What two masters differ in besides the shelves: a broad presence change and a small ripple.
            let ripple = 0.45 * sin(lf * 2.3 + 0.7) + 0.25 * sin(lf * 5.1)
            return sign * (air + sub + bump(3_000, -1.3, 0.55)) + ripple + louderDB
        }
        let floor = SpectrumReading.floorDB
        func reshaped(_ v: [Float]) -> [Float] {
            zip(v, s.frequencies).map { level, hz in level <= floor + 0.5 ? level : max(level + shape(hz), floor) }
        }
        var l = frame.loudness
        func shift(_ v: Float, _ d: Float) -> Float { v <= -119 ? v : v + d }
        l.momentaryLUFS = shift(l.momentaryLUFS, louderDB); l.shortTermLUFS = shift(l.shortTermLUFS, louderDB)
        l.integratedLUFS = shift(l.integratedLUFS, louderDB)
        l.momentaryMaxLUFS = shift(l.momentaryMaxLUFS, louderDB); l.shortTermMaxLUFS = shift(l.shortTermMaxLUFS, louderDB)
        // The quieter master keeps more of its peaks: 0.9 dB more peak-to-loudness, a wider loudness range.
        let dynamics: Float = louderDB < 0 ? 0.9 : -0.9
        l.truePeakMaxDBTP = shift(l.truePeakMaxDBTP, louderDB + dynamics)
        l.truePeakLeftDBTP = shift(l.truePeakLeftDBTP, louderDB + dynamics); l.truePeakRightDBTP = shift(l.truePeakRightDBTP, louderDB + dynamics)
        l.plrDB += dynamics; l.psrDB += dynamics
        l.loudnessRangeLU = max(l.loudnessRangeLU + dynamics * 1.3, 0)
        l.rmsLeftDB = shift(l.rmsLeftDB, louderDB); l.rmsRightDB = shift(l.rmsRightDB, louderDB)
        l.measuredSeconds = max(l.measuredSeconds, 42)

        var b = frame.bands
        let centers = (0..<8).map { (BandEnergy.edgesHz[$0] * BandEnergy.edgesHz[$0 + 1]).squareRoot() }
        b.subBass = shift(b.subBass, shape(centers[0])); b.bass = shift(b.bass, shape(centers[1])); b.lowMid = shift(b.lowMid, shape(centers[2]))
        b.mid = shift(b.mid, shape(centers[3])); b.upperMid = shift(b.upperMid, shape(centers[4])); b.presence = shift(b.presence, shape(centers[5]))
        b.brilliance = shift(b.brilliance, shape(centers[6])); b.air = shift(b.air, shape(centers[7]))

        let hp = headphone.map { demoHeadphoneReading($0, for: s) } ?? frame.headphone
        var snap = ComparisonSnapshot(
            name: name, date: Date(timeIntervalSince1970: 1_790_000_000), measuredSeconds: l.measuredSeconds,
            frequencies: s.frequencies, averageDB: reshaped(s.average), peakHoldDB: reshaped(s.peakHold), bands: b, loudness: l,
            correlation: frame.stereo.correlation, width: frame.stereo.width, balance: frame.stereo.balance,
            headphoneName: hp?.modelName, responseDB: hp?.responseDB, targetDB: (hp?.hasTarget ?? false) ? hp?.targetDB : nil,
            leqA: frame.spl.map { $0.leqATrack + louderDB }, lowestStrongHz: frame.lowestStrongHz > 0 ? (frame.lowestStrongHz * (brighter ? 1.18 : 0.84)).rounded() : 0)
        snap.tiltDBPerOctave = tiltDBPerOctave
        return snap
    }
}
