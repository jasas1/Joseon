import XCTest
import JoseonCore
@testable import JoseonHeadphones

/// Missing-for-the-listener item 1: the stress flags that are about a part of the spectrum
/// carry the span they were measured over and a short number, so a panel can shade the band
/// and label it without inventing anything. Whole-signal flags carry neither.
final class StressFlagPlotTests: XCTestCase {

    private var clock = TestClock()

    override func setUp() {
        super.setUp()
        clock = TestClock()
    }

    private func flag(_ flags: [StressFlag], _ id: String) throws -> StressFlag {
        try XCTUnwrap(flags.first { $0.id == id }, "\(id) did not fire; got \(flags.map(\.id))")
    }

    // MARK: - (a) Sub-bass load: 20…60 Hz, labelled with the level

    func testSubBassLoadCarriesItsBandAndLevel() throws {
        let model = HeadphoneModel(curve: Fixture.flatCurve(name: "Flat test"),
                                   target: Fixture.curve(name: "Flat target") { _ in 0 },
                                   thresholds: StressThresholds(), now: clock.read)
        let loud = Fixture.bands(subBass: -9)
        _ = model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: loud, loudness: Fixture.loudness())
        clock.advance(3.01)
        let flags = model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: loud, loudness: Fixture.loudness())

        let f = try flag(flags, StressFlagID.subBassLoad)
        let range = try XCTUnwrap(f.frequencyRangeHz)
        XCTAssertEqual(range.lowerBound, 20, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 60, accuracy: 0.001, "the sub-bass band the level is measured over")
        XCTAssertEqual(f.plotLabel, "\u{2212}9.0 dBFS")
    }

    // MARK: - (b) Deep bass not delivered: 20…40 Hz, labelled with the shortfall

    func testUnderDeliveryCarriesTheDeepBassSpanAndTheShortfall() throws {
        let model = HeadphoneModel(
            curve: Fixture.flatCurve(name: "Flat test"),
            target: Fixture.curve(name: "Deep target") { hz in hz < 40 ? 7 : 0 },
            thresholds: StressThresholds(),
            now: clock.read
        )
        let content = Fixture.spectrum { hz in hz < 40 ? -35 : -90 }
        let flags = clock.settled {
            model.stressFlags(spectrum: content, bands: Fixture.bands(subBass: -40), loudness: Fixture.loudness())
        }

        let f = try flag(flags, StressFlagID.subBassUnderDelivery)
        let range = try XCTUnwrap(f.frequencyRangeHz)
        XCTAssertEqual(range.lowerBound, 20, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 40, accuracy: 0.001, "the span the shortfall is averaged over")
        XCTAssertEqual(f.plotLabel, "\u{2212}7.0 dB vs Deep target")
    }

    /// The span follows the threshold, so the shading can never disagree with the detail text.
    func testUnderDeliverySpanFollowsTheThreshold() throws {
        var thresholds = StressThresholds()
        thresholds.deepBassTopHz = 50
        let model = HeadphoneModel(
            curve: Fixture.flatCurve(name: "Flat test"),
            target: Fixture.curve(name: "Deep target") { hz in hz < 50 ? 7 : 0 },
            thresholds: thresholds,
            now: clock.read
        )
        let content = Fixture.spectrum { hz in hz < 50 ? -35 : -90 }
        let flags = clock.settled {
            model.stressFlags(spectrum: content, bands: Fixture.bands(subBass: -40), loudness: Fixture.loudness())
        }
        let range = try XCTUnwrap(try flag(flags, StressFlagID.subBassUnderDelivery).frequencyRangeHz)
        XCTAssertEqual(range.upperBound, 50, accuracy: 0.001)
    }

    // MARK: - (c) Treble hot spot: the peak, ± 1/6 octave

    func testTrebleHotSpotCarriesThePeakSpanAndTheExcess() throws {
        let peaky = Fixture.curve(name: "Peaky") { hz in (hz > 5_000 && hz < 7_000) ? 4.6 : 0 }
        let model = HeadphoneModel(curve: peaky, target: Fixture.curve(name: "Flat target") { _ in 0 },
                                   thresholds: StressThresholds(), now: clock.read)
        let bright = Fixture.spectrum { hz in (hz > 4_000 && hz < 10_000) ? -30 : -90 }
        let flags = clock.settled {
            model.stressFlags(spectrum: bright, bands: Fixture.bands(), loudness: Fixture.loudness())
        }

        let f = try flag(flags, StressFlagID.trebleHotSpot)
        let range = try XCTUnwrap(f.frequencyRangeHz)
        // The detail text names the peak frequency; the span has to be centred on it.
        let sixth = exp2(Float(1.0 / 6))
        let centre = (range.lowerBound * range.upperBound).squareRoot()
        XCTAssertGreaterThan(centre, 5_000)
        XCTAssertLessThan(centre, 7_000)
        XCTAssertEqual(range.upperBound / range.lowerBound, sixth * sixth, accuracy: 0.02, "a third of an octave wide")
        XCTAssertTrue(f.detail.contains(FlagText.hz(centre)), "\(f.detail) vs centre \(centre)")
        XCTAssertEqual(f.plotLabel, "+4.6 dB vs Flat target")
    }

    /// The span never leaves the treble window, even for a peak sitting on its edge.
    func testTrebleHotSpotSpanStaysInsideTheTrebleWindow() throws {
        var thresholds = StressThresholds()
        thresholds.trebleLowHz = 4_000
        thresholds.trebleHighHz = 10_000
        let peaky = Fixture.curve(name: "Peaky") { hz in hz >= 9_000 ? 9 : 0 }
        let model = HeadphoneModel(curve: peaky, target: Fixture.curve(name: "Flat target") { _ in 0 },
                                   thresholds: thresholds, now: clock.read)
        let bright = Fixture.spectrum { hz in (hz > 4_000 && hz < 10_000) ? -30 : -90 }
        let flags = clock.settled {
            model.stressFlags(spectrum: bright, bands: Fixture.bands(), loudness: Fixture.loudness())
        }
        let range = try XCTUnwrap(try flag(flags, StressFlagID.trebleHotSpot).frequencyRangeHz)
        XCTAssertGreaterThanOrEqual(range.lowerBound, 4_000)
        XCTAssertLessThanOrEqual(range.upperBound, 10_000)
        XCTAssertLessThan(range.lowerBound, range.upperBound)
    }

    // MARK: - Whole-signal flags point at nothing

    func testWholeSignalFlagsHaveNoSpanAndNoLabel() {
        let model = HeadphoneModel(curve: Fixture.flatCurve(name: "Flat test"),
                                   target: Fixture.curve(name: "Flat target") { _ in 0 },
                                   thresholds: StressThresholds(), now: clock.read)
        let loudness = Fixture.loudness(truePeakMax: 1.2, plr: 5, clipCount: 3, measuredSeconds: 120, integrated: -6)
        let flags = clock.settled {
            model.stressFlags(spectrum: Fixture.silentSpectrum(), bands: Fixture.bands(), loudness: loudness)
        }

        let wholeSignal: [String] = [StressFlagID.interSampleOvers, StressFlagID.denseMaster, StressFlagID.clippedSamples]
        for id in wholeSignal {
            guard let f = flags.first(where: { $0.id == id }) else {
                XCTFail("\(id) did not fire; got \(flags.map(\.id))")
                continue
            }
            XCTAssertNil(f.frequencyRangeHz, "\(id) is about the whole signal")
            XCTAssertEqual(f.plotLabel, "", "\(id) has nothing to label a band with")
        }
    }

    /// Every span a flag reports is a real range inside the audible band.
    func testEverySpanIsSane() {
        let peaky = Fixture.curve(name: "Peaky") { hz in (hz > 5_000 && hz < 7_000) ? 9 : 0 }
        let model = HeadphoneModel(curve: peaky,
                                   target: Fixture.curve(name: "Deep target") { hz in hz < 40 ? 12 : 0 },
                                   thresholds: StressThresholds(), now: clock.read)
        let busy = Fixture.spectrum { hz in hz < 40 || (hz > 4_000 && hz < 10_000) ? -25 : -60 }
        _ = model.stressFlags(spectrum: busy, bands: Fixture.bands(subBass: -12), loudness: Fixture.loudness())
        clock.advance(3.01)
        let flags = model.stressFlags(spectrum: busy, bands: Fixture.bands(subBass: -12),
                                      loudness: Fixture.loudness(truePeakMax: 1.2, clipCount: 2))
        XCTAssertGreaterThan(flags.count, 2)
        for f in flags {
            guard let range = f.frequencyRangeHz else {
                XCTAssertEqual(f.plotLabel, "", "\(f.id) labels a band it does not have")
                continue
            }
            XCTAssertGreaterThanOrEqual(range.lowerBound, 20, f.id)
            XCTAssertLessThanOrEqual(range.upperBound, 20_000, f.id)
            XCTAssertLessThan(range.lowerBound, range.upperBound, f.id)
            XCTAssertFalse(f.plotLabel.isEmpty, "\(f.id) shades a band with no label")
        }
    }
}
