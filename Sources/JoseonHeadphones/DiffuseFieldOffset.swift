import Foundation

/// The one place the absolute diffuse-field-to-eardrum offset at 1 kHz is written down.
///
/// The value is **4.1 dB**, taken from a published table, not estimated:
///
/// > Hammershøi, D. and Møller, H., "Determination of Noise Immission From Sound Sources
/// > Close to the Ears", *Acta Acustica united with Acustica* **94**(1), 2008, 114–129.
/// > DOI 10.3813/AAA.918014. **Table II**, column `ΔL_DF [dB] / ED`, row `1000` Hz.
///
/// Table II is printed under the section heading "3.3. Literature data for ISO 11904-1",
/// so this is the quantity ISO 11904-1 subtracts, measured at the **eardrum** (ED), in a
/// **diffuse** field — not the free-field column and not the blocked-entrance column, which
/// the same table lists separately and which differ (2.7 dB and 2.3 dB at 1 kHz).
///
/// Sign: ISO 11904 subtracts. A 90 dB SPL at the eardrum at 1 kHz is an 85.9 dB
/// diffuse-field-equivalent level, and `SPLEstimator` subtracts accordingly.
///
/// Verified on 2026-09-21 by reading the open-access PDF's own text, not a secondary source.
/// See `docs/third-party-sensitivity.md`, section "Diffuse-field offset", for the full row,
/// the cross-check against the embedded KEMAR shape, and what remains unverified.
public enum DiffuseFieldOffsetDecision {
    /// dB, added to the normalized diffuse-field shape. See the type documentation.
    public static let valueDB: Double = 4.1

    /// Shown in the calibration sheet next to the level, so the user can see what it rests on.
    public static let source: String =
        "Hammershøi & Møller 2008, Acta Acustica 94(1), Table II, ΔL_DF eardrum at 1 kHz (ISO 11904-1 literature data)"

    /// Table II's `ΔL_DF [dB] / ED` column, by nominal third-octave center, transcribed from
    /// the paper. Used by the tests to check that the embedded KEMAR shape plus `valueDB`
    /// reproduces an independent measurement of the same physical quantity.
    ///
    /// The paper prints a single row "≤ 100" for everything at and below 100 Hz.
    public static let publishedEardrumDiffuseFieldDB: [(hz: Double, dB: Double)] = [
        (100, 0.0), (125, 0.2), (160, 0.4), (200, 0.6), (250, 0.8), (315, 1.1),
        (400, 1.5), (500, 2.1), (630, 2.8), (800, 3.3), (1_000, 4.1), (1_250, 5.5),
        (1_600, 7.7), (2_000, 11.0), (2_500, 15.3), (3_150, 15.7), (4_000, 12.9),
        (5_000, 10.6), (6_300, 9.4), (8_000, 9.5), (10_000, 6.8), (12_500, 3.8), (16_000, 0.7),
    ]
}
