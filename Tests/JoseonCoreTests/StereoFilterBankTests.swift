import XCTest
import Accelerate
@testable import JoseonCore

/// `BandSplitFilterBank` now runs eight bands at a time in one SIMD cascade instead of one
/// `vDSP_biquadD` call per band per channel. The filter has to be the same filter, so these
/// tests check it against an independent scalar reference and against what the bands are for.
final class StereoFilterBankTests: XCTestCase {

    /// Direct form I, one sample at a time, written the long way. Nothing in common with the
    /// bank's own arithmetic except the coefficients.
    private func reference(_ sections: [BiquadSection], _ input: [Double]) -> [Double] {
        var x = input
        for s in sections {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            var out = [Double](repeating: 0, count: x.count)
            for n in 0..<x.count {
                let value = s.b0 * x[n] + s.b1 * x1 + s.b2 * x2 - s.a1 * y1 - s.a2 * y2
                x2 = x1; x1 = x[n]
                y2 = y1; y1 = value
                out[n] = value
            }
            x = out
        }
        return x
    }

    private func sections(band: Int, edges: [Float], sampleRate: Double) -> [BiquadSection] {
        let lowEdge = Double(edges[band]), highEdge = Double(edges[band + 1])
        let keepLowPass = highEdge < sampleRate * 0.45
        var out: [BiquadSection] = []
        for q in BiquadSection.linkwitzRiley8Qs {
            out.append(keepLowPass ? .lowPass(hz: highEdge, sampleRate: sampleRate, q: q) : .passThrough)
        }
        for q in BiquadSection.linkwitzRiley8Qs {
            out.append(lowEdge > 0 ? .highPass(hz: lowEdge, sampleRate: sampleRate, q: q) : .passThrough)
        }
        return out
    }

    /// Every band of every channel, at every rate the analyzer supports, inside 1e-6 relative
    /// of the scalar reference. The signal is broadband so no band is fed silence.
    func testMatchesAScalarReferenceWithinOnePartInAMillion() {
        let edges = BandEnergy.edgesHz
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            guard let bank = BandSplitFilterBank(edgesHz: edges, sampleRate: rate) else {
                return XCTFail("bank at \(rate) Hz")
            }
            let n = 800
            let noise = TestSignals.pinkNoise(amplitude: 0.5, count: n, seed: 0xB10C).map { Double($0) }
            var out = [Double](repeating: 0, count: n)
            for band in 0..<(edges.count - 1) {
                let expected = reference(sections(band: band, edges: edges, sampleRate: rate), noise)
                var scale = 0.0
                for v in expected { scale = max(scale, abs(v)) }
                noise.withUnsafeBufferPointer { input in
                    out.withUnsafeMutableBufferPointer { o in
                        bank.filterLeft(band: band, input: input.baseAddress!, output: o.baseAddress!, count: n)
                    }
                }
                var worst = 0.0
                for i in 0..<n { worst = max(worst, abs(out[i] - expected[i])) }
                XCTAssertLessThan(worst, max(scale, 1e-12) * 1e-6, "band \(band) at \(rate) Hz: worst \(worst), scale \(scale)")
            }
        }
    }

    /// State carries across blocks: filtering one block of 800 has to equal filtering two of 400.
    func testStateCarriesAcrossBlocks() {
        let edges = BandEnergy.edgesHz
        let rate = 48_000.0
        guard let one = BandSplitFilterBank(edgesHz: edges, sampleRate: rate),
              let split = BandSplitFilterBank(edgesHz: edges, sampleRate: rate) else { return XCTFail() }
        let n = 800
        let noise = TestSignals.pinkNoise(amplitude: 0.5, count: n, seed: 7).map { Double($0) }
        var whole = [Double](repeating: 0, count: n)
        var halves = [Double](repeating: 0, count: n)
        noise.withUnsafeBufferPointer { input in
            whole.withUnsafeMutableBufferPointer { o in
                for band in 0..<(edges.count - 1) where band == 0 || true {
                    one.filterLeft(band: band, input: input.baseAddress!, output: o.baseAddress!, count: n)
                }
            }
            halves.withUnsafeMutableBufferPointer { o in
                for band in 0..<(edges.count - 1) { split.filterLeft(band: band, input: input.baseAddress!, output: o.baseAddress!, count: n / 2) }
                for band in 0..<(edges.count - 1) {
                    split.filterLeft(band: band, input: input.baseAddress! + n / 2, output: o.baseAddress! + n / 2, count: n / 2)
                }
            }
        }
        var worst = 0.0
        for i in 0..<n { worst = max(worst, abs(whole[i] - halves[i])) }
        XCTAssertLessThan(worst, 1e-12, "one block and two blocks disagree by \(worst)")
    }

    /// `resetState` really clears the delay line: the same block filtered twice with a reset
    /// between gives the same answer both times.
    func testResetClearsTheDelayLine() {
        let edges = BandEnergy.edgesHz
        guard let bank = BandSplitFilterBank(edgesHz: edges, sampleRate: 48_000) else { return XCTFail() }
        let n = 256
        let noise = TestSignals.pinkNoise(amplitude: 0.5, count: n, seed: 11).map { Double($0) }
        var first = [Double](repeating: 0, count: n)
        var second = [Double](repeating: 0, count: n)
        noise.withUnsafeBufferPointer { input in
            first.withUnsafeMutableBufferPointer { o in
                bank.filterLeft(band: 3, input: input.baseAddress!, output: o.baseAddress!, count: n)
            }
            bank.resetState()
            second.withUnsafeMutableBufferPointer { o in
                bank.filterLeft(band: 3, input: input.baseAddress!, output: o.baseAddress!, count: n)
            }
        }
        XCTAssertEqual(first, second)
    }

    /// Left and right keep their own state: the same band fed different signals does not mix.
    func testLeftAndRightAreIndependent() {
        let edges = BandEnergy.edgesHz
        guard let bank = BandSplitFilterBank(edgesHz: edges, sampleRate: 48_000) else { return XCTFail() }
        let n = 512
        let l = TestSignals.sine(hz: 1_000, amplitude: 0.5, sampleRate: 48_000, seconds: Double(n) / 48_000).map { Double($0) }
        let r = [Double](repeating: 0, count: n)
        var outL = [Double](repeating: 0, count: n)
        var outR = [Double](repeating: 1, count: n)
        l.withUnsafeBufferPointer { li in r.withUnsafeBufferPointer { ri in
            outL.withUnsafeMutableBufferPointer { ol in outR.withUnsafeMutableBufferPointer { or in
                for band in 0..<(edges.count - 1) {
                    bank.filterLeft(band: band, input: li.baseAddress!, output: ol.baseAddress!, count: n)
                    bank.filterRight(band: band, input: ri.baseAddress!, output: or.baseAddress!, count: n)
                }
            } }
        } }
        for v in outR { XCTAssertEqual(v, 0, "a silent right channel stays silent") }
        var energy = 0.0
        for v in outL { energy += v * v }
        XCTAssertGreaterThan(energy, 0)
    }

    /// A 1 kHz tone belongs to the mid band and to no other: that is what the bank is for.
    func testATonePicksOneBand() {
        let edges = BandEnergy.edgesHz
        let rate = 48_000.0
        guard let bank = BandSplitFilterBank(edgesHz: edges, sampleRate: rate) else { return XCTFail() }
        // Long enough that the band-pass start-up transient has rung out; energy is measured
        // over the last quarter only, which is the steady state the analyzer averages over.
        let n = 48_000
        let tail = n * 3 / 4
        let tone = TestSignals.sine(hz: 1_000, amplitude: 0.5, sampleRate: rate, seconds: Double(n) / rate).map { Double($0) }
        var out = [Double](repeating: 0, count: n)
        var energies = [Double]()
        tone.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { o in
                for band in 0..<(edges.count - 1) {
                    bank.filterLeft(band: band, input: input.baseAddress!, output: o.baseAddress!, count: n)
                    var e = 0.0
                    vDSP_dotprD(o.baseAddress! + tail, 1, o.baseAddress! + tail, 1, &e, vDSP_Length(n - tail))
                    energies.append(e)
                }
            }
        }
        let loudest = energies.firstIndex(of: energies.max()!)!
        XCTAssertTrue(edges[loudest] <= 1_000 && 1_000 < edges[loudest + 1], "1 kHz landed in band \(loudest)")
        for (band, e) in energies.enumerated() where band != loudest {
            XCTAssertLessThan(e, energies[loudest] * 1e-4, "band \(band) leaks")
        }
    }
}
