import Foundation
import JoseonCore

// MARK: - A-weighting

/// Frequency weighting A of IEC 61672-1, as the analytical transfer function, not the table.
///
/// The standard defines the weighting by a pole-zero network (two zero pairs at the origin,
/// poles at `f1`, `f2`, `f3`, `f4`) plus a normalization that makes the weighting exactly
/// 0 dB at 1 kHz. The published +2.00 dB constant is that normalization rounded; this type
/// divides by the network's own 1 kHz response instead, so `dB(atHz: 1000)` is exactly 0.
///
/// Joseon evaluates the weighting at the **nominal** third-octave center (1000, 1250, ...),
/// which is what the band labels mean and what `ThirdOctaveReading.nominalCentersHz` holds.
///
/// One subtlety, measured rather than assumed: the weighting values printed in the IEC 61672
/// and ANSI S1.4 tables are computed at the **exact** base-10 midband frequencies
/// (`10^(n/10)`, so nominal 16 kHz is really 15 848.9 Hz), not at the nominal ones. Evaluating
/// at the nominal center instead reproduces those printed values to within **0.16 dB** (worst
/// case at 160 Hz; 0.11 dB at 20 Hz and at 16 kHz, under 0.1 dB everywhere else). Evaluating at
/// the exact center matches the table to 0.05 dB. The nominal center is used because the spec
/// asks for it, and because 0.16 dB on one band is nothing beside a 2 dB calibration
/// uncertainty — but the difference is real, so it is written down rather than glossed over.
/// `ThirdOctaveBands.exactCenterHz(nominalHz:)` gives the other frequency if it is ever wanted.
public enum AWeighting {
    /// Pole frequencies of IEC 61672-1 clause 5.4.6, in Hz.
    public static let f1 = 20.598_997
    public static let f2 = 107.652_65
    public static let f3 = 737.862_23
    public static let f4 = 12_194.217

    /// The un-normalized network response in dB.
    private static func networkDB(_ hz: Double) -> Double {
        let w = hz * hz
        let numerator = f4 * f4 * w * w
        let denominator = (w + f1 * f1)
            * (w + f4 * f4)
            * ((w + f2 * f2) * (w + f3 * f3)).squareRoot()
        guard denominator > 0, numerator > 0 else { return -.infinity }
        return 20 * log10(numerator / denominator)
    }

    /// The network response at 1 kHz — about −2.000 dB, the origin of the published +2.00 constant.
    private static let normalizationDB = networkDB(1_000)

    /// A-weighting in dB at one frequency. 0 dB at 1 kHz by construction.
    public static func dB(atHz hz: Double) -> Double {
        guard hz > 0 else { return -.infinity }
        return networkDB(hz) - normalizationDB
    }

    /// A-weighting in dB at every nominal third-octave center of `ThirdOctaveReading`.
    public static func dB(atHz grid: [Float]) -> [Double] {
        grid.map { dB(atHz: Double($0)) }
    }
}

// MARK: - Third-octave band geometry

/// Edges and in-band sampling for the IEC 61260 third-octave bands Joseon uses.
public enum ThirdOctaveBands {
    /// Base-2 band edge ratio: a third-octave band spans `fc · 2^(±1/6)`.
    public static let edgeRatio = pow(2.0, 1.0 / 6.0)

    /// Lower and upper edge of the band with nominal center `centerHz`.
    public static func edges(centerHz: Double) -> (low: Double, high: Double) {
        (centerHz / edgeRatio, centerHz * edgeRatio)
    }

    /// The exact base-10 midband frequency, `10^(n/10)`, behind a nominal center.
    ///
    /// IEC 61260 labels the bands with round numbers but defines them on the base-10 grid, so
    /// nominal 16 000 Hz is exactly 15 848.9 Hz. Joseon works in nominal centers; this exists
    /// so the difference can be checked rather than assumed. See `AWeighting`.
    public static func exactCenterHz(nominalHz: Double) -> Double {
        guard nominalHz > 0 else { return 0 }
        return pow(10, (10 * log10(nominalHz)).rounded() / 10)
    }

    /// Log-spaced sample frequencies inside one band, edges included.
    ///
    /// Nine points over a third octave is one sample every 1/24 octave, which is finer than
    /// the 1/10-octave grid the embedded curves live on, so the mean below is a true band
    /// mean of the stored curve rather than a re-sampling artefact.
    public static let samplesPerBand = 9

    public static func sampleFrequencies(centerHz: Double) -> [Double] {
        guard centerHz > 0 else { return [] }
        let (low, high) = edges(centerHz: centerHz)
        let step = log(high / low) / Double(samplesPerBand - 1)
        return (0..<samplesPerBand).map { low * exp(step * Double($0)) }
    }

    /// Mean level of a curve across one band, averaged **in the dB domain**.
    ///
    /// The dB-domain mean is the spec's choice and is the right one here: the curve is a
    /// transfer function, not a spectrum, so its band value should be the mean gain in dB,
    /// not the energy mean of a gain (which would bias every band towards its peak).
    public static func meanDB(of interpolator: CurveInterpolator, centerHz: Double) -> Double {
        let samples = sampleFrequencies(centerHz: centerHz)
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for f in samples { sum += Double(interpolator.level(atHz: Float(f))) }
        return sum / Double(samples.count)
    }
}

// MARK: - Diffuse-field reference

/// The diffuse-field ear response that turns an eardrum level into a diffuse-field-equivalent level.
///
/// Noise-dose limits (NIOSH, WHO-ITU H.870) are written for sound measured in a free or diffuse
/// field, in the absence of the listener. A headphone level is measured at an eardrum simulator.
/// ISO 11904-1 bridges the two: subtract the ear's own diffuse-field transfer function from the
/// eardrum level and what remains is the diffuse-field-equivalent level the limits refer to.
///
/// The shape comes from the embedded "Diffuse field GRAS KEMAR" target, taken relative to its own
/// 800–1250 Hz mean — the same normalization `HeadphoneModel` applies to every curve. The shape
/// alone leaves the absolute level undefined, which is what `absoluteOffsetAt1kHzDB` supplies.
public enum DiffuseFieldReference {
    /// Absolute diffuse-field-to-eardrum offset at 1 kHz, in dB.
    ///
    /// See `docs/third-party-sensitivity.md`, section "Diffuse-field offset", for why this value
    /// is what it is. It is deliberately one named constant so that a later, citable figure is a
    /// one-line change and so that no caller can smear an unverified number through the code.
    public static let absoluteOffsetAt1kHzDB: Double = DiffuseFieldOffsetDecision.valueDB

    /// Human-readable provenance of `absoluteOffsetAt1kHzDB`, shown in the calibration UI.
    public static let absoluteOffsetSource: String = DiffuseFieldOffsetDecision.source

    /// The embedded diffuse-field target, normalized to 0 dB over 800–1250 Hz.
    public static let normalizedCurve: HeadphoneCurve = EmbeddedCurves.diffuseFieldKemar.normalizedTo1kHz()

    /// The full diffuse-field ear response in dB: the normalized shape plus the absolute offset.
    public static func responseDB(atHz hz: Double) -> Double {
        Double(CurveInterpolator(curve: normalizedCurve).level(atHz: Float(hz))) + absoluteOffsetAt1kHzDB
    }
}
