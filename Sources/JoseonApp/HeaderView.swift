import SwiftUI
import JoseonCore
import JoseonHeadphones

/// Actions the SwiftUI views send to the shell.
struct ShellActions {
    var openMainWindow: () -> Void = {}
    var openSettings: () -> Void = {}
    var openPrivacySettings: () -> Void = {}
    var openCalibration: () -> Void = {}
    var quit: () -> Void = {}
}

/// Header strip + banners + stress-flag strip at the top of the main window.
struct TopAreaView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var windowState: MainWindowState
    var actions: ShellActions

    static let headerHeight: CGFloat = 52
    static let bannerHeight: CGFloat = 38
    static let flagStripHeight: CGFloat = 34
    static func height(banners: Int) -> CGFloat { headerHeight + CGFloat(banners) * bannerHeight + flagStripHeight }

    var body: some View {
        VStack(spacing: 0) {
            HeaderStrip(model: model, settings: settings, leadingInset: windowState.isFullScreen ? 14 : 80)
                .frame(height: Self.headerHeight)
            if let error = model.captureError {
                BannerView(
                    symbol: "exclamationmark.triangle.fill", tint: .joseonWarn,
                    text: "Audio capture did not start: \(error). Joseon shows a demo signal.",
                    primaryTitle: "Retry", primary: { model.restartSource() },
                    secondaryTitle: "Dismiss", secondary: { model.dismissCaptureError() })
            }
            if model.showPermissionBanner {
                BannerView(
                    symbol: "speaker.slash.fill", tint: .joseonWarn,
                    text: "An app plays, but no audio arrives. Allow Joseon under System Audio Recording.",
                    primaryTitle: "Open Privacy Settings", primary: actions.openPrivacySettings,
                    secondaryTitle: "Retry", secondary: { model.restartSource() },
                    onClose: { model.dismissPermissionBanner() })
            }
            if let banner = model.spl.doseBanner {
                // Calm, in the app only, once per day and mark. No system notification.
                BannerView(
                    symbol: "ear", tint: banner.mark >= 100 ? .joseonWarn : .joseonAccent,
                    text: banner.text,
                    primaryTitle: "OK", primary: { model.spl.dismissDoseBanner() })
            }
            StressFlagStrip(model: model, settings: settings, spl: model.spl, actions: actions)
                .frame(height: Self.flagStripHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.joseonBackground)
        .ignoresSafeArea()
        .transaction { t in if Palette.reduceMotion { t.animation = nil } }
    }
}

// MARK: - Header

/// How much room the header has. ViewThatFits picks the first level that fits, so no control truncates.
enum HeaderDensity {
    /// Headphone and target pickers with names, "Reset measurement" with its label.
    case full
    /// The same pickers, reset as an icon.
    case medium
    /// One "Headphones" menu button (headphone + target + import) with the headphone name, reset as an icon.
    case combined
    /// The "Headphones" menu button as an icon, reset as an icon.
    case narrow
}

struct HeaderStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    var leadingInset: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(.full)
            content(.medium)
            content(.combined)
            content(.narrow)
        }
    }

    private func content(_ density: HeaderDensity) -> some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: leadingInset - 10, height: 1).accessibilityHidden(true)
            StateBadge(state: model.header.state)
            // ViewThatFits measures the full text width: it picks a level where the stream facts show whole.
            // Only the narrow level, with very long names, shortens the first fact.
            StreamBlock(header: model.header)
                .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            if model.isFrozen { PausedPill(model: model) }
            Picker("Layout", selection: $settings.layoutPreset) {
                ForEach(LayoutPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Layout preset")
            .help("Layout: ⌘1 Essential, ⌘2 Spectrum, ⌘3 Metering")

            if density == .narrow || density == .combined {
                HeadphonesMenu(model: model, settings: settings, showsName: density == .combined)
            } else {
                HeadphoneMenu(model: model, settings: settings)
                TargetMenu(model: model, settings: settings)
            }

            SessionButton(model: model, showsTitle: density == .full)

            Button(action: { model.resetMeasurement() }) {
                if density == .full {
                    Label("Reset measurement", systemImage: "arrow.counterclockwise")
                } else {
                    Image(systemName: "arrow.counterclockwise")
                }
            }
            .help("Reset measurement (R): integrated loudness, maximum values, average spectrum. The track summary goes to the session list.")
            .accessibilityLabel("Reset measurement")
            .fixedSize()
        }
        .padding(.trailing, 12)
        .controlSize(.regular)
    }
}

/// Two lines: the apps that play (or "Waiting for audio"), then device · sample rate · bit depth.
struct StreamBlock: View {
    var header: HeaderState

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(header.headline)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(header.state == .demo && header.notice == nil ? Color(nsColor: Palette.demo) : Color.joseonText)
                .lineLimit(1)
                .truncationMode(.tail)
            if !header.facts.isEmpty, header.notice == nil {
                // Only the first fact (app or device name) may shorten. Sample rate and bit depth never do.
                HStack(spacing: 0) {
                    ForEach(Array(header.facts.enumerated()), id: \.offset) { index, fact in
                        Text(index == 0 ? fact : "  ·  " + fact)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(index == 0 ? 0 : Double(index))
                            .fixedSize(horizontal: index >= max(header.facts.count - 2, 1), vertical: false)
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color.joseonSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stream")
        .accessibilityValue(header.spoken)
        .help(header.spoken)
    }
}

struct StateBadge: View {
    var state: SignalState

    private var color: Color {
        switch state {
        case .live: return Color(nsColor: Palette.live)
        case .silent: return Color.joseonSecondary
        case .demo: return Color(nsColor: Palette.demo)
        case .waiting: return Color.joseonAccent
        }
    }

    /// The silent, the starting and the demo state have their text in the stream block: one phrase, one place.
    private var showsLabel: Bool { state == .live }

    var body: some View {
        HStack(spacing: 5) {
            // Shape differs by state, so the state does not depend on color alone.
            Group {
                switch state {
                case .live: Circle().fill(color)
                case .silent: Circle().strokeBorder(color, lineWidth: 1.5)
                case .demo: RoundedRectangle(cornerRadius: 2).fill(color)
                case .waiting: Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2]))
                }
            }
            .frame(width: 9, height: 9)
            if showsLabel {
                Text(state.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.joseonSecondary)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal state")
        .accessibilityValue(state.label)
        .help(state == .demo ? "Joseon shows a synthetic signal, not the audio of this Mac." : state.label)
    }
}

/// The one "Paused" sign of a frozen display. The panel cards dim, they carry no tag of their own.
struct PausedPill: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button(action: { model.toggleFreeze() }) {
            HStack(spacing: 4) {
                Image(systemName: "pause.fill").font(.system(size: 8.5, weight: .bold))
                Text("Paused").font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Color.joseonAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.joseonAccent.opacity(0.16)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.joseonAccent.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("The display is frozen. The measurement goes on. Click or press Space to continue.")
        .accessibilityLabel("Display paused")
        .accessibilityHint("Press to continue")
    }
}

/// The headphone list: "None", the library, "Import curve…". Shared by every headphone menu.
struct HeadphoneChoices: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        let currentName = model.headphoneModelName
        Button(action: { model.selectHeadphone(named: nil) }) { checked("None", currentName == nil) }
        ForEach(model.curves, id: \.name) { curve in
            Button(action: { model.selectHeadphone(named: curve.name) }) { checked(curve.name, currentName == curve.name) }
        }
    }
}

struct TargetChoices: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let current = model.currentTargetName
        if model.targets.isEmpty {
            Text("No target curves in the library")
        }
        ForEach(model.targets, id: \.name) { target in
            Button(action: { model.selectTarget(named: target.name) }) { checked(target.name, current == target.name) }
        }
    }
}

struct HeadphoneMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Menu {
            HeadphoneChoices(model: model, settings: settings)
            Divider()
            Button("Import curve…") { model.runImportPanel() }
            Button("Measure your headphone…") { model.openMeasure() }
        } label: {
            Label(model.headphoneModelName ?? "No headphone", systemImage: "headphones")
        }
        .fixedSize()
        .help("Headphone response for the overlay and the stress flags")
        .accessibilityLabel("Headphone")
        .accessibilityValue(model.headphoneModelName ?? "None")
    }
}

struct TargetMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        let current = model.currentTargetName
        Menu {
            TargetChoices(model: model)
        } label: {
            Label(current ?? "No target", systemImage: "scope")
        }
        .fixedSize()
        .help("Target curve for the headphone overlay")
        .accessibilityLabel("Target curve")
        .accessibilityValue(current ?? "None")
    }
}

/// Narrow header: one menu button for the headphone, the target curve and the import.
struct HeadphonesMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    var showsName = false

    private var summary: String {
        "Headphone: \(model.headphoneModelName ?? "None"). Target curve: \(model.currentTargetName ?? "None")."
    }

    var body: some View {
        Menu {
            Section("Headphone") { HeadphoneChoices(model: model, settings: settings) }
            Section("Target curve") { TargetChoices(model: model) }
            Divider()
            Button("Import curve…") { model.runImportPanel() }
            Button("Measure your headphone…") { model.openMeasure() }
        } label: {
            if showsName {
                Label(model.headphoneModelName ?? "No headphone", systemImage: "headphones")
            } else {
                Image(systemName: "headphones")
            }
        }
        .fixedSize()
        .help(summary)
        .accessibilityLabel("Headphones")
        .accessibilityValue(summary)
    }
}

@ViewBuilder
private func checked(_ title: String, _ on: Bool) -> some View {
    if on { Label(title, systemImage: "checkmark") } else { Text(title) }
}

// MARK: - Banner

struct BannerView: View {
    var symbol: String
    var tint: Color
    var text: String
    var primaryTitle: String
    var primary: () -> Void
    var secondaryTitle: String?
    var secondary: () -> Void = {}
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.joseonText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(primaryTitle, action: primary)
            if let secondaryTitle { Button(secondaryTitle, action: secondary) }
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
                    .help("Dismiss")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: TopAreaView.bannerHeight)
        .background(tint.opacity(0.13))
        .overlay(alignment: .bottom) { Rectangle().fill(tint.opacity(0.4)).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Stress flags and loudness target

/// The strip under the header: headphone stress on the left, loudness against the target on the right.
struct StressFlagStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var spl: SPLController
    var actions: ShellActions

    /// Under this strip width every state of the level pill takes its shortest form.
    static let compactWidth: CGFloat = 1000

    var body: some View {
        GeometryReader { proxy in strip(compact: proxy.size.width < Self.compactWidth) }
    }

    private func strip(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Text("HEADPHONE STRESS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.joseonSecondary)
                .fixedSize()
                .accessibilityHidden(true)
            stress
            // The chip row takes the free width itself.
            if model.headphoneModelName == nil || model.stressFlags.isEmpty { Spacer(minLength: 0) }
            ComparisonChip(controller: model.comparison, model: model, settings: settings, compact: compact)
            SPLPill(controller: spl, actions: actions, compact: compact)
            // Less clutter by default: with the target Off the control folds into the menu of the meters card
            // ("Loudness Target") and into Settings. With a target set it shows here, with the difference.
            if settings.loudnessTarget != .off { LoudnessTargetControl(model: model, settings: settings) }
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
        .background(Color.joseonPanel.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: Palette.cardBorder)).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Palette.cardBorder)).frame(height: 1) }
    }

    @ViewBuilder private var stress: some View {
        if model.headphoneModelName == nil {
            // The short text comes second: ViewThatFits uses it when the window is narrow.
            ViewThatFits(in: .horizontal) {
                quiet("Pick a headphone to see how it handles this music")
                quiet("Pick a headphone")
            }
            Menu {
                HeadphoneChoices(model: model, settings: settings)
                Divider()
                Button("Import curve…") { model.runImportPanel() }
                Button("Measure your headphone…") { model.openMeasure() }
            } label: {
                Text("Choose headphone…")
            }
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Choose headphone")
            .help("Choose the headphone you listen on")
        } else if model.stressFlags.isEmpty, model.header.state == .silent || model.header.state == .waiting {
            // Nothing was measured yet: no green tick, it would reassure falsely.
            quiet("Stress check waits for audio  ·  \(model.headphoneModelName ?? "")")
                .accessibilityLabel("Headphone stress")
                .accessibilityValue("Waiting for audio")
        } else if model.stressFlags.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Palette.live))
                    .accessibilityHidden(true)
                quiet("No stress flags")
                quiet("·  \(model.headphoneModelName ?? "")").layoutPriority(-1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Headphone stress")
            .accessibilityValue("No stress flags for \(model.headphoneModelName ?? "the headphone")")
            .help("Joseon checks this music against the \(model.headphoneModelName ?? "headphone") response. A chip shows here when the music asks a lot of the headphone.")
        } else {
            // Whole chips only: the chips that do not fit go into one "+N" chip with a list.
            GeometryReader { proxy in
                let split = StressChipLayout.split(model.stressFlags, width: proxy.size.width)
                HStack(spacing: StressChipLayout.spacing) {
                    ForEach(split.shown) { flag in
                        StressChip(flag: flag, modelName: model.headphoneModelName)
                    }
                    if !split.hidden.isEmpty {
                        StressOverflowChip(flags: split.hidden, showsPlus: !split.shown.isEmpty, modelName: model.headphoneModelName)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Headphone stress flags")
        }
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Color.joseonSecondary)
            .lineLimit(1)
    }
}

/// "I −11.5 · +2.5 LU over target" and the "Loudness target" menu.
struct LoudnessTargetControl: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 8) {
            if let delta = model.loudnessDelta {
                Text(delta.text)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(delta.relation == .over ? Color.joseonWarn : (delta.relation == .none ? Color.joseonSecondary : Color.joseonText))
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityLabel("Loudness against target")
                    .accessibilityValue(delta.spoken)
                    .help("Integrated loudness since the last reset, against the loudness target. A streaming service turns a louder track down by about this amount.")
            }
            Menu {
                Picker("Loudness target", selection: $settings.loudnessTarget) {
                    ForEach(LoudnessTarget.allCases) { target in
                        Text(target.title).tag(target)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(settings.loudnessTarget.shortTitle, systemImage: "target")
            }
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Loudness target")
            .accessibilityValue(settings.loudnessTarget.title)
            .help("Loudness target: compare the integrated loudness with a streaming or broadcast level")
        }
        .fixedSize()
    }
}

/// Decides which chips show whole. Chip widths come from the text metrics, so the result needs no layout pass
/// and a chip never truncates.
enum StressChipLayout {
    static let spacing: CGFloat = 6
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// Icon 10 pt (about 13 wide) + gap 4 + padding 8 + 8, and one point of rounding room.
    static let chrome: CGFloat = 13 + 4 + 16 + 1

    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    static func chipWidth(_ flag: StressFlag) -> CGFloat { textWidth(flag.title) + chrome }
    static func overflowWidth(count: Int, plus: Bool) -> CGFloat { textWidth(overflowTitle(count: count, plus: plus)) + chrome }
    static func overflowTitle(count: Int, plus: Bool) -> String { plus ? "+\(count)" : (count == 1 ? "1 flag" : "\(count) flags") }

    /// Flags arrive highest severity first, so the chips that show are the ones that matter most.
    static func split(_ flags: [StressFlag], width: CGFloat) -> (shown: [StressFlag], hidden: [StressFlag]) {
        var used: CGFloat = 0
        var count = 0
        for (index, flag) in flags.enumerated() {
            let w = chipWidth(flag) + (index == 0 ? 0 : spacing)
            let rest = flags.count - index - 1
            let reserve = rest > 0 ? spacing + overflowWidth(count: rest, plus: true) : 0
            if used + w + reserve > width { break }
            used += w
            count += 1
        }
        return (Array(flags.prefix(count)), Array(flags.dropFirst(count)))
    }
}

extension StressFlag.Severity {
    var color: Color {
        switch self {
        case .info: return .joseonAccent
        case .watch: return .joseonWarn
        case .high: return .joseonDanger
        }
    }
    var symbol: String {
        switch self {
        case .info: return "info.circle.fill"
        case .watch: return "exclamationmark.triangle.fill"
        case .high: return "exclamationmark.octagon.fill"
        }
    }
    var name: String {
        switch self {
        case .info: return "Info"
        case .watch: return "Watch"
        case .high: return "High"
        }
    }
}

/// "+2": the flags that do not fit in the strip. A click shows them as a list.
struct StressOverflowChip: View {
    var flags: [StressFlag]
    /// False when no chip shows at all: the chip then reads "3 flags".
    var showsPlus: Bool
    var modelName: String?
    @State private var showList = false

    private var top: StressFlag.Severity { flags.map(\.severity).max { $0.rawValue < $1.rawValue } ?? .info }

    var body: some View {
        let color = top.color
        Button(action: { showList.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: top.symbol).font(.system(size: 10))
                Text(StressChipLayout.overflowTitle(count: flags.count, plus: showsPlus))
                    .font(.system(size: 11, weight: .medium).monospacedDigit()).lineLimit(1)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(flags.map(\.title).joined(separator: ", "))
        .accessibilityLabel(flags.count == 1 ? "1 more stress flag" : "\(flags.count) more stress flags")
        .accessibilityValue(flags.map { "\($0.severity.name): \($0.title)" }.joined(separator: ", "))
        .accessibilityHint("Press to show the list")
        .popover(isPresented: $showList, arrowEdge: .bottom) { StressFlagList(flags: flags, modelName: modelName) }
    }
}

/// The list behind the "+N" chip.
struct StressFlagList: View {
    var flags: [StressFlag]
    var modelName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(flags) { flag in
                VStack(alignment: .leading, spacing: 3) {
                    Label(flag.title, systemImage: flag.severity.symbol)
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(flag.severity.color)
                    Text(flag.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if let modelName {
                Text("Headphone model: \(modelName)").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }
}

struct StressChip: View {
    var flag: StressFlag
    var modelName: String?
    @State private var showDetail = false

    private var color: Color { flag.severity.color }
    private var symbol: String { flag.severity.symbol }
    private var severityName: String { flag.severity.name }

    var body: some View {
        Button(action: { showDetail.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(flag.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(color.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(flag.detail)
        .accessibilityLabel("\(severityName): \(flag.title)")
        .accessibilityHint("\(flag.detail) Press to show the detail.")
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Label(flag.title, systemImage: symbol).font(.headline).foregroundStyle(color)
                Text(flag.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let modelName {
                    Text("Headphone model: \(modelName)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
        }
    }
}
