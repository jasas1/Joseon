import Foundation
import JoseonCore

/// How much to believe a measurement.
///
/// Every field is something the user can act on: a low `snrDB` in the bass means measure again
/// in a quiet room, a high `thdPercent` means turn the level down, a large `agreementDB` means
/// the headphone moved between runs.
public struct MeasurementQuality: Sendable, Equatable {
    /// The grid `snrDB` and `agreementSpreadDB` are stated on — the module's 200-point grid.
    public var frequenciesHz: [Float]
    /// Signal-to-noise ratio per grid point, in dB, after the sweep's processing gain.
    /// Empty when no noise-only segment was given.
    public var snrDB: [Float]
    /// Total harmonic distortion (2nd + 3rd) as a percentage, over the whole sweep.
    public var thdPercent: Float
    /// How many runs were averaged.
    public var runs: Int
    /// Mean run-to-run spread of the magnitude over 100 Hz ... 10 kHz, in dB. 0 for one run.
    public var agreementDB: Float
    /// Per-grid-point run-to-run spread. Empty for one run.
    public var agreementSpreadDB: [Float]
    /// Lowest frequency the analysis window can resolve. Below it the curve is the window, not
    /// the headphone. Kept for compatibility: `lowestReliableHz` is the number to show.
    public var lowestResolvedHz: Float
    /// Lowest frequency with at least 10 dB of signal-to-noise. 0 when no noise-only segment was
    /// recorded, which means "not known" rather than "fine down to DC".
    public var noiseLimitedHz: Float
    /// Highest frequency the stimulus drove at full level — the sweep's end frequency with the
    /// fade-out region taken off, under the Nyquist clamp. 0 when not stated. Above it the curve
    /// is held flat, so the UI should stop drawing there.
    public var highestReliableHz: Float
    /// Length of the analysis window in milliseconds.
    public var windowMilliseconds: Float
    /// Plain sentences about what this measurement does and does not show.
    public var warnings: [String]

    public init(
        frequenciesHz: [Float],
        snrDB: [Float],
        thdPercent: Float,
        runs: Int,
        agreementDB: Float,
        agreementSpreadDB: [Float] = [],
        lowestResolvedHz: Float = 0,
        windowMilliseconds: Float = 0,
        warnings: [String] = [],
        noiseLimitedHz: Float = 0,
        highestReliableHz: Float = 0
    ) {
        self.noiseLimitedHz = noiseLimitedHz
        self.highestReliableHz = highestReliableHz
        self.frequenciesHz = frequenciesHz
        self.snrDB = snrDB
        self.thdPercent = thdPercent
        self.runs = runs
        self.agreementDB = agreementDB
        self.agreementSpreadDB = agreementSpreadDB
        self.lowestResolvedHz = lowestResolvedHz
        self.windowMilliseconds = windowMilliseconds
        self.warnings = warnings
    }

    /// Signal-to-noise ratio at one frequency, or `nil` when there is no noise segment.
    public func snrDB(atHz hz: Float) -> Float? {
        guard !snrDB.isEmpty, frequenciesHz.count == snrDB.count else { return nil }
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (i, f) in frequenciesHz.enumerated() {
            let d = abs(log(max(f, 1)) - log(max(hz, 1)))
            if d < bestDistance { bestDistance = d; best = i }
        }
        return snrDB[best]
    }

    /// Lowest frequency where the signal-to-noise ratio is at least `minimumDB`, walking up from
    /// the bottom. `nil` when there is no noise segment.
    public func lowestTrustedHz(minimumDB: Float = 10) -> Float? {
        guard !snrDB.isEmpty, frequenciesHz.count == snrDB.count else { return nil }
        for (i, snr) in snrDB.enumerated() where snr >= minimumDB {
            return frequenciesHz[i]
        }
        return nil
    }

    // MARK: - One lower limit, one cause

    /// **The** lower limit of the measurement: the higher of the noise-limited frequency and the
    /// window-limited one.
    ///
    /// A result page that prints two numbers — "not reliable under 28 Hz" beside "valid above
    /// 10 Hz" — has told the user nothing, because they can not know which one binds. Only this
    /// one is shown, and `lowLimitCause` says which of the two it is so the sentence can name the
    /// fix (a quieter room, or a longer window).
    public var lowestReliableHz: Float { max(noiseLimitedHz, lowestResolvedHz) }

    /// Which limit won. Ties go to the window: it is the one that is always there.
    public var lowLimitCause: LowLimitCause {
        noiseLimitedHz > lowestResolvedHz ? .noise : .window
    }
}

/// What sets the bottom of a measurement.
public enum LowLimitCause: String, Sendable, Equatable, CaseIterable {
    /// Room noise. The fix is a quieter room, more runs, or more level.
    case noise
    /// The analysis window. The fix is a longer window, which needs a quieter room to earn.
    case window

    /// The clause the warning uses after the number.
    public var reason: String {
        switch self {
        case .noise: return "room noise"
        case .window: return "the length of the analysis window"
        }
    }
}

// MARK: - Bass against a published curve

/// How far the measured bass sits under a reference curve — the leak test.
///
/// A headphone that has lost its seal on the rig looks exactly like a first-order high-pass: the
/// bass falls away smoothly and nothing else about the curve changes. Against a published curve
/// of the same model that shows up as a large negative mean over 30–100 Hz, and saving such a
/// curve as "my headphone" would spoil every at-ear estimate that uses it afterwards.
public struct BassShortfall: Sendable, Equatable {
    /// Mean of (measured − reference) over the range, in dB, both curves normalized at 1 kHz.
    /// Negative means the measurement has less bass than the reference.
    public var meanDifferenceDB: Double
    /// The range actually used — 30–100 Hz trimmed to what both curves cover.
    public var lowHz: Double
    public var highHz: Double
    /// How many grid points went into the mean.
    public var pointsUsed: Int
    /// True when the shortfall is worse than `leakThresholdDB`.
    public var likelyLeak: Bool
    /// The sentence for the UI, and for the confirmation sheet before Save.
    public var summary: String

    /// More than 6 dB under the reference is called a likely leak.
    public static let leakThresholdDB: Double = -6

    public init(
        meanDifferenceDB: Double,
        lowHz: Double,
        highHz: Double,
        pointsUsed: Int,
        likelyLeak: Bool,
        summary: String
    ) {
        self.meanDifferenceDB = meanDifferenceDB
        self.lowHz = lowHz
        self.highHz = highHz
        self.pointsUsed = pointsUsed
        self.likelyLeak = likelyLeak
        self.summary = summary
    }
}

/// The result of one measurement session: a curve, maybe a sensitivity, and the quality behind
/// both.
public struct MeasuredHeadphone: Sendable {
    /// Normalized to 0 dB at 1 kHz, on the module's 200-point grid — the same shape as every
    /// embedded curve, so it drops straight into the overlay.
    public var curve: HeadphoneCurve
    /// The measured response **before** normalization, in dB relative to the digital drive, after
    /// the microphone and coupler corrections. This is what the sensitivity derivation reads.
    public var absoluteMagnitudeDB: [Float]
    /// Derived sensitivity, when there was an absolute level reference and a playback calibration.
    public var sensitivity: HeadphoneSensitivity?
    /// The full derivation, including its uncertainty and workings.
    public var derivedSensitivity: DerivedSensitivity?
    public var quality: MeasurementQuality
    /// One sentence naming the method, for the curve's `source` and for the report.
    public var method: String

    public init(
        curve: HeadphoneCurve,
        absoluteMagnitudeDB: [Float],
        sensitivity: HeadphoneSensitivity?,
        derivedSensitivity: DerivedSensitivity?,
        quality: MeasurementQuality,
        method: String
    ) {
        self.curve = curve
        self.absoluteMagnitudeDB = absoluteMagnitudeDB
        self.sensitivity = sensitivity
        self.derivedSensitivity = derivedSensitivity
        self.quality = quality
        self.method = method
    }

    // MARK: - Leak detection

    /// Mean of (measured − reference) over 30–100 Hz, both curves normalized at 1 kHz.
    ///
    /// `nil` when the two curves do not overlap over enough of that range to mean anything — a
    /// reference that stops at 50 Hz is extrapolated flat by the interpolator, and comparing
    /// against an extrapolation would invent a leak or hide one. At least three grid points of
    /// real overlap are required.
    ///
    /// The comparison is the whole point of the range: 30–100 Hz is where a seal leak shows and
    /// where the published comparison line used to stop.
    public func bassShortfall(
        against reference: HeadphoneCurve,
        from requestedLowHz: Double = 30,
        to requestedHighHz: Double = 100
    ) -> BassShortfall? {
        let measured = curve.normalizedTo1kHz()
        let published = reference.normalizedTo1kHz()
        guard let measuredLow = measured.frequenciesHz.first,
              let measuredHigh = measured.frequenciesHz.last,
              let referenceLow = published.frequenciesHz.first,
              let referenceHigh = published.frequenciesHz.last
        else { return nil }

        // Only where both curves have data. Outside that the interpolator clamps, and a clamped
        // value is not a measurement.
        let low = max(requestedLowHz, Double(measuredLow), Double(referenceLow))
        let high = min(requestedHighHz, Double(measuredHigh), Double(referenceHigh))
        guard high > low else { return nil }

        let interpolator = CurveInterpolator(curve: published)
        var sum = 0.0
        var used = 0
        for (i, f) in measured.frequenciesHz.enumerated() where Double(f) >= low && Double(f) <= high {
            let difference = Double(measured.levelsDB[i]) - Double(interpolator.level(atHz: f))
            guard difference.isFinite else { continue }
            sum += difference
            used += 1
        }
        guard used >= 3 else { return nil }

        let mean = sum / Double(used)
        let leak = mean < BassShortfall.leakThresholdDB
        let range = "\(String(format: "%.0f", low)) Hz and \(String(format: "%.0f", high)) Hz"
        let size = String(format: "%.0f", abs(mean))
        let summary: String
        if leak {
            summary = "Bass is \(size) dB under \(referenceName(published)) between \(range): likely a seal leak on the rig. Reseat the headphone and measure again before saving this curve."
        } else if mean < 0 {
            summary = "Bass is \(size) dB under \(referenceName(published)) between \(range)."
        } else {
            summary = "Bass is \(size) dB over \(referenceName(published)) between \(range)."
        }
        return BassShortfall(
            meanDifferenceDB: mean,
            lowHz: low,
            highHz: high,
            pointsUsed: used,
            likelyLeak: leak,
            summary: summary
        )
    }

    private func referenceName(_ reference: HeadphoneCurve) -> String {
        reference.name.isEmpty ? "the published curve" : "\"\(reference.name)\""
    }

    /// What the measured curve alone says about the bass, with no reference curve to compare
    /// against. `nil` when the curve does not fall enough to be worth a sentence.
    ///
    /// This is `MeasuredHeadphone`'s copy of the warning the session already put in
    /// `quality.warnings`, so a UI that shows one note beside the curve does not have to match on
    /// the text of a warning.
    public var bassRollOffNote: String? {
        MeasuredHeadphone.bassRollOffNote(
            normalizedLevelsDB: curve.levelsDB.map(Double.init),
            grid: curve.frequenciesHz.map(Double.init),
            snrAt40Hz: quality.snrDB(atHz: 40).map(Double.init)
        )
    }

    /// The signal-to-noise ratio at 40 Hz from which a bass fall may be called a seal leak, in dB.
    ///
    /// THE one number for "is the bass measured, or is it the noise floor": the roll-off note
    /// below and the leak card of the result page (`MeasureController.leakWarning`) both read
    /// it, so the mid-run page and the result page can not give two verdicts on one bass fall.
    public static let snrThresholdDB: Double = 15

    /// True when there is enough signal at 40 Hz to say "seal leak". A missing figure (no
    /// noise-only segment) is not enough: nothing then tells a leak from the noise floor.
    public static func bassIsMeasured(snrAt40Hz: Double?) -> Bool {
        guard let snr = snrAt40Hz, snr.isFinite else { return false }
        return snr >= snrThresholdDB
    }

    /// How every roll-off note starts. `isBassRollOffNote` matches on it, so the text and the
    /// match can not drift apart.
    static let bassRollOffNotePrefix = "The measured curve falls "

    /// True for a sentence that `bassRollOffNote` wrote (any of its three verdicts).
    public static func isBassRollOffNote(_ warning: String) -> Bool { warning.hasPrefix(bassRollOffNotePrefix) }

    /// A leak looks like a first-order high-pass, so the test is the fall from 100 Hz down to
    /// 30 Hz. More than 10 dB is more than any sealed over-ear headphone does.
    ///
    /// The sentence only says "seal leak" when there is signal down there to say it with: at
    /// least `snrThresholdDB` (15 dB) of signal-to-noise at 40 Hz. Below that the fall may simply
    /// be the noise floor eating the measurement, and calling that a leak would send the user to
    /// reseat a headphone that was fine.
    public static func bassRollOffNote(
        normalizedLevelsDB levels: [Double],
        grid: [Double],
        snrAt40Hz: Double?,
        fallThresholdDB: Double = 10,
        snrThresholdDB: Double = MeasuredHeadphone.snrThresholdDB
    ) -> String? {
        guard levels.count == grid.count, !grid.isEmpty else { return nil }
        func level(atHz hz: Double) -> Double? {
            var best: Int?
            var bestDistance = Double.greatestFiniteMagnitude
            for (i, f) in grid.enumerated() where f > 0 {
                let d = abs(log(f) - log(hz))
                if d < bestDistance { bestDistance = d; best = i }
            }
            // Only trust a grid point within a sixth of an octave of the frequency asked for.
            guard let best, bestDistance < log(pow(2, 1.0 / 6)) else { return nil }
            return levels[best]
        }
        guard let at100 = level(atHz: 100), let at30 = level(atHz: 30) else { return nil }
        let fall = at100 - at30
        guard fall.isFinite, fall > fallThresholdDB else { return nil }

        let start = bassRollOffNotePrefix + String(format: "%.0f", fall) + " dB from 100 Hz to 30 Hz"
        guard let snr = snrAt40Hz else {
            return start + ". With no noise-only segment there is no signal-to-noise figure down there, so Joseon can not tell a seal leak from the noise floor. Record silence and measure again."
        }
        if snr >= snrThresholdDB {
            return start + ", with \(String(format: "%.0f", snr)) dB of signal-to-noise at 40 Hz. That looks like a seal leak on the rig rather than the headphone: reseat it and measure again."
        }
        return start + ", but signal-to-noise at 40 Hz is only \(String(format: "%.0f", snr)) dB, so the bass here is limited by noise rather than measured. Measure again in a quieter room, or at a higher level if there is headroom."
    }

    // MARK: - Average of two sides

    /// The sentence that opens the warnings of an averaged result.
    public static let averageNote = "This curve is the average of the left and the right side, measured one after the other. Agreement, distortion and signal to noise are the worse value of the two sides."

    /// The mean of two sides: the mean of the two dB curves (both are 0 dB at 1 kHz), with the
    /// worse quality figure of the two. The derived sensitivity is NOT averaged here: the result
    /// carries the left one until the caller sets its own.
    ///
    /// The warnings are the union of both sides, except the bass roll-off note. That sentence
    /// carries the fall of ONE curve, so the two sides give two near-identical bullets with no
    /// side on them. The average gets exactly one, computed from the averaged curve and the
    /// worse signal-to-noise of the two sides, or none when the averaged curve does not fall.
    public static func average(_ l: MeasuredHeadphone, _ r: MeasuredHeadphone) -> MeasuredHeadphone {
        var m = l
        m.curve.levelsDB = zip(l.curve.levelsDB, r.curve.levelsDB).map { ($0 + $1) / 2 }
        m.curve = m.curve.normalizedTo1kHz()
        m.absoluteMagnitudeDB = zip(l.absoluteMagnitudeDB, r.absoluteMagnitudeDB).map { ($0 + $1) / 2 }
        var q = l.quality
        let rq = r.quality
        q.runs += rq.runs
        q.agreementDB = max(q.agreementDB, rq.agreementDB)
        q.thdPercent = max(q.thdPercent, rq.thdPercent)
        q.lowestResolvedHz = max(q.lowestResolvedHz, rq.lowestResolvedHz)
        if q.snrDB.count == rq.snrDB.count { q.snrDB = zip(q.snrDB, rq.snrDB).map { min($0, $1) } }

        // Where the left side had its roll-off note, the note of the average goes.
        let noteIndex = q.warnings.firstIndex(where: isBassRollOffNote)
        var warnings = q.warnings.filter { !isBassRollOffNote($0) }
        warnings += rq.warnings.filter { !isBassRollOffNote($0) && !warnings.contains($0) }
        m.quality = q
        if let note = m.bassRollOffNote {
            warnings.insert(note, at: min(noteIndex ?? warnings.count, warnings.count))
        }
        m.quality.warnings = [averageNote] + warnings
        m.method = "Average of left and right; " + l.method
        return m
    }

    /// The curve in the AutoEq-compatible `frequency,raw` format, ready to save.
    ///
    /// `HeadphoneLibrary.importCurve` reads this back as the same curve — `AutoEQParser` sees the
    /// header, takes the `raw` column, and four decimal places round-trip a `Float` to well
    /// under a thousandth of a dB.
    ///
    /// Comment lines carry the method and the quality, because a bare column of numbers a year
    /// from now is a curve nobody can judge. `#` comments are what REW writes and what
    /// `AutoEQParser` already skips.
    public func csv() -> String {
        var lines: [String] = []
        lines.append("# \(curve.name)")
        lines.append("# \(method)")
        lines.append("# Runs: \(quality.runs); run-to-run agreement: \(String(format: "%.2f", quality.agreementDB)) dB; THD: \(String(format: "%.2f", quality.thdPercent)) %")
        lines.append("# Analysis window \(String(format: "%.0f", quality.windowMilliseconds)) ms; valid from \(String(format: "%.0f", quality.lowestReliableHz)) Hz (limit set by \(quality.lowLimitCause.reason)) to \(String(format: "%.0f", quality.highestReliableHz)) Hz")
        for warning in quality.warnings {
            lines.append("# Note: \(warning)")
        }
        lines.append("frequency,raw")
        for (f, db) in zip(curve.frequenciesHz, curve.levelsDB) {
            lines.append("\(String(format: "%.4f", f)),\(String(format: "%.4f", db))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
