import XCTest
@testable import JoseonHeadphones
import JoseonCore

/// The four things critic round 6 said the measurement module claims and can not support:
/// an uncertainty that ignores the calibration and the rig (D2), no leak detection (D3), two
/// lower limits with no cause (the "two lower limits" wording), and a hook at the top of the
/// log grid.
///
/// Every test simulates the chain, the way the rest of the measurement suite does.
final class MeasurementHonestyTests: XCTestCase {

    let sampleRate = 48_000.0
    let grid = SweepAnalysis.standardGrid

    // MARK: - D2, the uncertainty budget

    /// One row of the budget table: the inputs, the total, and which term should dominate.
    private struct Row {
        var label: String
        var level: AbsoluteLevel.Reference
        var playback: PlaybackCalibration
        var rig: MeasurementRig
        var micDB: Double
        var expectedTotalDB: Double
        var expectedPrintedDB: Double
        var expectedHeadline: String
    }

    func testUncertaintyIsEveryTermInQuadratureWithADominantTerm() throws {
        let meter = PlaybackCalibration.fromMeasuredTone(name: "WA33, multimeter", measuredVrms: 0.1, toneLevelDBFS: -6)
        let specs = PlaybackCalibration.fromSpecs(name: "WA33 from data sheets", dacFullScaleVrms: 2, ampGainDB: 10, volumeAttenuationDB: 20)
        let calibrator = AbsoluteLevel.Reference.calibrator(readingDBFS: -32.04)
        let sensFactor = AbsoluteLevel.Reference.micSensitivity(dbFSPerPascal: -32.04)
        let repeatability = 0.2

        let rows: [Row] = [
            Row(label: "calibrator · meter · ear simulator · mic file",
                level: calibrator, playback: meter, rig: .earSimulator, micDB: 0.5,
                expectedTotalDB: (0.25 + 4 + 1 + 0.25 + 0.04).squareRoot(),
                expectedPrintedDB: 2.5, expectedHeadline: "± 2.5 dB (voltage-limited)"),
            Row(label: "calibrator · meter · flat plate · mic file",
                level: calibrator, playback: meter, rig: .flatPlate, micDB: 0.5,
                expectedTotalDB: (0.25 + 4 + 6.25 + 0.25 + 0.04).squareRoot(),
                expectedPrintedDB: 3.5, expectedHeadline: "± 3.5 dB (rig-limited)"),
            Row(label: "Sens Factor · meter · flat plate · mic file",
                level: sensFactor, playback: meter, rig: .flatPlate, micDB: 0.5,
                expectedTotalDB: (4 + 4 + 6.25 + 0.25 + 0.04).squareRoot(),
                expectedPrintedDB: 4.0, expectedHeadline: "± 4 dB (rig-limited)"),
            Row(label: "Sens Factor · meter · other rig · no mic file",
                level: sensFactor, playback: meter, rig: .other, micDB: 2.0,
                expectedTotalDB: (4 + 4 + 9 + 4 + 0.04).squareRoot(),
                expectedPrintedDB: 5.0, expectedHeadline: "± 5 dB (rig-limited)"),
            Row(label: "calibrator · data sheets and a guessed knob · other rig · mic file",
                level: calibrator, playback: specs, rig: .other, micDB: 0.5,
                expectedTotalDB: (0.25 + 36 + 9 + 0.25 + 0.04).squareRoot(),
                expectedPrintedDB: 7.0, expectedHeadline: "± 7 dB (voltage-limited)"),
            // Three terms tie at 2 dB. The first listed wins, so the answer is stable.
            Row(label: "Sens Factor · meter · ear simulator · no mic file",
                level: sensFactor, playback: meter, rig: .earSimulator, micDB: 2.0,
                expectedTotalDB: (4 + 4 + 1 + 4 + 0.04).squareRoot(),
                expectedPrintedDB: 4.0, expectedHeadline: "± 4 dB (reference-limited)"),
        ]

        for row in rows {
            let result = AbsoluteLevel.deriveSensitivity(
                magnitudeAt1kHzDB: -20,
                absoluteLevel: AbsoluteLevel.scale(for: row.level),
                playback: row.playback,
                sweepLevelDBFS: -6,
                impedanceOhms: 45,
                measurementUncertaintyDB: repeatability,
                micCalibrationUncertaintyDB: row.micDB,
                rig: row.rig,
                source: "test"
            )
            let derived = try XCTUnwrap(result.value, row.label)
            print(String(format: "  %-58@ %.3f dB -> %@", row.label as NSString,
                         derived.uncertaintyDB, derived.uncertaintyHeadline as NSString))
            for term in derived.uncertaintyTable {
                print("      \(term.term): \(term.value) — \(term.detail)")
            }

            XCTAssertEqual(derived.uncertaintyDB, row.expectedTotalDB, accuracy: 1e-9, row.label)
            XCTAssertEqual(derived.printedUncertaintyDB, row.expectedPrintedDB, accuracy: 1e-9, row.label)
            XCTAssertEqual(derived.uncertaintyHeadline, row.expectedHeadline, row.label)
            XCTAssertGreaterThanOrEqual(derived.printedUncertaintyDB, derived.uncertaintyDB,
                                        "the printed figure must never be smaller than the total")
            XCTAssertEqual(derived.rig, row.rig)

            // Five named terms, every one of them in the total.
            XCTAssertEqual(derived.uncertaintyComponents.count, 5, row.label)
            XCTAssertEqual(
                derived.uncertaintyComponents.map(\.kind),
                [.absoluteLevel, .driveVoltage, .rig, .microphone, .repeatability],
                row.label
            )
            XCTAssertTrue(derived.uncertaintyComponents.allSatisfy { !$0.detail.isEmpty }, row.label)
            let quadrature = derived.uncertaintyComponents.reduce(0) { $0 + $1.dB * $1.dB }.squareRoot()
            XCTAssertEqual(derived.uncertaintyDB, quadrature, accuracy: 1e-9, row.label)

            // The old "± 0.9 dB" can not come back out of any combination.
            XCTAssertGreaterThan(derived.uncertaintyDB, 2.0, row.label)
        }
    }

    /// The two terms critic round 6 called out by name.
    func testDriveTermIsTheCalibrationsOwnFigureAndTheRigTermIsReal() {
        let meter = PlaybackCalibration.fromMeasuredTone(name: "meter", measuredVrms: 0.1, toneLevelDBFS: -6)
        XCTAssertEqual(meter.uncertaintyDB, 2.0, "the calibration window prints 2 dB for a meter")
        XCTAssertEqual(AbsoluteLevel.driveVoltageUncertaintyDB(for: meter), 2.0,
                       "so the sensitivity must not rate the same calibration at 0.5 dB")

        let specs = PlaybackCalibration.fromSpecs(name: "specs", dacFullScaleVrms: 2, ampGainDB: 10, volumeAttenuationDB: 20)
        XCTAssertEqual(AbsoluteLevel.driveVoltageUncertaintyDB(for: specs), 6.0, "data sheets and a guessed knob: the figure the calibration window prints")
        XCTAssertEqual(AbsoluteLevel.driveVoltageUncertaintyDB(for: specs), PlaybackCalibration.specsWithGuessedAttenuationUncertaintyDB)
        let stepped = PlaybackCalibration.fromSpecs(name: "stepped", dacFullScaleVrms: 2, ampGainDB: 10,
                                                    volumeAttenuationDB: 20, attenuationIsEstimated: false)
        XCTAssertEqual(AbsoluteLevel.driveVoltageUncertaintyDB(for: stepped), 4.0)

        // An optimistic hand-built calibration can not talk the budget under the method's floor.
        let optimistic = PlaybackCalibration(name: "wishful", method: .measuredVoltage, fullScaleVrms: 1, uncertaintyDB: 0.2)
        XCTAssertEqual(AbsoluteLevel.driveVoltageUncertaintyDB(for: optimistic), 2.0)
        let systemVolume = PlaybackCalibration(name: "Mac jack", method: .systemVolume, fullScaleVrms: 1, uncertaintyDB: 2.0)
        XCTAssertEqual(AbsoluteLevel.driveVoltageUncertaintyDB(for: systemVolume), 3.0)

        XCTAssertEqual(MeasurementRig.earSimulator.uncertaintyDB, 1.0)
        XCTAssertEqual(MeasurementRig.flatPlate.uncertaintyDB, 2.5)
        XCTAssertEqual(MeasurementRig.other.uncertaintyDB, 3.0)

        // The Sens Factor route carries its stated 2 dB into the sum, whatever a caller passes.
        let talkedDown = AbsoluteLevel.scale(for: .micSensitivity(dbFSPerPascal: -32, uncertaintyDB: 0.1))
        XCTAssertEqual(talkedDown.scale?.uncertaintyDB, MicCalibration.sensFactorUncertaintyDB)
        XCTAssertEqual(talkedDown.scale?.route, .microphoneSensFactor)
        XCTAssertEqual(AbsoluteLevel.scale(for: .calibrator(readingDBFS: -32)).scale?.route, .acousticCalibrator)
    }

    func testTotalRoundsUpToTheNextHalfDecibel() {
        XCTAssertEqual(DerivedSensitivity.roundedUpToHalfDB(2.3537), 2.5, accuracy: 1e-12)
        XCTAssertEqual(DerivedSensitivity.roundedUpToHalfDB(3.2848), 3.5, accuracy: 1e-12)
        XCTAssertEqual(DerivedSensitivity.roundedUpToHalfDB(3.0), 3.0, accuracy: 1e-12)
        XCTAssertEqual(DerivedSensitivity.roundedUpToHalfDB(2.5000000001), 2.5, accuracy: 1e-12)
        XCTAssertEqual(DerivedSensitivity.roundedUpToHalfDB(2.51), 3.0, accuracy: 1e-12)
    }

    /// Through the session, the way the app drives it: the rig travels in the context and the
    /// default is the pessimistic one.
    func testSessionCarriesTheRigIntoTheBudget() throws {
        let measured = try measuredSession(rig: nil)
        let derived = try XCTUnwrap(measured.derivedSensitivity)
        XCTAssertEqual(derived.rig, .flatPlate, "the default rig is the one most people have")
        XCTAssertEqual(derived.dominantTerm.kind, .rig)
        XCTAssertTrue(derived.uncertaintyHeadline.hasSuffix("(rig-limited)"), derived.uncertaintyHeadline)
        XCTAssertTrue(measured.method.contains("rig: Flat plate"), measured.method)

        let onASimulator = try XCTUnwrap(try measuredSession(rig: .earSimulator).derivedSensitivity)
        XCTAssertLessThan(onASimulator.uncertaintyDB, derived.uncertaintyDB,
                          "an ear simulator must buy something")
        print("  flat plate \(derived.uncertaintyHeadline), ear simulator \(onASimulator.uncertaintyHeadline)")
    }

    // MARK: - D3, the leak

    /// A first-order leak at 80 Hz against the clean response of the same headphone.
    func testBassShortfallFindsASimulatedLeak() throws {
        let clean = FilterCascade.headphone(sampleRate: sampleRate)
        let reference = HeadphoneCurve(
            name: "HiFiMAN Susvara Unveiled",
            source: "AutoEq",
            frequenciesHz: grid.map(Float.init),
            levelsDB: normalizedTo1kHz(clean.responseDB(onGrid: grid), onGrid: grid).map(Float.init)
        )

        // A clean measurement of the same headphone: no shortfall, no flag.
        let tight = try XCTUnwrap(measure(leakAtHz: nil, snrDB: 60).bassShortfall(against: reference))
        print(String(format: "  no leak: %.2f dB over 30–100 Hz (%d points)", tight.meanDifferenceDB, tight.pointsUsed))
        XCTAssertEqual(tight.meanDifferenceDB, 0, accuracy: 0.3)
        XCTAssertFalse(tight.likelyLeak)
        XCTAssertEqual(tight.lowHz, 30, accuracy: 1.0)
        XCTAssertEqual(tight.highHz, 100, accuracy: 3.0)
        XCTAssertGreaterThanOrEqual(tight.pointsUsed, 10)

        // The leak, against the closed form of the filter that made it.
        for leakHz in [80.0, 150.0] {
            let leak = Biquad.firstOrderHighPass(hz: leakHz, sampleRate: sampleRate)
            let truth = mean(
                grid.map { leak.responseDB(atHz: $0, sampleRate: sampleRate) - leak.responseDB(atHz: 1_000, sampleRate: sampleRate) },
                onGrid: grid, from: 30, to: 100
            )
            let shortfall = try XCTUnwrap(measure(leakAtHz: leakHz, snrDB: 60).bassShortfall(against: reference))
            print(String(format: "  %.0f Hz leak: measured %.2f dB, closed form %.2f dB, likelyLeak %@",
                         leakHz, shortfall.meanDifferenceDB, truth, shortfall.likelyLeak ? "yes" : "no"))
            expect(abs(shortfall.meanDifferenceDB - truth), atMost: 0.5,
                   "bass shortfall against the closed form of a \(Int(leakHz)) Hz leak")
            XCTAssertEqual(shortfall.likelyLeak, truth < BassShortfall.leakThresholdDB)
            if shortfall.likelyLeak {
                XCTAssertTrue(shortfall.summary.contains("likely a seal leak on the rig"), shortfall.summary)
                XCTAssertTrue(shortfall.summary.contains("HiFiMAN Susvara Unveiled"), shortfall.summary)
            }
        }
    }

    /// A reference that stops above the range is not compared against — the interpolator would
    /// clamp it flat and invent an answer.
    func testBassShortfallRefusesAReferenceThatDoesNotReachTheBass() throws {
        let measured = measure(leakAtHz: 150, snrDB: 60)
        let short = HeadphoneCurve(
            name: "stops at 200 Hz",
            source: "test",
            frequenciesHz: [200, 500, 1_000, 5_000],
            levelsDB: [0, 0, 0, 0]
        )
        XCTAssertNil(measured.bassShortfall(against: short))
        XCTAssertNil(measured.bassShortfall(against: HeadphoneCurve(name: "empty", source: "", frequenciesHz: [], levelsDB: [])))
    }

    /// The same falling bass means two different things, and only the signal-to-noise ratio at
    /// 40 Hz says which.
    func testLeakWordingSwitchesOnTheSignalToNoiseRatioAt40Hz() throws {
        let quiet = measure(leakAtHz: 80, snrDB: 45)
        let quietSNR = try XCTUnwrap(quiet.quality.snrDB(atHz: 40))
        let quietNote = try XCTUnwrap(quiet.bassRollOffNote)
        print(String(format: "  quiet room: SNR at 40 Hz %.0f dB — %@", quietSNR, quietNote as NSString))
        XCTAssertGreaterThanOrEqual(quietSNR, 15)
        XCTAssertTrue(quietNote.contains("looks like a seal leak"), quietNote)
        XCTAssertTrue(quiet.quality.warnings.contains(quietNote))

        let noisy = measure(leakAtHz: 80, snrDB: 5)
        let noisySNR = try XCTUnwrap(noisy.quality.snrDB(atHz: 40))
        let noisyNote = try XCTUnwrap(noisy.bassRollOffNote)
        print(String(format: "  noisy room: SNR at 40 Hz %.0f dB — %@", noisySNR, noisyNote as NSString))
        XCTAssertLessThan(noisySNR, 15)
        XCTAssertTrue(noisyNote.contains("limited by noise"), noisyNote)
        XCTAssertFalse(noisyNote.contains("seal leak"), noisyNote)
        XCTAssertTrue(noisy.quality.warnings.contains(noisyNote))

        // A sealed headphone says nothing at all.
        XCTAssertNil(measure(leakAtHz: nil, snrDB: 60).bassRollOffNote)

        // And with no noise-only segment Joseon refuses to call it either way.
        let blind = measure(leakAtHz: 80, snrDB: 45, withNoiseSegment: false)
        let blindNote = try XCTUnwrap(blind.bassRollOffNote)
        XCTAssertTrue(blindNote.contains("can not tell a seal leak from the noise floor"), blindNote)
    }

    // MARK: - One lower limit, one cause

    func testLowestReliableHzIsTheHigherOfTheTwoLimits() {
        func quality(noise: Float, window: Float) -> MeasurementQuality {
            MeasurementQuality(frequenciesHz: [], snrDB: [], thdPercent: 0, runs: 1, agreementDB: 0,
                               lowestResolvedHz: window, noiseLimitedHz: noise)
        }
        XCTAssertEqual(quality(noise: 28, window: 10).lowestReliableHz, 28)
        XCTAssertEqual(quality(noise: 28, window: 10).lowLimitCause, .noise)
        XCTAssertEqual(quality(noise: 8, window: 10).lowestReliableHz, 10)
        XCTAssertEqual(quality(noise: 8, window: 10).lowLimitCause, .window)
        XCTAssertEqual(quality(noise: 0, window: 10).lowLimitCause, .window, "no noise segment is not a noise limit")
        XCTAssertEqual(quality(noise: 10, window: 10).lowLimitCause, .window, "ties go to the window")
        // The old field is still there for whoever was reading it.
        XCTAssertEqual(quality(noise: 28, window: 10).lowestResolvedHz, 10)
    }

    func testTheWarningsNameOneLimitAndOneCause() throws {
        let quiet = measure(leakAtHz: nil, snrDB: 60)
        XCTAssertEqual(quiet.quality.lowLimitCause, .window)
        XCTAssertEqual(quiet.quality.noiseLimitedHz, 0, "10 dB of signal-to-noise at the bottom of the grid is not a noise limit")
        XCTAssertEqual(quiet.quality.lowestReliableHz, quiet.quality.lowestResolvedHz)

        let noisy = measure(leakAtHz: nil, snrDB: 5)
        XCTAssertEqual(noisy.quality.lowLimitCause, .noise)
        XCTAssertGreaterThan(noisy.quality.noiseLimitedHz, noisy.quality.lowestResolvedHz)
        XCTAssertEqual(noisy.quality.lowestReliableHz, noisy.quality.noiseLimitedHz)

        for measured in [quiet, noisy] {
            let limits = measured.quality.warnings.filter { $0.contains("Nothing under") }
            print("  \(measured.quality.lowLimitCause.rawValue)-limited: \(limits.first ?? "none")")
            XCTAssertEqual(limits.count, 1, "the result page must print one lower limit, not two")
            let sentence = try XCTUnwrap(limits.first)
            XCTAssertTrue(sentence.contains(String(format: "%.0f", measured.quality.lowestReliableHz)), sentence)
            switch measured.quality.lowLimitCause {
            case .window:
                XCTAssertTrue(sentence.contains("analysis window"), sentence)
                XCTAssertFalse(sentence.contains("signal-to-noise"), sentence)
            case .noise:
                XCTAssertTrue(sentence.contains("signal-to-noise"), sentence)
                XCTAssertFalse(sentence.contains("analysis window"), sentence)
            }
        }

        // And the file says the same thing, once.
        let csv = quiet.csv()
        XCTAssertTrue(csv.contains("limit set by the length of the analysis window"), csv.prefix(400).description)
    }

    // MARK: - The top of the band

    func testTheSweepKnowsWhereItStoppedDriving() {
        // 48 kHz: 20 kHz is under Nyquist, so the fade-out sets the top.
        let five = SweepSignal.exponentialSweep(sampleRate: 48_000, seconds: 5, levelDBFS: -6)
        let l5 = five.durationSeconds / log(five.endHz / five.startHz)
        XCTAssertEqual(five.highestFullEnergyHz, 20_000 * exp(-0.020 / l5), accuracy: 1)
        XCTAssertEqual(five.highestFullEnergyHz, 19_454.9, accuracy: 1)
        XCTAssertLessThan(SweepSignal.exponentialSweep(sampleRate: 48_000, seconds: 3).highestFullEnergyHz,
                          five.highestFullEnergyHz, "a shorter sweep spends more of the top octave fading")

        // 32 kHz: the Nyquist clamp sets the end frequency, and the fade still comes off it.
        let clamped = SweepSignal.exponentialSweep(sampleRate: 32_000, endHz: 20_000, seconds: 5)
        XCTAssertEqual(clamped.endHz, 15_200, accuracy: 1e-6, "clamped to 95 % of Nyquist")
        XCTAssertLessThan(clamped.highestFullEnergyHz, clamped.endHz)
        XCTAssertEqual(clamped.highestFullEnergyHz, 14_802, accuracy: 5)

        // Pink noise has no fade: its band simply ends.
        let pink = SweepSignal.periodicPinkNoise(sampleRate: 48_000, seconds: 4)
        XCTAssertEqual(pink.highestFullEnergyHz, pink.endHz, accuracy: 1e-9)
    }

    /// The defect in the review picture: the curve hooked at the last grid point, where the
    /// sweep's fade-out had already taken the energy away.
    func testNoHookAtTheTopOfTheLogGrid() throws {
        var chain = SimulatedChain(sampleRate: sampleRate, headphone: .headphone(sampleRate: sampleRate))
        chain.snrDB = 60
        let sweep = SweepSignal.exponentialSweep(sampleRate: sampleRate, seconds: 5, levelDBFS: -6)
        let session = HeadphoneMeasurement(sweep: sweep)
        session.setNoiseSegment(chain.silence(sweep))
        session.addRun(chain.record(sweep))
        let measured = try XCTUnwrap(session.result(name: "top of band"))

        let upper = Double(measured.quality.highestReliableHz)
        XCTAssertEqual(upper, sweep.highestFullEnergyHz, accuracy: 0.01)
        XCTAssertLessThan(upper, 20_000, "the grid goes higher than the sweep did")

        let truth = chain.trueResponseDB(onGrid: grid, includeMic: false)
        let got = measured.absoluteMagnitudeDB.map(Double.init)

        // The last octave under the reported limit is still a measurement.
        let worst = worstDifference(got, truth, onGrid: grid, from: upper / 2, to: upper)
        print(String(format: "  last octave (%.0f–%.0f Hz): worst %.3f dB at %.0f Hz; held flat above at %.3f dB",
                     upper / 2, upper, worst.dB, worst.hz, got[got.count - 1]))
        expect(worst.dB, atMost: 0.5, "top octave up to the reported upper limit")

        // Above it the curve holds flat: no hook, up or down.
        let lastIndex = try XCTUnwrap(grid.lastIndex(where: { $0 <= upper }))
        let lastMeasured = got[lastIndex]
        for (i, f) in grid.enumerated() where f > upper {
            XCTAssertEqual(got[i], lastMeasured, accuracy: 1e-9, "curve is not flat at \(f) Hz")
            XCTAssertEqual(Double(measured.curve.levelsDB[i]), Double(measured.curve.levelsDB[grid.count - 2]), accuracy: 1e-4)
        }

        // The old defect, in one number: before the fix the last grid point sat 6 dB low.
        XCTAssertLessThan(abs(got[grid.count - 1] - truth[grid.count - 1]), 0.5,
                          "the last grid point must not hook away from the response")
        XCTAssertTrue(measured.quality.warnings.contains { $0.contains("held flat") },
                      "the held region has to be declared")
    }

    // MARK: - Helpers

    /// One simulated session, optionally with a first-order leak in front of the headphone.
    private func measure(leakAtHz: Double?, snrDB: Double, withNoiseSegment: Bool = true) -> MeasuredHeadphone {
        var headphone = FilterCascade.headphone(sampleRate: sampleRate)
        if let leakAtHz {
            headphone.stages.append(Biquad.firstOrderHighPass(hz: leakAtHz, sampleRate: sampleRate))
        }
        var chain = SimulatedChain(sampleRate: sampleRate, headphone: headphone)
        chain.snrDB = snrDB
        let sweep = SweepSignal.exponentialSweep(sampleRate: sampleRate, seconds: 3, levelDBFS: -6)
        let session = HeadphoneMeasurement(sweep: sweep)
        if withNoiseSegment { session.setNoiseSegment(chain.silence(sweep)) }
        for run in 0..<3 {
            var c = chain
            c.seed = UInt64(run) &* 17 &+ 1
            session.addRun(c.record(sweep))
        }
        return session.result(name: "simulated")!
    }

    /// A session with an absolute level and a playback calibration, for the budget tests.
    private func measuredSession(rig: MeasurementRig?) throws -> MeasuredHeadphone {
        var chain = SimulatedChain(sampleRate: sampleRate, headphone: .headphone(sampleRate: sampleRate))
        chain.snrDB = 50
        let sweep = SweepSignal.exponentialSweep(sampleRate: sampleRate, seconds: 3, levelDBFS: -6)
        let mic = try MicCalibration.parse(
            text: "\"Sens Factor =-14.0412dB, SERNO: 7012345\"\r\n20\t0\t0\r\n100\t0\t0\r\n1000\t0\t0\r\n20000\t0\t0",
            name: "UMIK-1 7012345 (0°)"
        )
        let session = HeadphoneMeasurement(sweep: sweep, micCalibration: mic)
        session.setNoiseSegment(chain.silence(sweep))
        for run in 0..<3 {
            var c = chain
            c.seed = UInt64(run) &* 23 &+ 5
            session.addRun(c.record(sweep))
        }
        var context = HeadphoneMeasurement.SensitivityContext(
            playback: .fromMeasuredTone(name: "WA33 at 10 o'clock", measuredVrms: 0.1, toneLevelDBFS: -6),
            absoluteLevel: AbsoluteLevel.scale(for: .calibrator(readingDBFS: -32.04)),
            impedanceOhms: 45
        )
        if let rig { context.rig = rig }
        return try XCTUnwrap(session.result(name: "simulated", sensitivity: context))
    }
}
