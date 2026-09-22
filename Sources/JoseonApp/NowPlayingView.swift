import AppKit
import SwiftUI
import JoseonCore
import JoseonRender

/// The now-playing line: very small, light grey, next to the source name. It scrolls only when the text does not fit
/// (see `NowPlayingMarquee`). A one-shot timer chain runs at about 15 Hz while the text moves and not at all while it
/// rests, fits, or nothing plays.
final class NowPlayingView: NSView {
    enum Style {
        /// In the status bar button: text in the menu bar's own color, clicks go to the button.
        case menuBar
        /// In the popover: the app's secondary text color.
        case popover
    }

    static let font = NSFont.systemFont(ofSize: 9, weight: .regular)
    static let lineHeight: CGFloat = 12

    let style: Style
    var nowPlaying: NowPlaying? { didSet { if nowPlaying != oldValue { rebuild() } } }
    var showsHiRes = true { didSet { if showsHiRes != oldValue { rebuild() } } }
    /// False while the view is off screen (popover closed): no timer.
    var isActive = true { didSet { if isActive != oldValue { schedule() } } }

    private(set) var text = ""
    private(set) var marquee: NowPlayingMarquee?
    private var textSize = NSSize.zero
    private var timer: Timer?

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.lineHeight) }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { style == .menuBar ? nil : super.hitTest(point) }

    /// The timer runs only for a view in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        schedule()
    }

    override func viewDidHide() { super.viewDidHide(); schedule() }
    override func viewDidUnhide() { super.viewDidUnhide(); schedule() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, marquee != nil { rebuild(keepClock: true) }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// New text (or new room for it): measure once, start a cycle, and draw.
    private func rebuild(keepClock: Bool = false) {
        let newText = nowPlaying.map { NowPlayingMarquee.displayText(for: $0, showsHiRes: showsHiRes) } ?? ""
        if newText != text {
            text = newText
            textSize = text.isEmpty ? .zero : (text as NSString).size(withAttributes: [.font: Self.font])
            toolTip = text.isEmpty ? nil : text
            setAccessibilityElement(!text.isEmpty)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(text.isEmpty ? nil : "Now playing: \(text)")
        }
        if text.isEmpty {
            marquee = nil
        } else {
            let start = keepClock ? (marquee?.startTime ?? Self.now) : Self.now
            var m = NowPlayingMarquee(text: text, availableWidth: Double(bounds.width), textWidth: Double(textSize.width.rounded(.up)), startTime: start)
            m.allowsScrolling = !Palette.reduceMotion
            marquee = m
        }
        needsDisplay = true
        schedule()
    }

    /// One shot at the next moment the picture changes. Nothing scheduled while the text rests.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard isActive, window != nil, !isHiddenOrHasHiddenAncestor, let marquee else { return }
        let now = Self.now
        guard let next = marquee.nextRedraw(after: now) else { return }
        let t = Timer(timeInterval: max(next - now, 0.001), repeats: false) { [weak self] _ in
            self?.needsDisplay = true
            self?.schedule()
        }
        t.tolerance = 0.005
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Light grey: the menu bar's text color at 0.7 (0.9 with Increase Contrast), or the app's secondary text.
    private var color: NSColor {
        switch style {
        case .popover:
            return Palette.secondaryText
        case .menuBar:
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return (dark ? NSColor.white : NSColor.black).withAlphaComponent(Palette.highContrast ? 0.9 : 0.7)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let marquee, !text.isEmpty else { return }
        let frame = marquee.frame(at: Self.now)
        let y = ((bounds.height - textSize.height) / 2).rounded()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        if frame.isScrolling {
            let attributed = NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: color])
            attributed.draw(at: NSPoint(x: CGFloat(frame.offset), y: y))
            if let repeatOffset = frame.repeatOffset {
                attributed.draw(at: NSPoint(x: CGFloat(repeatOffset), y: y))
            }
        } else {
            // Rests (fits, or Reduce Motion): one line, an ellipsis where it would overflow.
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let attributed = NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: color, .paragraphStyle: paragraph])
            attributed.draw(in: NSRect(x: 0, y: y, width: bounds.width, height: textSize.height))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// `NowPlayingView` for the SwiftUI popover header. Takes the width SwiftUI offers, one line high.
struct NowPlayingMarqueeHost: NSViewRepresentable {
    var nowPlaying: NowPlaying?
    var showsHiRes: Bool
    /// False while the popover is closed: the view then runs no timer.
    var isActive: Bool

    func makeNSView(context: Context) -> NowPlayingView {
        let view = NowPlayingView(style: .popover)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NowPlayingView, context: Context) {
        view.showsHiRes = showsHiRes
        view.nowPlaying = nowPlaying
        view.isActive = isActive
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NowPlayingView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: NowPlayingView.lineHeight)
    }
}
