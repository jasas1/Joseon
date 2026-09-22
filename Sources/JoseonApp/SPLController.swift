import AppKit
import Combine
import JoseonCore
import JoseonCapture
import JoseonHeadphones
import JoseonRender

/// Why the header shows an SPL number, or why it does not.
enum SPLStatus: Equatable {
    case noHeadphone
    case sensitivityUnknown(headphone: String)
    /// `madeFor`: the preset remembered for this device was made for another headphone.
    case notCalibrated(device: String, madeFor: String?)
    case muted(device: String)
    /// Calibration and sensitivity are there, but this build has no estimator (see `SPLWiring`).
    case estimatorUnavailable
    case calibrated

    var isCalibrated: Bool { self == .calibrated }

    /// One short line: header tooltip, popover, settings.
    var summary: String {
        switch self {
        case .noHeadphone: return "Pick a headphone first. The level at the ear depends on it."
        case .sensitivityUnknown(let headphone): return "Sensitivity unknown for \(headphone). \"\(SPLPill.setUpTitle)\" in the main window says why and takes a value. A measurement gives the best one."
        case .notCalibrated(let device, let madeFor):
            let place = device.isEmpty ? "this output" : device
            if let madeFor { return "Not calibrated for \(place) with this headphone. The stored calibration was made for \(madeFor)." }
            return "Not calibrated for \(place)."
        case .muted(let device): return "\(device.isEmpty ? "The output" : device) is muted."
        case .estimatorUnavailable: return "This build of Joseon has no level estimator."
        case .calibrated: return "Calibrated"
        }
    }
}

/// What the header pill shows. Published only when a text or the ring changes.
struct SPLHeaderState: Equatable {
    var status = SPLStatus.noHeadphone
    /// Whole dB: the estimate is not better than that. Nil at silence or without a reading.
    var levelText: String?
    /// Dose of the chosen standard, in steps of 1%.
    var dosePercent = 0
    var standard = DoseStandard.nioshDaily
    var calibrationName = ""
    var uncertaintyText = ""
}

struct SPLDoseBanner: Equatable {
    var mark: Int          // 50 or 100
    var uncertaintyText: String
    var text: String {
        mark >= 100
            ? "Today's sound allowance is used up (NIOSH: 85 dB(A) for 8 hours). Your ears get a rest when you stop or turn down. Estimate, \(uncertaintyText)."
            : "Half of today's sound allowance is used (NIOSH: 85 dB(A) for 8 hours). Estimate, \(uncertaintyText)."
    }
}

/// Builds the estimator from headphone + sensitivity + calibration + output device, hands it to the engine,
/// and keeps the dose. Main thread only.
final class SPLController: ObservableObject {
    let store: SPLCalibrationStore
    let tone = TonePlayer()
    private let engine: AnalysisEngine
    private let doseStore: SPLDoseStore
    private let monitor = OutputVolumeMonitor()
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var header = SPLHeaderState()
    @Published private(set) var output: OutputVolumeState?
    @Published var doseBanner: SPLDoseBanner?
    /// Goes up with every change of the store: open views read the store again.
    @Published private(set) var revision = 0

    private(set) var headphone: HeadphoneCurve?
    private(set) var latestReading: SPLReading?
    private(set) var ledger: SPLDoseLedger
    private var ledgerDirtySince: TimeInterval?
    private var lastRollOverCheck: TimeInterval = 0

    private struct BuildKey: Equatable {
        var headphone: String?
        var sensitivity: HeadphoneSensitivity?
        var calibration: PlaybackCalibration?
        var muted = false
    }
    private var builtKey: BuildKey?
    private var estimator: SPLEstimating?
    private var snapshotStub: SnapshotSPLStub?

    var deviceName: String { output?.deviceName ?? "" }
    var headphoneName: String { headphone?.name ?? "" }
    var status: SPLStatus { header.status }

    init(engine: AnalysisEngine) {
        self.engine = engine
        if SnapshotSPL.isActive {
            // Layout review: nothing is read from or written to the user's defaults, and no device is watched.
            store = SPLCalibrationStore(defaults: nil)
            let stub = MemoryDoseStore(SnapshotSPL.seedLedger())
            doseStore = stub
            output = SnapshotSPL.output
        } else {
            store = SPLCalibrationStore()
            doseStore = UserDefaultsDoseStore()
            monitor.start()
            output = monitor.state
        }
        ledger = doseStore.load() ?? SPLDoseLedger()
        ledger.rollOver(now: Date())
        monitor.onChange = { [weak self] state in self?.outputChanged(state) }
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.revision += 1      // open views read the store again (rename, delete, sensitivity)
                self?.rebuild()
            }
            .store(in: &cancellables)
        rebuild()
    }

    /// Offline self-check only: a store and a dose store in memory, a made-up output device, and NO device monitor.
    init(engine: AnalysisEngine, selfCheckStore: SPLCalibrationStore, doseStore: SPLDoseStore, output: OutputVolumeState) {
        precondition(TonePlayPermit.processIsOffline, "this init is for the offline self-check")
        self.engine = engine
        store = selfCheckStore
        self.doseStore = doseStore
        self.output = output
        ledger = doseStore.load() ?? SPLDoseLedger()
        ledger.rollOver(now: Date())
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.revision += 1; self?.rebuild() }
            .store(in: &cancellables)
        rebuild()
    }

    /// Offline self-check only: the store publishes on the next main-queue turn, the check does not wait for it.
    func rebuildForSelfCheck() {
        precondition(TonePlayPermit.processIsOffline)
        rebuild()
    }

    // MARK: Inputs

    /// The app model calls this when the headphone choice changes. Nil = "None".
    func setHeadphone(_ curve: HeadphoneCurve?) {
        guard curve != headphone else { return }
        headphone = curve
        if let curve, SnapshotSPL.isActive { SnapshotSPL.seed(store, headphone: curve.name) }
        rebuild()
    }

    /// The default output device changed. The measurement window stops its sweep on it.
    var onOutputDeviceChange: (() -> Void)?

    private func outputChanged(_ state: OutputVolumeState?) {
        if state?.deviceID != output?.deviceID { tone.outputDeviceChanged(); onOutputDeviceChange?() }
        output = state
        rebuild()
    }

    // MARK: Sensitivity and calibration

    /// A value the owner MEASURED on this unit first, then the library, then what the user typed.
    var sensitivity: HeadphoneSensitivity? {
        guard let headphone else { return nil }
        let user = store.userSensitivity(headphone: headphone.name).flatMap { $0.isValid ? $0 : nil }
        if let user, user.isMeasured { return user.sensitivity }
        return SPLWiring.lookupSensitivity(headphone.name) ?? user?.sensitivity
    }

    /// The owner's measured value is in use.
    var sensitivityIsMeasured: Bool {
        guard let headphone, let user = store.userSensitivity(headphone: headphone.name) else { return false }
        return user.isValid && user.isMeasured
    }

    var sensitivityIsFromLibrary: Bool { !sensitivityIsMeasured && (headphone.map { SPLWiring.lookupSensitivity($0.name) != nil } ?? false) }

    var activePreset: CalibrationPreset? {
        guard let headphone else { return nil }
        return store.activePreset(device: deviceName, headphone: headphone.name)
    }

    /// The calibration as it counts now. `.systemVolume` follows the macOS volume of the output device.
    func effectiveCalibration(_ preset: CalibrationPreset) -> PlaybackCalibration? {
        guard preset.calibration.method == .systemVolume else { return preset.calibration }
        guard let attenuation = output?.attenuationDB else { return nil }   // the device lost its software volume
        var c = preset.calibration
        c.fullScaleVrms = SPLMath.fullScaleVrms(maxOutputVrms: preset.calibration.fullScaleVrms, volumeAttenuationDB: attenuation)
        return c
    }

    func save(_ preset: CalibrationPreset) {
        store.add(preset)
    }

    // MARK: Total uncertainty (voltage and sensitivity)

    /// One-sided uncertainty of the sensitivity in use: the measured value's own figure for "Measured by owner",
    /// 2 dB for a library value (maker data sheet: unit spread, test method), 3 dB for a value the user typed.
    var sensitivityUncertaintyDB: Double? {
        guard let headphone, sensitivity != nil else { return nil }
        if sensitivityIsMeasured {
            return store.userSensitivity(headphone: headphone.name)?.uncertaintyDB ?? SPLMath.typedSensitivityUncertaintyDB
        }
        return sensitivityIsFromLibrary ? SPLMath.librarySensitivityUncertaintyDB : SPLMath.typedSensitivityUncertaintyDB
    }

    /// What the estimator gets: the calibration with the TOTAL one-sided uncertainty (voltage and sensitivity are
    /// independent, so they add as a root of squares). The stored preset keeps its own voltage term: the total is
    /// made here, at estimator build time only, so it shrinks at once when a measured sensitivity replaces a typed one.
    func totalCalibration(_ calibration: PlaybackCalibration) -> PlaybackCalibration {
        guard let sensitivityTerm = sensitivityUncertaintyDB else { return calibration }
        var c = calibration
        c.uncertaintyDB = SPLMath.totalUncertaintyDB(voltage: calibration.uncertaintyDB, sensitivity: sensitivityTerm)
        return c
    }

    /// "± 4 dB: voltage ± 2, sensitivity ± 3" for the active preset. Nil without a preset or a sensitivity.
    var uncertaintyPartsText: String? {
        guard let preset = activePreset, let sensitivityTerm = sensitivityUncertaintyDB else { return nil }
        let total = SPLMath.totalUncertaintyDB(voltage: preset.calibration.uncertaintyDB, sensitivity: sensitivityTerm)
        return "\(Self.uncertaintyText(total)): voltage \(Self.termText(preset.calibration.uncertaintyDB, unit: false)), sensitivity \(Self.termText(sensitivityTerm, unit: false))"
    }

    // MARK: Estimator

    private func rebuild() {
        var key = BuildKey(headphone: headphone?.name)
        var newStatus: SPLStatus
        if let headphone {
            key.sensitivity = sensitivity
            if let preset = store.activePreset(device: deviceName, headphone: headphone.name), let calibration = effectiveCalibration(preset) {
                key.calibration = totalCalibration(calibration)
                key.muted = preset.calibration.method == .systemVolume && (output?.isMuted ?? false)
            }
            if key.sensitivity == nil {
                newStatus = .sensitivityUnknown(headphone: headphone.name)
            } else if key.calibration == nil {
                let remembered = store.rememberedPreset(device: deviceName)
                newStatus = .notCalibrated(device: deviceName, madeFor: remembered.flatMap { $0.headphoneName != headphone.name ? $0.headphoneName : nil })
            } else if key.muted {
                newStatus = .muted(device: deviceName)
            } else {
                newStatus = .calibrated
            }
        } else {
            newStatus = .noHeadphone
        }

        if key != builtKey {
            builtKey = key
            var new: SPLEstimating?
            snapshotStub = nil
            if newStatus == .calibrated, let headphone, let sensitivity = key.sensitivity, let calibration = key.calibration {
                if SnapshotSPL.isActive {
                    let stub = SnapshotSPLStub(calibration: calibration)
                    snapshotStub = stub
                    new = stub
                } else {
                    new = SPLWiring.makeEstimator(headphone, sensitivity, calibration)
                }
                if let state = (estimator as? SPLStateCarrying)?.exportCarriedState() { (new as? SPLStateCarrying)?.importCarriedState(state) }
            }
            estimator = new
            engine.splEstimator = new
            ledger.estimatorChanged()
            latestReading = nil
            DebugLog.log("SPL estimator \(new == nil ? "off" : "on"): \(newStatus.summary)")
        }
        if newStatus == .calibrated, estimator == nil { newStatus = .estimatorUnavailable }
        publish(status: newStatus)
    }

    // MARK: Per frame (10 Hz, from the app model's supervisor)

    func update(frame: AnalysisFrame) {
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastRollOverCheck > 1 {
            lastRollOverCheck = uptime
            if ledger.rollOver(now: Date()) { markLedgerDirty(uptime) }
        }
        // Layout review only: the stub makes a reading from the loudness when the analyzer has no third-octave bands.
        let reading = frame.spl ?? snapshotStub?.evaluate(loudness: frame.loudness, isSilent: frame.isSilent)
        latestReading = status.isCalibrated ? reading : nil
        if let reading, status.isCalibrated {
            let before = ledger
            ledger.note(doseNIOSH: Double(reading.doseNIOSH), doseWHOWeekly: Double(reading.doseWHOWeekly), doseSeconds: reading.doseSeconds, now: Date())
            if ledger != before { markLedgerDirty(uptime) }
            if let mark = ledger.takeBannerMark() {
                doseBanner = SPLDoseBanner(mark: mark, uncertaintyText: Self.uncertaintyText(Double(reading.uncertaintyDB)))
                persistLedger()
            }
        }
        if let since = ledgerDirtySince, uptime - since > 30 { persistLedger() }
        publish(status: status, silent: frame.isSilent)
    }

    private func markLedgerDirty(_ uptime: TimeInterval) { if ledgerDirtySince == nil { ledgerDirtySince = uptime } }

    func persistLedger() {
        ledgerDirtySince = nil
        doseStore.save(ledger)
    }

    func resetDose() {
        estimator?.resetDose()
        ledger.reset(now: Date())
        ledger.estimatorChanged()
        doseBanner = nil
        persistLedger()
        publish(status: status)
    }

    func dismissDoseBanner() { doseBanner = nil }

    func shutdown() {
        tone.stopNow()
        monitor.stop()
        persistLedger()
    }

    /// A TOTAL, whole dB: 3.6 dB prints as "± 4 dB". The text comes from `EarUncertaintyText` of JoseonRender, the same
    /// function the meters block prints with: one number, one text, on every surface.
    static func uncertaintyText(_ db: Double, unit: Bool = true) -> String { EarUncertaintyText.total(db, unit: unit) }

    /// One TERM of the total: the voltage of a calibration method or the sensitivity. Whole dB for the fixed terms of
    /// `SPLMath`; a measured sensitivity keeps the half step the measurement window printed ("± 3.5 dB").
    static func termText(_ db: Double, unit: Bool = true) -> String { EarUncertaintyText.term(db, unit: unit) }

    private func publish(status: SPLStatus, silent: Bool = false) {
        var h = SPLHeaderState(status: status, standard: store.doseStandard)
        h.dosePercent = Int(((store.doseStandard == .nioshDaily ? ledger.nioshToday : ledger.whoWeek) * 100).rounded())
        if status.isCalibrated, let preset = activePreset {
            h.calibrationName = preset.name
            h.uncertaintyText = Self.uncertaintyText(totalCalibration(preset.calibration).uncertaintyDB)
        }
        if let reading = latestReading, !silent, reading.levelASlow > 20 { h.levelText = String(Int(reading.levelASlow.rounded())) }
        if h != header { header = h }
    }

    // MARK: Text for popover, tooltip, settings

    var doseToday: Double { ledger.nioshToday }
    var doseWeek: Double { ledger.whoWeek }

    /// The words after "52% used · ": what the rest of the allowance means at the level of now.
    func timeLeftText(_ standard: DoseStandard, levelA: Float?) -> String {
        let dose = standard == .nioshDaily ? ledger.nioshToday : ledger.whoWeek
        return Self.timeLeftText(standard, dose: dose, levelA: levelA)
    }

    /// Under 1 h: "about 40 min left at this level". Under a day: "about 5 h left at this level". Else: "at 77 dB(A)
    /// the rest lasts all day" (NIOSH) / "… all week" (WHO), so "52% used" never reads as a contradiction.
    static func timeLeftText(_ standard: DoseStandard, dose: Double, levelA: Float?) -> String {
        if dose >= 1 { return "allowance used up" }
        guard let levelA, levelA > 20 else { return "no audio now" }
        let seconds = standard == .nioshDaily
            ? SPLMath.secondsLeft(dose: dose, levelA: Double(levelA), criterionDB: 85, criterionHours: 8)
            : SPLMath.secondsLeft(dose: dose, levelA: Double(levelA), criterionDB: 80, criterionHours: 40)
        let level = "\(Int(levelA.rounded())) dB(A)"
        if seconds < 3600 { return "about \(durationText(seconds)) left at this level" }
        // "All day" = more listening than the day has hours; "all week" the same for the 7 days of the WHO figure.
        let cap: Double = standard == .nioshDaily ? 24 * 3600 : 7 * 24 * 3600
        if seconds < cap { return "about \(Int((seconds / 3600).rounded())) h left at this level" }
        return "at \(level) the rest lasts all \(standard == .nioshDaily ? "day" : "week")"
    }

    static func durationText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "less than 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 600 { return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min" }
        return "\(Int((seconds / 3600).rounded())) h"
    }

    var sensitivityText: String {
        guard let s = sensitivity else { return "Unknown" }
        return "\(NumberText.signed(s.dbSPLPerVolt, decimals: 1)) dB SPL/V · \(s.source)"
    }
}
