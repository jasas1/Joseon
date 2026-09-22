import Foundation
import JoseonCore

// The "now playing" line next to the source name, CPU side: where the text sits at a moment and when it must be drawn
// next. No drawing here: the caller measures the text, draws it at `offset`, and asks `nextRedraw(after:)` so its timer
// runs only while the text moves. Text that fits stands still and costs no timer at all.
//
// A cycle: the text rests at the start for `startPause`, then moves left at `speed` until it has travelled its own width
// plus `gap`, where the next copy has arrived at the start; then the cycle repeats. The caller draws the second copy at
// `repeatOffset` so the line reads as one continuous band.

/// Position of the now-playing text for one moment. Pure: the same inputs give the same frame.
public struct NowPlayingMarquee: Equatable {
    public var text: String
    /// Width the caller can show, in points.
    public var availableWidth: Double
    /// Width of `text` as the caller's font draws it, in points.
    public var textWidth: Double
    /// The moment the text appeared. Every cycle counts from here.
    public var startTime: Double
    /// Reduce Motion: the text never moves. Overflow then shows as a truncated line.
    public var allowsScrolling = true
    /// Points per second. Slow enough to read.
    public var speed = 25.0
    /// Empty space between the end of the text and its next copy.
    public var gap = 40.0
    /// Seconds the text rests at the start of each cycle.
    public var startPause = 2.0
    /// Redraw interval while the text moves (about 15 fps).
    public var frameInterval = 1.0 / 15.0

    public init(text: String, availableWidth: Double, textWidth: Double, startTime: Double) {
        self.text = text
        self.availableWidth = availableWidth
        self.textWidth = textWidth
        self.startTime = startTime
    }

    /// Where to draw for one moment.
    public struct Frame: Equatable {
        /// X of the text's leading edge, relative to the leading edge of the available width. 0 or negative.
        public var offset: Double
        /// The text moves in this cycle (it may rest in the start pause).
        public var isScrolling: Bool
        /// X of the second copy, so the band reads continuously. Nil when that copy starts past the visible width.
        public var repeatOffset: Double?

        public init(offset: Double, isScrolling: Bool, repeatOffset: Double? = nil) {
            self.offset = offset
            self.isScrolling = isScrolling
            self.repeatOffset = repeatOffset
        }
    }

    /// The text is wider than the room for it.
    public var overflows: Bool { textWidth > availableWidth }
    /// Overflow that is allowed to move.
    public var isScrolling: Bool { allowsScrolling && overflows && speed > 0 && availableWidth > 0 }
    /// Distance one cycle covers: the text and the gap after it.
    public var travel: Double { textWidth + gap }
    /// Length of one cycle: the pause, then the travel at `speed`.
    public var cycleSeconds: Double { startPause + travel / speed }

    public func frame(at time: Double) -> Frame {
        guard isScrolling else { return Frame(offset: 0, isScrolling: false) }
        let phase = phase(at: time)
        let offset = -max(0, phase - startPause) * speed
        let repeatOffset = offset + travel
        return Frame(offset: offset, isScrolling: true, repeatOffset: repeatOffset < availableWidth ? repeatOffset : nil)
    }

    /// The next moment the picture changes, or nil when it never does (text fits, motion off). During the start pause
    /// this is the end of the pause; while the text moves it is one frame interval on.
    public func nextRedraw(after time: Double) -> Double? {
        guard isScrolling else { return nil }
        let phase = phase(at: time)
        if phase < startPause { return time + (startPause - phase) }
        return time + frameInterval
    }

    /// Seconds into the current cycle. A time before `startTime` counts as the start.
    private func phase(at time: Double) -> Double {
        let elapsed = max(0, time - startTime)
        let cycle = cycleSeconds
        guard cycle > 0 else { return 0 }
        return elapsed.truncatingRemainder(dividingBy: cycle)
    }

    /// "Artist – Title" (or the one that is known), with " · Hi-Res" after it when the stream is hi-res and the caller
    /// wants that mark. Empty when the track has neither artist nor title.
    public static func displayText(for nowPlaying: NowPlaying, showsHiRes: Bool) -> String {
        var line = nowPlaying.line
        if line.isEmpty { line = nowPlaying.title }
        guard !line.isEmpty else { return "" }
        if showsHiRes, nowPlaying.isHiRes { line += " \u{B7} Hi-Res" }
        return line
    }
}
