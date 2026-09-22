import XCTest
import JoseonCore
@testable import JoseonRender

/// The now-playing marquee model: rest when the text fits, a slow readable scroll with a pause and a gap when it does not,
/// and the redraw schedule that lets the view run no timer while nothing moves.
final class NowPlayingMarqueeTests: XCTestCase {
    private func marquee(textWidth: Double, available: Double = 140, start: Double = 100) -> NowPlayingMarquee {
        NowPlayingMarquee(text: "Artist \u{2013} Title", availableWidth: available, textWidth: textWidth, startTime: start)
    }

    // MARK: Fits

    func testTextThatFitsNeverMoves() {
        let m = marquee(textWidth: 90)
        XCTAssertFalse(m.overflows)
        XCTAssertFalse(m.isScrolling)
        for t in stride(from: 100.0, through: 160.0, by: 7.3) {
            XCTAssertEqual(m.frame(at: t), NowPlayingMarquee.Frame(offset: 0, isScrolling: false))
            XCTAssertNil(m.nextRedraw(after: t), "a static line needs no redraw")
        }
    }

    func testExactFitIsNotOverflow() {
        let m = marquee(textWidth: 140)
        XCTAssertFalse(m.isScrolling)
        XCTAssertNil(m.nextRedraw(after: 100))
    }

    // MARK: Overflow

    func testStartPauseHoldsTheTextAtZero() {
        let m = marquee(textWidth: 200)
        XCTAssertTrue(m.isScrolling)
        XCTAssertEqual(m.frame(at: 100).offset, 0)
        XCTAssertEqual(m.frame(at: 101.9).offset, 0)
        XCTAssertTrue(m.frame(at: 101.9).isScrolling)
        // Before the start time counts as the start.
        XCTAssertEqual(m.frame(at: 50).offset, 0)
        // The next redraw during the pause is the end of the pause, not a frame interval.
        XCTAssertEqual(try XCTUnwrap(m.nextRedraw(after: 100)), 102, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(m.nextRedraw(after: 101.5)), 102, accuracy: 1e-9)
    }

    func testOffsetMovesLeftMonotonicallyAtThePace() {
        let m = marquee(textWidth: 200)
        let step = m.frameInterval
        var last = m.frame(at: 100 + m.startPause).offset
        XCTAssertEqual(last, 0)
        var t = 100 + m.startPause
        let end = 100 + m.cycleSeconds - step / 2
        while t + step < end {
            t += step
            let offset = m.frame(at: t).offset
            XCTAssertLessThan(offset, last, "moves left every frame")
            XCTAssertEqual(last - offset, m.speed * step, accuracy: 1e-6, "25 pt/s at 15 fps")
            last = offset
        }
        // One second in: 25 pt.
        XCTAssertEqual(m.frame(at: 100 + m.startPause + 1).offset, -25, accuracy: 1e-9)
    }

    func testWrapsAfterTextPlusGap() {
        let m = marquee(textWidth: 200)
        XCTAssertEqual(m.travel, 240)
        XCTAssertEqual(m.cycleSeconds, 2 + 240 / 25, accuracy: 1e-9)
        let endOfCycle = 100 + m.cycleSeconds
        XCTAssertEqual(m.frame(at: endOfCycle - 0.01).offset, -240 + 0.25, accuracy: 1e-6)
        // The new cycle starts with the pause again. (Just past the boundary: the boundary itself is a rounding coin toss.)
        XCTAssertEqual(m.frame(at: endOfCycle + 1e-6).offset, 0, accuracy: 1e-9)
        XCTAssertEqual(m.frame(at: endOfCycle + 1).offset, 0)

        XCTAssertEqual(m.frame(at: endOfCycle + m.startPause + 2).offset, -50, accuracy: 1e-9)
    }

    func testRepeatCopyAppearsWhenItEntersTheVisibleWidth() {
        let m = marquee(textWidth: 200)
        // At rest the second copy starts at 240: past the 140 pt of room.
        XCTAssertNil(m.frame(at: 100).repeatOffset)
        // After 4 s of travel (100 pt) it starts at 140: still not visible. One frame on, it is.
        XCTAssertNil(m.frame(at: 100 + m.startPause + 4).repeatOffset)
        let visible = m.frame(at: 100 + m.startPause + 4 + m.frameInterval)
        XCTAssertEqual(try XCTUnwrap(visible.repeatOffset), visible.offset + 240, accuracy: 1e-9)
    }

    func testRedrawScheduleWhileMoving() throws {
        let m = marquee(textWidth: 200)
        let t = 100 + m.startPause + 1
        XCTAssertEqual(try XCTUnwrap(m.nextRedraw(after: t)), t + 1.0 / 15.0, accuracy: 1e-9)
    }

    func testReduceMotionKeepsTheTextStill() {
        var m = marquee(textWidth: 200)
        m.allowsScrolling = false
        XCTAssertTrue(m.overflows)
        XCTAssertFalse(m.isScrolling)
        XCTAssertEqual(m.frame(at: 105).offset, 0)
        XCTAssertNil(m.nextRedraw(after: 105))
    }

    func testNoRoomMeansNoMotion() {
        let m = marquee(textWidth: 200, available: 0)
        XCTAssertFalse(m.isScrolling)
        XCTAssertNil(m.nextRedraw(after: 100))
    }

    // MARK: Display text

    func testDisplayTextArtistAndTitle() {
        let np = NowPlaying(title: "Says", artist: "Nils Frahm", source: "Qobuz")
        XCTAssertEqual(NowPlayingMarquee.displayText(for: np, showsHiRes: true), "Nils Frahm \u{2013} Says")
    }

    func testDisplayTextFallsBackToTitleOnly() {
        let np = NowPlaying(title: "Untitled Track 4", artist: "", source: "Qobuz")
        XCTAssertEqual(NowPlayingMarquee.displayText(for: np, showsHiRes: true), "Untitled Track 4")
    }

    func testDisplayTextArtistOnly() {
        let np = NowPlaying(title: "", artist: "Boards of Canada", source: "Qobuz")
        XCTAssertEqual(NowPlayingMarquee.displayText(for: np, showsHiRes: true), "Boards of Canada")
    }

    func testDisplayTextHiResMarkOnlyWhenAllowed() {
        let np = NowPlaying(title: "Says", artist: "Nils Frahm", source: "Qobuz", isHiRes: true)
        XCTAssertEqual(NowPlayingMarquee.displayText(for: np, showsHiRes: true), "Nils Frahm \u{2013} Says \u{B7} Hi-Res")
        XCTAssertEqual(NowPlayingMarquee.displayText(for: np, showsHiRes: false), "Nils Frahm \u{2013} Says")
        let plain = NowPlaying(title: "Says", artist: "Nils Frahm", source: "Qobuz", isHiRes: false)
        XCTAssertEqual(NowPlayingMarquee.displayText(for: plain, showsHiRes: true), "Nils Frahm \u{2013} Says")
    }

    func testDisplayTextEmptyTrackIsEmptyEvenWhenHiRes() {
        let np = NowPlaying(title: "", artist: "", source: "Qobuz", isHiRes: true)
        XCTAssertEqual(NowPlayingMarquee.displayText(for: np, showsHiRes: true), "")
    }
}
