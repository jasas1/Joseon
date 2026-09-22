import Foundation
import Combine
import JoseonCore
import JoseonCapture
import JoseonHeadphones

// "Measure your headphone…": the state machine behind the window.
//
// Threads:
// - main: every @Published value, every seam call except `MeasureCapturing.start/stop`.
// - `work` (serial, background): opening and closing the input (Core Audio calls that may block), and ALL analysis.
//   The `HeadphoneMeasurement` objects are touched on `work` only (the math module is not thread safe).
// - the real-time IO thread lives inside `JoseonCapture` (`MeasurementRecorder.append`); nothing here runs on it.
//
// Every capture has a token. A late callback of an aborted capture finds a newer token and does nothing.
// Every capture has a deadline: a run that does not end in time is aborted with a message. Nothing waits forever.

enum MeasureStep: Int, CaseIterable, Identifiable {
    case input, microphone, level, measure, result
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .input: return "Input"
        case .microphone: return "Microphone"
        case .level: return "Level check"
        case .measure: return "Measure"
        case .result: return "Result"
        }
    }
}

enum MeasureSide: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? "Left" : "Right" }
    var other: MeasureSide { self == .left ? .right : .left }
}

enum MeasureSaveChoice: String, Identifiable {
    case left, right, average
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .average: return "Average of left and right"
        }
    }
}

enum MeasureActivity: Equatable {
    case idle
    case levelCheck
    case noise
    case run(Int)
    case calibrator
    case analysing(String)

    var isBusy: Bool { self != .idle }
    var makesSound: Bool { if case .levelCheck = self { return true }; if case .run = self { return true }; return false }
}

struct MeasureMessage: Equatable {
    var text: String
    var isProblem = true
}

struct MeasureMeter: Equatable {
    var peakDB: Double = -.infinity
    var rmsDB: Double = -.infinity
    /// Largest peak since the capture started.
    var maxPeakDB: Double = -.infinity
    var clipped = false
}

struct LevelCheckOutcome: Equatable {
    enum Verdict: Equatable { case clipped, tooHot, good, low, nothing }
    var playLevelDBFS: Double
    var inputPeakDB: Double
    var verdict: Verdict

    var passed: Bool { verdict == .good || verdict == .low || verdict == .tooHot }

    static func verdict(inputPeakDB: Double, clipped: Bool) -> Verdict {
        if clipped || inputPeakDB >= -0.01 { return .clipped }
        if inputPeakDB < MeasureSignal.inputFloorDBFS { return .nothing }
        if inputPeakDB > MeasureSignal.inputTargetDBFS.upperBound { return .tooHot }
        if inputPeakDB < MeasureSignal.inputTargetDBFS.lowerBound { return .low }
        return .good
    }
}

struct MeasureRunRow: Equatable, Identifiable {
    var index: Int
    var delayMilliseconds: Double
    /// Noise floor of this run under the impulse peak, in dB (a positive number).
    var impulseSNRDB: Double
    var thdPercent: Double
    var inputPeakDB: Double
    /// Run-to-run agreement of all runs so far. Nil for the first run.
    var agreementDB: Double?
    /// Signal to noise at 1 kHz of the average so far.
    var snrAt1kHzDB: Double?
    var note: String?
    var id: Int { index }
}

struct LoadedCorrection: Equatable {
    var fileName: String
    var pointCount: Int
    var lowHz: Double
    var highHz: Double
    var sensFactorDB: Double?
    /// The correction on a coarse log grid 20 Hz … 20 kHz, for the sparkline.
    var sparkline: [Double]
}

struct MeasureSideResult {
    var measured: MeasuredHeadphone
    var derived: DerivedSensitivity?
}

/// What the sensitivity block shows.
enum MeasureSensitivityState: Equatable {
    /// One sentence per missing piece.
    case missing([String])
    case available(dbSPLPerVolt: Double, uncertaintyDB: Double, components: [DerivedSensitivity.Component], splAt1kHz: Double, driveVolts: Double, basis: String)
}

struct MeasureTiming {
    var pollSeconds = 0.05
    /// Recording goes on this long after the sweep ended.
    var tailSeconds = 0.6
    /// The input must deliver its first frames within this time.
    var startTimeoutSeconds = 4.0
    /// A capture may take its nominal length plus this. Then it is aborted.
    var watchdogMarginSeconds = 5.0
    var calibratorSeconds = 3.0
    /// 1 = a second of signal takes a second. 0 for the fakes, where a "played" sweep takes no time at all.
    var nominalScale = 1.0

    static let live = MeasureTiming()
    static let fake = MeasureTiming(pollSeconds: 0.004, tailSeconds: 0, startTimeoutSeconds: 0.4, watchdogMarginSeconds: 0.6, calibratorSeconds: 3.0, nominalScale: 0)
}

/// Everything the controller needs from the rest of the app, as values and closures: the self-check replaces all of it.
struct MeasureEnvironment {
    var input: MeasureInputProviding
    var player: SignalPlaying
    var timing = MeasureTiming.live
    /// The headphone selected in the picker (the AutoEq curve to compare with), and the target curve.
    var headphone: () -> HeadphoneCurve?
    var target: () -> HeadphoneCurve?
    /// The ACTIVE level calibration as it counts now, with the name of its output device. Nil without one.
    var playback: () -> (calibration: PlaybackCalibration, deviceName: String)?
    var knownImpedanceOhms: () -> Double?
    /// Copies the CSV into the user curve folder, reloads the library and selects the curve. Returns an error text.
    var importCurve: (URL) -> String?
    var curveExists: (String) -> Bool
    var storeSensitivity: (UserSensitivity, String) -> Void
    /// Name of the default output device, for the text of the level check. Empty when unknown.
    var outputName: () -> String = { "" }
    /// Snapshot mode: the input and the player are fakes, and the window says so on every step.
    var isLabelledFake = false
}

final class MeasureController: ObservableObject {
    let environment: MeasureEnvironment

    // Steps
    @Published var step = MeasureStep.input
    // Step 1
    @Published private(set) var devices: [MeasurementInputDevice] = []
    @Published var deviceUID = "" { didSet { if deviceUID != oldValue { deviceChanged() } } }
    @Published var channel = 0 { didSet { if channel != oldValue { inputChanged() } } }
    @Published private(set) var permission = MicrophonePermission.Status.notDetermined
    // Step 2
    @Published private(set) var micInfo: LoadedCorrection?
    @Published private(set) var micError: String?
    @Published private(set) var couplerInfo: LoadedCorrection?
    @Published private(set) var couplerError: String?
    @Published var rigNote = ""
    /// The kind of rig decides the largest term of the measured sensitivity's uncertainty.
    @Published var rig: MeasurementRig = .flatPlate
    @Published var calibratorText = "" { didSet { if calibratorText != oldValue, !results.isEmpty { rebuildResults() } } }
    // Step 3
    /// The safety checkbox "on the rig, not on my head". SINGLE USE: it starts unticked with every window (the
    /// controller lives as long as the window), and the controller clears it when a sweep starts, so EVERY sound
    /// needs a new tick. A new side, a new play level and a new step clear it too.
    @Published var rigConfirmed = false
    @Published private(set) var levelIndex = 0
    @Published private(set) var levelCheck: LevelCheckOutcome?
    /// Index into `MeasureSignal.levelSteps` of the highest level with a passed check. −1 = none yet.
    @Published private(set) var passedLevelIndex = -1
    // Step 4
    @Published var side = MeasureSide.left { didSet { if side != oldValue { sideChanged() } } }
    @Published var runsWanted = 4
    @Published private(set) var noiseRMSDB: Double?
    @Published private(set) var runs: [MeasureRunRow] = []
    @Published private(set) var liveQuality: MeasurementQuality?
    // Step 5
    @Published private(set) var results: [MeasureSide: MeasureSideResult] = [:]
    @Published var smoothing = SweepAnalysis.OctaveSmoothing.twelfth { didSet { if smoothing != oldValue { rebuildResults() } } }
    @Published var impedanceText = "" { didSet { if impedanceText != oldValue { rebuildResults() } } }
    @Published private(set) var sensitivityStoredFor: String?
    @Published private(set) var savedName: String?
    // Everywhere
    @Published private(set) var activity = MeasureActivity.idle
    @Published private(set) var meter = MeasureMeter()
    @Published private(set) var progress: Double = 0
    @Published var message: MeasureMessage?

    // Main-thread state
    private var micCalibration: MicCalibration?
    private var coupler: CouplerCorrection?
    private var token = 0
    private var capture: MeasureCapturing?
    private var pollTimer: Timer?
    // `work`-queue state
    private let work = DispatchQueue(label: "joseon.measure.work", qos: .userInitiated)
    private var sessions: [MeasureSide: HeadphoneMeasurement] = [:]
    private var closed = false
    /// Self-check only: set when an analysis block found itself on the main thread. It never should.
    private(set) var analysisRanOnMainThread = false

    init(environment: MeasureEnvironment) {
        self.environment = environment
        permission = environment.input.permission
        if let z = environment.knownImpedanceOhms() { impedanceText = NumberText.signed(z, decimals: 0) }
        refreshDevices()
    }

    // MARK: - Step 1: input

    /// Reads the device list (properties only: no permission needed, nothing is opened).
    func refreshDevices() {
        permission = environment.input.permission
        let all = environment.input.devices()
        devices = all.filter { !Self.listedLast($0) } + all.filter(Self.listedLast)
        if !devices.contains(where: { $0.uid == deviceUID }) {
            // A USB measurement microphone is the likely choice. Never preselect a virtual or aggregate device.
            deviceUID = devices.first { $0.transport == .usb }?.uid ?? devices.first { !Self.listedLast($0) }?.uid ?? ""
        }
    }

    static func listedLast(_ device: MeasurementInputDevice) -> Bool { device.transport == .virtual || device.transport == .aggregate }

    var selectedDevice: MeasurementInputDevice? { devices.first { $0.uid == deviceUID } }

    private func deviceChanged() {
        if channel >= (selectedDevice?.channelCount ?? 1) { channel = 0 }
        inputChanged()
    }

    /// Another input: the level check and the runs made with the old one do not count.
    private func inputChanged() {
        if activity.isBusy { abort("The input changed, so Joseon stopped the run.") }
        levelIndex = 0
        passedLevelIndex = -1
        levelCheck = nil
        resetAll()
    }

    /// THE ONLY CALLER of `requestPermission`. It is the action of the "Allow microphone…" button and of nothing else.
    func requestPermissionFromButton() {
        environment.input.requestPermission { [weak self] _ in
            guard let self else { return }
            self.permission = self.environment.input.permission
        }
    }

    func openSystemSettings() { environment.input.openSystemSettings() }

    // MARK: - Step 2: microphone

    func loadMicCalibration(text: String, fileName: String) {
        do {
            let parsed = try MicCalibration.parse(text: text, name: fileName, source: fileName)
            micCalibration = parsed
            micInfo = Self.info(fileName: fileName, frequencies: parsed.frequenciesHz, sens: parsed.sensFactorDB) { parsed.correctionDB(onGrid: $0) }
            micError = nil
        } catch {
            micError = "Joseon could not read a calibration from “\(fileName)”. It needs lines with a frequency in Hz and a level in dB (the miniDSP and REW formats work)."
        }
        resetAll()
    }

    func clearMicCalibration() { micCalibration = nil; micInfo = nil; micError = nil; resetAll() }

    func loadCoupler(text: String, fileName: String) {
        do {
            let parsed = try CouplerCorrection.parse(text: text, name: fileName, source: fileName)
            coupler = parsed
            couplerInfo = Self.info(fileName: fileName, frequencies: parsed.frequenciesHz, sens: nil) { parsed.correctionDB(onGrid: $0) }
            couplerError = nil
        } catch {
            couplerError = "Joseon could not read a correction from “\(fileName)”. It needs lines with a frequency in Hz and a level in dB."
        }
        resetAll()
    }

    func clearCoupler() { coupler = nil; couplerInfo = nil; couplerError = nil; resetAll() }

    func loadFile(_ url: URL, asCoupler: Bool) {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        if asCoupler { loadCoupler(text: text, fileName: url.lastPathComponent) } else { loadMicCalibration(text: text, fileName: url.lastPathComponent) }
    }

    static let sparklineGrid: [Double] = (0..<61).map { 20 * pow(1000, Double($0) / 60) }

    private static func info(fileName: String, frequencies: [Double], sens: Double?, correction: ([Double]) -> [Double]) -> LoadedCorrection {
        LoadedCorrection(fileName: fileName, pointCount: frequencies.count, lowHz: frequencies.first ?? 0, highHz: frequencies.last ?? 0,
                         sensFactorDB: sens, sparkline: correction(sparklineGrid))
    }

    /// The calibrator reading the user typed, in dBFS RMS. A usable reading is a negative, finite number.
    var calibratorReadingDBFS: Double? {
        guard let v = SPLMath.parse(calibratorText), v < 0, v > -120 else { return nil }
        return v
    }

    /// What ties dBFS to dB SPL: a calibrator reading wins over the header of the calibration file.
    var absoluteLevel: AbsoluteLevel.Result {
        if let reading = calibratorReadingDBFS { return AbsoluteLevel.scale(for: .calibrator(readingDBFS: reading)) }
        return AbsoluteLevel.scale(for: .fromMicCalibration(micCalibration))
    }

    /// Records a few seconds with NOTHING playing and writes the RMS level into the calibrator field.
    func readCalibrator() {
        guard ready(for: .calibrator) else { return }
        activity = .calibrator
        let seconds = environment.timing.calibratorSeconds
        startCapture(play: nil, nominalSeconds: seconds, neededFrames: { Int(seconds * $0) }) { [weak self] recording in
            guard let self else { return }
            self.activity = .idle
            // The last two thirds: the first second may hold the click of the calibrator's switch.
            let tail = recording.samples.suffix(recording.samples.count * 2 / 3)
            let rms = MeasureSignal.rmsDB(tail)
            if recording.clipped {
                self.message = MeasureMessage(text: "The input clipped while Joseon read the calibrator. Lower the gain of the microphone input and read again.")
            } else if rms.isFinite, rms > -80 {
                self.calibratorText = NumberText.signed(rms, decimals: 2)
                self.message = MeasureMessage(text: "Read \(NumberText.signed(rms, decimals: 2)) dBFS RMS. From here on, do not touch the gain of the microphone input.", isProblem: false)
            } else {
                self.message = MeasureMessage(text: "Joseon heard almost nothing. Check that the calibrator is on, sits on the microphone, and that the right input channel is selected.")
            }
        }
    }

    // MARK: - Step 3: level check

    var playLevelDBFS: Double { MeasureSignal.levelSteps[levelIndex] }
    var canRaiseLevel: Bool {
        !activity.isBusy && levelIndex < MeasureSignal.levelSteps.count - 1 && passedLevelIndex >= levelIndex && levelCheck?.verdict != .tooHot
    }
    var canLowerLevel: Bool { !activity.isBusy && levelIndex > 0 }

    /// One 6 dB step up. Only after a passed check at the level before: no way to skip a step.
    func raiseLevel() {
        guard canRaiseLevel else { return }
        rigConfirmed = false
        levelIndex += 1
        levelCheck = nil
        resetSession()
    }

    func lowerLevel() {
        guard canLowerLevel else { return }
        rigConfirmed = false
        levelIndex -= 1
        levelCheck = nil
        resetSession()
    }

    /// The level check of the CURRENT play level passed (no clip, something arrived).
    var levelCheckPassed: Bool { passedLevelIndex >= levelIndex && (levelCheck?.passed ?? false) && levelCheck?.playLevelDBFS == playLevelDBFS }

    func startLevelCheck(permit: TonePlayPermit) {
        guard ready(for: .levelCheck), permitIsGood(permit) else { return }
        guard let buffer = playBuffer() else { return }
        rigConfirmed = false        // single use: the next sweep needs a new tick
        activity = .levelCheck
        let level = playLevelDBFS
        startCapture(play: (buffer, permit), nominalSeconds: MeasureSignal.sweepSeconds + environment.timing.tailSeconds, neededFrames: { _ in 1 }) { [weak self] recording in
            guard let self else { return }
            self.activity = .idle
            let peak = MeasureSignal.peakDB(recording.samples)
            let verdict = LevelCheckOutcome.verdict(inputPeakDB: peak, clipped: recording.clipped)
            let outcome = LevelCheckOutcome(playLevelDBFS: level, inputPeakDB: peak, verdict: verdict)
            self.levelCheck = outcome
            if outcome.passed { self.passedLevelIndex = max(self.passedLevelIndex, self.levelIndex) } else { self.passedLevelIndex = min(self.passedLevelIndex, self.levelIndex - 1) }
        }
    }

    // MARK: - Step 4: measure

    var noiseDone: Bool { noiseRMSDB != nil }
    var sideIsComplete: Bool { runs.count >= runsWanted }

    /// Same length as a run, nothing plays.
    func recordNoise() {
        guard ready(for: .noise) else { return }
        guard levelCheckPassed else { message = MeasureMessage(text: "Do the level check first."); return }
        activity = .noise
        let side = self.side, level = playLevelDBFS, smoothing = self.smoothing, mic = micCalibration, coupler = self.coupler
        let seconds = MeasureSignal.sweepSeconds + MeasureSignal.runPaddingSeconds
        startCapture(play: nil, nominalSeconds: seconds,
                     neededFrames: { MeasureSignal.runFrames(sweepFrames: Int((MeasureSignal.sweepSeconds * $0).rounded()), sampleRate: $0) }) { [weak self] recording in
            guard let self else { return }
            if recording.clipped {
                self.activity = .idle
                self.message = MeasureMessage(text: "The input clipped while nothing played. Something loud reached the microphone, or the input gain is far too high. Record the room noise again.")
                return
            }
            self.activity = .analysing("Preparing the analysis…")
            let current = self.token
            self.work.async {
                if Thread.isMainThread { self.analysisRanOnMainThread = true }
                let reference = MeasureSignal.sweep(sampleRate: recording.sampleRate, levelDBFS: level)
                var options = SweepAnalysis.Options()
                options.smoothing = smoothing
                let session = HeadphoneMeasurement(sweep: reference, options: options, micCalibration: mic, coupler: coupler)
                let frames = MeasureSignal.runFrames(sweepFrames: reference.samples.count, sampleRate: recording.sampleRate)
                session.setNoiseSegment(MeasureSignal.fitted(recording.samples, frames: frames))
                let rms = MeasureSignal.rmsDB(recording.samples[...])
                DispatchQueue.main.async {
                    guard current == self.token, !self.closed else { return }
                    self.work.async { self.sessions[side] = session }
                    self.runs = []
                    self.liveQuality = nil
                    self.results[side] = nil
                    self.noiseRMSDB = rms
                    self.activity = .idle
                }
            }
        }
    }

    func startRun(permit: TonePlayPermit) {
        let index = runs.count + 1
        guard ready(for: .run(index)), permitIsGood(permit) else { return }
        guard levelCheckPassed else { message = MeasureMessage(text: "Do the level check first."); return }
        guard noiseDone else { message = MeasureMessage(text: "Record the room noise first."); return }
        guard !sideIsComplete else { return }
        guard let buffer = playBuffer() else { return }
        rigConfirmed = false        // single use: the next run needs a new tick
        activity = .run(index)
        let side = self.side
        startCapture(play: (buffer, permit), nominalSeconds: MeasureSignal.sweepSeconds + environment.timing.tailSeconds, neededFrames: { _ in 1 }) { [weak self] recording in
            guard let self else { return }
            let peak = MeasureSignal.peakDB(recording.samples)
            // A clipped recording never reaches the average.
            if recording.clipped || peak >= -0.01 {
                self.activity = .idle
                self.levelCheck = LevelCheckOutcome(playLevelDBFS: self.playLevelDBFS, inputPeakDB: peak, verdict: .clipped)
                self.passedLevelIndex = self.levelIndex - 1
                self.message = MeasureMessage(text: "The input clipped in run \(index), so Joseon dropped that run. Go back to the level check: lower the play level or the gain of the microphone input, and check again.")
                return
            }
            if peak < MeasureSignal.inputFloorDBFS {
                self.activity = .idle
                self.message = MeasureMessage(text: "Almost nothing arrived in run \(index) (input peak \(Self.dbText(peak)) dBFS), so Joseon dropped that run. Check the cable, the input channel and the seat of the headphone.")
                return
            }
            self.activity = .analysing("Analysing run \(index)…")
            let current = self.token
            self.work.async {
                if Thread.isMainThread { self.analysisRanOnMainThread = true }
                guard let session = self.sessions[side] else { return }
                var row: MeasureRunRow?
                var quality: MeasurementQuality?
                var problem: String?
                if abs(session.sweep.sampleRate - recording.sampleRate) > 0.5 {
                    problem = "The sample rate of the input changed from \(Int(session.sweep.sampleRate)) Hz to \(Int(recording.sampleRate)) Hz. Start this side again."
                } else {
                    let sweepFrames = session.sweep.samples.count
                    let frames = MeasureSignal.runFrames(sweepFrames: sweepFrames, sampleRate: recording.sampleRate)
                    let summary = session.addRun(MeasureSignal.fitted(recording.samples, frames: frames))
                    let partial = session.result(name: "partial")
                    quality = partial?.quality
                    var note: String?
                    if summary.delaySamples + sweepFrames > min(frames, recording.samples.count) {
                        note = "The delay was long (\(Int((summary.delaySeconds * 1000).rounded())) ms): the end of the sweep may be missing. If the top of the curve looks wrong, start this side again."
                    } else if recording.overflowed {
                        note = "The recording was longer than the buffer. The sweep itself is complete."
                    }
                    row = MeasureRunRow(index: index, delayMilliseconds: summary.delaySeconds * 1000, impulseSNRDB: -summary.noiseFloorDB,
                                        thdPercent: summary.thdPercent, inputPeakDB: peak,
                                        agreementDB: (quality?.runs ?? 0) > 1 ? quality.map { Double($0.agreementDB) } : nil,
                                        snrAt1kHzDB: quality?.snrDB(atHz: 1000).map(Double.init), note: note)
                }
                DispatchQueue.main.async {
                    guard current == self.token, !self.closed else { return }
                    self.activity = .idle
                    if let problem { self.message = MeasureMessage(text: problem); return }
                    if let row { self.runs.append(row) }
                    self.liveQuality = quality
                    if self.sideIsComplete { self.rebuildResults() }
                }
            }
        }
    }

    /// "Start this side again", and a new play level: noise, runs and result of the CURRENT side are dropped.
    func resetSession() {
        if activity.isBusy { abort(nil) }
        token += 1
        let side = self.side
        work.async { self.sessions[side] = nil }
        runs = []
        liveQuality = nil
        noiseRMSDB = nil
        results[side] = nil
        savedName = nil
    }

    /// Another input, another microphone file, another coupler file: what was measured before is a different
    /// measurement, so both sides are dropped.
    private func resetAll() {
        if activity.isBusy { abort(nil) }
        token += 1
        work.async { self.sessions.removeAll() }
        runs = []
        liveQuality = nil
        noiseRMSDB = nil
        results = [:]
        savedName = nil
        sensitivityStoredFor = nil
    }

    /// The other side goes on the rig. The finished side keeps its result; the new side starts with its own room
    /// noise. (Recording the noise of a side again replaces what that side had.)
    private func sideChanged() {
        if activity.isBusy { abort(nil) }
        rigConfirmed = false        // the other cup goes on the rig: confirm again
        token += 1
        runs = []
        liveQuality = nil
        noiseRMSDB = nil
    }

    func measureOtherSide() {
        side = side.other
        message = nil
        step = .measure
    }

    // MARK: - Step 5: result

    var impedanceOhms: Double? {
        guard let z = SPLMath.parse(impedanceText), z > 1, z < 5000 else { return nil }
        return z
    }

    /// Every piece the sensitivity needs and does not have, one sentence each. Empty = available.
    var missingForSensitivity: [String] {
        var out: [String] = []
        if let reason = absoluteLevel.unavailableReason {
            out.append("No absolute level. \(reason) To add it: load a calibration file with a sensitivity header, or enter the reading of a 94 dB calibrator in step 2.")
        }
        if environment.headphone() == nil {
            out.append("No headphone is selected in the main window. A level calibration belongs to one headphone.")
        } else if environment.playback() == nil {
            out.append("No active level calibration. Joseon must know how many volts reach the headphone: make one with “Calibrate level at the ear…” (the multimeter method is the exact one), with the amplifier knob where it is for this measurement.")
        }
        if impedanceOhms == nil { out.append("The impedance of the headphone is missing. Enter it below (from the data sheet).") }
        return out
    }

    /// The same pieces in a few words each, for the note in the saved curve file.
    var missingForSensitivityShort: [String] {
        var out: [String] = []
        if !absoluteLevel.isAvailable { out.append("No absolute level reference (no calibrator reading, no sensitivity factor in the microphone file).") }
        if environment.headphone() == nil || environment.playback() == nil { out.append("No active level calibration, so the volts at the headphone are unknown.") }
        if impedanceOhms == nil { out.append("No impedance entered.") }
        return out
    }

    private var sensitivityContext: HeadphoneMeasurement.SensitivityContext? {
        guard missingForSensitivity.isEmpty, let playback = environment.playback(), let z = impedanceOhms else { return nil }
        return HeadphoneMeasurement.SensitivityContext(playback: playback.calibration, absoluteLevel: absoluteLevel, impedanceOhms: z, rig: rig)
    }

    /// Builds the result of every measured side again (smoothing, impedance, calibrator reading may have changed).
    func rebuildResults() {
        let context = sensitivityContext
        let missingShort = missingForSensitivityShort
        let smoothing = self.smoothing
        let name = environment.headphone()?.name ?? "Headphone"
        let current = token
        work.async {
            var built: [MeasureSide: MeasureSideResult] = [:]
            for (side, session) in self.sessions where session.runCount > 0 {
                session.options.smoothing = smoothing
                guard var measured = session.result(name: "\(name) (measured, \(side.title.lowercased()))", source: "Joseon measurement", sensitivity: context) else { continue }
                // Without a context the math module can only say "nothing was given". The app knows which piece is
                // missing, and the sentence goes into the saved file: say it exactly.
                if context == nil {
                    measured.quality.warnings = measured.quality.warnings.map {
                        $0.hasPrefix("No sensitivity was derived") ? "No sensitivity was derived. " + missingShort.joined(separator: " ") : $0
                    }
                }
                built[side] = MeasureSideResult(measured: measured, derived: measured.derivedSensitivity)
            }
            DispatchQueue.main.async {
                guard current == self.token, !self.closed else { return }
                self.results = built
            }
        }
    }

    var availableSaveChoices: [MeasureSaveChoice] {
        var out: [MeasureSaveChoice] = []
        if results[.left] != nil { out.append(.left) }
        if results[.right] != nil { out.append(.right) }
        if out.count == 2 { out.append(.average) }
        return out
    }

    /// One side, or the average of both. The average is the mean of the two dB curves (both are 0 dB at 1 kHz).
    func result(for choice: MeasureSaveChoice) -> MeasureSideResult? {
        switch choice {
        case .left: return results[.left]
        case .right: return results[.right]
        case .average:
            guard let l = results[.left], let r = results[.right] else { return nil }
            return Self.average(l, r)
        }
    }

    /// The curve, the quality and the warnings come from `MeasuredHeadphone.average`: one bass roll-off note for the
    /// averaged curve, not one per side. The sensitivity is averaged here.
    static func average(_ l: MeasureSideResult, _ r: MeasureSideResult) -> MeasureSideResult {
        var m = MeasuredHeadphone.average(l.measured, r.measured)
        var derived: DerivedSensitivity?
        if let a = l.derived, let b = r.derived {
            var d = a
            d.sensitivity.dbSPLPerVolt = (a.sensitivity.dbSPLPerVolt + b.sensitivity.dbSPLPerVolt) / 2
            d.uncertaintyDB = max(a.uncertaintyDB, b.uncertaintyDB)
            d.measuredSPLAt1kHz = (a.measuredSPLAt1kHz + b.measuredSPLAt1kHz) / 2
            derived = d
        }
        m.derivedSensitivity = derived
        m.sensitivity = derived?.sensitivity
        return MeasureSideResult(measured: m, derived: derived)
    }

    /// The best single answer on screen: the average when both sides exist, else the one side.
    var headlineChoice: MeasureSaveChoice? { availableSaveChoices.last }

    /// For example "± 3.5 dB (rig-limited)": the rounded-up total and the term that dominates it.
    var sensitivityUncertaintyHeadline: String {
        guard let choice = headlineChoice, let d = result(for: choice)?.derived else { return "" }
        return d.uncertaintyHeadline
    }

    var sensitivityState: MeasureSensitivityState {
        let missing = missingForSensitivity
        guard missing.isEmpty else { return .missing(missing) }
        guard let choice = headlineChoice, let d = result(for: choice)?.derived else {
            return .missing(["The measurement gave no usable level at 1 kHz."])
        }
        return .available(dbSPLPerVolt: d.sensitivity.dbSPLPerVolt, uncertaintyDB: d.printedUncertaintyDB, components: d.uncertaintyComponents,
                          splAt1kHz: d.measuredSPLAt1kHz, driveVolts: d.driveVoltsRMS,
                          basis: choice == .average ? "average of left and right" : "\(choice.title.lowercased()) side")
    }

    static func dateText(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    var trimmedRigNote: String { rigNote.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// "Measured by owner, 2026-09-21, flat plate, foam seal".
    var sensitivitySourceText: String {
        "Measured by owner, \(Self.dateText())" + (trimmedRigNote.isEmpty ? ", rig not described" : ", \(trimmedRigNote)")
    }

    /// Stores the derived value as the user sensitivity of the SELECTED headphone.
    func useSensitivity() {
        guard case .available(let value, let uncertainty, _, _, _, _) = sensitivityState, let z = impedanceOhms,
              let headphone = environment.headphone()?.name else { return }
        let entry = UserSensitivity(value: (value * 10).rounded() / 10, unit: .dbPerVolt, impedanceOhms: z,
                                    measuredNote: sensitivitySourceText, uncertaintyDB: (uncertainty * 10).rounded() / 10)
        guard entry.isValid else {
            message = MeasureMessage(text: "\(NumberText.signed(value, decimals: 1)) dB SPL/V is outside the range Joseon accepts for a headphone (40 … 150). Check the calibrator reading and the level calibration.")
            return
        }
        environment.storeSensitivity(entry, headphone)
        sensitivityStoredFor = headphone
    }

    var suggestedSaveName: String {
        "\(environment.headphone()?.name ?? "My headphone") measured \(Self.dateText())"
    }

    /// A name that is also a file name.
    static func fileSafe(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = name.components(separatedBy: bad).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(trimmed.prefix(120))
    }

    func curveExists(named name: String) -> Bool { environment.curveExists(Self.fileSafe(name)) }

    // MARK: Leak guard

    /// Bass of the measured curve against the published curve of the selected model.
    struct LeakWarning: Equatable {
        /// Mean of measured − published over `LeakWarning.band`, both curves at 0 dB at 1 kHz. Negative = less bass.
        var meanDifferenceDB: Double
        static let band: ClosedRange<Float> = 30...100
        /// More than this under the published curve (mean) reads as a seal leak on the rig.
        static let limitDB = 6.0

        var deficitDB: Int { Int((-meanDifferenceDB).rounded()) }
        var notice: String { "Bass is \(deficitDB) dB under the published curve: likely a seal leak on the rig" }
        var detail: String {
            "Mean over 30 – 100 Hz. Seat the cup again (hair, glasses arms, a gap in the foam or at the plate) and measure once more. An open-back planar can really roll off, but seldom this much against its own published curve."
        }
        var saveQuestion: String {
            "Save a curve with a likely seal leak? As your curve it would make every at-the-ear view show \(deficitDB) dB less bass than this headphone has on a sealed rig."
        }
    }

    /// Mean of measured − published over 30 – 100 Hz. Nil when the measured curve has no point in the band.
    static func bassDifferenceDB(measured: HeadphoneCurve, published: HeadphoneCurve) -> Double? {
        let reference = CurveInterpolator(curve: published.normalizedTo1kHz())
        let own = measured.normalizedTo1kHz()
        var sum = 0.0, count = 0.0
        for (f, v) in zip(own.frequenciesHz, own.levelsDB) where LeakWarning.band.contains(f) && v.isFinite {
            sum += Double(v - reference.level(atHz: f)); count += 1
        }
        return count > 0 ? sum / count : nil
    }

    /// The leak card of the result page. It honours the SAME noise gate as the bass roll-off note of the quality
    /// list (`MeasuredHeadphone.snrThresholdDB`, through `bassIsMeasured`): with no signal-to-noise figure at 40 Hz,
    /// or one under the gate, the bass is the noise floor, not the headphone. Then there is no leak card and no save
    /// question; the note that says "limited by noise" stays the one verdict.
    static func leakWarning(measured: HeadphoneCurve, published: HeadphoneCurve?, snrAt40Hz: Double?) -> LeakWarning? {
        guard MeasuredHeadphone.bassIsMeasured(snrAt40Hz: snrAt40Hz) else { return nil }
        guard let published, let mean = bassDifferenceDB(measured: measured, published: published), mean < -LeakWarning.limitDB else { return nil }
        return LeakWarning(meanDifferenceDB: mean)
    }

    /// The leak guard for the curve a save would write. Nil without a selected model: there is nothing to compare with.
    func leakWarning(for choice: MeasureSaveChoice) -> LeakWarning? {
        guard let measured = result(for: choice)?.measured else { return nil }
        return Self.leakWarning(measured: measured.curve, published: environment.headphone(),
                                snrAt40Hz: measured.quality.snrDB(atHz: 40).map(Double.init))
    }

    /// What a save needs the user to confirm first. The view asks, naming the risk; `save` refuses without the answer.
    struct SaveConfirmation: Equatable {
        var leak: LeakWarning?
        /// The file-safe name of the stored curve the save would replace.
        var replaces: String?

        var isNeeded: Bool { leak != nil || replaces != nil }
        var overwriteQuestion: String? {
            replaces.map { "Replace the stored curve “\($0)”? Joseon deletes the old file and writes this measurement in its place. The old curve can not be brought back." }
        }
        /// One button for everything that applies.
        var confirmTitle: String {
            switch (leak != nil, replaces != nil) {
            case (true, true): return "Save with the leak, replacing the existing curve"
            case (true, false): return "Save with the leak"
            default: return "Save, replacing the existing curve"
            }
        }
    }

    func saveConfirmation(choice: MeasureSaveChoice, name: String) -> SaveConfirmation {
        let safe = Self.fileSafe(name)
        return SaveConfirmation(leak: leakWarning(for: choice), replaces: !safe.isEmpty && environment.curveExists(safe) ? safe : nil)
    }

    /// Writes ONLY the curve CSV: to a temporary file, from there through `HeadphoneLibrary.importCurve` into the
    /// user curve folder. No recording and no impulse response is written anywhere.
    /// With a leak warning the save needs `confirmedLeak`; when a curve with this name is stored already it needs
    /// `confirmedOverwrite` (the import deletes the old file). The view asks first, naming the risk. Each risk needs
    /// its own yes: with both, one of the two is not enough, and a refused save writes nothing.
    func save(choice: MeasureSaveChoice, name: String, confirmedLeak: Bool = false, confirmedOverwrite: Bool = false) {
        let safe = Self.fileSafe(name)
        guard !safe.isEmpty else { message = MeasureMessage(text: "Give the curve a name first."); return }
        let needs = saveConfirmation(choice: choice, name: name)
        var open: [String] = []
        if let leak = needs.leak, !confirmedLeak { open.append(leak.notice + ".") }
        if needs.replaces != nil, !confirmedOverwrite { open.append("A curve named “\(safe)” exists and the save would replace it.") }
        guard open.isEmpty else {
            message = MeasureMessage(text: open.joined(separator: " ") + " Joseon did not save the curve: confirm the save first.")
            return
        }
        guard var measured = result(for: choice)?.measured else { return }
        measured.curve.name = safe
        if !trimmedRigNote.isEmpty { measured.method += "; rig: \(trimmedRigNote)" }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("joseon-measure-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(safe + ".csv")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try measured.csv().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            message = MeasureMessage(text: "Joseon could not write the curve file: \(error.localizedDescription)")
            return
        }
        if let problem = environment.importCurve(url) {
            message = MeasureMessage(text: problem)
        } else {
            savedName = safe
            message = nil
        }
    }

    // MARK: - Steps

    /// Why the user can not go on from `step`, or nil.
    func blocker(after step: MeasureStep) -> String? {
        switch step {
        case .input:
            if selectedDevice == nil { return "Pick the input of the measurement microphone." }
            if permission != .authorized { return "Joseon needs the microphone permission before it can open the input." }
            return nil
        case .microphone: return nil
        case .level:
            if levelCheck?.verdict == .clipped { return "The input clipped. Lower the level or the input gain, then check again." }
            return levelCheckPassed ? nil : "Run the level check at this level first."
        case .measure:
            return results.isEmpty && runs.isEmpty ? "Measure at least one run." : nil
        case .result: return nil
        }
    }

    func canShow(_ target: MeasureStep) -> Bool {
        // What is measured can always be looked at, also when the level check became void afterwards.
        if target == .result { return blocker(after: .measure) == nil }
        return MeasureStep.allCases.filter { $0.rawValue < target.rawValue }.allSatisfy { blocker(after: $0) == nil }
    }

    func go(to target: MeasureStep) {
        guard target != step, !activity.makesSound else { return }
        guard target.rawValue < step.rawValue || canShow(target) else { return }
        if target == .input { refreshDevices() }
        if target == .result { rebuildResults() }
        message = nil
        rigConfirmed = false        // a tick never travels to another step
        step = target
    }

    func next() { if let n = MeasureStep(rawValue: step.rawValue + 1) { go(to: n) } }
    func back() { if let p = MeasureStep(rawValue: step.rawValue - 1) { go(to: p) } }

    // MARK: - Capture engine

    private func ready(for new: MeasureActivity) -> Bool {
        guard !closed, !activity.isBusy else { return false }
        message = nil
        permission = environment.input.permission
        guard selectedDevice != nil else { message = MeasureMessage(text: "Pick the input of the measurement microphone first."); return false }
        guard permission == .authorized else { message = MeasureMessage(text: "Joseon has no microphone permission. Allow it in step 1."); return false }
        return true
    }

    /// The checkbox is ticked and the press is fresh. The player checks the permit again.
    private func permitIsGood(_ permit: TonePlayPermit) -> Bool {
        guard rigConfirmed else { message = MeasureMessage(text: "Confirm first that the headphones are on the rig, not on your head."); return false }
        guard permit.isFresh() else { message = MeasureMessage(text: "The button press is too old. Press the button again."); return false }
        return true
    }

    /// The sweep at the rate of the OUTPUT device and at the current play level, as the player wants it.
    private func playBuffer() -> [Float]? {
        let rate = environment.player.outputSampleRate
        guard rate > 0 else { message = MeasureMessage(text: "There is no output device to play the sweep through."); return nil }
        return MeasureSignal.sweep(sampleRate: rate, levelDBFS: playLevelDBFS).samples.map(Float.init)
    }

    private enum Phase { case opening, waitingForFrames, playing, tail(until: TimeInterval), recordingOnly }

    /// Opens the input, records, optionally plays `play` once, closes the input, and hands the recording to `done` (main).
    /// Every failure path ends in `abort`, which sets a message and returns to idle.
    private func startCapture(play: (samples: [Float], permit: TonePlayPermit)?, nominalSeconds: Double,
                              neededFrames: @escaping (Double) -> Int, done: @escaping (MeasureRecording) -> Void) {
        token += 1
        let current = token
        let timing = environment.timing
        let capture = environment.input.makeCapture(deviceUID: deviceUID, channel: channel,
                                                    maxSeconds: MeasureSignal.sweepSeconds + MeasureSignal.runPaddingSeconds + 4)
        self.capture = capture
        meter = MeasureMeter()
        progress = 0
        capture.onStop = { [weak self] reason in
            guard let self, current == self.token else { return }
            switch reason {
            case .deviceRemoved: self.abort("The input device went away during the run (unplugged?). Joseon stopped and dropped the recording. Plug it in, then pick it again in step 1.")
            case .formatChanged: self.abort("The sample rate or the format of the input changed during the run. Joseon stopped and dropped the recording. Leave the device settings alone during a measurement, then try again.")
            case .requested: break
            }
        }
        var phase = Phase.opening
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + timing.startTimeoutSeconds + nominalSeconds * timing.nominalScale + timing.watchdogMarginSeconds

        func finish() {
            pollTimer?.invalidate(); pollTimer = nil
            self.capture = nil
            work.async {
                let recording = capture.stop()
                DispatchQueue.main.async {
                    guard current == self.token, !self.closed else { return }
                    self.progress = 1
                    self.meter.peakDB = -.infinity
                    self.meter.rmsDB = -.infinity
                    done(recording)
                }
            }
        }

        work.async {
            var failure: String?
            do { try capture.start() } catch let error as MeasurementInputError { failure = Self.text(for: error) } catch { failure = "The input did not open: \(error.localizedDescription)" }
            DispatchQueue.main.async {
                guard current == self.token, !self.closed else { self.work.async { _ = capture.stop() }; return }
                if let failure { self.abort(failure); return }
                phase = .waitingForFrames
            }
        }

        let timer = Timer(timeInterval: timing.pollSeconds, repeats: true) { [weak self] _ in
            guard let self, current == self.token else { return }
            let now = ProcessInfo.processInfo.systemUptime
            var m = self.meter
            m.peakDB = capture.peakDB
            m.rmsDB = capture.rmsDB
            m.maxPeakDB = max(m.maxPeakDB, m.peakDB)
            m.clipped = capture.clipped
            if m != self.meter { self.meter = m }
            self.progress = min(0.99, max(0, (now - started) / max(nominalSeconds, 0.1)))
            if now > deadline {
                self.abort("The run did not finish in time, so Joseon stopped it and dropped the recording. Check that the input and the output device still work, then try again.")
                return
            }
            switch phase {
            case .opening: break
            case .waitingForFrames:
                if capture.framesRecorded > 0 {
                    guard let play else { phase = .recordingOnly; return }
                    let refusal = self.environment.player.play(play.samples, permit: play.permit) { [weak self] end in
                        guard let self, current == self.token else { return }
                        switch end {
                        case .completed: phase = .tail(until: ProcessInfo.processInfo.systemUptime + timing.tailSeconds)
                        case .stopped(let reason): self.abort(reason)
                        }
                    }
                    if let refusal { self.abort(refusal) } else { phase = .playing }
                } else if now - started > timing.startTimeoutSeconds {
                    self.abort("The input delivers no audio. Check that the device is connected and not in use by another app with exclusive access.")
                }
            case .playing: break
            case .tail(let until): if now >= until { finish() }
            case .recordingOnly:
                let rate = capture.sampleRate
                if rate > 0, capture.framesRecorded >= neededFrames(rate) { finish() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Ends whatever runs: the sweep fades out, the input closes, the recording is dropped.
    func abort(_ text: String?) {
        token += 1
        pollTimer?.invalidate(); pollTimer = nil
        environment.player.stop(reason: text ?? "Stopped.")
        if let capture {
            self.capture = nil
            capture.onStop = nil
            work.async { _ = capture.stop() }
        }
        activity = .idle
        progress = 0
        meter = MeasureMeter()
        if let text { message = MeasureMessage(text: text) }
    }

    func cancel() { if activity.isBusy { abort("Stopped. Joseon dropped the recording of this run.") } }

    /// The window closed: stop everything and drop every recording, every analysis object and every result.
    func windowClosed() {
        abort(nil)
        closed = true
        message = nil
        work.async { self.sessions.removeAll() }
        results = [:]
        runs = []
        liveQuality = nil
        noiseRMSDB = nil
    }

    /// Self-check: true when nothing measured is left in memory.
    func holdsNoMeasurementData(_ completion: @escaping (Bool) -> Void) {
        work.async {
            let empty = self.sessions.isEmpty
            DispatchQueue.main.async { completion(empty && self.results.isEmpty && self.runs.isEmpty && self.capture == nil) }
        }
    }

    static func dbText(_ db: Double, decimals: Int = 1) -> String { db.isFinite ? NumberText.signed(db, decimals: decimals) : "—" }

    static func text(for error: MeasurementInputError) -> String {
        switch error {
        case .permissionNotGranted: return "Joseon has no microphone permission. Allow it in step 1."
        case .deviceNotFound, .deviceNotAlive: return "The input device is gone (unplugged?). Plug it in, then pick it again in step 1."
        case .notAnInputDevice: return "This device has no input."
        case .channelOutOfRange(_, let available): return "The device has only \(available) input channel\(available == 1 ? "" : "s"). Pick the channel again in step 1."
        case .unsupportedFormat(let why): return "Joseon can not read the sample format of this input (\(why)). Choose another format for the device in Audio MIDI Setup."
        case .deviceHogged: return "Another app holds exclusive access to this input. Quit that app, or turn off its exclusive mode."
        case .alreadyRunning: return "The input runs already. Wait a moment and try again."
        case .ioProcFailed(let status): return "The input did not start (Core Audio error \(status))."
        }
    }
}
