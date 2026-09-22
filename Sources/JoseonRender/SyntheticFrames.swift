import Foundation
import JoseonCore

/// Music-like `AnalysisFrame` sequences for the demo mode, design review renders and tests.
/// This is a drawing aid: the numbers are plausible, deterministic and synthetic. They are not measurements.
public final class SyntheticFrames {
    public struct Options: Sendable {
        /// Display bins per spectrum.
        public var binCount = 1024
        public var framesPerSecond: Double = 60
        /// Adds a `HeadphoneReading` with a made-up response and target curve.
        public var includeHeadphone = false
        /// Overall level offset in dB. 0 gives about -13 LUFS.
        public var levelDB: Float = 0
        /// Pushes true peak over 0 dBTP and counts clips, to show the red states.
        public var hot = false
        public var seed: UInt64 = 0x4A6F_7365_6F6E
        /// Scope points per frame.
        public var scopePointCount = 1024
        /// Adds `thirdOctave` and a made-up `spl` reading (see `demoSPL`), as if a calibration were set.
        public var includeSPL = false
        public init() {}
    }

    public let options: Options
    public private(set) var time: Double = 0

    private let n: Int
    private let freqs: [Float]
    private let logF: [Float]          // log2(f)
    private var smoothL: [Float], smoothR: [Float], smoothM: [Float], smoothS: [Float]
    private var hold: [Float]
    private var avgPower: [Double]
    private var frameIndex = 0

    private var lufsM: Float = -70, lufsS: Float = -70
    private var integratedPower: Double = 0, integratedCount: Double = 0
    private var maxM: Float = -120, maxS: Float = -120, tpMax: Float = -120
    private var tpHoldL: Float = -120, tpHoldR: Float = -120
    private var shortTermHistory: [Float] = []
    private var clipCount = 0
    private var splState = DemoSPLState()

    public init(options: Options = Options()) {
        self.options = options
        n = max(options.binCount, 16)
        let silent = SpectrumReading.silent(binCount: n)
        freqs = silent.frequencies
        logF = freqs.map { log2($0) }
        let floor = [Float](repeating: SpectrumReading.floorDB, count: n)
        smoothL = floor; smoothR = floor; smoothM = floor; smoothS = floor; hold = floor
        avgPower = [Double](repeating: 0, count: n)
        shortTermHistory.reserveCapacity(4096)
    }

    /// `count` frames, 1 / framesPerSecond apart, starting at host time 1000.
    public static func sequence(count: Int, options: Options = Options()) -> [AnalysisFrame] {
        let g = SyntheticFrames(options: options)
        return (0..<count).map { _ in g.next() }
    }

    /// Digital silence.
    public static func silence(count: Int, binCount: Int = 1024, framesPerSecond: Double = 60) -> [AnalysisFrame] {
        (0..<count).map { i in
            AnalysisFrame(hostTime: 1000 + Double(i) / framesPerSecond,
                          stream: StreamInfo(sampleRate: 48_000, channelCount: 2, deviceName: "Synthetic"),
                          spectrum: .silent(binCount: binCount), isSilent: true)
        }
    }

    // MARK: Noise

    @inline(__always) private func hash(_ a: Int, _ b: Int, _ c: Int = 0) -> Float {
        var x = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15
        x ^= UInt64(bitPattern: Int64(b)) &* 0xC2B2_AE3D_27D4_EB4F
        x ^= UInt64(bitPattern: Int64(c)) &* 0x1656_67B1_9E37_79F9
        x ^= options.seed
        x ^= x >> 29; x = x &* 0xBF58_476D_1CE4_E5B9; x ^= x >> 32; x = x &* 0x94D0_49BB_1331_11EB; x ^= x >> 29
        return Float(x >> 40) / Float(1 << 24) * 2 - 1
    }

    /// Smooth value noise over (u, v), -1...1.
    private func noise(_ u: Float, _ v: Float, _ channel: Int) -> Float {
        let iu = Int(u.rounded(.down)), iv = Int(v.rounded(.down))
        var fu = u - Float(iu), fv = v - Float(iv)
        fu = fu * fu * (3 - 2 * fu); fv = fv * fv * (3 - 2 * fv)
        let a = hash(iu, iv, channel), b = hash(iu + 1, iv, channel)
        let c = hash(iu, iv + 1, channel), d = hash(iu + 1, iv + 1, channel)
        return (a + (b - a) * fu) + ((c + (d - c) * fu) - (a + (b - a) * fu)) * fv
    }

    // MARK: Music model

    private struct Partial { var hz: Float; var amp: Float; var pan: Float; var widthOct: Float }

    private static let chords: [[Int]] = [[45, 57, 60, 64, 69], [41, 53, 57, 60, 65], [48, 55, 60, 64, 67], [43, 55, 59, 62, 67]]
    private static let melody: [Int] = [76, 79, 81, 79, 76, 72, 74, 76, 81, 84, 83, 79, 76, 74, 72, 74]

    private func midiHz(_ m: Float) -> Float { 440 * pow(2, (m - 69) / 12) }

    private func partials(at t: Double) -> [Partial] {
        var out: [Partial] = []
        out.reserveCapacity(160)
        let bar = Int(t / 2.0)
        let chord = Self.chords[bar % Self.chords.count]
        let tInBar = Float(t - Double(bar) * 2.0)
        // Bass: root, plucked every beat.
        let beat = Float(t * 2).truncatingRemainder(dividingBy: 1)
        let bassEnv = exp(-beat * 2.2) * 0.9 + 0.1
        let root = midiHz(Float(chord[0]) - 12)
        for h in 1...10 {
            let a = 0.13 * bassEnv * pow(Float(h), -1.35)
            out.append(Partial(hz: root * Float(h), amp: a, pan: 0, widthOct: 0.018))
        }
        // Pad: chord tones with slow swell, spread across the field.
        let swell = 0.55 + 0.45 * sin(tInBar * .pi / 2)
        for (k, m) in chord.dropFirst().enumerated() {
            let f0 = midiHz(Float(m))
            let pan: Float = [-0.55, 0.45, -0.25, 0.6][k % 4]
            for h in 1...9 {
                let a = 0.060 * swell * pow(Float(h), -1.1) * (h % 2 == 0 ? 0.6 : 1)
                out.append(Partial(hz: f0 * Float(h) * (1 + 0.0006 * Float(k)), amp: a, pan: pan, widthOct: 0.012))
            }
        }
        // Melody: a new note every half beat, with vibrato and a decaying envelope.
        let step = Int(t * 4)
        let tInStep = Float(t * 4 - Double(step))
        let note = Self.melody[step % Self.melody.count]
        let vib = 0.12 * sin(Float(t) * 2 * .pi * 5.2)
        let f0 = midiHz(Float(note) + vib)
        let env = exp(-tInStep * 1.4) * (1 - exp(-tInStep * 40))
        let pan = 0.25 * sin(Float(t) * 0.7)
        for h in 1...14 {
            let a = 0.17 * env * pow(Float(h), -1.25) * (1 + 0.5 * sin(Float(h) * 1.7))
            out.append(Partial(hz: f0 * Float(h), amp: abs(a), pan: pan, widthOct: 0.010))
        }
        return out
    }

    // MARK: Frame

    public func next() -> AnalysisFrame {
        let dt = 1.0 / options.framesPerSecond
        time += dt
        frameIndex += 1
        let t = time
        let tf = Float(t)
        let gain = pow(10, options.levelDB / 20) * (options.hot ? 1.9 : 1)

        var ampL = [Float](repeating: 0, count: n), ampR = [Float](repeating: 0, count: n)

        // Percussion envelopes (120 bpm).
        let beatPos = Float(t * 2).truncatingRemainder(dividingBy: 1)
        let beatIndex = Int(t * 2)
        let kick = exp(-beatPos * 9)
        let snare = beatIndex % 2 == 1 ? exp(-beatPos * 7) : 0
        let eighth = Float(t * 4).truncatingRemainder(dividingBy: 1)
        let hat = exp(-eighth * 16) * (Int(t * 4) % 2 == 1 ? 1 : 0.55)

        // Broadband bed: pink-ish tilt, slow tonal drift, fine texture that moves in time.
        for i in 0..<n {
            let f = freqs[i], lf = logF[i]
            var db = -40 - 3.0 * (lf - log2(100))
            if f < 45 { db -= 20 * log2(45 / f) }
            if f > 15_000 { db -= 34 * log2(f / 15_000) }
            db += 3.5 * noise(lf * 0.9, tf * 0.18, 1)
            let texL = 1.6 * noise(lf * 3.0, tf * 0.9, 2) + 0.9 * noise(lf * 16, tf * 5, 3)
            let texR = 1.6 * noise(lf * 3.0, tf * 0.9, 4) + 0.9 * noise(lf * 16, tf * 5, 5)
            let shared = 2.4 * noise(lf * 8, tf * 3.2, 6) + 1.5 * noise(lf * 24, tf * 6, 10)
            var bed = pow(10, db / 20)
            // Kick body, snare band, hats.
            let kickShape = exp(-pow((lf - log2(58)) / 0.55, 2))
            let snareShape = exp(-pow((lf - log2(1900)) / 1.9, 2)) + 0.8 * exp(-pow((lf - log2(190)) / 0.35, 2))
            let hatShape = exp(-pow((lf - log2(9500)) / 0.9, 2))
            let perc = 0.085 * kick * kickShape + 0.030 * snare * snareShape + 0.014 * hat * hatShape
            bed += 0.004 * kick * exp(-pow((lf - log2(3000)) / 2.5, 2))
            ampL[i] = (bed * pow(10, (texL + shared) / 20) + perc * (1 + 0.04 * texL)) * gain
            ampR[i] = (bed * pow(10, (texR + shared) / 20) + perc * (1 - 0.04 * texR)) * gain
        }

        // Harmonic partials as narrow peaks.
        let lf0 = logF[0], lfSpan = logF[n - 1] - logF[0]
        for p in partials(at: t) where p.hz < 21_000 {
            let center = (log2(p.hz) - lf0) / lfSpan * Float(n - 1)
            // Peak width grows toward the lows, like an FFT with fixed Hz resolution.
            let widthOct = max(p.widthOct, 2.2 / p.hz)
            let widthBins = widthOct / lfSpan * Float(n - 1)
            let reach = Int(widthBins * 3.5) + 1
            let lo = max(Int(center) - reach, 0), hi = min(Int(center) + reach + 1, n - 1)
            guard lo <= hi else { continue }
            let angle = (p.pan + 1) * .pi / 4
            let gl = cos(angle) * 1.4142, gr = sin(angle) * 1.4142
            for i in lo...hi {
                let d = (Float(i) - center) / widthBins
                let a = p.amp * exp(-0.5 * d * d) * gain
                ampL[i] += a * gl
                ampR[i] += a * gr
            }
        }

        // To dB with instant attack and about 0.25 s release, like the real display smoothing.
        let release = Float(dt) * 46
        let holdDecay = Float(dt) * 12
        var bestBin = 0, bestDB: Float = -200
        for i in 0..<n {
            let l = ampL[i], r = ampR[i]
            let m = (l + r) * 0.5 * 0.94
            let s = abs(l - r) * 0.5 + m * 0.22
            let dl = max(20 * log10(max(l, 1e-7)), -120), dr = max(20 * log10(max(r, 1e-7)), -120)
            let dm = max(20 * log10(max(m, 1e-7)), -120), ds = max(20 * log10(max(s, 1e-7)), -120)
            smoothL[i] = max(dl, smoothL[i] - release)
            smoothR[i] = max(dr, smoothR[i] - release)
            smoothM[i] = max(dm, smoothM[i] - release)
            smoothS[i] = max(ds, smoothS[i] - release)
            hold[i] = max(smoothM[i], hold[i] - holdDecay)
            let pw = Double(m * m)
            avgPower[i] += (pw - avgPower[i]) / Double(min(frameIndex, 1800))
            if freqs[i] > 30, smoothM[i] > bestDB { bestDB = smoothM[i]; bestBin = i }
        }
        let average = avgPower.map { Float(max(10 * log10(max($0, 1e-14)), -120)) }
        let spectrum = SpectrumReading(frequencies: freqs, left: smoothL, right: smoothR, mid: smoothM, side: smoothS, peakHold: hold, average: average)

        // Peak with parabolic refinement.
        var peak = PeakReading()
        if bestDB > -90, bestBin > 0, bestBin < n - 1 {
            let a = smoothM[bestBin - 1], b = smoothM[bestBin], c = smoothM[bestBin + 1]
            let denom = a - 2 * b + c
            let off = abs(denom) > 1e-6 ? min(max(0.5 * (a - c) / denom, -0.5), 0.5) : 0
            let hz = pow(2, logF[bestBin] + off * lfSpan / Float(n - 1))
            let midi = 69 + 12 * log2(hz / 440)
            let nearest = midi.rounded()
            let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
            let idx = Int(nearest)
            let name = idx >= 0 ? names[idx % 12] + "\(idx / 12 - 1)" : ""
            peak = PeakReading(frequencyHz: hz, levelDB: b, noteName: name, cents: (midi - nearest) * 100)
        }

        // Band energy from the instantaneous mid power.
        var bandValues = [Float](repeating: -120, count: 8)
        var total: Double = 0
        for b in 0..<8 {
            var sum: Double = 0, count = 0
            for i in 0..<n where freqs[i] >= BandEnergy.edgesHz[b] && freqs[i] < BandEnergy.edgesHz[b + 1] {
                let m = Double((ampL[i] + ampR[i]) * 0.5)
                sum += m * m; count += 1
            }
            guard count > 0 else { continue }
            let octaves = Double(log2(BandEnergy.edgesHz[b + 1] / BandEnergy.edgesHz[b]))
            let power = sum / Double(count) * octaves * 9
            total += power
            bandValues[b] = Float(max(10 * log10(max(power, 1e-14)), -120))
        }
        let bands = BandEnergy(subBass: bandValues[0], bass: bandValues[1], lowMid: bandValues[2], mid: bandValues[3],
                               upperMid: bandValues[4], presence: bandValues[5], brilliance: bandValues[6], air: bandValues[7])

        // Loudness numbers that move like a meter.
        let instant = Float(10 * log10(max(total, 1e-14))) + 3.5
        let kM = Float(1 - exp(-dt / 0.4)), kS = Float(1 - exp(-dt / 3.0))
        lufsM = lufsM < -69 ? instant : lufsM + (instant - lufsM) * kM
        lufsS = lufsS < -69 ? instant : lufsS + (lufsM - lufsS) * kS
        integratedPower += pow(10, Double(lufsM) / 10); integratedCount += 1
        let integrated = Float(10 * log10(integratedPower / integratedCount))
        maxM = max(maxM, lufsM); maxS = max(maxS, lufsS)
        if frameIndex % 6 == 0, shortTermHistory.count < 4096 { shortTermHistory.append(lufsS) }
        var lra: Float = 0
        if shortTermHistory.count > 30 {
            let sorted = shortTermHistory.sorted()
            lra = sorted[Int(Float(sorted.count - 1) * 0.95)] - sorted[Int(Float(sorted.count - 1) * 0.10)]
        }
        let crestL = 8.5 + 3.5 * kick + 1.5 * noise(tf * 7, 0.5, 7)
        let crestR = 8.5 + 3.2 * kick + 1.5 * noise(tf * 7, 3.5, 8)
        let balanceDB = 0.6 * noise(tf * 0.3, 9.5, 9)
        let tpL = min(lufsM + crestL - balanceDB, options.hot ? 0.8 : -0.3)
        let tpR = min(lufsM + crestR + balanceDB, options.hot ? 0.6 : -0.4)
        tpHoldL = max(tpL, tpHoldL - Float(dt) * 20); tpHoldR = max(tpR, tpHoldR - Float(dt) * 20)
        tpMax = max(tpMax, tpHoldL, tpHoldR)
        if options.hot, tpL > 0.5, beatPos < 0.02 { clipCount += 1 }

        var loudness = LoudnessReading()
        loudness.momentaryLUFS = lufsM; loudness.shortTermLUFS = lufsS; loudness.integratedLUFS = integrated
        loudness.momentaryMaxLUFS = maxM; loudness.shortTermMaxLUFS = maxS; loudness.loudnessRangeLU = lra
        loudness.truePeakLeftDBTP = tpHoldL; loudness.truePeakRightDBTP = tpHoldR; loudness.truePeakMaxDBTP = tpMax
        loudness.rmsLeftDB = lufsM + 2.2 - balanceDB; loudness.rmsRightDB = lufsM + 2.0 + balanceDB
        loudness.plrDB = tpMax - integrated; loudness.psrDB = max(tpHoldL, tpHoldR) - lufsS
        loudness.clipCount = clipCount; loudness.measuredSeconds = t
        loudness.isIntegratedValid = true

        let stereo = makeStereo(t: t, kick: kick, hat: hat, level: pow(10, (lufsM + 14) / 20))

        var headphone: HeadphoneReading?
        if options.includeHeadphone {
            let response = logF.map { Self.demoResponse(log2Hz: $0) }
            let target = logF.map { Self.demoTarget(log2Hz: $0) }
            let predicted = (0..<n).map { max(smoothM[$0] + response[$0], -120) }
            headphone = HeadphoneReading(modelName: "Demo headphone", responseDB: response, targetDB: target, predictedAtEarDB: predicted, stressFlags: Self.demoStressFlags())
        }

        var frame = AnalysisFrame(hostTime: 1000 + t,
                                  stream: StreamInfo(sampleRate: 48_000, channelCount: 2, deviceName: "Synthetic", bitDepth: 24, activeSources: ["Joseon demo"]),
                                  spectrum: spectrum, peak: peak, bands: bands, loudness: loudness, stereo: stereo,
                                  headphone: headphone, isSilent: false)
        frame.topPeaks = Self.demoTopPeaks(of: spectrum, first: peak)
        frame.lowestStrongHz = Self.demoLowestStrong(of: spectrum)
        if options.includeSPL {
            let bands = Self.demoThirdOctave(of: spectrum)
            frame.thirdOctave = bands
            frame.spl = Self.demoSPL(loudness: loudness, thirdOctave: bands, dt: dt, state: &splState)
        }
        return frame
    }

    // MARK: Level at the ear (made up)

    /// Running state of the made-up SPL reading: the slow level, the Leq sums, the maximum and the dose. It starts in the
    /// middle of a listening session (3.5 h at about 78 dB(A)), so the dose shows a value a listener would see.
    public struct DemoSPLState: Sendable {
        var slowPower = 0.0
        var trackPower = 0.0, trackSeconds = 0.0
        var sessionPower = pow(10, 7.7) * 12_600, sessionSeconds = 12_600.0
        var maxFast: Float = 0
        var doseNIOSH = 0.087, doseWHO = 0.31
        public init() {}
    }

    public static let demoCalibrationName = "WA33 at 10 o'clock"
    /// Momentary loudness in LUFS + this = the made-up A-weighted level (about 76 ... 84 dB(A) on the demo signal).
    static let demoSPLOffsetDB: Float = 93
    /// Third-octave level in dBFS RMS + this = the made-up band level at the eardrum in dB SPL.
    static let demoBandOffsetDB: Float = 107

    /// Stand-in for `ThirdOctaveProviding.thirdOctave`: the display spectrum summed into the 31 nominal third-octave bands.
    /// Synthetic: the left and right curves of a display spectrum are not band RMS levels. Plausible shape, no measurement.
    public static func demoThirdOctave(of s: SpectrumReading) -> ThirdOctaveReading {
        let centers = ThirdOctaveReading.nominalCentersHz
        let n = min(s.frequencies.count, s.left.count, s.right.count)
        var left = [Float](repeating: ThirdOctaveReading.floorDB, count: centers.count), right = left
        guard n > 1 else { return ThirdOctaveReading(left: left, right: right) }
        let edge = pow(Float(2), 1.0 / 6)
        var i = 0
        for (b, fc) in centers.enumerated() {
            let lo = fc / edge, hi = fc * edge
            while i < n, s.frequencies[i] < lo { i += 1 }
            var sumL = 0.0, sumR = 0.0, count = 0
            var k = i
            while k < n, s.frequencies[k] < hi {
                sumL += pow(10, Double(s.left[k]) / 10); sumR += pow(10, Double(s.right[k]) / 10); count += 1; k += 1
            }
            guard count > 0 else { continue }
            // Mean power of the band's display bins, plus 5 dB for the width of a third octave, minus 3 dB (RMS of a sine).
            left[b] = max(Float(10 * log10(max(sumL / Double(count), 1e-14))) + 2, ThirdOctaveReading.floorDB)
            right[b] = max(Float(10 * log10(max(sumR / Double(count), 1e-14))) + 2, ThirdOctaveReading.floorDB)
        }
        return ThirdOctaveReading(left: left, right: right)
    }

    /// Stand-in for the SPL estimator of `JoseonHeadphones`: a made-up `SPLReading` that moves with the loudness numbers
    /// (momentary LUFS + 93 dB), with a calibration named "WA33 at 10 o'clock" and 2 dB of uncertainty. The dose rises at
    /// the NIOSH (85 dB(A), 8 h, 3 dB) and WHO (80 dB(A), 40 h, 3 dB) rates. Synthetic, deterministic; not a measurement.
    public static func demoSPL(loudness l: LoudnessReading, thirdOctave: ThirdOctaveReading?, dt: Double, state: inout DemoSPLState) -> SPLReading {
        let silent = l.momentaryLUFS <= -69
        let fast: Float = silent ? SPLReading.floorDB : max(l.momentaryLUFS + demoSPLOffsetDB, SPLReading.floorDB)
        let power = silent ? 0 : pow(10, Double(fast) / 10)
        state.slowPower = state.slowPower <= 0 ? power : state.slowPower + (power - state.slowPower) * (1 - exp(-dt / 1.0))
        let slow = state.slowPower > 1 ? Float(10 * log10(state.slowPower)) : SPLReading.floorDB
        if !silent {
            state.trackPower += power * dt; state.trackSeconds += dt
            state.sessionPower += power * dt; state.sessionSeconds += dt
            state.maxFast = max(state.maxFast, fast)
            state.doseNIOSH += dt / (8 * 3600 * pow(2, (85 - Double(slow)) / 3))
            state.doseWHO += dt / (40 * 3600 * pow(2, (80 - Double(slow)) / 3))
        }
        func leq(_ p: Double, _ t: Double) -> Float { t > 0 && p > 0 ? Float(10 * log10(p / t)) : SPLReading.floorDB }
        // Band levels at the eardrum: the louder channel of each band plus one constant, like a real calibration (volts and
        // sensitivity do not move with the music). The constant puts the A-weighted sum of the demo signal a few dB over
        // the diffuse-field level above, as the ear canal gain does.
        var bands = [Float](repeating: SPLReading.floorDB, count: ThirdOctaveReading.nominalCentersHz.count)
        if let t = thirdOctave, !silent {
            let count = min(t.left.count, t.right.count, bands.count)
            for b in 0..<count { bands[b] = max(max(t.left[b], t.right[b]) + demoBandOffsetDB, SPLReading.floorDB) }
        }
        let left = slow >= 70 ? max(1 - state.doseNIOSH, 0) * 8 * 3600 * pow(2, (85 - Double(slow)) / 3) : Double.infinity
        return SPLReading(calibrationName: demoCalibrationName, uncertaintyDB: 2, levelAFast: fast, levelASlow: slow,
                          levelZEardrum: silent ? SPLReading.floorDB : slow + 4.5, leqATrack: leq(state.trackPower, state.trackSeconds),
                          leqASession: leq(state.sessionPower, state.sessionSeconds), maxAFast: state.maxFast, bandLevelsEardrum: bands,
                          doseNIOSH: Float(state.doseNIOSH), doseWHOWeekly: Float(state.doseWHO), doseSeconds: state.sessionSeconds,
                          secondsToNIOSHLimit: left)
    }

    /// The same frames with a made-up third-octave reading and SPL reading (`demoThirdOctave`, `demoSPL`): for frames of
    /// the real analyzers, which carry no SPL until a calibration is set.
    public static func addingDemoSPL(to frames: [AnalysisFrame]) -> [AnalysisFrame] {
        var state = DemoSPLState()
        var last: Double?
        return frames.map { f in
            var f = f
            let dt = last.map { min(max(f.hostTime - $0, 0), 0.5) } ?? 1.0 / 60
            last = f.hostTime
            let bands = f.thirdOctave ?? demoThirdOctave(of: f.spectrum)
            f.thirdOctave = bands
            var l = f.loudness
            if f.isSilent { l.momentaryLUFS = -120 }
            f.spl = demoSPL(loudness: l, thirdOctave: bands, dt: dt, state: &state)
            return f
        }
    }

    // MARK: Spectrum layers

    /// Latencies of the three synthetic FFT resolutions (half their window): long, middle, short.
    public static let layerLatencies: [Float] = [0.34, 0.085, 0.021]

    /// Frames that carry `SpectrumReading.midLayers`, the way the analyzer provides them: three resolutions with the latencies
    /// of `layerLatencies`, crossfade weights around 200 Hz and 2 kHz, a steady noise floor with three tones, and one
    /// broadband click at each of `clickTimes` (seconds from the start; default: every second from 1 s). A click shows in
    /// each layer at ITS latency, as a hill as long as that layer's window. `mid` is the undelayed power blend, like the live
    /// spectrum. Synthetic, deterministic; for the spectrogram's layer path, its tests and design review renders.
    public static func layeredClicks(seconds: Double, clickTimes: [Double]? = nil, framesPerSecond: Double = 60, binCount: Int = 1024) -> [AnalysisFrame] {
        let silent = SpectrumReading.silent(binCount: binCount)
        let freqs = silent.frequencies
        let n = freqs.count
        let clicks = clickTimes ?? Array(stride(from: 1.0, to: max(seconds, 1.0), by: 1.0))
        // Steady part, as power: a pink-ish floor with a fixed fine texture, and three tones.
        let tones: [(hz: Float, db: Float)] = [(110, -30), (440, -36), (3_100, -46)]
        let steady: [Float] = (0..<n).map { i in
            let lf = log2(freqs[i])
            var db = -62 - 3.0 * (lf - log2(100)) + 0.5 * sin(lf * 23) + 0.3 * sin(lf * 71 + 1)
            if freqs[i] < 40 { db -= 18 * log2(40 / freqs[i]) }
            var p = pow(10, db / 10)
            for t in tones {
                let d = (lf - log2(t.hz)) / 0.006
                p += pow(10, t.db / 10) * exp(-0.5 * d * d)
            }
            return p
        }
        let clickPower = pow(Float(10), -34 / 10)
        let weights: [[Float]] = (0..<3).map { k in
            freqs.map { f in
                let w = SpectrumTiming.weights(atHz: f)
                return k == 0 ? w.low : (k == 1 ? w.mid : w.high)
            }
        }
        let stream = StreamInfo(sampleRate: 48_000, channelCount: 2, deviceName: "Synthetic layers", bitDepth: 24, activeSources: ["Joseon demo"])
        let floorRow = [Float](repeating: SpectrumReading.floorDB, count: n)
        let count = max(Int(seconds * framesPerSecond), 1)
        return (0..<count).map { index in
            let t = Double(index + 1) / framesPerSecond
            var layers: [SpectrumLayer] = []
            var blend = [Float](repeating: 0, count: n)
            for k in 0..<3 {
                let latency = Double(layerLatencies[k])
                // The window of this layer passes over the click: Hann window value at the click, squared (power).
                var hill: Float = 0
                for c in clicks {
                    let x = (t - c - latency) / latency
                    if abs(x) < 1 { let w = Float(0.5 * (1 + cos(.pi * x))); hill += w * w }
                }
                var levels = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    let p = steady[i] + clickPower * hill
                    levels[i] = max(10 * log10(p), SpectrumReading.floorDB)
                    blend[i] += weights[k][i] * p
                }
                layers.append(SpectrumLayer(levelsDB: levels, weights: weights[k], latencySeconds: layerLatencies[k]))
            }
            let mid = blend.map { max(10 * log10(max($0, 1e-12)), SpectrumReading.floorDB) }
            var spectrum = SpectrumReading(frequencies: freqs, left: mid, right: mid, mid: mid, side: floorRow, peakHold: mid,
                                           average: steady.map { 10 * log10($0) })
            spectrum.midLayers = layers
            var frame = AnalysisFrame(hostTime: 1000 + t, stream: stream, spectrum: spectrum, isSilent: false)
            frame.peak = PeakReading(frequencyHz: 110, levelDB: -30, noteName: "A2", cents: 0)
            return frame
        }
    }

    // MARK: Stand-ins for analyzer extras

    /// Made-up stress flags with a frequency span and a plot label, the way `JoseonHeadphones` fills them. The numbers are
    /// read from the demo curves (`demoResponse` against `demoTarget`), so a label never contradicts the curve under it.
    /// There is no whole-signal flag here: nothing in a synthetic frame measures one.
    public static func demoStressFlags() -> [StressFlag] {
        func error(_ hz: Float) -> Float { demoResponse(log2Hz: log2(hz)) - demoTarget(log2Hz: log2(hz)) }
        var flags: [StressFlag] = []
        // Sub-bass: mean error from 20 to 45 Hz.
        let subSteps = stride(from: Float(20), through: 45, by: 2.5)
        let sub = subSteps.reduce(Float(0)) { $0 + error($1) } / Float(Array(subSteps).count)
        if sub < -3 {
            flags.append(StressFlag(id: "demo-sub", severity: .watch, title: "Sub-bass under-delivered", detail: "Synthetic demo flag",
                                    frequencyRangeHz: 20...45, plotLabel: "\(Fmt.number(sub, digits: 0)) dB vs target"))
        }
        // Treble: the largest excess over the target between 4 and 14 kHz.
        var bestHz: Float = 0, best: Float = 0
        var hz: Float = 4_000
        while hz <= 14_000 { let e = error(hz); if e > best { best = e; bestHz = hz }; hz *= pow(2, 1.0 / 24) }
        if best > 2 {
            let label = "+\(Fmt.number(best, digits: 0)) dB at \(String(format: "%.1f", bestHz / 1000)) kHz"
            flags.append(StressFlag(id: "demo-treble", severity: .high, title: "Treble peak", detail: "Synthetic demo flag",
                                    frequencyRangeHz: (bestHz / pow(2, 0.2))...(bestHz * pow(2, 0.2)), plotLabel: label))
        }
        return flags
    }

    /// Stand-in for `TopPeaksProviding.topPeaks`: the strongest local maxima of mid that stand 10 dB over the level an
    /// octave around them, strongest first, at most 5, at least a third of an octave apart. `first` leads the list.
    public static func demoTopPeaks(of s: SpectrumReading, first: PeakReading? = nil) -> [PeakReading] {
        let n = min(s.mid.count, s.frequencies.count)
        guard n > 64 else { return [] }
        let perOctave = Float(n - 1) / log2(s.frequencies[n - 1] / s.frequencies[0])
        let reach = max(Int(perOctave / 2), 4)
        var found: [(Int, Float)] = []
        for i in 2..<(n - 2) where s.frequencies[i] > 25 && s.mid[i] > -80 && s.mid[i] >= s.mid[i - 1] && s.mid[i] > s.mid[i + 1] {
            var sum: Float = 0, c: Float = 0
            for k in stride(from: max(i - reach, 0), through: min(i + reach, n - 1), by: 2) { sum += s.mid[k]; c += 1 }
            if s.mid[i] - sum / c >= 10 { found.append((i, s.mid[i])) }
        }
        found.sort { $0.1 > $1.1 }
        var out: [PeakReading] = []
        if let first, first.frequencyHz > 0, first.levelDB > -119 { out.append(first) }
        for (i, db) in found where out.count < 5 {
            let hz = s.frequencies[i]
            if out.contains(where: { abs(log2($0.frequencyHz / hz)) < 1.0 / 3 }) { continue }
            let midi = 69 + 12 * log2(hz / 440), nearest = midi.rounded()
            let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
            let idx = Int(nearest)
            out.append(PeakReading(frequencyHz: hz, levelDB: db, noteName: idx >= 0 ? names[idx % 12] + "\(idx / 12 - 1)" : "", cents: (midi - nearest) * 100))
        }
        return out
    }

    /// Stand-in for `TopPeaksProviding.lowestStrongHz`: the lowest bin of the long-term average within 30 dB of its maximum.
    public static func demoLowestStrong(of s: SpectrumReading) -> Float {
        let n = min(s.average.count, s.frequencies.count)
        guard n > 0, let top = s.average.prefix(n).max(), top > -100 else { return 0 }
        for i in 0..<n where s.frequencies[i] >= 20 && s.average[i] >= top - 30 { return s.frequencies[i] }
        return 0
    }

    // MARK: Stereo field

    private func makeStereo(t: Double, kick: Float, hat: Float, level: Float) -> StereoReading {
        let count = max(options.scopePointCount, 16)
        var pts = [SIMD2<Float>](repeating: .zero, count: count)
        let sr = 48_000.0
        let bar = Int(t / 2.0)
        let chord = Self.chords[bar % Self.chords.count]
        let bassHz = Double(midiHz(Float(chord[0]) - 12))
        let tones: [(hz: Double, amp: Float, pan: Float, phase: Double)] = [
            (Double(midiHz(Float(chord[1]))), 0.16, -0.75, 0.3), (Double(midiHz(Float(chord[2]))), 0.15, 0.7, 1.1),
            (Double(midiHz(Float(chord[3]))), 0.13, -0.45, 2.0), (Double(midiHz(Float(chord[4]))) * 2, 0.10, 0.85, 0.7),
            (Double(midiHz(Float(chord[2]))) * 3.01, 0.07, -0.9, 1.9), (Double(midiHz(Float(chord[3]))) * 4.02, 0.05, 0.95, 2.6),
            (Double(midiHz(Float(Self.melody[Int(t * 4) % Self.melody.count]))), 0.14, 0.3 * Float(sin(t * 0.7)), 0.0),
        ]
        var sumLR: Float = 0, sumLL: Float = 0, sumRR: Float = 0, sumMM: Float = 0, sumSS: Float = 0
        let base = Int(t * sr)
        for i in 0..<count {
            let ts = Double(base + i) / sr
            let bass = Float(sin(2 * .pi * bassHz * ts)) * (0.13 + 0.16 * kick)
            var l = bass, r = bass
            for tone in tones {
                let angle = (tone.pan + 1) * .pi / 4
                // A small inter-channel phase offset gives the pad its width.
                l += tone.amp * cos(angle) * 1.4142 * Float(sin(2 * .pi * tone.hz * ts + tone.phase))
                r += tone.amp * sin(angle) * 1.4142 * Float(sin(2 * .pi * tone.hz * ts + tone.phase + 1.5 * Double(tone.pan)))
            }
            let nl = hash(base + i, 11, 1), nr = hash(base + i, 12, 2), nc = hash(base + i, 13, 3)
            let air = 0.012 + 0.05 * hat
            l += air * (0.9 * nl + 0.3 * nc)
            r += air * (0.9 * nr + 0.3 * nc)
            l *= level * 1.15; r *= level * 1.15
            let m = (l + r) * 0.5, s = (l - r) * 0.5
            // Contract mapping, the same as StereoAnalyzer: x = (R - L) / 2, y = (L + R) / 2, so |x| + |y| = max(|L|, |R|).
            // The clamp only catches input over full scale.
            pts[i] = SIMD2(min(max((r - l) * 0.5, -1), 1), min(max((l + r) * 0.5, -1), 1))
            sumLR += l * r; sumLL += l * l; sumRR += r * r; sumMM += m * m; sumSS += s * s
        }
        let corr = sumLR / max((sumLL * sumRR).squareRoot(), 1e-9)
        let rl = sumLL.squareRoot(), rr = sumRR.squareRoot()
        let balance = (rr - rl) / max(rr + rl, 1e-9)
        let width = (sumSS / max(sumMM, 1e-9)).squareRoot()
        let tf = Float(t)
        let baseCorr: [Float] = [0.99, 0.96, 0.84, 0.66, 0.52, 0.38, 0.22, 0.02]
        let bandCorr = (0..<8).map { i in min(max(baseCorr[i] + (0.04 + 0.05 * Float(i)) * noise(tf * 0.8, Float(i) * 3.1, 20), -1), 1) }
        let bandBal = (0..<8).map { i in (0.03 + 0.035 * Float(i)) * noise(tf * 0.5, Float(i) * 5.3, 21) * 2.2 }
        return StereoReading(correlation: corr, balance: balance, width: width, bandCorrelation: bandCorr, bandBalance: bandBal,
                             bandActive: [Bool](repeating: true, count: 8), scopePoints: pts)
    }

    // MARK: Demo headphone curves (made up, smooth, 0 dB at 1 kHz)

    private static func bump(_ lf: Float, _ hz: Float, _ gain: Float, _ widthOct: Float) -> Float {
        let d = (lf - log2(hz)) / widthOct
        return gain * exp(-0.5 * d * d)
    }

    static func demoResponse(log2Hz lf: Float) -> Float {
        var v: Float = 0
        v += bump(lf, 20, -7, 1.0) + bump(lf, 110, 1.8, 0.9)
        v += bump(lf, 3100, 8.5, 0.62) + bump(lf, 5800, -3.5, 0.22) + bump(lf, 8600, 4.5, 0.2)
        v += bump(lf, 17_000, -9, 0.5)
        return v - (bump(log2(1000), 3100, 8.5, 0.62) + bump(log2(1000), 110, 1.8, 0.9))
    }

    static func demoTarget(log2Hz lf: Float) -> Float {
        var v: Float = 0
        v += 5.5 / (1 + pow(2, (lf - log2(105)) * 2.2))
        v += bump(lf, 3000, 11, 0.75) + bump(lf, 9000, 2.0, 0.5) + bump(lf, 19_000, -8, 0.6)
        let at1k = 5.5 / (1 + pow(2, (log2(Float(1000)) - log2(105)) * 2.2)) + bump(log2(1000), 3000, 11, 0.75)
        return v - at1k
    }
}
