import AppKit

/// The panel area of the main window with the session timeline strip under it.
///
/// The strip keeps a height in points (not a share of the window): the user drags the gap above it between 100 and
/// 300 pt, and the height is stored under its own key. The panels above come first. When the window cannot give them
/// `contentMinimum` and the strip its wish, the strip shrinks down to 100 pt; with less room than that it hides, and
/// the panels get the whole area. Nothing else in the window changes then.
final class TimelineStripSplitView: NSSplitView, NSSplitViewDelegate {
    static let stripHeightRange: ClosedRange<CGFloat> = 100...300   // 300 lets the tone lane (needs a 260 pt panel) show
    static let defaultStripHeight: CGFloat = 140
    static let gap: CGFloat = 8
    /// Points the strip takes from the panels at its smallest: its 100 pt and the gap above it.
    static let smallestReserve = stripHeightRange.lowerBound + gap
    private static let storageKey = "split.v2.timeline.height"

    private let content: NSView
    private let strip: NSView
    /// Smallest height of the panel area in points. Under it the strip gives way.
    private let contentMinimum: CGFloat
    /// The height the user wants. The height on screen can be lower.
    private var wantedHeight: CGFloat
    private var isApplying = false
    private var lastApplied: (length: CGFloat, wanted: CGFloat)?
    /// The strip went away or came back because of the window height.
    var onStripVisibilityChange: (() -> Void)?

    init(content: NSView, strip: NSView, contentMinimum: CGFloat) {
        self.content = content
        self.strip = strip
        self.contentMinimum = contentMinimum
        let stored = CGFloat(UserDefaults.standard.double(forKey: Self.storageKey))
        wantedHeight = Self.stripHeightRange.contains(stored) ? stored : Self.defaultStripHeight
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        isVertical = false
        dividerStyle = .thin
        translatesAutoresizingMaskIntoConstraints = false
        for pane in [content, strip] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            addArrangedSubview(pane)
        }
        strip.isHidden = false
        delegate = self
        setAccessibilityLabel("Panels and session timeline")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var dividerThickness: CGFloat { Self.gap }
    override var dividerColor: NSColor { .clear }

    /// Height of the strip for a total height, or nil when it has to hide.
    static func stripHeight(total: CGFloat, contentMinimum: CGFloat, wanted: CGFloat) -> CGFloat? {
        let room = total - gap - contentMinimum
        guard room >= stripHeightRange.lowerBound else { return nil }
        return min(max(wanted, stripHeightRange.lowerBound), stripHeightRange.upperBound, room).rounded(.down)
    }

    override func layout() {
        super.layout()
        let length = bounds.height
        guard !isApplying, length > 50 else { return }
        // A divider drag changes neither the length nor the wish: it is left alone here.
        if let last = lastApplied, abs(last.length - length) < 0.5, last.wanted == wantedHeight { return }
        lastApplied = (length, wantedHeight)
        isApplying = true
        defer { isApplying = false }
        let height = Self.stripHeight(total: length, contentMinimum: contentMinimum, wanted: wantedHeight)
        if strip.isHidden != (height == nil) {
            strip.isHidden = height == nil
            adjustSubviews()
            onStripVisibilityChange?()
        }
        if let height { setPosition(length - Self.gap - height, ofDividerAt: 0) }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, contentMinimum, bounds.height - Self.gap - Self.stripHeightRange.upperBound)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, bounds.height - Self.gap - Self.stripHeightRange.lowerBound)
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only a user drag carries the divider index. Window resizes, snapshot runs and scripted resizes store nothing.
        guard !isApplying, !strip.isHidden, notification.userInfo?["NSSplitViewDividerIndex"] != nil,
              let type = NSApp.currentEvent?.type, type == .leftMouseDragged || type == .leftMouseUp || type == .leftMouseDown else { return }
        let height = min(max(strip.frame.height, Self.stripHeightRange.lowerBound), Self.stripHeightRange.upperBound)
        wantedHeight = height
        lastApplied = (bounds.height, height)
        UserDefaults.standard.set(Double(height), forKey: Self.storageKey)
    }
}
