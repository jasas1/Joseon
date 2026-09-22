import XCTest
@testable import JoseonCore

/// Band indices of `BandEnergy.edgesHz` = [20, 60, 250, 500, 2k, 4k, 6k, 12k, 24k].
private enum Band {
    static let subBass = 0
    static let bass = 1
    static let lowMid = 2
    static let mid = 3
    static let upperMid = 4
    static let presence = 5
    static let brilliance = 6
    static let air = 7
}

final class StereoAnalyzerTests: XCTestCase {
    // MARK: Helpers

    /// Feeds a whole signal in blocks, the way the analysis engine does.
    private func feed(_ analyzer: StereoAnalyzer, left: [Float], right: [Float], sampleRate: Double, block: Int = 800) {
        XCTAssertEqual(left.count, right.count, "test signal channels must match")
        left.withUnsafeBufferPointer { lb in
            right.withUnsafeBufferPointer { rb in
                guard let lp = lb.baseAddress, let rp = rb.baseAddress else { return }
                var i = 0
                while i < left.count {
                    let n = min(block, left.count - i)
                    analyzer.process(left: lp + i, right: rp + i, count: n, sampleRate: sampleRate)
                    i += n
                }
            }
        }
    }

    private func mix(_ parts: [Float]...) -> [Float] {
        guard var out = parts.first else { return [] }
        for p in parts.dropFirst() {
            for i in 0..<min(out.count, p.count) { out[i] += p[i] }
        }
        return out
    }

    private func assertNoNaN(_ reading: StereoReading, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(reading.correlation.isNaN, "correlation NaN", file: file, line: line)
        XCTAssertFalse(reading.balance.isNaN, "balance NaN", file: file, line: line)
        XCTAssertFalse(reading.width.isNaN, "width NaN", file: file, line: line)
        for v in reading.bandCorrelation { XCTAssertFalse(v.isNaN, "bandCorrelation NaN", file: file, line: line) }
        for v in reading.bandBalance { XCTAssertFalse(v.isNaN, "bandBalance NaN", file: file, line: line) }
        for p in reading.scopePoints {
            XCTAssertFalse(p.x.isNaN || p.y.isNaN, "scope point NaN", file: file, line: line)
        }
    }

    // MARK: Broadband numbers

    func testMonoSineIsFullyCorrelatedNarrowAndCentred() {
        let a = StereoAnalyzer()
        let s = TestSignals.sine(hz: 1_000, amplitude: 0.5, sampleRate: 48_000, seconds: 2)
        feed(a, left: s, right: s, sampleRate: 48_000)
        let r = a.read()
        XCTAssertGreaterThan(r.correlation, 0.99)
        XCTAssertLessThan(r.width, 0.01)
        XCTAssertEqual(r.balance, 0, accuracy: 0.01)
        assertNoNaN(r)
    }

    func testInvertedChannelIsAntiCorrelated() {
        let a = StereoAnalyzer()
        let s = TestSignals.sine(hz: 1_000, amplitude: 0.5, sampleRate: 48_000, seconds: 2)
        feed(a, left: s, right: s.map { -$0 }, sampleRate: 48_000)
        let r = a.read()
        XCTAssertLessThan(r.correlation, -0.99)
        // No mid energy at all: width pins at the clamp.
        XCTAssertEqual(r.width, StereoAnalyzer.maxWidth, accuracy: 1e-5)
        assertNoNaN(r)
    }

    func testIndependentNoiseIsUncorrelated() {
        let a = StereoAnalyzer()
        let n = 96_000
        let l = TestSignals.whiteNoise(amplitude: 0.5, count: n, seed: 1)
        let r = TestSignals.whiteNoise(amplitude: 0.5, count: n, seed: 99)
        feed(a, left: l, right: r, sampleRate: 48_000)
        let reading = a.read()
        XCTAssertLessThan(abs(reading.correlation), 0.1)
        assertNoNaN(reading)
    }

    func testLeftOnlyIsHardLeft() {
        let a = StereoAnalyzer()
        let s = TestSignals.sine(hz: 700, amplitude: 0.5, sampleRate: 48_000, seconds: 2)
        feed(a, left: s, right: [Float](repeating: 0, count: s.count), sampleRate: 48_000)
        let r = a.read()
        XCTAssertLessThan(r.balance, -0.95)
        // A hard-panned channel splits evenly into mid and side, so width reads 1.
        XCTAssertEqual(r.width, 1, accuracy: 0.02)
        assertNoNaN(r)
    }

    // MARK: Per-band numbers

    func testBandCorrelationSplitsMonoBassFromInvertedPresence() {
        let a = StereoAnalyzer()
        let low = TestSignals.sine(hz: 100, amplitude: 0.4, sampleRate: 48_000, seconds: 2)
        let high = TestSignals.sine(hz: 5_000, amplitude: 0.4, sampleRate: 48_000, seconds: 2)
        let l = mix(low, high)
        let r = mix(low, high.map { -$0 })
        feed(a, left: l, right: r, sampleRate: 48_000)
        let reading = a.read()
        XCTAssertGreaterThan(reading.bandCorrelation[Band.bass], 0.99)
        XCTAssertLessThan(reading.bandCorrelation[Band.presence], -0.99)
        assertNoNaN(reading)
    }

    func testBandBalancePutsRightOnlyToneInItsBandAndLeavesEmptyBandsAtZero() {
        let a = StereoAnalyzer()
        // 4 seconds: the band-split start-up transient has to leave the 300 ms window
        // before the far bands settle under the empty-band gate.
        let s = TestSignals.sine(hz: 1_000, amplitude: 0.5, sampleRate: 48_000, seconds: 4)
        feed(a, left: [Float](repeating: 0, count: s.count), right: s, sampleRate: 48_000)
        let r = a.read()
        XCTAssertGreaterThan(r.bandBalance[Band.mid], 0.9)
        // Bands far from 1 kHz hold no energy above the gate and stay neutral.
        XCTAssertEqual(r.bandBalance[Band.subBass], 0, accuracy: 1e-6)
        XCTAssertEqual(r.bandBalance[Band.brilliance], 0, accuracy: 1e-6)
        XCTAssertEqual(r.bandBalance[Band.air], 0, accuracy: 1e-6)
        XCTAssertEqual(r.bandCorrelation[Band.subBass], 0, accuracy: 1e-6)
        XCTAssertEqual(r.bandCorrelation[Band.air], 0, accuracy: 1e-6)
        assertNoNaN(r)
    }

    // MARK: Vectorscope

    func testScopePointCountIsCappedByTheRequestAndByFiftyMilliseconds() {
        let a = StereoAnalyzer()
        let s = TestSignals.sine(hz: 440, amplitude: 0.3, sampleRate: 48_000, seconds: 0.5)
        feed(a, left: s, right: s, sampleRate: 48_000)
        // 50 ms at 48 kHz = 2400 frames, more than the 2048 default: the request caps it.
        XCTAssertEqual(a.read().scopePoints.count, 2048)
        // Asking for more than the window holds gives the whole 50 ms and no more.
        a.scopePointCount = 8_192
        XCTAssertEqual(a.read().scopePoints.count, 2_400)
        a.scopePointCount = 256
        XCTAssertEqual(a.read().scopePoints.count, 256)
    }

    func testScopeIsNewestLastAndFullScaleMonoReachesTheDiamondTip() {
        let a = StereoAnalyzer()
        a.scopePointCount = 2_048
        let zeros = [Float](repeating: 0, count: 9_600)   // 200 ms, fills the 50 ms ring
        feed(a, left: zeros, right: zeros, sampleRate: 48_000)
        // One loud in-phase frame last.
        var one: Float = 1
        withUnsafePointer(to: &one) { p in
            a.process(left: p, right: p, count: 1, sampleRate: 48_000)
        }
        let points = a.read().scopePoints
        XCTAssertEqual(points.count, 2_048)
        let last = points[points.count - 1]
        // L = R = 1 is the top tip of the full-scale diamond: y = 1 by the mapping, not by
        // the clamp (at the old 0.7071 scale it was 1.414 and the clamp flattened it).
        XCTAssertEqual(last.y, 1, accuracy: 1e-6)
        XCTAssertEqual(last.x, 0, accuracy: 1e-6)
        XCTAssertEqual(points[points.count - 2].y, 0, accuracy: 1e-6)
        XCTAssertEqual(points[0].y, 0, accuracy: 1e-6)
    }

    func testScopeGeometryMonoLeftOnlyAndInverted() {
        let s = TestSignals.sine(hz: 200, amplitude: 0.5, sampleRate: 48_000, seconds: 0.3)
        let zeros = [Float](repeating: 0, count: s.count)

        let mono = StereoAnalyzer()
        feed(mono, left: s, right: s, sampleRate: 48_000)
        let monoPoints = mono.read().scopePoints
        XCTAssertFalse(monoPoints.isEmpty)
        for p in monoPoints { XCTAssertEqual(p.x, 0, accuracy: 1e-6) }   // vertical line
        // Mono at 0.5: y = (L + R)·0.5 = L, so the line reaches 0.5, half way to the tip.
        XCTAssertEqual(monoPoints.map { abs($0.y) }.max() ?? 0, 0.5, accuracy: 0.01)

        let leftOnly = StereoAnalyzer()
        feed(leftOnly, left: s, right: zeros, sampleRate: 48_000)
        let leftPoints = leftOnly.read().scopePoints
        // x = -0.5·L, y = +0.5·L: the cloud lies on the up-left / down-right diagonal.
        for p in leftPoints {
            XCTAssertLessThanOrEqual(p.x * p.y, 1e-9)
            XCTAssertEqual(p.x + p.y, 0, accuracy: 1e-6)
        }
        XCTAssertTrue(leftPoints.contains { $0.y > 0.2 && $0.x < -0.2 }, "no up-left points")

        let inverted = StereoAnalyzer()
        feed(inverted, left: s, right: s.map { -$0 }, sampleRate: 48_000)
        let invertedPoints = inverted.read().scopePoints
        for p in invertedPoints { XCTAssertEqual(p.y, 0, accuracy: 1e-6) }  // horizontal line
        // Anti-phase at 0.5: x = (R - L)·0.5 = -L, so the line reaches 0.5 either side.
        XCTAssertEqual(invertedPoints.map { abs($0.x) }.max() ?? 0, 0.5, accuracy: 0.01)
    }

    /// Defect 11 (critic r4): a hot signal drew a flat horizontal top and bottom inside the
    /// diamond. At the old 0.7071 scale a hard-clipped mono sample (L = R = ±1) mapped to
    /// y = ±1.414 and the -1...1 clamp cut it back to a straight edge. At 0.5 the full-scale
    /// diamond is exactly the unit square's inscribed diamond, so clipping follows its 45°
    /// edges and the clamp only ever sees out-of-range input.
    func testHardClippedSignalFollowsTheDiamondEdges() {
        let n = 4_800                                    // 50 ms at 96 kHz: exactly the ring
        let left = [Float](repeating: 1, count: n)       // pinned at full scale
        let right = (0..<n).map { Float($0) / Float(n - 1) * 2 - 1 }   // sweeps -1 ... 1
        let a = StereoAnalyzer()
        a.scopePointCount = 4_800
        feed(a, left: left, right: right, sampleRate: 96_000)
        let points = a.read().scopePoints
        XCTAssertEqual(points.count, n)

        // Every point sits on an edge of the full-scale diamond: |x| + |y| = max(|L|, |R|) = 1.
        for p in points {
            XCTAssertEqual(abs(p.x) + abs(p.y), 1, accuracy: 1e-6)
            XCTAssertLessThanOrEqual(abs(p.x), 1)
            XCTAssertLessThanOrEqual(abs(p.y), 1)
        }
        // The sweep is even, so the edge is drawn evenly: only the R = 1 end reaches the tip.
        // The old mapping clamped every R above 0.414 to y = 1 - about a third of the points.
        let atTheTop = points.filter { $0.y >= 0.999 }.count
        XCTAssertLessThan(Double(atTheTop) / Double(points.count), 0.02, "flat top: \(atTheTop) of \(points.count) points")
        XCTAssertEqual(points.map(\.y).max() ?? 0, 1, accuracy: 1e-6)
        XCTAssertEqual(points.map(\.y).min() ?? 0, 0, accuracy: 1e-6)
        XCTAssertEqual(points.map(\.x).min() ?? 0, -1, accuracy: 1e-6)
    }

    /// The contract's -1...1 box holds for every in-range sample without the clamp doing work.
    func testScopePointsStayInTheUnitDiamondForFullScaleInput() {
        let n = 2_400
        let left = TestSignals.whiteNoise(amplitude: 1, count: n, seed: 7)
        let right = TestSignals.whiteNoise(amplitude: 1, count: n, seed: 8)
        let a = StereoAnalyzer()
        a.scopePointCount = 2_400
        feed(a, left: left, right: right, sampleRate: 48_000)
        let points = a.read().scopePoints
        XCTAssertEqual(points.count, n)
        for (i, p) in points.enumerated() {
            XCTAssertLessThanOrEqual(abs(p.x) + abs(p.y), 1 + 1e-6, "point \(i) left the diamond")
            XCTAssertEqual(Double(abs(p.x) + abs(p.y)),
                           Double(max(abs(left[i]), abs(right[i]))), accuracy: 1e-6,
                           "|x| + |y| must be max(|L|, |R|)")
        }
    }

    // MARK: Silence, reset, sample rate

    func testSilenceGivesZerosAndNoNaN() {
        let a = StereoAnalyzer()
        let zeros = [Float](repeating: 0, count: 48_000)
        feed(a, left: zeros, right: zeros, sampleRate: 48_000)
        let r = a.read()
        XCTAssertEqual(r.correlation, 0)
        XCTAssertEqual(r.balance, 0)
        XCTAssertEqual(r.width, 0)
        XCTAssertEqual(r.bandCorrelation, [Float](repeating: 0, count: 8))
        XCTAssertEqual(r.bandBalance, [Float](repeating: 0, count: 8))
        XCTAssertEqual(r.scopePoints.count, 2_048)
        for p in r.scopePoints {
            XCTAssertEqual(p.x, 0)
            XCTAssertEqual(p.y, 0)
        }
        assertNoNaN(r)
    }

    func testResetClearsEverything() {
        let a = StereoAnalyzer()
        let s = TestSignals.sine(hz: 1_000, amplitude: 0.5, sampleRate: 48_000, seconds: 1)
        feed(a, left: s, right: [Float](repeating: 0, count: s.count), sampleRate: 48_000)
        XCTAssertLessThan(a.read().balance, -0.9)
        a.reset()
        let r = a.read()
        XCTAssertEqual(r.correlation, 0)
        XCTAssertEqual(r.balance, 0)
        XCTAssertEqual(r.width, 0)
        XCTAssertTrue(r.scopePoints.isEmpty)
        assertNoNaN(r)
    }

    func testSampleRateChangeReconfiguresCleanly() {
        let a = StereoAnalyzer()
        a.scopePointCount = 8_192
        let mono = TestSignals.sine(hz: 1_000, amplitude: 0.5, sampleRate: 48_000, seconds: 1)
        feed(a, left: mono, right: mono, sampleRate: 48_000)
        XCTAssertGreaterThan(a.read().correlation, 0.99)
        XCTAssertEqual(a.read().scopePoints.count, 2_400)   // 50 ms at 48 kHz

        let hi = TestSignals.sine(hz: 1_000, amplitude: 0.5, sampleRate: 96_000, seconds: 2)
        feed(a, left: hi, right: hi.map { -$0 }, sampleRate: 96_000)
        let r = a.read()
        XCTAssertLessThan(r.correlation, -0.99)
        XCTAssertEqual(r.scopePoints.count, 4_800)          // 50 ms at 96 kHz
        assertNoNaN(r)
    }

    func testSameResultsAt44100And96000() {
        func measureAt(_ rate: Double) -> StereoReading {
            let a = StereoAnalyzer()
            let lowL = TestSignals.sine(hz: 200, amplitude: 0.4, sampleRate: rate, seconds: 2)
            let highL = TestSignals.sine(hz: 3_000, amplitude: 0.3, sampleRate: rate, seconds: 2)
            let highR = TestSignals.sine(hz: 3_000, amplitude: 0.3, sampleRate: rate, seconds: 2, phase: .pi / 3)
            feed(a, left: mix(lowL, highL), right: mix(lowL, highR), sampleRate: rate)
            return a.read()
        }
        let a = measureAt(44_100)
        let b = measureAt(96_000)
        XCTAssertEqual(a.correlation, b.correlation, accuracy: 0.02)
        XCTAssertEqual(a.balance, b.balance, accuracy: 0.02)
        XCTAssertEqual(a.width, b.width, accuracy: 0.02)
        XCTAssertEqual(a.bandCorrelation[Band.bass], b.bandCorrelation[Band.bass], accuracy: 0.02)
        XCTAssertEqual(a.bandCorrelation[Band.upperMid], b.bandCorrelation[Band.upperMid], accuracy: 0.02)
        XCTAssertEqual(a.bandBalance[Band.bass], b.bandBalance[Band.bass], accuracy: 0.02)
        XCTAssertEqual(a.bandBalance[Band.upperMid], b.bandBalance[Band.upperMid], accuracy: 0.02)
        assertNoNaN(a)
        assertNoNaN(b)
    }

    /// The engine hands over up to 32768 frames at once. One big block must give the same
    /// answer as many small ones and must not overrun the 50 ms scope ring.
    func testOneLargeBlockMatchesManySmallBlocks() {
        let base = TestSignals.pinkNoise(amplitude: 0.5, count: 48_000, seed: 3)
        let other = TestSignals.pinkNoise(amplitude: 0.5, count: 48_000, seed: 5)
        let l = base
        let r = (0..<base.count).map { 0.7 * base[$0] + 0.3 * other[$0] }

        let small = StereoAnalyzer()
        feed(small, left: l, right: r, sampleRate: 48_000, block: 512)
        let big = StereoAnalyzer()
        feed(big, left: l, right: r, sampleRate: 48_000, block: 32_768)

        let a = small.read(), b = big.read()
        XCTAssertEqual(a.correlation, b.correlation, accuracy: 0.02)
        XCTAssertEqual(a.balance, b.balance, accuracy: 0.02)
        XCTAssertEqual(a.width, b.width, accuracy: 0.02)
        for i in 0..<8 {
            XCTAssertEqual(a.bandCorrelation[i], b.bandCorrelation[i], accuracy: 0.02, "band \(i) correlation")
            XCTAssertEqual(a.bandBalance[i], b.bandBalance[i], accuracy: 0.02, "band \(i) balance")
        }
        XCTAssertEqual(b.scopePoints.count, 2_048)
        assertNoNaN(b)
    }

    // MARK: Performance

    /// Budget: `process` of 800 stereo frames averages under 0.5 ms.
    /// The hard assertion runs only in an optimized build; a debug build carries the
    /// XCTest and Swift bounds-check overhead and is not the shipping path.
    func testProcessPerformance() {
        let a = StereoAnalyzer()
        let frames = 800
        let l = TestSignals.pinkNoise(amplitude: 0.5, count: frames, seed: 7)
        let r = TestSignals.pinkNoise(amplitude: 0.5, count: frames, seed: 11)
        let iterations = 200

        l.withUnsafeBufferPointer { lb in
            r.withUnsafeBufferPointer { rb in
                guard let lp = lb.baseAddress, let rp = rb.baseAddress else { return }
                for _ in 0..<100 { a.process(left: lp, right: rp, count: frames, sampleRate: 48_000) }

                measure {
                    for _ in 0..<iterations { a.process(left: lp, right: rp, count: frames, sampleRate: 48_000) }
                }

                let start = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<iterations { a.process(left: lp, right: rp, count: frames, sampleRate: 48_000) }
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                let perCallMS = Double(elapsed) / Double(iterations) / 1_000_000
                print("StereoAnalyzer.process(800 frames): \(String(format: "%.4f", perCallMS)) ms average")
                #if !DEBUG
                XCTAssertLessThan(perCallMS, 0.5, "process of 800 frames must average under 0.5 ms")
                #endif
            }
        }
    }
}
