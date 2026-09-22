import XCTest
import Darwin
@testable import JoseonCore

/// `SpectrumAnalyzer` as a `TopPeaksProviding`: the strongest tonal peaks of mid with their
/// note names, and the lowest frequency that carries sustained content.
final class TopPeaksTests: XCTestCase {

    private func feed(_ analyzer: SpectrumAnalyzer, left: [Float], right: [Float], sampleRate: Double) {
        precondition(left.count == right.count)
        var i = 0
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                while i < left.count {
                    let n = min(800, left.count - i)
                    analyzer.process(left: l.baseAddress! + i, right: r.baseAddress! + i, count: n, sampleRate: sampleRate)
                    i += n
                }
            }
        }
    }

    private func feedMono(_ analyzer: SpectrumAnalyzer, _ signal: [Float], _ rate: Double) {
        feed(analyzer, left: signal, right: signal, sampleRate: rate)
    }

    private func chord(_ frequencies: [Double], _ amplitudes: [Float], rate: Double, seconds: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Int(rate * seconds))
        for (hz, amplitude) in zip(frequencies, amplitudes) {
            let tone = TestSignals.sine(hz: hz, amplitude: amplitude, sampleRate: rate, seconds: seconds)
            for i in 0..<out.count { out[i] += tone[i] }
        }
        return out
    }

    // MARK: - topPeaks

    /// Five tones of decreasing level: five peaks, strongest first, each at its own frequency
    /// and level, each with the right note name.
    func testFiveTonesComeBackStrongestFirst() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        // A2, E3, A3, C#4, E4 - a spread-out A major, all more than 1/6 octave apart.
        let hz = [110.0, 164.81, 220.0, 277.18, 329.63]
        let levels: [Float] = [-6, -9, -12, -15, -18]
        feedMono(analyzer, chord(hz, levels.map { pow(10, $0 / 20) }, rate: rate, seconds: 3), rate)

        let peaks = analyzer.topPeaks
        XCTAssertEqual(peaks.count, 5)
        for i in 1..<peaks.count {
            XCTAssertLessThanOrEqual(peaks[i].levelDB, peaks[i - 1].levelDB, "peaks are not sorted by level")
        }
        let names = ["A2", "E3", "A3", "C#4", "E4"]
        for i in 0..<5 {
            XCTAssertEqual(Double(peaks[i].frequencyHz), hz[i], accuracy: hz[i] * 0.01, "peak \(i) frequency")
            XCTAssertEqual(peaks[i].levelDB, levels[i], accuracy: 0.5, "peak \(i) level")
            XCTAssertEqual(peaks[i].noteName, names[i], "peak \(i) note")
            XCTAssertEqual(peaks[i].cents, 0, accuracy: 5, "peak \(i) cents")
        }
    }

    /// The contract: `topPeaks.first` is the same peak as `peak`.
    func testFirstPeakIsThePeakReading() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, chord([440.0, 880.0, 1_318.5], [0.5, 0.2, 0.1], rate: rate, seconds: 2.5), rate)
        let (_, peak, _) = analyzer.read()
        let first = try? XCTUnwrap(analyzer.topPeaks.first)
        XCTAssertEqual(first?.frequencyHz, peak.frequencyHz)
        XCTAssertEqual(first?.levelDB, peak.levelDB)
        XCTAssertEqual(first?.noteName, peak.noteName)
        XCTAssertEqual(first?.cents ?? 0, peak.cents, accuracy: 0.001)
    }

    /// At most five, however many tones there are.
    func testAtMostFive() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let hz = [110.0, 147.0, 196.0, 262.0, 349.0, 466.0, 622.0, 831.0]
        feedMono(analyzer, chord(hz, hz.map { _ in Float(0.2) }, rate: rate, seconds: 3), rate)
        XCTAssertEqual(analyzer.topPeaks.count, SpectrumAnalyzer.maxTopPeaks)
    }

    /// One tone must not fill the list with its own skirt: entries stay 1/6 octave apart.
    func testEntriesAreAtLeastOneSixthOfAnOctaveApart() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        // 1000 and 1010 Hz are 0.014 octave apart: one entry, not two.
        feedMono(analyzer, chord([1_000.0, 1_010.0, 4_000.0], [0.5, 0.45, 0.3], rate: rate, seconds: 3), rate)
        let peaks = analyzer.topPeaks
        XCTAssertGreaterThan(peaks.count, 0)
        for i in 0..<peaks.count {
            for j in (i + 1)..<peaks.count {
                let octaves = abs(log2(peaks[i].frequencyHz / peaks[j].frequencyHz))
                XCTAssertGreaterThanOrEqual(octaves, SpectrumAnalyzer.topPeakSeparationOctaves - 1e-4,
                                            "\(peaks[i].frequencyHz) Hz and \(peaks[j].frequencyHz) Hz are \(octaves) octaves apart")
            }
        }
    }

    /// Noise has no tonal peak to name, so the list is empty. `peak` still reports where the
    /// most power is; the two are only required to agree when the list is not empty.
    func testNoiseAndSilenceGiveNoPeaks() {
        let rate = 48_000.0
        let noisy = SpectrumAnalyzer()
        feedMono(noisy, TestSignals.whiteNoise(amplitude: 0.3, count: Int(rate * 2)), rate)
        XCTAssertEqual(noisy.topPeaks.count, 0, "white noise is not tonal")

        let silent = SpectrumAnalyzer()
        feedMono(silent, [Float](repeating: 0, count: Int(rate * 2)), rate)
        XCTAssertEqual(silent.topPeaks.count, 0)
    }

    /// A tone under the -80 dBFS gate is not reported.
    func testAVeryQuietToneIsBelowTheGate() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, TestSignals.sine(hz: 1_000, amplitude: pow(10, -90.0 / 20), sampleRate: rate, seconds: 2), rate)
        XCTAssertEqual(analyzer.topPeaks.count, 0)
    }

    /// `reset` starts a new measurement: the list empties until new audio arrives.
    func testResetClearsTheList() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, chord([440.0, 880.0], [0.5, 0.3], rate: rate, seconds: 2), rate)
        XCTAssertGreaterThan(analyzer.topPeaks.count, 0)
        analyzer.reset()
        XCTAssertEqual(analyzer.topPeaks.count, 0)
    }

    // MARK: - lowestStrongHz

    /// Zero before three seconds have been measured, then the low tone of the pair.
    func testLowestStrongNeedsThreeSecondsAndThenFindsTheLowTone() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let signal = chord([80.0, 2_000.0], [0.5, 0.5], rate: rate, seconds: 2)
        feedMono(analyzer, signal, rate)
        XCTAssertEqual(analyzer.lowestStrongHz, 0, "nothing before 3 s of measurement")

        feedMono(analyzer, chord([80.0, 2_000.0], [0.5, 0.5], rate: rate, seconds: 4), rate)
        let hz = analyzer.lowestStrongHz
        XCTAssertGreaterThan(hz, 0)
        XCTAssertEqual(hz, 80, accuracy: 80 * 0.15, "found \(hz) Hz")
    }

    /// Content more than 12 dB under the loudest part of the smoothed average does not count.
    func testQuietLowContentIsNotStrong() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        // 40 Hz is 50 dB under the 1 kHz tone: far below the 12 dB window.
        feedMono(analyzer, chord([40.0, 1_000.0], [pow(10, -50.0 / 20) * 0.5, 0.5], rate: rate, seconds: 5), rate)
        let hz = analyzer.lowestStrongHz
        XCTAssertGreaterThan(hz, 200, "40 Hz is too quiet to count, got \(hz) Hz")
        XCTAssertEqual(hz, 1_000, accuracy: 1_000 * 0.2, "found \(hz) Hz")
    }

    /// `reset` starts the three-second clock again.
    func testResetClearsLowestStrong() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        feedMono(analyzer, chord([80.0, 2_000.0], [0.5, 0.5], rate: rate, seconds: 5), rate)
        XCTAssertGreaterThan(analyzer.lowestStrongHz, 0)
        analyzer.reset()
        XCTAssertEqual(analyzer.lowestStrongHz, 0)
    }

    // MARK: - Plumbing and cost

    /// The engine copies both into every frame.
    func testTheEngineCopiesThemIntoTheFrame() {
        let rate = 48_000.0
        let engine = AnalysisEngine()
        let signal = chord([220.0, 440.0, 660.0], [0.5, 0.3, 0.2], rate: rate, seconds: 5)
        var frame: AnalysisFrame?
        var i = 0
        while i < signal.count {
            let n = min(800, signal.count - i)
            frame = engine.processNow(left: Array(signal[i..<(i + n)]), right: Array(signal[i..<(i + n)]), count: n, sampleRate: rate)
            i += n
        }
        let f = frame!
        XCTAssertGreaterThan(f.topPeaks.count, 0)
        XCTAssertEqual(f.topPeaks.first?.frequencyHz, f.peak.frequencyHz)
        XCTAssertGreaterThan(f.lowestStrongHz, 0)
    }

    /// The list is built in `read`, from storage filled in `process`, so `process` still does
    /// not allocate once it is warm.
    func testProcessStillDoesNotAllocate() {
        let rate = 48_000.0
        let analyzer = SpectrumAnalyzer()
        let signal = chord([220.0, 440.0, 660.0, 880.0, 1_320.0], [0.4, 0.3, 0.2, 0.15, 0.1], rate: rate, seconds: 2)
        feedMono(analyzer, signal, rate)
        _ = analyzer.read()
        XCTAssertGreaterThan(analyzer.topPeaks.count, 0, "there is something to build a list from")

        func liveBlocks() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &stats)
            return Int(stats.blocks_in_use)
        }
        signal.withUnsafeBufferPointer { p in
            var offset = 0
            analyzer.process(left: p.baseAddress!, right: p.baseAddress!, count: 800, sampleRate: rate)
            let before = liveBlocks()
            for _ in 0..<500 {
                analyzer.process(left: p.baseAddress! + offset, right: p.baseAddress! + offset, count: 800, sampleRate: rate)
                offset += 800
                if offset + 800 > signal.count { offset = 0 }
            }
            XCTAssertLessThanOrEqual(liveBlocks() - before, 4, "process allocated when warm")
        }
    }
}
