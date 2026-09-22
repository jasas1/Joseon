import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Design review of A/B compare: the spectrum and the meters with a reference, from real pipeline frames for B
/// (`TestSignals.demoBlock` through `AnalysisEngine.processNow`) and `SyntheticFrames.demoComparison` for A.
/// Set JOSEON_AB_OUT to choose the directory.
final class ComparisonReviewTests: XCTestCase {
    static var outputDirectory: URL {
        let env = ProcessInfo.processInfo.environment["JOSEON_AB_OUT"]
        let url = env.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? RenderTestSupport.outputDirectory.appendingPathComponent("ab", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let sizes = [CGSize(width: 1200, height: 600), CGSize(width: 560, height: 360), CGSize(width: 460, height: 330)]

    /// B: the demo music, 12 s measured. With `headphone`, every frame carries that demo headphone.
    static func live(seconds: Double = 12, headphone: SyntheticFrames.DemoHeadphone? = nil) -> [AnalysisFrame] {
        let frames = RealFrames.demo(seconds: seconds)
        guard let headphone else { return frames }
        let tail = frames.suffix(180)
        guard let first = tail.first else { return frames }
        let reading = SyntheticFrames.demoHeadphoneReading(headphone, for: first.spectrum)
        return tail.map { f in
            var g = f
            var r = reading
            r.predictedAtEarDB = zip(f.spectrum.mid, reading.responseDB).map { $0 + $1 }
            g.headphone = r
            return g
        }
    }

    struct Scenario {
        var name: String
        var frames: [AnalysisFrame]
        var settings: OffscreenRenderer.Settings
    }

    static func scenarios() -> [Scenario] {
        let plain = live()
        let withHP = live(headphone: .hd800sLike)
        let young = RealFrames.demo(seconds: 3)
        let a = SyntheticFrames.demoComparison(from: plain[plain.count - 1])
        let aHP = SyntheticFrames.demoComparison(from: withHP[withHP.count - 1], headphone: .susvaraLike)
        func settings(_ c: ComparisonSnapshot, _ edit: (inout OffscreenRenderer.Settings) -> Void = { _ in }) -> OffscreenRenderer.Settings {
            var s = OffscreenRenderer.Settings()
            s.comparison = c
            s.targetLUFS = -14
            edit(&s)
            return s
        }
        return [
            Scenario(name: "signal-matched", frames: plain, settings: settings(a)),
            Scenario(name: "signal-as-played", frames: plain, settings: settings(a) { $0.comparisonLevelMatch = false }),
            Scenario(name: "signal-with-headphone-band", frames: withHP, settings: settings(aHP)),
            Scenario(name: "headphone-mode", frames: withHP, settings: settings(aHP) { $0.comparisonMode = .headphone }),
            Scenario(name: "measuring-b", frames: young, settings: settings(a)),
            Scenario(name: "pinned-cursor", frames: plain, settings: settings(a) { $0.cursor = PanelCursor(frequencyHz: 3_100, source: .spectrum, isPinned: true) }),
        ]
    }

    func testRenderComparisonReviewImages() throws {
        try RenderTestSupport.requireMetal()
        for sc in Self.scenarios() {
            // The narrow cards too, for the scenario that asks the most of the header.
            for size in Self.sizes + (sc.name == "signal-with-headphone-band" ? [CGSize(width: 290, height: 300), CGSize(width: 900, height: 420)] : []) {
                for panel in [PanelKind.spectrum, .meters] {
                    // The spectrum needs only the newest frames; the meters' history wants them all.
                    let frames = panel == .spectrum ? Array(sc.frames.suffix(180)) : sc.frames
                    let png = try OffscreenRenderer.png(panel: panel, frames: frames, size: size, scale: 2, settings: sc.settings)
                    XCTAssertGreaterThan(png.count, 1000)
                    try png.write(to: Self.outputDirectory.appendingPathComponent("\(panel.rawValue)-\(sc.name)-\(Int(size.width))x\(Int(size.height)).png"))
                }
            }
        }
    }
}
