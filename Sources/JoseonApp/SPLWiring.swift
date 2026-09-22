import Foundation
import JoseonCore
import JoseonHeadphones

/// The one place where the app meets the concrete SPL types of `JoseonHeadphones`.
/// Everything else in the app talks to the contract: `SPLEstimating`, `PlaybackCalibration`,
/// `HeadphoneSensitivity`, `SPLReading`, `AnalysisEngine.splEstimator`.
///
/// The integrator swaps the two lines marked `// INTEGRATION:` below. Nothing else changes.
/// While both return nil the app runs and says "sensitivity unknown" / "not calibrated".
enum SPLWiring {
    /// Builds the estimator for one headphone, its sensitivity and the active calibration.
    /// Nil = this build has no estimator: the app says so and shows no SPL number.
    static var makeEstimator: (HeadphoneCurve, HeadphoneSensitivity, PlaybackCalibration) -> SPLEstimating? = { curve, sensitivity, calibration in
        SPLEstimator(curve: curve, sensitivity: sensitivity, calibration: calibration)
    }

    /// Sensitivity from the built-in library, by headphone curve name. Nil = not in the library: the user types it in.
    static var lookupSensitivity: (String) -> HeadphoneSensitivity? = { headphoneName in
        HeadphoneSensitivityLibrary.sensitivity(forCurveNamed: headphoneName)
    }
}

/// OPTIONAL integration point. The app builds a new estimator when the calibration changes, for example at every
/// step of the macOS volume in the "macOS controls the volume" mode. An estimator that conforms hands its running
/// state (track Leq, session Leq, maximum, dose: the concrete `SPLDoseState`) to its successor, so a volume step
/// does not start the Leq again. The app treats the state as opaque bytes.
///
/// The noise dose does NOT depend on this: the app keeps the dose itself, from the `SPLReading` numbers
/// (see `SPLDoseLedger`), so it survives a new estimator and a new launch with the contract alone.
///
/// INTEGRATION (optional): `extension SPLEstimator: SPLStateCarrying { … }` with the JSON of its `SPLDoseState`.
protocol SPLStateCarrying: AnyObject {
    /// The running state as opaque bytes (for example JSON of `SPLDoseState`). Nil = nothing to carry.
    func exportCarriedState() -> Data?
    /// Continue from the state of the estimator that ran before. Called before the engine sees this estimator.
    func importCarriedState(_ data: Data)
}

/// Where the dose ledger lives between launches. `UserDefaultsDoseStore` in the app, `MemoryDoseStore` in
/// snapshot mode and in the self-check, so a review run never touches the user's dose.
protocol SPLDoseStore: AnyObject {
    func load() -> SPLDoseLedger?
    func save(_ ledger: SPLDoseLedger)
}

final class UserDefaultsDoseStore: SPLDoseStore {
    private let defaults: UserDefaults
    private let key = "spl.doseLedger.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> SPLDoseLedger? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SPLDoseLedger.self, from: $0) }
    }

    func save(_ ledger: SPLDoseLedger) {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: key) }
    }
}

final class MemoryDoseStore: SPLDoseStore {
    var ledger: SPLDoseLedger?
    init(_ ledger: SPLDoseLedger? = nil) { self.ledger = ledger }
    func load() -> SPLDoseLedger? { ledger }
    func save(_ ledger: SPLDoseLedger) { self.ledger = ledger }
}

extension SPLWiring {
    /// Why the built-in table has no sensitivity for this headphone (what the maker's page says), when known.
    static func unlistedReason(forHeadphoneNamed name: String) -> (reason: String, url: String)? {
        HeadphoneSensitivityLibrary.unlisted.first { $0.name == name }.map { ($0.reason, $0.checkedURL) }
    }
}
