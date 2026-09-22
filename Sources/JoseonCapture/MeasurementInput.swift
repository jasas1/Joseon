import AppKit
import AVFoundation
import CoreAudio
import Foundation

// Measurement microphone input (spec `docs/specs/mic-input.md`, part 1).
//
// Lists the input devices, opens ONE of them with an `AudioDeviceIOProc` on the device itself
// (no aggregate device, no AVCaptureSession, no AVAudioEngine) and delivers one channel as mono
// Float32 blocks. Nothing here writes audio to disk.
//
// Permission: opening an input needs the macOS Microphone permission. `MeasurementInputSession.start`
// never shows the prompt: it throws `permissionNotGranted` unless the permission is already
// granted. Only `MicrophonePermission.request` shows the prompt, and only the app calls it, on a user click.
// Listing devices and reading their properties needs no permission.

// MARK: - Errors

public enum MeasurementInputError: Error, CustomStringConvertible {
    /// The Microphone permission is not granted. `start` does not ask for it; the app does, on a user click.
    case permissionNotGranted(MicrophonePermission.Status)
    case deviceNotFound(uid: String)
    case deviceNotAlive(uid: String)
    case notAnInputDevice
    /// `requested` and `available` are 0-based channel index and channel count.
    case channelOutOfRange(requested: Int, available: Int)
    /// The stream format is not one this module converts. The text says which and why.
    case unsupportedFormat(String)
    /// Another process holds exclusive (hog mode) access to the device.
    case deviceHogged(pid: Int32)
    case alreadyRunning
    case ioProcFailed(OSStatus)

    public var description: String {
        switch self {
        case .permissionNotGranted(let s): return "Microphone permission is not granted (status: \(s.rawValue))"
        case .deviceNotFound(let uid): return "No audio device with UID \"\(uid)\""
        case .deviceNotAlive(let uid): return "The audio device \"\(uid)\" is not alive (unplugged?)"
        case .notAnInputDevice: return "The device has no input streams"
        case .channelOutOfRange(let requested, let available):
            return "Input channel index \(requested) is out of range: the device has \(available) input channel(s), index 0…\(max(0, available - 1))"
        case .unsupportedFormat(let why): return "Unsupported input stream format: \(why)"
        case .deviceHogged(let pid): return "Process \(pid) holds exclusive access to the input device"
        case .alreadyRunning: return "The measurement input session already runs"
        case .ioProcFailed(let s): return "Input IOProc setup failed: \(describeOSStatus(s))"
        }
    }
}

// MARK: - Permission

/// The macOS Microphone permission. Thin wrappers over `AVCaptureDevice`.
///
/// `status` only reads; it never shows a prompt. `request` SHOWS THE SYSTEM PROMPT when the status
/// is `notDetermined`: call it only from the app's measurement window, on a user click. The host
/// app needs `NSMicrophoneUsageDescription` in its Info.plist, or macOS kills the process on request.
public enum MicrophonePermission {
    public enum Status: String, Sendable {
        case notDetermined, denied, restricted, authorized
    }

    public static var status: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Shows the macOS prompt when the status is `notDetermined`; otherwise answers at once with
    /// the stored decision. `completion` runs on the main queue.
    public static func request(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    /// Opens System Settings → Privacy & Security → Microphone. Only opens the pane. It changes no setting.
    public static func openSystemSettings() {
        guard let url = URL(string: settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Device list

public enum MeasurementInputTransport: String, Sendable, Codable {
    case usb = "USB"
    case builtIn = "built-in"
    case aggregate
    case virtual
    case bluetooth
    /// Thunderbolt, PCI, FireWire, HDMI, AirPlay, Continuity and whatever the HAL adds later.
    case other

    init(transportType: UInt32) {
        switch transportType {
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeAggregate: self = .aggregate
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
        default: self = .other
        }
    }
}

public struct MeasurementInputDevice: Equatable, Sendable, Identifiable {
    public var uid: String
    public var name: String
    /// Input channels over all input streams.
    public var channelCount: Int
    public var nominalSampleRate: Double
    /// Rates the device offers, ascending. A device that reports a continuous range shows the
    /// ends of the range and the common rates inside it.
    public var availableSampleRates: [Double]
    public var transport: MeasurementInputTransport
    public var isDefaultInput: Bool

    public var id: String { uid }

    public init(uid: String, name: String, channelCount: Int, nominalSampleRate: Double,
                availableSampleRates: [Double], transport: MeasurementInputTransport, isDefaultInput: Bool) {
        self.uid = uid; self.name = name; self.channelCount = channelCount
        self.nominalSampleRate = nominalSampleRate; self.availableSampleRates = availableSampleRates
        self.transport = transport; self.isDefaultInput = isDefaultInput
    }
}

public enum MeasurementInput {
    /// Every device with at least one input channel, without Joseon's own private tap aggregate.
    /// Reads properties only: needs no permission, opens nothing.
    public static func devices() -> [MeasurementInputDevice] {
        let defaultInput = HAL.value(HAL.system, kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(kAudioObjectUnknown))
        return HAL.array(HAL.system, kAudioHardwarePropertyDevices, filler: AudioObjectID(0)).compactMap { id in
            let channels = inputFormats(id).reduce(0) { $0 + Int($1.mChannelsPerFrame) }
            guard channels > 0, let uid = HAL.string(id, kAudioDevicePropertyDeviceUID),
                  !MeasurementDeviceFacts.isJoseonTapAggregate(uid: uid) else { return nil }
            return MeasurementInputDevice(
                uid: uid,
                name: HAL.string(id, kAudioObjectPropertyName) ?? "Unknown device",
                channelCount: channels,
                nominalSampleRate: nominalRate(id),
                availableSampleRates: MeasurementDeviceFacts.discreteRates(rateRanges(id)),
                transport: MeasurementInputTransport(transportType: HAL.value(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0),
                isDefaultInput: id == defaultInput)
        }
    }

    static func deviceID(uid: String) -> AudioObjectID? {
        HAL.array(HAL.system, kAudioHardwarePropertyDevices, filler: AudioObjectID(0))
            .first { HAL.string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// Virtual format of every input stream, in device order. The IOProc gets the virtual format.
    static func inputFormats(_ device: AudioObjectID) -> [AudioStreamBasicDescription] {
        HAL.streams(device, scope: kAudioObjectPropertyScopeInput).compactMap(HAL.virtualFormat)
    }

    static func nominalRate(_ device: AudioObjectID) -> Double {
        HAL.value(device, kAudioDevicePropertyNominalSampleRate, initial: Double(0)) ?? 0
    }

    static func rateRanges(_ device: AudioObjectID) -> [(min: Double, max: Double)] {
        HAL.array(device, kAudioDevicePropertyAvailableNominalSampleRates, filler: AudioValueRange())
            .map { ($0.mMinimum, $0.mMaximum) }
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        (HAL.value(device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) ?? 0) != 0
    }
}

// MARK: - Session

/// One input channel of one device, as mono Float32 blocks.
///
/// Threads:
/// - `control` (serial queue): owns every Core Audio object. start / stop and all property listeners run here.
/// - IO thread: the IOProc. It touches only `MeasurementIOCore` (preallocated) and calls the handler.
/// - main queue: `onStop`.
///
/// `start` opens the input. It never shows the Microphone prompt: without the permission it throws.
/// When `preferredSampleRate` differs from the device's rate and the device offers it, `start` SETS
/// the device's nominal sample rate (a system-wide device setting, as Audio MIDI Setup does) and
/// does not set it back on `stop`.
public final class MeasurementInputSession: @unchecked Sendable {
    /// (mono samples, frame count, sample rate, host time of the first frame in `mach_absolute_time` units).
    ///
    /// Called on the REAL-TIME IO thread. The handler MUST be real-time safe: no allocation, no
    /// locks, no Objective-C, no logging, no file or network I/O, no `DispatchQueue` calls, no Swift
    /// array growth. Copy the samples into memory that already exists (`MeasurementRecorder` does)
    /// and return. The pointer is valid only during the call. One IO cycle normally is one call; a
    /// cycle longer than the internal buffer arrives as several calls with matching host times.
    public typealias Handler = (UnsafePointer<Float>, Int, Double, UInt64) -> Void

    public enum StopReason: String, Sendable {
        /// `stop()` was called.
        case requested
        /// The device went away (unplugged, driver gone).
        case deviceRemoved
        /// The device's sample rate or stream layout changed under the session. Start again.
        case formatChanged
    }

    public let deviceUID: String
    /// 0-based index over all input channels of the device.
    public let channel: Int
    public let preferredSampleRate: Double?

    /// Runs on the main queue when the session stops by itself (`deviceRemoved`, `formatChanged`).
    /// Not called for `stop()`.
    public var onStop: ((StopReason) -> Void)? {
        get { stateLock.withLock { _onStop } }
        set { stateLock.withLock { _onStop = newValue } }
    }

    public var isRunning: Bool { stateLock.withLock { _running } }
    /// The rate the session runs at. 0 when it never started.
    public var sampleRate: Double { stateLock.withLock { _sampleRate } }
    /// Why the session stopped last. Nil while it runs and before the first start.
    public var stopReason: StopReason? { stateLock.withLock { _stopReason } }
    /// Physical format of the stream that carries the chosen channel (what the converter of the
    /// interface delivers), read at `start`. Nil when the session never started.
    public var physicalFormat: AudioFormatDescription? { stateLock.withLock { _physicalFormat } }

    /// Peak of the last 100 ms in dBFS. −infinity for digital silence and while stopped. Thread-safe.
    public var peakDB: Double { level { $0.peak } }
    /// RMS of the last 100 ms in dBFS (a full-scale sine reads −3.01). −infinity while stopped. Thread-safe.
    public var rmsDB: Double { level { $0.rms } }
    /// True when any sample reached |x| ≥ 0.999 since the last `start`. Stays readable after `stop`. Thread-safe.
    public var clippedSinceStart: Bool { stateLock.withLock { _core }?.meter.clipped ?? false }

    /// Live query. While stopped it looks the device up by UID, so it is also "is the device plugged in".
    public var deviceIsAlive: Bool {
        let running: AudioObjectID? = stateLock.withLock { _running ? _device : nil }
        guard let id = running ?? MeasurementInput.deviceID(uid: deviceUID) else { return false }
        return MeasurementInput.isAlive(id)
    }

    /// Diagnostics since the last `start`. Zero cycles while running means the IOProc never ran.
    public var ioCycleCount: Int { stateLock.withLock { _core }?.cycleCount ?? 0 }
    public var framesDelivered: Int { stateLock.withLock { _core }?.framesDelivered ?? 0 }
    /// IO cycles whose buffers did not match the layout read at `start`; nothing was delivered for them.
    public var formatMismatchCount: Int { stateLock.withLock { _core }?.formatMismatchCount ?? 0 }

    // MARK: State

    private let stateLock = NSLock()
    private var _running = false
    private var _sampleRate: Double = 0
    private var _stopReason: StopReason?
    private var _physicalFormat: AudioFormatDescription?
    private var _onStop: ((StopReason) -> Void)?
    private var _core: MeasurementIOCore?
    private var _device = AudioObjectID(kAudioObjectUnknown)

    private let control = DispatchQueue(label: "joseon.measure.control", qos: .userInitiated)
    private let controlKey = DispatchSpecificKey<Bool>()

    // Owned by `control`.
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var plan: MeasurementChannelPlan?
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    /// Frames of the conversion buffer: at least this, or the device's largest IO buffer when that is larger.
    private static let minimumScratchFrames = 1 << 14
    private static let maximumScratchFrames = 1 << 18

    public init(deviceUID: String, channel: Int, preferredSampleRate: Double?) {
        self.deviceUID = deviceUID
        self.channel = channel
        self.preferredSampleRate = preferredSampleRate
        control.setSpecific(key: controlKey, value: true)
    }

    deinit { onControl { self.teardown(reason: .requested) } }

    // MARK: Start / stop

    /// Opens the input and starts IO. Synchronous; do not call it on the main thread when
    /// `preferredSampleRate` may change the device rate (the wait for the device takes up to 3 s).
    public func start(handler: @escaping Handler) throws {
        try onControl {
            guard !self.stateLock.withLock({ self._running }) else { throw MeasurementInputError.alreadyRunning }
            // First of all, and before any Core Audio call: never reach AudioDeviceStart without the
            // permission, because the HAL would then show the prompt (or deliver silence).
            let permission = MicrophonePermission.status
            guard permission == .authorized else { throw MeasurementInputError.permissionNotGranted(permission) }
            do { try self.build(handler: handler) } catch { self.teardown(reason: nil); throw error }
        }
    }

    public func stop() {
        onControl { self.teardown(reason: .requested) }
    }

    /// Run on the control queue and wait. Safe when already on it (listener → teardown paths).
    private func onControl<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: controlKey) == true { return try body() }
        return try control.sync(execute: body)
    }

    private func level(_ pick: ((peak: Float, rms: Float)) -> Float) -> Double {
        let core: MeasurementIOCore? = stateLock.withLock { _running ? _core : nil }
        guard let core else { return -.infinity }
        return MeasurementMeterMath.decibels(pick(core.meter.read()))
    }

    // MARK: Build (control queue)

    private func build(handler: @escaping Handler) throws {
        guard let id = MeasurementInput.deviceID(uid: deviceUID) else { throw MeasurementInputError.deviceNotFound(uid: deviceUID) }
        guard MeasurementInput.isAlive(id) else { throw MeasurementInputError.deviceNotAlive(uid: deviceUID) }
        let hog = HAL.hogPID(id)
        guard hog == -1 || hog == getpid() else { throw MeasurementInputError.deviceHogged(pid: hog) }
        guard !MeasurementInput.inputFormats(id).isEmpty else { throw MeasurementInputError.notAnInputDevice }
        device = id

        // 1. Sample rate first: a rate change can change the stream layout.
        if let rate = MeasurementDeviceFacts.rateToSet(preferred: preferredSampleRate,
                                                       nominal: MeasurementInput.nominalRate(id),
                                                       ranges: MeasurementInput.rateRanges(id)) {
            setNominalRate(id, rate)
        }
        let rate = MeasurementInput.nominalRate(id)
        guard rate > 0 else { throw MeasurementInputError.unsupportedFormat("the device reports no sample rate") }

        // 2. Where the channel is and how its samples look. Throws for anything we do not convert.
        let plan = try MeasurementChannelPlanner.plan(streams: MeasurementInput.inputFormats(id), channel: channel)
        self.plan = plan

        // 3. Everything the IO thread uses exists before it starts.
        let range = HAL.value(id, kAudioDevicePropertyBufferFrameSizeRange, initial: AudioValueRange())
        let largest = Int(range?.mMaximum ?? 0)
        let scratch = min(Self.maximumScratchFrames, max(Self.minimumScratchFrames, largest))
        let core = MeasurementIOCore(plan: plan, sampleRate: rate, scratchFrames: scratch,
                                     hostTicksPerFrame: MeasurementIOCore.hostTicksPerFrame(sampleRate: rate),
                                     meter: MeasurementLevelMeter(sampleRate: rate), handler: handler)
        let physical = Self.streamCarrying(plan: plan, device: id).flatMap(HAL.physicalFormat).map(AudioFormatDescription.init)

        // 4. IOProc on the input device itself.
        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil, Self.makeIOBlock(core: core))
        guard status == noErr, let proc else { throw MeasurementInputError.ioProcFailed(status) }
        ioProcID = proc

        // 5. Follow the device, then start.
        listen(id, kAudioDevicePropertyDeviceIsAlive) { [weak self] in self?.aliveChanged() }
        listen(id, kAudioDevicePropertyNominalSampleRate) { [weak self] in self?.formatMayHaveChanged() }
        listen(id, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput) { [weak self] in self?.formatMayHaveChanged() }
        if let stream = Self.streamCarrying(plan: plan, device: id) {
            listen(stream, kAudioStreamPropertyVirtualFormat) { [weak self] in self?.formatMayHaveChanged() }
        }

        stateLock.withLock {
            _core = core; _device = id; _sampleRate = rate; _physicalFormat = physical
            _stopReason = nil; _running = true
        }
        status = AudioDeviceStart(id, proc)
        guard status == noErr else { throw MeasurementInputError.ioProcFailed(status) }
    }

    /// Stop IO, destroy the IOProc, remove the listeners. `reason` nil = a failed start (no `stopReason`).
    private func teardown(reason: StopReason?) {
        for l in listeners {
            var addr = l.address
            AudioObjectRemovePropertyListenerBlock(l.object, &addr, control, l.block)
        }
        listeners.removeAll()
        if device != kAudioObjectUnknown, let proc = ioProcID {
            // AudioDeviceStop returns after the last IO cycle. The block keeps the core alive until
            // the IOProc is destroyed, so the IO thread never sees freed memory.
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        ioProcID = nil
        plan = nil
        device = AudioObjectID(kAudioObjectUnknown)
        stateLock.withLock {
            let wasRunning = _running
            _running = false
            _device = AudioObjectID(kAudioObjectUnknown)
            if reason == nil { _core = nil } else if wasRunning { _stopReason = reason }
        }
    }

    // MARK: Following the device (control queue)

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ handler: @escaping () -> Void) {
        var addr = HAL.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(object, &addr, control, block) == noErr {
            listeners.append((object, addr, block))
        }
    }

    private func aliveChanged() {
        guard device != kAudioObjectUnknown, !MeasurementInput.isAlive(device) else { return }
        stopBySelf(.deviceRemoved)
    }

    private func formatMayHaveChanged() {
        guard device != kAudioObjectUnknown, let plan, stateLock.withLock({ _running }) else { return }
        let rate = MeasurementInput.nominalRate(device)
        let now = try? MeasurementChannelPlanner.plan(streams: MeasurementInput.inputFormats(device), channel: channel)
        if rate != stateLock.withLock({ _sampleRate }) || now != plan { stopBySelf(.formatChanged) }
    }

    private func stopBySelf(_ reason: StopReason) {
        guard stateLock.withLock({ _running }) else { return }
        teardown(reason: reason)
        let callback = onStop
        DispatchQueue.main.async { callback?(reason) }
    }

    // MARK: HAL helpers (control queue)

    /// Sets the nominal rate and waits (up to 3 s) until the device reports it. The caller reads
    /// the rate back afterwards and runs at whatever the device then has.
    private func setNominalRate(_ id: AudioObjectID, _ rate: Double) {
        var addr = HAL.address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        guard AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &value) == noErr else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while abs(MeasurementInput.nominalRate(id) - rate) > 0.5, ProcessInfo.processInfo.systemUptime < deadline {
            usleep(20_000)
        }
    }

    /// The input stream object that carries the planned buffer.
    private static func streamCarrying(plan: MeasurementChannelPlan, device: AudioObjectID) -> AudioObjectID? {
        var bufferIndex = 0
        for stream in HAL.streams(device, scope: kAudioObjectPropertyScopeInput) {
            guard let format = HAL.virtualFormat(stream) else { continue }
            let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            let buffers = planar ? Int(format.mChannelsPerFrame) : 1
            if plan.bufferIndex < bufferIndex + buffers { return stream }
            bufferIndex += buffers
        }
        return nil
    }

    // MARK: Real-time IOProc

    /// Real-time rules: no allocation, no locks, no logging, no ObjC messaging.
    /// The block captures the preallocated core only. It never touches the session.
    private static func makeIOBlock(core: MeasurementIOCore) -> AudioDeviceIOBlock {
        return { inNow, inInputData, inInputTime, outOutputData, _ in
            // We play nothing. A device that also has outputs (a USB interface) must get zeros from us.
            let outCount = Int(outOutputData.pointee.mNumberBuffers)
            if outCount > 0 {
                let outs = UnsafeMutableAudioBufferListPointer(outOutputData)
                var o = 0
                while o < outCount {
                    if let data = outs[o].mData { memset(data, 0, Int(outs[o].mDataByteSize)) }
                    o += 1
                }
            }
            // Host time of the first input frame; the cycle's "now" when the input stamp carries none.
            let stamp = inInputTime.pointee.mFlags.contains(.hostTimeValid) ? inInputTime.pointee.mHostTime : inNow.pointee.mHostTime
            core.process(input: inInputData, hostTime: stamp)
        }
    }
}

// MARK: - Recorder

/// Collects the handler's blocks into one preallocated buffer of a fixed maximum length and hands
/// the recording out as `[Float]`. Memory only: it never writes to disk.
///
/// Use: `let recorder = MeasurementRecorder(maxSeconds: 15, sampleRate: rate)`, then
/// `try session.start(handler: recorder.handler)`, then `session.stop()`, then `recorder.recording()`.
///
/// `append` is real-time safe: one bounded copy into existing memory and single-word stores; no
/// allocation, no lock. When the buffer is full the rest is dropped and counted (`overflowed`,
/// `droppedFrames`): the recording always is the FIRST `capacity` frames, without a gap inside.
/// One writer thread (the IO thread). The read side is safe from any thread at any time: a
/// published frame is never rewritten, and the frame count is published after the frames it counts.
public final class MeasurementRecorder: @unchecked Sendable {
    public let capacity: Int

    private let buffer: UnsafeMutablePointer<Float>
    private let words = makeRTWords(count: 4)
    private static let countWord = 0, droppedWord = 1, hostTimeWord = 2, rateWord = 3

    /// IO-thread-only state, out of line so the IO thread reaches it through a raw pointer.
    private struct Writer { var count = 0; var dropped = 0 }
    private let writer: UnsafeMutablePointer<Writer>

    /// Room for `maxSeconds` at `sampleRate` (15 s at 48 kHz = 720 000 frames = 2.7 MB).
    public convenience init(maxSeconds: Double = 15, sampleRate: Double) {
        self.init(capacityFrames: Int((max(0, maxSeconds) * max(0, sampleRate)).rounded(.up)))
    }

    public init(capacityFrames: Int) {
        capacity = max(1, capacityFrames)
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)   // also touches the pages: no page fault on the IO thread
        writer = .allocate(capacity: 1)
        writer.initialize(to: Writer())
    }

    deinit {
        buffer.deallocate()
        writer.deinitialize(count: 1)
        writer.deallocate()
    }

    /// Real-time safe. IO thread only.
    public func append(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double, hostTime: UInt64) {
        guard count > 0 else { return }
        let have = writer.pointee.count
        let n = min(count, capacity - have)
        if n > 0 {
            (buffer + have).update(from: samples, count: n)
            if have == 0 {
                words.store(Self.hostTimeWord, hostTime)
                words.store(Self.rateWord, sampleRate.bitPattern)
            }
            writer.pointee.count = have + n
            words.store(Self.countWord, UInt64(have + n))   // last: it announces the samples and the two words above
        }
        if n < count {
            writer.pointee.dropped += count - n
            words.store(Self.droppedWord, UInt64(writer.pointee.dropped))
        }
    }

    /// Pass this to `MeasurementInputSession.start(handler:)`. It is `append`, nothing more.
    public var handler: MeasurementInputSession.Handler {
        { [self] samples, count, rate, hostTime in self.append(samples, count: count, sampleRate: rate, hostTime: hostTime) }
    }

    public var frameCount: Int { Int(words.load(Self.countWord)) }
    /// True when blocks arrived after the buffer was full.
    public var overflowed: Bool { words.load(Self.droppedWord) != 0 }
    /// Frames that did not fit.
    public var droppedFrames: Int { Int(words.load(Self.droppedWord)) }
    /// Host time (`mach_absolute_time` units) of the first recorded frame. 0 when empty.
    public var firstHostTime: UInt64 { frameCount > 0 ? words.load(Self.hostTimeWord) : 0 }
    /// Sample rate of the recording. 0 when empty.
    public var sampleRate: Double { frameCount > 0 ? Double(bitPattern: words.load(Self.rateWord)) : 0 }
    public var secondsRecorded: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }

    /// A copy of the recorded frames. Call it after `session.stop()` for the whole recording.
    public func recording() -> [Float] {
        let n = frameCount
        return n > 0 ? Array(UnsafeBufferPointer(start: buffer, count: n)) : []
    }

    /// Empties the recorder for the next run. Call it only while no session feeds this recorder.
    public func reset() {
        writer.pointee = Writer()
        words.store(Self.countWord, 0)
        words.store(Self.droppedWord, 0)
        words.store(Self.hostTimeWord, 0)
        words.store(Self.rateWord, 0)
    }
}
