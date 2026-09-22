import XCTest
import JoseonCore
@testable import JoseonHeadphones

final class StressFlagTests: XCTestCase {

    private var clock = TestClock()

    override func setUp() {
        super.setUp()
        clock = TestClock()
    }

    /// Flat headphone against a flat target: nothing about the headphone can fire on its own.
    private func flatModel(thresholds: StressThresholds = StressThresholds()) -> HeadphoneModel {
        HeadphoneModel(
            curve: Fixture.flatCurve(name: "Flat test"),
            target: Fixture.curve(name: "Flat target") { _ in 0 },
            thresholds: thresholds,
            now: clock.read
        )
    }

    private func ids(_ flags: [StressFlag]) -> Set<String> { Set(flags.map(\.id)) }

    // MARK: - Quiet baseline

    func testNothingFiresOnQuietFlatInput() {
        let model = flatModel()
        for _ in 0..<5 {
            let flags = model.stressFlags(
                spectrum: Fixture.silentSpectrum(),
                bands: Fixture.bands(),
                loudness: Fixture.loudness()
            )
            XCTAssertEqual(flags, [], "quiet input raised \(flags.map(\.id))")
            clock.advance(1)
        }
    }

    func testNothingFiresOnModerateMusicWithAWellBehavedHeadphone() {
        let model = flatModel()
        let spectrum = Fixture.spectrum { hz in hz < 40 ? -95 : -45 }
        let flags = model.stressFlags(
            spectrum: spectrum,
            bands: Fixture.bands(subBass: -40),
            loudness: Fixture.loudness(truePeakMax: -1.5, plr: 14, measuredSeconds: 90, integrated: -15.5)
        )
        XCTAssertEqual(flags, [])
    }

    // MARK: - (a) sub-bass load

    func testSubBassLoadNeedsSustainThenHoldsThenClears() {
        let model = flatModel()
        let quiet = Fixture.silentSpectrum()
        let loud = Fixture.bands(subBass: -20)   // above the -24 dBFS default

        // Not yet: the condition must hold for subBassSustainSeconds (3 s).
        XCTAssertFalse(ids(model.stressFlags(spectrum: quiet, bands: loud, loudness: Fixture.loudness()))
            .contains(StressFlagID.subBassLoad))
        clock.advance(2.5)
        XCTAssertFalse(ids(model.stressFlags(spectrum: quiet, bands: loud, loudness: Fixture.loudness()))
            .contains(StressFlagID.subBassLoad), "raised before the 3 s attack")

        clock.advance(0.6)
        let fired = model.stressFlags(spectrum: quiet, bands: loud, loudness: Fixture.loudness())
        guard let flag = fired.first(where: { $0.id == StressFlagID.subBassLoad }) else {
            return XCTFail("sub-bass load did not fire; got \(fired.map(\.id))")
        }
        XCTAssertEqual(flag.severity, .watch)
        XCTAssertTrue(flag.detail.contains("\u{2212}20.0 dBFS"), flag.detail)
        XCTAssertTrue(flag.detail.contains("Flat test"), flag.detail)

        // Down to -25, inside the 2 dB release margin: the flag holds, however long it sits there.
        clock.advance(30)
        XCTAssertTrue(ids(model.stressFlags(spectrum: quiet, bands: Fixture.bands(subBass: -25),
                                            loudness: Fixture.loudness()))
            .contains(StressFlagID.subBassLoad), "the margin has to hold the flag up")

        // Clear of the margin: the 5 s release starts here.
        let clear = Fixture.bands(subBass: -30)
        clock.advance(1)
        XCTAssertTrue(ids(model.stressFlags(spectrum: quiet, bands: clear, loudness: Fixture.loudness()))
            .contains(StressFlagID.subBassLoad))
        clock.advance(4.5)
        XCTAssertTrue(ids(model.stressFlags(spectrum: quiet, bands: clear, loudness: Fixture.loudness()))
            .contains(StressFlagID.subBassLoad), "cleared before the 5 s release")

        // Past the release: gone.
        clock.advance(0.6)
        XCTAssertFalse(ids(model.stressFlags(spectrum: quiet, bands: clear, loudness: Fixture.loudness()))
            .contains(StressFlagID.subBassLoad))
    }

    /// Defect 4: one demo window showed amber `Sub-bass load` at -23 dBFS and the next
    /// showed none. A value hovering on the threshold must give one continuous flag or
    /// none - never a flag that blinks.
    func testSubBassLoadDoesNotFlickerWhenTheLevelHoversOnTheThreshold() {
        let quiet = Fixture.silentSpectrum()
        // 60 s of -25 / -23 dBFS around the -24 threshold, a step every 0.5 s.
        func run(startingHigh: Bool) -> [Bool] {
            let model = flatModel()
            var up: [Bool] = []
            for step in 0..<120 {
                let high = (step % 2 == 0) == startingHigh
                let flags = model.stressFlags(spectrum: quiet, bands: Fixture.bands(subBass: high ? -23 : -25),
                                              loudness: Fixture.loudness())
                up.append(ids(flags).contains(StressFlagID.subBassLoad))
                clock.advance(0.5)
            }
            return up
        }
        for startingHigh in [true, false] {
            let up = run(startingHigh: startingHigh)
            let edges = zip(up, up.dropFirst()).filter { $0 != $1 }.count
            XCTAssertLessThanOrEqual(edges, 1, "the flag changed state \(edges) times while the level hovered")
        }
    }

    /// The same hover, but starting from a level that really did raise the flag: it must
    /// stay up for the whole hover instead of blinking with it.
    func testSubBassLoadStaysUpThroughAHoverOnceItIsRaised() {
        let model = flatModel()
        let quiet = Fixture.silentSpectrum()
        _ = model.stressFlags(spectrum: quiet, bands: Fixture.bands(subBass: -18), loudness: Fixture.loudness())
        clock.advance(3.01)
        XCTAssertTrue(ids(model.stressFlags(spectrum: quiet, bands: Fixture.bands(subBass: -18),
                                            loudness: Fixture.loudness()))
            .contains(StressFlagID.subBassLoad))
        let raised = model.flagOnsets()[StressFlagID.subBassLoad]
        XCTAssertNotNil(raised)

        for step in 0..<120 {
            clock.advance(0.5)
            let flags = model.stressFlags(spectrum: quiet,
                                          bands: Fixture.bands(subBass: step % 2 == 0 ? -23 : -25),
                                          loudness: Fixture.loudness())
            XCTAssertTrue(ids(flags).contains(StressFlagID.subBassLoad), "dropped at step \(step)")
        }
        XCTAssertEqual(model.flagOnsets()[StressFlagID.subBassLoad], raised, "the onset must not restart")
    }

    func testSubBassLoadGoesHighAtTheHighThreshold() {
        let model = flatModel()
        _ = model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(subBass: -10),
                              loudness: Fixture.loudness())
        clock.advance(3.01)
        let flags = model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(subBass: -10),
                                      loudness: Fixture.loudness())
        XCTAssertEqual(flags.first(where: { $0.id == StressFlagID.subBassLoad })?.severity, .high)
    }

    func testSubBassLoadDetailNamesWhatTheResponseDoesDownThere() {
        // A headphone that rolls off hard below 60 Hz.
        let rolled = Fixture.curve(name: "Rolled off") { hz in hz < 60 ? -10 : 0 }
        let model = HeadphoneModel(curve: rolled, target: nil, thresholds: StressThresholds(), now: clock.read)
        _ = model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(subBass: -18),
                              loudness: Fixture.loudness())
        clock.advance(3.01)
        let flag = model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(subBass: -18),
                                     loudness: Fixture.loudness())
            .first { $0.id == StressFlagID.subBassLoad }
        XCTAssertNotNil(flag)
        XCTAssertTrue(flag!.detail.contains("20–60 Hz"), flag!.detail)
        XCTAssertTrue(flag!.detail.contains("\u{2212}10.0 dB") || flag!.detail.contains("\u{2212}9."), flag!.detail)
    }

    // MARK: - (b) deep bass under-delivery

    func testDeepBassUnderDeliveryFiresAndClears() {
        // Headphone flat, target wants +12 dB under 40 Hz: a 12 dB shortfall.
        let model = HeadphoneModel(
            curve: Fixture.flatCurve(name: "Flat test"),
            target: Fixture.curve(name: "Deep target") { hz in hz < 40 ? 12 : 0 },
            thresholds: StressThresholds(),
            now: clock.read
        )
        let content = Fixture.spectrum { hz in hz < 40 ? -35 : -90 }

        let flags = clock.settled {
            model.stressFlags(spectrum: content, bands: Fixture.bands(subBass: -40), loudness: Fixture.loudness())
        }
        guard let flag = flags.first(where: { $0.id == StressFlagID.subBassUnderDelivery }) else {
            return XCTFail("under-delivery did not fire; got \(flags.map(\.id))")
        }
        XCTAssertEqual(flag.severity, .watch)
        XCTAssertTrue(flag.detail.contains("Deep target"), flag.detail)
        XCTAssertTrue(flag.detail.contains("40.0 Hz"), flag.detail)

        let cleared = clock.settled(5.01) {
            model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(),
                              loudness: Fixture.loudness())
        }
        XCTAssertFalse(ids(cleared).contains(StressFlagID.subBassUnderDelivery))
    }

    func testDeepBassUnderDeliveryStaysQuietWithoutContent() {
        let model = HeadphoneModel(
            curve: Fixture.flatCurve(),
            target: Fixture.curve(name: "Deep target") { hz in hz < 40 ? 12 : 0 },
            thresholds: StressThresholds(),
            now: clock.read
        )
        let noDeepContent = Fixture.spectrum { hz in hz < 40 ? -95 : -30 }
        XCTAssertFalse(ids(model.stressFlags(spectrum: noDeepContent, bands: Fixture.bands(subBass: -60),
                                             loudness: Fixture.loudness()))
            .contains(StressFlagID.subBassUnderDelivery))
    }

    func testNoTargetMeansNoUnderDeliveryFlag() {
        let model = HeadphoneModel(curve: Fixture.flatCurve(), target: nil,
                                   thresholds: StressThresholds(), now: clock.read)
        let content = Fixture.spectrum { hz in hz < 40 ? -20 : -90 }
        XCTAssertFalse(ids(model.stressFlags(spectrum: content, bands: Fixture.bands(subBass: -60),
                                             loudness: Fixture.loudness()))
            .contains(StressFlagID.subBassUnderDelivery))
    }

    // MARK: - (c) treble hot spot

    func testTrebleHotSpotFiresAndClears() {
        // +6 dB between 5 and 7 kHz over a flat target.
        let peaky = Fixture.curve(name: "Peaky") { hz in (hz > 5_000 && hz < 7_000) ? 6 : 0 }
        let model = HeadphoneModel(curve: peaky, target: Fixture.curve(name: "Flat target") { _ in 0 },
                                   thresholds: StressThresholds(), now: clock.read)
        let bright = Fixture.spectrum { hz in (hz > 4_000 && hz < 10_000) ? -30 : -90 }

        let flags = clock.settled {
            model.stressFlags(spectrum: bright, bands: Fixture.bands(), loudness: Fixture.loudness())
        }
        guard let flag = flags.first(where: { $0.id == StressFlagID.trebleHotSpot }) else {
            return XCTFail("treble hot spot did not fire; got \(flags.map(\.id))")
        }
        XCTAssertEqual(flag.severity, .watch)     // +6 dB is under the +8 dB "high" threshold
        XCTAssertTrue(flag.detail.contains("+6.0 dB"), flag.detail)
        XCTAssertTrue(flag.detail.contains("sibilance"), flag.detail)

        let quiet = clock.settled(5.01) {
            model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(),
                              loudness: Fixture.loudness())
        }
        XCTAssertFalse(ids(quiet).contains(StressFlagID.trebleHotSpot))
    }

    func testTrebleHotSpotNeedsMusicEnergyUpThere() {
        let peaky = Fixture.curve(name: "Peaky") { hz in (hz > 5_000 && hz < 7_000) ? 6 : 0 }
        let model = HeadphoneModel(curve: peaky, target: Fixture.curve(name: "Flat target") { _ in 0 },
                                   thresholds: StressThresholds(), now: clock.read)
        let dark = Fixture.spectrum { hz in hz < 2_000 ? -20 : -90 }
        XCTAssertFalse(ids(model.stressFlags(spectrum: dark, bands: Fixture.bands(), loudness: Fixture.loudness()))
            .contains(StressFlagID.trebleHotSpot))
    }

    // MARK: - (d) inter-sample overs

    func testInterSampleOversLatchUntilReset() {
        let model = flatModel()
        let flags = model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(),
                                      loudness: Fixture.loudness(truePeakMax: 1.3))
        guard let flag = flags.first(where: { $0.id == StressFlagID.interSampleOvers }) else {
            return XCTFail("overs did not fire; got \(flags.map(\.id))")
        }
        XCTAssertEqual(flag.severity, .high)
        XCTAssertTrue(flag.detail.contains("+1.30 dBTP"), flag.detail)

        // An over is an event: it stays up however long the signal behaves afterwards.
        clock.advance(600)
        XCTAssertTrue(ids(model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(),
                                            loudness: Fixture.loudness(truePeakMax: -3)))
            .contains(StressFlagID.interSampleOvers))
        model.resetFlags()
        XCTAssertFalse(ids(model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(),
                                             loudness: Fixture.loudness(truePeakMax: -3)))
            .contains(StressFlagID.interSampleOvers))
    }

    // MARK: - (e) dense master

    /// A minute of silence has PLR 0 and no integrated value. That is "no measurement", not a dense master.
    func testSilenceIsNotADenseMaster() {
        let model = HeadphoneModel(curve: Fixture.flatCurve(), target: nil)
        let silence = Fixture.loudness(plr: 0, measuredSeconds: 120)
        XCTAssertFalse(silence.isIntegratedValid)
        let flags = model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(), loudness: silence)
        XCTAssertFalse(flags.map(\.id).contains(StressFlagID.denseMaster))
    }

    func testDenseMasterNeedsThirtySecondsThenFiresAndClears() {
        let model = flatModel()
        let dense = Fixture.loudness(truePeakMax: -0.2, plr: 6.1, measuredSeconds: 12, integrated: -6.3)
        XCTAssertFalse(ids(model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(),
                                             loudness: dense))
            .contains(StressFlagID.denseMaster))

        let measured = Fixture.loudness(truePeakMax: -0.2, plr: 6.1, measuredSeconds: 47, integrated: -6.3)
        let flags = clock.settled {
            model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(), loudness: measured)
        }
        guard let flag = flags.first(where: { $0.id == StressFlagID.denseMaster }) else {
            return XCTFail("dense master did not fire; got \(flags.map(\.id))")
        }
        XCTAssertEqual(flag.severity, .info)
        XCTAssertTrue(flag.detail.contains("6.1 dB"), flag.detail)
        XCTAssertTrue(flag.detail.contains("47 s"), flag.detail)

        // PLR back over 8 + 2 dB for the release time. The flag needs a live measurement
        // to clear as well as to fire, so the reading stays a measurement.
        let open = Fixture.loudness(truePeakMax: -0.2, plr: 14, measuredSeconds: 60, integrated: -18)
        let cleared = clock.settled(5.01) {
            model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(), loudness: open)
        }
        XCTAssertFalse(ids(cleared).contains(StressFlagID.denseMaster))
    }

    // MARK: - (f) clipped samples

    func testClippedSamplesLatchUntilReset() {
        let model = flatModel()
        let flags = model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(),
                                      loudness: Fixture.loudness(clipCount: 3))
        guard let flag = flags.first(where: { $0.id == StressFlagID.clippedSamples }) else {
            return XCTFail("clip flag did not fire; got \(flags.map(\.id))")
        }
        XCTAssertEqual(flag.severity, .high)
        XCTAssertTrue(flag.detail.contains("3 runs"), flag.detail)

        // Clipping happened: the flag latches until the measurement resets.
        clock.advance(600)
        XCTAssertTrue(ids(model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(),
                                            loudness: Fixture.loudness()))
            .contains(StressFlagID.clippedSamples))
        model.resetFlags()
        XCTAssertFalse(ids(model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(),
                                             loudness: Fixture.loudness()))
            .contains(StressFlagID.clippedSamples))
    }

    // MARK: - Ordering, stability, reset

    func testHighSeverityComesFirst() {
        let model = flatModel()
        let loudness = Fixture.loudness(truePeakMax: 0.6, plr: 5, clipCount: 2, measuredSeconds: 60, integrated: -4.4)
        let flags = clock.settled {
            model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(), loudness: loudness)
        }
        XCTAssertEqual(flags.map(\.id), [
            StressFlagID.interSampleOvers, StressFlagID.clippedSamples, StressFlagID.denseMaster,
        ])
        XCTAssertEqual(flags.map(\.severity), [.high, .high, .info])
    }

    func testFlagsAreStableWhileHeld() {
        let model = flatModel()
        let first = model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(),
                                      loudness: Fixture.loudness(clipCount: 1))
        clock.advance(1)
        let held = model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(),
                                     loudness: Fixture.loudness())
        XCTAssertEqual(first, held)
        XCTAssertTrue(first[0].detail.contains("1 run "), first[0].detail)
    }

    func testResetDropsHeldFlags() {
        let model = flatModel()
        XCTAssertFalse(model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(),
                                         loudness: Fixture.loudness(clipCount: 1)).isEmpty)
        model.resetFlags()
        XCTAssertEqual(model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(),
                                         loudness: Fixture.loudness()), [])
    }

    func testEvaluateCarriesTheFlags() {
        let model = flatModel()
        let reading = model.evaluate(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(),
                                     loudness: Fixture.loudness(clipCount: 2))
        XCTAssertEqual(reading.stressFlags.map(\.id), [StressFlagID.clippedSamples])
    }

    // MARK: - Onsets

    /// `flagOnsets()` carries the "since mm:ss" a popover wants, so no flag text has to
    /// rewrite itself every second to show it.
    func testFlagOnsetsReportWhenEachFlagWentUp() {
        let model = flatModel()
        let quiet = Fixture.silentSpectrum()
        XCTAssertEqual(model.flagOnsets(), [:])

        // A clip at t = 2: an event flag, up at once.
        clock.advance(2)
        _ = model.stressFlags(spectrum: quiet, bands: Fixture.bands(), loudness: Fixture.loudness(clipCount: 1))
        XCTAssertEqual(model.flagOnsets()[StressFlagID.clippedSamples], 2)

        // Sub-bass load from t = 5, so it goes up at t = 8, when the attack is served.
        clock.advance(3)
        let loud = Fixture.bands(subBass: -12)
        _ = model.stressFlags(spectrum: quiet, bands: loud, loudness: Fixture.loudness(clipCount: 1))
        XCTAssertNil(model.flagOnsets()[StressFlagID.subBassLoad], "up before its attack")
        clock.advance(3.01)
        _ = model.stressFlags(spectrum: quiet, bands: loud, loudness: Fixture.loudness(clipCount: 1))
        XCTAssertEqual(try XCTUnwrap(model.flagOnsets()[StressFlagID.subBassLoad]), 8.01, accuracy: 0.001)
        // The clip flag keeps its own, older onset.
        XCTAssertEqual(model.flagOnsets()[StressFlagID.clippedSamples], 2)

        // Once a flag really clears, its onset goes with it.
        let clear = Fixture.bands(subBass: -40)
        _ = clock.settled(5.01) {
            model.stressFlags(spectrum: quiet, bands: clear, loudness: Fixture.loudness(clipCount: 1))
        }
        XCTAssertNil(model.flagOnsets()[StressFlagID.subBassLoad])
        XCTAssertEqual(model.flagOnsets()[StressFlagID.clippedSamples], 2)

        model.resetFlags()
        XCTAssertEqual(model.flagOnsets(), [:])
    }

    /// The texts themselves stay still: nothing in a held flag ticks with the clock.
    func testFlagTextDoesNotChangeWithTime() {
        let model = flatModel()
        let quiet = Fixture.silentSpectrum()
        let loud = Fixture.bands(subBass: -12)
        let raised = clock.settled { model.stressFlags(spectrum: quiet, bands: loud, loudness: Fixture.loudness()) }
        for _ in 0..<20 {
            clock.advance(1)
            let now = model.stressFlags(spectrum: quiet, bands: loud, loudness: Fixture.loudness())
            XCTAssertEqual(now, raised, "a flag text moved on its own")
        }
    }

    func testThresholdsAreTunable() {
        var t = StressThresholds()
        t.subBassLoadDBFS = -60
        t.subBassSustainSeconds = 0
        let model = flatModel(thresholds: t)
        XCTAssertTrue(ids(model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(subBass: -50),
                                            loudness: Fixture.loudness()))
            .contains(StressFlagID.subBassLoad))
    }
}
