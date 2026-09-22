import CoreAudio
import Foundation

// Read-only view of the default output device's software volume, with listeners.
// Joseon never SETS a volume or a mute: this file only reads and listens.
// Use: the "macOS controls the volume" SPL calibration follows the volume live.

/// The software volume of one output device, as the HAL reports it.
public struct OutputVolumeState: Equatable, Sendable {
    public var deviceID: UInt32
    public var deviceName: String
    public var deviceUID: String
    /// Current volume in dB. Nil when the device has no volume control that macOS can set
    /// (most external DACs with a fixed line output).
    public var volumeDB: Double?
    /// Top of the volume range in dB (often 0). Nil when unknown.
    public var maxVolumeDB: Double?
    /// Current volume as the 0...1 scalar of the macOS volume slider. Nil when the device has none.
    public var volumeScalar: Double?
    public var isMuted: Bool

    public init(deviceID: UInt32, deviceName: String, deviceUID: String, volumeDB: Double?, maxVolumeDB: Double?, volumeScalar: Double?, isMuted: Bool) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.deviceUID = deviceUID
        self.volumeDB = volumeDB; self.maxVolumeDB = maxVolumeDB; self.volumeScalar = volumeScalar; self.isMuted = isMuted
    }

    public var hasSoftwareVolume: Bool { volumeDB != nil }

    /// dB below the maximum volume, 0 or negative. Nil without a software volume.
    /// When the HAL gives no range, the top of the range counts as 0 dB.
    public var attenuationDB: Double? {
        guard let volumeDB else { return nil }
        return min(0, volumeDB - (maxVolumeDB ?? 0))
    }
}

public enum OutputVolume {
    /// State of the default output device now. Nil when there is no output device.
    public static func readDefaultDevice() -> OutputVolumeState? {
        HAL.defaultOutputDevice().map { read(device: $0) }
    }

    /// Elements that carry the volume: the main element when it has one, else the stereo channel pair.
    static func volumeElements(_ device: AudioObjectID) -> [AudioObjectPropertyElement] {
        if has(device, kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyElementMain)
            || has(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        var pair: [UInt32] = [1, 2]
        var addr = HAL.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput)
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        var stereo: [UInt32] = [1, 2]
        let status = stereo.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0.baseAddress!) }
        if status == noErr, stereo.allSatisfy({ $0 > 0 }) { pair = stereo }
        return pair.filter {
            has(device, kAudioDevicePropertyVolumeDecibels, $0) || has(device, kAudioDevicePropertyVolumeScalar, $0)
        }
    }

    static func has(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Bool {
        var addr = HAL.address(selector, scope: kAudioObjectPropertyScopeOutput, element: element)
        return AudioObjectHasProperty(device, &addr)
    }

    static func float32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Float32? {
        var addr = HAL.address(selector, scope: kAudioObjectPropertyScopeOutput, element: element)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// Scalar -> dB through the device's own curve, for a device that reports only a scalar.
    static func decibels(fromScalar scalar: Float32, _ device: AudioObjectID, _ element: AudioObjectPropertyElement) -> Float32? {
        var addr = HAL.address(kAudioDevicePropertyVolumeScalarToDecibels, scope: kAudioObjectPropertyScopeOutput, element: element)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value = scalar
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func rangeMaxDB(_ device: AudioObjectID, _ element: AudioObjectPropertyElement) -> Double? {
        var addr = HAL.address(kAudioDevicePropertyVolumeRangeDecibels, scope: kAudioObjectPropertyScopeOutput, element: element)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &range) == noErr ? range.mMaximum : nil
    }

    static func isMuted(_ device: AudioObjectID, elements: [AudioObjectPropertyElement]) -> Bool {
        // Main mute first, then "every volume channel is muted".
        func mute(_ element: AudioObjectPropertyElement) -> Bool? {
            var addr = HAL.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, element: element)
            guard AudioObjectHasProperty(device, &addr) else { return nil }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value != 0 : nil
        }
        if let main = mute(kAudioObjectPropertyElementMain) { return main }
        let channels = elements.compactMap(mute)
        return !channels.isEmpty && channels.allSatisfy { $0 }
    }

    static func read(device: AudioObjectID) -> OutputVolumeState {
        let elements = volumeElements(device)
        var levels: [Double] = [], tops: [Double] = [], scalars: [Double] = []
        for element in elements {
            let scalar = float32(device, kAudioDevicePropertyVolumeScalar, element)
            if let s = scalar { scalars.append(Double(s)) }
            if let db = float32(device, kAudioDevicePropertyVolumeDecibels, element)
                ?? scalar.flatMap({ decibels(fromScalar: $0, device, element) }) {
                levels.append(Double(db))
                if let top = rangeMaxDB(device, element) { tops.append(top) }
            }
        }
        // Two channel volumes (a balance offset): the louder channel counts, as the SPL estimate takes the louder ear.
        return OutputVolumeState(
            deviceID: device,
            deviceName: HAL.string(device, kAudioObjectPropertyName) ?? "Unknown device",
            deviceUID: HAL.string(device, kAudioDevicePropertyDeviceUID) ?? "",
            volumeDB: levels.max(), maxVolumeDB: tops.max(), volumeScalar: scalars.max(),
            isMuted: isMuted(device, elements: elements))
    }
}

/// Follows the default output device and its volume. Callbacks arrive on `queue`.
/// Listeners only: the monitor changes nothing in the audio system.
public final class OutputVolumeMonitor {
    public var onChange: ((OutputVolumeState?) -> Void)?
    public private(set) var state: OutputVolumeState?

    private let queue: DispatchQueue
    private var running = false
    private var device: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var deviceAddresses: [AudioObjectPropertyAddress] = []
    private lazy var systemBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.defaultDeviceChanged() }
    private lazy var deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }

    public init(queue: DispatchQueue = .main) { self.queue = queue }

    deinit { stop() }

    public func start() {
        guard !running else { return }
        running = true
        var addr = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(HAL.system, &addr, queue, systemBlock)
        attach()
        state = device == kAudioObjectUnknown ? nil : OutputVolume.read(device: device)
    }

    public func stop() {
        guard running else { return }
        running = false
        var addr = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(HAL.system, &addr, queue, systemBlock)
        detach()
    }

    private func attach() {
        device = HAL.defaultOutputDevice() ?? AudioObjectID(kAudioObjectUnknown)
        guard device != kAudioObjectUnknown else { return }
        let out = kAudioObjectPropertyScopeOutput
        var addresses = [HAL.address(kAudioDevicePropertyMute, scope: out)]
        for element in OutputVolume.volumeElements(device) {
            addresses.append(HAL.address(kAudioDevicePropertyVolumeDecibels, scope: out, element: element))
            addresses.append(HAL.address(kAudioDevicePropertyVolumeScalar, scope: out, element: element))
            if element != kAudioObjectPropertyElementMain { addresses.append(HAL.address(kAudioDevicePropertyMute, scope: out, element: element)) }
        }
        deviceAddresses = addresses.filter { var a = $0; return AudioObjectHasProperty(device, &a) }
        for var a in deviceAddresses { AudioObjectAddPropertyListenerBlock(device, &a, queue, deviceBlock) }
    }

    private func detach() {
        for var a in deviceAddresses { AudioObjectRemovePropertyListenerBlock(device, &a, queue, deviceBlock) }
        deviceAddresses = []
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func defaultDeviceChanged() {
        guard running else { return }
        detach()
        attach()
        refresh()
    }

    private func refresh() {
        guard running else { return }
        let new = device == kAudioObjectUnknown ? nil : OutputVolume.read(device: device)
        guard new != state else { return }
        state = new
        onChange?(new)
    }
}
