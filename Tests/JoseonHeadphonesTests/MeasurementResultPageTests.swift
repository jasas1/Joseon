import XCTest
@testable import JoseonHeadphones
import JoseonCore

/// The result page of "Measure your headphone…" (review ringer-r2, critic round 7 item 2):
/// one bass roll-off note on an averaged result, and one gate for "noise or leak".
///
/// No audio: two tests simulate the chain like the rest of the measurement suite, the others
/// work on hand-made curves. The controller side of the same fixes (the leak card, the save
/// confirmations) is checked by the offline self-check, `JOSEON_MEASURE_SELFCHECK=1`.
final class MeasurementResultPageTests: XCTestCase {

    let sampleRate = 48_000.0
    let grid = SweepAnalysis.standardGrid

    // MARK: - a. One roll-off note on the average

    /// Both sides leak, by different amounts. Each side carries its own note; the average must
    /// carry exactly one, and that one must be the note of the averaged curve.
    func testAverageOfTwoLeakySidesCarriesExactlyOneRollOffNote() throws {
        let left = side(bassDB: -14, snrAt40Hz: 40)
        let right = side(bassDB: -20, snrAt40Hz: 32)
        let leftNote = try XCTUnwrap(left.bassRollOffNote)
        let rightNote = try XCTUnwrap(right.bassRollOffNote)
        XCTAssertNotEqual(leftNote, rightNote, "the two sides must differ, or the old de-duplication would hide the defect")

        let average = MeasuredHeadphone.average(left, right)
        let notes = average.quality.warnings.filter(MeasuredHeadphone.isBassRollOffNote)
        XCTAssertEqual(notes.count, 1, "\(notes)")
        XCTAssertEqual(notes.first, average.bassRollOffNote)
        XCTAssertFalse(average.quality.warnings.contains(leftNote))
        XCTAssertFalse(average.quality.warnings.contains(rightNote))
        // The mean of a 14 dB and a 20 dB fall, with the worse signal-to-noise of the two sides.
        let note = try XCTUnwrap(notes.first)
        XCTAssertTrue(note.contains("falls 17 dB"), note)
        XCTAssertTrue(note.contains("32 dB of signal-to-noise"), note)

        // Everything else is still the union of both sides, once each, under the average banner.
        XCTAssertEqual(average.quality.warnings.first, MeasuredHeadphone.averageNote)
        XCTAssertEqual(average.quality.warnings.filter { $0 == "Both sides say this." }.count, 1)
        XCTAssertTrue(average.quality.warnings.contains("Only the left side says this."))
        XCTAssertTrue(average.quality.warnings.contains("Only the right side says this."))
        XCTAssertEqual(average.quality.runs, 6)
    }

    /// One noisy side makes the averaged bass "limited by noise": the worse signal-to-noise wins,
    /// and the one note says so.
    func testAverageWithOneNoisySideSaysNoiseOnce() throws {
        let average = MeasuredHeadphone.average(side(bassDB: -14, snrAt40Hz: 40), side(bassDB: -14, snrAt40Hz: 6))
        let notes = average.quality.warnings.filter(MeasuredHeadphone.isBassRollOffNote)
        XCTAssertEqual(notes.count, 1, "\(notes)")
        XCTAssertTrue(notes[0].contains("limited by noise"), notes[0])
        XCTAssertFalse(notes[0].contains("seal leak"), notes[0])
    }

    /// Sealed sides: no note per side, none on the average. And one leaky side whose fall the
    /// average halves under the threshold leaves no stale per-side sentence behind.
    func testAverageWithoutAFallCarriesNoRollOffNote() {
        let sealed = MeasuredHeadphone.average(side(bassDB: -3, snrAt40Hz: 40), side(bassDB: -4, snrAt40Hz: 40))
        XCTAssertTrue(sealed.quality.warnings.filter(MeasuredHeadphone.isBassRollOffNote).isEmpty)

        let halved = MeasuredHeadphone.average(side(bassDB: -14, snrAt40Hz: 40), side(bassDB: -2, snrAt40Hz: 40))
        XCTAssertNil(halved.bassRollOffNote)
        XCTAssertTrue(halved.quality.warnings.filter(MeasuredHeadphone.isBassRollOffNote).isEmpty, "\(halved.quality.warnings)")
    }

    /// The same through the real analysis: two simulated leaky sides, 80 Hz and 150 Hz.
    func testAverageOfTwoSimulatedLeakySidesCarriesExactlyOneRollOffNote() throws {
        let left = measure(leakAtHz: 80, snrDB: 45)
        let right = measure(leakAtHz: 150, snrDB: 45)
        XCTAssertEqual(left.quality.warnings.filter(MeasuredHeadphone.isBassRollOffNote).count, 1)
        XCTAssertEqual(right.quality.warnings.filter(MeasuredHeadphone.isBassRollOffNote).count, 1)
        XCTAssertNotEqual(left.bassRollOffNote, right.bassRollOffNote)

        let average = MeasuredHeadphone.average(left, right)
        let notes = average.quality.warnings.filter(MeasuredHeadphone.isBassRollOffNote)
        print("  average of an 80 Hz and a 150 Hz leak: \(notes)")
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first, average.bassRollOffNote)
        // No other sentence doubles either.
        XCTAssertEqual(Set(average.quality.warnings).count, average.quality.warnings.count, "\(average.quality.warnings)")
    }

    /// Every verdict of the note is recognised, so the average can drop all three.
    func testEveryRollOffNoteIsRecognised() throws {
        let levels = grid.map { $0 <= 50 ? -15.0 : 0.0 }
        for snr in [nil, 3.0, 40.0] as [Double?] {
            let note = try XCTUnwrap(MeasuredHeadphone.bassRollOffNote(normalizedLevelsDB: levels, grid: grid, snrAt40Hz: snr))
            XCTAssertTrue(MeasuredHeadphone.isBassRollOffNote(note), note)
        }
        XCTAssertFalse(MeasuredHeadphone.isBassRollOffNote("No coupler correction."))
    }

    // MARK: - b. One gate for noise versus leak

    /// `bassIsMeasured` is what the leak card of the result page asks. It must flip at exactly the
    /// signal-to-noise ratio where the note flips from "limited by noise" to "seal leak".
    func testTheLeakGateAndTheRollOffNoteFlipAtTheSameSignalToNoiseRatio() throws {
        let gate = MeasuredHeadphone.snrThresholdDB
        let levels = grid.map { $0 <= 50 ? -15.0 : 0.0 }
        for snr in [-10, 0, gate - 5, gate - 0.01, gate, gate + 0.01, gate + 30] {
            let note = try XCTUnwrap(MeasuredHeadphone.bassRollOffNote(normalizedLevelsDB: levels, grid: grid, snrAt40Hz: snr))
            let measured = MeasuredHeadphone.bassIsMeasured(snrAt40Hz: snr)
            XCTAssertEqual(measured, snr >= gate, "at \(snr) dB")
            XCTAssertEqual(note.contains("looks like a seal leak"), measured, "at \(snr) dB: \(note)")
            XCTAssertEqual(note.contains("limited by noise"), !measured, "at \(snr) dB: \(note)")
        }
    }

    /// No noise-only segment, or a figure that is not a number: nothing says "leak".
    func testTheLeakGateIsClosedWithoutASignalToNoiseFigure() {
        XCTAssertFalse(MeasuredHeadphone.bassIsMeasured(snrAt40Hz: nil))
        XCTAssertFalse(MeasuredHeadphone.bassIsMeasured(snrAt40Hz: .nan))
        XCTAssertFalse(MeasuredHeadphone.bassIsMeasured(snrAt40Hz: -.infinity))
        XCTAssertTrue(MeasuredHeadphone.bassIsMeasured(snrAt40Hz: MeasuredHeadphone.snrThresholdDB))
    }

    /// Through the real analysis: the quiet leak passes the gate, the noisy one does not, the one
    /// without a noise segment does not.
    func testTheLeakGateOnSimulatedMeasurements() {
        func gate(_ m: MeasuredHeadphone) -> Bool { MeasuredHeadphone.bassIsMeasured(snrAt40Hz: m.quality.snrDB(atHz: 40).map(Double.init)) }
        XCTAssertTrue(gate(measure(leakAtHz: 80, snrDB: 45)))
        XCTAssertFalse(gate(measure(leakAtHz: 80, snrDB: 5)))
        XCTAssertFalse(gate(measure(leakAtHz: 80, snrDB: 45, withNoiseSegment: false)))
    }

    // MARK: - Helpers

    /// A hand-made side: flat, with a bass shelf of `bassDB` at and under 50 Hz, and one
    /// signal-to-noise figure everywhere.
    private func side(bassDB: Float, snrAt40Hz: Float) -> MeasuredHeadphone {
        let levels = grid.map { $0 <= 50 ? bassDB : Float(0) }
        let curve = HeadphoneCurve(name: "side", source: "test", frequenciesHz: grid.map(Float.init), levelsDB: levels)
        var quality = MeasurementQuality(frequenciesHz: grid.map(Float.init), snrDB: [Float](repeating: snrAt40Hz, count: grid.count),
                                         thdPercent: 0.1, runs: 3, agreementDB: 0.2)
        var measured = MeasuredHeadphone(curve: curve, absoluteMagnitudeDB: levels, sensitivity: nil, derivedSensitivity: nil,
                                         quality: quality, method: "test")
        quality.warnings = ["Both sides say this.", bassDB == -14 ? "Only the left side says this." : "Only the right side says this."]
        if let note = measured.bassRollOffNote { quality.warnings.insert(note, at: 1) }
        measured.quality = quality
        return measured
    }

    /// One simulated session with a first-order leak in front of the headphone.
    private func measure(leakAtHz: Double, snrDB: Double, withNoiseSegment: Bool = true) -> MeasuredHeadphone {
        var headphone = FilterCascade.headphone(sampleRate: sampleRate)
        headphone.stages.append(Biquad.firstOrderHighPass(hz: leakAtHz, sampleRate: sampleRate))
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
}
