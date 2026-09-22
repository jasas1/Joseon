import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// A display must agree with its own numbers. These tests use frames from the real analyzers.
final class TrustTests: XCTestCase {
    /// Critic r1 item 3 and r2 item 1: "a 6 kHz tone in R is missing from Mid". In round 2 the demo signal put its
    /// 6.2 kHz shimmer into the SIDE channel (+ in L, - in R), so Mid really did cancel it - a correct number that
    /// two reviewers in a row read as a bug. The signal is honest now: the shimmer is in the RIGHT channel only, so
    /// it appears in R, in Mid and in Side, with Mid and Side 6 dB under R. The cursor label still names Side.
    func testTheSixKilohertzToneIsRightOnlyAndTheCursorSaysSo() throws {
        let f = try XCTUnwrap(RealFrames.demo(seconds: 8).last)
        let s = f.spectrum
        let i = try XCTUnwrap(s.frequencies.indices.min(by: { abs(s.frequencies[$0] - 6200) < abs(s.frequencies[$1] - 6200) }))
        var l: Float = -200, r: Float = -200, m: Float = -200, sd: Float = -200
        for k in max(i - 3, 0)...min(i + 3, s.frequencies.count - 1) {
            l = max(l, s.left[k]); r = max(r, s.right[k]); m = max(m, s.mid[k]); sd = max(sd, s.side[k])
        }
        print(String(format: "TRUST 6.2 kHz: L %.1f dB  R %.1f dB  Mid %.1f dB  Side %.1f dB", l, r, m, sd))
        XCTAssertGreaterThan(r, l + 10, "the tone is in the right channel only")
        XCTAssertEqual(m, sd, accuracy: 1.5, "one-sided content splits evenly between mid and side")
        XCTAssertEqual(m, r - 6, accuracy: 1.5, "mid is half the amplitude of a one-sided tone")

        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let renderer = try XCTUnwrap(PanelRenderer.make(kind: .spectrum, ctx: ctx, theme: Theme()) as? SpectrumRenderer)
        renderer.setLayout(size: CGSize(width: 1200, height: 600), scale: 2)
        renderer.ingest(f)
        // Cursor on 6.2 kHz: plot is 44 ... 1186 pt wide on a 20 Hz - 20 kHz log axis.
        let x = 44 + CGFloat(log(Float(6200) / 20) / log(Float(1000))) * (1200 - 44 - 14)
        renderer.hover = CGPoint(x: x, y: 300)
        let label = try XCTUnwrap(renderer.hoverLabel())
        XCTAssertTrue(label.lines[0].hasPrefix("cursor"), "\(label.lines)")
        XCTAssertTrue(label.lines[1].hasPrefix("cursor"))
        let third = try XCTUnwrap(label.lines.dropFirst(2).first)
        XCTAssertTrue(third.hasPrefix("Mid") && third.contains("Side"), third)
    }

    /// Critic r1 item 4: the M bar and the momentary numeral, the TP bars and the TP labels. One value each.
    func testMeterBarsEndWhereTheirNumbersSay() throws {
        try RenderTestSupport.requireMetal()
        let frames = RealFrames.demo(seconds: 6)
        let last = try XCTUnwrap(frames.last)
        let size = CGSize(width: 1200, height: 600)
        let px = try RenderTestSupport.decode(png: OffscreenRenderer.png(panel: .meters, frames: frames, size: size))
        // Geometry of the non-compact layout (see MetersRenderer.layoutChanged): bars from y = 14 + 66 to 600 - 14 - 22, -60 ... +3 dB.
        let top: CGFloat = 80, bottom: CGFloat = 564
        func y(_ db: Float) -> Int { Int(((bottom - CGFloat((db + 60) / 63) * (bottom - top)) * 2).rounded()) }
        /// First row from the top where the column turns from the dark track into the bar.
        func barTop(x: Int) -> Int {
            // Twelve bar-colored rows in a run: the thin max-hold tick over the bar does not count.
            func lit(_ row: Int) -> Bool { let c = px.rgb(x, row); return c.2 > 140 && c.1 > 90 }
            for row in Int(top * 2)..<Int(bottom * 2) - 12 where (0..<12).allSatisfy({ lit(row + $0) }) { return row }
            return -1
        }
        let l = last.loudness
        // M bar: x = 14 + 32 ... , width (150 - 32 - 16) / 3.
        let mX = Int((14 + 32 + 17) * 2)
        XCTAssertEqual(Double(barTop(x: mX)), Double(y(l.momentaryLUFS)), accuracy: 5, "M bar vs momentary \(l.momentaryLUFS)")
        let sX = mX + Int((34 + 8) * 2)
        XCTAssertEqual(Double(barTop(x: sX)), Double(y(l.shortTermLUFS)), accuracy: 5, "S bar vs short term \(l.shortTermLUFS)")
        // PSR is labeled as what the contract computes: live true peak minus short-term.
        XCTAssertEqual(l.psrDB, max(l.truePeakLeftDBTP, l.truePeakRightDBTP) - l.shortTermLUFS, accuracy: 0.05)
    }
}

final class ResampleTableTests: XCTestCase {
    /// The cached table must give the same curve as the reference resampler, in both modes.
    func testTableMatchesTheReferenceResampler() {
        let s = SyntheticFrames.sequence(count: 30)[29].spectrum
        let axis = LogAxis(minHz: 20, maxHz: 20_000)
        for count in [1222, 200] {       // interpolation, and maximum of several bins
            var a = [Float](repeating: 0, count: count), b = a
            a.withUnsafeMutableBufferPointer {
                CurveResampler.resample(s.mid, frequencies: s.frequencies, axis: axis, minDB: -84, maxDB: -12, offsetDB: 1.5, into: $0.baseAddress!, count: count)
            }
            let table = ResampleTable(frequencies: s.frequencies, axis: axis, count: count)
            XCTAssertNotNil(table)
            XCTAssertTrue(table!.matches(frequencies: s.frequencies, axis: axis, count: count))
            b.withUnsafeMutableBufferPointer { table!.apply(s.mid, minDB: -84, maxDB: -12, offsetDB: 1.5, into: $0.baseAddress!) }
            for j in 0..<count { XCTAssertEqual(a[j], b[j], accuracy: 2e-4, "point \(j) of \(count)") }
        }
    }
}
