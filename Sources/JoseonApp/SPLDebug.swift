import AVFoundation
import Foundation
import JoseonCore
import JoseonCapture
import JoseonHeadphones
import JoseonRender

// MARK: - Snapshot mode (layout review only)

/// Snapshot mode (JOSEON_SNAPSHOT_DIR) never reads or writes the user's calibrations and dose, and never watches
/// the real output device. JOSEON_SNAPSHOT_SPL picks the state the pictures show:
///   unset / "nosensitivity"  empty store: "sensitivity unknown"
///   "uncalibrated"           a typed-in sensitivity, no calibration
///   "calibrated"             sensitivity + one preset + the STUB estimator below
/// JOSEON_SNAPSHOT_SPL_DOSE=0.52 seeds the daily dose (default 0.34), so the ring and the banner can be reviewed.
enum SnapshotSPL {
    static var isActive: Bool { DebugSnapshot.directory != nil }
    static var mode: String { ProcessInfo.processInfo.environment["JOSEON_SNAPSHOT_SPL"] ?? "nosensitivity" }

    /// A made-up output device with a software volume, so the "macOS controls the volume" method has something to show.
    /// JOSEON_SNAPSHOT_SPL_VOLUME=none: a device without software volume.
    static var output: OutputVolumeState {
        let fixed = ProcessInfo.processInfo.environment["JOSEON_SNAPSHOT_SPL_VOLUME"] == "none"
        return OutputVolumeState(deviceID: 0, deviceName: "Snapshot DAC", deviceUID: "snapshot", volumeDB: fixed ? nil : -12, maxVolumeDB: fixed ? nil : 0,
                                 volumeScalar: fixed ? nil : 0.62, isMuted: false)
    }

    static func seedLedger() -> SPLDoseLedger {
        var ledger = SPLDoseLedger()
        ledger.rollOver(now: Date())
        guard mode == "calibrated" else { return ledger }
        let dose = ProcessInfo.processInfo.environment["JOSEON_SNAPSHOT_SPL_DOSE"].flatMap(Double.init) ?? 0.34
        ledger.nioshToday = dose
        ledger.whoWeek = dose * 0.6
        ledger.listeningSecondsToday = 2.5 * 3600
        return ledger
    }

    static func seed(_ store: SPLCalibrationStore, headphone: String) {
        guard mode == "calibrated" || mode == "uncalibrated", store.userSensitivity(headphone: headphone) == nil else { return }
        // STUB numbers for the pictures. Not data about any real headphone.
        store.setUserSensitivity(UserSensitivity(value: 100, unit: .dbPerVolt, impedanceOhms: 50), headphone: headphone)
        guard mode == "calibrated" else { return }
        store.add(CalibrationPreset(
            calibration: PlaybackCalibration(name: "Snapshot DAC · stub preset", method: .measuredVoltage, fullScaleVrms: 2.0, uncertaintyDB: 2),
            deviceName: output.deviceName, headphoneName: headphone, knobNote: "10 o'clock"))
    }
}

/// STUB. NOT A MEASUREMENT. Snapshot mode only, so the header pill, the popover and the session list can be
/// reviewed before the real estimator of `JoseonHeadphones` is in the build. It turns the band levels (or, when
/// the analyzer has no third-octave bands yet, the momentary loudness) into a plausible A-level with a fixed
/// offset. No headphone response, no diffuse-field correction, no A-weighting.
final class SnapshotSPLStub: SPLEstimating {
    private let calibration: PlaybackCalibration
    private let lock = NSLock()
    private var slow: Float = 0, trackEnergy = 0.0, trackSeconds = 0.0, sessionEnergy = 0.0, sessionSeconds = 0.0
    private var maxFast: Float = 0, niosh = 0.0, who = 0.0, doseSeconds = 0.0
    private var lastUptime: TimeInterval = 0
    /// Stub sensitivity in dB SPL per volt, minus a few dB that stand in for the diffuse-field correction.
    private static let offset: Float = 94 - 4

    init(calibration: PlaybackCalibration) { self.calibration = calibration }

    func evaluate(thirdOctave: ThirdOctaveReading, dt: Double, isSilent: Bool) -> SPLReading {
        func total(_ bands: [Float]) -> Float { 10 * log10(bands.reduce(Float(1e-14)) { $0 + pow(10, $1 / 10) }) }
        let dbfs = max(total(thirdOctave.left), total(thirdOctave.right)) + 3.01
        return step(level: dbfs + 20 * log10(Float(calibration.fullScaleVrms)) + Self.offset, dt: dt, isSilent: isSilent, bands: thirdOctave.left.count)
    }

    /// Fallback while the analyzer has no third-octave bands: momentary loudness in place of the band sum.
    func evaluate(loudness: LoudnessReading, isSilent: Bool) -> SPLReading {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = lastUptime == 0 ? 0 : min(now - lastUptime, 1)
        lastUptime = now
        return step(level: loudness.momentaryLUFS + 20 * log10(Float(calibration.fullScaleVrms)) + Self.offset, dt: dt, isSilent: isSilent, bands: 31)
    }

    private func step(level raw: Float, dt: Double, isSilent: Bool, bands: Int) -> SPLReading {
        lock.lock(); defer { lock.unlock() }
        let fast = isSilent ? 0 : max(0, raw)
        slow += (fast - slow) * Float(min(1, dt / 1.0))
        if fast > 20, dt > 0 {
            let energy = pow(10, Double(fast) / 10) * dt
            trackEnergy += energy; trackSeconds += dt; sessionEnergy += energy; sessionSeconds += dt
            doseSeconds += dt
            niosh += dt / SPLMath.allowedSeconds(levelA: Double(fast), criterionDB: 85, criterionHours: 8)
            who += dt / SPLMath.allowedSeconds(levelA: Double(fast), criterionDB: 80, criterionHours: 40)
            maxFast = max(maxFast, fast)
        }
        func leq(_ energy: Double, _ seconds: Double) -> Float { seconds > 0 ? Float(10 * log10(energy / seconds)) : 0 }
        return SPLReading(
            calibrationName: calibration.name, uncertaintyDB: Float(calibration.uncertaintyDB), levelAFast: fast, levelASlow: slow,
            levelZEardrum: fast + 4, leqATrack: leq(trackEnergy, trackSeconds), leqASession: leq(sessionEnergy, sessionSeconds), maxAFast: maxFast,
            bandLevelsEardrum: [Float](repeating: 0, count: bands), doseNIOSH: Float(niosh), doseWHOWeekly: Float(who), doseSeconds: doseSeconds,
            secondsToNIOSHLimit: SPLMath.secondsLeft(dose: niosh, levelA: Double(slow), criterionDB: 85, criterionHours: 8))
    }

    func resetMeasurement() { lock.lock(); trackEnergy = 0; trackSeconds = 0; maxFast = 0; lock.unlock() }
    func resetDose() { lock.lock(); niosh = 0; who = 0; doseSeconds = 0; sessionEnergy = 0; sessionSeconds = 0; lock.unlock() }
}

// MARK: - Self-check

/// JOSEON_SPL_SELFCHECK=1 (debug builds): offline checks of the tone generator, the calibration arithmetic, the dose
/// ledger and the preset store. Prints PASS / FAIL lines and exits. It plays NO sound: the tone is rendered into
/// memory, and the AVAudioEngine graph runs in manual (offline) rendering mode, which has no output device.
enum SPLSelfCheck {
    static var isRequested: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["JOSEON_SPL_SELFCHECK"] == "1"
        #else
        return false
        #endif
    }

    #if DEBUG
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
    }

    private static func rmsDBFS(_ x: ArraySlice<Float>) -> Double {
        let sum = x.reduce(0.0) { $0 + Double($1) * Double($1) }
        return 10 * log10(sum / Double(max(x.count, 1)))
    }

    private static func render(_ generator: inout ToneGenerator, seconds: Double, block: Int, stopAtSample: Int? = nil) -> [Float] {
        let total = Int(seconds * generator.sampleRate)
        var out = [Float](repeating: 0, count: total)
        var done = 0
        out.withUnsafeMutableBufferPointer { p in
            while done < total {
                if let stopAtSample, done >= stopAtSample { generator.requestStop() }
                let n = min(block, total - done)
                generator.render(into: p.baseAddress! + done, count: n)
                done += n
            }
        }
        return out
    }

    private static func maxStep(_ x: [Float]) -> Double {
        var m = 0.0
        for i in 1..<x.count { m = max(m, Double(abs(x[i] - x[i - 1]))) }
        return m
    }

    /// Runs every check and returns the process exit code.
    static func run() -> Int32 {
        print("Joseon SPL self-check (offline, no sound)")
        tone()
        offlineGraph()
        math()
        ledger()
        store()
        totalUncertainty()
        calibrationTexts()
        oneFormat()
        sessionClips()
        if let device = OutputVolume.readDefaultDevice() {
            let volume = device.volumeDB.map { String(format: "%.1f dB (max %.1f dB), %.1f dB below maximum", $0, device.maxVolumeDB ?? 0, device.attenuationDB ?? 0) } ?? "no software volume"
            print("INFO  default output (read only): \(device.deviceName): \(volume)\(device.isMuted ? ", muted" : "")")
            // Listeners only: the monitor adds and removes HAL property listeners, it sets nothing.
            let monitor = OutputVolumeMonitor()
            monitor.start()
            check("output volume monitor: starts, reads the same device, stops", monitor.state?.deviceID == device.deviceID)
            monitor.stop()
        } else {
            print("INFO  no default output device")
        }
        print(failures == 0 ? "RESULT PASS" : "RESULT FAIL (\(failures))")
        return failures == 0 ? 0 : 1
    }

    private static func tone() {
        for sampleRate in [44_100.0, 48_000.0, 96_000.0] {
            let tag = "\(Int(sampleRate)) Hz"
            var g = ToneGenerator(sampleRate: sampleRate)
            let x = render(&g, seconds: 61, block: 512)
            let sr = Int(sampleRate)
            // Steady part, a whole number of 400 Hz cycles: 1 s ... 59 s.
            let rms = rmsDBFS(x[sr..<(59 * sr)])
            check("tone RMS −23.01 dBFS ±0.05 (\(tag))", abs(rms - (-23.0103)) < 0.05, String(format: "%.4f dBFS", rms))
            let peak = x[sr..<(59 * sr)].map { abs($0) }.max() ?? 0
            check("tone peak −20 dBFS (\(tag))", abs(20 * log10(Double(peak)) + 20) < 0.01, String(format: "%.4f dBFS", 20 * log10(Double(peak))))

            // Fade-in: a raised cosine of 0.5 s. Compare every sample with the formula.
            var worst = 0.0
            let step = 2 * Double.pi * 400 / sampleRate
            for n in 0..<(sr / 2) {
                let e = 0.5 * (1 - cos(Double.pi * Double(n) / Double(sr / 2)))
                worst = max(worst, abs(Double(x[n]) - 0.1 * e * sin(step * Double(n))))
            }
            check("fade-in is a 0.5 s raised cosine (\(tag))", worst < 1e-6 && x[0] == 0, String(format: "max error %.2e", worst))
            check("fade-in envelope 0 → 0.5 → 1 (\(tag))", g.envelope(at: 0) == 0 && abs(g.envelope(at: sr / 4) - 0.5) < 1e-9 && g.envelope(at: sr / 2) == 1)
            let first10ms = x[0..<(sr / 100)].map { abs($0) }.max() ?? 1
            check("first 10 ms stay under −80 dBFS (\(tag))", first10ms < 1e-4, String(format: "%.1f dBFS", 20 * log10(Double(max(first10ms, 1e-12)))))

            // Hard limit: nothing after 60 s, and the tone is faded out when it gets there.
            let tail = x[(60 * sr)...].map { abs($0) }.max() ?? 1
            let beforeEnd = abs(x[60 * sr - 1])
            check("hard 60 s limit: zeros after 60 s, faded before (\(tag))", tail == 0 && beforeEnd < 1e-5 && g.isFinished, String(format: "last sample %.2e", beforeEnd))

            // No click anywhere: no sample step larger than the steepest step of the full-level sine.
            let sineStep = 0.1 * step
            check("no click over the whole 61 s (\(tag))", maxStep(x) <= sineStep * 1.02, String(format: "max step %.6f, sine %.6f", maxStep(x), sineStep))

            // Stop in the steady part, at a sample that is not a block edge and not a zero crossing.
            var s = ToneGenerator(sampleRate: sampleRate)
            let stopAt = Int(2.0137 * sampleRate)
            let y = render(&s, seconds: 3, block: 441, stopAtSample: stopAt)
            let fadeEnd = s.fadeOutStart + s.fadeOutSamples
            let after = y[fadeEnd...].map { abs($0) }.max() ?? 1
            check("stop: 0.1 s raised-cosine fade-out, then zeros (\(tag))", after == 0 && s.isFinished && abs(y[fadeEnd - 1]) < 1e-5 && s.fadeOutStart >= stopAt && s.fadeOutStart < stopAt + 441,
                  "fade starts at sample \(s.fadeOutStart)")
            check("stop: no click (\(tag))", maxStep(y) <= sineStep * 1.02, String(format: "max step %.6f", maxStep(y)))

            // Stop inside the fade-in: the fade-out starts from the level reached, without a jump.
            var early = ToneGenerator(sampleRate: sampleRate)
            let z = render(&early, seconds: 1, block: 256, stopAtSample: Int(0.2 * sampleRate))
            let reached = early.envelope(at: early.fadeOutStart)
            check("stop inside the fade-in: no jump, no click (\(tag))", maxStep(z) <= sineStep * 1.02 && reached < 0.5 && abs(early.envelope(at: early.fadeOutStart - 1) - reached) < 1e-3,
                  String(format: "envelope at stop %.3f", reached))

            // Blocks join without a step: one big block equals many small ones.
            var one = ToneGenerator(sampleRate: sampleRate), many = ToneGenerator(sampleRate: sampleRate)
            let a = render(&one, seconds: 1, block: sr), b = render(&many, seconds: 1, block: 137)
            check("block size does not change the samples (\(tag))", a == b)
        }
    }

    /// The real node graph of `TonePlayer` (source node -> output node) in offline manual rendering mode.
    private static func offlineGraph() {
        let sampleRate = 48_000.0
        let shared = ToneShared()
        guard let source = TonePlayer.makeSourceNode(sampleRate: sampleRate, shared: shared) else { check("offline engine graph", false, "no format"); return }
        let engine = AVAudioEngine()
        do {
            try engine.enableManualRenderingMode(.offline, format: source.format, maximumFrameCount: 4096)
            engine.attach(source.node)
            engine.connect(source.node, to: engine.outputNode, format: source.format)
            try engine.start()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { check("offline engine graph", false, "no buffer"); return }
            var left: [Float] = [], right: [Float] = []
            var stopRequested = false
            while left.count < Int(2.5 * sampleRate) {
                if !stopRequested, left.count >= Int(1.5 * sampleRate) { shared.requestStop(); stopRequested = true }
                guard try engine.renderOffline(4096, to: buffer) == .success, let data = buffer.floatChannelData else { break }
                let n = Int(buffer.frameLength)
                left += UnsafeBufferPointer(start: data[0], count: n)
                right += UnsafeBufferPointer(start: data[1], count: n)
            }
            engine.stop()
            let sr = Int(sampleRate)
            let rms = rmsDBFS(left[(sr * 6 / 10)..<(sr * 14 / 10)])
            check("engine graph (offline): level at the output node −23.01 dBFS ±0.05", abs(rms + 23.0103) < 0.05, String(format: "%.4f dBFS", rms))
            check("engine graph (offline): left equals right", left == right && !left.isEmpty)
            let end = left[(2 * sr)...].map { abs($0) }.max() ?? 1
            let state = shared.read()
            check("engine graph (offline): stop request fades out and ends the tone", end == 0 && state.finished, "stop seen by the render thread, finished \(state.finished)")
            check("engine graph (offline): no click", maxStep(left) <= 0.1 * 2 * Double.pi * 400 / sampleRate * 1.02, String(format: "max step %.6f", maxStep(left)))
        } catch {
            check("offline engine graph", false, "\(error)")
        }
    }

    private static func math() {
        check("measured 0.840 V at −20 dBFS → 8.40 V full scale", abs(SPLMath.fullScaleVrms(measuredVrms: 0.84) - 8.4) < 1e-9)
        check("specs: 2 V DAC, +12 dB gain, 20 dB down → 0.796 V", abs(SPLMath.fullScaleVrms(dacVrms: 2, gainDB: 12, attenuationDB: 20) - 2 * pow(10, -8.0 / 20)) < 1e-9)
        check("macOS volume: 1 V max at −12 dB → 0.251 V", abs(SPLMath.fullScaleVrms(maxOutputVrms: 1, volumeAttenuationDB: -12) - pow(10, -12.0 / 20)) < 1e-9)
        let s = UserSensitivity(value: 90, unit: .dbPerMilliwatt, impedanceOhms: 100).sensitivity
        check("90 dB/mW at 100 Ω → 100 dB SPL/V", abs(s.dbSPLPerVolt - 100) < 1e-9)
        check("full-scale SPL: 1 V, 100 dB/V → 100 dB", abs(SPLMath.fullScaleSPL(fullScaleVrms: 1, sensitivity: s) - 100) < 1e-9)
        check("number entry: \"1,25\" and \" 840 \"", SPLMath.parse("1,25") == 1.25 && SPLMath.parse(" 840 ") == 840 && SPLMath.parse("abc") == nil && SPLMath.parse("") == nil)
        check("uncertainty: loaded 2, open 3, specs 4, guess 6 dB", SPLMath.uncertaintyDB(measuredLoaded: true) == 2 && SPLMath.uncertaintyDB(measuredLoaded: false) == 3
              && SPLMath.uncertaintyDB(specsAttenuationIsGuess: false) == 4 && SPLMath.uncertaintyDB(specsAttenuationIsGuess: true) == 6)
        check("total uncertainty: voltage 2 with sensitivity 3 → 3.6 (prints ± 4); 2 with 2 → 2.8; 6 with 3 → 6.7",
              abs(SPLMath.totalUncertaintyDB(voltage: 2, sensitivity: 3) - 13.0.squareRoot()) < 1e-12 && SPLController.uncertaintyText(SPLMath.totalUncertaintyDB(voltage: 2, sensitivity: 3)) == "± 4 dB"
              && abs(SPLMath.totalUncertaintyDB(voltage: 2, sensitivity: 2) - 8.0.squareRoot()) < 1e-12 && abs(SPLMath.totalUncertaintyDB(voltage: 6, sensitivity: 3) - 45.0.squareRoot()) < 1e-12)
        check("NIOSH: 88 dB(A) allows 4 h; half used → 2 h left", abs(SPLMath.secondsLeft(dose: 0.5, levelA: 88, criterionDB: 85, criterionHours: 8) - 2 * 3600) < 1e-6)
        check("dose line: under 1 h in minutes, under a day in hours, else 'the rest lasts all day'",
              SPLController.timeLeftText(.nioshDaily, dose: 0.9, levelA: 94) == "about 6 min left at this level"
              && SPLController.timeLeftText(.nioshDaily, dose: 0.5, levelA: 88) == "about 2 h left at this level"
              && SPLController.timeLeftText(.nioshDaily, dose: 0.52, levelA: 77) == "at 77 dB(A) the rest lasts all day"
              && SPLController.timeLeftText(.whoWeekly, dose: 0.31, levelA: 80) == "about 28 h left at this level"
              && SPLController.timeLeftText(.whoWeekly, dose: 0.31, levelA: 70) == "at 70 dB(A) the rest lasts all week"
              && SPLController.timeLeftText(.nioshDaily, dose: 1.0, levelA: 77) == "allowance used up",
              SPLController.timeLeftText(.nioshDaily, dose: 0.9, levelA: 94) + " | " + SPLController.timeLeftText(.whoWeekly, dose: 0.31, levelA: 80))
        check("pill: one name while the level is not set up", SPLPill.setUpTitle == "Level at ear: set up\u{2026}" && SPLPill.setUpTitleCompact == "set up")
        check("WHO: 83 dB(A) allows 20 h per week", abs(SPLMath.allowedSeconds(levelA: 83, criterionDB: 80, criterionHours: 40) - 20 * 3600) < 1e-6)
    }

    private static func ledger() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }

        var l = SPLDoseLedger()
        l.rollOver(now: date(2026, 9, 21), calendar: utc)          // a Monday
        check("ledger keys: day and ISO week", l.dayKey == "2026-09-21" && l.weekKey == "2026-W39", "\(l.dayKey) \(l.weekKey)")
        l.note(doseNIOSH: 0.30, doseWHOWeekly: 0.10, doseSeconds: 100, now: date(2026, 9, 21), calendar: utc)
        check("ledger: the first reading of an estimator is the baseline", l.nioshToday == 0 && l.whoWeek == 0)
        l.note(doseNIOSH: 0.40, doseWHOWeekly: 0.15, doseSeconds: 160, now: date(2026, 9, 21), calendar: utc)
        check("ledger: adds the growth", abs(l.nioshToday - 0.10) < 1e-9 && abs(l.whoWeek - 0.05) < 1e-9 && abs(l.listeningSecondsToday - 60) < 1e-9)
        l.estimatorChanged()
        l.note(doseNIOSH: 0.0, doseWHOWeekly: 0.0, doseSeconds: 0, now: date(2026, 9, 21), calendar: utc)
        l.note(doseNIOSH: 0.05, doseWHOWeekly: 0.02, doseSeconds: 30, now: date(2026, 9, 21), calendar: utc)
        check("ledger: a new estimator goes on from the stored dose", abs(l.nioshToday - 0.15) < 1e-9 && abs(l.whoWeek - 0.07) < 1e-9)
        l.note(doseNIOSH: 0.01, doseWHOWeekly: 0.01, doseSeconds: 5, now: date(2026, 9, 21), calendar: utc)
        check("ledger: an estimator that starts again is not a negative dose", abs(l.nioshToday - 0.15) < 1e-9)

        let data = try? JSONEncoder().encode(l)
        var back = data.flatMap { try? JSONDecoder().decode(SPLDoseLedger.self, from: $0) } ?? SPLDoseLedger()
        check("ledger: JSON round trip", abs(back.nioshToday - 0.15) < 1e-9 && back.dayKey == "2026-09-21")
        back.note(doseNIOSH: 0.5, doseWHOWeekly: 0.5, doseSeconds: 5, now: date(2026, 9, 21), calendar: utc)
        check("ledger: after a launch the first reading is the baseline again", abs(back.nioshToday - 0.15) < 1e-9)

        l.rollOver(now: date(2026, 9, 22), calendar: utc)
        check("day roll-over clears the NIOSH dose, keeps the week", l.nioshToday == 0 && abs(l.whoWeek - 0.07) < 1e-9 && l.dayKey == "2026-09-22")
        l.rollOver(now: date(2026, 9, 27), calendar: utc)          // Sunday: same ISO week
        check("Sunday is still the same ISO week", abs(l.whoWeek - 0.07) < 1e-9 && l.weekKey == "2026-W39")
        l.rollOver(now: date(2026, 9, 28), calendar: utc)          // Monday
        check("ISO-week roll-over clears the WHO dose", l.whoWeek == 0 && l.weekKey == "2026-W40")
        check("ISO week across the year end", SPLDoseLedger.weekKey(date(2027, 1, 3), timeZone: utc.timeZone) == "2026-W53"
              && SPLDoseLedger.weekKey(date(2027, 1, 4), timeZone: utc.timeZone) == "2027-W01")

        var b = SPLDoseLedger()
        b.rollOver(now: date(2026, 9, 21), calendar: utc)
        b.nioshToday = 0.49
        check("banner: nothing under 50%", b.takeBannerMark() == nil)
        b.nioshToday = 0.51
        check("banner: 50% once per day", b.takeBannerMark() == 50 && b.takeBannerMark() == nil)
        b.nioshToday = 1.02
        check("banner: 100% once per day", b.takeBannerMark() == 100 && b.takeBannerMark() == nil)
        b.rollOver(now: date(2026, 9, 22), calendar: utc)
        b.nioshToday = 0.6
        check("banner: shows again on a new day", b.takeBannerMark() == 50)
        // "OK" only hides the banner; the day mark is in the ledger, so a new launch on the same day stays quiet.
        var relaunched = (try? JSONEncoder().encode(b)).flatMap { try? JSONDecoder().decode(SPLDoseLedger.self, from: $0) } ?? SPLDoseLedger()
        relaunched.nioshToday = 0.7
        check("banner: stays dismissed after a new launch on the same day", relaunched.takeBannerMark() == nil)
    }

    /// D4: the calibration the estimator gets carries voltage ⊕ sensitivity; the stored preset keeps its voltage term.
    private static func totalUncertainty() {
        let savedMake = SPLWiring.makeEstimator, savedLookup = SPLWiring.lookupSensitivity
        defer { SPLWiring.makeEstimator = savedMake; SPLWiring.lookupSensitivity = savedLookup }
        var handed: [PlaybackCalibration] = []
        SPLWiring.makeEstimator = { _, _, calibration in handed.append(calibration); return SnapshotSPLStub(calibration: calibration) }
        var inLibrary = false
        SPLWiring.lookupSensitivity = { _ in inLibrary ? HeadphoneSensitivity(dbSPLPerVolt: 100, impedanceOhms: 50, source: "Library (self-check)") : nil }

        let store = SPLCalibrationStore(defaults: nil)
        let output = OutputVolumeState(deviceID: 0, deviceName: "DAC A", deviceUID: "selfcheck", volumeDB: nil, maxVolumeDB: nil, volumeScalar: nil, isMuted: false)
        let controller = SPLController(engine: AnalysisEngine(), selfCheckStore: store, doseStore: MemoryDoseStore(), output: output)
        controller.setHeadphone(HeadphoneCurve(name: "Headphone X", source: "self-check", frequenciesHz: [20, 20_000], levelsDB: [0, 0]))
        store.setUserSensitivity(UserSensitivity(value: 100, unit: .dbPerVolt, impedanceOhms: 50), headphone: "Headphone X")
        store.add(CalibrationPreset(calibration: PlaybackCalibration(name: "Multimeter", method: .measuredVoltage, fullScaleVrms: 2, uncertaintyDB: 2),
                                    deviceName: "DAC A", headphoneName: "Headphone X"))
        controller.rebuildForSelfCheck()
        let typed = handed.last?.uncertaintyDB ?? -1
        check("total: typed sensitivity → the estimator gets sqrt(2² + 3²) = 3.61 dB", abs(typed - 13.0.squareRoot()) < 1e-9, String(format: "%.3f dB", typed))
        check("total: the header says ± 4 dB, the parts line names both", controller.header.uncertaintyText == "± 4 dB" && controller.uncertaintyPartsText == "± 4 dB: voltage ± 2, sensitivity ± 3",
              controller.uncertaintyPartsText ?? "nil")
        check("total: the stored preset keeps its own voltage term (2 dB)", store.presets.first?.calibration.uncertaintyDB == 2)

        inLibrary = true
        controller.rebuildForSelfCheck()
        let library = handed.last?.uncertaintyDB ?? -1
        check("total: library sensitivity → sqrt(2² + 2²) = 2.83 dB", abs(library - 8.0.squareRoot()) < 1e-9, String(format: "%.3f dB", library))

        store.setUserSensitivity(UserSensitivity(value: 101, unit: .dbPerVolt, impedanceOhms: 50, measuredNote: "Measured by owner, self-check", uncertaintyDB: 1.5), headphone: "Headphone X")
        controller.rebuildForSelfCheck()
        let measured = handed.last?.uncertaintyDB ?? -1
        check("total: a measured sensitivity wins and brings its own term → sqrt(2² + 1.5²) = 2.5 dB; the total shrinks", abs(measured - 2.5) < 1e-9 && measured < typed, String(format: "%.3f dB", measured))
        check("total: still 2 dB in the store after three builds", store.presets.first?.calibration.uncertaintyDB == 2)
    }

    /// r7 item 1: in every state of the two toggles the blurb, the toggle help, the note and the result line of the
    /// calibration window name the SAME voltage term, and that term is the one `Save` stores.
    private static func calibrationTexts() {
        for method in CalibrationMethod.allCases {
            for loaded in [false, true] {
                for guess in [false, true] {
                    let term = CalibrationText.voltageTermDB(method, measuredLoaded: loaded, attenuationIsGuess: guess)
                    let expected: Double
                    switch method {
                    case .measure: expected = SPLMath.uncertaintyDB(measuredLoaded: loaded)
                    case .specs: expected = SPLMath.uncertaintyDB(specsAttenuationIsGuess: guess)
                    case .system: expected = SPLMath.systemVolumeUncertaintyDB
                    }
                    let text = SPLController.termText(term)
                    let blurb = CalibrationText.blurb(method, measuredLoaded: loaded, attenuationIsGuess: guess)
                    let footer = CalibrationText.resultLine(voltageDB: term, sensitivityDB: SPLMath.typedSensitivityUncertaintyDB)
                    let total = SPLController.uncertaintyText(SPLMath.totalUncertaintyDB(voltage: term, sensitivity: SPLMath.typedSensitivityUncertaintyDB))
                    var ok = term == expected && blurb.contains("about \(text) of the voltage") && footer == "voltage \(text) \u{00B7} level \(total)"
                    // The blurb leads with the term of NOW: the first "±" in it is that term.
                    if let first = blurb.range(of: "\u{00B1}") { ok = ok && blurb[first.lowerBound...].hasPrefix(text) } else { ok = false }
                    var shown = [blurb, footer]
                    if method == .specs {
                        let help = CalibrationText.guessHelp(isGuess: guess)
                        ok = ok && help.contains("This is \(guess ? "on" : "off"): the voltage counts with \(text).")
                        shown.append(help)
                        if guess { ok = ok && CalibrationText.guessNote.contains("counts with \(text) in this calibration"); shown.append(CalibrationText.guessNote) }
                    }
                    if method == .measure, !loaded {
                        ok = ok && CalibrationText.openMeasurementNote.hasSuffix("to \(text).")
                        shown.append(CalibrationText.openMeasurementNote)
                    }
                    check("calibration window: blurb, help, note and result line agree (\(method.rawValue), plugged in \(loaded), guess \(guess)) → \(text)", ok, ok ? "" : shown.joined(separator: " | "))
                }
            }
        }
        // No "±" figure of the window is typed in: every one in these sentences is a term of the one table.
        let table = Set([PlaybackCalibration.measuredToneUncertaintyDB, PlaybackCalibration.measuredOpenCircuitUncertaintyDB, PlaybackCalibration.specsUncertaintyDB,
                         PlaybackCalibration.specsWithGuessedAttenuationUncertaintyDB, PlaybackCalibration.systemVolumeUncertaintyDB].map { SPLController.termText($0) })
        let sentences = CalibrationMethod.allCases.flatMap { m in [false, true].flatMap { l in [false, true].map { g in CalibrationText.blurb(m, measuredLoaded: l, attenuationIsGuess: g) } } }
            + [CalibrationText.openMeasurementNote, CalibrationText.guessNote, CalibrationText.guessHelp(isGuess: true), CalibrationText.guessHelp(isGuess: false)]
        var strays: [String] = []
        for sentence in sentences {
            var rest = Substring(sentence)
            while let r = rest.range(of: "\u{00B1} ") {
                let figure = "\u{00B1} " + rest[r.upperBound...].prefix { $0.isNumber || $0 == "." } + " dB"
                if !table.contains(figure) { strays.append(figure) }
                rest = rest[r.upperBound...]
            }
        }
        check("calibration window: every ± figure in its sentences is a term of the one table", strays.isEmpty, strays.joined(separator: ", "))
        check("the one table: plugged in 2, open 3, specs 4, guess 6, macOS volume 3 dB",
              PlaybackCalibration.fromSpecs(name: "s", dacFullScaleVrms: 2, ampGainDB: 12, volumeAttenuationDB: 20).uncertaintyDB == SPLMath.uncertaintyDB(specsAttenuationIsGuess: true)
              && PlaybackCalibration.fromSpecs(name: "s", dacFullScaleVrms: 2, ampGainDB: 12, volumeAttenuationDB: 20, attenuationIsEstimated: false).uncertaintyDB == SPLMath.uncertaintyDB(specsAttenuationIsGuess: false)
              && PlaybackCalibration.fromMeasuredTone(name: "m", measuredVrms: 0.84, toneLevelDBFS: -20).uncertaintyDB == SPLMath.uncertaintyDB(measuredLoaded: true)
              && SPLMath.systemVolumeUncertaintyDB == 3)
    }

    /// One text for one number: the header, the popover and the calibration window print a total with the function the
    /// meters block prints it with (`EarUncertaintyText` of JoseonRender). A term keeps the half step of a measurement.
    private static func oneFormat() {
        let totals: [Double] = [2, 2.5, 8.0.squareRoot(), 13.0.squareRoot(), 3.5, 45.0.squareRoot(), 0, 12.4]
        check("one format: the header text of a total is the meters text of the same total",
              totals.allSatisfy { SPLController.uncertaintyText($0) == EarUncertaintyText.total($0) && SPLController.uncertaintyText($0, unit: false) == EarUncertaintyText.total($0, unit: false) }
              && SPLController.uncertaintyText(13.0.squareRoot()) == "\u{00B1} 4 dB" && SPLController.uncertaintyText(8.0.squareRoot()) == "\u{00B1} 3 dB",
              totals.map { SPLController.uncertaintyText($0) }.joined(separator: ", "))
        check("one format: a measured term keeps its half step (± 3.5 dB, as the measurement window printed it); fixed terms are whole",
              SPLController.termText(3.5) == "\u{00B1} 3.5 dB" && SPLController.termText(2) == "\u{00B1} 2 dB" && SPLController.termText(1.5, unit: false) == "\u{00B1} 1.5"
              && CalibrationText.sensitivityLine(termDB: 3.5).hasPrefix("Counts with \u{00B1} 3.5 dB in the level."))
    }

    /// D6: track card, table and events count clips from the same `LoudnessReading.clipCount`.
    private static func sessionClips() {
        let recorder = SessionRecorder(capacitySeconds: 600)
        let empty = SpectrumReading(frequencies: [], left: [], right: [], mid: [], side: [], peakHold: [], average: [])
        func reading(clips: Int, seconds: Double) -> LoudnessReading {
            var l = LoudnessReading()
            l.clipCount = clips; l.measuredSeconds = seconds; l.isIntegratedValid = true
            l.integratedLUFS = -14; l.momentaryLUFS = -14; l.shortTermLUFS = -14
            return l
        }
        // Track 1: the count grows 0 → 3 → 7 over five seconds, 10 frames per second.
        var last = LoudnessReading()
        for tenth in 0..<50 {
            let clips = tenth < 12 ? 0 : (tenth < 31 ? 3 : 7)
            last = reading(clips: clips, seconds: Double(tenth + 1) / 10)
            recorder.ingest(AnalysisFrame(spectrum: empty, loudness: last, isSilent: false), dt: 0.1)
        }
        let start = Date(timeIntervalSinceNow: -5), end = Date()
        let summary = TrackSummary(loudness: last, start: start, end: end, source: "Self-check", lowestStrongHz: 0)
        let snapshot = recorder.snapshot()
        let rows = SessionEventList.rows(from: snapshot).filter { $0.isAlert }.map(\.text)
        check("session: the events add up to the clip count of the track summary (7)", SessionEventList.clipTotal(in: snapshot) == 7 && summary?.clipCount == 7,
              "events \(SessionEventList.clipTotal(in: snapshot)), summary \(summary?.clipCount ?? -1), rows \(rows)")
        check("session: card, table and events use one word", summary?.clipText == "7" && TrackSummary.columns[7] == "Clips" && rows.allSatisfy { $0.hasPrefix("Clips ×") } && !rows.isEmpty)

        // The reset order: the summary is made from the newest reading of the measurement that ENDS, never from a
        // reading made after the reset zeroed the count.
        let cached = reading(clips: 5, seconds: 60), newer = reading(clips: 7, seconds: 60.08), afterReset = reading(clips: 0, seconds: 0.02)
        check("session: the last 100 ms of clips count (newest reading of the same measurement)", AppModel.closingReading(cached: cached, engineLatest: newer).clipCount == 7)
        check("session: a reading from after the reset never replaces the copy", AppModel.closingReading(cached: cached, engineLatest: afterReset).clipCount == 5)
    }

    private static func store() {
        let suite = "joseon.spl.selfcheck.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { check("store: defaults suite", false); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = SPLCalibrationStore(defaults: defaults)
        let wa33 = CalibrationPreset(calibration: PlaybackCalibration(name: "WA33 at 10 o'clock", method: .measuredVoltage, fullScaleVrms: 8.4, uncertaintyDB: 2),
                                     deviceName: "DAC A", headphoneName: "Headphone X")
        s.add(wa33)
        check("store: a saved preset is active for its device and headphone", s.activePreset(device: "DAC A", headphone: "Headphone X")?.id == wa33.id)
        check("store: another headphone deactivates it", s.activePreset(device: "DAC A", headphone: "Headphone Y") == nil && s.rememberedPreset(device: "DAC A")?.id == wa33.id)
        check("store: another output device deactivates it", s.activePreset(device: "MacBook Pro Speakers", headphone: "Headphone X") == nil)
        let jack = CalibrationPreset(calibration: PlaybackCalibration(name: "Jack", method: .systemVolume, fullScaleVrms: 1, uncertaintyDB: 3),
                                     deviceName: "External Headphones", headphoneName: "Headphone X")
        s.add(jack)
        check("store: each device remembers its own preset", s.activePreset(device: "DAC A", headphone: "Headphone X")?.id == wa33.id
              && s.activePreset(device: "External Headphones", headphone: "Headphone X")?.id == jack.id)
        s.setUserSensitivity(UserSensitivity(value: 86, unit: .dbPerMilliwatt, impedanceOhms: 45), headphone: "Headphone X")
        s.rename(wa33.id, to: "WA33 at 11 o'clock")
        s.doseStandard = .whoWeekly

        let again = SPLCalibrationStore(defaults: defaults)
        check("store: JSON in UserDefaults comes back", again.presets.count == 2 && again.activePreset(device: "DAC A", headphone: "Headphone X")?.name == "WA33 at 11 o'clock"
              && again.userSensitivity(headphone: "Headphone X")?.impedanceOhms == 45 && again.doseStandard == .whoWeekly)
        again.delete(wa33.id)
        check("store: delete removes the preset and its active mark", again.presets.count == 1 && again.rememberedPreset(device: "DAC A") == nil)
        check("store: suggested name is unique", s.suggestedName(device: "DAC A") != s.suggestedName(device: "DAC B") && s.suggestedName(device: "DAC A").hasPrefix("DAC A · "))
    }
    #endif
}
