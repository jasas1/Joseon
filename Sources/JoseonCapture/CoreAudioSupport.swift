import AppKit
import CoreAudio
import Foundation

// Thin, allocation-tolerant wrappers around the Core Audio HAL property API.
// None of this runs on the IO thread.

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Read a fixed-size (POD) property. Returns nil when the HAL reports an error.
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         initial: T) -> T? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var out = initial
        let status = withUnsafeMutablePointer(to: &out) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        return status == noErr ? out : nil
    }

    /// Read a CFString property.
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var ref: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &ref) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    /// Read a variable-length array property of POD elements.
    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         filler: T) -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var items = [T](repeating: filler, count: count)
        let status = items.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw.baseAddress!)
        }
        guard status == noErr else { return [] }
        let got = Int(size) / MemoryLayout<T>.stride
        if got < count { items.removeLast(count - got) }
        return items
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let id = value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown)),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func streams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        array(device, kAudioDevicePropertyStreams, scope: scope, filler: AudioObjectID(0))
    }

    static func physicalFormat(_ stream: AudioObjectID) -> AudioStreamBasicDescription? {
        value(stream, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription())
    }

    static func virtualFormat(_ stream: AudioObjectID) -> AudioStreamBasicDescription? {
        value(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
    }

    /// pid that holds exclusive (hog) access, or -1.
    static func hogPID(_ device: AudioObjectID) -> pid_t {
        value(device, kAudioDevicePropertyHogMode, initial: pid_t(-1)) ?? -1
    }

    /// Address of the "which devices does this process play to" property.
    ///
    /// SCOPE TRAP: `kAudioProcessPropertyDevices` must be read with `kAudioObjectPropertyScopeOutput`.
    /// With the global scope the HAL answers an empty array for a process that is playing
    /// (measured 2026-09-22: Qobuz → ["Woo Audio"] in output scope, [] in global scope).
    static let processOutputDevicesAddress = address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)

    /// Output devices a process object plays to now (see `processOutputDevicesAddress` for the scope trap).
    static func processOutputDevices(_ process: AudioObjectID) -> [AudioObjectID] {
        array(process, processOutputDevicesAddress.mSelector, scope: processOutputDevicesAddress.mScope, filler: AudioObjectID(0))
    }

    /// The device with this UID, or nil when no visible device has it (unplugged).
    static func device(uid: String) -> AudioObjectID? {
        guard !uid.isEmpty else { return nil }
        return array(system, kAudioHardwarePropertyDevices, filler: AudioObjectID(0))
            .first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func fourCC(_ v: UInt32) -> String {
        let bytes = [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return String(bytes: bytes, encoding: .ascii) ?? "\(v)" }
        return "\(v)"
    }
}

/// A printable form of an `OSStatus`: the number, plus the four-char code when it is one.
public func describeOSStatus(_ status: OSStatus) -> String {
    let code = HAL.fourCC(UInt32(bitPattern: status))
    return code == "\(UInt32(bitPattern: status))" ? "\(status)" : "\(status) ('\(code)')"
}

// MARK: - Public, read-only facts about the audio system (used by joseon-probe `devices`)

public struct AudioFormatDescription: Equatable, Sendable {
    public var sampleRate: Double
    public var channels: Int
    public var bitsPerChannel: Int
    public var formatID: String
    public var isFloat: Bool
    public var isNonInterleaved: Bool

    init(_ asbd: AudioStreamBasicDescription) {
        sampleRate = asbd.mSampleRate
        channels = Int(asbd.mChannelsPerFrame)
        bitsPerChannel = Int(asbd.mBitsPerChannel)
        formatID = HAL.fourCC(asbd.mFormatID)
        isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    }
}

public struct AudioDeviceDescription: Equatable, Sendable {
    public var id: UInt32
    public var name: String
    public var uid: String
    public var transport: String
    public var nominalSampleRate: Double
    public var outputChannels: Int
    public var inputChannels: Int
    /// Physical format of the first output stream (what goes to the DAC).
    public var outputPhysicalFormat: AudioFormatDescription?
    /// Virtual format of the first output stream (what apps mix into).
    public var outputVirtualFormat: AudioFormatDescription?
    /// pid with exclusive access, -1 when nobody hogs the device.
    public var hogPID: Int32
    public var isAggregate: Bool

    /// True when a process other than this one holds exclusive access.
    public var isHoggedByOther: Bool { hogPID != -1 && hogPID != getpid() }
}

public enum AudioSystem {
    public static func describe(deviceID: UInt32) -> AudioDeviceDescription {
        let id = AudioObjectID(deviceID)
        let outStreams = HAL.streams(id, scope: kAudioObjectPropertyScopeOutput)
        let inStreams = HAL.streams(id, scope: kAudioObjectPropertyScopeInput)
        func channels(_ streams: [AudioObjectID]) -> Int {
            streams.reduce(0) { $0 + Int(HAL.virtualFormat($1)?.mChannelsPerFrame ?? 0) }
        }
        let transport = HAL.value(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
        return AudioDeviceDescription(
            id: deviceID,
            name: HAL.string(id, kAudioObjectPropertyName) ?? "Unknown device",
            uid: HAL.string(id, kAudioDevicePropertyDeviceUID) ?? "",
            transport: HAL.fourCC(transport),
            nominalSampleRate: HAL.value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0)) ?? 0,
            outputChannels: channels(outStreams),
            inputChannels: channels(inStreams),
            outputPhysicalFormat: outStreams.first.flatMap(HAL.physicalFormat).map(AudioFormatDescription.init),
            outputVirtualFormat: outStreams.first.flatMap(HAL.virtualFormat).map(AudioFormatDescription.init),
            hogPID: HAL.hogPID(id),
            isAggregate: transport == kAudioDeviceTransportTypeAggregate
        )
    }

    public static func defaultOutputDevice() -> AudioDeviceDescription? {
        HAL.defaultOutputDevice().map { describe(deviceID: $0) }
    }

    /// Every device this process can see. A private aggregate device is visible only to its owner,
    /// so a leak check must run inside the process that made the device.
    public static func allDevices() -> [AudioDeviceDescription] {
        HAL.array(HAL.system, kAudioHardwarePropertyDevices, filler: AudioObjectID(0)).map { describe(deviceID: $0) }
    }

    /// Tap objects this process can see.
    public static func tapCount() -> Int {
        HAL.array(HAL.system, kAudioHardwarePropertyTapList, filler: AudioObjectID(0)).count
    }

    /// Names of the processes that run audio output now, without this process. Sorted, no duplicates.
    public static func activeSources() -> [String] {
        Set(playingProcesses().map(\.name)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Bundle id prefix of every Joseon process (app, probe). None of them plays audio.
    public static let ownBundlePrefix = "app.joseon."

    /// True for a Joseon process: this pid, or any process with a Joseon bundle id.
    ///
    /// Measured 2026-09-22: the running Joseon app shows up as a "running output" process whose
    /// output-scope device is the default output (its capture aggregate has an output side that
    /// carries zeros). Counted as a player, it tied with Qobuz and dragged the choice to the default.
    public static func isOwnProcess(pid: Int32, bundleID: String, me: Int32 = getpid(),
                                    ownBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        if pid == me { return true }
        if bundleID.hasPrefix(ownBundlePrefix) { return true }
        if let ownBundleID, !ownBundleID.isEmpty, bundleID == ownBundleID { return true }
        return false
    }

    /// Every process that runs audio output now, without any Joseon process, with the output devices it plays to.
    /// One HAL walk; the sources timer calls it once a second. Order: process object list order.
    public static func playingProcesses() -> [ProcessPlayback] {
        let me = getpid()
        var result: [ProcessPlayback] = []
        for process in HAL.array(HAL.system, kAudioHardwarePropertyProcessObjectList, filler: AudioObjectID(0)) {
            guard let running = HAL.value(process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)), running != 0 else { continue }
            guard let pid = HAL.value(process, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else { continue }
            let bundleID = HAL.string(process, kAudioProcessPropertyBundleID) ?? ""
            guard !isOwnProcess(pid: pid, bundleID: bundleID, me: me) else { continue }
            let devices = HAL.processOutputDevices(process).compactMap { id -> PlaybackDevice? in
                guard let uid = HAL.deviceUID(id), !uid.isEmpty else { return nil }
                return PlaybackDevice(id: id, uid: uid,
                                      name: HAL.string(id, kAudioObjectPropertyName) ?? "Unknown device",
                                      nominalSampleRate: HAL.value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0)) ?? 0)
            }
            result.append(ProcessPlayback(pid: pid, bundleID: bundleID, name: displayName(pid: pid, bundleID: bundleID), devices: devices))
        }
        return result
    }

    /// The device the tap should clock on right now, by `PlaybackDeviceChooser` with no current choice.
    /// Nil only when there is no default output device and nothing plays.
    public static func chosenPlaybackDevice(playing: [ProcessPlayback]? = nil) -> AudioDeviceDescription? {
        let defaultUID = HAL.defaultOutputDevice().flatMap(HAL.deviceUID)
        let uid = PlaybackDeviceChooser.choose(playing: playing ?? playingProcesses(), current: nil, defaultOutput: defaultUID)
        return uid.flatMap(HAL.device(uid:)).map { describe(deviceID: $0) }
    }

    /// pid → app name. Helper processes (for example a browser's audio helper) have no
    /// NSRunningApplication, so walk the bundle id up to the owning app ("com.x.App.helper" → "com.x.App").
    static func displayName(pid: pid_t, bundleID: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName, !name.isEmpty {
            return name
        }
        var parts = bundleID.split(separator: ".").map(String.init)
        while parts.count > 2 {
            parts.removeLast()
            let candidate = parts.joined(separator: ".")
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: candidate).first,
               let name = app.localizedName, !name.isEmpty {
                return name
            }
        }
        return bundleID.isEmpty ? "pid \(pid)" : bundleID
    }
}

// MARK: - Which device to clock the tap on

/// An output device a process plays to.
public struct PlaybackDevice: Equatable, Sendable {
    public var id: UInt32
    public var uid: String
    public var name: String
    public var nominalSampleRate: Double

    public init(id: UInt32 = 0, uid: String, name: String = "", nominalSampleRate: Double = 0) {
        self.id = id
        self.uid = uid
        self.name = name
        self.nominalSampleRate = nominalSampleRate
    }
}

/// A process that runs audio output now, and the output devices it plays to.
public struct ProcessPlayback: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String
    /// Display name, for example "Qobuz".
    public var name: String
    /// Output-scope devices. A player that mixes into a device it did not open itself still lists it here.
    public var devices: [PlaybackDevice]

    public init(pid: Int32 = 0, bundleID: String = "", name: String, devices: [PlaybackDevice]) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.devices = devices
    }

    /// Test convenience: a process by name that plays to these device UIDs.
    public init(name: String, deviceUIDs: [String]) {
        self.init(name: name, devices: deviceUIDs.map { PlaybackDevice(uid: $0) })
    }

    public var deviceUIDs: [String] { devices.map(\.uid) }
}

/// Decides which output device the capture aggregate takes as its clock (main sub-device).
///
/// The macOS default output device is the wrong answer when a player picks its own device:
/// Qobuz → USB DAC at 96 kHz while the default is a display at 48 kHz. Then the tap would run
/// at 48 kHz and lose everything above 24 kHz. So the choice follows the playing processes.
///
/// Pure: no HAL calls, so the rules are unit-tested.
public enum PlaybackDeviceChooser {
    /// Rules, in order:
    /// (a) `current` still has a playing process → keep it (no flapping while it plays);
    /// (b) else the device of the playing process that comes first in a stable order:
    ///     most playing processes on the device, then the lowest process name on it, then the UID;
    /// (c) else `defaultOutput`.
    /// Processes with no device and empty UIDs are ignored. Nil only when (c) has nothing.
    public static func choose(playing: [ProcessPlayback], current: String?, defaultOutput: String?) -> String? {
        if let current, !current.isEmpty, playing.contains(where: { $0.deviceUIDs.contains(current) }) {
            return current
        }
        if let best = rank(playing).first { return best }
        return defaultOutput.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Candidate device UIDs in the rule (b) order.
    public static func rank(_ playing: [ProcessPlayback]) -> [String] {
        var count: [String: Int] = [:]
        var firstName: [String: String] = [:]
        for process in playing {
            for uid in Set(process.deviceUIDs) where !uid.isEmpty {
                count[uid, default: 0] += 1
                if let name = firstName[uid], name.localizedCaseInsensitiveCompare(process.name) != .orderedDescending { continue }
                firstName[uid] = process.name
            }
        }
        return count.keys.sorted { a, b in
            if count[a]! != count[b]! { return count[a]! > count[b]! }
            let byName = firstName[a]!.localizedCaseInsensitiveCompare(firstName[b]!)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a < b
        }
    }
}
