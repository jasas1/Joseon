import Foundation

/// A parsed calibration file: frequency / dB pairs, plus the sensitivity header when the file
/// carries one.
///
/// Handles the three things people actually have:
///
/// - **miniDSP UMIK-1 / UMIK-2** — a quoted header line `"Sens Factor =-1.2dB, SERNO: 7012345"`
///   followed by tab-separated frequency, dB, phase.
/// - **REW and friends** — `*` or `#` comment lines, then two or three columns separated by
///   commas, tabs or spaces.
/// - Anything else with two numbers per line.
///
/// A 0° file and a 90° file are just different files; Joseon does not know which one is loaded
/// and says so in the measurement's warnings.
public struct MicCalibration: Sendable, Equatable {

    public var name: String
    /// Where it came from — a file name, for the measurement's method note.
    public var source: String
    /// Ascending, strictly rising, positive.
    public var frequenciesHz: [Double]
    /// The microphone's deviation in dB. Subtract it from a measurement to remove the mic.
    public var levelsDB: [Double]
    /// The `Sens Factor` value in dB, when the file had one.
    public var sensFactorDB: Double?
    /// True when the file carried a third (phase) column. The phase is read and discarded:
    /// nothing in this module uses microphone phase.
    public var hasPhaseColumn: Bool

    public init(
        name: String,
        source: String,
        frequenciesHz: [Double],
        levelsDB: [Double],
        sensFactorDB: Double? = nil,
        hasPhaseColumn: Bool = false
    ) {
        self.name = name
        self.source = source
        self.frequenciesHz = frequenciesHz
        self.levelsDB = levelsDB
        self.sensFactorDB = sensFactorDB
        self.hasPhaseColumn = hasPhaseColumn
    }

    /// Parse the text of a calibration file.
    ///
    /// - Throws: `CurveParseError.noData` when fewer than four usable rows survive.
    public static func parse(text: String, name: String, source: String = "") throws -> MicCalibration {
        let parsed = try CalibrationFileParser.parse(text: text)
        return MicCalibration(
            name: name,
            source: source.isEmpty ? name : source,
            frequenciesHz: parsed.frequenciesHz,
            levelsDB: parsed.levelsDB,
            sensFactorDB: parsed.sensFactorDB,
            hasPhaseColumn: parsed.hasPhaseColumn
        )
    }

    /// The same data as a `HeadphoneCurve`, so the module's interpolator can be used on it.
    public var curve: HeadphoneCurve {
        HeadphoneCurve(
            name: name,
            source: source,
            frequenciesHz: frequenciesHz.map(Float.init),
            levelsDB: levelsDB.map(Float.init)
        )
    }

    /// The correction in dB on a frequency grid: flat beyond the ends of the file, linear in dB
    /// over log frequency between its points.
    public func correctionDB(onGrid grid: [Double]) -> [Double] {
        let interpolator = CurveInterpolator(curve: curve)
        return interpolator.levels(atHz: grid.map(Float.init)).map(Double.init)
    }

    /// Remove the microphone from a measured magnitude response: subtract the correction.
    public func apply(toMagnitudeDB magnitude: [Double], onGrid grid: [Double]) -> [Double] {
        let correction = correctionDB(onGrid: grid)
        return zip(magnitude, correction).map { $0 - $1 }
    }

    // MARK: - Absolute sensitivity

    /// The dBFS level a UMIK-style microphone is taken to produce at 94 dB SPL when its
    /// `Sens Factor` is 0 dB.
    ///
    /// **This is a convention, not a measurement.** miniDSP states the UMIK sensitivity factor
    /// relative to a fixed digital reference, and this is that reference as Joseon understands
    /// it. It has never been checked here against a real microphone, because there is no
    /// microphone yet. Anything derived from it carries `sensFactorUncertaintyDB`, and the app
    /// must offer the acoustic-calibrator route as the trustworthy one.
    public static let sensFactorReferenceDBFS: Double = -18.0

    /// Uncertainty Joseon assigns to the `Sens Factor` route, in dB, one side.
    public static let sensFactorUncertaintyDB: Double = 2.0

    /// dBFS per pascal from the `Sens Factor` header, or `nil` when the file had none.
    ///
    /// 1 Pa is 94 dB SPL, so this is the digital RMS level (in the convention where a full-scale
    /// sine reads −3.01 dBFS) that 94 dB SPL at 1 kHz produces.
    public func micSensitivityDBFSPerPascal(
        referenceDBFS: Double = MicCalibration.sensFactorReferenceDBFS
    ) -> Double? {
        guard let sens = sensFactorDB else { return nil }
        return referenceDBFS + sens
    }
}

/// An optional correction for the rig the headphone sits on.
///
/// A standards-type ear simulator (IEC 60318-4) needs none: its transfer impedance is the
/// reference. A flat plate, a home-made coupler or a cheap silicone ear needs one, and the only
/// honest source for it is a curve the user got from whoever characterised the rig. Same file
/// format as a microphone calibration, same subtraction.
public struct CouplerCorrection: Sendable, Equatable {
    public var name: String
    public var source: String
    public var frequenciesHz: [Double]
    public var levelsDB: [Double]

    public init(name: String, source: String, frequenciesHz: [Double], levelsDB: [Double]) {
        self.name = name
        self.source = source
        self.frequenciesHz = frequenciesHz
        self.levelsDB = levelsDB
    }

    public static func parse(text: String, name: String, source: String = "") throws -> CouplerCorrection {
        let parsed = try CalibrationFileParser.parse(text: text)
        return CouplerCorrection(
            name: name,
            source: source.isEmpty ? name : source,
            frequenciesHz: parsed.frequenciesHz,
            levelsDB: parsed.levelsDB
        )
    }

    public var curve: HeadphoneCurve {
        HeadphoneCurve(
            name: name,
            source: source,
            frequenciesHz: frequenciesHz.map(Float.init),
            levelsDB: levelsDB.map(Float.init)
        )
    }

    public func correctionDB(onGrid grid: [Double]) -> [Double] {
        CurveInterpolator(curve: curve).levels(atHz: grid.map(Float.init)).map(Double.init)
    }

    public func apply(toMagnitudeDB magnitude: [Double], onGrid grid: [Double]) -> [Double] {
        zip(magnitude, correctionDB(onGrid: grid)).map { $0 - $1 }
    }
}

// MARK: - The shared parser

/// One tolerant reader for every calibration file shape.
enum CalibrationFileParser {

    struct Parsed {
        var frequenciesHz: [Double]
        var levelsDB: [Double]
        var sensFactorDB: Double?
        var hasPhaseColumn: Bool
    }

    private static let separators = CharacterSet(charactersIn: ",;\t ")

    static func parse(text: String) throws -> Parsed {
        var points: [(f: Double, db: Double)] = []
        var sensFactor: Double?
        var hasPhase = false

        // `Character.isNewline` matches LF, CR and the single CRLF grapheme, so a Windows file
        // needs no special case. Splitting on "\n" would leave a stray "\r" on every row.
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // A quoted line is a header (miniDSP quotes theirs). Unquote before looking inside.
            if line.hasPrefix("\"") {
                line = String(line.drop(while: { $0 == "\"" }))
                if let end = line.lastIndex(of: "\"") { line = String(line[line.startIndex..<end]) }
            }
            if sensFactor == nil, let value = sensFactorValue(in: line) {
                sensFactor = value
                continue
            }
            if line.hasPrefix("#") || line.hasPrefix("*") || line.hasPrefix("//") || line.hasPrefix(";") {
                continue
            }

            let fields = line.components(separatedBy: separators).filter { !$0.isEmpty }
            guard fields.count >= 2 else { continue }
            if fields.count >= 3, Double(fields[2]) != nil { hasPhase = true }
            guard let f = Double(fields[0]), let db = Double(fields[1]) else { continue }
            guard f.isFinite, db.isFinite, f > 0 else { continue }
            points.append((f, db))
        }

        points.sort { $0.f < $1.f }
        var freqs: [Double] = []
        var levels: [Double] = []
        var i = 0
        while i < points.count {
            var j = i
            var sum = 0.0
            while j < points.count && points[j].f == points[i].f {
                sum += points[j].db
                j += 1
            }
            freqs.append(points[i].f)
            levels.append(sum / Double(j - i))
            i = j
        }

        guard freqs.count >= 4 else { throw CurveParseError.noData }
        return Parsed(frequenciesHz: freqs, levelsDB: levels, sensFactorDB: sensFactor, hasPhaseColumn: hasPhase)
    }

    /// `Sens Factor =-1.2dB, SERNO: 7012345` → `-1.2`. Case and spacing do not matter, and the
    /// number may be written `-.1`.
    static func sensFactorValue(in line: String) -> Double? {
        let lowered = line.lowercased()
        guard lowered.contains("sens factor") || lowered.contains("sensfactor") else { return nil }
        guard let equals = line.firstIndex(of: "=") else { return nil }
        var digits = ""
        for character in line[line.index(after: equals)...] {
            if character == " " && digits.isEmpty { continue }
            if character.isNumber || character == "." || character == "-" || character == "+"
                || ((character == "e" || character == "E") && !digits.isEmpty && digits.last!.isNumber) {
                digits.append(character)
            } else {
                break
            }
        }
        return Double(digits)
    }
}
