import XCTest
import JoseonCore
@testable import JoseonRender

/// Critic r2 defect 11: the loudness history began with a spike (M and S climbing out of silence while their windows fill).
final class MetersHistoryTests: XCTestCase {
    func testNoMomentaryBefore400msAndNoShortTermBefore3s() throws {
        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let r = try XCTUnwrap(PanelRenderer.make(kind: .meters, ctx: ctx, theme: Theme()) as? MetersRenderer)
        r.setLayout(size: CGSize(width: 1200, height: 600), scale: 2)
        for f in RealFrames.demo(seconds: 8) { r.ingest(f) }
        let h = r.historyForTesting
        XCTAssertGreaterThan(h.momentary.count, 70)
        // Slot k closes at (k + 1) * 100 ms.
        for k in 0..<3 { XCTAssertEqual(h.momentary[k], MetersRenderer.noValue, "M slot \(k) closes before 400 ms") }
        for k in 0..<29 { XCTAssertEqual(h.shortTerm[k], MetersRenderer.noValue, "S slot \(k) closes before 3 s") }
        XCTAssertGreaterThan(h.momentary[5], -70)
        XCTAssertGreaterThan(h.shortTerm[31], -70)
        // No spike: the first values lie inside the range of the rest.
        let laterM = h.momentary[20...], laterS = h.shortTerm[40...]
        for k in 4..<8 {
            XCTAssertLessThanOrEqual(h.momentary[k], laterM.max()! + 1.5)
            XCTAssertGreaterThanOrEqual(h.momentary[k], laterM.min()! - 6)
        }
        XCTAssertEqual(h.shortTerm[30], laterS.reduce(0, +) / Float(laterS.count), accuracy: 3)
    }

    func testAResetEmptiesTheWindowsAgain() throws {
        try RenderTestSupport.requireMetal()
        let ctx = try XCTUnwrap(RenderContext.shared)
        let r = try XCTUnwrap(PanelRenderer.make(kind: .meters, ctx: ctx, theme: Theme()) as? MetersRenderer)
        r.setLayout(size: CGSize(width: 1200, height: 600), scale: 2)
        let frames = RealFrames.demo(seconds: 5)
        var t = 0.0
        for pass in 0..<2 {
            for f in frames { var g = f; t += 1.0 / 60; g.hostTime = t; r.ingest(g) }
            _ = pass
        }
        let h = r.historyForTesting
        // Second pass starts at slot 50: measuredSeconds fell back to 0 there.
        XCTAssertEqual(h.shortTerm[60], MetersRenderer.noValue)
        XCTAssertGreaterThan(h.shortTerm[85], -70)
    }
}
