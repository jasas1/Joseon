import Accelerate
import Foundation
import JoseonCore

/// A measured magnitude response. `frequenciesHz` ascending; `levelsDB` raw dB from the file.
public struct HeadphoneCurve: Equatable, Sendable {
    public var name: String
    public var source: String
    public var frequenciesHz: [Float]
    public var levelsDB: [Float]
    public init(name: String, source: String, frequenciesHz: [Float], levelsDB: [Float]) {
        self.name = name; self.source = source; self.frequenciesHz = frequenciesHz; self.levelsDB = levelsDB
    }
}

public enum CurveParseError: Error { case noData, badRow(Int) }

// MARK: - Curve math

extension HeadphoneCurve {
    /// Lowest and highest measured frequency. `(0, 0)` when the curve is empty.
    public var rangeHz: (low: Float, high: Float) {
        guard let lo = frequenciesHz.first, let hi = frequenciesHz.last else { return (0, 0) }
        return (lo, hi)
    }

    /// Mean level over 800–1250 Hz — the reference that normalization subtracts.
    ///
    /// Falls back to the interpolated 1 kHz level when no measured point lands in the band.
    public var referenceLevelDB: Float {
        var sum: Float = 0
        var n = 0
        for (i, f) in frequenciesHz.enumerated() where f >= 800 && f <= 1250 {
            sum += levelsDB[i]
            n += 1
        }
        guard n > 0 else { return CurveInterpolator(curve: self).level(atHz: 1_000) }
        return sum / Float(n)
    }

    /// The same curve shifted so that `referenceLevelDB` becomes 0 dB.
    public func normalizedTo1kHz() -> HeadphoneCurve {
        let ref = referenceLevelDB
        guard ref != 0 else { return self }
        var out = self
        out.levelsDB = levelsDB.map { $0 - ref }
        return out
    }
}

/// Linear-in-dB interpolation over log frequency. Flat (clamped) beyond the measured ends.
///
/// The log of every measured frequency is computed once, so resampling a whole
/// display grid is one pass with a moving cursor.
public struct CurveInterpolator: Sendable {
    public let curve: HeadphoneCurve
    private let logF: [Float]

    public init(curve: HeadphoneCurve) {
        self.curve = curve
        self.logF = curve.frequenciesHz.map { Foundation.log($0 > 0 ? $0 : Float.leastNormalMagnitude) }
    }

    /// Level in dB at one frequency.
    public func level(atHz hz: Float) -> Float {
        let levels = curve.levelsDB
        guard let first = levels.first, let last = levels.last else { return 0 }
        guard levels.count > 1 else { return first }
        let x = Foundation.log(max(hz, Float.leastNormalMagnitude))
        if x <= logF[0] { return first }
        if x >= logF[logF.count - 1] { return last }
        var lo = 0
        var hi = logF.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if logF[mid] <= x { lo = mid } else { hi = mid }
        }
        let span = logF[hi] - logF[lo]
        guard span > 0 else { return levels[lo] }
        let t = (x - logF[lo]) / span
        return levels[lo] + t * (levels[hi] - levels[lo])
    }

    /// Level in dB on a whole ascending frequency grid.
    public func levels(atHz grid: [Float]) -> [Float] {
        let levels = curve.levelsDB
        guard let first = levels.first, let last = levels.last else {
            return [Float](repeating: 0, count: grid.count)
        }
        guard levels.count > 1 else { return [Float](repeating: first, count: grid.count) }
        var out = [Float](repeating: 0, count: grid.count)
        var cursor = 0
        let n = logF.count
        for (i, hz) in grid.enumerated() {
            let x = Foundation.log(max(hz, Float.leastNormalMagnitude))
            if x <= logF[0] { out[i] = first; continue }
            if x >= logF[n - 1] { out[i] = last; continue }
            // Grids are ascending, so the cursor only ever moves forward.
            if logF[cursor] > x { cursor = 0 }
            while cursor + 1 < n - 1 && logF[cursor + 1] <= x { cursor += 1 }
            let span = logF[cursor + 1] - logF[cursor]
            if span > 0 {
                let t = (x - logF[cursor]) / span
                out[i] = levels[cursor] + t * (levels[cursor + 1] - levels[cursor])
            } else {
                out[i] = levels[cursor]
            }
        }
        return out
    }
}

// MARK: - Parser

public enum AutoEQParser {
    /// Characters that separate the two numbers on a data row.
    private static let separators = CharacterSet(charactersIn: ",;\t ")

    /// Parse an AutoEQ-style CSV ("frequency,raw,..." header, or two plain columns "freq,dB", comma/tab/space separated).
    ///
    /// Rules:
    /// - `#` and `*` start a comment line (REW exports use both).
    /// - A header line is recognised when it holds the word `frequency`. The level
    ///   column is then `raw` when present — never `smoothed`, `target` or any
    ///   `equalized_*` column — otherwise the column after `frequency`.
    /// - Rows that do not hold two finite numbers, or a positive frequency, are dropped.
    /// - Points are sorted ascending; duplicate frequencies are averaged.
    /// - Fewer than 8 surviving points throws `CurveParseError.noData`.
    public static func parse(csv: String, name: String, source: String) throws -> HeadphoneCurve {
        var freqColumn = 0
        var levelColumn = 1
        var sawHeader = false
        var points: [(f: Float, db: Float)] = []

        // `Character.isNewline` covers LF, CR and the single CRLF grapheme that
        // Windows and REW exports produce.
        for rawLine in csv.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") || line.hasPrefix("*") || line.hasPrefix("//") { continue }

            let fields = line
                .components(separatedBy: separators)
                .filter { !$0.isEmpty }
            if fields.count < 2 { continue }

            if !sawHeader, points.isEmpty {
                let lowered = fields.map { $0.lowercased() }
                if let fi = lowered.firstIndex(where: { $0.hasPrefix("frequency") || $0 == "freq" || $0 == "hz" }) {
                    sawHeader = true
                    freqColumn = fi
                    if let ri = lowered.firstIndex(of: "raw") {
                        levelColumn = ri
                    } else {
                        levelColumn = fi + 1 < fields.count ? fi + 1 : min(1, fields.count - 1)
                    }
                    continue
                }
            }

            guard fields.count > freqColumn, fields.count > levelColumn else { continue }
            guard let f = Float(fields[freqColumn]), let db = Float(fields[levelColumn]) else { continue }
            guard f.isFinite, db.isFinite, f > 0 else { continue }
            points.append((f, db))
        }

        points.sort { $0.f < $1.f }

        // Average duplicate frequencies so the interpolator sees a strictly rising grid.
        var freqs: [Float] = []
        var levels: [Float] = []
        freqs.reserveCapacity(points.count)
        levels.reserveCapacity(points.count)
        var i = 0
        while i < points.count {
            var j = i
            var sum: Float = 0
            while j < points.count && points[j].f == points[i].f {
                sum += points[j].db
                j += 1
            }
            freqs.append(points[i].f)
            levels.append(sum / Float(j - i))
            i = j
        }

        guard freqs.count >= 8 else { throw CurveParseError.noData }
        return HeadphoneCurve(name: name, source: source, frequenciesHz: freqs, levelsDB: levels)
    }
}

// MARK: - Library

public final class HeadphoneLibrary {
    /// Where imported user curves live. Injectable so tests can use a temp directory.
    public let userCurvesDirectory: URL
    private let fileManager: FileManager

    /// `~/Library/Application Support/Joseon/Curves`.
    public static var defaultUserCurvesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Joseon/Curves", isDirectory: true)
    }

    /// Extensions the library reads out of the user curves directory.
    public static let userCurveExtensions: Set<String> = ["csv", "txt"]

    public init() {
        self.userCurvesDirectory = HeadphoneLibrary.defaultUserCurvesDirectory
        self.fileManager = .default
    }

    public init(userCurvesDirectory: URL, fileManager: FileManager = .default) {
        self.userCurvesDirectory = userCurvesDirectory
        self.fileManager = fileManager
    }

    /// Curves embedded in the module source plus curves the user imported.
    public func allCurves() -> [HeadphoneCurve] {
        EmbeddedCurves.headphones + userCurves()
    }

    /// Target curves embedded in the module source, for example "Harman over-ear 2018".
    public func allTargets() -> [HeadphoneCurve] {
        EmbeddedCurves.targets
    }

    /// Curves parsed out of `userCurvesDirectory`, sorted by name. Unreadable files are skipped.
    public func userCurves() -> [HeadphoneCurve] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: userCurvesDirectory.path) else { return [] }
        var out: [HeadphoneCurve] = []
        for name in names.sorted() {
            let url = userCurvesDirectory.appendingPathComponent(name)
            guard Self.userCurveExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let curve = try? parseFile(at: url) else { continue }
            out.append(curve)
        }
        return out
    }

    /// Copy a CSV into ~/Library/Application Support/Joseon/Curves and return the parsed curve.
    ///
    /// The file is parsed before it is copied, so a bad file never lands in the library.
    @discardableResult
    public func importCurve(from url: URL) throws -> HeadphoneCurve {
        let curve = try parseFile(at: url)
        try fileManager.createDirectory(at: userCurvesDirectory, withIntermediateDirectories: true)
        let destination = userCurvesDirectory.appendingPathComponent(url.lastPathComponent)
        if destination.standardizedFileURL != url.standardizedFileURL {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: url, to: destination)
        }
        return curve
    }

    /// First curve with this name, embedded or user, or nil.
    public func curve(named name: String) -> HeadphoneCurve? {
        allCurves().first { $0.name == name }
    }

    /// First target with this name, or nil.
    public func target(named name: String) -> HeadphoneCurve? {
        allTargets().first { $0.name == name }
    }

    private func parseFile(at url: URL) throws -> HeadphoneCurve {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let name = url.deletingPathExtension().lastPathComponent
        return try AutoEQParser.parse(csv: text, name: name, source: "User import")
    }
}

// MARK: - Model

/// One headphone curve (and an optional target) applied to the live spectrum, plus the stress flags.
///
/// Threading: the engine calls `evaluate` and `reset` on the analysis queue, while the app may set
/// `thresholds` or call `resetFlags` on the main thread. One lock guards all mutable state (thresholds,
/// the resample cache, the detector's gates and window cache). It is uncontended in practice, so it
/// costs a few tens of nanoseconds per `evaluate`. Everything else is immutable after `init`.
public final class HeadphoneModel: HeadphoneModeling, @unchecked Sendable {
    public let curve: HeadphoneCurve
    public let target: HeadphoneCurve?
    public var modelName: String { curve.name }

    /// Thresholds for `stressFlags`. Change them at any time, from any thread; the detector picks them up next call.
    public var thresholds: StressThresholds {
        get { lock.withLock { _thresholds } }
        set { lock.withLock { _thresholds = newValue } }
    }
    private var _thresholds: StressThresholds
    private let lock = NSLock()

    /// Curve and target normalized to 0 dB at 1 kHz, on the curve's own frequency grid.
    public let normalizedCurve: HeadphoneCurve
    public let normalizedTarget: HeadphoneCurve?

    private let curveInterpolator: CurveInterpolator
    private let targetInterpolator: CurveInterpolator?

    private let detector: StressDetector
    /// Curve, target and names in the shape the detector wants. Built once.
    public let stressContext: StressContext

    // Resample cache — keyed on the display frequency grid.
    private var cachedFrequencies: [Float] = []
    private var cachedResponseDB: [Float] = []
    private var cachedTargetDB: [Float] = []

    public convenience init(curve: HeadphoneCurve, target: HeadphoneCurve?) {
        self.init(curve: curve, target: target, thresholds: StressThresholds())
    }

    /// - Parameter now: monotonic seconds, injected so tests can drive the flag hysteresis.
    public init(
        curve: HeadphoneCurve,
        target: HeadphoneCurve?,
        thresholds: StressThresholds,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.curve = curve
        self.target = target
        self._thresholds = thresholds
        let nc = curve.normalizedTo1kHz()
        let nt = target?.normalizedTo1kHz()
        self.normalizedCurve = nc
        self.normalizedTarget = nt
        self.curveInterpolator = CurveInterpolator(curve: nc)
        let ti = nt.map { CurveInterpolator(curve: $0) }
        self.targetInterpolator = ti
        self.detector = StressDetector(now: now)
        self.stressContext = StressContext(
            curveName: nc.name,
            targetName: nt?.name,
            curveFrequencies: nc.frequenciesHz,
            curveLevels: nc.levelsDB,
            targetLevels: ti?.levels(atHz: nc.frequenciesHz)
        )
    }

    /// Headphone response in dB on `grid`, normalized to 0 dB at 1 kHz.
    public func responseDB(onGrid grid: [Float]) -> [Float] {
        curveInterpolator.levels(atHz: grid)
    }

    /// Target in dB on `grid`, or zeros when there is no target.
    public func targetDB(onGrid grid: [Float]) -> [Float] {
        targetInterpolator?.levels(atHz: grid) ?? [Float](repeating: 0, count: grid.count)
    }

    public func evaluate(spectrum: SpectrumReading, bands: BandEnergy, loudness: LoudnessReading) -> HeadphoneReading {
        lock.lock()
        defer { lock.unlock() }
        let grid = spectrum.frequencies
        if cachedFrequencies != grid {
            cachedFrequencies = grid
            cachedResponseDB = responseDB(onGrid: grid)
            cachedTargetDB = targetDB(onGrid: grid)
        }
        let response = cachedResponseDB
        let mid = spectrum.mid
        let n = min(mid.count, response.count)
        var predicted = [Float](repeating: SpectrumReading.floorDB, count: grid.count)
        predicted.withUnsafeMutableBufferPointer { p in
            mid.withUnsafeBufferPointer { m in
                response.withUnsafeBufferPointer { r in
                    guard let p = p.baseAddress, let m = m.baseAddress, let r = r.baseAddress else { return }
                    vDSP_vadd(m, 1, r, 1, p, 1, vDSP_Length(n))
                }
            }
        }

        let flags = detector.evaluate(spectrum: spectrum, bands: bands, loudness: loudness, thresholds: _thresholds, context: stressContext)
        return HeadphoneReading(
            modelName: modelName,
            responseDB: response,
            targetDB: cachedTargetDB,
            hasTarget: targetInterpolator != nil,
            predictedAtEarDB: predicted,
            stressFlags: flags
        )
    }

    /// Flags that describe what this music asks of this headphone and of the chain.
    ///
    /// Each flag has hysteresis. A level flag goes up only after its condition has held
    /// for `thresholds.levelAttackSeconds` and comes down only after its value has stayed
    /// `thresholds.releaseMarginDB` under the threshold for `thresholds.holdSeconds`, so a
    /// value sitting on the threshold gives one continuous flag or none. Event flags —
    /// clipped samples, inter-sample overs — latch until `resetFlags()`.
    public func stressFlags(spectrum: SpectrumReading, bands: BandEnergy, loudness: LoudnessReading) -> [StressFlag] {
        lock.withLock {
            detector.evaluate(
                spectrum: spectrum,
                bands: bands,
                loudness: loudness,
                thresholds: _thresholds,
                context: stressContext
            )
        }
    }

    /// Host time each flag that is currently up was raised, by flag id, on the same clock
    /// the model was built with.
    ///
    /// The flag texts do not carry the elapsed time: a "· since 1:23" inside `detail`
    /// would rewrite every flag every second, and a panel that diffs its flags would
    /// redraw with it. Ask here instead and format "since mm:ss" at whatever rate the
    /// popover likes. A flag that is still up keeps its first onset, through every
    /// dip inside the hysteresis band, until it really clears or `resetFlags()` runs.
    public func flagOnsets() -> [String: TimeInterval] {
        lock.withLock { detector.flagOnsets() }
    }

    /// `HeadphoneModeling`: the engine calls this when the measurement resets.
    public func reset() { resetFlags() }

    /// Drop the hysteresis state (new track, new measurement).
    public func resetFlags() {
        lock.withLock { detector.reset() }
    }
}
