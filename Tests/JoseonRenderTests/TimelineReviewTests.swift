import XCTest
import AppKit
import JoseonCore
@testable import JoseonRender

/// Design review of the session timeline: every size of the brief, the three windows, with and without the level at the
/// ear, hover and pinned cursors, the empty state. Set JOSEON_TIMELINE_REVIEW=1; PNGs go to `<JOSEON_RENDER_OUT>/`.
final class TimelineReviewTests: XCTestCase {
    static let sizes = [CGSize(width: 1200, height: 220), CGSize(width: 1200, height: 140), CGSize(width: 900, height: 120), CGSize(width: 560, height: 360)]

    func testWriteReviewImages() throws {
        guard ProcessInfo.processInfo.environment["JOSEON_TIMELINE_REVIEW"] == "1" else { throw XCTSkip("Set JOSEON_TIMELINE_REVIEW=1") }
        try RenderTestSupport.requireMetal()
        let frames = SyntheticFrames.sequence(count: 4)
        let withEar = SyntheticFrames.demoSession(minutes: 25), plain = SyntheticFrames.demoSession(minutes: 25, includeLevelA: false)
        func write(_ name: String, _ size: CGSize, _ settings: OffscreenRenderer.Settings) throws {
            RenderTestSupport.write(try OffscreenRenderer.png(panel: .timeline, frames: frames, size: size, settings: settings),
                                    "timeline-\(Int(size.width))x\(Int(size.height))-\(name).png")
        }
        for size in Self.sizes {
            for window in [300, 900, 1800] {
                for (tag, session) in [("ear", withEar), ("plain", plain)] {
                    var s = OffscreenRenderer.Settings()
                    s.session = session; s.timelineWindowSeconds = window; s.targetLUFS = -14
                    try write("\(window / 60)min-\(tag)", size, s)
                }
            }
            var s = OffscreenRenderer.Settings()
            s.session = withEar; s.targetLUFS = -14
            // Hover (not linked): the pointer over the first clip burst of the 15 minute window is not there; take the over flag span.
            var hover = s
            hover.hover = CGPoint(x: size.width * 0.52, y: size.height * 0.45)
            try write("hover", size, hover)
            // Linked, the pointer in the timeline: the cursor is the one the pointer makes (the readout then stands at the pointer).
            var linkedHover = s
            linkedHover.hover = CGPoint(x: size.width * 0.74, y: size.height * 0.5)
            let probe = try OffscreenRenderer.Session(panel: .timeline, size: size, scale: 2, theme: Theme(), settings: linkedHover)
            probe.renderer.cursorLinked = true
            linkedHover.cursor = probe.renderer.cursor(at: linkedHover.hover!)
            try write("hover-linked", size, linkedHover)
            var pinned = s
            pinned.cursor = PanelCursor(frequencyHz: 392, secondsAgo: 166, source: .timeline, isPinned: true)
            try write("pinned", size, pinned)
            var follower = s
            follower.cursor = PanelCursor(frequencyHz: 392, secondsAgo: 12.4, source: .spectrogram)
            try write("follows-spectrogram", size, follower)
            var empty = OffscreenRenderer.Settings()
            empty.targetLUFS = -14
            try write("empty", size, empty)
            var hc = s; hc.increaseContrast = true
            try write("high-contrast", size, hc)
        }
    }
}
