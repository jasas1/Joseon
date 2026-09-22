import SwiftUI
import JoseonCore

/// The noise dose as a ring: empty at 0%, closed at 100%. The color steps at 50% and 100%, and the popover says
/// the percentage, so the state does not depend on color alone.
struct DoseRing: View {
    var percent: Int
    var size: CGFloat = 14

    private var color: Color { percent >= 100 ? .joseonDanger : (percent >= 50 ? .joseonWarn : .joseonAccent) }

    var body: some View {
        ZStack {
            Circle().stroke(Color.joseonSecondary.opacity(0.35), lineWidth: 2.5)
            Circle().trim(from: 0, to: CGFloat(min(max(percent, 0), 100)) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if percent >= 100 {
                Circle().fill(color).frame(width: size * 0.36, height: size * 0.36)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "≈ 78 dB(A)" with the dose ring, in the strip next to the loudness target. A click opens the popover.
struct SPLPill: View {
    @ObservedObject var controller: SPLController
    var actions: ShellActions
    /// Narrow window: the shortest form of every state.
    var compact: Bool
    @State private var isOpen = false

    static let setUpTitle = "Level at ear: set up\u{2026}"
    /// Beside the ear glyph, in a narrow window.
    static let setUpTitleCompact = "set up"

    private var state: SPLHeaderState { controller.header }

    private var title: String {
        switch state.status {
        case .calibrated: return "≈ \(state.levelText ?? "—") dB(A)"
        case .muted: return "Muted"
        // One name while the level is not set up, whatever is missing: the popover says what.
        case .notCalibrated, .sensitivityUnknown, .noHeadphone, .estimatorUnavailable: return compact ? Self.setUpTitleCompact : Self.setUpTitle
        }
    }

    private var spokenValue: String {
        guard state.status.isCalibrated else { return state.status.summary }
        let level = state.levelText.map { "about \($0) dB A" } ?? "no audio now"
        let dose = state.standard == .nioshDaily ? "Dose today \(state.dosePercent) percent" : "Dose this week \(state.dosePercent) percent"
        return "\(level), \(state.uncertaintyText). \(dose). Calibration \(state.calibrationName)."
    }

    private var tooltip: String {
        guard state.status.isCalibrated else { return "Sound level at the ear. \(state.status.summary) Click for details." }
        let dose = state.standard == .nioshDaily ? "Dose today (NIOSH) \(state.dosePercent)%" : "Dose this week (WHO) \(state.dosePercent)%"
        return "Estimated sound level at the ear, A-weighted, slow. \(dose). Calibration: \(state.calibrationName), \(state.uncertaintyText). Click for details."
    }

    var body: some View {
        Button(action: { isOpen.toggle() }) {
            HStack(spacing: 5) {
                if state.status.isCalibrated {
                    DoseRing(percent: state.dosePercent)
                } else {
                    Image(systemName: "ear").font(.system(size: 10.5))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(state.status.isCalibrated ? Color.joseonText : Color.joseonSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.joseonPanel))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(Palette.highContrast ? 0.55 : 0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(tooltip)
        .accessibilityLabel("Sound level at the ear")
        .accessibilityValue(spokenValue)
        .accessibilityHint("Shows levels, noise dose and calibration")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SPLPopoverView(controller: controller, openCalibration: { isOpen = false; actions.openCalibration() })
        }
    }
}

/// Levels, dose, calibration and the two actions. Reads the engine twice per second while it is open.
struct SPLPopoverView: View {
    @ObservedObject var controller: SPLController
    var openCalibration: () -> Void
    /// False in snapshot mode: draw once, without a timer.
    var isLive = true
    @State private var confirmReset = false

    var body: some View {
        Group {
            if isLive {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in content(controller.latestReading) }
            } else {
                content(controller.latestReading)
            }
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
    }

    @ViewBuilder private func content(_ reading: SPLReading?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sound level at the ear").font(.headline)
                Spacer()
                Text("Estimate").font(.footnote).foregroundStyle(.secondary)
            }
            switch controller.status {
            case .calibrated: calibrated(reading)
            case .sensitivityUnknown(let headphone):
                explain("Joseon does not know the sensitivity of \(headphone).",
                        "The sensitivity says how loud the headphone plays for one volt. It is on the data sheet of the headphone.")
                if let note = SPLWiring.unlistedReason(forHeadphoneNamed: headphone) {
                    Text(note.reason + " If the maker means dB per milliwatt (the usual reading for this kind of figure), choose the unit dB/mW and enter the impedance. Joseon shows the source as \"User\".")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                SensitivityEditor(controller: controller)
                Button("Set up level at the ear…", action: openCalibration)
                    .help("One window: the sensitivity of the headphone, then the voltage calibration")
            case .notCalibrated:
                explain(controller.status.summary,
                        "Joseon can not see the volume knob of your amplifier. One calibration (a multimeter measurement, values from the data sheets, or the macOS volume) tells it how many volts reach the headphone.")
                Button("Set up level at the ear…", action: openCalibration).keyboardShortcut(.defaultAction)
            case .noHeadphone:
                explain("No headphone chosen.", controller.status.summary)
            case .muted:
                explain(controller.status.summary, "The level estimate is back when the output plays again.")
            case .estimatorUnavailable:
                explain(controller.status.summary, "The calibration and the sensitivity are stored. This build can not turn them into a level.")
            }
            if controller.status != .noHeadphone, !controller.status.isCalibrated, controller.status != .sensitivityUnknown(headphone: controller.headphoneName) {
                sensitivityLine
            }
        }
    }

    private func explain(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func calibrated(_ reading: SPLReading?) -> some View {
        let live = reading.flatMap { $0.levelASlow > 20 ? $0 : nil }
        HStack(alignment: .top, spacing: 0) {
            number("SLOW", live?.levelASlow, "now, 1 s")
            number("FAST", live?.levelAFast, "now, 125 ms")
            number("LEQ TRACK", reading?.leqATrack, "average")
            number("LEQ SESSION", reading?.leqASession, "average")
            number("MAX", reading?.maxAFast, "this track")
        }
        Text("dB(A), diffuse-field equivalent, louder ear. \(controller.header.uncertaintyText).")
            .font(.footnote).foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 8) {
            dose(.nioshDaily, title: "Today", fraction: controller.doseToday, level: live?.levelASlow)
            dose(.whoWeekly, title: "This week", fraction: controller.doseWeek, level: live?.levelASlow)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.joseonPanel))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: Palette.cardBorder), lineWidth: 1))

        if let preset = controller.activePreset {
            VStack(alignment: .leading, spacing: 3) {
                line("Calibration", preset.name)
                // The total and its two parts, in one line: the voltage term alone is not the uncertainty of the level.
                line("Uncertainty", controller.uncertaintyPartsText ?? controller.header.uncertaintyText)
                line("Method", preset.methodTitle + (preset.knobNote.isEmpty ? "" : " · knob at \(preset.knobNote)"))
                line("Output", preset.deviceName)
                sensitivityLine
            }
        }
        HStack {
            Button("Calibrate…", action: openCalibration)
            Spacer()
            if confirmReset {
                Text("Clear today and this week?").font(.footnote).foregroundStyle(.secondary)
                Button("Clear") { controller.resetDose(); confirmReset = false }
                Button("Keep") { confirmReset = false }
            } else {
                Button("Reset dose") { confirmReset = true }
                    .help("Clear the noise dose of today and of this week, and the session average")
            }
        }
        .controlSize(.small)
    }

    private var sensitivityLine: some View { line("Sensitivity", controller.sensitivityText) }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5))
        .accessibilityElement(children: .combine)
    }

    private func number(_ label: String, _ value: Float?, _ caption: String) -> some View {
        let text = value.flatMap { $0 > 20 ? String(Int($0.rounded())) : nil } ?? "—"
        return VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 19, weight: .medium).monospacedDigit())
            Text(caption).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.capitalized)
        .accessibilityValue(text == "—" ? "no value" : "about \(text) dB A")
    }

    private func dose(_ standard: DoseStandard, title: String, fraction: Double, level: Float?) -> some View {
        let percent = Int((fraction * 100).rounded())
        return HStack(alignment: .center, spacing: 10) {
            DoseRing(percent: percent, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(title): \(percent)% used").font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Text("\u{00B7} " + controller.timeLeftText(standard, levelA: level)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Text("\(standard == .nioshDaily ? "NIOSH" : "WHO / ITU H.870"): \(standard.detail)")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Noise dose, \(title.lowercased())")
        .accessibilityValue("\(percent) percent used, \(controller.timeLeftText(standard, levelA: level)). Limit: \(standard.detail).")
    }
}

/// Settings → "Level at the ear".
struct SPLSettingsSection: View {
    @ObservedObject var controller: SPLController
    var openCalibration: () -> Void
    var openMeasure: () -> Void = {}
    @State private var renaming: UUID?
    @State private var renameText = ""

    private var devicePresets: [CalibrationPreset] { controller.store.presets.sorted { $0.created > $1.created } }

    var body: some View {
        Section {
            LabeledContent("Status") {
                Text(controller.status.isCalibrated ? "Calibrated · \(controller.header.calibrationName) · \(controller.header.uncertaintyText)" : controller.status.summary)
                    .foregroundStyle(.secondary).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Active calibration", selection: Binding(
                get: { controller.store.rememberedPreset(device: controller.deviceName)?.id },
                set: { id in controller.store.activate(controller.store.presets.first { $0.id == id }, device: controller.deviceName) })) {
                Text("None").tag(UUID?.none)
                ForEach(controller.store.presets(forDevice: controller.deviceName)) { preset in
                    Text(preset.name + (preset.headphoneName == controller.headphoneName ? "" : "  (for \(preset.headphoneName))")).tag(UUID?.some(preset.id))
                }
            }
            .help("Calibrations made for \(controller.deviceName.isEmpty ? "this output" : controller.deviceName). A calibration counts only with the headphone it was made for.")
            Button("Set up level at the ear…", action: openCalibration)
                .help("One window: the sensitivity of the headphone, then the voltage calibration")

            if !devicePresets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stored calibrations").font(.callout)
                    ForEach(devicePresets) { preset in presetRow(preset) }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Headphone sensitivity").font(.callout)
                SensitivityEditor(controller: controller)
            }
            VStack(alignment: .leading, spacing: 4) {
                Button("Measure your headphone…", action: openMeasure)
                Text("With a measurement microphone and a coupler or a flat-plate rig: the response of your own unit, and its sensitivity.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Picker("Dose in the header", selection: Binding(get: { controller.store.doseStandard }, set: { controller.store.doseStandard = $0 })) {
                ForEach(DoseStandard.allCases) { Text($0.title).tag($0) }
            }
            .help("NIOSH: 85 dB(A) for 8 hours per day. WHO / ITU H.870: 80 dB(A) for 40 hours per week. Both count with 3 dB per doubling.")
            LabeledContent("Dose") {
                HStack {
                    Text("Today \(Int((controller.doseToday * 100).rounded()))% · this week \(Int((controller.doseWeek * 100).rounded()))%")
                        .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Reset dose") { controller.resetDose() }
                }
            }
        } header: { SettingsSectionHeader(title: "Level at the ear") }
        .listRowBackground(Color.joseonPanel)
    }

    private func presetRow(_ preset: CalibrationPreset) -> some View {
        HStack(spacing: 8) {
            if renaming == preset.id {
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(preset) }
                    .accessibilityLabel("New name for \(preset.name)")
                Button("Done") { commitRename(preset) }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name).lineLimit(1).truncationMode(.middle)
                    Text("\(preset.headphoneName) on \(preset.deviceName)")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Text("\(preset.methodTitle) · voltage \(SPLController.termText(preset.calibration.uncertaintyDB))" + (preset.knobNote.isEmpty ? "" : " · knob at \(preset.knobNote)"))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Button("Rename") { renaming = preset.id; renameText = preset.name }
                Button("Delete", role: .destructive) { controller.store.delete(preset.id) }
                    .help("Delete this calibration")
            }
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
    }

    private func commitRename(_ preset: CalibrationPreset) {
        controller.store.rename(preset.id, to: renameText)
        renaming = nil
    }
}
