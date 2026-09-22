import XCTest
import JoseonCore
@testable import JoseonRender

/// Critic r2 defect 6: never text on text, at any size. Every text a panel draws records its ink box; no two may intersect,
/// and none may leave the panel.
final class LabelLayoutTests: XCTestCase {
    static let sizes = [CGSize(width: 1200, height: 600), CGSize(width: 900, height: 420), CGSize(width: 560, height: 360),
                        CGSize(width: 420, height: 300), CGSize(width: 290, height: 300), CGSize(width: 340, height: 160),
                        CGSize(width: 460, height: 330), CGSize(width: 300, height: 220)]

    private func check(_ panel: PanelKind, _ frames: [AnalysisFrame], _ settings: OffscreenRenderer.Settings, _ name: String) throws {
        for size in Self.sizes {
            let s = try OffscreenRenderer.Session(panel: panel, size: size, scale: 2, theme: Theme(), settings: settings)
            try s.feed(frames)
            _ = try s.snapshotPNG()
            let labels = s.renderer.textLayer.lastLabels
            XCTAssertFalse(labels.isEmpty, "\(name) \(size): no labels")
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5)
            for (i, a) in labels.enumerated() {
                XCTAssertTrue(bounds.contains(a.rect), "\(name) \(Int(size.width))x\(Int(size.height)): \"\(a.text)\" \(a.rect) leaves the panel")
                for b in labels[(i + 1)...] where a.rect.intersects(b.rect) {
                    XCTFail("\(name) \(Int(size.width))x\(Int(size.height)): \"\(a.text)\" \(a.rect) on \"\(b.text)\" \(b.rect)")
                }
            }
        }
    }

    func testSpectrumLabelsNeverIntersect() throws {
        try RenderTestSupport.requireMetal()
        let real = Array(RealFrames.demo(seconds: 4).suffix(120))
        try check(.spectrum, real, .init(), "spectrum")
        try check(.spectrum, RealFrames.annotated(real), .init(), "spectrum+headphone+flags+peaks")
        // Flags that fight for the same place, and peaks next to each other.
        var crowded = RealFrames.annotated(real)
        for i in crowded.indices {
            crowded[i].headphone?.stressFlags = [
                StressFlag(id: "a", severity: .high, title: "A", detail: "", frequencyRangeHz: 20...60, plotLabel: "\u{2212}9 dB vs target"),
                StressFlag(id: "b", severity: .watch, title: "B", detail: "", frequencyRangeHz: 30...80, plotLabel: "excursion +4 dB"),
                StressFlag(id: "c", severity: .info, title: "C with a long title and no label", detail: "", frequencyRangeHz: 40...100),
                StressFlag(id: "d", severity: .high, title: "D", detail: "", frequencyRangeHz: 8_000...20_000, plotLabel: "+8 dB at 9.5 kHz"),
            ]
            crowded[i].topPeaks = [crowded[i].peak] + [131.5, 139, 147, 156].map { PeakReading(frequencyHz: $0, levelDB: -30, noteName: "C#3", cents: 0) }
        }
        try check(.spectrum, crowded, .init(), "spectrum crowded")
    }

    /// Linked cursor: the header readout, the ghost legend entry and the band captions join the labels. Hover from another
    /// panel, pinned, and timed with its ghost trace; every panel; with and without the headphone overlay, and with SPL on.
    /// (The label box at the pointer of the source panel is the hover label of before: it floats over the plot by design.)
    func testLinkedCursorLabelsNeverIntersect() throws {
        try RenderTestSupport.requireMetal()
        for size in [CGSize(width: 1200, height: 600), CGSize(width: 560, height: 360), CGSize(width: 460, height: 330), CGSize(width: 300, height: 220)] {
            XCTAssertTrue(Self.sizes.contains(size))
        }
        let real = Array(RealFrames.demo(seconds: 6).suffix(240))
        var o = SyntheticFrames.Options(); o.includeHeadphone = true; o.includeSPL = true
        let spl = SyntheticFrames.sequence(count: 240, options: o)
        let cursors = [PanelCursor(frequencyHz: 392, source: .meters), PanelCursor(frequencyHz: 3_100, source: .spectrum, isPinned: true),
                       PanelCursor(frequencyHz: 18_500, source: .spectrum, isPinned: true), PanelCursor(frequencyHz: 24, source: .spectrogram),
                       PanelCursor(frequencyHz: 392, secondsAgo: 3.2, source: .spectrogram, isPinned: true)]
        for (k, c) in cursors.enumerated() {
            var base = OffscreenRenderer.Settings()
            base.cursor = c
            base.targetLUFS = -14
            if let ago = c.secondsAgo { base.cursorHistorySlice = try OffscreenRenderer.historySlice(frames: real, secondsAgo: ago) }
            var side = base; side.spectrum.showSide = true
            var splAxis = side; splAxis.levelAxis = .dBSPL
            var pan = base; pan.vectorscopeMode = .panSpectrum
            try check(.spectrum, real, base, "cursor \(k) spectrum")
            try check(.spectrum, RealFrames.annotated(real), side, "cursor \(k) spectrum+headphone+side")
            try check(.spectrum, spl, splAxis, "cursor \(k) spectrum+headphone+SPL")
            try check(.spectrogram, real, base, "cursor \(k) spectrogram")
            try check(.vectorscope, real, base, "cursor \(k) vectorscope")
            try check(.vectorscope, real, pan, "cursor \(k) placement")
            try check(.meters, real, base, "cursor \(k) meters")
            try check(.meters, spl, base, "cursor \(k) meters+SPL")
        }
    }

    func testOtherPanelsLabelsNeverIntersect() throws {
        try RenderTestSupport.requireMetal()
        let real = Array(RealFrames.demo(seconds: 4).suffix(120))
        var pan = OffscreenRenderer.Settings(); pan.vectorscopeMode = .panSpectrum
        var target = OffscreenRenderer.Settings(); target.targetLUFS = -14
        try check(.spectrogram, real, .init(), "spectrogram")
        try check(.vectorscope, real, .init(), "vectorscope")
        try check(.vectorscope, real, pan, "pan spectrum")
        try check(.meters, real, target, "meters")
        var hot = SyntheticFrames.Options(); hot.hot = true
        try check(.meters, SyntheticFrames.sequence(count: 200, options: hot), target, "meters hot")
    }
}
