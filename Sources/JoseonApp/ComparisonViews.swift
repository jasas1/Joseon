import AppKit
import SwiftUI
import JoseonCore
import JoseonRender

extension Color {
    /// The reference "A" everywhere: the calm warm grey-gold of its trace in the spectrum (`#C9B891`).
    static let joseonReference = Color(.sRGB, red: 0xC9 / 255.0, green: 0xB8 / 255.0, blue: 0x91 / 255.0, opacity: 1)
}

// MARK: - Header chip

/// "Compare" with a pin, in the strip next to the level pill and the loudness target. With an active reference it
/// reads `A · 21:42` in the reference gold ("A" = the active reference, never a place in the list). A narrow window shows the pin alone, with a gold dot while a reference
/// is active. A click opens the compare popover.
struct ComparisonChip: View {
    @ObservedObject var controller: ComparisonController
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    /// Narrow window: the icon alone.
    var compact: Bool
    @State private var isOpen = false

    private var spokenValue: String {
        guard let active = controller.active else {
            return controller.references.isEmpty ? "No reference" : "Off. \(controller.references.count) of \(ComparisonController.limit) references kept."
        }
        let mode = controller.effectiveMode(currentHeadphone: model.headphoneModelName) == .headphone ? "headphone difference" : "signal difference"
        return "Live against \(active.snapshot.name), \(mode)" + (settings.comparisonLevelMatch ? ", level-matched" : "")
    }

    private var tooltip: String {
        if let active = controller.active { return "Compare: the live signal against \(active.snapshot.name). Click for the references." }
        return "Compare: keep what plays now as a reference (⌘B), then see the next master, track or headphone against it."
    }

    var body: some View {
        let active = controller.active
        Button(action: { isOpen.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: active == nil ? "pin" : "pin.fill")
                    .font(.system(size: 10.5))
                    .overlay(alignment: .topTrailing) {
                        // Icon only: the dot says "a reference is active". With the text, the text says it.
                        if compact, active != nil {
                            Circle().fill(Color.joseonReference).frame(width: 5, height: 5).offset(x: 3, y: -1.5)
                        }
                    }
                if !compact {
                    Text(active?.activeChipName ?? "Compare")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .lineLimit(1)
                }
            }
            .foregroundStyle(active == nil ? Color.joseonSecondary : Color.joseonReference)
            .padding(.horizontal, compact ? 10 : 8)
            .padding(.vertical, 3)
            .frame(minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.joseonPanel))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(active == nil ? Color.white.opacity(Palette.highContrast ? 0.55 : 0.16) : Color.joseonReference.opacity(Palette.highContrast ? 0.9 : 0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(tooltip)
        .accessibilityLabel("Compare")
        .accessibilityValue(spokenValue)
        .accessibilityHint("Shows the references and the compare options")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            ComparisonPopoverView(controller: controller, model: model, settings: settings)
        }
    }
}

// MARK: - Popover

struct ComparisonPopoverView: View {
    @ObservedObject var controller: ComparisonController
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @State private var renaming: UUID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Compare").font(.headline)
                Spacer()
                Text("References stay in memory only").font(.footnote).foregroundStyle(.secondary)
            }
            Text("A = the active reference  \u{00B7}  B = what plays now")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.joseonReference)
                .accessibilityLabel("A is the active reference. B is what plays now.")
            list
            capture
            Divider()
            options
            Divider()
            hint
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
    }

    // MARK: References

    @ViewBuilder private var list: some View {
        if controller.references.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("No reference yet").font(.system(size: 13, weight: .semibold))
                Text("A reference is a frozen summary of what plays now: the long-term spectrum and the loudness numbers. The live signal is then drawn against it. No audio is kept.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("REFERENCES").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    Text("\(controller.references.count) of \(ComparisonController.limit)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear all") { renaming = nil; controller.clearAll() }
                        .controlSize(.small)
                        .help("Forget every reference")
                }
                .padding(.bottom, 2)
                // Newest first, like the session list.
                ForEach(controller.references.reversed()) { reference in row(reference) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("References")
        }
    }

    private func row(_ reference: ComparisonReference) -> some View {
        let isActive = reference.id == controller.activeID
        return HStack(spacing: 6) {
            if renaming == reference.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFocused)
                    .onSubmit { commitRename(reference) }
                    .onExitCommand { renaming = nil }
                    .accessibilityLabel("New name for \(reference.snapshot.name)")
                Button("Done") { commitRename(reference) }
            } else {
                Button(action: { controller.setActive(isActive ? nil : reference.id) }) {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Color.joseonReference)
                            .opacity(isActive ? 1 : 0)
                            .frame(width: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reference.snapshot.name)
                                .font(.system(size: 12.5, weight: isActive ? .semibold : .regular).monospacedDigit())
                                .foregroundStyle(isActive ? Color.joseonReference : Color.joseonText)
                                .lineLimit(1).truncationMode(.middle)
                            Text(ComparisonController.detailText(reference.snapshot))
                                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isActive ? "The live signal is drawn against this reference. Click to stop comparing." : "Compare the live signal against this reference")
                .accessibilityLabel(reference.snapshot.name)
                .accessibilityValue((isActive ? "Active reference. " : "Not active. ") + ComparisonController.detailText(reference.snapshot))
                .accessibilityHint(isActive ? "Press to stop comparing" : "Press to compare against this reference")
                .accessibilityAddTraits(isActive ? [.isSelected] : [])
                Button(action: { renameText = reference.snapshot.name; renaming = reference.id; renameFocused = true }) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Rename")
                    .accessibilityLabel("Rename \(reference.snapshot.name)")
                Button(action: { controller.delete(reference.id) }) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete this reference")
                    .accessibilityLabel("Delete \(reference.snapshot.name)")
            }
        }
        .controlSize(.small)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isActive ? Color.joseonReference.opacity(0.10) : Color.clear))
    }

    private func commitRename(_ reference: ComparisonReference) {
        controller.rename(reference.id, to: renameText)
        renaming = nil
    }

    // MARK: Capture

    private var captureNote: String {
        if let block = controller.captureBlock { return block.reason }
        if controller.references.count >= ComparisonController.limit {
            return "replaces the oldest inactive reference"
        }
        return "the measurement since the last reset  ·  ⌘B"
    }

    private var capture: some View {
        HStack(spacing: 8) {
            Button(action: { controller.captureReference() }) { Label("Capture reference", systemImage: "pin") }
                .disabled(!controller.canCapture)
                .accessibilityHint(captureNote)
            Text(captureNote)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
    }

    // MARK: Options

    @ViewBuilder private var options: some View {
        let block = controller.headphoneModeBlock(currentHeadphone: model.headphoneModelName)
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $settings.comparisonLevelMatch) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Level-matched")
                    Text("Takes the overall level difference out, so the lane shows the change of tone. The lane prints the removed offset.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("Level-matched")
            .accessibilityHint("Takes the overall level difference out of the difference lane and the band bars")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Difference lane").font(.system(size: 12))
                    Picker("Difference lane", selection: Binding(
                        get: { block == nil && controller.wantsHeadphoneMode },
                        set: { settings.comparisonHeadphoneMode = $0 })) {
                        Text("Signal").tag(false)
                        Text("Headphone").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(block != nil)
                    .accessibilityLabel("Difference lane")
                    .accessibilityValue(block == nil && controller.wantsHeadphoneMode ? "Headphone" : "Signal")
                    .accessibilityHint(block?.reason ?? "Signal: what changed in the music. Headphone: what the other headphone changes at the ear.")
                }
                Text(block.map { "Headphone is off: " + $0.reason.prefix(1).lowercased() + $0.reason.dropFirst() }
                     ?? "Signal: B − A of the music. Headphone: response of \(model.headphoneModelName ?? "B") − \(controller.active?.snapshot.headphoneName ?? "A"), independent of the music.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(block != nil)
            }
        }
    }

    // MARK: Hint

    private var hint: some View {
        VStack(alignment: .leading, spacing: 3) {
            hintLine("Two masters", "capture near the end of master 1, then play master 2.")
            hintLine("Two headphones", "capture, pick another one, set the lane to Headphone.")
            hintLine("Space", "freezes the live side only. A reset keeps the references.")
        }
        .accessibilityElement(children: .combine)
    }

    private func hintLine(_ lead: String, _ text: String) -> some View {
        (Text(lead + ": ").fontWeight(.semibold) + Text(text))
            .font(.system(size: 10.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Menus

/// A menu item that runs a closure and asks two closures for its state, each time the menu opens and each time
/// its key equivalent is pressed. The item is its own target, so nothing else has to keep it alive.
final class LiveClosureMenuItem: NSMenuItem, NSMenuItemValidation {
    private let handler: () -> Void
    /// Nil = enabled. A text = disabled, and the text is the tool tip (the reason).
    var disabledReason: () -> String? = { nil }
    var isChecked: () -> Bool = { false }
    private let baseToolTip: String?

    init(title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], toolTip: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        self.baseToolTip = toolTip
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        self.toolTip = toolTip
        target = self
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func run() {
        guard disabledReason() == nil else { return }
        handler()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let reason = disabledReason()
        state = isChecked() ? .on : .off
        toolTip = reason ?? baseToolTip
        return reason == nil
    }
}

enum ComparisonMenu {
    /// The "Compare" menu of the menu bar.
    static func build(model: @escaping () -> AppModel) -> NSMenu {
        let menu = NSMenu(title: "Compare")
        let capture = LiveClosureMenuItem(title: "Capture Reference", key: "b",
                                          toolTip: "Keep what plays now (the measurement since the last reset) as the reference the live signal is drawn against") {
            model().comparison.captureReference()
        }
        capture.disabledReason = { model().comparison.captureBlock.map { "Capture " + $0.reason } }
        menu.addItem(capture)
        let clear = LiveClosureMenuItem(title: "Clear Active Reference", key: "b", modifiers: [.command, .shift],
                                        toolTip: "Forget the active reference. The comparison ends.") {
            model().comparison.clearActive()
        }
        clear.disabledReason = { model().comparison.active == nil ? "No reference is active" : nil }
        menu.addItem(clear)
        menu.addItem(.separator())
        menu.addItem(levelMatchItem(model: model))
        return menu
    }

    /// "Level-Matched" and the lane mode, for the spectrum card menu.
    static func addToggles(to menu: NSMenu, model: AppModel, header: NSMenuItem) {
        menu.addItem(.separator())
        menu.addItem(header)
        menu.addItem(levelMatchItem(model: { model }))
        let lane = LiveClosureMenuItem(title: "Lane Shows Headphone Difference",
                                       toolTip: "The difference lane shows the response of this headphone minus the reference's headphone, independent of the music") {
            model.settings.comparisonHeadphoneMode.toggle()
        }
        lane.isChecked = { model.comparison.effectiveMode(currentHeadphone: model.headphoneModelName) == .headphone }
        lane.disabledReason = { model.comparison.headphoneModeBlock(currentHeadphone: model.headphoneModelName)?.reason }
        menu.addItem(lane)
    }

    private static func levelMatchItem(model: @escaping () -> AppModel) -> NSMenuItem {
        let item = LiveClosureMenuItem(title: "Level-Matched",
                                       toolTip: "Take the overall level difference out of the difference lane and the band bars") {
            model().settings.comparisonLevelMatch.toggle()
        }
        item.isChecked = { model().settings.comparisonLevelMatch }
        return item
    }
}

// MARK: - Snapshot mode (layout review only)

/// SNAPSHOT MODE ONLY. Pictures of the compare popover in its states. The references in them are MADE UP
/// (`ComparisonController.addSnapshotOnlySeed`) and live in controllers of their own: the app's controller is not touched.
enum ComparisonSnapshotPictures {
    static func steps(model: AppModel) -> [(delay: Double, run: () -> Void)] {
        guard DebugSnapshot.directory != nil, ComparisonController.snapshotSeedMode != nil else { return [] }
        return [(0.3, {
            func popover(_ controller: ComparisonController) -> ComparisonPopoverView {
                ComparisonPopoverView(controller: controller, model: model, settings: model.settings)
            }
            // Empty, and a measurement that is too short.
            let empty = ComparisonController(engine: model.engine, settings: model.settings)
            empty.setSnapshotOnlyCaptureBlock(.tooShort)
            DebugSnapshot.write(swiftUI: popover(empty), name: "ab-popover-empty")

            // Three references, the newest active, with the headphone of now: headphone mode is off, with the reason.
            let same = ComparisonController(engine: model.engine, settings: model.settings)
            same.setSnapshotOnlyCaptureBlock(nil)
            same.addSnapshotOnlySeed(minutesAgo: 31)
            same.addSnapshotOnlySeed(minutesAgo: 12)
            same.addSnapshotOnlySeed(minutesAgo: 0)
            DebugSnapshot.write(swiftUI: popover(same), name: "ab-popover-references")

            // Four references (full), the active one with another headphone: headphone mode is possible.
            let other = ComparisonController(engine: model.engine, settings: model.settings)
            other.setSnapshotOnlyCaptureBlock(nil)
            other.addSnapshotOnlySeed(minutesAgo: 44)
            other.addSnapshotOnlySeed(minutesAgo: 31)
            other.addSnapshotOnlySeed(minutesAgo: 12)
            other.addSnapshotOnlySeed(headphone: .hd800sLike, minutesAgo: 0)
            DebugSnapshot.write(swiftUI: popover(other), name: "ab-popover-headphone")

            // A reference without a headphone, and no reference active.
            let none = ComparisonController(engine: model.engine, settings: model.settings)
            none.setSnapshotOnlyCaptureBlock(.silent)
            none.addSnapshotOnlySeed(minutesAgo: 5, activate: false)
            DebugSnapshot.write(swiftUI: popover(none), name: "ab-popover-inactive")

            // Self-check of the real capture path, from the live demo frame: five captures into four places.
            let real = ComparisonController(engine: model.engine, settings: model.settings)
            real.sourceName = { SignalState.demo.label }
            let first = real.captureReference()
            for _ in 0..<4 { real.captureReference() }
            let lettered = real.references.contains { name in ["A ", "B ", "C ", "D "].contains { name.snapshot.name.hasPrefix($0) } }
            print("compare self-check: first \(first?.snapshot.name ?? "nil"), \(Int(first?.snapshot.measuredSeconds ?? 0)) s, tilt \(first?.snapshot.tiltDBPerOctave ?? -1), bins \(first?.snapshot.averageDB.count ?? 0); kept \(real.references.count) of \(ComparisonController.limit), chip \(real.active?.activeChipName ?? "-"), names without a letter: \(lettered ? "FAIL" : "ok")")
            real.delete(real.activeID ?? UUID())
            print("compare self-check: after delete of the active one: kept \(real.references.count), active \(real.active == nil ? "none" : "some")")

            // The chip in its four forms, as the strip shows it.
            for (name, controller) in [("idle", empty), ("active", same)] {
                for compact in [false, true] {
                    DebugSnapshot.write(swiftUI: ComparisonChip(controller: controller, model: model, settings: model.settings, compact: compact).padding(6),
                                        name: "ab-chip-\(name)\(compact ? "-compact" : "")")
                }
            }
        })]
    }
}
