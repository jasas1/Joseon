import XCTest
@testable import JoseonHeadphones

/// What one measurement costs. The budget in the brief is 150 ms for one 5 s sweep at 48 kHz,
/// in release; a debug build runs several times slower, so there the number is printed and not
/// asserted on.
final class MeasurementCostTests: XCTestCase {

    func testOneFiveSecondSweepUnder150Milliseconds() throws {
        let sampleRate = 48_000.0
        var chain = SimulatedChain(sampleRate: sampleRate, headphone: .headphone(sampleRate: sampleRate))
        chain.snrDB = 45
        let sweep = SweepSignal.exponentialSweep(sampleRate: sampleRate, seconds: 5, levelDBFS: -6)
        let recording = chain.record(sweep)          // built outside the timed section
        let silence = chain.silence(sweep)
        XCTAssertEqual(recording.count, 249_733)

        var best = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            let start = Date()
            let session = HeadphoneMeasurement(sweep: sweep)
            session.setNoiseSegment(silence)
            session.addRun(recording)
            let measured = session.result(name: "cost")
            let elapsed = Date().timeIntervalSince(start) * 1000
            XCTAssertNotNil(measured)
            best = min(best, elapsed)
        }
        print(String(format: "  one 5 s sweep at 48 kHz: %.1f ms (deconvolution, alignment, window, 200-point response, noise floor, distortion)", best))

        #if DEBUG
        print("  debug build — not asserting on the budget; run with `swift test -c release`")
        #else
        expect(best, atMost: 150, "analysis of one 5 s sweep, milliseconds")
        #endif
    }

    /// Adding a run must not redo the work that only depends on the sweep.
    func testFurtherRunsAreCheaperThanTheFirst() {
        let sampleRate = 48_000.0
        var chain = SimulatedChain(sampleRate: sampleRate, headphone: .headphone(sampleRate: sampleRate))
        chain.snrDB = 45
        let sweep = SweepSignal.exponentialSweep(sampleRate: sampleRate, seconds: 5)
        let recording = chain.record(sweep)

        let session = HeadphoneMeasurement(sweep: sweep)
        let firstStart = Date()
        session.addRun(recording)
        let first = Date().timeIntervalSince(firstStart) * 1000
        let secondStart = Date()
        session.addRun(recording)
        let second = Date().timeIntervalSince(secondStart) * 1000
        print(String(format: "  first run %.1f ms, second run %.1f ms", first, second))
        XCTAssertLessThan(second, first)
    }
}
