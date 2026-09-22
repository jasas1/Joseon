import AppKit
import SwiftUI
import UniformTypeIdentifiers
import JoseonCore
import JoseonCapture
import JoseonHeadphones

/// "Measure your headphone…": five steps from the input device to a saved curve.
/// Sound starts only from a `PermitButton` (button press + the checkbox "on the rig, not on my head").
/// The Microphone prompt comes only from the "Allow microphone…" button.
struct MeasureView: View {
    @ObservedObject var controller: MeasureController
    var onClose: () -> Void
    /// Design review only: the whole step without the scroll view, so one picture shows every word of it.
    var flat = false

    @State private var saveName = ""
    /// Nil = the best curve there is: the average when both sides are measured.
    @State private var pickedSaveChoice: MeasureSaveChoice?
    @State private var showsLimits = false
    /// The curve and the name the user was asked about ("likely seal leak", "replace the stored curve"). A new name
    /// or a new curve asks again.
    @State private var saveQuestionFor: String?

    private static let rigCheckbox = "The headphones are on the rig, not on my head"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if flat { stepContent } else { ScrollView(.vertical) { stepContent } }
            Divider()
            footer
        }
        .background(Color.joseonBackground)
        .foregroundStyle(Color.joseonText)
        .tint(Color.joseonAccent)
        .environment(\.colorScheme, .dark)
        // The window's minimum content size is 580 × 620 and includes the title bar: stay under it.
        .frame(minWidth: 580, idealWidth: 680, minHeight: flat ? nil : 560, idealHeight: flat ? nil : 800)
        .onAppear { if flat { showsLimits = true } }
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let message = controller.message {
                note(message.text, symbol: message.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle", tint: message.isProblem ? .joseonWarn : .joseonSecondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.joseonPanel))
            }
            switch controller.step {
            case .input: inputStep
            case .microphone: microphoneStep
            case .level: levelStep
            case .measure: measureStep
            case .result: resultStep
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Measure your headphone").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if controller.step == .input {
                // The honest limit comes first, on the page where the user decides whether to go on.
                Text("You need a measurement microphone and a coupler or a flat-plate rig. Without them, skip this: Joseon works with the published curve.")
                    .font(.callout).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if controller.environment.isLabelledFake {
                Text("SNAPSHOT: fake input, fake player, simulated headphone. Nothing here is a measurement.")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.black)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.joseonWarn))
            }
            stepBar
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepBar: some View {
        HStack(spacing: 4) {
            ForEach(MeasureStep.allCases) { step in
                let current = step == controller.step
                let reachable = step.rawValue < controller.step.rawValue || controller.canShow(step)
                Button(action: { controller.go(to: step) }) {
                    HStack(spacing: 5) {
                        Text("\(step.rawValue + 1)")
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(current ? Color.joseonBackground : Color.joseonText)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(current ? Color.joseonAccent : Color.white.opacity(reachable ? 0.16 : 0.07)))
                        Text(step.title).font(.system(size: 12, weight: current ? .semibold : .regular)).lineLimit(1).fixedSize()
                    }
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(current ? Color.joseonPanel : Color.clear))
                    .opacity(reachable || current ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .disabled(!current && (!reachable || controller.activity.makesSound))
                .allowsHitTesting(!current)
                .accessibilityLabel("Step \(step.rawValue + 1) of 5: \(step.title)")
                .accessibilityAddTraits(current ? .isSelected : [])
                if step != .result { Spacer(minLength: 0) }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Recordings stay in memory and are dropped when this window closes. Only the curve is saved, when you press Save.")
                .font(.footnote).foregroundStyle(Color.joseonSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if controller.step != .input {
                Button("Back") { controller.back() }.disabled(controller.activity.makesSound)
            }
            if controller.step == .result {
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            } else {
                let blocker = controller.blocker(after: controller.step)
                Button(nextTitle) { controller.next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocker != nil || controller.activity.isBusy)
                    .help(blocker ?? "Go to the next step")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private var nextTitle: String {
        MeasureStep(rawValue: controller.step.rawValue + 1).map { "Next: \($0.title)" } ?? "Next"
    }

    // MARK: Step 1 — input

    private var inputStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Where is the measurement microphone plugged in?",
                      "Joseon only reads the list of inputs here. It opens the input later, for a level check, the room-noise recording and each run, and closes it again after each one.")
            section("INPUT DEVICE") {
                if controller.devices.isEmpty {
                    note("macOS shows no audio input. Plug in the microphone or the audio interface, then press “Read the list again”.", symbol: "exclamationmark.circle", tint: .joseonWarn)
                } else {
                    Picker("Input device", selection: $controller.deviceUID) {
                        ForEach(controller.devices) { device in
                            Text(Self.deviceTitle(device)).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 440, alignment: .leading)
                    .accessibilityLabel("Input device")
                    if let device = controller.selectedDevice {
                        if device.channelCount > 1 {
                            Picker("Input channel", selection: $controller.channel) {
                                ForEach(0..<device.channelCount, id: \.self) { Text("Input \($0 + 1)").tag($0) }
                            }
                            .frame(maxWidth: 240, alignment: .leading)
                        }
                        Text("\(device.transport.rawValue) · \(device.channelCount) input channel\(device.channelCount == 1 ? "" : "s") · \(Self.rateText(device.nominalSampleRate)). Joseon uses the sample rate the device has now and never changes it.")
                            .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
                        if MeasureController.listedLast(device) {
                            note("This is a virtual or aggregate device. It carries audio between apps; it is not a microphone. Use it only when you know that your microphone runs through it.", symbol: "exclamationmark.triangle", tint: .joseonWarn)
                        } else if device.transport == .builtIn {
                            note("The built-in microphone is not a measurement microphone: it has no calibration and does not fit a coupler.", symbol: "exclamationmark.triangle", tint: .joseonWarn)
                        } else if device.transport == .bluetooth {
                            note("A Bluetooth microphone compresses the audio. It can not measure a frequency response.", symbol: "exclamationmark.triangle", tint: .joseonWarn)
                        }
                    }
                    if controller.devices.contains(where: MeasureController.listedLast) {
                        Text("Virtual and aggregate devices are at the end of the list.")
                            .font(.footnote).foregroundStyle(Color.joseonSecondary)
                    }
                }
                Button("Read the list again") { controller.refreshDevices() }
                    .controlSize(.small)
            }
            section("MICROPHONE PERMISSION") { permissionBlock }
        }
    }

    static func deviceTitle(_ device: MeasurementInputDevice) -> String {
        var title = device.name
        if device.transport == .virtual { title += "  (virtual)" }
        if device.transport == .aggregate { title += "  (aggregate)" }
        return title
    }

    static func rateText(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(rate / 1000)) kHz" : "\(NumberText.signed(rate / 1000, decimals: 1)) kHz"
    }

    @ViewBuilder private var permissionBlock: some View {
        switch controller.permission {
        case .authorized:
            note("Allowed. Joseon may open the input when you start a check or a run.", symbol: "checkmark.circle.fill", tint: Color(nsColor: Palette.live))
        case .notDetermined:
            Text("macOS asks once whether Joseon may use the microphone. The question comes when you press the button below, not before.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            // The ONLY control that leads to `MicrophonePermission.request`.
            Button("Allow microphone…") { controller.requestPermissionFromButton() }
                .help("macOS shows its permission question")
        case .denied:
            note("Not allowed. Turn Joseon on under System Settings → Privacy & Security → Microphone, then come back to this window.", symbol: "xmark.octagon.fill", tint: .joseonWarn)
            HStack {
                Button("Open System Settings…") { controller.openSystemSettings() }
                Button("Check again") { controller.refreshDevices() }
            }
        case .restricted:
            note("A device policy of this Mac blocks the microphone. Joseon can not measure here.", symbol: "xmark.octagon.fill", tint: .joseonWarn)
        }
    }

    // MARK: Step 2 — microphone

    private var microphoneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Tell Joseon about the microphone and the rig.",
                      "Everything on this page is optional, and everything you leave out is named in the result.")
            section("MICROPHONE CALIBRATION FILE") {
                correctionBlock(info: controller.micInfo, error: controller.micError, chooseTitle: "Choose calibration file…",
                                choose: { chooseFile(asCoupler: false) }, remove: { controller.clearMicCalibration() })
                if let info = controller.micInfo {
                    Text(info.sensFactorDB.map { "Sensitivity factor in the file: \(NumberText.signed($0, decimals: 2)) dB. Joseon can use it for a rough absolute level (± 2 dB), and only while the input gain stays as the maker set it. Joseon's reading of this factor was never checked against a real microphone: a calibrator reading (below) is the exact way." }
                         ?? "This file has no sensitivity factor. The shape of the curve does not need one; absolute level does (see below).")
                        .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
                    Text("Many makers give two files: 0° (microphone points at the driver) and 90°. In a coupler or on a flat plate the microphone points at the driver: use the 0° file. Joseon can not tell the files apart.")
                        .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The file the maker of the microphone gives you (miniDSP UMIK, Dayton, REW text format). Without it the curve is the headphone and the microphone together.")
                        .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            section("COUPLER CORRECTION FILE (OPTIONAL)") {
                correctionBlock(info: controller.couplerInfo, error: controller.couplerError, chooseTitle: "Choose correction file…",
                                choose: { chooseFile(asCoupler: true) }, remove: { controller.clearCoupler() })
                Text("Only when the maker of your rig gives a correction curve. A standards-type ear simulator (IEC 60318-4) needs none. A flat plate without a correction shows the bass and the treble of the plate, not of an ear.")
                    .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
            }
            section("KIND OF RIG") {
                Picker("Kind of rig", selection: $controller.rig) {
                    ForEach(MeasurementRig.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel("Kind of rig")
                Text(controller.rig.note)
                    .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
            }
            section("RIG NOTE") {
                TextField("for example: flat plate, 3D-printed, foam seal", text: $controller.rigNote)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Note about the rig")
                Text("Goes into the saved curve file and into the source of a measured sensitivity, so you know later how the numbers were made.")
                    .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
            }
            section("ABSOLUTE LEVEL (OPTIONAL, FOR THE SENSITIVITY)") {
                Text("The curve needs no absolute level. The sensitivity of your headphone (dB SPL per volt) does. The exact way: put a 94 dB, 1 kHz sound calibrator on the microphone and enter what the input reads.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("for example −26.4", text: $controller.calibratorText)
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                        .accessibilityLabel("Calibrator reading in dBFS RMS")
                    Text("dBFS RMS").foregroundStyle(Color.joseonSecondary)
                    if controller.activity == .calibrator {
                        ProgressView(value: controller.progress).frame(width: 90)
                        Button("Stop") { controller.cancel() }
                    } else {
                        Button("Read it now") { controller.readCalibrator() }
                            .disabled(controller.activity.isBusy || controller.blocker(after: .input) != nil)
                            .help("Opens the input for 3 s and reads the level. Nothing plays.")
                    }
                }
                Text("“Read it now” opens the input for 3 s with the calibrator running. Nothing plays. After the reading, do not touch the gain of the microphone input.")
                    .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
                absoluteLevelLine
            }
        }
    }

    @ViewBuilder private var absoluteLevelLine: some View {
        switch controller.absoluteLevel {
        case .available(let scale):
            note("Absolute level: available. \(scale.method). ± \(NumberText.signed(scale.uncertaintyDB, decimals: 1)) dB.", symbol: "checkmark.circle", tint: .joseonSecondary)
        case .unavailable(let reason):
            note("Absolute level: not available. \(reason)", symbol: "info.circle")
        }
    }

    @ViewBuilder private func correctionBlock(info: LoadedCorrection?, error: String?, chooseTitle: String, choose: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        if let info {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(Color.joseonSecondary).accessibilityHidden(true)
                Text(info.fileName).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Other file…", action: choose).controlSize(.small).fixedSize()
                Button("Remove", action: remove).controlSize(.small).fixedSize()
            }
            MeasureSparkline(values: info.sparkline,
                             caption: "\(info.pointCount) points, \(MeasureView.hzText(info.lowHz)) – \(MeasureView.hzText(info.highHz))")
        } else {
            Button(chooseTitle, action: choose)
        }
        if let error { note(error, symbol: "exclamationmark.triangle", tint: .joseonWarn) }
    }

    static func hzText(_ hz: Double) -> String {
        hz >= 1000 ? "\(NumberText.signed(hz / 1000, decimals: hz.truncatingRemainder(dividingBy: 1000) == 0 ? 0 : 1)) kHz" : "\(NumberText.signed(hz, decimals: hz < 10 ? 1 : 0)) Hz"
    }

    private func chooseFile(asCoupler: Bool) {
        let panel = NSOpenPanel()
        panel.title = asCoupler ? "Coupler correction file" : "Microphone calibration file"
        panel.message = "A text file with a frequency in Hz and a level in dB on each line."
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .tabSeparatedText, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.loadFile(url, asCoupler: asCoupler)
    }

    // MARK: Step 3 — level check

    private var outputText: String {
        let name = controller.environment.outputName()
        return name.isEmpty ? "the default output of this Mac" : name
    }

    private var levelStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Find a safe level.",
                      "Joseon plays one \(Int(MeasureSignal.sweepSeconds)) s sweep, 20 Hz to 20 kHz, through \(outputText), and records the microphone. The first sweep is 30 dB under full scale. With the amplifier turned up it can still be loud: keep the headphone off your head.")
            section("BEFORE YOU PLAY") {
                bullet("The headphone is on the rig. Nobody wears it.")
                bullet("Amplifier knob: where it was for your level calibration (the sensitivity needs that). Without a calibration, start low.")
                bullet("Keep Joseon in front. The sweep stops when you switch apps, change the output device or close this window.")
            }
            section("PLAY LEVEL AND CHECK") {
                HStack(spacing: 10) {
                    Text("\(NumberText.signed(Int(controller.playLevelDBFS))) dBFS peak")
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        .frame(minWidth: 120, alignment: .leading)
                        .accessibilityLabel("Play level \(Int(controller.playLevelDBFS)) dBFS peak")
                    Button("Lower 6 dB") { controller.lowerLevel() }.disabled(!controller.canLowerLevel)
                    Button("Raise 6 dB") { controller.raiseLevel() }.disabled(!controller.canRaiseLevel)
                        .help(controller.canRaiseLevel ? "One step up. The new level needs its own check." : "Only after a check at this level without clipping, and not above −6 dBFS")
                }
                Text("Stop when the bar is in the green. More level gives no better result and can harm the driver.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text("The first check runs at \(NumberText.signed(Int(MeasureSignal.levelSteps[0]))) dBFS. You go up one 6 dB step at a time, each step after a check without clipping, to \(NumberText.signed(Int(MeasureSignal.levelSteps.last ?? -6))) dBFS at most. The runs in step 4 use the level you stop at.")
                    .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
                Divider().padding(.vertical, 2)
                playControl(title: "Play sweep and check the level", busy: controller.activity == .levelCheck) { controller.startLevelCheck(permit: $0) }
                MeasureInputMeter(meter: controller.meter, heldPeakDB: controller.levelCheck?.inputPeakDB, heldClipped: controller.levelCheck?.verdict == .clipped)
                    .frame(maxWidth: 460)
                levelVerdict
            }
        }
    }

    @ViewBuilder private var levelVerdict: some View {
        if let check = controller.levelCheck {
            let peak = MeasureController.dbText(check.inputPeakDB)
            switch check.verdict {
            case .clipped:
                note("The input clipped (peak \(peak) dBFS). A clipped recording is useless, so step 4 stays closed. Lower the gain of the microphone input, or lower the play level, then check again.", symbol: "exclamationmark.octagon.fill", tint: .joseonDanger)
            case .tooHot:
                note("Input peak \(peak) dBFS: no clipping, but close. This level works; do not go higher. If you can, take the input gain down a little.", symbol: "exclamationmark.triangle", tint: .joseonWarn)
            case .good:
                note("Input peak \(peak) dBFS: inside the target zone. This level is good for the measurement.", symbol: "checkmark.circle.fill", tint: Color(nsColor: Palette.live))
            case .low:
                note("Input peak \(peak) dBFS: under the target zone. It works, with more noise in the result. Better: raise the play level one step, or raise the gain of the microphone input, and check again.", symbol: "arrow.up.circle", tint: .joseonSecondary)
            case .nothing:
                note("Almost nothing arrived (peak \(peak) dBFS). Check the input channel in step 1, the cable, the amplifier, and that the sound goes to the headphone on the rig.", symbol: "exclamationmark.triangle", tint: .joseonWarn)
            }
        } else if controller.activity != .levelCheck {
            Text("No check at this level yet.").font(.footnote).foregroundStyle(Color.joseonSecondary)
        }
    }

    /// The safety checkbox, the button that makes a permit, and Stop while the sweep plays.
    @ViewBuilder private func playControl(title: String, busy: Bool, action: @escaping (TonePlayPermit) -> Void) -> some View {
        if busy {
            HStack(spacing: 12) {
                Button(action: { controller.cancel() }) {
                    Label("Stop", systemImage: "stop.fill").font(.system(size: 14, weight: .semibold)).frame(minWidth: 120, minHeight: 30)
                }
                .buttonStyle(.borderedProminent).tint(Color.joseonDanger)
                .accessibilityLabel("Stop the sweep")
                ProgressView(value: controller.progress).frame(maxWidth: 200)
                Text("The sweep plays at \(NumberText.signed(Int(controller.playLevelDBFS))) dBFS").font(.footnote).foregroundStyle(Color.joseonSecondary)
            }
        } else {
            Toggle(Self.rigCheckbox, isOn: $controller.rigConfirmed)
            HStack(spacing: 12) {
                PermitButton(confirmed: controller.rigConfirmed && !controller.activity.isBusy, action: action) {
                    Label(title, systemImage: "speaker.wave.2.fill").font(.system(size: 14, weight: .semibold)).frame(minHeight: 30).padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .help(controller.rigConfirmed ? "Plays a \(Int(MeasureSignal.sweepSeconds)) s sweep at \(Int(controller.playLevelDBFS)) dBFS through \(outputText)" : "Confirm first that the headphones are on the rig")
                .accessibilityHint("Plays a \(Int(MeasureSignal.sweepSeconds)) second sweep at \(Int(controller.playLevelDBFS)) dBFS through \(outputText)")
                Text("Sound plays only after you press this button.").font(.footnote).foregroundStyle(Color.joseonSecondary)
            }
        }
    }

    // MARK: Step 4 — measure

    private var measureStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Record the room, then the sweeps.",
                      "Each run is one sweep at \(NumberText.signed(Int(controller.playLevelDBFS))) dBFS. Lift the headphone and seat it again before every run: then the agreement number shows how much the seat changes the result.")
            section("SIDE AND NUMBER OF RUNS") {
                HStack(spacing: 16) {
                    Picker("Side on the rig", selection: $controller.side) {
                        ForEach(MeasureSide.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).fixedSize()
                    .disabled(controller.activity.isBusy)
                    Stepper(value: $controller.runsWanted, in: max(1, controller.runs.count)...8) {
                        Text("\(controller.runsWanted) run\(controller.runsWanted == 1 ? "" : "s")").monospacedDigit()
                    }
                    .fixedSize()
                    .disabled(controller.activity.isBusy)
                    .accessibilityLabel("Number of runs")
                    .accessibilityValue("\(controller.runsWanted)")
                }
                Text("One cup at a time. For the other cup, come back here after the result: Joseon keeps both and offers the average.")
                    .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
            }
            section("1 · ROOM NOISE") {
                HStack(spacing: 12) {
                    if controller.activity == .noise {
                        Button("Stop") { controller.cancel() }
                        ProgressView(value: controller.progress).frame(maxWidth: 200)
                        Text("Recording. Nothing plays. Keep quiet.").font(.footnote).foregroundStyle(Color.joseonSecondary)
                    } else {
                        Button(controller.noiseDone ? "Record room noise again" : "Record room noise") { controller.recordNoise() }
                            .disabled(controller.activity.isBusy)
                            .help("Opens the input for about 7 s. Nothing plays.")
                        if let noise = controller.noiseRMSDB {
                            Text("Room noise \(MeasureController.dbText(noise)) dBFS RMS").font(.system(size: 12).monospacedDigit())
                        }
                    }
                }
                Text("About 7 s with nothing playing, headphone on the rig. Joseon needs it to say which parts of the curve stand clear of the noise. Recording it again starts this side from zero.")
                    .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
            }
            section("2 · SWEEPS") {
                if controller.sideIsComplete {
                    note("All \(controller.runsWanted) runs of the \(controller.side.title.lowercased()) side are done. Go to the result, or add runs with the stepper above.", symbol: "checkmark.circle.fill", tint: Color(nsColor: Palette.live))
                } else if case .analysing(let text) = controller.activity {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(text).font(.callout) }
                } else {
                    let index = controller.runs.count + 1
                    if !controller.noiseDone { Text("Record the room noise first.").font(.footnote).foregroundStyle(Color.joseonSecondary) }
                    playControl(title: "Play sweep: run \(index) of \(controller.runsWanted)", busy: controller.activity == .run(index)) { controller.startRun(permit: $0) }
                        .disabled(!controller.noiseDone)
                    if controller.activity == .run(index) {
                        MeasureInputMeter(meter: controller.meter, heldPeakDB: nil, heldClipped: false).frame(maxWidth: 460)
                    }
                }
                if !controller.runs.isEmpty { runTable }
            }
            if let quality = controller.liveQuality { qualityBlock(quality, title: "QUALITY SO FAR") }
            if !controller.runs.isEmpty || controller.noiseDone {
                Button("Start this side again") { controller.resetSession() }
                    .controlSize(.small).disabled(controller.activity.isBusy)
                    .help("Drops the room noise and the runs of the \(controller.side.title.lowercased()) side")
            }
        }
    }

    private var runTable: some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("Run").gridColumnAlignment(.leading)
                Text("Delay"); Text("Impulse S/N"); Text("Distortion"); Text("Input peak"); Text("Agreement"); Text("S/N 1 kHz")
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.joseonSecondary)
            ForEach(controller.runs) { run in
                GridRow {
                    Text("\(run.index)").gridColumnAlignment(.leading)
                    Text("\(NumberText.signed(run.delayMilliseconds, decimals: 1)) ms")
                    Text("\(NumberText.signed(run.impulseSNRDB, decimals: 0)) dB")
                    Text("\(NumberText.signed(run.thdPercent, decimals: 2)) %")
                    Text("\(MeasureController.dbText(run.inputPeakDB)) dBFS")
                    Text(run.agreementDB.map { "\(NumberText.signed($0, decimals: 2)) dB" } ?? "—")
                    Text(run.snrAt1kHzDB.map { "\(NumberText.signed($0, decimals: 0)) dB" } ?? "—")
                }
                .font(.system(size: 12).monospacedDigit())
                .accessibilityElement(children: .combine)
                if let note = run.note {
                    GridRow { self.note(note, symbol: "exclamationmark.triangle", tint: .joseonWarn).gridCellColumns(7).gridCellAnchor(.leading) }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.18)))
    }

    static func agreementWord(_ db: Double) -> String { db <= 0.5 ? "good" : (db <= 1 ? "fair" : "poor: the seat changed between runs") }
    static func snrWord(_ db: Double) -> String { db >= 50 ? "good" : (db >= 30 ? "fair" : "poor: too much noise, or too low a level") }

    private func qualityBlock(_ quality: MeasurementQuality, title: String) -> some View {
        section(title) {
            VStack(alignment: .leading, spacing: 3) {
                if quality.runs > 1 {
                    fact("Run-to-run agreement", "\(NumberText.signed(Double(quality.agreementDB), decimals: 2)) dB, 100 Hz – 10 kHz (\(Self.agreementWord(Double(quality.agreementDB))))")
                } else {
                    fact("Run-to-run agreement", "needs two runs or more")
                }
                if let snr = quality.snrDB(atHz: 1000) {
                    fact("Signal to noise at 1 kHz", "\(NumberText.signed(Double(snr), decimals: 0)) dB (\(Self.snrWord(Double(snr))))")
                }
                if let snr = quality.snrDB(atHz: 40) { fact("Signal to noise at 40 Hz", "\(NumberText.signed(Double(snr), decimals: 0)) dB") }
                fact("Distortion (2nd + 3rd harmonic)", "\(NumberText.signed(Double(quality.thdPercent), decimals: 2)) %, whole chain")
                fact("Runs averaged", "\(quality.runs)")
            }
            DisclosureGroup("What this measurement does and does not show (\(Self.shownWarnings(quality).count))", isExpanded: $showsLimits) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(Self.shownWarnings(quality).enumerated()), id: \.offset) { _, warning in bullet(warning) }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label + ":").foregroundStyle(Color.joseonSecondary)
            Text(value).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }

    // MARK: Step 5 — result

    private var plotSeries: [MeasurePlotSeries] {
        var out: [MeasurePlotSeries] = []
        if let target = controller.environment.target()?.normalizedTo1kHz() {
            out.append(MeasurePlotSeries(id: "target", title: "Target: \(target.name)", color: MeasurePlotColors.target, style: .dotted, lineWidth: 1.5,
                                         frequenciesHz: target.frequenciesHz, levelsDB: target.levelsDB))
        }
        if let autoEq = controller.environment.headphone()?.normalizedTo1kHz() {
            out.append(MeasurePlotSeries(id: "autoeq", title: "Published: \(autoEq.name)", color: MeasurePlotColors.autoEq, style: .dashed, lineWidth: 1.5,
                                         frequenciesHz: autoEq.frequenciesHz, levelsDB: autoEq.levelsDB))
        }
        let both = controller.results.count == 2
        for side in MeasureSide.allCases {
            guard let curve = controller.results[side]?.measured.curve else { continue }
            out.append(MeasurePlotSeries(id: side.rawValue, title: "Measured, \(side.title.lowercased())", color: side == .left ? MeasurePlotColors.left : MeasurePlotColors.right,
                                         style: .solid, lineWidth: both ? 1.5 : 2.2, frequenciesHz: curve.frequenciesHz, levelsDB: curve.levelsDB))
        }
        if both, let average = controller.result(for: .average)?.measured.curve {
            out.append(MeasurePlotSeries(id: "average", title: "Measured, average", color: MeasurePlotColors.average, style: .solid, lineWidth: 2.2,
                                         frequenciesHz: average.frequenciesHz, levelsDB: average.levelsDB))
        }
        return out
    }

    /// The window limit, the sweep start, and the frequency where the signal stands 10 dB clear of the noise.
    static func lowestHonestHz(_ quality: MeasurementQuality) -> Double {
        max(20, Double(quality.lowestResolvedHz), Double(quality.lowestTrustedHz(minimumDB: 10) ?? 0))
    }

    /// ONE lower-limit number with ONE cause, for the result page: the cause that sets `lowestHonestHz`.
    static func lowestHonestText(_ quality: MeasurementQuality) -> String {
        let honest = lowestHonestHz(quality)
        let noise = Double(quality.lowestTrustedHz(minimumDB: 10) ?? 0), window = Double(quality.lowestResolvedHz)
        let cause: String
        if noise >= window, noise > 20 {
            cause = "under it the sweep stands less than 10 dB clear of the room noise, so the curve there is noise, not the headphone"
        } else if window > 20 {
            cause = "the analysis window is too short to resolve anything under it"
        } else {
            cause = "the sweep starts there"
        }
        return "Not reliable under \(Int(honest.rounded())) Hz: \(cause)."
    }

    /// The module's list names the window limit with a number of its own (for example "under about 10 Hz"). The result
    /// page gives one lower limit with one cause (`lowestHonestText`), so that line stays out of the list here. The
    /// saved file keeps the full list.
    static func shownWarnings(_ quality: MeasurementQuality) -> [String] {
        quality.warnings.filter { !$0.hasPrefix("The analysis window is") }
    }

    /// Mean and largest difference between the measured and the published curve, 100 Hz … 10 kHz, and the mean
    /// difference in the bass, 30 … 100 Hz (the range a seal leak changes).
    static func comparison(measured: HeadphoneCurve, published: HeadphoneCurve) -> String {
        let reference = CurveInterpolator(curve: published.normalizedTo1kHz())
        var sum = 0.0, count = 0.0, worst = 0.0, worstHz = 0.0
        for (f, v) in zip(measured.frequenciesHz, measured.levelsDB) where f >= 100 && f <= 10_000 {
            let d = Double(v - reference.level(atHz: f))
            sum += abs(d); count += 1
            if abs(d) > abs(worst) { worst = d; worstHz = Double(f) }
        }
        guard count > 0 else { return "" }
        var text = "Against the published curve: 100 Hz – 10 kHz \(NumberText.signed(sum / count, decimals: 1)) dB mean difference, largest \(NumberText.signed(worst, decimals: 1, plus: true)) dB at \(hzText((worstHz / 10).rounded() * 10))"
        if let bass = MeasureController.bassDifferenceDB(measured: measured, published: published) {
            text += "; 30 – 100 Hz \(NumberText.signed(bass, decimals: 1, plus: true)) dB mean (measured minus published)"
        }
        return text + "."
    }

    @ViewBuilder private var resultStep: some View {
        if let choice = controller.headlineChoice, let headline = controller.result(for: choice) {
            let quality = headline.measured.quality
            let honest = Self.lowestHonestHz(quality)
            let comparison = controller.environment.headphone().map { Self.comparison(measured: headline.measured.curve, published: $0) } ?? ""
            VStack(alignment: .leading, spacing: 14) {
                stepTitle("Your headphone, measured.", "All curves are set to 0 dB at 1 kHz. The published curve is one sample of the model on a standard rig; yours is this unit on your rig.")
                VStack(alignment: .leading, spacing: 6) {
                    MeasureResponsePlot(series: plotSeries, lowestHonestHz: honest, summary: comparison)
                        .frame(height: 250)
                    legend
                    HStack(spacing: 10) {
                        Picker("Smoothing", selection: $controller.smoothing) {
                            Text("1/12 octave").tag(SweepAnalysis.OctaveSmoothing.twelfth)
                            Text("1/6 octave").tag(SweepAnalysis.OctaveSmoothing.sixth)
                            Text("1/3 octave").tag(SweepAnalysis.OctaveSmoothing.third)
                        }
                        .pickerStyle(.segmented).fixedSize()
                        Text("Measured curves only").font(.footnote).foregroundStyle(Color.joseonSecondary)
                    }
                    Text(Self.lowestHonestText(quality))
                        .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
                    if !comparison.isEmpty {
                        Text(comparison).font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if controller.environment.headphone() == nil {
                        Text("No headphone is selected in the main window, so there is no published curve to compare with.")
                            .font(.footnote).foregroundStyle(Color.joseonSecondary)
                    }
                }
                // Directly under the chart and its legend group: the one warning that should stop a save is on screen
                // with the curve it is about, not below SENSITIVITY.
                if let leak = controller.leakWarning(for: saveChoice) { leakNotice(leak) }
                sidesBlock
                qualityBlock(quality, title: choice == .average ? "QUALITY (WORSE OF THE TWO SIDES)" : "QUALITY, \(choice.title.uppercased()) SIDE")
                sensitivityBlock
                saveBlock
            }
            .onAppear { if saveName.isEmpty { saveName = controller.suggestedSaveName } }
        } else {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Building the result…").font(.callout) }
        }
    }

    private var legend: some View {
        let items = plotSeries
        return VStack(alignment: .leading, spacing: 3) {
            // Two rows at most: the measured curves first, then what they are compared with.
            HStack(spacing: 14) { ForEach(items.filter { $0.id != "target" && $0.id != "autoeq" }) { MeasureLegendItem(series: $0) } }
            HStack(spacing: 14) { ForEach(items.filter { $0.id == "target" || $0.id == "autoeq" }) { MeasureLegendItem(series: $0) } }
        }
    }

    private var sidesBlock: some View {
        section("SIDES") {
            ForEach(MeasureSide.allCases) { side in
                if let result = controller.results[side] {
                    fact(side.title, "\(result.measured.quality.runs) run\(result.measured.quality.runs == 1 ? "" : "s")"
                         + (result.measured.quality.runs > 1 ? ", agreement \(NumberText.signed(Double(result.measured.quality.agreementDB), decimals: 2)) dB" : ""))
                } else {
                    fact(side.title, "not measured")
                }
            }
            if controller.results.count == 1, let done = controller.results.keys.first {
                Button("Measure the \(done.other.title.lowercased()) side…") { controller.measureOtherSide() }
                    .help("Keeps this result. Put the other cup on the rig, then record the room noise and the runs again.")
                Text("With both sides Joseon shows both curves and their average.")
                    .font(.footnote).foregroundStyle(Color.joseonSecondary)
            }
        }
    }

    private var sensitivityBlock: some View {
        section("SENSITIVITY OF THIS UNIT") {
            switch controller.sensitivityState {
            case .available(let value, let uncertainty, let components, let spl, let volts, let basis):
                Text("\(NumberText.signed(value, decimals: 1)) dB SPL/V  \(controller.sensitivityUncertaintyHeadline)")
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .accessibilityLabel("\(NumberText.signed(value, decimals: 1)) dB SPL per volt, plus or minus \(NumberText.signed(uncertainty, decimals: 1)) dB")
                Text("At 1 kHz (mean 800 – 1250 Hz), \(basis): \(NumberText.signed(spl, decimals: 1)) dB SPL at \(Self.voltText(volts)) RMS. This holds for the amplifier knob position of the level calibration “\(controller.environment.playback()?.calibration.name ?? "")”, and for your rig: a flat plate reads differently from an ear simulator.")
                    .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
                Text("Uncertainty: " + components.map { "\($0.name) ± \(NumberText.signed($0.dB, decimals: 1)) dB" }.joined(separator: "; ") + ". Added as squares.")
                    .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
                impedanceField
                let headphone = controller.environment.headphone()?.name ?? ""
                if controller.sensitivityStoredFor == headphone {
                    note("Stored for \(headphone). Source: “\(controller.sensitivitySourceText)”. You can remove it in Settings → Level at the ear.", symbol: "checkmark.circle.fill", tint: Color(nsColor: Palette.live))
                } else {
                    Button("Use this sensitivity for \(headphone)") { controller.useSensitivity() }
                        .help("Stores it as your sensitivity of \(headphone). It replaces a typed-in value and wins over the built-in one.")
                }
            case .missing(let reasons):
                Text("Not available. Joseon gives a sensitivity only when nothing in it is a guess. Missing:")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                ForEach(reasons, id: \.self) { bullet($0) }
                if reasons.contains(where: { $0.contains("impedance") }) { impedanceField }
            }
        }
    }

    private var impedanceField: some View {
        HStack(spacing: 8) {
            Text("Impedance").foregroundStyle(Color.joseonSecondary)
            TextField("for example 45", text: $controller.impedanceText)
                .textFieldStyle(.roundedBorder).frame(width: 110)
                .accessibilityLabel("Impedance of the headphone in ohms")
            Text("Ω").foregroundStyle(Color.joseonSecondary)
        }
        .font(.system(size: 12))
    }

    static func voltText(_ v: Double) -> String {
        v < 0.1 ? "\(NumberText.signed(v * 1000, decimals: 1)) mV" : "\(NumberText.signed(v, decimals: 3)) V"
    }

    /// One question belongs to one curve and one name: a new pick or a new name takes the question away.
    private var saveQuestionKey: String { "\(saveChoice.id)|\(saveName)" }

    private var saveChoice: MeasureSaveChoice {
        if let picked = pickedSaveChoice, controller.availableSaveChoices.contains(picked) { return picked }
        return controller.headlineChoice ?? .left
    }

    /// Amber, directly under the chart and its legend group (above SIDES): the measured bass is far under the
    /// published curve of the selected model, and there is enough signal at 40 Hz to call it a leak and not noise.
    /// It is about the curve picked under SAVE. With two sides measured the card names that curve, because the
    /// QUALITY block under it is about the average.
    private func leakNotice(_ leak: MeasureController.LeakWarning) -> some View {
        let about = controller.availableSaveChoices.count > 1 ? "Curve to save: \(saveChoice.title.lowercased()). " : ""
        return leakCard(leak, about: about)
    }

    private func leakCard(_ leak: MeasureController.LeakWarning, about: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.joseonWarn).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(leak.notice).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(about + leak.detail).font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.joseonWarn.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.joseonWarn.opacity(0.7), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warning. \(leak.notice). \(about)\(leak.detail)")
    }

    private var saveBlock: some View {
        section("SAVE") {
            if controller.availableSaveChoices.count > 1 {
                Picker("Curve to save", selection: Binding(get: { saveChoice }, set: { pickedSaveChoice = $0 })) {
                    ForEach(controller.availableSaveChoices) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 330, alignment: .leading)
            }
            HStack(spacing: 8) {
                TextField("Name of the curve", text: $saveName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name of the curve")
                Button("Save as my curve") {
                    // With a likely seal leak, or a stored curve of this name, the first press only asks; the save
                    // needs the second, named button.
                    if controller.saveConfirmation(choice: saveChoice, name: saveName).isNeeded { saveQuestionFor = saveQuestionKey } else { controller.save(choice: saveChoice, name: saveName) }
                }
                .disabled(MeasureController.fileSafe(saveName).isEmpty || saveQuestionFor == saveQuestionKey)
                .fixedSize()
            }
            let needs = controller.saveConfirmation(choice: saveChoice, name: saveName)
            let asking = saveQuestionFor == saveQuestionKey && needs.isNeeded
            if asking {
                VStack(alignment: .leading, spacing: 6) {
                    if let leak = needs.leak { note(leak.saveQuestion, symbol: "exclamationmark.triangle.fill", tint: .joseonWarn) }
                    if let question = needs.overwriteQuestion { note(question, symbol: "exclamationmark.triangle.fill", tint: .joseonWarn) }
                    HStack(spacing: 8) {
                        Button("Do not save") { saveQuestionFor = nil }.keyboardShortcut(.cancelAction)
                        // The button says yes to exactly what the question above it named, not to more.
                        Button(needs.confirmTitle) {
                            controller.save(choice: saveChoice, name: saveName, confirmedLeak: needs.leak != nil, confirmedOverwrite: needs.replaces != nil)
                            saveQuestionFor = nil
                        }
                    }
                    .controlSize(.small)
                }
            }
            if let saved = controller.savedName {
                note("Saved “\(saved)” and selected it in the headphone picker. A level calibration belongs to one headphone name: with the new name selected, make the level calibration again (or go back to the published name to keep the old one).", symbol: "checkmark.circle.fill", tint: Color(nsColor: Palette.live))
            }
            if let existing = needs.replaces, existing != controller.savedName, !asking {
                note("A curve with this name exists. Saving replaces it: Joseon asks first.", symbol: "exclamationmark.triangle", tint: .joseonWarn)
            }
            Text("Saves one small text file: the curve (frequency and dB), with the method and the limits as comment lines, in ~/Library/Application Support/Joseon/Curves. No recording is saved, now or later.")
                .font(.footnote).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Parts

    private func stepTitle(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.callout).foregroundStyle(Color.joseonSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).kerning(0.4).foregroundStyle(Color.joseonSecondary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.joseonPanel))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: Palette.cardBorder), lineWidth: 1))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("•").foregroundStyle(Color.joseonSecondary).accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
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

/// The measurement window. One at a time. Closing it stops the sweep, closes the input and drops every recording:
/// the controller lives only as long as the window.
final class MeasureWindowController: NSObject, NSWindowDelegate {
    private let makeEnvironment: () -> MeasureEnvironment
    private(set) var window: NSWindow?
    private(set) var controller: MeasureController?

    static let defaultSize = NSSize(width: 680, height: 800)
    static let minimumSize = NSSize(width: 580, height: 620)

    init(makeEnvironment: @escaping () -> MeasureEnvironment) { self.makeEnvironment = makeEnvironment }

    func show(size: NSSize = MeasureWindowController.defaultSize) {
        if let window { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return }
        let controller = MeasureController(environment: makeEnvironment())
        self.controller = controller
        let view = MeasureView(controller: controller) { [weak self] in self?.window?.close() }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.title = "Measure your headphone"
        w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Palette.background
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.contentMinSize = Self.minimumSize
        w.setContentSize(size)
        w.center()
        w.delegate = self
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// The output device changed (from the app's output monitor): a sweep must not go on into another device.
    func outputDeviceChanged() {
        guard let controller, controller.activity.makesSound else { return }
        controller.abort("The output device changed during the run, so Joseon stopped the sweep and dropped the recording.")
    }

    func windowWillClose(_ notification: Notification) {
        controller?.windowClosed()
        controller = nil
        window = nil
    }

    func shutdown() { controller?.windowClosed() }
}
