import SwiftUI

/// Proof that the user pressed a button that says it will make sound, AFTER ticking the safety checkbox next to it.
///
/// The init is fileprivate, and the only code in this file that calls it is `PermitButton`: so no other code path
/// in the app can start the calibration tone (`TonePlayer.start(permit:)`) or the measurement sweep
/// (`SignalPlayer.play(_:permit:)`). Both players also check that the permit is fresh: a stored permit starts
/// nothing later.
///
/// `offline()` is the one exception, and it can make no sound: it gives a permit only in the offline self-checks
/// and in snapshot mode, the permit says `isOffline`, and the real players refuse an offline permit AND refuse to
/// start in those modes at all. It exists so the self-check can drive the measurement controller with FAKE seams.
struct TonePlayPermit {
    let pressedAt: Date
    let isOffline: Bool

    fileprivate init(offline: Bool = false, age: TimeInterval = 0) {
        pressedAt = Date().addingTimeInterval(-age)
        isOffline = offline
    }

    func isFresh(within seconds: TimeInterval = 1) -> Bool { abs(pressedAt.timeIntervalSinceNow) < seconds }

    /// True when this process can never play sound from a permit: snapshot mode and the offline self-checks.
    static var processIsOffline: Bool {
        DebugSnapshot.directory != nil || SPLSelfCheck.isRequested || MeasureSelfCheck.isRequested
    }

    /// Self-check and snapshot mode only. Nil in a normal run. `age`: an old press, to check that a stale permit is refused.
    static func offline(age: TimeInterval = 0) -> TonePlayPermit? { processIsOffline ? TonePlayPermit(offline: true, age: age) : nil }
}

/// The only maker of a `TonePlayPermit`. The button is disabled until `confirmed` (the safety checkbox) is true, and
/// the action checks it again: a permit exists only for a press with the checkbox ticked.
struct PermitButton<Label: View>: View {
    var confirmed: Bool
    var action: (TonePlayPermit) -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: {
            guard confirmed else { return }
            action(TonePlayPermit())
        }, label: label)
        .disabled(!confirmed)
    }
}
