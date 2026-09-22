import Foundation
import JoseonCore

// MARK: - Building a calibration

/// Joseon can not see the amplifier gain, so the whole SPL chain hangs off one number:
/// the RMS volts at the headphone for a full-scale sine. These two factories are the only
/// honest ways to get it, and each carries the uncertainty it deserves.
extension PlaybackCalibration {

    // THE table of voltage terms. One-sided, in dB. Every surface reads these symbols and nothing else: the
    // calibration window (through `SPLMath.uncertaintyDB` of the app), the stored presets, the meters block, the header
    // and the drive-voltage term of a measured sensitivity. No other file states these numbers.

    /// A multimeter on the test tone, with the headphones plugged in while measuring.
    ///
    /// A cheap true-RMS multimeter reads a 400 Hz sine to a few percent (well under 1 dB). The
    /// rest is the knob moving between the measurement and the listening, and the two channels
    /// not being equal. The figure the level-at-the-ear design asks for; not optimistic.
    public static let measuredToneUncertaintyDB: Double = 2

    /// The same measurement WITHOUT the headphones plugged in: an amplifier with a high output
    /// impedance (a tube amplifier) gives less voltage into the load than into the meter alone.
    public static let measuredOpenCircuitUncertaintyDB: Double = 3

    /// The volts come from data sheets rather than a meter, and the volume setting is known in dB.
    public static let specsUncertaintyDB: Double = 4

    /// The volume attenuation is a guess as well — an analog knob with no scale, which is exactly
    /// the first user's Woo Audio WA33. A knob position read off a clock face is worth several dB.
    public static let specsWithGuessedAttenuationUncertaintyDB: Double = 6

    /// A known maximum output voltage, scaled with the macOS volume of the output device.
    public static let systemVolumeUncertaintyDB: Double = 3

    /// From a measured test tone: play a sine at `toneLevelDBFS`, measure the RMS volts at the
    /// headphone, and scale back up to full scale.
    ///
    ///     fullScaleVrms = measuredVrms · 10^(−toneLevelDBFS / 20)
    ///
    /// `toneLevelDBFS` is the tone's **peak** level in dBFS, the number the tone generator shows
    /// (a −20 dBFS sine reads −23.01 dBFS RMS), which is the same convention `fullScaleVrms` uses.
    ///
    /// Never play a tone without the user pressing a button that says it will make sound.
    public static func fromMeasuredTone(
        name: String,
        measuredVrms: Double,
        toneLevelDBFS: Double
    ) -> PlaybackCalibration {
        let fullScale = measuredVrms * pow(10, -toneLevelDBFS / 20)
        return PlaybackCalibration(
            name: name,
            method: .measuredVoltage,
            fullScaleVrms: max(fullScale, 0),
            uncertaintyDB: measuredToneUncertaintyDB
        )
    }

    /// From data sheets: the DAC's full-scale output, the amplifier's gain, and how far the
    /// volume control is turned down.
    ///
    ///     fullScaleVrms = dacFullScaleVrms · 10^((ampGainDB − volumeAttenuationDB) / 20)
    ///
    /// - Parameters:
    ///   - volumeAttenuationDB: positive dB of attenuation. 0 means the control is wide open.
    ///   - attenuationIsEstimated: `true` when that number is read off an unmarked analog knob
    ///     rather than a stepped attenuator or a digital readout. Defaults to `true` because
    ///     the safe assumption about a knob is that nobody knows where it is.
    public static func fromSpecs(
        name: String,
        dacFullScaleVrms: Double,
        ampGainDB: Double,
        volumeAttenuationDB: Double,
        attenuationIsEstimated: Bool = true
    ) -> PlaybackCalibration {
        let fullScale = dacFullScaleVrms * pow(10, (ampGainDB - volumeAttenuationDB) / 20)
        return PlaybackCalibration(
            name: name,
            method: .enteredSpecs,
            fullScaleVrms: max(fullScale, 0),
            uncertaintyDB: attenuationIsEstimated
                ? specsWithGuessedAttenuationUncertaintyDB
                : specsUncertaintyDB
        )
    }
}

// MARK: - Sanity line for the calibration UI

/// SPL at the eardrum for a steady sine at `dBFS`, at 1 kHz.
///
///     SPL = dbSPLPerVolt + 20·log10(fullScaleVrms) + dBFS
///
/// `dBFS` is the sine's peak level, so a 0 dBFS sine gives `fullScaleVrms` volts. The headphone
/// response does not appear because sensitivity is defined at 1 kHz and the curve is normalized
/// to 0 dB there; at any other frequency add the normalized response.
///
/// The calibration sheet shows this as one line the user can check against a meter or against
/// plain experience — "a −20 dBFS 1 kHz tone ≈ 78 dB SPL". If that line reads 110, the
/// calibration is wrong, and the user will see it before any dose number is believed.
public func expectedSPL(
    forSineDBFS dBFS: Double,
    sensitivity: HeadphoneSensitivity,
    calibration: PlaybackCalibration
) -> Double {
    let volts = max(calibration.fullScaleVrms, 1e-12)
    return sensitivity.dbSPLPerVolt + 20 * log10(volts) + dBFS
}

/// The same value at a frequency other than 1 kHz, shaped by the headphone's own response.
/// `curve` is normalized internally, so pass the raw curve from the library.
public func expectedSPL(
    forSineDBFS dBFS: Double,
    atHz hz: Double,
    sensitivity: HeadphoneSensitivity,
    calibration: PlaybackCalibration,
    curve: HeadphoneCurve
) -> Double {
    let response = CurveInterpolator(curve: curve.normalizedTo1kHz()).level(atHz: Float(hz))
    return expectedSPL(forSineDBFS: dBFS, sensitivity: sensitivity, calibration: calibration) + Double(response)
}
