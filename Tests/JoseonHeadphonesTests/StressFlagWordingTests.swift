import XCTest
import JoseonCore
@testable import JoseonHeadphones

/// Round 4: a flag says what is known, and says each number once.
///
/// Joseon sees the signal and knows the headphone's response. It does not know the playback
/// level, so it cannot know anything about driver excursion, and no flag may claim it.
final class StressFlagWordingTests: XCTestCase {

    private func allFlags() -> [StressFlag] {
        var clock: TimeInterval = 0
        let detector = StressDetector(now: { clock })
        // A rolled-off, treble-peaked headphone against a flat target, so (a), (b) and (c) all fire.
        let frequencies = (0..<200).map { 20 * pow(Float(1_000), Float($0) / 199) }
        let levels = frequencies.map { f -> Float in
            if f < 60 { return -9.37 }
            if f > 5_800 && f < 6_500 { return 5.13 }
            return 0
        }
        let context = StressContext(curveName: "Test phone", targetName: "Flat target", curveFrequencies: frequencies,
                                    curveLevels: levels, targetLevels: [Float](repeating: 0, count: frequencies.count))
        let spectrum = Fixture.spectrum(bins: 512) { f in
            if f >= 20 && f <= 60 { return -21.64 }
            if f >= 4_000 && f <= 10_000 { return -33.26 }
            return SpectrumReading.floorDB
        }
        let bands = Fixture.bands(subBass: -17.46)
        let loudness = Fixture.loudness(truePeakMax: 0.37, plr: 6.14, clipCount: 2, measuredSeconds: 47, integrated: -7.92)
        var flags = [StressFlag]()
        // Level flags need `levelAttackSeconds` of a true condition, so hold it 4 s.
        for _ in 0..<5 {
            flags = detector.evaluate(spectrum: spectrum, bands: bands, loudness: loudness, thresholds: StressThresholds(), context: context)
            clock += 1
        }
        return flags
    }

    func testEveryFlagFires() {
        XCTAssertEqual(Set(allFlags().map(\.id)), Set(StressFlagID.all))
    }

    func testNoFlagClaimsAnythingAboutTheDriver() {
        for flag in allFlags() {
            let text = (flag.title + " " + flag.detail + " " + flag.plotLabel).lowercased()
            for word in ["excursion", "driver", "bottom", "damage", "overload", "you will not hear"] {
                XCTAssertFalse(text.contains(word), "\(flag.id) says \"\(word)\": \(flag.detail)")
            }
        }
    }

    func testSubBassFlagSaysWhatIsKnown() {
        let flag = allFlags().first { $0.id == StressFlagID.subBassLoad }!
        XCTAssertTrue(flag.detail.contains("in the signal"), flag.detail)
        XCTAssertTrue(flag.detail.contains("\u{2212}17.5 dBFS"), flag.detail)              // the level of sub-bass in the signal
        XCTAssertTrue(flag.detail.contains("\u{2212}9.4 dB against its own level at 1.00 kHz"), flag.detail) // what the response does there
        XCTAssertTrue(flag.detail.contains("does not know"), flag.detail)
        XCTAssertEqual(flag.plotLabel, "\u{2212}17.5 dBFS")
    }

    /// Every number in the plot label is in the detail, written the same way, and so is every
    /// number in the title. One quantity, one rounding.
    func testNumbersAgreeAcrossTitleDetailAndPlotLabel() {
        let number = try! NSRegularExpression(pattern: "[+\u{2212}]?[0-9]+(\\.[0-9]+)?")
        func numbers(_ text: String) -> [String] {
            number.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) }
        }
        for flag in allFlags() {
            for n in numbers(flag.plotLabel) + numbers(flag.title) {
                XCTAssertTrue(numbers(flag.detail).contains(n), "\(flag.id): \"\(n)\" is on the plot or in the title but not in the detail: \(flag.detail)")
            }
            let all = flag.title + " " + flag.detail + " " + flag.plotLabel
            XCTAssertNil(all.range(of: "-[0-9]", options: .regularExpression), "\(flag.id) writes a minus as an ASCII hyphen: \(all)")
        }
    }

    /// Measured and threshold frequencies: one decimal under 1 kHz, x.xx kHz from there up.
    /// (Band names such as "20–60 Hz" are exact edges, not measurements, and stay as they are.)
    func testFrequencyFormat() {
        XCTAssertEqual(FlagText.hz(40), "40.0 Hz")
        XCTAssertEqual(FlagText.hz(999.94), "999.9 Hz")
        XCTAssertEqual(FlagText.hz(999.96), "1.00 kHz")
        XCTAssertEqual(FlagText.hz(6_104), "6.10 kHz")
        XCTAssertEqual(FlagText.db(-0.04), "0.0")
        XCTAssertEqual(FlagText.signedDB(-7.24), "\u{2212}7.2")
        XCTAssertEqual(FlagText.signedDB(5.13), "+5.1")

        let frequency = try! NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?) (k?Hz)")
        for flag in allFlags() {
            let text = flag.detail.replacingOccurrences(of: "20–60 Hz", with: "")
            for m in frequency.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let value = String(text[Range(m.range(at: 1), in: text)!])
                let unit = String(text[Range(m.range(at: 2), in: text)!])
                let decimals = value.split(separator: ".").dropFirst().first?.count ?? 0
                XCTAssertEqual(decimals, unit == "kHz" ? 2 : 1, "\(flag.id): \(value) \(unit) in: \(flag.detail)")
                if unit == "Hz" { XCTAssertLessThan(Float(value)!, 1_000) }
            }
        }
        let hot = allFlags().first { $0.id == StressFlagID.trebleHotSpot }!
        XCTAssertTrue(hot.detail.contains("kHz at +5.1 dB vs Flat target"), hot.detail)
        XCTAssertEqual(hot.plotLabel, "+5.1 dB vs Flat target")
    }
}
