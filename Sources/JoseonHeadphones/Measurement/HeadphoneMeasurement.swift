import Foundation
import JoseonCore

/// One measurement session, from the first sweep to the curve that gets saved.
///
/// This is the object an app engineer holds. The order of the calls is the order of the work:
///
/// ```swift
/// // 1. Make the stimulus. The app plays `sweep.samples` — only after the user presses a
/// //    button that says it will make sound.
/// let sweep = SweepSignal.exponentialSweep(sampleRate: 48_000, seconds: 5, levelDBFS: -6)
///
/// // 2. Load what is known about the rig. Both are optional and both are remembered in the
/// //    warnings when they are missing.
/// let mic = try? MicCalibration.parse(text: calFileText, name: "UMIK-1 7012345 (0°)")
/// let coupler = try? CouplerCorrection.parse(text: rigFileText, name: "Flat plate")
///
/// // 3. Open the session.
/// let session = HeadphoneMeasurement(sweep: sweep, micCalibration: mic, coupler: coupler)
///
/// // 4. Record a second or two of silence first and hand it over. Without it there is no
/// //    signal-to-noise figure and the curve can not be judged.
/// session.setNoiseSegment(silence)
///
/// // 5. Play and record the sweep N times. Each call returns what that run looked like, for a
/// //    live read-out.
/// for recording in recordings { _ = session.addRun(recording) }
///
/// // 6. Ask for the result. `sensitivity:` is optional: leave it out and the curve still comes
/// //    back, with `sensitivity == nil` and a warning saying why.
/// let measured = session.result(
///     name: "HiFiMAN Susvara Unveiled (measured)",
///     sensitivity: .init(
///         playback: calibration,
///         absoluteLevel: AbsoluteLevel.scale(for: .fromMicCalibration(mic)),
///         impedanceOhms: 45
///     )
/// )
///
/// // 7. Save `measured?.csv()` and hand the file to HeadphoneLibrary.importCurve.
/// ```
///
/// Nothing in here opens a device, plays a sound or writes a file. It is arrays in, arrays out.
///
/// Threading: not thread safe. Drive it from one queue — in practice the queue that owns the
/// measurement window.
public final class HeadphoneMeasurement {

    /// What a single run looked like, for the live read-out during a measurement.
    public struct RunSummary: Sendable, Equatable {
        /// Play-to-record delay in samples, from the peak of the deconvolved impulse response.
        public var delaySamples: Int
        public var delaySeconds: Double
        /// The same delay from a plain cross-correlation against the sweep, when it was asked for.
        public var crossCorrelationDelaySamples: Int?
        /// Impulse peak level in dB relative to full scale.
        public var peakLevelDB: Double
        /// Noise floor of this run in dB below the impulse peak.
        public var noiseFloorDB: Double
        /// Total harmonic distortion of this run, in percent.
        public var thdPercent: Double
        /// True when a sample in the recording reached ±0.999.
        public var clipped: Bool
    }

    /// Everything the sensitivity derivation needs beyond the measurement itself.
    public struct SensitivityContext: Sendable {
        public var playback: PlaybackCalibration
        public var absoluteLevel: AbsoluteLevel.Result
        public var impedanceOhms: Double
        /// Overrides `AbsoluteLevel.driveVoltageUncertaintyDB(for:)` when the app knows better.
        public var driveVoltageUncertaintyDB: Double?
        /// What the headphone sits on. Sets the rig term of the uncertainty budget, so the
        /// default is the pessimistic one: most people have a flat plate, not an ear simulator.
        public var rig: MeasurementRig

        public init(
            playback: PlaybackCalibration,
            absoluteLevel: AbsoluteLevel.Result,
            impedanceOhms: Double,
            driveVoltageUncertaintyDB: Double? = nil,
            rig: MeasurementRig = .flatPlate
        ) {
            self.playback = playback
            self.absoluteLevel = absoluteLevel
            self.impedanceOhms = impedanceOhms
            self.driveVoltageUncertaintyDB = driveVoltageUncertaintyDB
            self.rig = rig
        }
    }

    public let sweep: SweepSignal
    public var options: SweepAnalysis.Options
    public let micCalibration: MicCalibration?
    public let coupler: CouplerCorrection?
    /// The frequency grid the result is stated on. The module's 200-point log grid by default.
    public let grid: [Double]
    /// True when any recording reached ±0.999 at the input.
    public private(set) var sawClipping = false

    private var deconvolver: SweepDeconvolver?
    private var responses: [SweepAnalysis.ComplexResponse] = []
    private var summaries: [RunSummary] = []
    private var distortions: [Double] = []
    private var windowPre = 0
    private var windowPost = 0
    private var noiseSegment: [Double] = []
    private var truncatedRun = false

    public init(
        sweep: SweepSignal,
        options: SweepAnalysis.Options = SweepAnalysis.Options(),
        micCalibration: MicCalibration? = nil,
        coupler: CouplerCorrection? = nil,
        grid: [Double] = SweepAnalysis.standardGrid
    ) {
        self.sweep = sweep
        self.options = options
        self.micCalibration = micCalibration
        self.coupler = coupler
        self.grid = grid
    }

    public var runCount: Int { responses.count }
    public var runSummaries: [RunSummary] { summaries }

    /// Hand over a recording made with nothing playing. Without it there is no per-band
    /// signal-to-noise figure, and `MeasurementQuality.snrDB` comes back empty.
    ///
    /// Make it at least as long as the sweep. The regularized inverse is a sweep-length filter,
    /// so a short burst of silence comes out of it thinner than the noise that ran under the
    /// whole measurement, and the signal-to-noise figures would read better than the truth.
    /// `MeasurementQuality.warnings` says so when the segment is short.
    public func setNoiseSegment(_ noise: [Double]) {
        noiseSegment = noise
    }

    /// Analyse one recording of the sweep and add it to the average.
    ///
    /// The recording may start whenever it likes and may be any length up to the sweep plus the
    /// analysis buffer; the delay comes out of the deconvolution.
    @discardableResult
    public func addRun(_ recorded: [Double], measureCrossCorrelation: Bool = false) -> RunSummary {
        let clipped = recorded.contains { abs($0) >= 0.999 }
        if clipped { sawClipping = true }

        if deconvolver == nil {
            deconvolver = SweepDeconvolver(sweep: sweep, recordedCount: recorded.count, options: options)
        }
        guard let deconvolver else { preconditionFailure("unreachable") }
        var run = recorded
        if run.count > deconvolver.length {
            run.removeLast(run.count - deconvolver.length)
            truncatedRun = true
        }

        let ir = deconvolver.impulseResponse(of: run)
        if responses.isEmpty {
            let adaptive = SweepAnalysis.window(ir, options: options)
            windowPre = adaptive.preSamples
            windowPost = adaptive.postSamples
        }
        let windowed = SweepAnalysis.window(
            ir,
            preSamples: windowPre,
            postSamples: windowPost,
            fadeFraction: options.postWindowFadeFraction
        )
        responses.append(SweepAnalysis.complexResponse(windowed, options: options))

        let distortion = SweepAnalysis.harmonicDistortion(ir, sweep: sweep, options: options)
        distortions.append(distortion.totalPercent)

        var correlationDelay: Int?
        if measureCrossCorrelation {
            correlationDelay = SweepAnalysis.delaySamples(recorded: run, reference: sweep.samples).samples
        }

        let summary = RunSummary(
            delaySamples: ir.peakIndex,
            delaySeconds: ir.delaySeconds,
            crossCorrelationDelaySamples: correlationDelay,
            peakLevelDB: amplitudeDB(abs(ir.samples[ir.peakIndex])),
            noiseFloorDB: ir.noiseFloorDBRelativePeak,
            thdPercent: distortion.totalPercent,
            clipped: clipped
        )
        summaries.append(summary)
        return summary
    }

    /// The measured curve, its quality, and — when the context is given and an absolute level
    /// exists — the headphone's sensitivity.
    ///
    /// `nil` when no run has been added.
    public func result(
        name: String,
        source: String = "Joseon measurement",
        sensitivity context: SensitivityContext? = nil
    ) -> MeasuredHeadphone? {
        guard !responses.isEmpty, let deconvolver else { return nil }

        let smoothing = options.smoothing
        let averaged = SweepAnalysis.average(responses, grid: grid, smoothing: smoothing)
        var magnitude = averaged.mean.magnitudeDB(onGrid: grid, smoothing: smoothing)

        if let micCalibration {
            magnitude = micCalibration.apply(toMagnitudeDB: magnitude, onGrid: grid)
        }
        if let coupler {
            magnitude = coupler.apply(toMagnitudeDB: magnitude, onGrid: grid)
        }

        // The top of the log grid is not the top of the measurement. Hold the curve flat above
        // the last frequency the stimulus drove at full level, so it ends rather than hooks.
        let upperLimit = highestReliableHz()
        holdFlat(&magnitude, aboveHz: upperLimit)

        // Signal to noise, through the same deconvolution and the same window.
        var snr: [Float] = []
        if !noiseSegment.isEmpty {
            let noiseResponse = SweepAnalysis.noiseFloorResponse(
                deconvolvedNoise: deconvolver.deconvolve(noiseSegment),
                sampleRate: sweep.sampleRate,
                preSamples: windowPre,
                postSamples: windowPost,
                usableSamples: noiseSegment.count,
                options: options
            )
            // Averaging N runs buys 10·log10(N) against uncorrelated noise.
            let averagingGain = 10 * log10(Double(responses.count))
            let measured = SweepAnalysis.signalToNoiseDB(
                signal: averaged.mean,
                noise: noiseResponse,
                grid: grid,
                smoothing: smoothing
            )
            snr = measured.map { Float($0 + averagingGain) }
            var held = snr.map(Double.init)
            holdFlat(&held, aboveHz: upperLimit)
            snr = held.map(Float.init)
        }

        let reference = referenceLevel(magnitude)
        let normalized = magnitude.map { Float($0 - reference) }
        let windowSeconds = Double(windowPre + windowPost) / sweep.sampleRate
        let thd = distortions.isEmpty ? 0 : distortions.reduce(0, +) / Double(distortions.count)

        var quality = MeasurementQuality(
            frequenciesHz: grid.map(Float.init),
            snrDB: snr,
            thdPercent: Float(thd),
            runs: responses.count,
            agreementDB: Float(averaged.agreementDB),
            agreementSpreadDB: averaged.spreadDB.map(Float.init),
            lowestResolvedHz: Float(1 / windowSeconds),
            windowMilliseconds: Float(windowSeconds * 1000),
            warnings: [],
            noiseLimitedHz: 0,
            highestReliableHz: Float(upperLimit)
        )
        quality.noiseLimitedHz = noiseLimitedHz(quality)
        quality.warnings = warnings(
            quality: quality,
            context: context,
            normalizedLevelsDB: normalized.map(Double.init)
        )

        let method = methodSentence(context: context)
        var derived: DerivedSensitivity?
        if let context {
            let result = AbsoluteLevel.deriveSensitivity(
                magnitudeAt1kHzDB: reference,
                absoluteLevel: context.absoluteLevel,
                playback: context.playback,
                sweepLevelDBFS: sweep.levelDBFS,
                impedanceOhms: context.impedanceOhms,
                driveVoltageUncertaintyDB: context.driveVoltageUncertaintyDB,
                measurementUncertaintyDB: repeatabilityDB(quality),
                micCalibrationUncertaintyDB: micCalibration == nil ? 2.0 : 0.5,
                rig: context.rig,
                source: "Measured with Joseon — \(method)"
            )
            derived = result.value
        }

        return MeasuredHeadphone(
            curve: HeadphoneCurve(
                name: name,
                source: source,
                frequenciesHz: grid.map(Float.init),
                levelsDB: normalized
            ),
            absoluteMagnitudeDB: magnitude.map(Float.init),
            sensitivity: derived?.sensitivity,
            derivedSensitivity: derived,
            quality: quality,
            method: method
        )
    }

    /// Just the sensitivity, for a UI that derives it after the curve is already on screen.
    public func derivedSensitivity(_ context: SensitivityContext) -> DerivedSensitivityResult {
        guard let measured = result(name: "sensitivity", sensitivity: nil) else {
            return .unavailable(reason: "No runs have been measured yet.")
        }
        let reference = referenceLevel(measured.absoluteMagnitudeDB.map(Double.init))
        return AbsoluteLevel.deriveSensitivity(
            magnitudeAt1kHzDB: reference,
            absoluteLevel: context.absoluteLevel,
            playback: context.playback,
            sweepLevelDBFS: sweep.levelDBFS,
            impedanceOhms: context.impedanceOhms,
            driveVoltageUncertaintyDB: context.driveVoltageUncertaintyDB,
            measurementUncertaintyDB: repeatabilityDB(measured.quality),
            micCalibrationUncertaintyDB: micCalibration == nil ? 2.0 : 0.5,
            rig: context.rig,
            source: "Measured with Joseon — \(methodSentence(context: context))"
        )
    }

    // MARK: - Private

    /// Mean level over 800–1250 Hz — the same reference `HeadphoneCurve` normalizes to.
    private func referenceLevel(_ magnitude: [Double]) -> Double {
        var sum = 0.0
        var used = 0
        for (i, f) in grid.enumerated() where f >= 800 && f <= 1250 {
            sum += magnitude[i]
            used += 1
        }
        guard used > 0 else { return 0 }
        return sum / Double(used)
    }

    /// The highest frequency this result is allowed to claim: the last frequency the stimulus
    /// drove at full level, inside the grid and under Nyquist.
    private func highestReliableHz() -> Double {
        let gridTop = grid.last ?? sweep.endHz
        return max(min(sweep.highestFullEnergyHz, gridTop), grid.first ?? 20)
    }

    /// Hold a curve at its last trustworthy value above `hz`, instead of drawing what the
    /// deconvolution returns where the stimulus had no energy left.
    private func holdFlat(_ values: inout [Double], aboveHz hz: Double) {
        guard values.count == grid.count else { return }
        var last: Double?
        for (i, f) in grid.enumerated() {
            if f <= hz {
                last = values[i]
            } else if let last {
                values[i] = last
            }
        }
    }

    /// Lowest frequency with 10 dB of signal-to-noise, or 0 when noise does not limit anything.
    ///
    /// 0 means two different things and both are "noise is not the limit here": no noise-only
    /// segment was recorded, or the signal-to-noise ratio is already good at the bottom of the
    /// grid. The second case matters — reporting the grid's own first point as a noise limit
    /// would make room noise look like the binding constraint in a silent room.
    ///
    /// When nothing anywhere on the grid reaches 10 dB, the limit is the top of the grid: none of
    /// this curve is signal.
    private func noiseLimitedHz(_ quality: MeasurementQuality) -> Float {
        guard !quality.snrDB.isEmpty else { return 0 }
        guard let trusted = quality.lowestTrustedHz(minimumDB: 10) else {
            return Float(grid.last ?? 20_000)
        }
        guard let bottom = grid.first, trusted > Float(bottom) else { return 0 }
        return trusted
    }

    /// How repeatable the measurement was, in dB — the run spread cut down by the averaging.
    private func repeatabilityDB(_ quality: MeasurementQuality) -> Double {
        guard quality.runs > 1 else { return 1.0 }
        return max(Double(quality.agreementDB) / Double(quality.runs).squareRoot(), 0.2)
    }

    private func methodSentence(context: SensitivityContext?) -> String {
        var parts: [String] = []
        parts.append(sweep.kind == .exponentialSweep
            ? "\(String(format: "%.0f", sweep.durationSeconds)) s exponential sweep, \(String(format: "%.0f", sweep.startHz))–\(String(format: "%.0f", sweep.endHz / 1000)) kHz at \(String(format: "%.0f", sweep.levelDBFS)) dBFS"
            : "periodic pink noise, \(String(format: "%.0f", sweep.durationSeconds)) s period at \(String(format: "%.0f", sweep.levelDBFS)) dBFS")
        parts.append("\(responses.count) run\(responses.count == 1 ? "" : "s") averaged")
        parts.append(options.smoothing == .none ? "no smoothing" : "\(options.smoothing.rawValue) smoothing")
        parts.append(micCalibration.map { "microphone calibration \"\($0.name)\" applied" } ?? "no microphone calibration")
        if let coupler { parts.append("coupler correction \"\(coupler.name)\" applied") }
        if let context {
            parts.append("rig: \(context.rig.label)")
            if case .available(let scale) = context.absoluteLevel {
                parts.append("absolute level from \(scale.method)")
            }
        }
        return parts.joined(separator: "; ")
    }

    private func warnings(
        quality: MeasurementQuality,
        context: SensitivityContext?,
        normalizedLevelsDB: [Double]
    ) -> [String] {
        var out: [String] = []

        if micCalibration == nil {
            out.append("No microphone calibration was applied, so this curve is the headphone and the microphone together.")
        } else if let mic = micCalibration {
            out.append("Microphone calibration \"\(mic.name)\" applied. Joseon can not tell a 0° file from a 90° one — use the file that matches how the microphone points.")
        }
        if coupler == nil {
            out.append("No coupler correction. On a flat plate or a home-made coupler the bass and the ear-canal resonance are the rig's, not the headphone's; a standards-type ear simulator needs no correction.")
        }
        if quality.runs == 1 {
            out.append("One run only, so there is no run-to-run agreement to report. Measure at least three times, lifting and reseating the headphone between runs.")
        } else if quality.agreementDB > 1 {
            out.append("Runs disagree by \(String(format: "%.1f", quality.agreementDB)) dB on average between 100 Hz and 10 kHz. The headphone probably moved on the rig; the bass seal is the usual cause.")
        }
        if quality.snrDB.isEmpty {
            out.append("No noise-only segment was recorded, so the signal-to-noise ratio is unknown and nothing here says which parts of the curve are real.")
        } else if noiseSegment.count < sweep.samples.count {
            out.append("The noise-only recording is shorter than the sweep, so the signal-to-noise figures are optimistic. Record silence for at least as long as the sweep.")
        }
        if sawClipping {
            out.append("The input clipped (a sample reached ±0.999). The result is not trustworthy — lower the input gain and measure again.")
        }
        if quality.thdPercent > 3 {
            out.append("Harmonic distortion is \(String(format: "%.1f", quality.thdPercent)) %. Some of that is the amplifier and the microphone, not the headphone; measure again 10 dB lower and see whether it follows the level.")
        }

        // One lower limit, with the one cause that set it. The other number is still in
        // `quality` for anyone who wants it, but the user gets one sentence, not two that
        // contradict each other.
        let lowest = String(format: "%.0f", quality.lowestReliableHz)
        switch quality.lowLimitCause {
        case .window:
            out.append("Nothing under \(lowest) Hz is the headphone: the \(String(format: "%.0f", quality.windowMilliseconds)) ms analysis window sets the bottom of this measurement.")
        case .noise:
            out.append("Nothing under \(lowest) Hz is the headphone: signal-to-noise falls under 10 dB there, so room noise sets the bottom of this measurement. Measure again in a quieter room, or at a higher level if there is headroom.")
        }

        // The top: where the stimulus stopped driving at full level.
        let top = Double(quality.highestReliableHz)
        if let gridTop = grid.last, top < gridTop * 0.999 {
            out.append("The stimulus drove at full level only up to \(String(format: "%.0f", top)) Hz (the fade-out covers the frequencies above it), so the curve is held flat from there to \(String(format: "%.0f", gridTop)) Hz rather than drawn from data.")
        }

        if let note = MeasuredHeadphone.bassRollOffNote(
            normalizedLevelsDB: normalizedLevelsDB,
            grid: grid,
            snrAt40Hz: quality.snrDB(atHz: 40).map(Double.init)
        ) {
            out.append(note)
        }

        if truncatedRun {
            out.append("A recording was longer than the analysis buffer and was truncated. Stop the recording within a second of the end of the sweep.")
        }
        if sweep.kind == .periodicPinkNoise {
            out.append("Pink noise can not separate distortion from the response, so the distortion figure is zero by construction rather than by measurement.")
        }
        if let context, case .unavailable(let reason) = context.absoluteLevel {
            out.append("No sensitivity was derived. \(reason)")
        } else if context == nil {
            out.append("No sensitivity was derived: no playback calibration and no absolute level reference were given.")
        }
        out.append("Clock drift between the playback device and the recording device is not corrected. Two devices at 20 ppm move about 5 samples over a 5 s sweep, which costs a fraction of a dB in the top octave; a much larger drift shows up as a soft top end.")
        return out
    }
}
