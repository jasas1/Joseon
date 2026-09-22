import Accelerate
import AppKit
import CoreAudio
import Foundation
import JoseonCore

public enum CaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case noOutputDevice
    case notImplemented

    public var description: String {
        switch self {
        case .permissionDenied: return "System audio capture permission denied"
        case .tapCreationFailed(let s): return "AudioHardwareCreateProcessTap failed: \(describeOSStatus(s))"
        case .aggregateDeviceFailed(let s): return "AudioHardwareCreateAggregateDevice failed: \(describeOSStatus(s))"
        case .ioProcFailed(let s): return "IOProc setup failed: \(describeOSStatus(s))"
        case .noOutputDevice: return "No default output device"
        case .notImplemented: return "Capture not implemented"
        }
    }
}

/// Permission helper for "System Audio Recording" (TCC service kTCCServiceAudioCapture).
///
/// macOS has no public preflight API for this permission. The prompt shows on first tap use.
/// When the user denies it (or never answers), the tap still starts and delivers digital silence.
/// Heuristic the app must use: the tap is silent for more than 3 s while `activeSources` is not
/// empty → the permission is likely denied. See `SystemAudioTap.isLikelyPermissionDenied`.
public enum CapturePermission {
    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"

    /// Opens System Settings → Privacy & Security → Screen & System Audio Recording.
    /// Only opens the pane. It changes no setting.
    public static func openSystemSettings() {
        guard let url = URL(string: settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Captures ALL system output audio with a Core Audio process tap (macOS 14.4+). No driver.
///
/// Threads:
/// - `control` (serial queue): owns every Core Audio object. start / stop / rebuild and all
///   property listeners run here.
/// - IO thread: the IOProc. It touches only `RTState` (raw pointers) and the ring buffer.
/// - `sourcesQueue` (utility): polls the process list once per second.
/// - main queue: `onStreamInfoChange` callbacks.
public final class SystemAudioTap: AudioSource, @unchecked Sendable {

    // MARK: AudioSource

    public var streamInfo: StreamInfo? { stateLock.withLock { _streamInfo } }
    public let ringBuffer = StereoRingBuffer()
    public var onStreamInfoChange: ((StreamInfo) -> Void)? {
        get { stateLock.withLock { _onChange } }
        set { stateLock.withLock { _onChange = newValue } }
    }
    public var isRunning: Bool { stateLock.withLock { _running } }

    // MARK: Added public API

    /// True when any non-zero sample arrived since `start()`.
    public var hasReceivedSignal: Bool { signalFlag.pointee != 0 }

    /// Seconds since `start()`. 0 when stopped.
    public var secondsSinceStart: Double {
        stateLock.withLock { _running ? ProcessInfo.processInfo.systemUptime - _startUptime : 0 }
    }

    /// True when another process holds exclusive (hog mode) access to the default output device.
    /// Audio then bypasses the system mixer and the tap hears silence. Live query, cheap.
    public var outputDeviceIsHogged: Bool {
        guard let device = HAL.defaultOutputDevice() else { return false }
        let pid = HAL.hogPID(device)
        return pid != -1 && pid != getpid()
    }

    /// The documented heuristic: running, silent for more than 3 s, some app plays audio,
    /// and hog mode does not explain the silence → "System Audio Recording" is likely denied.
    /// It is a guess: a player that is open but paused-with-IO-running looks the same.
    public var isLikelyPermissionDenied: Bool {
        guard isRunning, !hasReceivedSignal, secondsSinceStart > 3, !outputDeviceIsHogged else { return false }
        return !(streamInfo?.activeSources.isEmpty ?? true)
    }

    /// Diagnostics: IO cycles and frames delivered since `start()`. Zero cycles means the IOProc never ran.
    public var ioCycleCount: Int { Int(counters[0]) }
    public var framesDelivered: Int { Int(counters[1]) }

    /// Last Core Audio error seen during an automatic rebuild (device switch). Nil when the last build was clean.
    public var lastRebuildError: CaptureError? { stateLock.withLock { _lastRebuildError } }

    // MARK: State

    private let stateLock = NSLock()
    private var _streamInfo: StreamInfo?
    private var _onChange: ((StreamInfo) -> Void)?
    private var _running = false
    private var _startUptime: Double = 0
    private var _lastRebuildError: CaptureError?

    private let control = DispatchQueue(label: "joseon.capture.control", qos: .userInitiated)
    private let controlKey = DispatchSpecificKey<Bool>()
    private let sourcesQueue = DispatchQueue(label: "joseon.capture.sources", qos: .utility)

    // Owned by `control`.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var rt: UnsafeMutablePointer<RTState>?
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)
    private var captureSampleRate: Double = 0
    private var captureChannels = 0
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var sourcesTimer: DispatchSourceTimer?
    private var activeSources: [String] = []
    private var rebuildGeneration = 0

    // Written by the IO thread, read anywhere. Single aligned words: no lock.
    private let signalFlag: UnsafeMutablePointer<Int32>
    private let counters: UnsafeMutablePointer<Int64>   // [0] = IO cycles, [1] = frames

    private static let scratchFrames = 1 << 14

    public init() {
        signalFlag = .allocate(capacity: 1); signalFlag.initialize(to: 0)
        counters = .allocate(capacity: 2); counters.initialize(repeating: 0, count: 2)
        control.setSpecific(key: controlKey, value: true)
    }

    deinit {
        onControl { self.teardownAll() }
        signalFlag.deallocate()
        counters.deallocate()
    }

    // MARK: Start / stop

    /// Builds the tap graph and starts IO. Synchronous.
    ///
    /// First-run warning (seen on macOS 26.6): while the "System Audio Recording" prompt is on screen,
    /// `AudioDeviceCreateIOProcIDWithBlock` does not return, so this call blocks until the user answers.
    /// Do not call it on the main thread in an app. Use `startAsync`.
    /// Measured with the prompt left unanswered: the call returned `noErr` after about 90 s, the IOProc
    /// never ran (`ioCycleCount == 0`), and `stop()` then blocked about 90 s in `AudioDeviceStop`.
    /// When the permission is denied, or the host process has no `NSAudioCaptureUsageDescription`,
    /// every call still returns `noErr` and the tap delivers digital silence.
    public func start() throws {
        try onControl {
            guard !self.stateLock.withLock({ self._running }) else { return }
            self.signalFlag.pointee = 0
            self.counters[0] = 0; self.counters[1] = 0
            do { try self.build() } catch { self.teardownGraph(); throw error }
            self.stateLock.withLock {
                self._running = true
                self._startUptime = ProcessInfo.processInfo.systemUptime
                self._lastRebuildError = nil
            }
            self.installSystemListener()
            self.startSourcesTimer()
            self.publish()
        }
    }

    /// `start()` on a background queue. `completion` runs on the main queue with nil on success.
    public func startAsync(completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: Error?
            do { try self?.start() } catch { failure = error }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    /// Blocks while a `start()` is waiting on the permission prompt (same serial queue).
    public func stop() {
        onControl { self.teardownAll() }
    }

    private func teardownAll() {
        rebuildGeneration += 1
        sourcesTimer?.cancel(); sourcesTimer = nil
        removeSystemListener()
        teardownGraph()
        stateLock.withLock { _running = false; _streamInfo = nil }
    }

    /// Run on the control queue and wait. Safe when already on it (listener → deinit paths).
    private func onControl<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: controlKey) == true { return try body() }
        return try control.sync(execute: body)
    }

    // MARK: Build the tap → aggregate device → IOProc graph (control queue)

    private func build() throws {
        guard let device = HAL.defaultOutputDevice(),
              let deviceUID = HAL.string(device, kAudioDevicePropertyDeviceUID) else { throw CaptureError.noOutputDevice }
        outputDevice = device

        // 1. Global stereo tap: every process, mixed down to stereo, playback untouched.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Joseon system tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr, newTap != kAudioObjectUnknown else { throw CaptureError.tapCreationFailed(status) }
        tapID = newTap

        guard let tapFormat = HAL.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()) else {
            throw CaptureError.tapCreationFailed(kAudioHardwareUnknownPropertyError)
        }
        let isFloat32 = tapFormat.mFormatID == kAudioFormatLinearPCM
            && tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && tapFormat.mBitsPerChannel == 32
        guard isFloat32, tapFormat.mChannelsPerFrame > 0 else { throw CaptureError.ioProcFailed(kAudioDeviceUnsupportedFormatError) }
        let tapUID = HAL.string(tapID, kAudioTapPropertyUID) ?? description.uuid.uuidString

        // 2. Private aggregate device: output device as main sub-device (clock), tap as sub-tap.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Joseon Capture",
            kAudioAggregateDeviceUIDKey: "app.joseon.Joseon.capture." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
        guard status == noErr, newAggregate != kAudioObjectUnknown else { throw CaptureError.aggregateDeviceFailed(status) }
        aggregateID = newAggregate

        // 3. Where is the tap in the IOProc input buffer list? When the output device also has
        //    input streams (USB interface, headset), those come first; the tap streams come last.
        let deviceInputStreams = HAL.streams(device, scope: kAudioObjectPropertyScopeInput).count
        let aggregateInputStreams = HAL.streams(aggregateID, scope: kAudioObjectPropertyScopeInput).count
        let planar = tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let tapStreams = planar ? Int(tapFormat.mChannelsPerFrame) : 1
        var tapBufferIndex = 0
        if aggregateInputStreams > tapStreams {
            tapBufferIndex = deviceInputStreams + tapStreams == aggregateInputStreams
                ? deviceInputStreams
                : aggregateInputStreams - tapStreams
        }

        let aggregateRate = HAL.value(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Double(0)) ?? 0
        captureSampleRate = aggregateRate > 0 ? aggregateRate : tapFormat.mSampleRate
        captureChannels = Int(tapFormat.mChannelsPerFrame)

        // 4. IOProc. All memory it uses exists before it starts.
        let state = UnsafeMutablePointer<RTState>.allocate(capacity: 1)
        let scratchL = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchFrames)
        let scratchR = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchFrames)
        scratchL.initialize(repeating: 0, count: Self.scratchFrames)
        scratchR.initialize(repeating: 0, count: Self.scratchFrames)
        state.initialize(to: RTState(
            scratchL: scratchL, scratchR: scratchR, scratchFrames: Self.scratchFrames,
            sampleRate: captureSampleRate, tapBufferIndex: tapBufferIndex,
            planarStereo: planar && tapFormat.mChannelsPerFrame >= 2,
            signalFlag: signalFlag, counters: counters))
        rt = state

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil, Self.makeIOBlock(state: state, ring: ringBuffer))
        guard status == noErr, let proc else { throw CaptureError.ioProcFailed(status) }
        ioProcID = proc
        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else { throw CaptureError.ioProcFailed(status) }

        // 5. Follow the output device.
        listen(device, kAudioDevicePropertyNominalSampleRate) { [weak self] in self?.outputRateChanged() }
        listen(device, kAudioDevicePropertyDeviceIsAlive) { [weak self] in self?.scheduleRebuild() }
        listen(device, kAudioDevicePropertyHogMode) { [weak self] in self?.publish() }
        if let stream = HAL.streams(device, scope: kAudioObjectPropertyScopeOutput).first {
            listen(stream, kAudioStreamPropertyPhysicalFormat) { [weak self] in self?.publish() }
        }
    }

    /// Destroy IOProc, aggregate device, tap, device listeners, RT memory. Leaves `_running` alone.
    private func teardownGraph() {
        for l in listeners {
            var addr = l.address
            AudioObjectRemovePropertyListenerBlock(l.object, &addr, control, l.block)
        }
        listeners.removeAll()
        if aggregateID != kAudioObjectUnknown {
            if let proc = ioProcID {
                AudioDeviceStop(aggregateID, proc)
                AudioDeviceDestroyIOProcID(aggregateID, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        // AudioDeviceStop returns after the last IO cycle, so nothing reads this memory now.
        if let state = rt {
            state.pointee.scratchL.deallocate()
            state.pointee.scratchR.deallocate()
            state.deinitialize(count: 1)
            state.deallocate()
        }
        rt = nil
        outputDevice = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Following changes (control queue)

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var addr = HAL.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(object, &addr, control, block) == noErr {
            listeners.append((object, addr, block))
        }
    }

    private func installSystemListener() {
        guard systemListener == nil else { return }
        var addr = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRebuild() }
        if AudioObjectAddPropertyListenerBlock(HAL.system, &addr, control, block) == noErr { systemListener = block }
    }

    private func removeSystemListener() {
        guard let block = systemListener else { return }
        var addr = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(HAL.system, &addr, control, block)
        systemListener = nil
    }

    private func outputRateChanged() {
        guard outputDevice != kAudioObjectUnknown,
              let rate = HAL.value(outputDevice, kAudioDevicePropertyNominalSampleRate, initial: Double(0)) else { return }
        // The tap format follows the device rate. Rebuild so format, scratch and rate all agree.
        if rate != captureSampleRate { scheduleRebuild() }
    }

    /// Debounced: a device switch fires several notifications in a row.
    private func scheduleRebuild(after delay: Double = 0.15) {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        control.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.rebuildGeneration, self.stateLock.withLock({ self._running }) else { return }
            self.teardownGraph()
            do {
                try self.build()
                self.stateLock.withLock { self._lastRebuildError = nil }
                self.publish()
            } catch {
                self.teardownGraph()
                self.stateLock.withLock { self._lastRebuildError = error as? CaptureError }
                self.scheduleRebuild(after: 2)   // for example no output device for a moment
            }
        }
    }

    // MARK: StreamInfo

    /// Build StreamInfo from the live graph and send it to the main queue when it changed.
    private func publish() {
        onControl {
            guard self.outputDevice != kAudioObjectUnknown else { return }
            let device = self.outputDevice
            let physical = HAL.streams(device, scope: kAudioObjectPropertyScopeOutput).first.flatMap(HAL.physicalFormat)
            let bits = physical.map { Int($0.mBitsPerChannel) }.flatMap { $0 > 0 ? $0 : nil }
            let info = StreamInfo(
                sampleRate: self.captureSampleRate,
                channelCount: self.captureChannels,
                deviceName: HAL.string(device, kAudioObjectPropertyName) ?? "Unknown device",
                bitDepth: bits,
                activeSources: self.activeSources)
            let changed: Bool = self.stateLock.withLock {
                guard self._running, self._streamInfo != info else { return false }
                self._streamInfo = info
                return true
            }
            guard changed else { return }
            DispatchQueue.main.async { [weak self] in self?.onStreamInfoChange?(info) }
        }
    }

    private func startSourcesTimer() {
        sourcesTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: sourcesQueue)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            let names = AudioSystem.activeSources()
            guard let self else { return }
            self.control.async { [weak self] in
                guard let self, self.stateLock.withLock({ self._running }), names != self.activeSources else { return }
                self.activeSources = names
                self.publish()
            }
        }
        sourcesTimer = timer
        timer.resume()
    }

    // MARK: Real-time IOProc

    /// Everything the IO thread needs, as plain pointers. Made before the IOProc starts, freed after it stops.
    struct RTState {
        var scratchL: UnsafeMutablePointer<Float>
        var scratchR: UnsafeMutablePointer<Float>
        var scratchFrames: Int
        var sampleRate: Double
        var tapBufferIndex: Int
        var planarStereo: Bool
        var signalFlag: UnsafeMutablePointer<Int32>
        var counters: UnsafeMutablePointer<Int64>
    }

    /// Real-time rules: no allocation, no array growth, no logging, no ObjC messaging.
    /// The block captures one raw pointer and the ring buffer. It never touches `self`.
    private static func makeIOBlock(state: UnsafeMutablePointer<RTState>, ring: StereoRingBuffer) -> AudioDeviceIOBlock {
        return { _, inInputData, _, outOutputData, _ in
            // We play nothing. Make sure the output side of the aggregate device carries zeros.
            let outCount = Int(outOutputData.pointee.mNumberBuffers)
            if outCount > 0 {
                let outs = UnsafeMutableAudioBufferListPointer(outOutputData)
                var o = 0
                while o < outCount {
                    if let data = outs[o].mData { memset(data, 0, Int(outs[o].mDataByteSize)) }
                    o += 1
                }
            }

            let st = state.pointee
            let bufferCount = Int(inInputData.pointee.mNumberBuffers)
            guard bufferCount > 0 else { return }
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let index = min(st.tapBufferIndex, bufferCount - 1)
            let first = ins[index]
            let channels = Int(first.mNumberChannels)
            guard channels > 0, let raw = first.mData else { return }
            let samples = raw.assumingMemoryBound(to: Float.self)
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard frames > 0 else { return }

            st.counters[0] &+= 1
            st.counters[1] &+= Int64(frames)

            if channels == 1 {
                // Non-interleaved: one buffer per channel. Mono: the same buffer for both sides.
                var rightSamples = samples
                if st.planarStereo, index + 1 < bufferCount {
                    let second = ins[index + 1]
                    if second.mNumberChannels == 1, second.mDataByteSize == first.mDataByteSize, let r = second.mData {
                        rightSamples = r.assumingMemoryBound(to: Float.self)
                    }
                }
                if st.signalFlag.pointee == 0 {
                    var peakL: Float = 0, peakR: Float = 0
                    vDSP_maxmgv(samples, 1, &peakL, vDSP_Length(frames))
                    vDSP_maxmgv(rightSamples, 1, &peakR, vDSP_Length(frames))
                    if peakL > 0 || peakR > 0 { st.signalFlag.pointee = 1 }
                }
                ring.write(left: samples, right: rightSamples, count: frames, sampleRate: st.sampleRate)
            } else {
                // Interleaved: take the first two channels, in scratch-sized chunks.
                if st.signalFlag.pointee == 0 {
                    var peak: Float = 0
                    vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frames * channels))
                    if peak > 0 { st.signalFlag.pointee = 1 }
                }
                var done = 0
                while done < frames {
                    let n = min(st.scratchFrames, frames - done)
                    let base = samples + done * channels
                    var i = 0
                    while i < n {
                        st.scratchL[i] = base[i * channels]
                        st.scratchR[i] = base[i * channels + 1]
                        i += 1
                    }
                    ring.write(left: st.scratchL, right: st.scratchR, count: n, sampleRate: st.sampleRate)
                    done += n
                }
            }
        }
    }
}
