import AppKit
import SwiftUI
import JoseonCore

// `TonePlayPermit` and `PermitButton` (the only maker of a permit) live in `PlayPermit.swift`.

enum CalibrationMethod: String, CaseIterable, Identifiable {
    case measure, specs, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .measure: return "Measure with a multimeter"
        case .specs: return "Enter values from specs"
        case .system: return "macOS controls the volume"
        }
    }
    var shortTitle: String {
        switch self {
        case .measure: return "Multimeter"
        case .specs: return "From specs"
        case .system: return "macOS volume"
        }
    }
}

/// Every sentence of the calibration window that names a "±" figure. No number is typed here: each one comes from
/// `SPLMath` and prints through `SPLController.termText` / `uncertaintyText`, and each sentence follows the two
/// toggles, so the blurb, the toggle help, the note and the result line say the same number in every state.
/// The self-check (`SPLSelfCheck.calibrationTexts`) holds them to that.
enum CalibrationText {
    /// The voltage term the calibration is stored with: the one source for the texts below and for `Save`.
    static func voltageTermDB(_ method: CalibrationMethod, measuredLoaded: Bool, attenuationIsGuess: Bool) -> Double {
        switch method {
        case .measure: return SPLMath.uncertaintyDB(measuredLoaded: measuredLoaded)
        case .specs: return SPLMath.uncertaintyDB(specsAttenuationIsGuess: attenuationIsGuess)
        case .system: return SPLMath.systemVolumeUncertaintyDB
        }
    }

    private static func t(_ db: Double) -> String { SPLController.termText(db) }

    static func blurb(_ method: CalibrationMethod, measuredLoaded: Bool, attenuationIsGuess: Bool) -> String {
        let now = t(voltageTermDB(method, measuredLoaded: measuredLoaded, attenuationIsGuess: attenuationIsGuess))
        switch method {
        case .measure:
            let head = "Recommended for an amplifier with a volume knob. Most exact: about \(now) of the voltage"
            return measuredLoaded ? head + "." : head + ", \(t(SPLMath.uncertaintyDB(measuredLoaded: true))) with the headphones plugged in while you measure."
        case .specs:
            let head = "No meter at hand. Uses the data sheets of the DAC and the amplifier: about \(now) of the voltage"
            return attenuationIsGuess ? head + " while the volume setting is a guess, \(t(SPLMath.uncertaintyDB(specsAttenuationIsGuess: false))) when you know it." : head + "."
        case .system:
            return "For the Mac headphone jack and other outputs where the macOS volume sets the level: about \(now) of the voltage."
        }
    }

    /// Under the "headphones were plugged in" toggle while it is off.
    static var openMeasurementNote: String {
        "A measurement without the headphones reads a little high on an amplifier with a high output impedance, such as a tube amplifier. Joseon widens the uncertainty of the voltage from \(t(SPLMath.uncertaintyDB(measuredLoaded: true))) to \(t(SPLMath.uncertaintyDB(measuredLoaded: false)))."
    }

    /// Help of the "This is a guess" toggle.
    static func guessHelp(isGuess: Bool) -> String {
        let known = t(SPLMath.uncertaintyDB(specsAttenuationIsGuess: false)), guess = t(SPLMath.uncertaintyDB(specsAttenuationIsGuess: true))
        return isGuess
            ? "An analog knob has no dB scale. This is on: the voltage counts with \(guess). Off, it counts with \(known)."
            : "An analog knob has no dB scale. This is off: the voltage counts with \(known). On, it counts with \(guess)."
    }

    /// Under the "This is a guess" toggle while it is on.
    static var guessNote: String {
        "Most knobs have no dB scale, so a guess can be far off. The voltage counts with \(t(SPLMath.uncertaintyDB(specsAttenuationIsGuess: true))) in this calibration. A multimeter measurement is much closer."
    }

    /// The result line: "voltage ± 2 dB · level ± 4 dB". The voltage term, and the total with the sensitivity in use.
    static func resultLine(voltageDB: Double, sensitivityDB: Double?) -> String {
        let voltage = "voltage \(t(voltageDB))"
        guard let sensitivityDB else { return voltage }
        return voltage + " \u{00B7} level " + SPLController.uncertaintyText(SPLMath.totalUncertaintyDB(voltage: voltageDB, sensitivity: sensitivityDB))
    }

    /// Under the sensitivity in use.
    static func sensitivityLine(termDB: Double) -> String {
        "Counts with \(t(termDB)) in the level. \"Measure your headphone\u{2026}\" in Settings gives the value of your own unit."
    }

    /// Under the fields for a typed-in sensitivity (calibration window, popover, Settings): one wording everywhere.
    static func typedSensitivityHint(headphone: String) -> String {
        "Sensitivity at 1 kHz in dB/mW or dB/V, and the impedance, of \(headphone): from the maker's data sheet, or a value you trust. Joseon needs both to turn volts into sound level. A typed-in value counts with \(t(SPLMath.typedSensitivityUncertaintyDB)) in the level; \"Measure your headphone\u{2026}\" gives the value of your own unit."
    }
}

enum VoltUnit: String, CaseIterable, Identifiable {
    case millivolts, volts
    var id: String { rawValue }
    var title: String { self == .millivolts ? "mV" : "V" }
    var factor: Double { self == .millivolts ? 0.001 : 1 }
}

/// "Calibrate level at the ear": three ways to tell Joseon how many volts reach the headphone.
struct CalibrationView: View {
    @ObservedObject var controller: SPLController
    @ObservedObject var tone: TonePlayer
    var onClose: () -> Void

    @State private var method: CalibrationMethod
    // Multimeter
    @State private var headphonesOff = false
    @State private var voltText = ""
    @State private var voltUnit = VoltUnit.millivolts
    @State private var measuredLoaded = false
    // Specs
    @State private var dacText = ""
    @State private var gainText = ""
    @State private var attenuationText = ""
    @State private var attenuationIsGuess = false
    // macOS volume
    @State private var maxVoltText = ""
    // Name
    @State private var name = ""
    @State private var knobNote = ""

    /// `prefill`: design-review pictures only, so the result lines show.
    init(controller: SPLController, initialMethod: CalibrationMethod = .measure, prefill: Bool = false, onClose: @escaping () -> Void) {
        self.controller = controller
        self.tone = controller.tone
        self.onClose = onClose
        _method = State(initialValue: initialMethod)
        if prefill {
            // The safety checkbox is NOT prefilled: the pictures show the true first state, with "Play" off.
            _voltText = State(initialValue: "840")
            _dacText = State(initialValue: "2.0"); _gainText = State(initialValue: "12"); _attenuationText = State(initialValue: "20")
            _attenuationIsGuess = State(initialValue: true)
            _maxVoltText = State(initialValue: "1.0")
            _knobNote = State(initialValue: "10 o'clock")
        }
    }

    private var device: String { controller.deviceName.isEmpty ? "the default output" : controller.deviceName }
    private var hasSoftwareVolume: Bool { controller.output?.hasSoftwareVolume ?? false }

    // MARK: Result

    private struct CalibrationResult { var fullScaleVrms: Double; var storedVrms: Double; var uncertaintyDB: Double; var method: PlaybackCalibration.Method }

    private var voltageTermDB: Double { CalibrationText.voltageTermDB(method, measuredLoaded: measuredLoaded, attenuationIsGuess: attenuationIsGuess) }

    private var result: CalibrationResult? {
        switch method {
        case .measure:
            guard let v = SPLMath.parse(voltText), v > 0 else { return nil }
            let fs = SPLMath.fullScaleVrms(measuredVrms: v * voltUnit.factor)
            return CalibrationResult(fullScaleVrms: fs, storedVrms: fs, uncertaintyDB: voltageTermDB, method: .measuredVoltage)
        case .specs:
            guard let dac = SPLMath.parse(dacText), dac > 0, let gain = SPLMath.parse(gainText), let attenuation = SPLMath.parse(attenuationText) else { return nil }
            let fs = SPLMath.fullScaleVrms(dacVrms: dac, gainDB: gain, attenuationDB: attenuation)
            return CalibrationResult(fullScaleVrms: fs, storedVrms: fs, uncertaintyDB: voltageTermDB, method: .enteredSpecs)
        case .system:
            guard let maxV = SPLMath.parse(maxVoltText), maxV > 0, let attenuation = controller.output?.attenuationDB else { return nil }
            return CalibrationResult(fullScaleVrms: SPLMath.fullScaleVrms(maxOutputVrms: maxV, volumeAttenuationDB: attenuation), storedVrms: maxV,
                                     uncertaintyDB: voltageTermDB, method: .systemVolume)
        }
    }

    /// A full-scale level outside this range is a typing error (mV for V, or the reverse) more often than a real chain.
    private var plausibility: String? {
        guard let result else { return nil }
        if result.fullScaleVrms > 60 { return "More than 60 V at full scale is not likely. Check the value and the unit (mV or V)." }
        if result.fullScaleVrms < 0.005 { return "Less than 5 mV at full scale is not likely. Check the value and the unit (mV or V)." }
        return nil
    }

    private var canSave: Bool { result != nil && plausibility == nil && !controller.headphoneName.isEmpty }

    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? controller.store.suggestedName(device: controller.deviceName) : typed
    }

    private func save() {
        guard let result, canSave else { return }
        tone.stop()
        let note = knobNote.trimmingCharacters(in: .whitespaces)
        controller.save(CalibrationPreset(
            calibration: PlaybackCalibration(name: effectiveName, method: result.method, fullScaleVrms: result.storedVrms, uncertaintyDB: result.uncertaintyDB),
            deviceName: controller.deviceName, headphoneName: controller.headphoneName, knobNote: note))
        onClose()
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 13) {
                    intro
                    if !controller.headphoneName.isEmpty { sensitivitySection }
                    methodPicker
                    Group {
                        switch method {
                        case .measure: measureSteps
                        case .specs: specsSteps
                        case .system: systemSteps
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            // The result and the name stay in view while the steps scroll: the scroll edge never cuts the name field.
            VStack(alignment: .leading, spacing: 10) {
                if result != nil { resultBox }
                if method != .system || hasSoftwareVolume { naming }
            }
            .padding(.horizontal, 22).padding(.top, 10)
            HStack {
                Text("Every level is an estimate. Joseon never changes your volume.")
                    .font(.footnote).foregroundStyle(Color.joseonSecondary)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Button("Cancel") { tone.stop(); onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Save calibration", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .help(canSave ? "Save and use this calibration for \(device)" : "Fill in the values first")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .background(Color.joseonBackground)
        .foregroundStyle(Color.joseonText)
        .tint(Color.joseonAccent)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: CalibrationWindowController.minimumSize.width, idealWidth: 620, minHeight: CalibrationWindowController.minimumSize.height, idealHeight: 760)
        .onChange(of: method) { tone.stop() }
        .onDisappear { tone.stop() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calibrate level at the ear").font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Joseon sees the digital signal, but it can not see the volume knob of your amplifier. One calibration tells Joseon how many volts reach your headphones, and from there it estimates the sound level at your ear.")
                .font(.callout).foregroundStyle(Color.joseonSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                fact("hifispeaker", "Output", device)
                fact("headphones", "Headphone", controller.headphoneName.isEmpty ? "None" : controller.headphoneName)
            }
            if controller.headphoneName.isEmpty {
                note("Pick a headphone in the main window first. A calibration belongs to one output and one headphone.", symbol: "exclamationmark.circle")
            }
        }
    }

    /// Set-up is one window: the sensitivity of the headphone first, then the voltage. A library or measured value
    /// shows as one line; a missing one shows the fields, and for a headphone the maker gives no usable figure for,
    /// the reason (the "86dB with no reference" text of the library).
    private var sensitivitySection: some View {
        let missing = controller.sensitivity == nil
        return VStack(alignment: .leading, spacing: 6) {
            Text("HEADPHONE SENSITIVITY").font(.system(size: 10.5, weight: .semibold)).kerning(0.4).foregroundStyle(Color.joseonSecondary)
                .accessibilityAddTraits(.isHeader)
            if missing, let reason = SPLWiring.unlistedReason(forHeadphoneNamed: controller.headphoneName) {
                Text(reason.reason + " If the maker means dB per milliwatt (the usual reading for this kind of figure), choose the unit dB/mW and enter the impedance. Joseon shows the source as \"User\".")
                    .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
            }
            SensitivityEditor(controller: controller)
            if let term = controller.sensitivityUncertaintyDB {
                Text(CalibrationText.sensitivityLine(termDB: term))
                    .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.joseonPanel))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(missing ? Color.joseonWarn.opacity(0.6) : Color(nsColor: Palette.cardBorder), lineWidth: 1))
    }

    private func fact(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(Color.joseonSecondary).accessibilityHidden(true)
            Text(label + ":").foregroundStyle(Color.joseonSecondary)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }

    private var methodPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Method", selection: $method) {
                ForEach(CalibrationMethod.allCases) { Text($0.shortTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Calibration method")
            Text(method.title).font(.headline).padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
            Text(CalibrationText.blurb(method, measuredLoaded: measuredLoaded, attenuationIsGuess: attenuationIsGuess)).font(.callout).foregroundStyle(Color.joseonSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Method a — multimeter

    private var measureSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, "Take the headphones off your head.",
                 "Unplug them, or use a breakout adapter, so the meter probes can reach the contacts of the headphone output.")
            step(2, "Set the amplifier volume where you normally listen.",
                 hasSoftwareVolume
                    ? "Leave the macOS volume where you normally have it too. The calibration is valid for these two settings only: write down where the knob stands, and make one calibration per position you use."
                    : "The calibration is valid for this knob position only: write down where the knob stands, and make one calibration per position you use.")
            step(3, "Set the multimeter to AC volts, then play the test tone.",
                 "A 400 Hz sine at \(NumberText.signed(Int(SPLMath.toneLevelDBFS))) dBFS through \(device). Common multimeters read AC correctly at 400 Hz. The tone fades in over 0.5 s and stops by itself after 60 s.") {
                toneControl
            }
            step(4, "Measure across one channel of the headphone output and type the value.",
                 "Volts RMS, as the meter shows them. If you can, measure with the headphones plugged in (still off your head).") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("for example 840", text: $voltText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                            .accessibilityLabel("Measured voltage")
                        Picker("Unit", selection: $voltUnit) {
                            ForEach(VoltUnit.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .accessibilityLabel("Unit of the measured voltage")
                        Text("RMS").foregroundStyle(Color.joseonSecondary)
                    }
                    Toggle("The headphones were plugged in while I measured", isOn: $measuredLoaded)
                    if !measuredLoaded {
                        note(CalibrationText.openMeasurementNote)
                    }
                }
            }
        }
    }

    private var toneControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            if tone.state == .playing {
                HStack(spacing: 12) {
                    Button(action: { tone.stop() }) {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 150, height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.joseonDanger)
                    .accessibilityLabel("Stop the test tone")
                    ToneMeter(levelDBFS: tone.levelDBFS, secondsLeft: tone.secondsLeft)
                }
            } else {
                Toggle("The headphones are off my head", isOn: $headphonesOff)
                HStack(spacing: 12) {
                    // The tick is single use: every tone needs a new one. While the tone plays this block is not on
                    // screen; when it comes back the checkbox is unticked and "Play" is off again.
                    PermitButton(confirmed: headphonesOff, action: { tone.start(permit: $0); headphonesOff = false }) {
                        Label("Play test tone", systemImage: "speaker.wave.2.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 150, height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .help(headphonesOff ? "Plays a 400 Hz tone through \(device) for at most 60 s" : "Confirm first that the headphones are off your head")
                    .accessibilityHint("Plays a 400 hertz tone through \(device) for at most 60 seconds")
                    Text("Sound plays only after you press this button.")
                        .font(.footnote).foregroundStyle(Color.joseonSecondary)
                }
                if case .failed(let message) = tone.state {
                    note(message, symbol: "exclamationmark.triangle", tint: .joseonWarn)
                }
            }
        }
    }

    // MARK: Method b — specs

    private var specsSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "DAC output at full scale.", "From the data sheet of the DAC. 2 V RMS is common for a single-ended line output, 4 V RMS for a balanced one.") {
                field("for example 2.0", $dacText, unit: "V RMS", label: "DAC full-scale output in volts RMS")
            }
            step(2, "Amplifier gain.", "From the data sheet of the amplifier, in dB, for the gain setting you use.") {
                field("for example 12", $gainText, unit: "dB", label: "Amplifier gain in decibels")
            }
            step(3, "How far the volume control is turned down.", "In dB under maximum. 0 means the control is fully up.") {
                VStack(alignment: .leading, spacing: 8) {
                    field("for example 20", $attenuationText, unit: "dB under maximum", label: "Volume attenuation in decibels under maximum")
                    Toggle("This is a guess", isOn: $attenuationIsGuess)
                        .help(CalibrationText.guessHelp(isGuess: attenuationIsGuess))
                    if attenuationIsGuess {
                        note(CalibrationText.guessNote)
                    }
                }
            }
        }
    }

    // MARK: Method c — macOS volume

    @ViewBuilder private var systemSteps: some View {
        if let output = controller.output, let attenuation = output.attenuationDB {
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Maximum output voltage of \(device).",
                     "Look up the headphone-output specification of this device, for example on the maker's support pages. Some outputs give a higher voltage to high-impedance headphones: use the value for your headphone's impedance.") {
                    field("volts at maximum volume", $maxVoltText, unit: "V RMS", label: "Maximum output voltage in volts RMS")
                }
                step(2, "Joseon follows the macOS volume from here on.",
                     "macOS volume now: \(volumeText(attenuation))\(output.isMuted ? ", muted" : ""). When you change the volume, the level estimate follows at once.")
            }
        } else {
            note("\(device.prefix(1).uppercased() + device.dropFirst()) has no volume control that macOS can set, so Joseon can not follow its level. This is normal for an external DAC with a fixed output. Use one of the other two methods.",
                 symbol: "speaker.slash", tint: .joseonWarn)
        }
    }

    private func volumeText(_ attenuation: Double) -> String {
        attenuation > -0.05 ? "maximum" : "\(NumberText.signed(abs(attenuation), decimals: 1)) dB under maximum"
    }

    // MARK: Result and name

    @ViewBuilder private var resultBox: some View {
        if let result {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Full-scale level").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.joseonSecondary)
                    Text("\(volts(result.fullScaleVrms)) RMS for a 0 dBFS sine").font(.system(size: 14, weight: .medium).monospacedDigit())
                    Spacer()
                    Text(uncertaintyLine(result)).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Color.joseonSecondary)
                        .accessibilityLabel("Uncertainty: \(uncertaintyLine(result))")
                }
                if let plausibility {
                    note(plausibility, symbol: "exclamationmark.triangle", tint: .joseonWarn)
                } else if let sensitivity = controller.sensitivity {
                    let spl = SPLMath.fullScaleSPL(fullScaleVrms: result.fullScaleVrms, sensitivity: sensitivity)
                    Text("At this setting a 0 dBFS tone would be ≈ \(Int(spl.rounded())) dB SPL at the eardrum. Typical music at \(NumberText.signed(-14)) LUFS is then roughly \(Int(SPLMath.roughMusicSPL(fullScaleSPL: spl).rounded())) dB SPL.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    if spl > 125 {
                        note("That is very loud for a listening position. Check the value and the unit.", symbol: "exclamationmark.triangle", tint: .joseonWarn)
                    }
                } else {
                    Text("Joseon shows the matching sound level here when it knows the sensitivity of the headphone. Enter it at the top of this window.")
                        .font(.callout).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.joseonPanel))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: Palette.cardBorder), lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
    }

    /// "voltage ± 2 dB · level ± 4 dB": the voltage term of this method, and the total with the sensitivity in use.
    private func uncertaintyLine(_ result: CalibrationResult) -> String {
        CalibrationText.resultLine(voltageDB: result.uncertaintyDB, sensitivityDB: controller.sensitivityUncertaintyDB)
    }

    private func volts(_ v: Double) -> String {
        v < 0.1 ? "\(NumberText.signed(v * 1000, decimals: 1)) mV" : "\(NumberText.signed(v, decimals: v < 10 ? 2 : 1)) V"
    }

    /// One row, in the pinned part above the buttons.
    private var naming: some View {
        HStack(spacing: 10) {
            Text("NAME").font(.system(size: 10.5, weight: .semibold)).kerning(0.4).foregroundStyle(Color.joseonSecondary)
                .accessibilityHidden(true)
            TextField(controller.store.suggestedName(device: controller.deviceName), text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Calibration name")
            if method != .system {
                TextField("Knob position, for example 10 o'clock", text: $knobNote)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)
                    .accessibilityLabel("Volume knob position")
                    .help("Write down where the knob stands. When you move the knob, this calibration no longer fits: make one for each position you use.")
            }
        }
    }

    // MARK: Parts

    private func step<Extra: View>(_ number: Int, _ title: String, _ detail: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.joseonBackground)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.joseonAccent))
                .accessibilityLabel("Step \(number)")
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.callout).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                extra()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        step(number, title, detail) { EmptyView() }
    }

    private func field(_ prompt: String, _ text: Binding<String>, unit: String, label: String) -> some View {
        HStack(spacing: 8) {
            TextField(prompt, text: text).textFieldStyle(.roundedBorder).frame(width: 190).accessibilityLabel(label)
            Text(unit).foregroundStyle(Color.joseonSecondary)
        }
    }

    private func note(_ text: String, symbol: String = "info.circle", tint: Color = .joseonSecondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).font(.footnote).foregroundStyle(tint == .joseonSecondary ? Color.joseonSecondary : Color.joseonText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Level of the test tone while it plays, and the time until it stops by itself.
struct ToneMeter: View {
    var levelDBFS: Double
    var secondsLeft: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let share = min(max((levelDBFS + 60) / 60, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.joseonPanel)
                    Capsule().fill(Color.joseonAccent).frame(width: max(4, proxy.size.width * share))
                }
            }
            .frame(height: 8)
            Text("\(levelDBFS > -100 ? NumberText.signed(levelDBFS, decimals: 1) : "—") dBFS peak  ·  stops by itself in \(Int(secondsLeft.rounded(.up))) s")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.joseonSecondary)
        }
        .frame(maxWidth: 260)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Test tone plays")
        .accessibilityValue("\(Int(levelDBFS.rounded())) dBFS, stops in \(Int(secondsLeft.rounded(.up))) seconds")
    }
}

/// Sensitivity of the chosen headphone: the library value, or fields to type it in. Used in the calibration window,
/// in the SPL popover and in Settings.
struct SensitivityEditor: View {
    @ObservedObject var controller: SPLController
    @State private var valueText = ""
    @State private var unit = SensitivityUnit.dbPerMilliwatt
    @State private var impedanceText = ""
    @State private var loadedFor = ""

    private var entry: UserSensitivity? {
        guard let value = SPLMath.parse(valueText), let z = SPLMath.parse(impedanceText) else { return nil }
        let e = UserSensitivity(value: value, unit: unit, impedanceOhms: z)
        return e.isValid ? e : nil
    }

    private var stored: UserSensitivity? { controller.store.userSensitivity(headphone: controller.headphoneName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.headphoneName.isEmpty {
                Text("Pick a headphone first.").foregroundStyle(.secondary)
            } else if controller.sensitivityIsMeasured, let s = controller.sensitivity {
                // From "Measure your headphone…". It wins over the library value: it is this unit, not a sample.
                Text("\(NumberText.signed(s.dbSPLPerVolt, decimals: 1)) dB SPL/V · \(NumberText.signed(s.impedanceOhms, decimals: 0)) Ω").font(.body.monospacedDigit())
                Text("Source: \(s.source)").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Remove the measured value") {
                    controller.store.setUserSensitivity(nil, headphone: controller.headphoneName)
                    valueText = ""; impedanceText = ""
                }
                .buttonStyle(.link).font(.footnote)
            } else if controller.sensitivityIsFromLibrary, let s = controller.sensitivity {
                Text("\(NumberText.signed(s.dbSPLPerVolt, decimals: 1)) dB SPL/V · \(NumberText.signed(s.impedanceOhms, decimals: 0)) Ω").font(.body.monospacedDigit())
                Text("Source: \(s.source)").font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    TextField("", text: $valueText, prompt: Text("Sensitivity"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(width: 88)
                        .accessibilityLabel("Sensitivity of \(controller.headphoneName)")
                    Picker("Unit", selection: $unit) {
                        ForEach(SensitivityUnit.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .accessibilityLabel("Sensitivity unit")
                    TextField("", text: $impedanceText, prompt: Text("Impedance"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(width: 88)
                        .accessibilityLabel("Impedance in ohms")
                    Text("Ω").foregroundStyle(.secondary)
                    Button(stored == nil ? "Save" : "Update") {
                        controller.store.setUserSensitivity(entry, headphone: controller.headphoneName)
                    }
                    .disabled(entry == nil || entry == stored)
                    .fixedSize()
                }
                // A headphone whose maker gives no usable figure: never send the user to "the data sheet" for it.
                Text(SPLWiring.unlistedReason(forHeadphoneNamed: controller.headphoneName) != nil
                     ? "The maker's page gives no usable sensitivity for \(controller.headphoneName) (\"\(SPLPill.setUpTitle)\" in the main window says why). Enter a value you trust, with its unit and the impedance, or measure your own unit. Joseon needs both numbers to turn volts into sound level."
                     : CalibrationText.typedSensitivityHint(headphone: controller.headphoneName))
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if stored != nil {
                    Button("Remove the typed-in value") {
                        controller.store.setUserSensitivity(nil, headphone: controller.headphoneName)
                        valueText = ""; impedanceText = ""
                    }
                    .buttonStyle(.link).font(.footnote)
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: controller.headphoneName) { load() }
    }

    private func load() {
        guard loadedFor != controller.headphoneName else { return }
        loadedFor = controller.headphoneName
        if let stored {
            valueText = NumberText.signed(stored.value, decimals: 1)
            impedanceText = NumberText.signed(stored.impedanceOhms, decimals: 0)
            unit = stored.unit
        } else {
            valueText = ""; impedanceText = ""
        }
    }
}

/// The calibration window. One at a time. Closing it stops the test tone.
final class CalibrationWindowController: NSObject, NSWindowDelegate {
    private let controller: SPLController
    private(set) var window: NSWindow?

    init(controller: SPLController) { self.controller = controller }

    /// At 560 pt of height the sensitivity box, the result and the name left about 100 pt for the steps, and the scroll
    /// edge cut a line of step 1. 680 pt shows the method and its first two steps whole.
    static let minimumSize = NSSize(width: 560, height: 680)

    func show(method: CalibrationMethod = .measure, prefill: Bool = false, size: NSSize = NSSize(width: 620, height: 760)) {
        if let window, !prefill { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        window?.close()
        let view = CalibrationView(controller: controller, initialMethod: method, prefill: prefill) { [weak self] in self?.window?.close() }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.title = "Calibrate level at the ear"
        w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Palette.background
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentMinSize = Self.minimumSize
        // A programmatic size is not held to `contentMinSize`: the review pictures of the "minimum" must show the real one.
        w.setContentSize(NSSize(width: max(size.width, Self.minimumSize.width), height: max(size.height, Self.minimumSize.height)))
        w.center()
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        controller.tone.stop()
        window = nil
    }
}
