import AVFoundation
import Foundation
import JoseonCore
import JoseonCapture
import JoseonHeadphones

// MARK: - Snapshot scenes (layout review only)

/// The pictures of "Measure your headphone…". Snapshot mode builds the window with the FAKE seams of
/// `MeasureFakes.swift`; every scene drives the real controller through its normal calls. The curve in the pictures
/// is the simulated headphone of the fakes, and the window says "SNAPSHOT: fake" on every picture.
enum MeasureSnapshotScene: String, CaseIterable {
    case inputAsk = "1-input-ask"
    case inputDenied = "1-input-denied"
    case input = "1-input"
    case microphoneEmpty = "2-microphone-empty"
    case microphone = "2-microphone"
    case levelFirst = "3-level-first"
    case levelGood = "3-level-good"
    case levelClipped = "3-level-clipped"
    case measureStart = "4-measure-start"
    case measureRuns = "4-measure-runs"
    case resultOneSide = "5-result-one-side"
    case resultBoth = "5-result-both"

    /// Time between the scene's calls and its picture: the fake runs take no time, the analysis takes some.
    var settleSeconds: Double {
        switch self {
        case .levelGood, .levelClipped, .measureStart: return 1.5
        case .measureRuns, .resultOneSide: return 3.0
        case .resultBoth: return 5.0
        default: return 0.6
        }
    }
}

enum MeasureSnapshot {
    /// A made-up calibration file in the miniDSP format, for the pictures.
    static let fakeMicFile = """
    "Sens Factor =-1.37dB, SERNO: 0000000 (SNAPSHOT FAKE)"
    20\t-0.8\t0
    50\t-0.3\t0
    100\t-0.1\t0
    1000\t0.0\t0
    3000\t0.2\t0
    6000\t0.9\t0
    10000\t1.8\t0
    15000\t0.6\t0
    20000\t-1.9\t0
    """
    static let fakeCouplerFile = "20 2.5\n60 1.0\n200 0.0\n1000 0.0\n3000 -1.5\n8000 -3.0\n20000 -1.0\n"

    /// Runs `operations` one after the other; each waits until the controller is idle again.
    static func drive(_ controller: MeasureController, _ operations: [() -> Void]) {
        var queue = operations
        func step() {
            guard controller.activity == .idle else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: step); return }
            guard !queue.isEmpty else { return }
            queue.removeFirst()()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: step)
        }
        step()
    }

    static func apply(_ scene: MeasureSnapshotScene, to c: MeasureController, link: FakeAcousticLink) {
        precondition(DebugSnapshot.directory != nil, "measurement snapshot scenes are for snapshot runs only")
        func permit() -> TonePlayPermit { TonePlayPermit.offline()! }
        let check: () -> Void = { c.rigConfirmed = true; c.startLevelCheck(permit: permit()) }
        let run: () -> Void = { c.rigConfirmed = true; c.startRun(permit: permit()) }
        switch scene {
        case .inputAsk:
            link.gainDB = 3; link.headphoneVariation = 0; link.fault = nil; link.fakePlayback = nil
            link.seatJitterDB = 0.6; link.noiseDBFS = -70; link.rumbleDBFS = -30; link.leakHz = 90
            link.permission = .notDetermined
            c.refreshDevices()
        case .inputDenied:
            link.permission = .denied
            c.refreshDevices()
        case .input:
            link.permission = .authorized
            c.refreshDevices()
            c.deviceUID = "fake-interface"
            c.channel = 1
        case .microphoneEmpty:
            c.go(to: .microphone)
        case .microphone:
            c.loadMicCalibration(text: fakeMicFile, fileName: "SNAPSHOT fake mic 0deg.txt")
            c.loadCoupler(text: fakeCouplerFile, fileName: "SNAPSHOT fake plate correction.txt")
            c.rigNote = "flat plate, 3D-printed, foam seal"
        case .levelFirst:
            c.go(to: .level)
        case .levelGood:
            drive(c, [check, { c.raiseLevel() }, check, { c.raiseLevel() }, check])
        case .levelClipped:
            drive(c, [{ link.gainDB = 40 }, check])
        case .measureStart:
            drive(c, [{ link.gainDB = 3 }, check, { c.go(to: .measure) }])
        case .measureRuns:
            drive(c, [{ c.recordNoise() }, run, run])
        case .resultOneSide:
            drive(c, [run, run, { c.go(to: .result) }])
        case .resultBoth:
            drive(c, [{ c.measureOtherSide(); link.headphoneVariation = 1.5 }, { c.recordNoise() }, run, run, run, run, {
                // Made-up numbers so the sensitivity block shows its "available" state.
                link.fakePlayback = PlaybackCalibration(name: "Snapshot DAC · stub preset", method: .measuredVoltage, fullScaleVrms: 2.0, uncertaintyDB: 2)
                c.calibratorText = "−12.0"
                c.impedanceText = "50"
                c.go(to: .result)
            }])
        }
    }
}

// MARK: - Self-check

/// JOSEON_MEASURE_SELFCHECK=1 (debug builds): drives the WHOLE measurement controller offline, with a FAKE input and
/// a FAKE player, and checks the sweep player's generator and its real AVAudioEngine graph in offline manual
/// rendering mode (no output device). Prints PASS / FAIL lines and exits.
/// It opens no audio input, plays no sound, and never reaches `MicrophonePermission.request`: the fake input
/// stands in for all three.
enum MeasureSelfCheck {
    static var isRequested: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["JOSEON_MEASURE_SELFCHECK"] == "1"
        #else
        return false
        #endif
    }

    #if DEBUG
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
    }

    /// Spins the main run loop (timers and main-queue blocks run) until `condition` or the timeout.
    @discardableResult
    private static func wait(_ seconds: Double = 60, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return true
    }

    private static func idle(_ c: MeasureController, _ seconds: Double = 60) -> Bool { wait(seconds) { c.activity == .idle } }

    private static func permit(age: TimeInterval = 0) -> TonePlayPermit { TonePlayPermit.offline(age: age)! }

    static func run() -> Int32 {
        print("Joseon measurement self-check (offline: fake input, fake player, no sound, no microphone)")
        player()
        offlineGraph()
        controller()
        print(failures == 0 ? "RESULT PASS" : "RESULT FAIL (\(failures))")
        return failures == 0 ? 0 : 1
    }

    // MARK: Player

    private static func maxStep(_ x: [Float]) -> Double {
        var m = 0.0
        for i in 1..<max(x.count, 1) { m = max(m, Double(abs(x[i] - x[i - 1]))) }
        return m
    }

    private static func player() {
        let rate = 48_000.0
        // A constant: what comes out IS the player's envelope.
        let ones = [Float](repeating: 0.25, count: Int(rate))
        let out = BufferGenerator.renderAll(ones, sampleRate: rate)
        let fade = Int(BufferGenerator.fadeInSeconds * rate)
        var worst = 0.0
        for n in 0..<fade { worst = max(worst, abs(Double(out[n]) - 0.25 * 0.5 * (1 - cos(Double.pi * Double(n) / Double(fade))))) }
        check("player: fade-in is a \(Int(BufferGenerator.fadeInSeconds * 1000)) ms raised cosine from zero", out[0] == 0 && worst < 1e-6 && out[fade] == 0.25, String(format: "max error %.1e", worst))
        check("player: plays the buffer once, then ends", out.count == ones.count && out.last == 0.25)
        check("player: block size does not change the samples", out == BufferGenerator.renderAll(ones, sampleRate: rate, block: 137))

        // Hard length limit: a 13 s buffer is faded out before 12 s and nothing comes after.
        let long = [Float](repeating: 0.25, count: Int(13 * rate))
        var g = BufferGenerator(sampleRate: rate, buffer: PreparedBuffer(long))
        var rendered = [Float](repeating: 1, count: Int(13 * rate))
        rendered.withUnsafeMutableBufferPointer { g.render(into: $0.baseAddress!, count: $0.count) }
        let limit = Int(SignalPlayer.maxSeconds * rate)
        check("player: hard \(Int(SignalPlayer.maxSeconds)) s limit: faded before it, zeros after it",
              rendered[limit...].allSatisfy { $0 == 0 } && abs(rendered[limit - 1]) < 1e-4 && rendered[limit - Int(0.06 * rate)] == 0.25 && g.isFinished,
              String(format: "last sample before the limit %.1e", rendered[limit - 1]))

        // Stop in the middle: 50 ms raised-cosine fade-out, then zeros, no step.
        let sweep = MeasureSignal.sweep(sampleRate: rate, levelDBFS: -6).samples.map(Float.init)
        var s = BufferGenerator(sampleRate: rate, buffer: PreparedBuffer(sweep))
        var y = [Float](repeating: 0, count: sweep.count)
        let stopAt = Int(2.0137 * rate)
        y.withUnsafeMutableBufferPointer { p in
            var done = 0
            while done < p.count {
                if done >= stopAt { s.requestStop() }
                let n = min(441, p.count - done)
                s.render(into: p.baseAddress! + done, count: n)
                done += n
            }
        }
        let end = s.fadeOutStart + s.fadeOutSamples
        let reference = BufferGenerator.renderAll(sweep, sampleRate: rate)
        check("player: stop fades out in \(Int(BufferGenerator.fadeOutSeconds * 1000)) ms, then zeros", y[end...].allSatisfy { $0 == 0 } && s.isFinished && s.fadeOutStart >= stopAt && s.fadeOutStart < stopAt + 441)
        let untilStop = Array(reference[0..<end])
        check("player: stop makes no click", maxStep(y) <= maxStep(untilStop) * 1.02, String(format: "max step %.5f, the sweep up to that point %.5f", maxStep(y), maxStep(untilStop)))

        // The played sweep and the analysis reference are the same signal but for the first 20 ms.
        var difference = 0.0
        for i in 0..<sweep.count { difference = max(difference, Double(abs(reference[i] - sweep[i]))) }
        var lastChanged = 0
        for i in 0..<sweep.count where reference[i] != sweep[i] { lastChanged = i }
        let relative = 20 * log10(max(difference, 1e-12)) + 6
        check("player: its fade changes only the first 10 ms of the sweep, by less than −36 dB re the sweep peak",
              relative < -36 && lastChanged < Int(BufferGenerator.fadeInSeconds * rate), String(format: "largest change %.1f dB re peak, last changed sample %d", relative, lastChanged))
        for level in MeasureSignal.levelSteps {
            let peak = MeasureSignal.peakDB(MeasureSignal.sweep(sampleRate: rate, levelDBFS: level).samples.map(Float.init))
            check("signal: sweep at \(Int(level)) dBFS peaks at \(Int(level)) dBFS", abs(peak - level) < 0.05, String(format: "%.3f dBFS", peak))
        }
        check("signal: first level is −30 dBFS, steps are 6 dB, top is −6 dBFS",
              MeasureSignal.levelSteps.first == -30 && MeasureSignal.levelSteps.last == -6 && zip(MeasureSignal.levelSteps, MeasureSignal.levelSteps.dropFirst()).allSatisfy { $1 - $0 == 6 })

        // Refusals.
        check("player: refuses a buffer louder than −6 dBFS", SignalPlayer.refusal(samples: MeasureSignal.sweep(sampleRate: rate, levelDBFS: -3).samples.map(Float.init), sampleRate: rate) != nil)
        check("player: accepts the sweep at −6 dBFS", SignalPlayer.refusal(samples: sweep, sampleRate: rate) == nil)
        check("player: refuses a buffer longer than \(Int(SignalPlayer.maxSeconds)) s", SignalPlayer.refusal(samples: long, sampleRate: rate) != nil)
        check("player: refuses a damaged buffer (NaN)", SignalPlayer.refusal(samples: [0, .nan, 0], sampleRate: rate) != nil)
        check("player: refuses an empty buffer", SignalPlayer.refusal(samples: [], sampleRate: rate) != nil)
        check("permit: an offline permit starts nothing in the real player", SignalPlayer.permitRefusal(permit()) != nil)
        check("permit: no offline permit outside self-check and snapshot mode", TonePlayPermit.processIsOffline)   // the factory is nil otherwise
        let real = SignalPlayer()
        var ended = false
        let refusal = real.play(sweep, permit: permit()) { _ in ended = true }
        check("real SignalPlayer.play in this process: refused before it touches the audio engine", refusal != nil && !real.isPlaying && !ended, refusal ?? "")
        check("real SignalPlayer: no output format is read in an offline process", real.outputSampleRate == 0)
    }

    /// The real node graph of `SignalPlayer` (source node -> output node) in offline manual rendering mode.
    private static func offlineGraph() {
        let rate = 48_000.0
        let sweep = MeasureSignal.sweep(sampleRate: rate, levelDBFS: -30, seconds: 2).samples.map(Float.init)
        let shared = ToneShared()
        guard let source = SignalPlayer.makeSourceNode(sampleRate: rate, buffer: PreparedBuffer(sweep), shared: shared) else { check("offline engine graph", false, "no format"); return }
        let engine = AVAudioEngine()
        do {
            try engine.enableManualRenderingMode(.offline, format: source.format, maximumFrameCount: 4096)
            engine.attach(source.node)
            engine.connect(source.node, to: engine.outputNode, format: source.format)
            try engine.start()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { check("offline engine graph", false, "no buffer"); return }
            var left: [Float] = [], right: [Float] = []
            while left.count < sweep.count + 8192 {
                guard try engine.renderOffline(4096, to: buffer) == .success, let data = buffer.floatChannelData else { break }
                let n = Int(buffer.frameLength)
                left += UnsafeBufferPointer(start: data[0], count: n)
                right += UnsafeBufferPointer(start: data[1], count: n)
            }
            engine.stop()
            let expected = BufferGenerator.renderAll(sweep, sampleRate: rate)
            var worst: Float = 0
            for i in 0..<min(expected.count, left.count) { worst = max(worst, abs(left[i] - expected[i])) }
            check("engine graph (offline): the output node carries the sweep, sample for sample", left.count >= expected.count && worst < 1e-6, String(format: "max error %.1e", worst))
            check("engine graph (offline): left equals right", left == right && !left.isEmpty)
            check("engine graph (offline): silence after the buffer, and the render thread says finished",
                  left[expected.count...].allSatisfy { $0 == 0 } && shared.read().finished)
        } catch {
            check("offline engine graph", false, "\(error)")
        }
    }

    // MARK: Controller

    private static let plainMicFile = "20 0.5\n100 0.0\n1000 0.0\n5000 0.4\n10000 1.2\n20000 -1.0\n"
    private static let umikFile = "\"Sens Factor =-1.37dB, SERNO: 0000000\"\r\n20\t0.5\t0\r\n100\t0\t0\r\n1000\t0\t0\r\n5000\t0.4\t0\r\n10000\t1.2\t0\r\n20000\t-1.0\t0\r\n"

    private static func controller() {
        let link = FakeAcousticLink()
        link.permission = .notDetermined
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("joseon-measure-selfcheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = HeadphoneLibrary(userCurvesDirectory: directory)
        let store = SPLCalibrationStore(defaults: nil)
        let published = library.allCurves().first
        /// What the environment hands out as the selected model. The leak-guard checks swap it for a bass-heavy one.
        var selectedModel = published
        let fakePlayer = FakeSignalPlayer(link: link)
        let environment = MeasureEnvironment(
            input: FakeMeasureInput(link: link), player: fakePlayer, timing: .fake,
            headphone: { selectedModel }, target: { library.allTargets().first },
            playback: { link.fakePlayback.map { ($0, "Self-check DAC") } },
            knownImpedanceOhms: { nil },
            importCurve: { url in do { try library.importCurve(from: url); return nil } catch { return "\(error)" } },
            curveExists: { name in library.userCurves().contains { $0.name == name } },
            storeSensitivity: { entry, name in store.setUserSensitivity(entry, headphone: name) },
            outputName: { "Self-check DAC" })
        let c = MeasureController(environment: environment)
        /// The user ticks the safety checkbox. Every sweep needs it again: the controller clears it when a sweep starts.
        func tick() { c.rigConfirmed = true }
        check("safety: the checkbox starts unticked in a new window", !c.rigConfirmed)

        // Step 1: input and permission.
        check("start: step 1, nothing asked, nothing opened", c.step == .input && link.permissionRequests == 0 && link.capturesOpened == 0 && link.playCount == 0)
        check("devices: virtual and aggregate devices are last; a USB microphone is preselected",
              c.devices.last?.transport == .virtual && c.devices.dropLast().allSatisfy { !MeasureController.listedLast($0) } && c.selectedDevice?.transport == .usb)
        check("step 1 blocks without the microphone permission", c.blocker(after: .input) != nil && !c.canShow(.microphone))
        c.next()
        check("steps: Next does not advance past a blocker", c.step == .input)
        c.rigConfirmed = true
        tick(); c.startLevelCheck(permit: permit())
        check("no permission: a check opens no input and plays nothing", c.activity == .idle && link.capturesOpened == 0 && link.playCount == 0 && c.message != nil)
        c.requestPermissionFromButton()
        wait(2) { c.permission == .authorized }
        check("permission: asked exactly once, by the button's action", link.permissionRequests == 1 && c.permission == .authorized)
        c.next()
        check("steps: 1 → 2 with device and permission", c.step == .microphone)

        // Step 2: files.
        c.loadMicCalibration(text: "this is not a calibration file", fileName: "bad.txt")
        check("microphone: a bad file gives an error and no calibration", c.micInfo == nil && c.micError != nil)
        c.loadMicCalibration(text: plainMicFile, fileName: "plain.txt")
        check("microphone: a two-column file loads: 6 points, no sensitivity factor, a sparkline",
              c.micInfo?.pointCount == 6 && c.micInfo?.sensFactorDB == nil && c.micInfo?.sparkline.count == MeasureController.sparklineGrid.count && c.micError == nil)
        c.rigNote = "flat plate, self-check"
        c.next()
        check("steps: 2 → 3", c.step == .level)

        // Step 3: permit, forced first level, 6 dB steps.
        check("step 3 blocks before a level check", c.blocker(after: .level) != nil && !c.canShow(.measure))
        check("level: the first level is −30 dBFS and can not be raised before a check", c.playLevelDBFS == -30 && !c.canRaiseLevel)
        c.raiseLevel()
        check("level: raise without a check does nothing", c.playLevelDBFS == -30)
        c.rigConfirmed = false
        c.startLevelCheck(permit: permit())
        check("permit: without the checkbox nothing opens and nothing plays", c.activity == .idle && link.playCount == 0 && link.capturesOpened == 0 && c.message != nil)
        c.rigConfirmed = true
        c.startLevelCheck(permit: permit(age: 5))
        check("permit: a press that is 5 s old starts nothing", c.activity == .idle && link.playCount == 0 && link.capturesOpened == 0)
        link.gainDB = -8
        tick(); c.startLevelCheck(permit: permit())
        check("level check: busy while it runs", c.activity == .levelCheck)
        idle(c)
        check("level check: first sweep played at −30 dBFS", link.playCount == 1 && abs(link.lastPlayedPeakDB + 30) < 0.1, String(format: "%.2f dBFS", link.lastPlayedPeakDB))
        check("safety: the sweep cleared the checkbox (single use)", !c.rigConfirmed)
        let playsAfterFirst = link.playCount
        c.startLevelCheck(permit: permit())
        check("safety: a second press without a NEW tick plays nothing", c.activity == .idle && link.playCount == playsAfterFirst && c.message != nil)
        check("level check: low input passes with advice", c.levelCheck?.verdict == .low && c.levelCheckPassed, "input peak \(MeasureController.dbText(c.levelCheck?.inputPeakDB ?? 0)) dBFS")
        var walked: [Double] = [c.playLevelDBFS]
        while c.canRaiseLevel {
            c.raiseLevel()
            let raisedWithoutCheck = c.canRaiseLevel
            if raisedWithoutCheck { check("level: a new level needs its own check", false); break }
            tick(); c.startLevelCheck(permit: permit()); idle(c)
            walked.append(c.playLevelDBFS)
        }
        check("level: up in 6 dB steps to −6 dBFS, one check per step, never higher", walked == MeasureSignal.levelSteps && abs(link.lastPlayedPeakDB + 6) < 0.1 && !c.canRaiseLevel,
              walked.map { String(Int($0)) }.joined(separator: " → "))
        while c.canLowerLevel { c.lowerLevel() }
        check("level: lower goes back to −30 dBFS and needs a new check", c.playLevelDBFS == -30 && !c.levelCheckPassed)

        // A clipped input blocks the run.
        link.gainDB = 40
        tick(); c.startLevelCheck(permit: permit()); idle(c)
        check("clip: the level check sees it", c.levelCheck?.verdict == .clipped && !c.levelCheckPassed)
        check("clip: step 4 stays closed", c.blocker(after: .level) != nil && !c.canShow(.measure))
        c.go(to: .measure)
        check("clip: the step does not advance", c.step == .level)
        var plays = link.playCount
        tick(); c.startRun(permit: permit())
        check("clip: a run does not start", c.activity == .idle && link.playCount == plays && c.runs.isEmpty)
        link.gainDB = 9
        tick(); c.startLevelCheck(permit: permit()); idle(c)
        c.raiseLevel(); tick(); c.startLevelCheck(permit: permit()); idle(c)
        check("level check: inside the target zone at −24 dBFS", c.levelCheck?.verdict == .good && c.playLevelDBFS == -24, "input peak \(MeasureController.dbText(c.levelCheck?.inputPeakDB ?? 0)) dBFS")
        c.next()
        check("steps: 3 → 4 after a clean check", c.step == .measure)

        // Step 4: noise, N runs, average.
        c.runsWanted = 3
        plays = link.playCount
        tick(); c.startRun(permit: permit())
        check("measure: no run before the room noise", c.activity == .idle && link.playCount == plays)
        c.recordNoise(); idle(c)
        check("measure: room noise recorded without playing anything", c.noiseDone && link.playCount == plays, "\(MeasureController.dbText(c.noiseRMSDB ?? 0)) dBFS RMS")
        check("step 4 blocks before the first run", c.blocker(after: .measure) != nil)
        for index in 1...3 {
            tick(); c.startRun(permit: permit())
            if index == 1 { check("measure: busy while the run plays", c.activity == .run(1)) }
            idle(c)
        }
        check("safety: every run cleared the checkbox", !c.rigConfirmed)
        let playsAfterRuns = link.playCount
        c.runsWanted = 4
        c.startRun(permit: permit())
        check("safety: a run without a NEW tick plays nothing", c.activity == .idle && link.playCount == playsAfterRuns && c.runs.count == 3 && c.message != nil)
        c.runsWanted = 3
        check("measure: 3 runs recorded, one sweep each, at the checked level", c.runs.count == 3 && link.playCount == plays + 3 && abs(link.lastPlayedPeakDB + 24) < 0.1)
        let delays = c.runs.map(\.delayMilliseconds)
        check("measure: each run reports the play-to-record delay", delays.allSatisfy { abs($0 - 3733.0 / 48.0) < 0.1 }, delays.map { String(format: "%.2f ms", $0) }.joined(separator: ", "))
        check("measure: agreement from the second run on, S/N at 1 kHz on every run",
              c.runs[0].agreementDB == nil && c.runs[1].agreementDB != nil && c.runs[2].agreementDB != nil && c.runs.allSatisfy { ($0.snrAt1kHzDB ?? 0) > 30 },
              "agreement \(String(format: "%.3f", c.runs[2].agreementDB ?? -1)) dB, S/N \(String(format: "%.0f", c.runs[2].snrAt1kHzDB ?? -1)) dB")
        tick(); c.startRun(permit: permit())
        check("measure: no run beyond the chosen number", c.activity == .idle && link.playCount == plays + 3)
        wait(30) { c.results[.left] != nil }
        check("measure: the 3 runs are averaged into one result", c.results[.left]?.measured.quality.runs == 3 && c.liveQuality?.runs == 3)
        check("threads: the analysis never ran on the main thread", !c.analysisRanOnMainThread)

        // A clip in the middle of the runs: the run is dropped, the level check is void.
        c.runsWanted = 4
        link.gainDB = 40
        tick(); c.startRun(permit: permit()); idle(c)
        check("clip in a run: dropped, not averaged, level check void", c.runs.count == 3 && c.message != nil && !c.levelCheckPassed && c.levelCheck?.verdict == .clipped)
        link.gainDB = 9
        c.runsWanted = 3

        // Step 5: the curve against the simulated truth.
        c.go(to: .result)
        check("steps: 4 → 5", c.step == .result)
        wait(30) { c.results[.left] != nil }
        let grid = SweepAnalysis.standardGrid
        func worstError(_ curve: HeadphoneCurve, _ truth: [Double], micCorrection: [Double]) -> (Double, Double) {
            var worst = 0.0, at = 0.0
            // The fake chain has no microphone response, so the applied calibration shows up as its negative.
            let reference = zip(truth, micCorrection).map { $0 - $1 }
            let inBand = zip(grid, reference).filter { $0.0 >= 800 && $0.0 <= 1250 }.map(\.1)
            let shift = inBand.reduce(0, +) / Double(max(inBand.count, 1))
            for (i, f) in grid.enumerated() where f >= 40 && f <= 16_000 {
                let d = abs(Double(curve.levelsDB[i]) - (reference[i] - shift))
                if d > worst { worst = d; at = f }
            }
            return (worst, at)
        }
        let micCorrection = (try? MicCalibration.parse(text: plainMicFile, name: "plain"))?.correctionDB(onGrid: grid) ?? []
        if let left = c.results[.left] {
            let (worst, at) = worstError(left.measured.curve, link.headphone.normalizedResponseDB(onGrid: grid), micCorrection: micCorrection)
            check("result: the curve matches the simulated headphone within 0.5 dB, 40 Hz – 16 kHz", worst < 0.5, String(format: "worst %.3f dB at %.0f Hz", worst, at))
            check("result: the warnings name the missing coupler correction and the rig limits", left.measured.quality.warnings.contains { $0.contains("coupler") })
            let honest = MeasureView.lowestHonestHz(left.measured.quality)
            check("result: a lowest honest frequency is stated", honest >= 20 && honest < 60, String(format: "%.0f Hz", honest))
        } else {
            check("result: a curve exists", false)
        }
        let fine = c.results[.left]?.measured.curve.levelsDB ?? []
        c.smoothing = .third
        wait(30) { (c.results[.left]?.measured.curve.levelsDB ?? fine) != fine }
        let coarse = c.results[.left]?.measured.curve.levelsDB ?? []
        check("result: 1/3 octave smoothing builds a new, smoother curve from the same runs", coarse != fine && coarse.count == fine.count && coarse.allSatisfy { $0.isFinite }
              && c.results[.left]?.measured.quality.runs == 3)
        c.smoothing = .twelfth
        wait(30) { (c.results[.left]?.measured.curve.levelsDB ?? []) == fine }

        // Sensitivity: unavailable without absolute level, available with it.
        if case .missing(let reasons) = c.sensitivityState {
            check("sensitivity: not available without absolute level, and the text says which piece is missing",
                  reasons.contains { $0.contains("absolute level") } && reasons.contains { $0.contains("level calibration") } && reasons.contains { $0.contains("impedance") },
                  "\(reasons.count) missing pieces")
        } else {
            check("sensitivity: not available without absolute level", false)
        }
        c.useSensitivity()
        check("sensitivity: nothing is stored while it is unavailable", store.userSensitivity(headphone: published?.name ?? "") == nil)
        c.calibratorText = "-12.0"
        if case .missing(let reasons) = c.sensitivityState {
            check("sensitivity: with a calibrator reading, still not available without a level calibration", !reasons.contains { $0.contains("absolute level") } && reasons.contains { $0.contains("level calibration") })
        } else { check("sensitivity: needs the level calibration too", false) }
        link.fakePlayback = PlaybackCalibration(name: "Self-check preset", method: .measuredVoltage, fullScaleVrms: 2.0, uncertaintyDB: 2)
        c.impedanceText = "45"
        wait(30) { c.results[.left]?.derived != nil }
        // dB SPL/V = 20·log10|H(1 kHz)| − 3.01 + (94 − reading) − 20·log10(full-scale volts); |H| here is the fake gain
        // (the simulated headphone is 0 dB at 1 kHz to within 0.1 dB, and so is the microphone file).
        let h1k = link.gainDB + link.headphone.responseDB(atHz: 1000)
        let expected = h1k - 3.0103 + (94 + 12) - 20 * log10(2.0)
        if case .available(let value, let uncertainty, let components, _, let volts, _) = c.sensitivityState {
            check("sensitivity: available with a calibrator reading and a level calibration", abs(value - expected) < 0.3 && abs(uncertainty - 3.5) < 0.01 && components.count == 5,   // calibrator + meter + flat plate: rig-limited ± 3.5 dB
                  String(format: "%.2f dB SPL/V (expected %.2f) ± %.2f dB", value, expected, uncertainty))
            check("sensitivity: drive voltage = full scale × level", abs(volts - 2.0 * pow(10, -24.0 / 20)) < 1e-6, String(format: "%.4f V", volts))
        } else {
            check("sensitivity: available with a calibrator reading and a level calibration", false)
        }
        c.useSensitivity()
        let stored = store.userSensitivity(headphone: published?.name ?? "")
        check("sensitivity: stored as the user sensitivity, source “Measured by owner, <date>, <rig note>”",
              stored?.isMeasured == true && stored?.unit == .dbPerVolt && stored?.impedanceOhms == 45 && abs((stored?.value ?? 0) - expected) < 0.35
              && stored?.sensitivity.source.hasPrefix("Measured by owner, \(MeasureController.dateText()), flat plate, self-check") == true
              && c.sensitivityStoredFor == published?.name, stored?.sensitivity.source ?? "")

        // Save: only the CSV, and the library reads it back.
        let name = "Self-check: curve / 1"
        c.save(choice: .left, name: name)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let loaded = library.userCurves()
        check("save: exactly one file lands in the curve folder, a CSV", files.count == 1 && files[0].hasSuffix(".csv") && c.savedName == MeasureController.fileSafe(name), files.joined(separator: ", "))
        var roundTrip = Float.infinity
        if let back = loaded.first, back.levelsDB.count == fine.count { roundTrip = zip(back.levelsDB, fine).map { abs($0 - $1) }.max() ?? .infinity }
        check("save: HeadphoneLibrary loads the curve back, same name, same values", loaded.count == 1 && loaded[0].name == MeasureController.fileSafe(name) && roundTrip < 0.001, String(format: "max difference %.5f dB", roundTrip))
        let text = (try? String(contentsOf: directory.appendingPathComponent(files.first ?? "x"), encoding: .utf8)) ?? ""
        check("save: the file carries the method, the rig note and the limits as comments, and no audio",
              text.contains("rig: flat plate, self-check") && text.contains("# Note:") && text.contains("frequency,raw") && text.utf8.count < 40_000, "\(text.utf8.count) bytes")
        check("save: a second save with the same name is announced", c.curveExists(named: name))

        // Overwrite guard (ringer-r2 d): a stored curve of this name is replaced only after its own yes.
        func listing() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() }
        func fileText(_ curveName: String) -> String {
            (try? String(contentsOf: directory.appendingPathComponent(MeasureController.fileSafe(curveName) + ".csv"), encoding: .utf8)) ?? ""
        }
        let firstFile = fileText(name)
        let listingBefore = listing()
        c.rigNote = "flat plate, self-check, second save"
        check("overwrite guard: the save of a stored name needs a confirmation, a new name needs none",
              c.saveConfirmation(choice: .left, name: name) == MeasureController.SaveConfirmation(leak: nil, replaces: MeasureController.fileSafe(name))
              && !c.saveConfirmation(choice: .left, name: "Self-check: not stored").isNeeded)
        c.save(choice: .left, name: name)
        check("overwrite guard: Save without the confirmation writes nothing and says why",
              fileText(name) == firstFile && !firstFile.isEmpty && listing() == listingBefore && (c.message?.text.contains("would replace it") ?? false), c.message?.text ?? "no message")
        c.save(choice: .left, name: name, confirmedLeak: true)
        check("overwrite guard: the yes to a leak is not a yes to the overwrite", fileText(name) == firstFile && listing() == listingBefore && c.message != nil)
        c.save(choice: .left, name: name, confirmedOverwrite: true)
        check("overwrite guard: the confirmed save replaces the stored curve, still one file",
              fileText(name) != firstFile && fileText(name).contains("second save") && listing() == listingBefore && c.message == nil && c.savedName == MeasureController.fileSafe(name))
        c.rigNote = "flat plate, self-check"

        // Leak guard (D3): bass far under the published curve of the selected model.
        func flat(_ name: String, bassDB: Float) -> HeadphoneCurve {
            let f: [Float] = [20, 30, 40, 50, 63, 80, 100, 125, 1000, 10_000, 20_000]
            return HeadphoneCurve(name: name, source: "self-check", frequenciesHz: f, levelsDB: f.map { $0 <= 100 ? bassDB : 0 })
        }
        let mean15 = MeasureController.bassDifferenceDB(measured: flat("leaky", bassDB: -15), published: flat("published", bassDB: 0)) ?? 0
        check("leak guard: −15 dB over 30 – 100 Hz is found and named", abs(mean15 + 15) < 0.01
              && MeasureController.leakWarning(measured: flat("leaky", bassDB: -15), published: flat("published", bassDB: 0), snrAt40Hz: 40)?.notice == "Bass is 15 dB under the published curve: likely a seal leak on the rig",
              String(format: "%.2f dB", mean15))
        check("leak guard: −5 dB is no warning; no selected model is no warning",
              MeasureController.leakWarning(measured: flat("ok", bassDB: -5), published: flat("published", bassDB: 0), snrAt40Hz: 40) == nil
              && MeasureController.leakWarning(measured: flat("leaky", bassDB: -15), published: nil, snrAt40Hz: 40) == nil)
        // One rule for noise versus leak (ringer-r2 b): the card reads the gate of the bass roll-off note.
        let gate = MeasuredHeadphone.snrThresholdDB
        func card(_ snr: Double?) -> MeasureController.LeakWarning? {
            MeasureController.leakWarning(measured: flat("leaky", bassDB: -15), published: flat("published", bassDB: 0), snrAt40Hz: snr)
        }
        check("leak guard: no card under the noise gate or without a signal-to-noise figure; a card from the gate up",
              card(nil) == nil && card(gate - 0.1) == nil && card(-.infinity) == nil && card(.nan) == nil && card(gate) != nil && card(gate + 30) != nil,
              String(format: "gate %.0f dB at 40 Hz", gate))
        // The same fall, the same signal-to-noise: the note and the card never give two verdicts.
        let fallGrid: [Double] = [20, 30, 40, 50, 63, 80, 100, 125, 1000, 10_000, 20_000]
        let fallLevels = fallGrid.map { $0 <= 50 ? -15.0 : 0.0 }
        let verdicts = [gate - 5, gate - 0.1, gate, gate + 5].map { snr -> Bool in
            let note = MeasuredHeadphone.bassRollOffNote(normalizedLevelsDB: fallLevels, grid: fallGrid, snrAt40Hz: snr) ?? ""
            return note.contains("seal leak on the rig") == (card(snr) != nil) && note.contains("limited by noise") == (card(snr) == nil)
        }
        check("leak guard: the roll-off note says \"seal leak\" exactly when the card shows, and \"limited by noise\" exactly when it does not", verdicts.allSatisfy { $0 })
        check("leak guard: the comparison line covers both ranges",
              MeasureView.comparison(measured: flat("leaky", bassDB: -15), published: flat("published", bassDB: 0)).contains("100 Hz – 10 kHz")
              && MeasureView.comparison(measured: flat("leaky", bassDB: -15), published: flat("published", bassDB: 0)).contains("30 – 100 Hz \(NumberText.signed(-15.0, decimals: 1)) dB"),
              MeasureView.comparison(measured: flat("leaky", bassDB: -15), published: flat("published", bassDB: 0)))
        if let measuredLeft = c.results[.left]?.measured.curve {
            // The same measured curve against a model whose published bass is 12 dB higher: the save must ask first.
            var heavy = measuredLeft.normalizedTo1kHz()
            heavy.name = "Self-check bass-heavy model"
            heavy.levelsDB = zip(heavy.frequenciesHz, heavy.levelsDB).map { $0 <= 125 ? $1 + 12 : $1 }
            selectedModel = heavy
            let filesBefore = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count
            let leak = c.leakWarning(for: .left)
            c.save(choice: .left, name: "Self-check: leaky")
            let refused = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count == filesBefore && c.savedName != MeasureController.fileSafe("Self-check: leaky")
            check("leak guard: with a warning, Save without the confirmation writes nothing", leak != nil && refused && c.message != nil, leak?.notice ?? "no warning")
            c.save(choice: .left, name: "Self-check: leaky", confirmedLeak: true)
            check("leak guard: the confirmed save writes the curve",
                  ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count == filesBefore + 1 && c.savedName == MeasureController.fileSafe("Self-check: leaky"))
            // Leak AND overwrite (ringer-r2 d): "Self-check: leaky" is stored now, and the leak warning still holds.
            let leaky = "Self-check: leaky"
            let leakyFile = fileText(leaky)
            let leakyListing = listing()
            let both = c.saveConfirmation(choice: .left, name: leaky)
            check("leak + overwrite: the save asks about both, with one button that names both",
                  both.leak != nil && both.replaces == MeasureController.fileSafe(leaky) && both.confirmTitle == "Save with the leak, replacing the existing curve" && both.overwriteQuestion != nil)
            c.rigNote = "flat plate, self-check, leaky again"
            var untouched = true
            for (leakYes, overwriteYes) in [(false, false), (true, false), (false, true)] {
                c.save(choice: .left, name: leaky, confirmedLeak: leakYes, confirmedOverwrite: overwriteYes)
                untouched = untouched && fileText(leaky) == leakyFile && listing() == leakyListing && c.message != nil
            }
            check("leak + overwrite: no yes, or only one of the two, writes nothing", untouched && !leakyFile.isEmpty)
            c.save(choice: .left, name: leaky)
            check("leak + overwrite: the refusal names both risks",
                  (c.message?.text.contains("likely a seal leak") ?? false) && (c.message?.text.contains("would replace it") ?? false), c.message?.text ?? "no message")
            c.save(choice: .left, name: leaky, confirmedLeak: true, confirmedOverwrite: true)
            check("leak + overwrite: both confirmed, the save replaces the curve",
                  fileText(leaky) != leakyFile && fileText(leaky).contains("leaky again") && listing() == leakyListing && c.message == nil)
            c.rigNote = "flat plate, self-check"
            selectedModel = published
        } else {
            check("leak guard: a left result exists", false)
        }
        if let quality = c.results[.left]?.measured.quality {
            let text = MeasureView.lowestHonestText(quality)
            let numbers = text.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            check("result page: one lower-limit number with one cause", text.hasPrefix("Not reliable under \(Int(MeasureView.lowestHonestHz(quality).rounded())) Hz: ")
                  && !MeasureView.shownWarnings(quality).contains { $0.hasPrefix("The analysis window is") } && numbers.count <= 2, text)
        }

        // The other side, and the average.
        link.headphoneVariation = 1.5
        tick()
        c.measureOtherSide()
        check("safety: a side change clears the checkbox", !c.rigConfirmed)
        check("sides: the other side starts at step 4 with its own noise and runs; the first side keeps its result",
              c.step == .measure && c.side == .right && c.runs.isEmpty && !c.noiseDone && c.results[.left] != nil)
        // The clip above voided the level check: the side needs a clean one first.
        tick(); c.startLevelCheck(permit: permit()); idle(c)
        c.recordNoise(); idle(c)
        for _ in 1...3 { tick(); c.startRun(permit: permit()); idle(c) }
        wait(30) { c.results[.right] != nil && c.results[.left] != nil }
        check("sides: two results, both kept", c.results.count == 2 && c.availableSaveChoices == [.left, .right, .average])
        if let l = c.results[.left], let r = c.results[.right], let a = c.result(for: .average) {
            let (worst, at) = worstError(r.measured.curve, link.headphone.normalizedResponseDB(onGrid: grid), micCorrection: micCorrection)
            check("sides: the right curve matches ITS simulated response within 0.5 dB", worst < 0.5, String(format: "worst %.3f dB at %.0f Hz", worst, at))
            var error: Float = 0, apart: Float = 0
            for i in 0..<a.measured.curve.levelsDB.count where grid[i] >= 40 && grid[i] <= 16_000 {
                error = max(error, abs(a.measured.curve.levelsDB[i] - (l.measured.curve.levelsDB[i] + r.measured.curve.levelsDB[i]) / 2))
                apart = max(apart, abs(l.measured.curve.levelsDB[i] - r.measured.curve.levelsDB[i]))
            }
            check("sides: the average is the mean of the two curves", error < 0.05 && apart > 1 && a.measured.quality.runs == 6, String(format: "sides differ by up to %.2f dB", apart))
            // One bass roll-off note on the average (ringer-r2 a). The simulated headphone is sealed, so both sides
            // get a leak by hand: 14 dB and 20 dB under 50 Hz, each with its own note, the way the session writes it.
            func leaking(_ side: MeasureSideResult, by fallDB: Float) -> MeasureSideResult {
                var out = side
                out.measured.curve.levelsDB = zip(out.measured.curve.frequenciesHz, out.measured.curve.levelsDB).map { $0 <= 50 ? -fallDB : ($0 <= 125 ? 0 : $1) }
                out.measured.quality.warnings.removeAll(where: MeasuredHeadphone.isBassRollOffNote)
                if let note = out.measured.bassRollOffNote { out.measured.quality.warnings.append(note) }
                return out
            }
            let leakyLeft = leaking(l, by: 14), leakyRight = leaking(r, by: 20)
            let sideNotes = [leakyLeft, leakyRight].map { $0.measured.quality.warnings.filter(MeasuredHeadphone.isBassRollOffNote) }
            let averaged = MeasureController.average(leakyLeft, leakyRight).measured
            let notes = averaged.quality.warnings.filter(MeasuredHeadphone.isBassRollOffNote)
            check("sides: two leaky sides with different notes give ONE bass roll-off note on the average, from the averaged curve",
                  sideNotes[0].count == 1 && sideNotes[1].count == 1 && sideNotes[0] != sideNotes[1]
                  && notes.count == 1 && notes.first == averaged.bassRollOffNote && (notes.first?.contains("falls 17 dB") ?? false)
                  && MeasureView.shownWarnings(averaged.quality).filter(MeasuredHeadphone.isBassRollOffNote).count == 1,
                  notes.first ?? "no note")
            check("sides: the average of the sealed sides carries no roll-off note, and no sentence twice",
                  a.measured.quality.warnings.filter(MeasuredHeadphone.isBassRollOffNote).count == (a.measured.bassRollOffNote == nil ? 0 : 1)
                  && Set(a.measured.quality.warnings).count == a.measured.quality.warnings.count && a.measured.quality.warnings.first == MeasuredHeadphone.averageNote)
        } else {
            check("sides: an average exists", false)
        }

        // Faults: every one ends the run with a message. None hangs.
        let faults: [(FakeAcousticLink.Fault, String, String)] = [
            (.deviceRemoved, "device loss in a run", "went away"),
            (.formatChanged, "format change in a run", "format of the input changed"),
            (.playerNeverFinishes, "a player that never finishes (watchdog)", "did not finish in time"),
            (.inputDeliversNothing, "an input that delivers nothing", "delivers no audio"),
            (.startFails, "an input that does not open", "is gone"),
        ]
        c.runsWanted = 8
        for (fault, label, words) in faults {
            link.fault = fault
            let before = c.runs.count
            tick(); c.startRun(permit: permit())
            let ended = idle(c, 5)
            check("fault: \(label) ends the run with a clear message", ended && c.runs.count == before && (c.message?.text.contains(words) ?? false), c.message?.text ?? "no message")
        }
        link.fault = .playerNeverFinishes
        tick(); c.startRun(permit: permit())
        wait(1) { fakePlayer.isPlaying }
        c.cancel()
        check("stop: Stop ends a run at once and tells the player to stop", c.activity == .idle && fakePlayer.stopReasons.last != nil && c.runs.count == 3)
        link.fault = nil
        tick(); c.startRun(permit: permit()); idle(c)
        check("after the faults a normal run works again", c.runs.count == 4)

        // Window close: everything measured leaves memory.
        link.fault = .playerNeverFinishes
        tick(); c.startRun(permit: permit())
        wait(1) { fakePlayer.isPlaying }
        c.windowClosed()
        var empty: Bool?
        c.holdsNoMeasurementData { empty = $0 }
        wait(5) { empty != nil }
        check("window close: the sweep stops, and no recording, analysis or result stays in memory", empty == true && c.activity == .idle && !fakePlayer.isPlaying)
        tick(); c.startRun(permit: permit())
        check("window close: nothing starts afterwards", c.activity == .idle)
        check("the fake input was never asked for the permission again", link.permissionRequests == 1)

        noiseOrLeak(directory: directory, library: library)

        // Absolute level from the header of a calibration file.
        let c2 = MeasureController(environment: environment)
        check("absolute level: not available without a file and without a calibrator", !c2.absoluteLevel.isAvailable)
        c2.loadMicCalibration(text: plainMicFile, fileName: "plain.txt")
        check("absolute level: not available with a file that has no sensitivity factor", !c2.absoluteLevel.isAvailable)
        c2.loadMicCalibration(text: umikFile, fileName: "umik.txt")
        check("absolute level: available from a miniDSP-style sensitivity factor", c2.absoluteLevel.isAvailable && c2.micInfo?.sensFactorDB == -1.37)
        c2.calibratorText = "abc"
        check("absolute level: a calibrator reading that is no number is ignored", c2.calibratorReadingDBFS == nil)
        c2.windowClosed()
    }

    /// One rule for noise versus leak, end to end (ringer-r2 b). The same leaky seat (a 90 Hz corner) is measured
    /// twice: the left side under room rumble, the right side in a quiet room. The quality list and the leak card
    /// must agree on each side, and the noisy side must not be held back by a leak question.
    private static func noiseOrLeak(directory: URL, library: HeadphoneLibrary) {
        let link = FakeAcousticLink()
        link.gainDB = 9
        link.leakHz = 90
        link.rumbleDBFS = -30
        let grid: [Float] = [20, 30, 40, 50, 63, 80, 100, 125, 1000, 10_000, 20_000]
        let model = HeadphoneCurve(name: "Self-check sealed model", source: "self-check", frequenciesHz: grid, levelsDB: grid.map { _ in 0 })
        let environment = MeasureEnvironment(
            input: FakeMeasureInput(link: link), player: FakeSignalPlayer(link: link), timing: .fake,
            headphone: { model }, target: { nil }, playback: { nil }, knownImpedanceOhms: { nil },
            importCurve: { url in do { try library.importCurve(from: url); return nil } catch { return "\(error)" } },
            curveExists: { name in library.userCurves().contains { $0.name == name } },
            storeSensitivity: { _, _ in }, outputName: { "Self-check DAC" })
        let c = MeasureController(environment: environment)
        func sweepSide() {
            c.rigConfirmed = true; c.startLevelCheck(permit: permit()); _ = idle(c)
            if c.step != .measure { c.go(to: .measure) }
            c.recordNoise(); _ = idle(c)
            c.rigConfirmed = true; c.startRun(permit: permit()); _ = idle(c)
        }
        c.runsWanted = 1
        sweepSide()
        wait(30) { c.results[.left] != nil }
        link.rumbleDBFS = nil
        c.measureOtherSide()
        sweepSide()
        wait(30) { c.results[.right] != nil && c.results[.left] != nil }
        guard let noisy = c.results[.left]?.measured, let quiet = c.results[.right]?.measured,
              let noisySNR = noisy.quality.snrDB(atHz: 40), let quietSNR = quiet.quality.snrDB(atHz: 40) else {
            check("noise or leak: both sides measured", false); return
        }
        let gate = Float(MeasuredHeadphone.snrThresholdDB)
        let bass = [noisy, quiet].map { MeasureController.bassDifferenceDB(measured: $0.curve, published: model) ?? 0 }
        check("noise or leak: the fake rig gives one noisy and one quiet side, both with the bass far under the model",
              noisySNR < gate && quietSNR >= gate && bass.allSatisfy { $0 < -MeasureController.LeakWarning.limitDB },
              String(format: "S/N at 40 Hz %.0f dB and %.0f dB; bass %.1f dB and %.1f dB", noisySNR, quietSNR, bass[0], bass[1]))
        // Under the rumble the bass of the noisy side is the noise floor. Its fall may or may not reach the 10 dB of
        // the roll-off note; what must hold is that NOTHING on that side says "seal leak", and that the noise is named.
        let noisyWords = noisy.quality.warnings.joined(separator: " ")
        check("noise or leak: the noisy side names the noise, never says \"seal leak\", and shows NO leak card",
              !noisyWords.contains("seal leak on the rig") && (noisyWords.contains("limited by noise") || noisy.quality.lowLimitCause == .noise)
              && c.leakWarning(for: .left) == nil
              && MeasureController.leakWarning(measured: noisy.curve, published: model, snrAt40Hz: Double(quietSNR)) != nil,   // the gate, not the curve, held the card back
              noisy.bassRollOffNote ?? "lower limit set by \(noisy.quality.lowLimitCause.reason)")
        check("noise or leak: the quiet side says \"seal leak\" and shows the leak card",
              (quiet.bassRollOffNote?.contains("seal leak on the rig") ?? false) && c.leakWarning(for: .right) != nil, quiet.bassRollOffNote ?? "no note")
        if let average = c.result(for: .average)?.measured {
            let notes = average.quality.warnings.filter(MeasuredHeadphone.isBassRollOffNote)
            check("noise or leak: the average takes the worse signal-to-noise: one note, \"limited by noise\", no leak card",
                  notes.count == 1 && notes[0].contains("limited by noise") && c.leakWarning(for: .average) == nil, notes.first ?? "no note")
        } else {
            check("noise or leak: an average exists", false)
        }
        let before = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count
        c.save(choice: .left, name: "Self-check: noisy side")
        let noisyFile = (try? String(contentsOf: directory.appendingPathComponent("Self-check noisy side.csv"), encoding: .utf8)) ?? ""
        check("noise or leak: the noisy side saves without a leak question, and its file does not say \"seal leak\"",
              ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count == before + 1 && c.message == nil
              && noisyFile.contains("frequency,raw") && !noisyFile.contains("seal leak on the rig"))
        c.save(choice: .right, name: "Self-check: quiet leaky side")
        check("noise or leak: the quiet leaky side still asks first",
              ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).count == before + 1 && c.message != nil)
        c.windowClosed()
    }
    #endif
}
