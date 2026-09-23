import AppKit
import Foundation
import JoseonCapture
import JoseonCore
import JoseonHeadphones
import JoseonRender

// joseon-probe — headless checks for Joseon. Audio is analyzed in memory only, never written to disk.
//
//   joseon-probe devices
//   joseon-probe capture --seconds N
//   joseon-probe demo --seconds N
//   joseon-probe cycle [--count N]
//   joseon-probe render --panel spectrum|spectrogram|vectorscope|meters --out FILE.png
//                       [--width W --height H] [--seconds N] [--realtime]
//                       [--target LUFS] [--mode scope|placement] [--side] [--headphone "NAME"]
//   joseon-probe measure-devices     lists the input devices as JSON; opens no input, needs no permission
//   joseon-probe measure-selftest    offline checks of the measurement input logic; no audio I/O
//   joseon-probe now-playing         reads the Qobuz player bar once through Accessibility; no prompt, no audio
//
// Exit codes: 0 ok / signal received, 1 usage or start error, 2 only silence, 3 renderer error, 4 leak found,
//             5 a measure-selftest check failed.

// MARK: - Output

let stdoutLock = NSLock()

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    stdoutLock.withLock {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// JSON has no NaN or infinity.
func num(_ v: Double, places: Int = 3) -> Any {
    v.isFinite ? NSDecimalNumber(string: String(format: "%.\(places)f", v)) : NSNull()
}
func num(_ v: Float) -> Any { num(Double(v)) }
func dbfs(_ linear: Float) -> Any { linear > 0 ? num(20 * log10(Double(linear))) : NSNull() }

// MARK: - Arguments

struct Arguments {
    var command: String
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: [String]) {
        command = argv.count > 1 ? argv[1] : ""
        var i = 2
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { options[key] = argv[i + 1]; i += 1 } else { flags.insert(key) }
            }
            i += 1
        }
    }
    func double(_ key: String, default d: Double) -> Double { options[key].flatMap(Double.init) ?? d }
    func int(_ key: String, default d: Int) -> Int { options[key].flatMap(Int.init) ?? d }
}

let usage = """
usage:
  joseon-probe devices
  joseon-probe capture --seconds N
  joseon-probe demo --seconds N
  joseon-probe cycle [--count N]
  joseon-probe render --panel spectrum|spectrogram|vectorscope|meters --out FILE.png [--width W --height H] [--seconds N] [--realtime]
                      [--target LUFS] [--mode scope|placement] [--side] [--headphone "NAME"]
      --target LUFS       loudness target of the meters panel, for example -14
      --mode              vectorscope panel: scope (default) or placement (stereo placement by frequency)
      --side              spectrum panel: draw the Side (L−R) trace
      --headphone "NAME"  a curve of the headphone library, against the Harman over-ear 2018 target: the real
                          HeadphoneModel runs on the engine, so the render shows the real overlay and real stress flags
  joseon-probe measure-devices     list the input devices as JSON (opens no input, needs no permission)
  joseon-probe measure-selftest    offline checks of the measurement input logic (no audio I/O); exit 5 on a FAIL
  joseon-probe now-playing         read the Qobuz player bar once through Accessibility, as JSON
                                   {"trusted":bool,"running":bool,"nowPlaying":{...}|null}; never prompts for the permission
"""

// MARK: - JSON shapes

func json(_ f: AudioFormatDescription?) -> Any {
    guard let f else { return NSNull() }
    return ["sampleRate": f.sampleRate, "channels": f.channels, "bitsPerChannel": f.bitsPerChannel,
            "formatID": f.formatID, "float": f.isFloat, "nonInterleaved": f.isNonInterleaved]
}

func json(_ d: AudioDeviceDescription) -> [String: Any] {
    ["id": Int(d.id), "name": d.name, "uid": d.uid, "transport": d.transport, "nominalSampleRate": d.nominalSampleRate,
     "outputChannels": d.outputChannels, "inputChannels": d.inputChannels,
     "outputPhysicalFormat": json(d.outputPhysicalFormat), "outputVirtualFormat": json(d.outputVirtualFormat),
     "hogPID": Int(d.hogPID), "hoggedByOtherProcess": d.isHoggedByOther, "aggregate": d.isAggregate]
}

func json(_ s: StreamInfo?) -> Any {
    guard let s else { return NSNull() }
    return ["sampleRate": s.sampleRate, "channelCount": s.channelCount, "deviceName": s.deviceName,
            "bitDepth": s.bitDepth.map { $0 as Any } ?? NSNull(), "activeSources": s.activeSources,
            "deviceIsDefault": s.deviceIsDefault.map { $0 as Any } ?? NSNull()]
}

/// Device ids this process can see. A private aggregate device shows only here, in its owner.
func visibleDeviceIDs() -> Set<UInt32> { Set(AudioSystem.allDevices().map(\.id)) }

/// Devices that exist now and did not exist in `before`. The HAL removes a destroyed aggregate device
/// from the device list a moment after the destroy call returns, so poll for up to `timeout` seconds.
func leftoverDevices(since before: Set<UInt32>, timeout: Double = 3) -> (ids: [Int], settledAfter: Double) {
    let started = ProcessInfo.processInfo.systemUptime
    while true {
        let extra = visibleDeviceIDs().subtracting(before)
        let waited = ProcessInfo.processInfo.systemUptime - started
        if extra.isEmpty || waited >= timeout { return (extra.sorted().map { Int($0) }, waited) }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

// MARK: - Live run (capture and demo)

/// Drains the ring buffer on its own thread: measures the raw peak on its own copy of the samples,
/// then hands the same block to `engine.processNow`. One reader, so the engine never starves.
func runLive(source: AudioSource, mode: String, seconds: Double) -> Never {
    let tap = source as? SystemAudioTap
    let engine = AnalysisEngine()
    let devicesBefore = visibleDeviceIDs()
    let tapsBefore = AudioSystem.tapCount()

    source.onStreamInfoChange = { info in
        engine.streamInfo = info
        emit(["event": "streamInfo", "mode": mode, "stream": json(info)])
    }
    do { try source.start() } catch {
        emit(["event": "error", "mode": mode, "error": "\(error)"])
        exit(1)
    }

    let worker = Thread {
        let capacity = 1 << 15
        let left = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        let started = ProcessInfo.processInfo.systemUptime
        var nextReport = 0.5
        var windowPeak: Float = 0, totalPeak: Float = 0
        var windowFrames = 0, totalFrames = 0, nonZeroSamples = 0
        var frame = engine.latestFrame

        /// Empties the ring buffer, but stops at `deadline`: a debug build of the engine runs slower
        /// than real time at 96 kHz, and the ring then never empties (seen with a USB DAC at 96 kHz).
        func drain(deadline: Double) {
            var n = source.ringBuffer.read(left: left, right: right, maxCount: capacity)
            while n > 0 {
                for i in 0..<n {
                    let a = max(abs(left[i]), abs(right[i]))
                    if a > 0 { nonZeroSamples += 1; if a > windowPeak { windowPeak = a } }
                }
                windowFrames += n
                frame = engine.processNow(left: left, right: right, count: n, sampleRate: source.ringBuffer.sampleRate)
                if ProcessInfo.processInfo.systemUptime - started >= deadline { return }
                n = source.ringBuffer.read(left: left, right: right, maxCount: capacity)
            }
        }

        while true {
            drain(deadline: min(nextReport, seconds))
            let t = ProcessInfo.processInfo.systemUptime - started
            if t >= nextReport {
                totalPeak = max(totalPeak, windowPeak)
                totalFrames += windowFrames
                var line: [String: Any] = [
                    "event": "reading", "mode": mode, "t": num(t),
                    "stream": json(source.streamInfo),
                    "frames": windowFrames,
                    "rawPeak": num(Double(windowPeak), places: 6), "rawPeakDBFS": dbfs(windowPeak),
                    "momentaryLUFS": num(frame.loudness.momentaryLUFS),
                    "correlation": num(frame.stereo.correlation),
                    "topPeak": ["hz": num(frame.peak.frequencyHz), "dB": num(frame.peak.levelDB), "note": frame.peak.noteName],
                    "engineSilent": frame.isSilent,
                    "hasReceivedSignal": tap?.hasReceivedSignal ?? (totalPeak > 0),
                ]
                if let tap {
                    line["ioCycles"] = tap.ioCycleCount
                    line["outputDeviceIsHogged"] = tap.outputDeviceIsHogged
                    line["likelyPermissionDenied"] = tap.isLikelyPermissionDenied
                }
                emit(line)
                windowPeak = 0; windowFrames = 0
                nextReport += 0.5
            }
            if t >= seconds { break }
            Thread.sleep(forTimeInterval: 0.01)
        }

        totalPeak = max(totalPeak, windowPeak)   // the part after the last report line
        totalFrames += windowFrames
        let lastStream = source.streamInfo
        let ioCycles = tap?.ioCycleCount
        let likelyDenied = tap?.isLikelyPermissionDenied
        let rebuildError = tap?.lastRebuildError
        source.stop()
        let leftover = leftoverDevices(since: devicesBefore)
        let tapsAfter = AudioSystem.tapCount()
        let gotSignal = totalPeak > 0

        var summary: [String: Any] = [
            "event": "summary", "mode": mode, "seconds": num(ProcessInfo.processInfo.systemUptime - started),
            "stream": json(lastStream),
            "totalFrames": totalFrames, "nonZeroSamples": nonZeroSamples,
            "rawPeak": num(Double(totalPeak), places: 6), "rawPeakDBFS": dbfs(totalPeak),
            "integratedLUFS": num(frame.loudness.integratedLUFS),
            "truePeakMaxDBTP": num(frame.loudness.truePeakMaxDBTP),
            "signalReceived": gotSignal,
            "devicesLeftBehind": leftover.ids, "deviceListSettledAfterSeconds": num(leftover.settledAfter),
            "tapsBefore": tapsBefore, "tapsAfter": tapsAfter,
            "result": gotSignal ? "signal" : "silence",
        ]
        if let tap {
            summary["hasReceivedSignal"] = tap.hasReceivedSignal
            summary["ioCycles"] = ioCycles ?? 0
            summary["likelyPermissionDenied"] = likelyDenied ?? false
            summary["outputDeviceIsHogged"] = tap.outputDeviceIsHogged
            if let rebuildError { summary["lastRebuildError"] = "\(rebuildError)" }
        }
        emit(summary)
        exit(gotSignal ? 0 : 2)
    }
    worker.qualityOfService = .userInitiated
    worker.start()
    RunLoop.main.run()   // serves onStreamInfoChange (main queue)
    exit(1)
}

// MARK: - cycle: start/stop repeatedly and check for leaked devices

func runCycle(count: Int) -> Never {
    let devicesBefore = visibleDeviceIDs()
    let tapsBefore = AudioSystem.tapCount()
    var failures = 0
    let worker = Thread {
        var tap: SystemAudioTap? = SystemAudioTap()
        for round in 1...max(count, 1) {
            var line: [String: Any] = ["event": "cycle", "round": round]
            do {
                try tap!.start()
                Thread.sleep(forTimeInterval: 0.6)
                line["runningAfterStart"] = tap!.isRunning
                line["ioCycles"] = tap!.ioCycleCount
                line["devicesWhileRunning"] = visibleDeviceIDs().subtracting(devicesBefore).count
                line["tapsWhileRunning"] = AudioSystem.tapCount() - tapsBefore
                if tap!.ioCycleCount == 0 { failures += 1 }
            } catch {
                line["error"] = "\(error)"
                failures += 1
            }
            tap!.stop()
            line["runningAfterStop"] = tap!.isRunning
            let after = leftoverDevices(since: devicesBefore)
            line["devicesLeftBehind"] = after.ids
            line["deviceListSettledAfterSeconds"] = num(after.settledAfter)
            if !after.ids.isEmpty { failures += 1 }
            line["tapsLeftBehind"] = AudioSystem.tapCount() - tapsBefore
            emit(line)
        }
        // deinit path: start, then drop the last reference without stop().
        var deinitLine: [String: Any] = ["event": "deinitCheck"]
        do { try tap!.start(); Thread.sleep(forTimeInterval: 0.3) } catch { deinitLine["error"] = "\(error)"; failures += 1 }
        tap = nil
        let leftover = leftoverDevices(since: devicesBefore).ids
        let tapsLeft = AudioSystem.tapCount() - tapsBefore
        deinitLine["devicesLeftBehind"] = leftover
        deinitLine["tapsLeftBehind"] = tapsLeft
        emit(deinitLine)
        let leaked = !leftover.isEmpty || tapsLeft != 0
        emit(["event": "summary", "mode": "cycle", "rounds": count, "failures": failures, "leaked": leaked])
        exit(leaked ? 4 : (failures > 0 ? 1 : 0))
    }
    worker.start()
    RunLoop.main.run()
    exit(1)
}

// MARK: - devices

func runDevices() -> Never {
    guard let device = AudioSystem.defaultOutputDevice() else {
        emit(["event": "devices", "error": "No default output device"])
        exit(1)
    }
    let playing = AudioSystem.playingProcesses()
    let chosen = AudioSystem.chosenPlaybackDevice(playing: playing)
    emit([
        "event": "devices",
        "defaultOutput": json(device),
        "activeSources": AudioSystem.activeSources(),
        // Per playing process: the output devices it plays to (output scope), so a player that picked
        // its own DAC shows up next to the default.
        "playingProcesses": playing.map { p -> [String: Any] in
            ["pid": Int(p.pid), "bundleID": p.bundleID, "name": p.name,
             "outputDevices": p.devices.map { ["id": Int($0.id), "name": $0.name, "uid": $0.uid, "nominalSampleRate": $0.nominalSampleRate] as [String: Any] }]
        },
        // The device the tap would clock on now (PlaybackDeviceChooser, no current choice).
        "chosenDevice": chosen.map { json($0) as Any } ?? NSNull(),
        "chosenDeviceIsDefault": chosen.map { $0.id == device.id } as Any? ?? NSNull(),
        "allDevices": AudioSystem.allDevices().map { ["id": Int($0.id), "name": $0.name, "transport": $0.transport, "aggregate": $0.isAggregate] as [String: Any] },
        "visibleTaps": AudioSystem.tapCount(),
    ])
    exit(0)
}

// MARK: - measure-devices / measure-selftest

/// Lists input devices. Reads device properties and the stored permission status only:
/// it opens no input stream and never shows the Microphone prompt.
func runMeasureDevices() -> Never {
    let devices = MeasurementInput.devices().map { d -> [String: Any] in
        ["uid": d.uid, "name": d.name, "channelCount": d.channelCount,
         "nominalSampleRate": num(d.nominalSampleRate, places: 1),
         "availableSampleRates": d.availableSampleRates.map { num($0, places: 1) },
         "transport": d.transport.rawValue, "isDefaultInput": d.isDefaultInput]
    }
    emit(["mode": "measure-devices", "microphonePermission": MicrophonePermission.status.rawValue, "devices": devices])
    exit(0)
}

/// Offline checks of the non-I/O logic in JoseonCapture (no test target covers that module). No audio I/O.
func runMeasureSelfTest() -> Never {
    let results = MeasurementInputSelfTest.run()
    for r in results {
        print("\(r.passed ? "PASS" : "FAIL")  \(r.name)\(r.detail.isEmpty ? "" : "  [\(r.detail)]")")
    }
    let failed = results.filter { !$0.passed }.count
    print("measure-selftest: \(results.count - failed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 5)
}

// MARK: - now-playing

/// One read of the player bar. No timer: the reader's `readNow()` runs at most a few times, because the web content
/// of an Electron app shows up in the Accessibility tree a moment after `AXManualAccessibility` is set.
/// Not trusted: prints so and exits 0 without showing the permission prompt.
func runNowPlaying() -> Never {
    let reader = AccessibilityNowPlayingReader()
    let trusted = AccessibilityNowPlayingReader.isTrusted
    let running = reader.isPlayerRunning
    var value: NowPlaying?
    if trusted, running {
        for attempt in 0..<8 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.4) }
            value = reader.readNow()
            if value != nil { break }
        }
    }
    let nowPlaying: Any = value.map {
        ["title": $0.title, "artist": $0.artist, "album": $0.album, "source": $0.source, "isHiRes": $0.isHiRes, "line": $0.line] as [String: Any]
    } ?? NSNull()
    emit(["trusted": trusted, "running": running, "nowPlaying": nowPlaying])
    exit(0)
}

// MARK: - render

/// Frames older than this are dropped from a long offline run: no panel shows more history by default.
let keepSeconds = 30.0

/// `--headphone "NAME"`: the library curve with that name (case-insensitive; a unique part of the name is enough)
/// and the Harman over-ear 2018 target, as the real `HeadphoneModel`.
func headphoneModel(named name: String) -> HeadphoneModel {
    let library = HeadphoneLibrary()
    let curves = library.allCurves()
    let wanted = name.lowercased()
    let exact = curves.filter { $0.name.lowercased() == wanted }
    let partial = curves.filter { $0.name.lowercased().contains(wanted) }
    guard let curve = exact.first ?? (partial.count == 1 ? partial.first : nil) else {
        let list = (partial.isEmpty ? curves : partial).map { "  " + $0.name }.joined(separator: "\n")
        fail("render: --headphone \"\(name)\" \(partial.count > 1 ? "matches more than one curve" : "is not in the library"). Curves:\n\(list)", code: 1)
    }
    let targetName = "Harman over-ear 2018"
    guard let target = library.allTargets().first(where: { $0.name == targetName }) else {
        fail("render: the target \"\(targetName)\" is not in the library", code: 1)
    }
    return HeadphoneModel(curve: curve, target: target)
}

func collectFramesOffline(seconds: Double, model: HeadphoneModel?) -> [AnalysisFrame] {
    let engine = AnalysisEngine()
    engine.headphoneModel = model
    // The generator of `DemoAudioSource`, run offline, so a render does not wait in real time.
    // `--realtime` uses the real DemoAudioSource instead.
    let sampleRate = 48_000.0
    engine.streamInfo = StreamInfo(sampleRate: sampleRate, channelCount: 2, deviceName: "Demo signal", bitDepth: 32, activeSources: ["Joseon demo"])
    let block = Int(sampleRate / 60)
    var frames: [AnalysisFrame] = []
    let total = max(1, Int(seconds * 60))
    frames.reserveCapacity(total)
    for k in 0..<total {
        let samples = TestSignals.demoBlock(startSample: k * block, count: block, sampleRate: sampleRate)
        var frame = engine.processNow(left: samples.left, right: samples.right, count: block, sampleRate: sampleRate)
        frame.hostTime = Double(k) / 60   // offline: the frame clock is the signal clock
        frames.append(frame)
        if frames.count > Int(keepSeconds * 60) + 600 { frames.removeFirst(600) }
    }
    return frames
}

func collectFramesRealtime(seconds: Double, model: HeadphoneModel?) -> [AnalysisFrame] {
    let engine = AnalysisEngine()
    engine.headphoneModel = model
    let source = DemoAudioSource()
    do { try source.start() } catch { fail("demo source failed: \(error)", code: 1) }
    engine.streamInfo = source.streamInfo
    let capacity = 1 << 15
    var l = [Float](repeating: 0, count: capacity), r = [Float](repeating: 0, count: capacity)
    var frames: [AnalysisFrame] = []
    let started = ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime - started < seconds {
        let n = source.ringBuffer.read(left: &l, right: &r, maxCount: capacity)
        if n > 0 { frames.append(engine.processNow(left: l, right: r, count: n, sampleRate: source.ringBuffer.sampleRate)) }
        Thread.sleep(forTimeInterval: 1.0 / 60)
    }
    source.stop()
    return frames
}

func runRender(_ args: Arguments) -> Never {
    guard let panelName = args.options["panel"], let panel = PanelKind(rawValue: panelName) else {
        fail("render: --panel must be one of \(PanelKind.allCases.map(\.rawValue).joined(separator: "|"))\n" + usage, code: 1)
    }
    guard let out = args.options["out"] else { fail("render: --out FILE.png is required\n" + usage, code: 1) }
    let size = CGSize(width: args.int("width", default: 1200), height: args.int("height", default: 600))
    let seconds = max(0.1, args.double("seconds", default: 5))
    var settings = OffscreenRenderer.Settings()
    if let raw = args.options["target"] {
        guard let lufs = Float(raw), lufs.isFinite, lufs < 0 else { fail("render: --target needs a level in LUFS, for example -14\n" + usage, code: 1) }
        settings.targetLUFS = lufs
    }
    if let raw = args.options["mode"] {
        switch raw {
        case "scope": settings.vectorscopeMode = .lissajous
        case "placement": settings.vectorscopeMode = .panSpectrum
        default: fail("render: --mode must be scope or placement\n" + usage, code: 1)
        }
    }
    if args.flags.contains("side") { settings.spectrum.showSide = true }
    let model = args.options["headphone"].map(headphoneModel(named:))
    let frames = args.flags.contains("realtime") ? collectFramesRealtime(seconds: seconds, model: model)
        : collectFramesOffline(seconds: seconds, model: model)
    do {
        let data = try OffscreenRenderer.png(panel: panel, frames: frames, size: size, settings: settings)
        try data.write(to: URL(fileURLWithPath: out))
        emit(["event": "render", "panel": panel.rawValue, "out": out, "frames": frames.count, "bytes": data.count,
              "width": Int(size.width), "height": Int(size.height),
              "headphone": model?.modelName ?? NSNull(),
              "stressFlags": (frames.last?.headphone?.stressFlags ?? []).map { ["id": $0.id, "title": $0.title, "detail": $0.detail] }])
        exit(0)
    } catch {
        fail("render failed: \(error)", code: 3)
    }
}

// MARK: - Entry

let args = Arguments(CommandLine.arguments)
switch args.command {
case "devices": runDevices()
case "capture": runLive(source: SystemAudioTap(), mode: "capture", seconds: max(0.5, args.double("seconds", default: 5)))
case "demo": runLive(source: DemoAudioSource(), mode: "demo", seconds: max(0.5, args.double("seconds", default: 5)))
case "cycle": runCycle(count: args.int("count", default: 3))
case "render": runRender(args)
case "measure-devices": runMeasureDevices()
case "measure-selftest": runMeasureSelfTest()
case "now-playing": runNowPlaying()
default: fail(usage, code: 1)
}
