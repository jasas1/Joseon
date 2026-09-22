import AppKit
import JoseonRender

/// A rounded card with a small title, an options menu button and one panel.
final class PanelCardView: NSView {
    let panel: PanelView
    /// Shown in capitals in the title row. The accessibility labels follow it.
    var title: String { didSet { if title != oldValue { applyTitle() } } }
    /// A small control in the title row, left of the options button (for example "Scope | Placement").
    /// When the card is too narrow for the title and the control, the control takes the place of the title:
    /// its selected segment names the view. When not even the control fits, it hides (the options menu has the same items).
    var accessoryView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let accessoryView {
                accessoryView.translatesAutoresizingMaskIntoConstraints = true
                addSubview(accessoryView, positioned: .below, relativeTo: placeholder)
            }
            needsLayout = true
        }
    }
    /// A frozen display: the graph goes to 70 % so the card reads as "not live". The header has the one "Paused" sign.
    var isDimmed = false {
        didSet {
            guard isDimmed != oldValue else { return }
            panel.alphaValue = isDimmed ? Self.dimmedAlpha : 1
            refreshState()
        }
    }
    static let dimmedAlpha: CGFloat = 0.7
    /// Height of the header row every panel draws at its top.
    static let panelHeaderHeight: CGFloat = 22
    /// Builds the options menu each time the user opens it.
    var menuProvider: (() -> NSMenu)?

    private let titleLabel: NSTextField
    private let optionsButton: NSButton
    private let stateLabel = NSTextField(labelWithString: "")
    private let placeholder = PlaceholderBadge()

    /// Where the card shows its "nothing to draw" text.
    enum PlaceholderStyle {
        /// A quiet plate in the center of the graph. For panels with a large empty plot.
        case center
        /// Beside the title. For dense panels that keep scales and readouts on screen at silence.
        case titleRow
    }
    var placeholderStyle = PlaceholderStyle.center { didSet { refreshState() } }

    /// Quiet text for a card that has nothing to draw. Set it only then.
    var placeholderText: String? { didSet { if placeholderText != oldValue { refreshState() } } }

    /// Small text beside the title. It never covers the graph.
    var stateText: String? { didSet { if stateText != oldValue { refreshState() } } }

    private func applyTitle() {
        titleLabel.stringValue = title.uppercased()
        optionsButton.toolTip = "\(title) options"
        optionsButton.setAccessibilityLabel("\(title) options")
        panel.setAccessibilityLabel("\(title) graph")
        setAccessibilityLabel("\(title) panel")
        needsLayout = true
    }

    private func refreshState() {
        let centered = placeholderStyle == .center ? placeholderText : nil
        placeholder.text = centered ?? ""
        placeholder.isHidden = centered == nil
        let tag = stateText ?? (placeholderStyle == .titleRow ? placeholderText : nil)
        // A state ("PAUSED") reads as a tag. The no-audio text is quiet: plain case, regular weight.
        stateLabel.stringValue = stateText != nil ? (tag ?? "").uppercased() : (tag ?? "")
        stateLabel.font = .systemFont(ofSize: stateText != nil ? 10 : 11, weight: stateText != nil ? .semibold : .regular)
        stateLabel.toolTip = tag
        needsLayout = true
        stateLabel.textColor = stateText != nil ? Palette.accent : Palette.secondaryText
        setAccessibilityValue(placeholderText ?? stateText ?? (isDimmed ? "Paused" : ""))
    }


    init(title: String, panel: PanelView) {
        self.title = title
        self.panel = panel
        titleLabel = NSTextField(labelWithString: title.uppercased())
        optionsButton = NSButton()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        titleLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // The card is the accessibility group: the label text would be read twice.
        titleLabel.setAccessibilityElement(false)

        optionsButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        optionsButton.imagePosition = .imageOnly
        optionsButton.isBordered = false
        optionsButton.bezelStyle = .regularSquare
        optionsButton.target = self
        optionsButton.action = #selector(showOptions(_:))
        optionsButton.toolTip = "\(title) options"
        optionsButton.setAccessibilityLabel("\(title) options")
        optionsButton.setAccessibilityRole(.menuButton)
        optionsButton.translatesAutoresizingMaskIntoConstraints = false

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.image)
        panel.setAccessibilityLabel("\(title) graph")

        stateLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.setAccessibilityElement(false)
        stateLabel.isHidden = true
        stateLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isHidden = true

        addSubview(panel)
        addSubview(titleLabel)
        addSubview(stateLabel)
        addSubview(optionsButton)
        // Above the panel. It is hidden while the panel has graphics to draw.
        addSubview(placeholder)

        let minWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
        let minHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: 110)
        minWidth.priority = NSLayoutConstraint.Priority(751)
        minHeight.priority = NSLayoutConstraint.Priority(751)
        let placeholderCenterY = placeholder.centerYAnchor.constraint(equalTo: panel.centerYAnchor)
        placeholderCenterY.priority = .defaultHigh
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: 14),
            stateLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            stateLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: optionsButton.leadingAnchor, constant: -6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: optionsButton.leadingAnchor, constant: -6),
            placeholder.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            placeholderCenterY,
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: panel.widthAnchor, constant: -16),
            // The top 22 pt of a panel are its own header row (legend, readouts): the card never draws there.
            placeholder.topAnchor.constraint(greaterThanOrEqualTo: panel.topAnchor, constant: PanelCardView.panelHeaderHeight + 4),
            optionsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            optionsButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            optionsButton.widthAnchor.constraint(equalToConstant: 22),
            optionsButton.heightAnchor.constraint(equalToConstant: 22),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            minWidth, minHeight,
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title) panel")
        applyColors()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The text beside the title shows whole or not at all: a narrow card never truncates it.
    override func layout() {
        super.layout()
        var trailingLimit = optionsButton.frame.minX - 6
        var showTitle = true
        if let accessory = accessoryView {
            let size = accessory.fittingSize
            let titleWidth = ceil(titleLabel.intrinsicContentSize.width)
            let y = ((bounds.height - 14 - size.height / 2) * 2).rounded() / 2
            if 12 + titleWidth + 10 + size.width <= trailingLimit {
                accessory.isHidden = false
                accessory.frame = NSRect(x: trailingLimit - size.width, y: y, width: size.width, height: size.height)
                trailingLimit = accessory.frame.minX - 8
            } else if 10 + size.width <= trailingLimit {
                accessory.isHidden = false
                accessory.frame = NSRect(x: 10, y: y, width: size.width, height: size.height)
                showTitle = false
            } else {
                accessory.isHidden = true
            }
        }
        if titleLabel.isHidden == showTitle { titleLabel.isHidden = !showTitle }
        let available = showTitle ? trailingLimit - (titleLabel.frame.maxX + 10) : -1
        let hide = stateLabel.stringValue.isEmpty || stateLabel.intrinsicContentSize.width > available
        if stateLabel.isHidden != hide { stateLabel.isHidden = hide }
    }

    /// Call when Increase Contrast changes.
    func applyColors() {
        layer?.backgroundColor = Palette.panel.cgColor
        layer?.borderColor = Palette.cardBorder.cgColor
        titleLabel.textColor = Palette.secondaryText
        placeholder.applyColors()
        refreshState()
        optionsButton.contentTintColor = Palette.secondaryText
        panel.theme = Palette.current
        panel.needsDisplay = true
    }

    @objc private func showOptions(_ sender: NSButton) {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }
}

/// Quiet text on a soft rounded plate. It lets clicks through to the panel.
final class PlaceholderBadge: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        applyColors()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func applyColors() {
        layer?.backgroundColor = Palette.panel.withAlphaComponent(0.88).cgColor
        layer?.borderColor = Palette.cardBorder.cgColor
        label.textColor = Palette.secondaryText
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// An NSSplitView that stores its divider positions as fractions in UserDefaults.
/// The gap between the cards is the drag handle.
final class PersistentSplitView: NSSplitView, NSSplitViewDelegate {
    private let storageKey: String
    private let defaultFractions: [CGFloat]
    private var restored = false
    private var isApplying = false
    /// The shares on screen: the defaults, the stored split, or the last user drag. Every resize applies them
    /// again, so the layout at a window size does not depend on the sizes the window had before.
    private var currentFractions: [CGFloat] = []
    private var lastAppliedLength: CGFloat = 0

    /// Smallest length of each pane in points. A drag stops there, and the default split respects it
    /// when the whole is long enough. Empty = no limit beyond the card's own minimum.
    private let minimums: [CGFloat]

    /// `fractions`: size of each pane as a share of the whole, for example [0.6, 0.4].
    init(key: String, vertical: Bool, panes: [NSView], fractions: [CGFloat], minimums: [CGFloat] = []) {
        // "v2": round 5 changed the default shares. A stored round 4 split would keep the stereo card a thumbnail.
        storageKey = "split.v2." + key
        defaultFractions = fractions
        self.minimums = minimums.count == fractions.count ? minimums : [CGFloat](repeating: 0, count: fractions.count)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        isVertical = vertical
        dividerStyle = .thin
        translatesAutoresizingMaskIntoConstraints = false
        for pane in panes {
            pane.translatesAutoresizingMaskIntoConstraints = false
            addArrangedSubview(pane)
        }
        delegate = self
        setAccessibilityLabel("Panel layout")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var dividerThickness: CGFloat { 8 }
    override var dividerColor: NSColor { .clear }

    private var length: CGFloat { isVertical ? bounds.width : bounds.height }

    override func layout() {
        super.layout()
        if !restored, length > 50 {
            restored = true
            let stored = (UserDefaults.standard.array(forKey: storageKey) as? [Double])?.map { CGFloat($0) }
            let fractions = (stored?.count == defaultFractions.count && stored?.allSatisfy({ $0 > 0.02 && $0 < 0.98 }) == true) ? stored! : defaultFractions
            currentFractions = fractions
            lastAppliedLength = length
            apply(fractions)
        } else if restored, !isApplying, length > 50, abs(length - lastAppliedLength) > 0.5 {
            // A window resize keeps the shares, and no pane goes under its minimum while the others have room.
            lastAppliedLength = length
            apply(currentFractions)
        }
    }

    private func apply(_ fractions: [CGFloat]) {
        let usable = length - dividerThickness * CGFloat(fractions.count - 1)
        let total = fractions.reduce(0, +)
        guard usable > 0, total > 0 else { return }
        var lengths = fractions.map { usable * $0 / total }
        // Raise a pane under its minimum, and take the points from the panes that have room to give.
        if minimums.reduce(0, +) <= usable {
            for _ in 0..<lengths.count {
                var missing: CGFloat = 0
                for i in lengths.indices where lengths[i] < minimums[i] { missing += minimums[i] - lengths[i]; lengths[i] = minimums[i] }
                guard missing > 0.5 else { break }
                let room = lengths.indices.map { max(lengths[$0] - minimums[$0], 0) }
                let totalRoom = room.reduce(0, +)
                guard totalRoom > 0 else { break }
                for i in lengths.indices { lengths[i] -= missing * room[i] / totalRoom }
            }
        }
        var position: CGFloat = 0
        isApplying = true
        defer { isApplying = false }
        for index in 0..<(fractions.count - 1) {
            position += lengths[index]
            setPosition(position.rounded(), ofDividerAt: index)
            position += dividerThickness
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let start = dividerIndex == 0 ? 0 : (isVertical ? arrangedSubviews[dividerIndex].frame.minX : arrangedSubviews[dividerIndex].frame.minY)
        return max(proposedMinimumPosition, start + minimums[dividerIndex])
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let next = arrangedSubviews[dividerIndex + 1].frame
        let end = isVertical ? next.maxX : next.maxY
        return min(proposedMaximumPosition, end - minimums[dividerIndex + 1] - dividerThickness)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Only a user drag carries the divider index. Window resizes keep the stored fractions.
        // Snapshot runs and scripted resizes are not the user: they never store a split.
        guard restored, !isApplying, notification.userInfo?["NSSplitViewDividerIndex"] != nil,
              let type = NSApp.currentEvent?.type, type == .leftMouseDragged || type == .leftMouseUp || type == .leftMouseDown else { return }
        let sizes = arrangedSubviews.map { isVertical ? $0.frame.width : $0.frame.height }
        let total = sizes.reduce(0, +)
        guard total > 0 else { return }
        currentFractions = sizes.map { $0 / total }
        UserDefaults.standard.set(sizes.map { Double($0 / total) }, forKey: storageKey)
    }
}
