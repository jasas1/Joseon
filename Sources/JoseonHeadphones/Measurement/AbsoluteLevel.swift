import Foundation
import JoseonCore

/// Tying a measurement's dBFS to real dB SPL — and refusing to when nothing ties them.
///
/// A deconvolved response is a *ratio*: digital out over digital in. It says what shape the
/// headphone has, and nothing at all about how loud it was. Turning it into pascals needs one
/// more number, and there are exactly two honest ways to get it:
///
/// - an acoustic calibrator (94 dB SPL at 1 kHz) held on the microphone, read in dBFS;
/// - a microphone sensitivity stated in dBFS per pascal, which only means anything if the
///   interface gain between the microphone and the samples is known and fixed.
///
/// If neither exists, absolute level is **not available**. That is not a degraded result to be
/// papered over with a plausible default — it is a different answer, so it has a different
/// case. `Result` has no "0 dB offset" to fall through to.
public enum AbsoluteLevel {

    /// What ties dBFS to dB SPL.
    public enum Reference: Sendable, Equatable {
        /// An acoustic calibrator on the microphone. `readingDBFS` is the RMS level of its tone
        /// in the recording, in the convention where a full-scale sine reads −3.01 dBFS.
        case calibrator(readingDBFS: Double, levelDBSPL: Double = 94, atHz: Double = 1_000, uncertaintyDB: Double = 0.5)
        /// A stated microphone sensitivity, for example from a UMIK `Sens Factor` header. Only
        /// valid while the interface gain stays exactly where it was when the figure was made.
        case micSensitivity(dbFSPerPascal: Double, uncertaintyDB: Double = MicCalibration.sensFactorUncertaintyDB)
        /// Nothing ties them. Carries the sentence the app should show.
        case unknown(reason: String)

        /// The usual case: a UMIK-style file whose `Sens Factor` header survived, or nothing.
        public static func fromMicCalibration(_ calibration: MicCalibration?) -> Reference {
            guard let calibration else {
                return .unknown(reason: "No microphone calibration file, so nothing states what a sample is worth in pascals.")
            }
            guard let sensitivity = calibration.micSensitivityDBFSPerPascal() else {
                return .unknown(reason: "The calibration file \"\(calibration.name)\" has no sensitivity header, and the gain of the audio interface is unknown, so a level in dBFS can not be turned into dB SPL.")
            }
            return .micSensitivity(dbFSPerPascal: sensitivity)
        }
    }

    /// Which of the two honest routes an offset came from.
    ///
    /// The route is kept, not just its sentence, because the two are not worth the same and the
    /// uncertainty budget has to say so: a calibrator is a traceable 94 dB SPL on the microphone,
    /// while `Sens Factor` is a convention about a digital reference (`MicCalibration
    /// .sensFactorReferenceDBFS`) that Joseon has never checked against a real microphone.
    public enum Route: String, Sendable, Equatable {
        case acousticCalibrator
        case microphoneSensFactor
        case other

        /// The smallest uncertainty this route may claim, in dB, one side.
        public var minimumUncertaintyDB: Double {
            switch self {
            case .acousticCalibrator: return 0.5
            case .microphoneSensFactor: return MicCalibration.sensFactorUncertaintyDB
            case .other: return 0
            }
        }

        /// Short label for the uncertainty table.
        public var label: String {
            switch self {
            case .acousticCalibrator: return "Acoustic calibrator"
            case .microphoneSensFactor: return "Microphone \"Sens Factor\" convention"
            case .other: return "Stated level reference"
            }
        }
    }

    /// dB SPL = dBFS + `offsetDB`.
    public struct Scale: Sendable, Equatable {
        public var offsetDB: Double
        public var uncertaintyDB: Double
        /// One sentence for the report: how this offset was obtained.
        public var method: String
        /// Which route made it. `.other` for a scale somebody built by hand.
        public var route: Route

        public init(offsetDB: Double, uncertaintyDB: Double, method: String, route: Route = .other) {
            self.offsetDB = offsetDB
            self.uncertaintyDB = uncertaintyDB
            self.method = method
            self.route = route
        }

        /// dB SPL for a level in dBFS RMS.
        public func splDB(fromDBFS dbfs: Double) -> Double { dbfs + offsetDB }
    }

    /// Available, or not, with the reason.
    public enum Result: Sendable, Equatable {
        case available(Scale)
        case unavailable(reason: String)

        /// The scale, or `nil`. Use this only where "no absolute level" is already handled.
        public var scale: Scale? {
            if case .available(let s) = self { return s }
            return nil
        }

        /// Why there is no scale, or `nil` when there is one.
        public var unavailableReason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }

        public var isAvailable: Bool { scale != nil }
    }

    /// Work out the scale from a reference.
    public static func scale(for reference: Reference) -> Result {
        switch reference {
        case .calibrator(let readingDBFS, let levelDBSPL, let atHz, let uncertaintyDB):
            guard readingDBFS.isFinite, readingDBFS < 0 else {
                return .unavailable(reason: "The calibrator reading (\(String(format: "%.1f", readingDBFS)) dBFS) is not a usable level. Re-run the level check with the calibrator on the microphone.")
            }
            return .available(Scale(
                offsetDB: levelDBSPL - readingDBFS,
                uncertaintyDB: max(uncertaintyDB, Route.acousticCalibrator.minimumUncertaintyDB),
                method: "Acoustic calibrator, \(String(format: "%.0f", levelDBSPL)) dB SPL at \(String(format: "%.0f", atHz)) Hz, read as \(String(format: "%.2f", readingDBFS)) dBFS RMS",
                route: .acousticCalibrator
            ))
        case .micSensitivity(let dbFSPerPascal, let uncertaintyDB):
            guard dbFSPerPascal.isFinite else {
                return .unavailable(reason: "The stated microphone sensitivity is not a number.")
            }
            return .available(Scale(
                offsetDB: 94 - dbFSPerPascal,
                // The 2 dB the module states for this route is a floor, not a default that a
                // caller can talk down: the reference level it rests on has never been checked.
                uncertaintyDB: max(uncertaintyDB, Route.microphoneSensFactor.minimumUncertaintyDB),
                method: "Stated microphone sensitivity \(String(format: "%.2f", dbFSPerPascal)) dBFS per pascal (94 dB SPL); valid only while the interface gain is untouched",
                route: .microphoneSensFactor
            ))
        case .unknown(let reason):
            return .unavailable(reason: reason)
        }
    }
}

// MARK: - Sensitivity derivation

/// A headphone sensitivity worked out from a measurement, with its error bar and its workings.
///
/// The error bar is five terms in quadrature, and none of them is a constant picked to make the
/// answer look good:
///
/// | Term | Where it comes from |
/// |---|---|
/// | Absolute level reference | the route that ties dBFS to dB SPL: `AbsoluteLevel.Route.minimumUncertaintyDB` (an acoustic calibrator is the small one, the `Sens Factor` convention is `MicCalibration.sensFactorUncertaintyDB`) |
/// | Drive voltage | `PlaybackCalibration.uncertaintyDB` — the same figure the calibration window prints (the table of `PlaybackCalibration+Factories.swift`) |
/// | Rig | `MeasurementRig.uncertaintyDB`, an engineering estimate per rig |
/// | Microphone response at 1 kHz | the `micCalibrationUncertaintyDB` argument of `deriveSensitivity`: small with a calibration file, larger without one |
/// | Measurement repeatability | the run-to-run spread, divided by √runs |
///
/// `printedUncertaintyDB`, `dominantTerm` and `uncertaintyHeadline` turn that into the one line
/// the big type shows, for example `± 3.5 dB (rig-limited)`. The numbers are not restated here: a
/// table of literals in a comment is one more copy that can drift from the symbols above.
public struct DerivedSensitivity: Sendable, Equatable {
    public var sensitivity: HeadphoneSensitivity
    /// One-sided uncertainty in dB, the pieces added in quadrature. Unrounded; the UI prints
    /// `printedUncertaintyDB`.
    public var uncertaintyDB: Double
    /// Every piece that went into `uncertaintyDB`, named, for the report and for the UI tooltip.
    public var uncertaintyComponents: [Component]
    /// The SPL the headphone made at 1 kHz during the measurement, for the sanity line.
    public var measuredSPLAt1kHz: Double
    /// The RMS volts at the headphone during the measurement.
    public var driveVoltsRMS: Double
    /// What the headphone was measured on. Sets the rig term.
    public var rig: MeasurementRig

    /// One line of the uncertainty budget.
    public struct Component: Sendable, Equatable {
        /// What the UI prints in the first column, for example "Drive voltage".
        public var name: String
        /// One-sided uncertainty in dB.
        public var dB: Double
        /// Where this number came from, for the second line or the tooltip.
        public var detail: String
        /// Which piece of the chain it is, for code that must not match on prose.
        public var kind: Kind

        public init(name: String, dB: Double, detail: String = "", kind: Kind = .other) {
            self.name = name
            self.dB = dB
            self.detail = detail
            self.kind = kind
        }
    }

    public init(
        sensitivity: HeadphoneSensitivity,
        uncertaintyDB: Double,
        uncertaintyComponents: [Component],
        measuredSPLAt1kHz: Double,
        driveVoltsRMS: Double,
        rig: MeasurementRig = .flatPlate
    ) {
        self.sensitivity = sensitivity
        self.uncertaintyDB = uncertaintyDB
        self.uncertaintyComponents = uncertaintyComponents
        self.measuredSPLAt1kHz = measuredSPLAt1kHz
        self.driveVoltsRMS = driveVoltsRMS
        self.rig = rig
    }
}

/// Derived, or not, with the reason. Same rule as `AbsoluteLevel.Result`: no absolute level, no
/// sensitivity, and the type says so.
public enum DerivedSensitivityResult: Sendable, Equatable {
    case derived(DerivedSensitivity)
    case unavailable(reason: String)

    public var value: DerivedSensitivity? {
        if case .derived(let d) = self { return d }
        return nil
    }

    public var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

extension AbsoluteLevel {

    /// Uncertainty Joseon assigns to the drive voltage: **the figure the active calibration
    /// carries**, never a constant of this module's own.
    ///
    /// Joseon used to assign 0.5 dB here for a measured tone, on the argument that a true-RMS
    /// meter reads a 1 kHz sine to a few percent and that `PlaybackCalibration.uncertaintyDB`
    /// covers a whole SPL chain dominated by the published sensitivity being replaced. The
    /// argument is defensible and the result was not: the calibration window printed ± 2 dB for
    /// the same calibration that the sensitivity read-out rated ± 0.5 dB, and one of the two was
    /// lying. The user has one calibration, so it gets one uncertainty — the one they were shown.
    ///
    /// The method only sets a floor, so that a hand-built `PlaybackCalibration` carrying an
    /// optimistic figure can not talk the budget down:
    ///
    /// | Method | Floor |
    /// |---|---|
    /// | `.measuredVoltage` | `PlaybackCalibration.measuredToneUncertaintyDB` — a multimeter on the test tone |
    /// | `.systemVolume` | `PlaybackCalibration.systemVolumeUncertaintyDB` — a known output with a volume curve in between |
    /// | `.enteredSpecs` | `PlaybackCalibration.specsUncertaintyDB` — data sheets, with a volume setting known in dB |
    public static func driveVoltageUncertaintyDB(for calibration: PlaybackCalibration) -> Double {
        let floor: Double
        switch calibration.method {
        case .measuredVoltage: floor = 2.0
        case .systemVolume: floor = 3.0
        case .enteredSpecs: floor = 4.0
        }
        let stated = calibration.uncertaintyDB
        return max(stated.isFinite ? stated : 0, floor)
    }

    /// Derive dB SPL per volt at 1 kHz from a measurement.
    ///
    ///     SPL(1 kHz) = (sweep level dBFS − 3.01) + 20·log₁₀|H(1 kHz)| + offset
    ///     V_rms      = fullScaleVrms · 10^(sweep level dBFS / 20)
    ///     dB SPL/V   = SPL(1 kHz) − 20·log₁₀(V_rms)
    ///                = 20·log₁₀|H(1 kHz)| − 3.01 + offset − 20·log₁₀(fullScaleVrms)
    ///
    /// The sweep level cancels, because the transfer function is a ratio — it only sets the
    /// signal-to-noise ratio, not the answer. The −3.01 is the module's convention showing up:
    /// `fullScaleVrms` is the RMS volts for a 0 dBFS *peak* sine, so a sine at `levelDBFS` peak
    /// has RMS `levelDBFS − 3.01` dBFS.
    ///
    /// - Parameters:
    ///   - magnitudeAt1kHzDB: `20·log₁₀|H|` averaged over 800–1250 Hz, **before** normalization
    ///     and after the microphone correction.
    ///   - measurementUncertaintyDB: repeatability of the measurement itself — the run-to-run
    ///     agreement, or the reciprocal of the signal-to-noise ratio at 1 kHz.
    ///   - micCalibrationUncertaintyDB: how well the microphone's own response is known at 1 kHz.
    ///   - rig: what the headphone was measured on. A flat plate is not an ear simulator and the
    ///     budget says so; see `MeasurementRig`.
    public static func deriveSensitivity(
        magnitudeAt1kHzDB: Double,
        absoluteLevel: Result,
        playback: PlaybackCalibration,
        sweepLevelDBFS: Double,
        impedanceOhms: Double,
        driveVoltageUncertaintyDB: Double? = nil,
        measurementUncertaintyDB: Double = 0.3,
        micCalibrationUncertaintyDB: Double = 0.5,
        rig: MeasurementRig = .flatPlate,
        source: String
    ) -> DerivedSensitivityResult {
        guard case .available(let scale) = absoluteLevel else {
            return .unavailable(reason: absoluteLevel.unavailableReason
                ?? "No absolute level reference, so the measurement gives a shape but not a sensitivity.")
        }
        guard playback.fullScaleVrms > 0 else {
            return .unavailable(reason: "The playback calibration \"\(playback.name)\" has no voltage, so the drive level at the headphone is unknown.")
        }
        guard magnitudeAt1kHzDB.isFinite else {
            return .unavailable(reason: "The measured response at 1 kHz is not a usable number.")
        }

        let driveVolts = playback.fullScaleVrms * pow(10, sweepLevelDBFS / 20)
        let spl = (sweepLevelDBFS - 3.0103) + magnitudeAt1kHzDB + scale.offsetDB
        let dbSPLPerVolt = spl - 20 * log10(driveVolts)

        // The drive term is the calibration's own figure unless the app states a better one; the
        // route's floor keeps the absolute-level term honest even for a hand-built scale.
        let driveDB = driveVoltageUncertaintyDB ?? Self.driveVoltageUncertaintyDB(for: playback)
        let levelDB = max(scale.uncertaintyDB, scale.route.minimumUncertaintyDB)

        let components = [
            DerivedSensitivity.Component(
                name: "Absolute level reference",
                dB: levelDB,
                detail: scale.route.label,
                kind: .absoluteLevel
            ),
            DerivedSensitivity.Component(
                name: "Drive voltage",
                dB: driveDB,
                detail: "Playback calibration \"\(playback.name)\"",
                kind: .driveVoltage
            ),
            DerivedSensitivity.Component(
                name: "Rig",
                dB: rig.uncertaintyDB,
                detail: "\(rig.label), against an IEC 60318-4 eardrum reading (engineering estimate)",
                kind: .rig
            ),
            DerivedSensitivity.Component(
                name: "Microphone response at 1 kHz",
                dB: micCalibrationUncertaintyDB,
                detail: micCalibrationUncertaintyDB <= 0.5
                    ? "Calibration file applied"
                    : "No microphone calibration file",
                kind: .microphone
            ),
            DerivedSensitivity.Component(
                name: "Measurement repeatability",
                dB: measurementUncertaintyDB,
                detail: "Run-to-run spread of this measurement",
                kind: .repeatability
            ),
        ]
        let quadrature = components.reduce(0) { $0 + $1.dB * $1.dB }.squareRoot()

        return .derived(DerivedSensitivity(
            sensitivity: HeadphoneSensitivity(
                dbSPLPerVolt: dbSPLPerVolt,
                impedanceOhms: impedanceOhms,
                source: source
            ),
            uncertaintyDB: quadrature,
            uncertaintyComponents: components,
            measuredSPLAt1kHz: spl,
            driveVoltsRMS: driveVolts,
            rig: rig
        ))
    }
}
