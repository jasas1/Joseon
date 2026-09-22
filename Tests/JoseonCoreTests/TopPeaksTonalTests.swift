import XCTest
@testable import JoseonCore

/// Round 4: a note name belongs to a tone, not to the top of a kick drum, and a marker belongs
/// on the curve. And `lowestStrongHz` answers the question it is named after.
final class TopPeaksTonalTests: XCTestCase {

    /// Feeds like the engine does: 800 frames, then a read.
    private func run(_ analyzer: SpectrumAnalyzer, seconds: Double, rate: Double = 48_000,
                     each: ((Double) -> Void)? = nil,
                     signal: (Int, Int) -> (left: [Float], right: [Float])) -> (SpectrumReading, PeakReading) {
        let block = Int(rate / 60)
        var last = analyzer.read()
        for k in 0..<Int(seconds * 60) {
            let s = signal(k * block, block)
            analyzer.process(left: s.left, right: s.right, count: block, sampleRate: rate)
            last = analyzer.read()
            each?(Double((k + 1) * block) / rate)
        }
        return (last.spectrum, last.peak)
    }

    private func kick(_ start: Int, _ count: Int) -> (left: [Float], right: [Float]) {
        let noise = TestSignals.pinkNoise(amplitude: 0.02, count: 1 << 16, seed: 0x4B1C)
        var x = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let beat = (Double(start + i) / 48_000).truncatingRemainder(dividingBy: 0.5)
            x[i] = Float(exp(-beat * 18) * sin(2 * .pi * (48 + 60 * exp(-beat * 30)) * beat)) * 0.5 + noise[(start + i) % noise.count]
        }
        return (x, x)
    }

    private func curveValue(_ reading: SpectrumReading, near hz: Float) -> Float {
        let i = reading.frequencies.enumerated().min { abs(log2($0.element / hz)) < abs(log2($1.element / hz)) }!.offset
        return reading.mid[max(i - 1, 0)...min(i + 1, reading.mid.count - 1)].max()!
    }

    // MARK: topPeaks

    /// The demo signal at 8 s: chord root 98 Hz. The list is partials of the chord, by name,
    /// and nothing on the 35-110 Hz kick hump (round 3 named it F1, A#1 and D#2).
    func testDemoSignalNamesTheChordNotTheKick() {
        let analyzer = SpectrumAnalyzer()
        let (reading, peak) = run(analyzer, seconds: 8) { TestSignals.demoBlock(startSample: $0, count: $1) }
        let peaks = analyzer.topPeaks
        print("demo top peaks:", peaks.map { "\($0.noteName) \($0.frequencyHz) Hz \($0.levelDB) dB" })
        let chord: [String: Float] = ["G2": 98, "D3": 147, "G3": 196, "B3": 246.96, "D4": 294, "G4": 392]
        XCTAssertGreaterThanOrEqual(peaks.count, 4, "the chord has six partials over the gate")
        for p in peaks {
            let expected = chord[p.noteName]
            XCTAssertNotNil(expected, "\(p.noteName) at \(p.frequencyHz) Hz is not a partial of the chord")
            if let expected { XCTAssertEqual(p.frequencyHz, expected, accuracy: expected * 0.005, p.noteName) }
            // On the curve: the display bin the marker lands in reads the same level.
            XCTAssertEqual(p.levelDB, curveValue(reading, near: p.frequencyHz), accuracy: 0.05, "\(p.noteName) floats off the mid curve")
        }
        XCTAssertEqual(peaks.first, peak, "a list that is not empty starts with `peak`")
        XCTAssertEqual(peak.noteName, "G2")
        XCTAssertEqual(peak.cents, 0, accuracy: 3)
    }

    /// With a display tilt the marker follows the documented offset rule.
    func testLevelsFollowTheTiltOffsetRule() {
        var settings = SpectrumSettings()
        settings.tiltDBPerOctave = 4.5
        let analyzer = SpectrumAnalyzer(settings: settings)
        let (reading, _) = run(analyzer, seconds: 8) { TestSignals.demoBlock(startSample: $0, count: $1) }
        let peaks = analyzer.topPeaks
        XCTAssertGreaterThanOrEqual(peaks.count, 4)
        for p in peaks {
            let onCurve = p.levelDB + 4.5 * log2(p.frequencyHz / 1_000)
            XCTAssertEqual(onCurve, curveValue(reading, near: p.frequencyHz), accuracy: 0.1, p.noteName)
        }
    }

    /// A kick drum and a little noise: one broad hump. `peak` says where it is, names no note,
    /// and the list is empty.
    func testAKickHumpGetsNoNote() {
        let analyzer = SpectrumAnalyzer()
        var named = 0
        let (reading, peak) = run(analyzer, seconds: 4, each: { _ in
            named += analyzer.topPeaks.filter { !$0.noteName.isEmpty }.count
        }, signal: kick)
        XCTAssertEqual(named, 0, "a note was named on the kick hump in some frame")
        XCTAssertEqual(analyzer.topPeaks.count, 0)
        XCTAssertEqual(peak.noteName, "")
        XCTAssertGreaterThan(peak.frequencyHz, 30)
        XCTAssertLessThan(peak.frequencyHz, 120)
        XCTAssertEqual(peak.levelDB, curveValue(reading, near: peak.frequencyHz), accuracy: 0.05, "the peak marker floats off the mid curve")
    }

    /// Tones keep their names down to the bottom of the range, where the analyzer's own lobe is
    /// wider than 1/12 octave, and a broad peak first in the list does not push a tone out of it.
    func testLowTonesAndATonalListBehindABroadPeak() {
        let low = SpectrumAnalyzer()
        _ = run(low, seconds: 3) { start, count in
            let x = (0..<count).map { Float(0.25 * sin(2 * Double.pi * 30.87 * Double(start + $0) / 48_000)) }
            return (x, x)
        }
        XCTAssertEqual(low.topPeaks.first?.noteName, "B0")

        // A loud kick and a 440 Hz tone 10 dB under its hump: `peak` is the hump, the list still has A4.
        let analyzer = SpectrumAnalyzer()
        let (_, peak) = run(analyzer, seconds: 4) { start, count in
            var s = self.kick(start, count)
            for i in 0..<count { s.left[i] += Float(0.02 * sin(2 * Double.pi * 440 * Double(start + i) / 48_000)); s.right[i] = s.left[i] }
            return s
        }
        let peaks = analyzer.topPeaks
        XCTAssertEqual(peak.noteName, "")
        XCTAssertEqual(peaks.first, peak)
        XCTAssertEqual(peaks.dropFirst().map(\.noteName), ["A4"])
    }

    // MARK: lowestStrongHz

    func testDemoLowestStrongIsTheKick() {
        let analyzer = SpectrumAnalyzer()
        var early: Float = -1
        var values = Set<Float>()
        _ = run(analyzer, seconds: 8, each: { t in
            if t < 2.9 { early = max(early, analyzer.lowestStrongHz) }
            if t > 5 { values.insert(analyzer.lowestStrongHz) }
        }) { TestSignals.demoBlock(startSample: $0, count: $1) }
        let hz = analyzer.lowestStrongHz
        print("demo lowest strong content:", hz, "values after 5 s:", values.sorted())
        XCTAssertEqual(early, 0, "nothing before 3 s")
        XCTAssertGreaterThanOrEqual(hz, 30)
        XCTAssertLessThanOrEqual(hz, 45)
        XCTAssertEqual(hz, hz.rounded(), "whole Hz")
        XCTAssertLessThanOrEqual(values.count, 3, "the number should hold still, got \(values.sorted())")
    }

    func testLowestStrongOfOneToneSilenceAndInfrasound() {
        let tone = SpectrumAnalyzer()
        _ = run(tone, seconds: 5) { start, count in
            let x = (0..<count).map { Float(0.5 * sin(2 * Double.pi * 1_000 * Double(start + $0) / 48_000)) }
            return (x, x)
        }
        XCTAssertEqual(tone.lowestStrongHz, 1_000, accuracy: 50)

        let silent = SpectrumAnalyzer()
        _ = run(silent, seconds: 5) { _, count in ([Float](repeating: 0, count: count), [Float](repeating: 0, count: count)) }
        XCTAssertEqual(silent.lowestStrongHz, 0)

        // 12 Hz is on the plot (it starts at 10 Hz) but it is not an answer: never under 20 Hz.
        let rumble = SpectrumAnalyzer()
        _ = run(rumble, seconds: 5) { start, count in
            let x = (0..<count).map { Float(0.5 * sin(2 * Double.pi * 12 * Double(start + $0) / 48_000)) }
            return (x, x)
        }
        let hz = rumble.lowestStrongHz
        XCTAssertTrue(hz == 0 || hz >= 20, "got \(hz) Hz")
    }
}
