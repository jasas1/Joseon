import Foundation
import JoseonCore

// MARK: - Dose options

/// Switches that change how the dose is counted. Named, so nothing is hidden in a magic number.
public struct SPLDoseOptions: Equatable, Sendable, Codable {
    /// NIOSH integrates only the time spent at or above a threshold level; sound under it does
    /// not add dose at all. NIOSH REL (DHHS 98-126) sets that threshold at 80 dBA.
    /// Default **on**, which is what NIOSH publishes. Turn it off to integrate every level.
    public var applyNIOSHThreshold: Bool

    public init(applyNIOSHThreshold: Bool = true) {
        self.applyNIOSHThreshold = applyNIOSHThreshold
    }

    // MARK: Criteria, as named constants

    /// NIOSH REL: 85 dBA for 8 hours is 100 % of the daily dose.
    public static let nioshCriterionDBA: Double = 85
    public static let nioshCriterionSeconds: Double = 8 * 3_600
    /// NIOSH exchange rate: 3 dB. Halving the allowed time per 3 dB is `2^((L − 85) / 3)`.
    public static let nioshExchangeRateDB: Double = 3
    /// NIOSH threshold level. Levels under this do not accumulate dose when the option is on.
    public static let nioshThresholdDBA: Double = 80

    /// WHO / ITU-T H.870 adult allowance: 80 dBA for 40 hours is one week's worth of sound.
    public static let whoCriterionDBA: Double = 80
    public static let whoWeeklySeconds: Double = 40 * 3_600

    /// Allowed time in seconds at a steady A-weighted level, under the NIOSH criterion.
    public static func nioshAllowedSeconds(atDBA level: Double) -> Double {
        guard level.isFinite else { return level < 0 ? .infinity : 0 }
        return nioshCriterionSeconds * pow(2, (nioshCriterionDBA - level) / nioshExchangeRateDB)
    }
}

// MARK: - Persistable dose

/// Everything the dose counters hold, in a form the app can write to disk and give back.
///
/// The estimator never touches the filesystem. The app decides where this lives and when a
/// new day or week starts; `rolled(to:)` says what a rollover means so both agree.
public struct SPLDoseState: Equatable, Sendable, Codable {
    /// NIOSH daily dose so far, 1.0 = 100 %.
    public var nioshDose: Double
    /// Σ dt · 10^((L − 80)/10) in seconds. WHO weekly dose = this / (40 h).
    public var whoWeeklyEnergySeconds: Double
    /// Seconds of audio counted into the dose (time with signal).
    public var doseSeconds: Double
    /// Σ dt · 10^(L/10) for the session Leq, in seconds (`L` is the A-weighted level).
    public var sessionEnergySeconds: Double
    /// Σ dt for the session Leq. Equal to `doseSeconds`, kept separate so the two can diverge
    /// if a future option ever gates one of them and not the other.
    public var sessionSeconds: Double
    /// Calendar day the NIOSH dose belongs to, `yyyy-MM-dd`.
    public var dayStamp: String
    /// ISO-8601 week the WHO allowance belongs to, `yyyy-Www`.
    public var weekStamp: String

    public init(
        nioshDose: Double = 0,
        whoWeeklyEnergySeconds: Double = 0,
        doseSeconds: Double = 0,
        sessionEnergySeconds: Double = 0,
        sessionSeconds: Double = 0,
        dayStamp: String = "",
        weekStamp: String = ""
    ) {
        self.nioshDose = nioshDose
        self.whoWeeklyEnergySeconds = whoWeeklyEnergySeconds
        self.doseSeconds = doseSeconds
        self.sessionEnergySeconds = sessionEnergySeconds
        self.sessionSeconds = sessionSeconds
        self.dayStamp = dayStamp
        self.weekStamp = weekStamp
    }

    /// WHO / ITU-T H.870 weekly dose, 1.0 = the whole adult weekly allowance.
    public var whoWeeklyDose: Double {
        whoWeeklyEnergySeconds / SPLDoseOptions.whoWeeklySeconds
    }

    /// ISO-8601 week numbering, so a listening week starts on Monday wherever the user is.
    public static let isoCalendar = Calendar(identifier: .iso8601)

    /// `yyyy-MM-dd` in the user's own time zone — a listening day is a local day.
    public static func dayStamp(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `yyyy-Www` using ISO-8601 week numbering, so a week starts on Monday.
    ///
    /// `calendar` supplies only the time zone; the week numbering is always ISO-8601. Passing
    /// the same calendar as `dayStamp(for:)` keeps the two stamps talking about the same
    /// midnight — otherwise a listener near midnight can land in one day and the next week.
    public static func weekStamp(for date: Date, calendar: Calendar = .current) -> String {
        var iso = isoCalendar
        iso.timeZone = calendar.timeZone
        let c = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    /// A fresh state stamped for `date`.
    public static func empty(at date: Date, calendar: Calendar = .current) -> SPLDoseState {
        SPLDoseState(dayStamp: dayStamp(for: date, calendar: calendar),
                     weekStamp: weekStamp(for: date, calendar: calendar))
    }

    /// The same state rolled forward to `date`.
    ///
    /// A new day clears the NIOSH daily dose, the counted seconds and the session Leq.
    /// A new ISO week clears the WHO weekly allowance. Nothing else changes, so a state
    /// restored inside the same day and week comes back untouched.
    public func rolled(to date: Date, calendar: Calendar = .current) -> SPLDoseState {
        var out = self
        let day = Self.dayStamp(for: date, calendar: calendar)
        let week = Self.weekStamp(for: date, calendar: calendar)
        if out.dayStamp != day {
            out.nioshDose = 0
            out.doseSeconds = 0
            out.sessionEnergySeconds = 0
            out.sessionSeconds = 0
            out.dayStamp = day
        }
        if out.weekStamp != week {
            out.whoWeeklyEnergySeconds = 0
            out.weekStamp = week
        }
        return out
    }
}

// MARK: - Estimator

/// Sound level at the ear, from third-octave band levels plus a calibration and a headphone.
///
/// Chain per band `b` and channel, as the level-at-the-ear design states it:
///
///     eardrum_b = L_b + 3.01 + 20·log10(fullScaleVrms) + dbSPLPerVolt + response(f_b)
///
/// `L_b` is dBFS RMS, where a full-scale sine reads −3.01, so `+3.01` puts a full-scale sine at
/// `fullScaleVrms` volts. `response` is the headphone curve normalized to 0 dB over 800–1250 Hz
/// (the module's own normalization) and averaged over the band in the dB domain.
///
/// The diffuse-field equivalent per band is `eardrum_b − DF(f_b)` (see `DiffuseFieldReference`),
/// then A-weighted per IEC 61672 at the nominal center and summed as energy.
///
/// Threading, the same shape as `HeadphoneModel`: the app sets things up from the main thread
/// through `configure`, the analysis thread calls `evaluate`. One lock guards all mutable state.
/// It is uncontended in practice and costs tens of nanoseconds per call.
///
/// Every number this type produces is an estimate. `SPLReading.uncertaintyDB` carries the
/// calibration's own uncertainty; the UI must show it and must never present an SPL as exact.
public final class SPLEstimator: SPLEstimating, @unchecked Sendable {

    // MARK: Configuration (guarded by `lock`)

    private var _curve: HeadphoneCurve
    private var _sensitivity: HeadphoneSensitivity
    private var _calibration: PlaybackCalibration
    private var _options: SPLDoseOptions

    /// Rebuilt when the curve or the band centers change.
    private var cachedCenters: [Float] = []
    private var cachedResponseDB: [Double] = []
    private var cachedDiffuseDB: [Double] = []
    private var cachedAWeightDB: [Double] = []
    private var cacheIsStale = true

    // MARK: Running state (guarded by `lock`)

    /// 1 s exponential averages, kept as linear energy (10^(L/10)) so the filter is on power.
    private var slowAEnergy: Double = 0
    private var slowZEnergy: Double = 0

    /// Track Leq accumulators — cleared by `resetMeasurement()`.
    private var trackEnergySeconds: Double = 0
    private var trackSeconds: Double = 0
    private var maxAFast: Double = -.infinity

    /// Dose + session accumulators — cleared by `resetDose()`, persisted through `doseState()`.
    private var dose = SPLDoseState()

    private let lock = NSLock()
    private let now: () -> Date

    /// Time constant of the slow weighting, IEC 61672 "S".
    public static let slowTimeConstantSeconds: Double = 1.0

    // MARK: Init

    /// - Parameter now: injected clock, so tests can stamp a dose state without waiting for midnight.
    public init(
        curve: HeadphoneCurve,
        sensitivity: HeadphoneSensitivity,
        calibration: PlaybackCalibration,
        options: SPLDoseOptions = SPLDoseOptions(),
        now: @escaping () -> Date = { Date() }
    ) {
        self._curve = curve.normalizedTo1kHz()
        self._sensitivity = sensitivity
        self._calibration = calibration
        self._options = options
        self.now = now
        self.dose = SPLDoseState.empty(at: now())
    }

    // MARK: Live configuration

    /// Replace any of the three inputs while the analysis thread is running.
    ///
    /// One call, so a headphone swap that changes the curve and the sensitivity together lands
    /// as one atomic change and no frame is ever computed from half of it. Passing `nil` keeps
    /// the current value.
    public func configure(
        curve: HeadphoneCurve? = nil,
        sensitivity: HeadphoneSensitivity? = nil,
        calibration: PlaybackCalibration? = nil,
        options: SPLDoseOptions? = nil
    ) {
        lock.withLock {
            if let curve {
                _curve = curve.normalizedTo1kHz()
                cacheIsStale = true
            }
            if let sensitivity { _sensitivity = sensitivity }
            if let calibration { _calibration = calibration }
            if let options { _options = options }
        }
    }

    /// The headphone curve in use, normalized to 0 dB over 800–1250 Hz.
    public var normalizedCurve: HeadphoneCurve { lock.withLock { _curve } }
    public var sensitivity: HeadphoneSensitivity { lock.withLock { _sensitivity } }
    public var calibration: PlaybackCalibration { lock.withLock { _calibration } }
    public var options: SPLDoseOptions { lock.withLock { _options } }

    // MARK: Inspection helpers (for the calibration UI and for tests)

    /// The diffuse-field term subtracted from the eardrum level in the band at `centerHz`:
    /// the normalized diffuse-field shape averaged over the band, plus the absolute 1 kHz offset.
    public static func diffuseFieldTermDB(centerHz: Double) -> Double {
        ThirdOctaveBands.meanDB(of: diffuseInterpolator, centerHz: centerHz)
            + DiffuseFieldReference.absoluteOffsetAt1kHzDB
    }

    private static let diffuseInterpolator = CurveInterpolator(curve: DiffuseFieldReference.normalizedCurve)

    /// The constant part of the chain: `3.01 + 20·log10(fullScaleVrms) + dbSPLPerVolt`.
    /// A band's eardrum level is this plus the band's dBFS RMS plus the band's response.
    public var chainOffsetDB: Double { lock.withLock { chainOffsetLocked() } }

    private func chainOffsetLocked() -> Double {
        // A calibration of zero volts is not a level, it is "no signal path". Clamp rather
        // than return NaN, so a mis-entered calibration reads as silence, not as garbage.
        let volts = max(_calibration.fullScaleVrms, 1e-12)
        return 3.01 + 20 * log10(volts) + _sensitivity.dbSPLPerVolt
    }

    // MARK: Cache

    private func refreshCacheIfNeeded(centers: [Float]) {
        guard cacheIsStale || cachedCenters != centers else { return }
        cachedCenters = centers
        let curveInterpolator = CurveInterpolator(curve: _curve)
        cachedResponseDB = centers.map { ThirdOctaveBands.meanDB(of: curveInterpolator, centerHz: Double($0)) }
        cachedDiffuseDB = centers.map { Self.diffuseFieldTermDB(centerHz: Double($0)) }
        cachedAWeightDB = AWeighting.dB(atHz: centers)
        cacheIsStale = false
    }

    // MARK: SPLEstimating

    public func evaluate(thirdOctave: ThirdOctaveReading, dt: Double, isSilent: Bool) -> SPLReading {
        lock.lock()
        defer { lock.unlock() }

        let centers = thirdOctave.centersHz
        refreshCacheIfNeeded(centers: centers)
        let offset = chainOffsetLocked()
        let bandCount = min(centers.count, min(thirdOctave.left.count, thirdOctave.right.count))

        // Per-channel band energies. The louder ear is decided per frame, by A-weighted total.
        var leftEardrum = [Double](repeating: -.infinity, count: bandCount)
        var rightEardrum = [Double](repeating: -.infinity, count: bandCount)
        var leftA = 0.0, rightA = 0.0
        var leftZ = 0.0, rightZ = 0.0

        for b in 0..<bandCount {
            let response = cachedResponseDB[b]
            let diffuse = cachedDiffuseDB[b]
            let weight = cachedAWeightDB[b]

            let el = Double(thirdOctave.left[b]) + offset + response
            let er = Double(thirdOctave.right[b]) + offset + response
            leftEardrum[b] = el
            rightEardrum[b] = er
            leftZ += Self.energy(el)
            rightZ += Self.energy(er)
            leftA += Self.energy(el - diffuse + weight)
            rightA += Self.energy(er - diffuse + weight)
        }

        let leftIsLouder = leftA >= rightA
        let louderA = leftIsLouder ? leftA : rightA
        let louderZ = leftIsLouder ? leftZ : rightZ
        let louderBands = leftIsLouder ? leftEardrum : rightEardrum
        let levelAFast = Self.level(louderA)

        // Time weightings. The incoming bands are already "fast" (125 ms), so `levelAFast` is
        // the band sum as it stands; "slow" is a 1 s exponential average on A-weighted energy.
        // The slow filter advances on every frame that carried audio time, silent or not, so a
        // meter decays through digital silence the way a real sound level meter does.
        if dt > 0 {
            let alpha = 1 - exp(-dt / Self.slowTimeConstantSeconds)
            slowAEnergy += alpha * (louderA - slowAEnergy)
            slowZEnergy += alpha * (louderZ - slowZEnergy)
        }
        let levelASlow = Self.level(slowAEnergy)

        if levelAFast > maxAFast { maxAFast = levelAFast }

        // Leq and dose count audio time that carried signal. Digital silence is skipped, and so
        // is a frame that advanced no audio time. Quiet-but-not-silent music DOES count: a track
        // fade or a pianissimo passage is still sound at the ear, and dropping it would flatter
        // both the Leq and the dose.
        if dt > 0, !isSilent {
            accumulate(levelAFast: levelAFast, dt: dt)
        }

        var bandLevels = [Float](repeating: SPLReading.floorDB, count: centers.count)
        for b in 0..<bandCount {
            bandLevels[b] = Float(max(louderBands[b], Double(SPLReading.floorDB)))
        }

        return SPLReading(
            calibrationName: _calibration.name,
            uncertaintyDB: Float(_calibration.uncertaintyDB),
            levelAFast: Self.reportable(levelAFast),
            levelASlow: Self.reportable(levelASlow),
            levelZEardrum: Self.reportable(Self.level(slowZEnergy)),
            leqATrack: Self.reportable(Self.mean(energySeconds: trackEnergySeconds, seconds: trackSeconds)),
            leqASession: Self.reportable(Self.mean(energySeconds: dose.sessionEnergySeconds, seconds: dose.sessionSeconds)),
            maxAFast: Self.reportable(maxAFast),
            bandLevelsEardrum: bandLevels,
            doseNIOSH: Float(dose.nioshDose),
            doseWHOWeekly: Float(dose.whoWeeklyDose),
            doseSeconds: dose.doseSeconds,
            secondsToNIOSHLimit: secondsToNIOSHLimitLocked(atDBA: levelASlow)
        )
    }

    /// New track: clears `leqATrack` and `maxAFast`. The dose keeps running.
    public func resetMeasurement() {
        lock.withLock {
            trackEnergySeconds = 0
            trackSeconds = 0
            maxAFast = -.infinity
        }
    }

    /// Clears the dose and the session Leq. The day and week stamps move to now.
    public func resetDose() {
        lock.withLock { dose = SPLDoseState.empty(at: now()) }
    }

    // MARK: Dose persistence

    /// A snapshot the app can encode and write. The estimator never touches disk itself.
    public func doseState() -> SPLDoseState { lock.withLock { dose } }

    /// Put a saved snapshot back. Call `SPLDoseState.rolled(to:)` first to handle a day or week
    /// boundary; this method stores exactly what it is given.
    public func restore(_ state: SPLDoseState) {
        lock.withLock { dose = state }
    }

    /// Time left at a steady `level`, in seconds, before the NIOSH dose reaches 100 %.
    /// Infinite when the level cannot ever reach the limit (under the threshold, or silence).
    public func secondsToNIOSHLimit(atDBA level: Double) -> Double {
        lock.withLock { secondsToNIOSHLimitLocked(atDBA: level) }
    }

    // MARK: Private

    private func accumulate(levelAFast level: Double, dt: Double) {
        guard level.isFinite else { return }

        let energy = Self.energy(level)
        trackEnergySeconds += dt * energy
        trackSeconds += dt
        dose.sessionEnergySeconds += dt * energy
        dose.sessionSeconds += dt
        dose.doseSeconds += dt

        // NIOSH: dose = ∫ dt / T(L), T(L) = 8 h · 2^((85 − L)/3), with an 80 dBA threshold.
        if !_options.applyNIOSHThreshold || level >= SPLDoseOptions.nioshThresholdDBA {
            let allowed = SPLDoseOptions.nioshAllowedSeconds(atDBA: level)
            if allowed > 0, allowed.isFinite { dose.nioshDose += dt / allowed }
        }

        // WHO / ITU-T H.870 adult weekly allowance: Σ dt · 10^((L − 80)/10), over 40 h.
        // H.870 states no threshold level, so every frame with signal counts.
        dose.whoWeeklyEnergySeconds += dt * pow(10, (level - SPLDoseOptions.whoCriterionDBA) / 10)
    }

    private func secondsToNIOSHLimitLocked(atDBA level: Double) -> Double {
        guard level.isFinite else { return .infinity }
        if _options.applyNIOSHThreshold, level < SPLDoseOptions.nioshThresholdDBA { return .infinity }
        let remaining = 1 - dose.nioshDose
        if remaining <= 0 { return 0 }
        let allowed = SPLDoseOptions.nioshAllowedSeconds(atDBA: level)
        guard allowed.isFinite else { return .infinity }
        return remaining * allowed
    }

    private static func energy(_ dB: Double) -> Double {
        dB.isFinite ? pow(10, dB / 10) : 0
    }

    private static func level(_ energy: Double) -> Double {
        energy > 0 ? 10 * log10(energy) : -.infinity
    }

    private static func mean(energySeconds: Double, seconds: Double) -> Double {
        seconds > 0 ? level(energySeconds / seconds) : -.infinity
    }

    /// Clamp to the contract's floor so the UI never gets −inf or a negative dB SPL.
    private static func reportable(_ dB: Double) -> Float {
        guard dB.isFinite else { return SPLReading.floorDB }
        return Float(max(dB, Double(SPLReading.floorDB)))
    }
}
