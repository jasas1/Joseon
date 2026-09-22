import AppKit
import QuartzCore
import JoseonCore

/// The session timeline panel: the last minutes of listening as lanes (loudness, true peak, the level at the ear when it
/// is known, tone) over one time axis, with track flags, clip and over marks, stress-flag spans and silence.
/// See `docs/specs/session-timeline.md`.
///
/// Data: the view pulls a `SessionSnapshot` from `sessionProvider` at most once per second, and once more when the shared
/// cursor moved. A snapshot with the revision already on screen costs nothing. The panel does not read analysis frames on
/// its display ticks; `frameProvider` only gives the frequency a cursor made here starts with (the frame's peak).
///
/// Cursor: with a `cursorLink` the timeline is a time-axis source, like the spectrogram. The pointer sets
/// `PanelCursor(frequencyHz: <the link's current frequency, or the frame's peak>, secondsAgo:, source: .timeline)`, a click
/// pins it, and a cursor with a time from another panel draws here as a hairline at that time. Keys: left / right move one
/// second into the past / toward now (Shift: 10 s), Return pins or unpins, Esc clears.
public final class TimelineView: PanelView {
    public var sessionProvider: SessionProvider
    /// Seconds across the panel: 300, 900 (default) or 1800. Other values work; under 10 is taken as 10.
    public var windowSeconds = 900
    /// The loudness target as a dotted line in the Loudness lane. The same value as `MetersView.targetLUFS`. Nil = no line.
    public var targetLUFS: Float?
    /// The Tone lane (the 8 band energies as a hue strip). It shows on panels of 260 pt height or more; false hides it there too.
    public var showBands = true
    /// The "At the ear" lane (the A-weighted level per second, with the 85 dB(A) line). Off by default: the lane is opt-in,
    /// and needs samples that carry `levelA`. The level at the ear stays in the cursor readout either way.
    public var showLevelAtEar = false

    private var lastPull: CFTimeInterval = -1
    private var lastPulledCursor: PanelCursor?
    /// Seconds between two pulls of the record.
    static let pullInterval: CFTimeInterval = 1
    /// The newest sample may be this old (wall clock) and the right end of the axis still reads "now".
    static let liveTolerance: TimeInterval = 3

    public init(frameProvider: @escaping FrameProvider, sessionProvider: @escaping SessionProvider) {
        self.sessionProvider = sessionProvider
        super.init(kind: .timeline, frameProvider: frameProvider)
        preferredFramesPerSecond = 30
    }

    override func syncOptions() { syncSession(now: CACurrentMediaTime()) }

    /// Runs on every display tick. Without a due pull it compares three options and one time stamp.
    func syncSession(now: CFTimeInterval, date: Date = Date()) {
        guard let r = renderer as? TimelineRenderer else { return }
        r.windowSeconds = windowSeconds
        r.targetLUFS = targetLUFS
        r.showBands = showBands
        r.showLevelAtEar = showLevelAtEar
        let cursor = cursorLink?.cursor
        let cursorMoved = cursor != lastPulledCursor && cursor?.secondsAgo != nil
        guard lastPull < 0 || now - lastPull >= Self.pullInterval || now < lastPull || cursorMoved else { return }
        if now - lastPull >= Self.pullInterval || lastPull < 0 || now < lastPull { lastPull = now }
        lastPulledCursor = cursor
        let snapshot = sessionProvider()
        r.setSnapshot(snapshot)             // equal revision: returns at once
        r.isLive = snapshot.samples.last.map { date.timeIntervalSince($0.date) < Self.liveTolerance } ?? true
    }

    /// Pulls the record now (the app calls it after `SessionRecording.clear()` so the panel empties at once).
    public func reloadSession() {
        lastPull = -1
        (renderer as? TimelineRenderer)?.needsDisplay = true
    }

    // MARK: Keyboard

    /// Left / right: one second into the past / toward now (Shift: 10 s). Up / down do nothing here. Return and Esc as in
    /// every panel. With no timed cursor the first arrow key starts at the newest second.
    override func handleCursorKey(_ key: CursorKey, shift: Bool) -> Bool {
        guard key == .left || key == .right || key == .up || key == .down else { return super.handleCursorKey(key, shift: shift) }
        guard key == .left || key == .right, let link = cursorLink, let r = renderer as? TimelineRenderer else { return false }
        syncSession(now: CACurrentMediaTime())
        guard !r.model.isEmpty else { return false }
        let span = max(r.model.newestTime - r.model.oldestTime, 0)
        var c: PanelCursor
        if let current = link.cursor {
            c = current
            if let ago = current.secondsAgo {
                let step = shift ? 10.0 : 1.0
                // Whole seconds back from the newest sample: the cursor stands on recorded seconds.
                c.secondsAgo = min(max((ago + (key == .left ? step : -step)).rounded(), 0), span)
            } else {
                c.secondsAgo = 0
            }
        } else {
            c = PanelCursor(frequencyHz: peakFrequency(), secondsAgo: 0, source: .timeline)
        }
        c.source = .timeline
        link.set(c)
        announceCursor()
        return true
    }

    private func peakFrequency() -> Float {
        let f = frameProvider()
        let peak = !Fmt.isFloor(f.peak.levelDB) && f.peak.frequencyHz > 0 ? f.peak.frequencyHz : 1000
        return min(max(peak, Self.cursorRangeHz.lowerBound), Self.cursorRangeHz.upperBound)
    }

    public override func mouseEntered(with event: NSEvent) {
        // The frequency of a cursor that starts here: read once per entry, not per move.
        (renderer as? TimelineRenderer)?.fallbackFrequencyHz = peakFrequency()
        super.mouseEntered(with: event)
    }

    public override func accessibilityValue() -> Any? {
        syncSession(now: CACurrentMediaTime())
        return super.accessibilityValue()
    }
}
