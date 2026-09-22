import XCTest
import JoseonCore
@testable import JoseonHeadphones

/// Regression guards on the embedded AutoEq data plus the flag logic.
/// The expected values were read off the measurements, not chosen to make a test pass.
final class RealDataBehaviourTests: XCTestCase {

    private let library = HeadphoneLibrary(userCurvesDirectory: URL(fileURLWithPath: "/nonexistent"))
    private var clock = TestClock()

    override func setUp() {
        super.setUp()
        clock = TestClock()
    }

    private func model(_ headphone: String, _ target: String) -> HeadphoneModel {
        HeadphoneModel(curve: library.curve(named: headphone)!, target: library.target(named: target)!,
                       thresholds: StressThresholds(), now: clock.read)
    }

    /// Pink-ish music with real content everywhere, peaking near -20 dBFS in the low mids.
    private var musicSpectrum: SpectrumReading {
        Fixture.spectrum(bins: 1_024) { hz in -20 - 4.5 * log2(max(hz, 20) / 1_000) }
    }

    func testClosedBackConsumerCansPushBassAndOpenReferenceCansDoNot() {
        // Sub-bass shelf relative to each headphone's own 1 kHz level, 20–60 Hz.
        let sony = model("Sony WH-1000XM5", "Harman over-ear 2018").stressContext.meanSubBassResponseDB!
        let airpods = model("Apple AirPods Max", "Harman over-ear 2018").stressContext.meanSubBassResponseDB!
        let hd800s = model("Sennheiser HD 800 S", "Harman over-ear 2018").stressContext.meanSubBassResponseDB!
        XCTAssertGreaterThan(sony, 5, "WH-1000XM5 measures a large bass shelf")
        XCTAssertGreaterThan(airpods, 2, "AirPods Max measures a bass shelf")
        XCTAssertLessThan(hd800s, 0, "HD 800 S measures below its own 1 kHz level in the sub-bass")
    }

    func testHD800SRaisesDeepBassUnderDeliveryAgainstHarman() {
        let m = model("Sennheiser HD 800 S", "Harman over-ear 2018")
        let shortfall = m.stressContext.meanShortfallDB(from: 20, to: 40)!
        XCTAssertGreaterThan(shortfall, 6, "measured shortfall under 40 Hz")
        let flags = clock.settled {
            m.stressFlags(spectrum: musicSpectrum, bands: Fixture.bands(subBass: -30),
                          loudness: Fixture.loudness(truePeakMax: -2, plr: 12, measuredSeconds: 60))
        }
        XCTAssertTrue(flags.contains { $0.id == StressFlagID.subBassUnderDelivery },
                      "expected under-delivery, got \(flags.map(\.id))")
    }

    func testBassBoostedHeadphonesDoNotRaiseUnderDelivery() {
        for name in ["Sony WH-1000XM5", "Apple AirPods Max"] {
            let m = model(name, "Harman over-ear 2018")
            let flags = clock.settled {
                m.stressFlags(spectrum: musicSpectrum, bands: Fixture.bands(subBass: -30),
                              loudness: Fixture.loudness(truePeakMax: -2, plr: 12, measuredSeconds: 60))
            }
            XCTAssertFalse(flags.contains { $0.id == StressFlagID.subBassUnderDelivery },
                           "\(name) should not be short of deep bass")
        }
    }

    func testWH1000XM5RaisesATrebleHotSpot() {
        let m = model("Sony WH-1000XM5", "Harman over-ear 2018")
        let peak = m.stressContext.maxExcessOverTarget(from: 4_000, to: 10_000)!
        XCTAssertGreaterThan(peak.excessDB, 4)
        XCTAssertTrue((4_000...10_000).contains(peak.hz))
        let flags = clock.settled {
            m.stressFlags(spectrum: musicSpectrum, bands: Fixture.bands(subBass: -30),
                          loudness: Fixture.loudness(truePeakMax: -2, plr: 12, measuredSeconds: 60))
        }
        XCTAssertTrue(flags.contains { $0.id == StressFlagID.trebleHotSpot },
                      "expected a treble hot spot, got \(flags.map(\.id))")
    }

    func testSusvaraUnveiledIsCalmAgainstHarmanOnOrdinaryMusic() {
        // The listening rig this app is built for: nothing should shout at the user.
        let m = model("HiFiMAN Susvara Unveiled", "Harman over-ear 2018")
        XCTAssertEqual(m.stressContext.meanSubBassResponseDB!, 0, accuracy: 2)
        let flags = clock.settled {
            m.stressFlags(spectrum: musicSpectrum, bands: Fixture.bands(subBass: -30),
                          loudness: Fixture.loudness(truePeakMax: -2, plr: 12, measuredSeconds: 60))
        }
        XCTAssertEqual(flags, [], "unexpected flags: \(flags.map(\.id))")
    }

    func testNormalizedResponseIsSaneAcrossEveryEmbeddedHeadphone() {
        for curve in EmbeddedCurves.headphones {
            let m = HeadphoneModel(curve: curve, target: EmbeddedCurves.harmanOverEar2018)
            let onGrid = m.responseDB(onGrid: Fixture.grid(bins: 1_024))
            XCTAssertTrue(onGrid.allSatisfy { $0.isFinite && $0 > -60 && $0 < 40 },
                          "\(curve.name): normalized response out of range")
        }
    }
}
