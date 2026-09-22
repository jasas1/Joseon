import AppKit
import Foundation
import JoseonCore

// Render contracts. Frozen for module workers.
// Every panel is an NSView that pulls frames from a provider closure on its own display link.

public typealias FrameProvider = () -> AnalysisFrame

public enum PanelKind: String, CaseIterable, Sendable {
    case spectrum, spectrogram, vectorscope, meters
    /// The session timeline (last minutes of loudness, peaks and events). Its data comes from a `SessionSnapshot` provider.
    case timeline
}

/// Colors and type for all panels. One theme object so panels read as one system.
public struct Theme: Sendable {
    public var background = SIMD4<Float>(0.035, 0.047, 0.086, 1)
    public var panel = SIMD4<Float>(0.055, 0.075, 0.13, 1)
    public var grid = SIMD4<Float>(0.35, 0.45, 0.65, 0.22)
    public var text = SIMD4<Float>(0.80, 0.86, 0.95, 1)
    public var accent = SIMD4<Float>(0.20, 0.55, 1.0, 1)
    public var warn = SIMD4<Float>(1.0, 0.65, 0.15, 1)
    public var danger = SIMD4<Float>(1.0, 0.25, 0.25, 1)
    public init() {}
}

public struct SpectrumViewOptions: Equatable, Sendable {
    public var showLeftRight = true
    public var showMid = true
    /// Side = (L−R)/2 as its own trace. Off by default.
    public var showSide = false
    public var showPeakHold = true
    public var showAverage = true
    public var showHeadphoneOverlay = true
    public var minDB: Float = -96
    public var maxDB: Float = 0
    public init() {}
}

// MARK: - Linked cursor
//
// One `PanelCursorLink` is shared by the panels of one window. A panel that the pointer (or the keyboard) moves in
// writes the cursor; every panel that holds the same link draws it and shows its own readout at that frequency.
// Main thread only.

/// The shared cursor. `frequencyHz` is always set; `secondsAgo` only when the cursor comes from a time axis (spectrogram).
public struct PanelCursor: Equatable, Sendable {
    public var frequencyHz: Float
    /// Seconds before "now" on the spectrogram time axis. Nil = the live moment.
    public var secondsAgo: Double?
    /// The panel the cursor came from.
    public var source: PanelKind
    /// A click pins the cursor: it stays when the pointer leaves, until Esc or a second click.
    public var isPinned: Bool

    public init(frequencyHz: Float, secondsAgo: Double? = nil, source: PanelKind, isPinned: Bool = false) {
        self.frequencyHz = frequencyHz; self.secondsAgo = secondsAgo; self.source = source; self.isPinned = isPinned
    }
}

/// A past spectrum column that the spectrogram publishes while the cursor has a time, so the spectrum panel can
/// draw it as a ghost trace ("the spectrum at −3.2 s").
public struct CursorHistorySlice: Equatable, Sendable {
    public var secondsAgo: Double
    /// Same length and meaning as `SpectrumReading.frequencies` / `.mid` (dBFS) of the frames the spectrogram saw.
    public var frequencies: [Float]
    public var midDB: [Float]

    public init(secondsAgo: Double, frequencies: [Float], midDB: [Float]) {
        self.secondsAgo = secondsAgo; self.frequencies = frequencies; self.midDB = midDB
    }
}

public final class PanelCursorLink {
    public private(set) var cursor: PanelCursor?
    public private(set) var historySlice: CursorHistorySlice?
    private var observers: [UUID: () -> Void] = [:]

    public init() {}

    /// Set or move the cursor. A pinned cursor is only replaced by another pinned cursor or by `clear()`;
    /// hover moves from any panel are ignored while it is pinned.
    public func set(_ new: PanelCursor) {
        if let current = cursor, current.isPinned, !new.isPinned { return }
        guard new != cursor else { return }
        cursor = new
        if new.secondsAgo == nil { historySlice = nil }
        notify()
    }

    /// The pointer left the panel: clears a hover cursor, keeps a pinned one.
    public func hoverEnded(from source: PanelKind) {
        guard let current = cursor, !current.isPinned, current.source == source else { return }
        cursor = nil; historySlice = nil
        notify()
    }

    /// Esc, or a click on a pinned cursor.
    public func clear() {
        guard cursor != nil || historySlice != nil else { return }
        cursor = nil; historySlice = nil
        notify()
    }

    /// The spectrogram publishes the column under a timed cursor. Nil when the time is outside its history.
    public func publish(historySlice slice: CursorHistorySlice?) {
        guard slice != historySlice else { return }
        historySlice = slice
        notify()
    }

    /// Returns a token; pass it to `removeObserver`. The closure runs on the main thread after every change.
    @discardableResult
    public func addObserver(_ onChange: @escaping () -> Void) -> UUID {
        let id = UUID(); observers[id] = onChange; return id
    }
    public func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() { for o in observers.values { o() } }
}

// MARK: - Session timeline panel

/// The timeline panel pulls the record with this closure about once per second (and on cursor moves).
public typealias SessionProvider = () -> SessionSnapshot
