import SwiftUI
import ServiceManagement

/// Launch at login through SMAppService. Works only from the bundled Joseon.app.
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var message: String?

    /// `swift run` has no app bundle: SMAppService cannot register a bare executable.
    let isAvailable: Bool = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil

    init() { refresh() }

    func refresh() {
        guard isAvailable else {
            message = "Launch at login is available when Joseon runs as an installed app."
            return
        }
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        message = status == .requiresApproval ? "Approve Joseon under System Settings → General → Login Items." : nil
    }

    func setEnabled(_ on: Bool) {
        guard isAvailable else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refresh()
        } catch {
            refresh()
            message = "Joseon could not change the login item. \(error.localizedDescription)"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    var openCalibration: () -> Void = {}
    var openMeasure: () -> Void = {}
    @StateObject private var loginItem = LoginItem()

    var body: some View {
        Form {
            Section {
                Picker("Resolution", selection: $settings.displayBins) {
                    ForEach(AppSettings.binChoices, id: \.self) { Text("\(String($0)) points").tag($0) }
                }
                .help("Number of points in the spectrum curve. More points show finer detail.")
                LabeledSlider(title: "Release time", value: $settings.releaseSeconds, range: 0.05...2.0, step: 0.05,
                              text: NumberText.signed(settings.releaseSeconds, decimals: 2) + " s")
                LabeledSlider(title: "Peak decay", value: $settings.peakDecayDBPerSecond, range: 3...48, step: 1,
                              text: NumberText.signed(settings.peakDecayDBPerSecond, decimals: 0) + " dB/s")
                Picker("Tilt", selection: $settings.tiltDBPerOctave) {
                    ForEach(AppSettings.tiltChoices, id: \.self) { Text(MainWindowController.tiltTitle($0)).tag($0) }
                }
                .help("Tilt raises the high frequencies on the display. With 4.5 dB per octave most music looks flat.")
                Picker("Level range", selection: Binding(get: { settings.levelRangeChoice }, set: { settings.levelRangeChoice = $0 })) {
                    Text("Auto").tag(0)
                    ForEach(AppSettings.dbRangeChoices, id: \.self) { Text("\($0) dB").tag($0) }
                }
                .help("Auto: a 72 dB window that follows the level of the music. A fixed range shows 0 dBFS down to that level.")
                Toggle("Compare level-matched", isOn: $settings.comparisonLevelMatch)
                    .help("A/B compare: take the overall level difference out, so the difference lane shows the change of tone")
            } header: { SettingsSectionHeader(title: "Spectrum") }
            .listRowBackground(Color.joseonPanel)

            Section {
                Picker("Headphone", selection: $settings.headphoneName) {
                    Text("None").tag("")
                    ForEach(model.curves, id: \.name) { Text($0.name).tag($0.name) }
                }
                Picker("Target", selection: Binding(
                    get: { model.currentTargetName ?? "" },
                    set: { settings.targetName = $0 })) {
                    if model.targets.isEmpty { Text("None").tag("") }
                    ForEach(model.targets, id: \.name) { Text($0.name).tag($0.name) }
                }
                .disabled(model.targets.isEmpty)
                Button("Import curve…") { model.runImportPanel() }
            } header: { SettingsSectionHeader(title: "Headphones") }
            .listRowBackground(Color.joseonPanel)

            SPLSettingsSection(controller: model.spl, openCalibration: openCalibration, openMeasure: openMeasure)

            Section {
                Picker("Loudness target", selection: $settings.loudnessTarget) {
                    ForEach(LoudnessTarget.allCases) { Text($0.title).tag($0) }
                }
                .help("Joseon shows how far the integrated loudness is over or under this level")
                Toggle("Reset measurement when audio resumes after silence longer than 2 s", isOn: $settings.autoResetAfterSilence)
                    .help("A new track or album starts a new measurement")
            } header: { SettingsSectionHeader(title: "Loudness") }
            .listRowBackground(Color.joseonPanel)

            Section {
                Picker("Mini graph width", selection: $settings.miniGraphWidth) {
                    ForEach(AppSettings.miniWidthChoices, id: \.self) { Text("\($0) pt").tag($0) }
                }
                Picker("Menu bar graph color", selection: $settings.miniGraphColor) {
                    ForEach(MiniGraphColor.allCases) { Text($0.title).tag($0) }
                }
                .help("Template follows the menu bar: white on a dark menu bar, black on a light one")
                Toggle("Show Dock icon", isOn: $settings.showDockIcon)
                    .help("When off, Joseon shows only in the menu bar")
            } header: { SettingsSectionHeader(title: "Menu bar") }
            .listRowBackground(Color.joseonPanel)

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }))
                    .disabled(!loginItem.isAvailable)
                if let message = loginItem.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Demo mode", isOn: $settings.demoMode)
                    .help("Show a synthetic signal in place of the audio of this Mac")
                Text("Audio never leaves this Mac and is never recorded.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { SettingsSectionHeader(title: "General") }
            .listRowBackground(Color.joseonPanel)
        }
        .formStyle(.grouped)
        // The look of the main window: navy ground, the panels' card color for the groups, the app accent.
        // The controls stay the native ones, so keyboard access and VoiceOver work as in every Settings window.
        .scrollContentBackground(.hidden)
        .background(Color.joseonBackground)
        .tint(Color.joseonAccent)
        .foregroundStyle(Color.joseonText)
        .environment(\.colorScheme, .dark)
        .frame(width: 460, height: 720)
        .onAppear { loginItem.refresh() }
    }
}

/// Section title in the style of the panel card titles: small capitals, secondary color.
struct SettingsSectionHeader: View {
    var title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.4)
            .foregroundStyle(Color.joseonSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

struct LabeledSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var text: String

    var body: some View {
        LabeledContent(title) {
            HStack {
                // Rounds to the step in the binding: a stepped SwiftUI slider draws a row of tick marks.
                Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                    .frame(minWidth: 160)
                    .accessibilityLabel(title)
                    .accessibilityValue(text)
                Text(text)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.joseonAccent)
                    .accessibilityHidden(true)
                Text("Welcome to Joseon").font(.title2.weight(.semibold))
            }
            point("chart.xyaxis.line", "See what is in the music",
                  "Joseon shows the spectrum, loudness and stereo field of the audio this Mac plays, and what your headphones must deliver.")
            point("lock.shield", "Audio stays on this Mac",
                  "Joseon reads the audio only to draw it. Audio never leaves this Mac and is never recorded.")
            point("hand.raised", "macOS asks for one permission",
                  "After you continue, macOS asks to allow “System Audio Recording”. Joseon needs it to read the audio. You can change it later in System Settings → Privacy & Security.")
            HStack {
                Spacer()
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(Color.joseonAccent)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
