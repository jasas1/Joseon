import Foundation
import JoseonCore

/// Published sensitivity and impedance for the embedded headphones.
///
/// **Every figure here came off the manufacturer's own page or data sheet on 2026-09-21.**
/// Nothing is remembered, inferred, averaged from reviews, or carried over from a similar
/// model. `docs/third-party-sensitivity.md` lists each URL, the spec line exactly as printed,
/// and what was checked and not found.
///
/// A headphone whose maker publishes no usable figure is **not in this library**. It is in
/// `unlisted` instead, with the reason, so the app can say why it is asking the user to type
/// a number rather than silently showing a wrong one. Six of the twelve embedded curves are
/// in that state, including the first user's own HiFiMAN Susvara Unveiled.
///
/// Keys are the same `HeadphoneCurve.name` strings `HeadphoneLibrary` uses.
public enum HeadphoneSensitivityLibrary {

    // MARK: - Why a headphone can be missing

    /// A headphone Joseon has a curve for but no citable sensitivity.
    public struct Unlisted: Equatable, Sendable {
        /// The curve name, as `HeadphoneLibrary` spells it.
        public var name: String
        /// What the manufacturer publishes, or does not, in one sentence for the UI.
        public var reason: String
        /// The page that was checked, so the user can look for themselves.
        public var checkedURL: String

        public init(name: String, reason: String, checkedURL: String) {
            self.name = name; self.reason = reason; self.checkedURL = checkedURL
        }
    }

    /// Curves with no citable sensitivity. The app must ask the user to measure or type one.
    public static let unlisted: [Unlisted] = [
        Unlisted(
            name: "HiFiMAN Susvara Unveiled",
            reason: "HiFiMAN publishes \"86dB\" with no reference — not per milliwatt, not per volt, no frequency. An unreferenced dB figure cannot be converted, so Joseon will not guess one.",
            checkedURL: "https://www.hifiman.com/products/detail/347"
        ),
        Unlisted(
            name: "HiFiMAN Susvara",
            reason: "HiFiMAN publishes \"83dB\" with no reference, the same as the Unveiled. Not convertible.",
            checkedURL: "https://www.hifiman.com/products/detail/275"
        ),
        Unlisted(
            name: "Meze Empyrean (leather earpads)",
            reason: "Meze has retired the first-generation Empyrean; its product page is gone. Empyrean II is a different driver, so its 90 dB SPL/mW does not carry over.",
            checkedURL: "https://mezeaudio.com/products/meze-empyrean"
        ),
        Unlisted(
            name: "ZMF Verite",
            reason: "ZMF has retired the Verite. The remaining page has no specification table — only prose about the driver.",
            checkedURL: "https://www.zmfheadphones.com/verite/"
        ),
        Unlisted(
            name: "Apple AirPods Max",
            reason: "Apple publishes no sensitivity or impedance for any AirPods model.",
            checkedURL: "https://www.apple.com/airpods-max/specs/"
        ),
        Unlisted(
            name: "Apple AirPods Pro 2",
            reason: "Apple publishes no sensitivity or impedance for any AirPods model.",
            checkedURL: "https://support.apple.com/en-us/111851"
        ),
    ]

    // MARK: - Verified entries

    /// Sennheiser prints "Sound pressure level (SPL) 97 dB (1 V)" — already dB SPL per volt,
    /// which is what `HeadphoneSensitivity.dbSPLPerVolt` is, so nothing is converted.
    public static let hd600 = HeadphoneSensitivity(
        dbSPLPerVolt: 97,
        impedanceOhms: 300,
        source: "Sennheiser HD 600 product page, \"Sound pressure level (SPL) 97 dB (1 V)\", 300 Ω — us.sennheiser-hearing.com/products/hd-600, fetched 2026-09-21"
    )

    public static let hd650 = HeadphoneSensitivity(
        dbSPLPerVolt: 103,
        impedanceOhms: 300,
        source: "Sennheiser HD 650 product page, \"Sound pressure level (SPL) 103 dB (1 V)\", 300 Ω — us.sennheiser-hearing.com/products/hd-650, fetched 2026-09-21"
    )

    public static let hd800s = HeadphoneSensitivity(
        dbSPLPerVolt: 102,
        impedanceOhms: 300,
        source: "Sennheiser HD 800 S product page, \"Sound pressure level (SPL) 102 dB (1 V)\", 300 Ω — us.sennheiser-hearing.com/products/hd-800-s, fetched 2026-09-21"
    )

    /// Focal's *product data sheet* prints "Sensitivity 104dB SPL / 1mW @ 1kHz" with 80 Ω.
    /// Careful: the web product page prints "Maximum SPL (peak@1m) : 104 dB SPL", a different
    /// quantity that happens to share the number. The data sheet is the figure used here.
    public static let focalUtopia = HeadphoneSensitivity.fromDBPerMilliwatt(
        104,
        impedanceOhms: 80,
        source: "Focal Utopia product data sheet (v1, 07/07/2022), \"Sensitivity 104dB SPL / 1mW @ 1kHz\", 80 Ohms — dam.focal-naim.com/m/60e16a1d4cab5a65/original/FP_Utopia_EN-pdf.pdf, fetched 2026-09-21"
    )

    /// Audeze states the figure at the Drum Reference Point, which is the reference the SPL
    /// chain wants: `dbSPLPerVolt` is defined at the eardrum simulator.
    public static let lcdX = HeadphoneSensitivity.fromDBPerMilliwatt(
        103,
        impedanceOhms: 20,
        source: "Audeze LCD-X product page, \"Sensitivity 103 dB/1mW (at Drum Reference Point)\", 20 ohms — audeze.com/products/lcd-x, fetched 2026-09-21 (the page states no model year; the embedded curve is the 2021 revision)"
    )

    /// Sony does publish a figure, in the Help Guide rather than on the product page, and only
    /// for the wired connection. Joseon can only see a wired chain's voltage anyway, so the
    /// "headset turned on" row is the one that applies. Passive (off) is 100 dB/mW into 16 Ω.
    public static let sonyWH1000XM5 = HeadphoneSensitivity.fromDBPerMilliwatt(
        102,
        impedanceOhms: 48,
        source: "Sony WH-1000XM5 Help Guide specifications, \"Sensitivity: 102 dB/mW (when connecting via the headphone cable with the headset turned on)\", 48 Ω (1 kHz) — helpguide.sony.net/mdr/wh1000xm5/v1/en/contents/TP1000541014.html, fetched 2026-09-21"
    )

    // MARK: - Lookup

    /// Every verified entry, keyed by the curve name `HeadphoneLibrary` uses.
    public static let byCurveName: [String: HeadphoneSensitivity] = [
        "Sennheiser HD 600": hd600,
        "Sennheiser HD 650": hd650,
        "Sennheiser HD 800 S": hd800s,
        "Focal Utopia": focalUtopia,
        "Audeze LCD-X (2021)": lcdX,
        "Sony WH-1000XM5": sonyWH1000XM5,
    ]

    /// Published sensitivity for a curve name, or `nil` when the maker publishes none.
    ///
    /// `nil` is a real answer, not a failure: it means "ask the user". Show `reason(for:)`
    /// next to that question.
    public static func sensitivity(forCurveNamed name: String) -> HeadphoneSensitivity? {
        byCurveName[name]
    }

    /// Why there is no figure for this curve name, for the UI to show beside the input field.
    public static func reason(forCurveNamed name: String) -> String? {
        unlisted.first { $0.name == name }?.reason
    }

    /// A sensitivity the user typed or measured. `source` is fixed to "User" so a typed number
    /// can never be mistaken for a published one anywhere downstream.
    public static func userEntered(dbSPLPerVolt: Double, impedanceOhms: Double) -> HeadphoneSensitivity {
        HeadphoneSensitivity(dbSPLPerVolt: dbSPLPerVolt, impedanceOhms: impedanceOhms, source: "User")
    }

    /// The same, from a dB/mW figure off a box or a review the user trusts.
    public static func userEntered(dbPerMilliwatt: Double, impedanceOhms: Double) -> HeadphoneSensitivity {
        HeadphoneSensitivity.fromDBPerMilliwatt(dbPerMilliwatt, impedanceOhms: impedanceOhms, source: "User")
    }

    /// True when the sensitivity did not come from a manufacturer — the UI must say so.
    public static func isUserEntered(_ sensitivity: HeadphoneSensitivity) -> Bool {
        sensitivity.source == "User"
    }
}
