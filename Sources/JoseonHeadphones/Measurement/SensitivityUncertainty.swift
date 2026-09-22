import Foundation
import JoseonCore

/// What the headphone was measured on.
///
/// The number attached to each case is how far this rig's reading at 1 kHz can sit from what an
/// IEC 60318-4 ear simulator would read on the same headphone — a **rig term**, not a repeatability
/// term. It is there because a sensitivity in dB SPL per volt is only meaningful against a stated
/// eardrum reference, and a flat plate is not one.
///
/// **These three figures are engineering estimates, not standards values.** No standard states
/// them; nothing here was checked against a real coupler, because there is no coupler yet. They
/// are Joseon's own conservative guesses at the spread between rigs:
///
/// | Rig | Term | Why |
/// |---|---|---|
/// | `.earSimulator` | ± 1 dB | An IEC 60318-4 type coupler *is* the reference, so what is left is unit-to-unit spread and how the headphone sits on it. |
/// | `.flatPlate` | ± 2.5 dB | A flat plate has no ear canal and no eardrum impedance. At 1 kHz the leak and the missing canal volume move the reading by a decibel or two either way. |
/// | `.other` | ± 3 dB | A home-made coupler or a silicone ear: unknown volume, unknown leak, unknown termination. |
///
/// A coupler correction curve (`CouplerCorrection`) takes out the *shape* of a rig. It does not
/// remove this term, because the correction is itself only as good as whoever characterised the
/// rig, and the first user has no such file.
public enum MeasurementRig: String, Sendable, Equatable, CaseIterable, Codable {
    /// A standards-type ear simulator, IEC 60318-4 (the old 711 coupler).
    case earSimulator
    /// A flat plate: the headphone sits on a baffle with the microphone flush in it.
    case flatPlate
    /// Anything else — a home-made coupler, a silicone pinna, a cup over a measurement mic.
    case other

    /// One-sided uncertainty in dB this rig adds to a derived sensitivity. Engineering estimate.
    public var uncertaintyDB: Double {
        switch self {
        case .earSimulator: return 1.0
        case .flatPlate: return 2.5
        case .other: return 3.0
        }
    }

    /// Short name for the UI and for the uncertainty table.
    public var label: String {
        switch self {
        case .earSimulator: return "Ear simulator (IEC 60318-4 type)"
        case .flatPlate: return "Flat plate"
        case .other: return "Other rig"
        }
    }

    /// One sentence for the report: what this rig's reading at 1 kHz is worth.
    public var note: String {
        switch self {
        case .earSimulator:
            return "Measured on a standards-type ear simulator, so the 1 kHz reading is close to an eardrum reading; Joseon still allows ± 1 dB for the coupler and the seating."
        case .flatPlate:
            return "Measured on a flat plate, which has no ear canal and no eardrum impedance. Its 1 kHz reading can sit ± 2.5 dB from what an IEC 60318-4 ear simulator would read."
        case .other:
            return "Measured on a rig Joseon knows nothing about, so its 1 kHz reading can sit ± 3 dB from an IEC 60318-4 ear simulator reading."
        }
    }
}

// MARK: - Reading the budget out loud

extension DerivedSensitivity {

    /// The total, rounded **up** to the next half decibel.
    ///
    /// Up, never to nearest: rounding 2.6 dB down to 2.5 would be a claim the measurement can not
    /// support, and half a decibel of pessimism costs nothing.
    public var printedUncertaintyDB: Double {
        DerivedSensitivity.roundedUpToHalfDB(uncertaintyDB)
    }

    /// The largest single term. Ties go to the term listed first, so the answer is stable.
    public var dominantTerm: Component {
        var best = Component(name: "Measurement", dB: uncertaintyDB, kind: .other)
        var bestDB = -Double.infinity
        for component in uncertaintyComponents where component.dB > bestDB {
            best = component
            bestDB = component.dB
        }
        return best
    }

    /// What the big type shows: `"± 3 dB (rig-limited)"`.
    ///
    /// The bracket names the one term that dominates, so the user can see what to fix — a better
    /// rig, a meter on the amplifier, an acoustic calibrator — rather than reading a number with
    /// no handle on it.
    public var uncertaintyHeadline: String {
        let value = DerivedSensitivity.format(printedUncertaintyDB)
        guard let phrase = dominantTerm.kind.limitPhrase else { return "± \(value) dB" }
        return "± \(value) dB (\(phrase))"
    }

    /// Every term, in the order the UI should print them, each as `("Drive voltage", "2.0 dB", detail)`.
    public var uncertaintyTable: [(term: String, value: String, detail: String)] {
        uncertaintyComponents.map {
            (term: $0.name, value: String(format: "%.1f dB", $0.dB), detail: $0.detail)
        }
    }

    /// `2.35 → 2.5`, `3.0 → 3.0`. The epsilon stops a total that is a hair over a half step from
    /// jumping a whole one.
    public static func roundedUpToHalfDB(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return max(0.5, ((value - 1e-9) / 0.5).rounded(.up) * 0.5)
    }

    /// `3.0 → "3"`, `2.5 → "2.5"`.
    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }
}

extension DerivedSensitivity.Component {

    /// Which piece of the chain this term belongs to. The UI needs this to name the limit without
    /// matching on `name`, which is prose and may be translated.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// What ties dBFS to dB SPL: an acoustic calibrator, or a stated microphone sensitivity.
        case absoluteLevel
        /// How well the volts at the headphone are known.
        case driveVoltage
        /// How far this rig's 1 kHz reading can sit from an eardrum reading.
        case rig
        /// How well the microphone's own response at 1 kHz is known.
        case microphone
        /// Run-to-run repeatability of this measurement.
        case repeatability
        case other

        /// The word in the brackets after the total: `"rig-limited"`.
        public var limitPhrase: String? {
            switch self {
            case .absoluteLevel: return "reference-limited"
            case .driveVoltage: return "voltage-limited"
            case .rig: return "rig-limited"
            case .microphone: return "microphone-limited"
            case .repeatability: return "repeatability-limited"
            case .other: return nil
            }
        }
    }
}
