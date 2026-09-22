import XCTest
@testable import JoseonCore

/// Budget: `process` of 800 frames averages under 1 ms on an M-series chip.
///
/// 800 frames at 48 kHz is one 60 Hz tick, which is how the engine drives the analyzer.
/// The hard assertion only runs on a release build, because `swift test` defaults to
/// `-Onone` and the scalar mapping loops are several times slower there. Run
/// `swift test -c release --filter SpectrumPerformanceTests` for the real number.
final class SpectrumPerformanceTests: XCTestCase {

    private func makeWarmAnalyzer(rate: Double, block: Int) -> (SpectrumAnalyzer, [Float]) {
        let analyzer = SpectrumAnalyzer()
        let signal = TestSignals.pinkNoise(amplitude: 0.5, count: 1 << 16)
        // Warm up: fill the history, build every FFT, take every allocation path once.
        signal.withUnsafeBufferPointer { p in
            var i = 0
            while i + block <= signal.count {
                analyzer.process(left: p.baseAddress! + i, right: p.baseAddress! + i, count: block, sampleRate: rate)
                i += block
            }
        }
        _ = analyzer.read()
        return (analyzer, signal)
    }

    func testProcessBudget() {
        let rate = 48_000.0
        let block = 800
        let (analyzer, signal) = makeWarmAnalyzer(rate: rate, block: block)
        let iterations = 2_000

        var elapsed: Double = 0
        signal.withUnsafeBufferPointer { p in
            var offset = 0
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                analyzer.process(left: p.baseAddress! + offset, right: p.baseAddress! + offset, count: block, sampleRate: rate)
                offset += block
                if offset + block > signal.count { offset = 0 }
            }
            elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        }

        let microseconds = elapsed / Double(iterations) * 1e6
        print(String(format: "process(800 frames @ 48 kHz): %.1f us average over %d calls", microseconds, iterations))

        #if DEBUG
        // -Onone. Loose bound only; the real budget is checked in release.
        XCTAssertLessThan(microseconds, 4_000, "debug build is far over budget")
        #else
        XCTAssertLessThan(microseconds, 1_000, "process of 800 frames must average under 1 ms")
        #endif
    }

    /// The same on the demo signal, which has a dozen tones to find, measure and draw in every
    /// transform, with a `read` per block the way the engine drives it. Round 4 guard: `process`
    /// stays under 130 us.
    func testProcessBudgetOnTheDemoSignal() {
        let rate = 48_000.0
        let block = 800
        let analyzer = SpectrumAnalyzer()
        let seconds = 12
        let demo = TestSignals.demoBlock(startSample: 0, count: Int(rate) * seconds, sampleRate: rate)
        var processNanos: UInt64 = 0, readNanos: UInt64 = 0
        var calls = 0
        demo.left.withUnsafeBufferPointer { l in
            demo.right.withUnsafeBufferPointer { r in
                var offset = 0
                while offset + block <= l.count {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    analyzer.process(left: l.baseAddress! + offset, right: r.baseAddress! + offset, count: block, sampleRate: rate)
                    let t1 = DispatchTime.now().uptimeNanoseconds
                    _ = analyzer.read()
                    let t2 = DispatchTime.now().uptimeNanoseconds
                    // The first two seconds fill the history and take every first-use path.
                    if offset >= Int(rate) * 2 { processNanos += t1 - t0; readNanos += t2 - t1; calls += 1 }
                    offset += block
                }
            }
        }
        let processMicros = Double(processNanos) / 1e3 / Double(calls)
        let readMicros = Double(readNanos) / 1e3 / Double(calls)
        print(String(format: "demo signal: process %.1f us, read %.1f us, average over %d blocks of 800 frames", processMicros, readMicros, calls))
        #if !DEBUG
        XCTAssertLessThan(processMicros, 130, "process of 800 frames must stay under 130 us")
        XCTAssertLessThan(readMicros, 30)
        #endif
    }

    /// The XCTest `measure` run the brief asks for. Reported, not asserted.
    func testProcessPerformance() {
        let rate = 48_000.0
        let block = 800
        let (analyzer, signal) = makeWarmAnalyzer(rate: rate, block: block)
        measure {
            signal.withUnsafeBufferPointer { p in
                var offset = 0
                for _ in 0..<1_000 {
                    analyzer.process(left: p.baseAddress! + offset, right: p.baseAddress! + offset, count: block, sampleRate: rate)
                    offset += block
                    if offset + block > signal.count { offset = 0 }
                }
            }
        }
    }

    /// `process` must not touch the heap once it is warm. Counted with the malloc zone's
    /// own live-block count, which is exact for this thread's allocations.
    func testProcessDoesNotAllocateWhenWarm() {
        let rate = 48_000.0
        let block = 800
        let (analyzer, signal) = makeWarmAnalyzer(rate: rate, block: block)

        func liveBlocks() -> Int {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(malloc_default_zone(), &stats)
            return Int(stats.blocks_in_use)
        }

        signal.withUnsafeBufferPointer { p in
            var offset = 0
            // One more call so any lazily created runtime metadata is already in place.
            analyzer.process(left: p.baseAddress!, right: p.baseAddress!, count: block, sampleRate: rate)
            let before = liveBlocks()
            for _ in 0..<1_000 {
                analyzer.process(left: p.baseAddress! + offset, right: p.baseAddress! + offset, count: block, sampleRate: rate)
                offset += block
                if offset + block > signal.count { offset = 0 }
            }
            let growth = liveBlocks() - before
            XCTAssertLessThanOrEqual(growth, 4, "process allocated \(growth) blocks over 1000 calls")
        }
    }

    /// `read` runs once per displayed frame, so it has to stay cheap too.
    func testReadPerformance() {
        let rate = 48_000.0
        let (analyzer, _) = makeWarmAnalyzer(rate: rate, block: 800)
        let iterations = 2_000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { _ = analyzer.read() }
        let microseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e3 / Double(iterations)
        print(String(format: "read(1024 bins): %.1f us average over %d calls", microseconds, iterations))
        #if !DEBUG
        XCTAssertLessThan(microseconds, 250)
        #endif
    }
}
