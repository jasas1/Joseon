import Foundation
import Combine
import JoseonCore
import JoseonHeadphones

// MARK: - Math

/// The arithmetic of the calibration window. Pure functions: the self-check covers them.
enum SPLMath {
    static let toneLevelDBFS: Double = -20
    static let toneFrequencyHz: Double = 400

    /// Volts RMS measured while a sine with a peak of `toneDBFS` plays -> volts RMS for a 0 dBFS sine.
    static func fullScaleVrms(measuredVrms: Double, toneDBFS: Double = toneLevelDBFS) -> Double {
        measuredVrms / pow(10, toneDBFS / 20)
    }

    /// DAC full-scale output, amplifier gain, volume attenuation (a positive number of dB below maximum).
    static func fullScaleVrms(dacVrms: Double, gainDB: Double, attenuationDB: Double) -> Double {
        dacVrms * pow(10, (gainDB - abs(attenuationDB)) / 20)
    }

    /// Maximum output voltage and the macOS volume in dB below maximum (0 or negative).
    static func fullScaleVrms(maxOutputVrms: Double, volumeAttenuationDB: Double) -> Double {
        maxOutputVrms * pow(10, min(0, volumeAttenuationDB) / 20)
    }

    /// Eardrum level of a 0 dBFS sine at 1 kHz.
    static func fullScaleSPL(fullScaleVrms: Double, sensitivity: HeadphoneSensitivity) -> Double {
        20 * log10(max(fullScaleVrms, 1e-9)) + sensitivity.dbSPLPerVolt
    }

    /// EBU Tech 3341: a stereo sine at −X dBFS peak reads −X LUFS. So music at −14 LUFS sits about 14 dB under the
    /// level of a full-scale sine. A rough figure for the sanity line, not a measurement.
    static func roughMusicSPL(fullScaleSPL: Double, lufs: Double = -14) -> Double { fullScaleSPL + lufs }

    // The voltage term of each method. The numbers live in ONE place, `PlaybackCalibration` (JoseonHeadphones,
    // `PlaybackCalibration+Factories.swift`): its factories, the measurement window and this window read the same symbols.
    static func uncertaintyDB(measuredLoaded: Bool) -> Double {
        measuredLoaded ? PlaybackCalibration.measuredToneUncertaintyDB : PlaybackCalibration.measuredOpenCircuitUncertaintyDB
    }
    static func uncertaintyDB(specsAttenuationIsGuess: Bool) -> Double {
        specsAttenuationIsGuess ? PlaybackCalibration.specsWithGuessedAttenuationUncertaintyDB : PlaybackCalibration.specsUncertaintyDB
    }
    static var systemVolumeUncertaintyDB: Double { PlaybackCalibration.systemVolumeUncertaintyDB }

    /// One-sided uncertainty of a sensitivity the user typed from a data sheet (unit spread, unknown test method, dB/mW or dB/V mix-ups).
    static let typedSensitivityUncertaintyDB: Double = 3
    /// The built-in library: a maker data sheet value that was checked against its source.
    static let librarySensitivityUncertaintyDB: Double = 2

    /// Voltage and sensitivity are independent: the total is the root of the sum of squares.
    static func totalUncertaintyDB(voltage: Double, sensitivity: Double) -> Double {
        (voltage * voltage + sensitivity * sensitivity).squareRoot()
    }

    /// "1.25", "1,25", " 840 " -> Double. Nil when the text is no positive-or-negative finite number.
    static func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: NumberText.minus, with: "-")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    /// NIOSH: 85 dB(A) for 8 h, 3 dB exchange rate. WHO / ITU H.870 adults: 80 dB(A) for 40 h per week, 3 dB.
    static func allowedSeconds(levelA: Double, criterionDB: Double, criterionHours: Double) -> Double {
        criterionHours * 3600 * pow(2, (criterionDB - levelA) / 3)
    }

    /// Time until the dose reaches 100% when the level stays at `levelA`. Infinite for a full dose at no level.
    static func secondsLeft(dose: Double, levelA: Double, criterionDB: Double, criterionHours: Double) -> Double {
        guard levelA.isFinite, levelA > 0 else { return .infinity }
        return max(0, 1 - dose) * allowedSeconds(levelA: levelA, criterionDB: criterionDB, criterionHours: criterionHours)
    }
}

// MARK: - Stored types

enum SensitivityUnit: String, Codable, CaseIterable, Identifiable {
    case dbPerMilliwatt, dbPerVolt
    var id: String { rawValue }
    var title: String { self == .dbPerMilliwatt ? "dB/mW" : "dB/V" }
    var spoken: String { self == .dbPerMilliwatt ? "decibels per milliwatt" : "decibels per volt" }
}

/// What the user typed for one headphone. The contract value comes from `sensitivity`.
struct UserSensitivity: Codable, Equatable {
    var value: Double
    var unit: SensitivityUnit
    var impedanceOhms: Double
    /// Set when the value came out of "Measure your headphone…": "Measured by owner, <date>, <rig note>".
    /// Nil for a typed-in value (and in everything stored before the measurement window existed).
    var measuredNote: String? = nil
    /// One-sided uncertainty of a measured value in dB.
    var uncertaintyDB: Double? = nil

    var isValid: Bool { value > 40 && value < 150 && impedanceOhms > 1 && impedanceOhms < 5000 }
    var isMeasured: Bool { measuredNote != nil }

    var sensitivity: HeadphoneSensitivity {
        let typed = "User: \(NumberText.signed(value, decimals: 1)) \(unit.title), \(NumberText.signed(impedanceOhms, decimals: 0)) Ω"
        let source = measuredNote.map { note in uncertaintyDB.map { "\(note) (\(SPLController.termText($0)))" } ?? note } ?? typed
        switch unit {
        case .dbPerMilliwatt: return .fromDBPerMilliwatt(value, impedanceOhms: impedanceOhms, source: source)
        case .dbPerVolt: return HeadphoneSensitivity(dbSPLPerVolt: value, impedanceOhms: impedanceOhms, source: source)
        }
    }
}

/// One named calibration, made for one output device and one headphone.
struct CalibrationPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    /// `fullScaleVrms` is the value at the time of the calibration. With `.systemVolume` it is the value at
    /// MAXIMUM volume: the app scales it with the macOS volume (see `SPLController.effectiveCalibration`).
    var calibration: PlaybackCalibration
    var deviceName: String
    var headphoneName: String
    /// For example "10 o'clock": where the volume knob stood.
    var knobNote = ""
    var created = Date()

    var name: String { calibration.name }

    var methodTitle: String {
        switch calibration.method {
        case .measuredVoltage: return "Measured with a multimeter"
        case .enteredSpecs: return "From specs"
        case .systemVolume: return "macOS volume"
        }
    }
}

enum DoseStandard: String, Codable, CaseIterable, Identifiable {
    case nioshDaily, whoWeekly
    var id: String { rawValue }
    var title: String { self == .nioshDaily ? "NIOSH, per day" : "WHO, per week" }
    var detail: String {
        self == .nioshDaily ? "85 dB(A) for 8 hours per day" : "80 dB(A) for 40 hours per week"
    }
}

// MARK: - Store

/// Calibration presets, the active preset per output device, typed-in sensitivities, the dose standard.
/// JSON in UserDefaults. Snapshot mode and the self-check use their own suite or no persistence at all.
final class SPLCalibrationStore: ObservableObject {
    private struct Stored: Codable {
        var presets: [CalibrationPreset] = []
        /// Output device name -> preset id. The choice comes back when the device comes back.
        var activeByDevice: [String: UUID] = [:]
        /// Headphone name -> what the user typed.
        var sensitivities: [String: UserSensitivity] = [:]
        var doseStandard = DoseStandard.nioshDaily
    }

    private let defaults: UserDefaults?
    private let key = "spl.calibrationStore.v1"
    private var stored: Stored { didSet { persist() } }

    /// `defaults: nil` keeps everything in memory.
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        stored = defaults?.data(forKey: key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    private func persist() {
        objectWillChange.send()
        guard let defaults, let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key)
    }

    var presets: [CalibrationPreset] { stored.presets }

    var doseStandard: DoseStandard {
        get { stored.doseStandard }
        set { if newValue != stored.doseStandard { stored.doseStandard = newValue } }
    }

    /// Presets made for this device, newest first.
    func presets(forDevice device: String) -> [CalibrationPreset] {
        stored.presets.filter { $0.deviceName == device }.sorted { $0.created > $1.created }
    }

    /// The preset the user chose for this device. It counts only when it was made for this device AND this headphone.
    func activePreset(device: String, headphone: String) -> CalibrationPreset? {
        guard let id = stored.activeByDevice[device], let preset = stored.presets.first(where: { $0.id == id }),
              preset.deviceName == device, preset.headphoneName == headphone else { return nil }
        return preset
    }

    /// The preset remembered for the device, also when the headphone does not match (for the "made for …" hint).
    func rememberedPreset(device: String) -> CalibrationPreset? {
        stored.activeByDevice[device].flatMap { id in stored.presets.first { $0.id == id } }
    }

    /// Adds the preset and makes it the active one of its device.
    func add(_ preset: CalibrationPreset) {
        var s = stored
        s.presets.append(preset)
        s.activeByDevice[preset.deviceName] = preset.id
        stored = s
    }

    func activate(_ preset: CalibrationPreset?, device: String) {
        var s = stored
        s.activeByDevice[device] = preset?.id
        stored = s
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = stored.presets.firstIndex(where: { $0.id == id }) else { return }
        stored.presets[index].calibration.name = trimmed
    }

    func delete(_ id: UUID) {
        var s = stored
        s.presets.removeAll { $0.id == id }
        s.activeByDevice = s.activeByDevice.filter { $0.value != id }
        stored = s
    }

    func userSensitivity(headphone: String) -> UserSensitivity? { stored.sensitivities[headphone] }

    func setUserSensitivity(_ value: UserSensitivity?, headphone: String) {
        guard !headphone.isEmpty else { return }
        stored.sensitivities[headphone] = value
    }

    /// "<device> · <date>", made unique among the stored names.
    func suggestedName(device: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        let base = "\(device.isEmpty ? "Output" : device) · \(f.string(from: date))"
        var name = base, n = 2
        while stored.presets.contains(where: { $0.name == name }) { name = "\(base) (\(n))"; n += 1 }
        return name
    }
}

// MARK: - Dose ledger

/// The noise dose the app keeps: today (NIOSH) and this ISO week (WHO). It adds up the GROWTH of the dose numbers
/// in `SPLReading`, so it needs the contract alone and survives a new estimator (each one starts at zero) and a
/// new launch. A new day clears the daily dose, a new ISO week clears the weekly dose.
struct SPLDoseLedger: Codable, Equatable {
    /// "2026-09-21"
    var dayKey = ""
    /// "2026-W39" (ISO 8601 week)
    var weekKey = ""
    /// 1.0 = 100%.
    var nioshToday: Double = 0
    var whoWeek: Double = 0
    var listeningSecondsToday: Double = 0
    /// The day for which the 50% / 100% banner showed already.
    var banner50Day = ""
    var banner100Day = ""

    /// Last values seen from the running estimator. Not stored: a new launch has a new estimator.
    private var lastNIOSH: Double?
    private var lastWHO: Double?
    private var lastSeconds: Double?

    private enum CodingKeys: String, CodingKey { case dayKey, weekKey, nioshToday, whoWeek, listeningSecondsToday, banner50Day, banner100Day }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func weekKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = timeZone
        let c = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    /// Clears what belongs to an older day or week. Returns true when something changed.
    @discardableResult
    mutating func rollOver(now: Date, calendar: Calendar = .current) -> Bool {
        var changed = false
        let day = Self.dayKey(now, calendar: calendar)
        if day != dayKey { dayKey = day; nioshToday = 0; listeningSecondsToday = 0; changed = true }
        let week = Self.weekKey(now, timeZone: calendar.timeZone)
        if week != weekKey { weekKey = week; whoWeek = 0; changed = true }
        return changed
    }

    /// A new estimator runs (or the old one was reset): its first reading is the baseline, not growth.
    mutating func estimatorChanged() { lastNIOSH = nil; lastWHO = nil; lastSeconds = nil }

    /// Add the growth since the last reading.
    mutating func note(doseNIOSH: Double, doseWHOWeekly: Double, doseSeconds: Double, now: Date, calendar: Calendar = .current) {
        rollOver(now: now, calendar: calendar)
        func growth(_ value: Double, _ last: Double?) -> Double {
            guard value.isFinite, let last, value > last else { return 0 }   // smaller = the estimator started again
            return value - last
        }
        nioshToday += growth(doseNIOSH, lastNIOSH)
        whoWeek += growth(doseWHOWeekly, lastWHO)
        listeningSecondsToday += growth(doseSeconds, lastSeconds)
        lastNIOSH = doseNIOSH; lastWHO = doseWHOWeekly; lastSeconds = doseSeconds
    }

    mutating func reset(now: Date) {
        let day = dayKey, week = weekKey
        self = SPLDoseLedger()
        dayKey = day; weekKey = week
        rollOver(now: now)
    }

    /// 50 or 100 when the daily dose passed that mark and today's banner for it did not show yet.
    mutating func takeBannerMark() -> Int? {
        if nioshToday >= 1, banner100Day != dayKey { banner100Day = dayKey; banner50Day = dayKey; return 100 }
        if nioshToday >= 0.5, banner50Day != dayKey { banner50Day = dayKey; return 50 }
        return nil
    }
}
