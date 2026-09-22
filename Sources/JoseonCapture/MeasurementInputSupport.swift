import Accelerate
import CoreAudio
import Foundation
#if canImport(Synchronization)
import Synchronization
#endif

// The pure, non-I/O half of the measurement microphone input: sample formats, channel planning,
// conversion to mono Float32, the level meter, the lock-free words the IO thread shares with the
// rest of the process, and the offline self-test of all of it (`joseon-probe measure-selftest`).
//
// Nothing in this file calls the HAL. Everything here can run, and does run, without a device,
// without a permission and without sound.

// MARK: - Words shared between the IO thread and everybody else

/// A small fixed array of 64-bit words. One thread stores (the IO thread, or the control thread
/// while the IO thread is stopped); any thread loads. Every word is published on its own, so a
/// reader never sees half a value and never needs a lock.
///
/// The publish order the users of this type rely on is the ordinary one: the writer stores plain
/// data first (samples, other words) and the *releasing* store of the word that announces them
/// last; a reader that *acquires* the announcing word therefore also sees what it announces.
/// This is the opposite direction from the `StereoRingBuffer` reader, which validates a plain copy
/// *after* making it and so needs `ringReaderCopyFence()`. No reader in this file validates after
/// a copy: the recorder never rewrites a published sample, and the meter words are self-contained.
internal protocol RTWords: AnyObject, Sendable {
    var count: Int { get }
    /// Writer. Real-time safe: a single store, no lock, no allocation.
    func store(_ index: Int, _ value: UInt64)
    /// Any thread.
    func load(_ index: Int) -> UInt64
}

#if canImport(Synchronization)
/// macOS 15 and later: real atomics. `store` is one releasing store, `load` one acquiring load.
@available(macOS 15, iOS 18, *)
internal final class AtomicRTWords: RTWords, @unchecked Sendable {
    let count: Int
    private let cells: UnsafeMutablePointer<Atomic<UInt64>>

    init(count: Int) {
        self.count = max(1, count)
        cells = .allocate(capacity: self.count)
        for i in 0..<self.count { (cells + i).initialize(to: Atomic<UInt64>(0)) }
    }

    deinit {
        cells.deinitialize(count: count)
        cells.deallocate()
    }

    func store(_ index: Int, _ value: UInt64) { cells[index].store(value, ordering: .releasing) }
    func load(_ index: Int) -> UInt64 { cells[index].load(ordering: .acquiring) }
}
#endif

/// macOS 14 floor, where `Synchronization.Atomic` does not exist: naturally aligned 64-bit words.
/// An aligned 64-bit store is indivisible on arm64 and x86-64, so a load yields the old or the new
/// value, never a mix. The full barriers give the ordering the atomic backend gets from its
/// releasing / acquiring orderings: the barrier before the store keeps the data the word announces
/// from sinking below it, and the barrier before the load keeps the reads that follow from
/// floating above it. Still no lock, no wait.
internal final class BarrierRTWords: RTWords, @unchecked Sendable {
    let count: Int
    private let cells: UnsafeMutablePointer<UInt64>

    init(count: Int) {
        self.count = max(1, count)
        cells = .allocate(capacity: self.count)
        cells.initialize(repeating: 0, count: self.count)
    }

    deinit { cells.deallocate() }

    func store(_ index: Int, _ value: UInt64) {
        OSMemoryBarrier()
        cells[index] = value
        OSMemoryBarrier()
    }

    func load(_ index: Int) -> UInt64 {
        OSMemoryBarrier()
        return cells[index]
    }
}

internal func makeRTWords(count: Int) -> RTWords {
    #if canImport(Synchronization)
    if #available(macOS 15, iOS 18, *) { return AtomicRTWords(count: count) }
    #endif
    return BarrierRTWords(count: count)
}

// MARK: - Sample formats

/// The sample layouts the IOProc can turn into Float32. Little-endian linear PCM only.
internal enum MeasurementSampleFormat: Equatable {
    case float32
    case int16
    /// 24-bit samples packed in 3 bytes.
    case int24Packed
    /// 32-bit samples, and 24-bit samples aligned high in a 32-bit word (same scale).
    case int32
    /// 24-bit samples aligned low in a 32-bit word.
    case int24In32Low

    var bytesPerSample: Int {
        switch self {
        case .int16: return 2
        case .int24Packed: return 3
        case .float32, .int32, .int24In32Low: return 4
        }
    }

    /// Reads the layout of one stream format. Throws a plain-words error for everything this
    /// module does not convert: compressed formats, big-endian, unsigned, Float64, odd widths.
    init(_ asbd: AudioStreamBasicDescription) throws {
        func unsupported(_ why: String) -> MeasurementInputError {
            .unsupportedFormat("\(why) (format '\(HAL.fourCC(asbd.mFormatID))', \(asbd.mBitsPerChannel) bit, flags 0x\(String(asbd.mFormatFlags, radix: 16)))")
        }
        guard asbd.mFormatID == kAudioFormatLinearPCM else { throw unsupported("not linear PCM") }
        guard asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { throw unsupported("big-endian samples") }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else { throw unsupported("no channels") }
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytes = Int(asbd.mBytesPerFrame) / (planar ? 1 : channels)
        let bits = Int(asbd.mBitsPerChannel)
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            guard bits == 32, bytes == 4 else { throw unsupported("only 32-bit float is supported") }
            self = .float32
            return
        }
        guard asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 else { throw unsupported("unsigned integer samples") }
        switch (bits, bytes) {
        case (16, 2): self = .int16
        case (24, 3): self = .int24Packed
        case (32, 4): self = .int32
        case (24, 4): self = asbd.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0 ? .int32 : .int24In32Low
        default: throw unsupported("only 16, 24 and 32-bit integers are supported")
        }
    }
}

// MARK: - Channel planning

/// Where one device channel lives in the IOProc's input `AudioBufferList`.
internal struct MeasurementChannelPlan: Equatable {
    var bufferIndex: Int
    var channelInBuffer: Int
    var format: MeasurementSampleFormat
}

internal enum MeasurementChannelPlanner {
    /// `streams`: the virtual format of every input stream, in device order. `channel` is 0-based
    /// over the whole device. An interleaved stream is one buffer with all its channels; a
    /// non-interleaved stream is one mono buffer per channel.
    static func plan(streams: [AudioStreamBasicDescription], channel: Int) throws -> MeasurementChannelPlan {
        let total = streams.reduce(0) { $0 + Int($1.mChannelsPerFrame) }
        guard !streams.isEmpty, total > 0 else { throw MeasurementInputError.notAnInputDevice }
        guard channel >= 0, channel < total else {
            throw MeasurementInputError.channelOutOfRange(requested: channel, available: total)
        }
        var bufferIndex = 0
        var firstChannel = 0
        for stream in streams {
            let channels = Int(stream.mChannelsPerFrame)
            let planar = stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            if channel < firstChannel + channels {
                let format = try MeasurementSampleFormat(stream)
                let local = channel - firstChannel
                return planar
                    ? MeasurementChannelPlan(bufferIndex: bufferIndex + local, channelInBuffer: 0, format: format)
                    : MeasurementChannelPlan(bufferIndex: bufferIndex, channelInBuffer: local, format: format)
            }
            firstChannel += channels
            bufferIndex += planar ? channels : 1
        }
        throw MeasurementInputError.channelOutOfRange(requested: channel, available: total)
    }
}

// MARK: - Conversion to mono Float32

internal enum MeasurementConvert {
    /// Copies `frameCount` frames of one channel out of a buffer into `dst` as Float32 in −1…+1.
    /// Real-time safe: plain loads and stores. Integer full scale maps to 1.0 (divide by 2^(bits−1)).
    @inline(__always)
    static func extractMono(from source: UnsafeRawPointer, format: MeasurementSampleFormat,
                            channelsInBuffer: Int, channel: Int, firstFrame: Int, frameCount: Int,
                            into dst: UnsafeMutablePointer<Float>) {
        let size = format.bytesPerSample
        let step = channelsInBuffer * size
        var p = source + (firstFrame * channelsInBuffer + channel) * size
        var i = 0
        switch format {
        case .float32:
            if channelsInBuffer == 1 {
                memcpy(dst, p, frameCount * size)
            } else {
                while i < frameCount { dst[i] = p.loadUnaligned(as: Float.self); p += step; i += 1 }
            }
        case .int16:
            while i < frameCount { dst[i] = Float(p.loadUnaligned(as: Int16.self)) * (1.0 / 32_768.0); p += step; i += 1 }
        case .int24Packed:
            while i < frameCount {
                let b0 = UInt32(p.load(as: UInt8.self))
                let b1 = UInt32(p.load(fromByteOffset: 1, as: UInt8.self))
                let b2 = UInt32(p.load(fromByteOffset: 2, as: UInt8.self))
                let v = Int32(bitPattern: b0 << 8 | b1 << 16 | b2 << 24) >> 8   // sign-extend
                dst[i] = Float(v) * (1.0 / 8_388_608.0)
                p += step; i += 1
            }
        case .int32:
            while i < frameCount { dst[i] = Float(p.loadUnaligned(as: Int32.self)) * (1.0 / 2_147_483_648.0); p += step; i += 1 }
        case .int24In32Low:
            while i < frameCount {
                let v = (p.loadUnaligned(as: Int32.self) << 8) >> 8             // sign-extend the low 24 bits
                dst[i] = Float(v) * (1.0 / 8_388_608.0)
                p += step; i += 1
            }
        }
    }
}

// MARK: - Level meter

internal enum MeasurementMeterMath {
    /// The input counts as clipped at |x| ≥ 0.999 (spec `mic-input.md`).
    static let clipThreshold: Float = 0.999

    /// dB re full scale. Digital silence is −infinity: the meter does not invent a floor.
    static func decibels(_ linear: Float) -> Double {
        linear > 0 ? 20 * log10(Double(linear)) : -.infinity
    }

    /// One meter slot in one word: peak in the high half, mean square in the low half.
    static func pack(peak: Float, meanSquare: Float) -> UInt64 {
        UInt64(peak.bitPattern) << 32 | UInt64(meanSquare.bitPattern)
    }

    static func unpack(_ word: UInt64) -> (peak: Float, meanSquare: Float) {
        (Float(bitPattern: UInt32(word >> 32)), Float(bitPattern: UInt32(word & 0xFFFF_FFFF)))
    }

    /// Slots of equal length → the window's peak is the largest peak, its RMS the root of the mean of the means.
    static func combine(_ slots: [(peak: Float, meanSquare: Float)]) -> (peak: Float, rms: Float) {
        guard !slots.isEmpty else { return (0, 0) }
        var peak: Float = 0
        var sum: Double = 0
        for s in slots { peak = max(peak, s.peak); sum += Double(s.meanSquare) }
        return (peak, Float((sum / Double(slots.count)).squareRoot()))
    }
}

/// Peak and RMS of the last 100 ms, plus a sticky clip flag.
///
/// The IO thread cuts the signal into 10 slots of 10 ms. When a slot is full it publishes the slot
/// as ONE word (peak and mean square packed together), then the slot counter. A reader takes the
/// newest 10 slot words. A reader that races the writer can see a window that is one slot (10 ms)
/// newer at one end than at the other; for a level meter that is not an error, and no value it
/// reads is ever torn. The level therefore updates every 10 ms and is 0 until the first 10 ms ran.
internal final class MeasurementLevelMeter: @unchecked Sendable {
    static let slotCount = 10
    private static let publishedWord = slotCount
    private static let clippedWord = slotCount + 1

    let slotFrames: Int
    private let words: RTWords

    /// IO-thread-only state, out of line so the IO thread reaches it through a raw pointer.
    private struct Writer {
        var filled = 0
        var peak: Float = 0
        var sumSquares: Double = 0
        var published: UInt64 = 0
        var clipped = false
    }
    private let writer: UnsafeMutablePointer<Writer>

    init(sampleRate: Double, words: RTWords? = nil) {
        slotFrames = max(1, Int((sampleRate / 100).rounded()))
        self.words = words ?? makeRTWords(count: Self.slotCount + 2)
        writer = .allocate(capacity: 1)
        writer.initialize(to: Writer())
    }

    deinit {
        writer.deinitialize(count: 1)
        writer.deallocate()
    }

    /// IO thread. Real-time safe: vDSP over the block, one word store per finished slot.
    func process(_ samples: UnsafePointer<Float>, count: Int) {
        var done = 0
        while done < count {
            let n = min(count - done, slotFrames - writer.pointee.filled)
            var peak: Float = 0
            var squares: Float = 0
            vDSP_maxmgv(samples + done, 1, &peak, vDSP_Length(n))
            vDSP_svesq(samples + done, 1, &squares, vDSP_Length(n))
            if peak >= MeasurementMeterMath.clipThreshold, !writer.pointee.clipped {
                writer.pointee.clipped = true
                words.store(Self.clippedWord, 1)
            }
            if peak > writer.pointee.peak { writer.pointee.peak = peak }
            writer.pointee.sumSquares += Double(squares)
            writer.pointee.filled += n
            done += n
            if writer.pointee.filled == slotFrames {
                let mean = Float(writer.pointee.sumSquares / Double(slotFrames))
                let slot = Int(writer.pointee.published % UInt64(Self.slotCount))
                words.store(slot, MeasurementMeterMath.pack(peak: writer.pointee.peak, meanSquare: mean))
                writer.pointee.published &+= 1
                words.store(Self.publishedWord, writer.pointee.published)
                writer.pointee.filled = 0
                writer.pointee.peak = 0
                writer.pointee.sumSquares = 0
            }
        }
    }

    /// Any thread. Linear peak and RMS of the newest (up to) 10 finished slots.
    func read() -> (peak: Float, rms: Float) {
        let published = words.load(Self.publishedWord)
        let n = Int(min(published, UInt64(Self.slotCount)))
        var slots: [(peak: Float, meanSquare: Float)] = []
        slots.reserveCapacity(n)
        var k: UInt64 = 0
        while k < UInt64(n) {
            slots.append(MeasurementMeterMath.unpack(words.load(Int((published - 1 - k) % UInt64(Self.slotCount)))))
            k += 1
        }
        return MeasurementMeterMath.combine(slots)
    }

    /// Any thread. True when any sample reached |x| ≥ 0.999 since the last `reset`.
    var clipped: Bool { words.load(Self.clippedWord) != 0 }

    /// Only while the IO thread does not run.
    func reset() {
        writer.pointee = Writer()
        for i in 0..<(Self.slotCount + 2) { words.store(i, 0) }
    }
}

// MARK: - The IOProc body, without the HAL

/// Everything the IOProc does with one input buffer list: pick the buffer, convert the chosen
/// channel to mono Float32, feed the meter, call the handler. It is a separate type so the offline
/// self-test runs the same code the IO thread runs, on a synthetic `AudioBufferList`.
///
/// Real-time rules: all memory exists before the first call; no allocation, no lock, no logging.
internal final class MeasurementIOCore: @unchecked Sendable {
    typealias Handler = (UnsafePointer<Float>, Int, Double, UInt64) -> Void

    static let cyclesWord = 0, framesWord = 1, mismatchWord = 2

    let plan: MeasurementChannelPlan
    let sampleRate: Double
    let scratchFrames: Int
    let meter: MeasurementLevelMeter
    private let hostTicksPerFrame: Double
    private let scratch: UnsafeMutablePointer<Float>
    private let words: RTWords
    private let handler: Handler

    private struct Writer { var cycles: UInt64 = 0; var frames: UInt64 = 0; var mismatches: UInt64 = 0 }
    private let writer: UnsafeMutablePointer<Writer>

    init(plan: MeasurementChannelPlan, sampleRate: Double, scratchFrames: Int, hostTicksPerFrame: Double,
         meter: MeasurementLevelMeter, handler: @escaping Handler) {
        self.plan = plan
        self.sampleRate = sampleRate
        self.scratchFrames = max(1, scratchFrames)
        self.hostTicksPerFrame = hostTicksPerFrame
        self.meter = meter
        self.handler = handler
        words = makeRTWords(count: 3)
        scratch = .allocate(capacity: self.scratchFrames)
        scratch.initialize(repeating: 0, count: self.scratchFrames)   // also touches the pages
        writer = .allocate(capacity: 1)
        writer.initialize(to: Writer())
    }

    deinit {
        scratch.deallocate()
        writer.deinitialize(count: 1)
        writer.deallocate()
    }

    var cycleCount: Int { Int(words.load(Self.cyclesWord)) }
    var framesDelivered: Int { Int(words.load(Self.framesWord)) }
    /// IO cycles whose buffer list did not match the plan (nothing was delivered for them).
    var formatMismatchCount: Int { Int(words.load(Self.mismatchWord)) }

    /// Host ticks (mach_absolute_time units) per frame at `sampleRate`.
    static func hostTicksPerFrame(sampleRate: Double) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard sampleRate > 0, info.numer > 0 else { return 0 }
        return 1e9 / sampleRate * Double(info.denom) / Double(info.numer)
    }

    /// IO thread. A block longer than the scratch buffer reaches the handler in several calls;
    /// the host time of each call is moved forward by the frames already delivered.
    func process(input: UnsafePointer<AudioBufferList>, hostTime: UInt64) {
        writer.pointee.cycles &+= 1
        words.store(Self.cyclesWord, writer.pointee.cycles)

        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard plan.bufferIndex < list.count else { return mismatch() }
        let buffer = list[plan.bufferIndex]
        let channels = Int(buffer.mNumberChannels)
        guard channels > plan.channelInBuffer, let data = buffer.mData else { return mismatch() }
        let frames = Int(buffer.mDataByteSize) / (plan.format.bytesPerSample * channels)
        guard frames > 0 else { return }

        var done = 0
        while done < frames {
            let n = min(scratchFrames, frames - done)
            MeasurementConvert.extractMono(from: UnsafeRawPointer(data), format: plan.format,
                                           channelsInBuffer: channels, channel: plan.channelInBuffer,
                                           firstFrame: done, frameCount: n, into: scratch)
            meter.process(scratch, count: n)
            handler(scratch, n, sampleRate, hostTime &+ UInt64(Double(done) * hostTicksPerFrame))
            done += n
        }
        writer.pointee.frames &+= UInt64(frames)
        words.store(Self.framesWord, writer.pointee.frames)
    }

    private func mismatch() {
        writer.pointee.mismatches &+= 1
        words.store(Self.mismatchWord, writer.pointee.mismatches)
    }
}

// MARK: - Device facts, pure parts

internal enum MeasurementDeviceFacts {
    /// UID prefix of the private aggregate device `SystemAudioTap` builds. It has an input stream
    /// (the tap) and is visible inside the Joseon process, so the device list must drop it.
    static let joseonTapAggregateUIDPrefix = "app.joseon.Joseon.capture."

    static func isJoseonTapAggregate(uid: String) -> Bool { uid.hasPrefix(joseonTapAggregateUIDPrefix) }

    static let commonSampleRates: [Double] = [8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000,
                                              88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    /// The HAL reports rates as ranges. A range of one value is that rate; a real range is shown
    /// as the common rates inside it (plus its ends). Sorted, no duplicates.
    static func discreteRates(_ ranges: [(min: Double, max: Double)]) -> [Double] {
        var rates = Set<Double>()
        for r in ranges where r.min > 0 && r.max >= r.min {
            if r.min == r.max { rates.insert(r.min); continue }
            rates.insert(r.min); rates.insert(r.max)
            for c in commonSampleRates where c > r.min && c < r.max { rates.insert(c) }
        }
        return rates.sorted()
    }

    /// The rate to SET on the device before the session starts, or nil to leave the device alone:
    /// no preference, already there, or a rate the device does not offer.
    static func rateToSet(preferred: Double?, nominal: Double, ranges: [(min: Double, max: Double)]) -> Double? {
        guard let preferred, preferred > 0, abs(preferred - nominal) > 0.5 else { return nil }
        return ranges.contains { preferred >= $0.min - 0.5 && preferred <= $0.max + 0.5 } ? preferred : nil
    }
}

// MARK: - Offline self-test (`joseon-probe measure-selftest`)

public struct MeasurementSelfTestResult: Sendable {
    public var name: String
    public var passed: Bool
    public var detail: String
}

/// Offline checks of the non-I/O logic. No test target covers JoseonCapture, so the probe runs these.
/// It opens no device, asks for no permission and makes no sound: every input is a synthetic buffer.
public enum MeasurementInputSelfTest {
    public static func run() -> [MeasurementSelfTestResult] {
        var t = Checker()
        formats(&t)
        planning(&t)
        conversion(&t)
        ioCore(&t)
        recorder(&t)
        meter(&t)
        clipping(&t)
        words(&t)
        deviceFacts(&t)
        return t.results
    }

    struct Checker {
        var results: [MeasurementSelfTestResult] = []
        mutating func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
            results.append(MeasurementSelfTestResult(name: name, passed: passed, detail: detail()))
        }
        mutating func throwsError<T>(_ name: String, _ body: () throws -> T, matches: (MeasurementInputError) -> Bool) {
            do { let v = try body(); check(name, false, "no error, got \(v)") } catch let e as MeasurementInputError {
                check(name, matches(e), "\(e)")
            } catch { check(name, false, "wrong error type: \(error)") }
        }
    }

    // MARK: fixtures

    static func asbd(bits: Int, bytesPerSample: Int, channels: Int, float: Bool = false, planar: Bool = false,
                     extraFlags: AudioFormatFlags = 0, signed: Bool = true, formatID: AudioFormatID = kAudioFormatLinearPCM,
                     rate: Double = 48_000) -> AudioStreamBasicDescription {
        var flags: AudioFormatFlags = extraFlags
        if float { flags |= kAudioFormatFlagIsFloat } else if signed { flags |= kAudioFormatFlagIsSignedInteger }
        if planar { flags |= kAudioFormatFlagIsNonInterleaved }
        if bits == bytesPerSample * 8 { flags |= kAudioFormatFlagIsPacked }
        return AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: formatID, mFormatFlags: flags,
            mBytesPerPacket: UInt32(bytesPerSample * (planar ? 1 : channels)), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerSample * (planar ? 1 : channels)),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: UInt32(bits), mReserved: 0)
    }

    static let float32Stereo = asbd(bits: 32, bytesPerSample: 4, channels: 2, float: true)

    /// Runs `body` with an `AudioBufferList` whose buffers hold the given bytes.
    static func withBufferList(_ buffers: [(channels: Int, bytes: [UInt8])], _ body: (UnsafePointer<AudioBufferList>) -> Void) {
        let list = AudioBufferList.allocate(maximumBuffers: max(1, buffers.count))
        var storage: [UnsafeMutableRawPointer] = []
        for (i, b) in buffers.enumerated() {
            let mem = UnsafeMutableRawPointer.allocate(byteCount: max(1, b.bytes.count), alignment: 16)
            b.bytes.withUnsafeBytes { if let base = $0.baseAddress { mem.copyMemory(from: base, byteCount: b.bytes.count) } }
            storage.append(mem)
            list[i] = AudioBuffer(mNumberChannels: UInt32(b.channels), mDataByteSize: UInt32(b.bytes.count), mData: mem)
        }
        list.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(buffers.count)
        body(UnsafePointer(list.unsafeMutablePointer))
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }

    static func bytes<T>(_ values: [T]) -> [UInt8] { values.withUnsafeBytes { Array($0) } }

    static func int24Bytes(_ values: [Int32]) -> [UInt8] {
        values.flatMap { v -> [UInt8] in
            let u = UInt32(bitPattern: v)
            return [UInt8(u & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u >> 16 & 0xFF)]
        }
    }

    static func extract(_ raw: [UInt8], _ format: MeasurementSampleFormat, channels: Int, channel: Int,
                        firstFrame: Int = 0, frames: Int) -> [Float] {
        var out = [Float](repeating: .nan, count: frames)
        raw.withUnsafeBytes { src in
            out.withUnsafeMutableBufferPointer { dst in
                MeasurementConvert.extractMono(from: src.baseAddress!, format: format, channelsInBuffer: channels,
                                               channel: channel, firstFrame: firstFrame, frameCount: frames, into: dst.baseAddress!)
            }
        }
        return out
    }

    static func close(_ a: [Float], _ b: [Float], tolerance: Float = 1e-7) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }

    static func sine(frequency: Double, amplitude: Float, rate: Double, frames: Int) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    static func feed(_ meter: MeasurementLevelMeter, _ signal: [Float], block: Int) {
        signal.withUnsafeBufferPointer { p in
            var done = 0
            while done < p.count {
                let n = min(block, p.count - done)
                meter.process(p.baseAddress! + done, count: n)
                done += n
            }
        }
    }

    // MARK: checks

    static func formats(_ t: inout Checker) {
        func format(_ a: AudioStreamBasicDescription) -> MeasurementSampleFormat? { try? MeasurementSampleFormat(a) }
        t.check("format: Float32 interleaved", format(float32Stereo) == .float32)
        t.check("format: Float32 non-interleaved", format(asbd(bits: 32, bytesPerSample: 4, channels: 2, float: true, planar: true)) == .float32)
        t.check("format: Int16", format(asbd(bits: 16, bytesPerSample: 2, channels: 2)) == .int16)
        t.check("format: Int24 packed", format(asbd(bits: 24, bytesPerSample: 3, channels: 2)) == .int24Packed)
        t.check("format: Int32", format(asbd(bits: 32, bytesPerSample: 4, channels: 1)) == .int32)
        t.check("format: Int24 in 32, aligned low", format(asbd(bits: 24, bytesPerSample: 4, channels: 2)) == .int24In32Low)
        t.check("format: Int24 in 32, aligned high = Int32 scale",
                format(asbd(bits: 24, bytesPerSample: 4, channels: 2, extraFlags: kAudioFormatFlagIsAlignedHigh)) == .int32)
        let isUnsupported: (MeasurementInputError) -> Bool = { if case .unsupportedFormat = $0 { return true } else { return false } }
        t.throwsError("format: Float64 is refused", { try MeasurementSampleFormat(asbd(bits: 64, bytesPerSample: 8, channels: 1, float: true)) }, matches: isUnsupported)
        t.throwsError("format: big-endian is refused", { try MeasurementSampleFormat(asbd(bits: 16, bytesPerSample: 2, channels: 2, extraFlags: kAudioFormatFlagIsBigEndian)) }, matches: isUnsupported)
        t.throwsError("format: unsigned 8-bit is refused", { try MeasurementSampleFormat(asbd(bits: 8, bytesPerSample: 1, channels: 1, signed: false)) }, matches: isUnsupported)
        t.throwsError("format: signed 8-bit is refused", { try MeasurementSampleFormat(asbd(bits: 8, bytesPerSample: 1, channels: 1)) }, matches: isUnsupported)
        t.throwsError("format: compressed (non-LPCM) is refused", { try MeasurementSampleFormat(asbd(bits: 0, bytesPerSample: 0, channels: 2, formatID: kAudioFormatMPEG4AAC)) }, matches: isUnsupported)
    }

    static func planning(_ t: inout Checker) {
        func plan(_ s: [AudioStreamBasicDescription], _ c: Int) -> MeasurementChannelPlan? { try? MeasurementChannelPlanner.plan(streams: s, channel: c) }
        t.check("plan: interleaved stereo, channel 1",
                plan([float32Stereo], 1) == MeasurementChannelPlan(bufferIndex: 0, channelInBuffer: 1, format: .float32))
        let planar3 = asbd(bits: 32, bytesPerSample: 4, channels: 3, float: true, planar: true)
        t.check("plan: non-interleaved, channel 2 is buffer 2",
                plan([planar3], 2) == MeasurementChannelPlan(bufferIndex: 2, channelInBuffer: 0, format: .float32))
        let int24Stereo = asbd(bits: 24, bytesPerSample: 3, channels: 2)
        t.check("plan: two streams (2 + 2), channel 3 is buffer 1 channel 1, with that stream's format",
                plan([float32Stereo, int24Stereo], 3) == MeasurementChannelPlan(bufferIndex: 1, channelInBuffer: 1, format: .int24Packed))
        t.check("plan: non-interleaved stream then interleaved stream",
                plan([planar3, float32Stereo], 4) == MeasurementChannelPlan(bufferIndex: 3, channelInBuffer: 1, format: .float32))
        t.throwsError("plan: channel past the end is refused", { try MeasurementChannelPlanner.plan(streams: [float32Stereo], channel: 2) }) {
            if case .channelOutOfRange(let requested, let available) = $0 { return requested == 2 && available == 2 } else { return false }
        }
        t.throwsError("plan: negative channel is refused", { try MeasurementChannelPlanner.plan(streams: [float32Stereo], channel: -1) }) {
            if case .channelOutOfRange = $0 { return true } else { return false }
        }
        t.throwsError("plan: no input streams is refused", { try MeasurementChannelPlanner.plan(streams: [], channel: 0) }) {
            if case .notAnInputDevice = $0 { return true } else { return false }
        }
        t.throwsError("plan: an unsupported format on the chosen stream is refused",
                      { try MeasurementChannelPlanner.plan(streams: [asbd(bits: 64, bytesPerSample: 8, channels: 2, float: true)], channel: 0) }) {
            if case .unsupportedFormat = $0 { return true } else { return false }
        }
    }

    static func conversion(_ t: inout Checker) {
        let interleaved: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4]
        t.check("convert: Float32 interleaved, channel 0", extract(bytes(interleaved), .float32, channels: 2, channel: 0, frames: 4) == [0.1, 0.2, 0.3, 0.4])
        t.check("convert: Float32 interleaved, channel 1", extract(bytes(interleaved), .float32, channels: 2, channel: 1, frames: 4) == [-0.1, -0.2, -0.3, -0.4])
        t.check("convert: Float32 mono buffer (non-interleaved path)", extract(bytes([0.5, -0.5, 0.25] as [Float]), .float32, channels: 1, channel: 0, frames: 3) == [0.5, -0.5, 0.25])
        t.check("convert: first-frame offset (chunked delivery)", extract(bytes(interleaved), .float32, channels: 2, channel: 1, firstFrame: 2, frames: 2) == [-0.3, -0.4])

        let i16: [Int16] = [0, 100, 16_384, -100, 32_767, -32_768, -16_384, 1]
        t.check("convert: Int16 interleaved, channel 0", close(extract(bytes(i16), .int16, channels: 2, channel: 0, frames: 4), [0, 0.5, 32_767.0 / 32_768.0, -0.5]))
        t.check("convert: Int16 interleaved, channel 1 (negative full scale = -1)", close(extract(bytes(i16), .int16, channels: 2, channel: 1, frames: 4), [100.0 / 32_768.0, -100.0 / 32_768.0, -1, 1.0 / 32_768.0]))

        let i24: [Int32] = [4_194_304, -4_194_304, 8_388_607, -8_388_608, -1, 0]
        t.check("convert: Int24 packed, channel 0", close(extract(int24Bytes(i24), .int24Packed, channels: 2, channel: 0, frames: 3), [0.5, 8_388_607.0 / 8_388_608.0, -1.0 / 8_388_608.0]))
        t.check("convert: Int24 packed, channel 1 (sign extension)", close(extract(int24Bytes(i24), .int24Packed, channels: 2, channel: 1, frames: 3), [-0.5, -1, 0]))

        let i32: [Int32] = [1_073_741_824, -1_073_741_824, Int32.max, Int32.min]
        t.check("convert: Int32, channel 0", close(extract(bytes(i32), .int32, channels: 2, channel: 0, frames: 2), [0.5, 1]))
        t.check("convert: Int32, channel 1", close(extract(bytes(i32), .int32, channels: 2, channel: 1, frames: 2), [-0.5, -1]))

        // 24 valid bits in the low bytes; the top byte is garbage the converter must ignore.
        let low: [Int32] = [4_194_304, Int32(bitPattern: 0x7FC0_0000), Int32(bitPattern: 0x00FF_FFFF), Int32(bitPattern: 0x5580_0000)]
        t.check("convert: Int24 in 32 aligned low ignores the top byte", close(extract(bytes(low), .int24In32Low, channels: 1, channel: 0, frames: 4), [0.5, -0.5, -1.0 / 8_388_608.0, -1]))
    }

    static func ioCore(_ t: inout Checker) {
        // Interleaved stereo Float32, 1000 frames, scratch of 256 → 4 handler calls, channel 1 delivered intact.
        let frames = 1000
        var stereo = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { stereo[2 * i] = 9; stereo[2 * i + 1] = Float(i) / 2000 }
        let recorder = MeasurementRecorder(capacityFrames: 4096)
        var calls: [(count: Int, rate: Double, host: UInt64)] = []
        let plan = try! MeasurementChannelPlanner.plan(streams: [float32Stereo], channel: 1)
        let core = MeasurementIOCore(plan: plan, sampleRate: 48_000, scratchFrames: 256, hostTicksPerFrame: 10,
                                     meter: MeasurementLevelMeter(sampleRate: 48_000)) { samples, count, rate, host in
            calls.append((count, rate, host))
            recorder.append(samples, count: count, sampleRate: rate, hostTime: host)
        }
        withBufferList([(2, bytes(stereo))]) { core.process(input: $0, hostTime: 1_000_000) }
        t.check("io: a long block is delivered in scratch-sized pieces", calls.map(\.count) == [256, 256, 256, 232], "\(calls.map(\.count))")
        t.check("io: host time moves forward with the frames already delivered", calls.map(\.host) == [1_000_000, 1_002_560, 1_005_120, 1_007_680], "\(calls.map(\.host))")
        t.check("io: the handler gets the session sample rate", calls.allSatisfy { $0.rate == 48_000 })
        t.check("io: the chosen channel arrives intact", recorder.recording() == (0..<frames).map { Float($0) / 2000 })
        t.check("io: counters", core.cycleCount == 1 && core.framesDelivered == frames && core.formatMismatchCount == 0)
        t.check("io: first host time and rate reach the recorder", recorder.firstHostTime == 1_000_000 && recorder.sampleRate == 48_000)

        // Non-interleaved Int16: two mono buffers, channel 1 = second buffer.
        let planarInt16 = asbd(bits: 16, bytesPerSample: 2, channels: 2, planar: true)
        var got: [Float] = []
        let core2 = MeasurementIOCore(plan: try! MeasurementChannelPlanner.plan(streams: [planarInt16], channel: 1),
                                      sampleRate: 44_100, scratchFrames: 64, hostTicksPerFrame: 0,
                                      meter: MeasurementLevelMeter(sampleRate: 44_100)) { samples, count, _, _ in
            got.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        }
        withBufferList([(1, bytes([1, 2, 3] as [Int16])), (1, bytes([16_384, -16_384, 0] as [Int16]))]) { core2.process(input: $0, hostTime: 0) }
        t.check("io: non-interleaved Int16, second buffer", close(got, [0.5, -0.5, 0]), "\(got)")

        // A buffer list that does not match the plan delivers nothing and is counted.
        var mismatchCalls = 0
        let core3 = MeasurementIOCore(plan: MeasurementChannelPlan(bufferIndex: 2, channelInBuffer: 0, format: .float32),
                                      sampleRate: 48_000, scratchFrames: 64, hostTicksPerFrame: 0,
                                      meter: MeasurementLevelMeter(sampleRate: 48_000)) { _, _, _, _ in mismatchCalls += 1 }
        withBufferList([(1, bytes([0.5] as [Float]))]) { core3.process(input: $0, hostTime: 0) }
        let core4 = MeasurementIOCore(plan: MeasurementChannelPlan(bufferIndex: 0, channelInBuffer: 1, format: .float32),
                                      sampleRate: 48_000, scratchFrames: 64, hostTicksPerFrame: 0,
                                      meter: MeasurementLevelMeter(sampleRate: 48_000)) { _, _, _, _ in mismatchCalls += 1 }
        withBufferList([(1, bytes([0.5] as [Float]))]) { core4.process(input: $0, hostTime: 0) }
        t.check("io: missing buffer or missing channel → no delivery, mismatch counted",
                mismatchCalls == 0 && core3.formatMismatchCount == 1 && core4.formatMismatchCount == 1 && core3.framesDelivered == 0)

        // The meter sees exactly what the handler sees.
        let loud = sine(frequency: 1000, amplitude: 0.5, rate: 48_000, frames: 9600)
        let core5 = MeasurementIOCore(plan: MeasurementChannelPlan(bufferIndex: 0, channelInBuffer: 0, format: .float32),
                                      sampleRate: 48_000, scratchFrames: 512, hostTicksPerFrame: 0,
                                      meter: MeasurementLevelMeter(sampleRate: 48_000)) { _, _, _, _ in }
        withBufferList([(1, bytes(loud))]) { core5.process(input: $0, hostTime: 0) }
        let level = MeasurementMeterMath.decibels(core5.meter.read().peak)
        t.check("io: the meter is fed from the converted block", abs(level - -6.02) < 0.02, String(format: "peak %.3f dB", level))
    }

    static func recorder(_ t: inout Checker) {
        let r = MeasurementRecorder(capacityFrames: 10)
        t.check("recorder: capacity from seconds × rate", MeasurementRecorder(maxSeconds: 15, sampleRate: 48_000).capacity == 720_000)
        let a: [Float] = [1, 2, 3, 4, 5, 6]
        a.withUnsafeBufferPointer { r.append($0.baseAddress!, count: 6, sampleRate: 96_000, hostTime: 77) }
        t.check("recorder: holds what was appended", r.frameCount == 6 && !r.overflowed && r.droppedFrames == 0 && r.recording() == a)
        let b: [Float] = [7, 8, 9, 10, 11, 12, 13]
        b.withUnsafeBufferPointer { r.append($0.baseAddress!, count: 7, sampleRate: 96_000, hostTime: 99) }
        t.check("recorder: overflow keeps the first `capacity` frames and reports the rest",
                r.frameCount == 10 && r.overflowed && r.droppedFrames == 3 && r.recording() == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
                "frames \(r.frameCount), dropped \(r.droppedFrames)")
        b.withUnsafeBufferPointer { r.append($0.baseAddress!, count: 7, sampleRate: 96_000, hostTime: 120) }
        t.check("recorder: a full recorder drops whole blocks", r.frameCount == 10 && r.droppedFrames == 10)
        t.check("recorder: first host time and rate are those of the first block", r.firstHostTime == 77 && r.sampleRate == 96_000)
        t.check("recorder: seconds recorded", abs(r.secondsRecorded - 10.0 / 96_000) < 1e-12)
        r.reset()
        t.check("recorder: reset empties it", r.frameCount == 0 && !r.overflowed && r.recording().isEmpty && r.firstHostTime == 0)
        a.withUnsafeBufferPointer { r.append($0.baseAddress!, count: 0, sampleRate: 48_000, hostTime: 5) }
        t.check("recorder: an empty block changes nothing", r.frameCount == 0 && r.firstHostTime == 0)
    }

    static func meter(_ t: inout Checker) {
        let rate = 48_000.0
        t.check("meter math: 1.0 → 0 dB, 0.5 → −6.02 dB, 0 → −infinity",
                MeasurementMeterMath.decibels(1) == 0 && abs(MeasurementMeterMath.decibels(0.5) + 6.0206) < 1e-3 && MeasurementMeterMath.decibels(0) == -.infinity)
        let packed = MeasurementMeterMath.unpack(MeasurementMeterMath.pack(peak: 0.75, meanSquare: 0.125))
        t.check("meter math: slot word round trip", packed.peak == 0.75 && packed.meanSquare == 0.125)
        let combined = MeasurementMeterMath.combine([(0.2, 0.01), (0.9, 0.03)])
        t.check("meter math: window = max of peaks, root of mean of mean squares", combined.peak == 0.9 && abs(combined.rms - Float(0.02).squareRoot()) < 1e-6)

        let m = MeasurementLevelMeter(sampleRate: rate)
        t.check("meter: 10 ms slots", m.slotFrames == 480 && MeasurementLevelMeter(sampleRate: 44_100).slotFrames == 441)
        t.check("meter: silent before the first slot", m.read().peak == 0 && m.read().rms == 0)
        feed(m, sine(frequency: 1000, amplitude: 1, rate: rate, frames: 24_000), block: 512)
        var v = m.read()
        t.check("meter: full-scale 1 kHz sine → peak 0 dBFS, RMS −3.01 dBFS",
                abs(MeasurementMeterMath.decibels(v.peak)) < 0.01 && abs(MeasurementMeterMath.decibels(v.rms) + 3.0103) < 0.01,
                String(format: "peak %.4f dB, rms %.4f dB", MeasurementMeterMath.decibels(v.peak), MeasurementMeterMath.decibels(v.rms)))
        feed(m, sine(frequency: 1000, amplitude: 0.01, rate: rate, frames: 4800), block: 512)
        v = m.read()
        t.check("meter: window is the last 100 ms (loud signal 100 ms ago is gone)",
                abs(MeasurementMeterMath.decibels(v.peak) + 40) < 0.01 && abs(MeasurementMeterMath.decibels(v.rms) + 43.0103) < 0.01,
                String(format: "peak %.4f dB, rms %.4f dB", MeasurementMeterMath.decibels(v.peak), MeasurementMeterMath.decibels(v.rms)))
        feed(m, sine(frequency: 1000, amplitude: 1, rate: rate, frames: 480), block: 512)
        t.check("meter: one loud slot inside the window sets the peak", abs(MeasurementMeterMath.decibels(m.read().peak)) < 0.01)

        let signal = sine(frequency: 997, amplitude: 0.3, rate: rate, frames: 9600)
        let m1 = MeasurementLevelMeter(sampleRate: rate), m2 = MeasurementLevelMeter(sampleRate: rate)
        feed(m1, signal, block: 37); feed(m2, signal, block: 4096)
        t.check("meter: the result does not depend on the block size", m1.read() == m2.read(), "\(m1.read()) vs \(m2.read())")

        let dc = MeasurementLevelMeter(sampleRate: rate)
        feed(dc, [Float](repeating: -0.25, count: 4800), block: 480)
        t.check("meter: DC −0.25 → peak = RMS = −12.04 dBFS",
                abs(MeasurementMeterMath.decibels(dc.read().peak) + 12.0412) < 1e-3 && abs(MeasurementMeterMath.decibels(dc.read().rms) + 12.0412) < 1e-3)
        dc.reset()
        t.check("meter: reset", dc.read().peak == 0 && !dc.clipped)
    }

    static func clipping(_ t: inout Checker) {
        let m = MeasurementLevelMeter(sampleRate: 48_000)
        feed(m, [0, 0.5, -0.998, 0.9989], block: 4)
        t.check("clip: |x| < 0.999 is not a clip", !m.clipped)
        feed(m, [0.1, -0.999, 0.1], block: 3)
        t.check("clip: |x| = 0.999 is a clip (negative side too)", m.clipped)
        feed(m, [Float](repeating: 0, count: 48_000), block: 512)
        t.check("clip: the flag is sticky", m.clipped)
        m.reset()
        t.check("clip: reset clears the flag", !m.clipped)

        let full = MeasurementLevelMeter(sampleRate: 48_000)
        feed(full, extract(bytes([0, 32_767] as [Int16]), .int16, channels: 1, channel: 0, frames: 2), block: 2)
        t.check("clip: Int16 positive full scale (0.99997) counts as clipped", full.clipped)
        let quiet = MeasurementLevelMeter(sampleRate: 48_000)
        feed(quiet, extract(bytes([0, 32_700, -32_700] as [Int16]), .int16, channels: 1, channel: 0, frames: 3), block: 3)
        t.check("clip: Int16 ±32700 (0.9979) does not", !quiet.clipped)
    }

    static func words(_ t: inout Checker) {
        var backends: [(String, RTWords)] = [("barrier words (macOS 14 fallback)", BarrierRTWords(count: 12))]
        #if canImport(Synchronization)
        if #available(macOS 15, iOS 18, *) { backends.append(("atomic words", AtomicRTWords(count: 12))) }
        #endif
        for (name, w) in backends {
            w.store(3, 0xDEAD_BEEF_0000_0001); w.store(11, 7)
            t.check("words: \(name) store / load", w.load(3) == 0xDEAD_BEEF_0000_0001 && w.load(11) == 7 && w.load(0) == 0)
            let m = MeasurementLevelMeter(sampleRate: 48_000, words: w)
            m.reset()
            feed(m, sine(frequency: 1000, amplitude: 1, rate: 48_000, frames: 9600), block: 256)
            t.check("words: meter on \(name)", abs(MeasurementMeterMath.decibels(m.read().rms) + 3.0103) < 0.01 && m.clipped)
        }

        // One writer thread, one reader thread: the reader must only ever see values the writer published.
        let shared = makeRTWords(count: 1)
        let total: UInt64 = 200_000
        let result = makeRTWords(count: 1)   // the reader reports its count of bad reads through a word, too
        let done = DispatchSemaphore(value: 0)
        Thread {
            var last: UInt64 = 0
            var bad: UInt64 = 0
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while last < total, ProcessInfo.processInfo.systemUptime < deadline {
                let v = shared.load(0)
                if v < last || v > total { bad += 1 }
                last = max(last, v)
            }
            result.store(0, bad + (last < total ? 1 << 32 : 0))
            done.signal()
        }.start()
        var i: UInt64 = 1
        while i <= total { shared.store(0, i); i += 1 }
        let finished = done.wait(timeout: .now() + 15) == .success
        t.check("words: a concurrent reader sees only published, never decreasing values",
                finished && result.load(0) == 0, "reader result word \(result.load(0))")
    }

    static func deviceFacts(_ t: inout Checker) {
        t.check("transport: USB", MeasurementInputTransport(transportType: kAudioDeviceTransportTypeUSB) == .usb)
        t.check("transport: built-in", MeasurementInputTransport(transportType: kAudioDeviceTransportTypeBuiltIn) == .builtIn)
        t.check("transport: aggregate", MeasurementInputTransport(transportType: kAudioDeviceTransportTypeAggregate) == .aggregate)
        t.check("transport: virtual", MeasurementInputTransport(transportType: kAudioDeviceTransportTypeVirtual) == .virtual)
        t.check("transport: Bluetooth and Bluetooth LE", MeasurementInputTransport(transportType: kAudioDeviceTransportTypeBluetooth) == .bluetooth
                && MeasurementInputTransport(transportType: kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
        t.check("transport: everything else is 'other'", MeasurementInputTransport(transportType: kAudioDeviceTransportTypeThunderbolt) == .other
                && MeasurementInputTransport(transportType: 0) == .other)
        t.check("devices: Joseon's tap aggregate is recognised", MeasurementDeviceFacts.isJoseonTapAggregate(uid: "app.joseon.Joseon.capture.1B2C")
                && !MeasurementDeviceFacts.isJoseonTapAggregate(uid: "BuiltInMicrophoneDevice"))
        t.check("rates: discrete list", MeasurementDeviceFacts.discreteRates([(44_100, 44_100), (48_000, 48_000), (96_000, 96_000), (48_000, 48_000)]) == [44_100, 48_000, 96_000])
        t.check("rates: a real range shows its ends and the common rates inside", MeasurementDeviceFacts.discreteRates([(40_000, 100_000)]) == [40_000, 44_100, 48_000, 88_200, 96_000, 100_000])
        let ranges: [(min: Double, max: Double)] = [(44_100, 44_100), (48_000, 48_000), (96_000, 96_000)]
        t.check("rates: no preference → leave the device alone", MeasurementDeviceFacts.rateToSet(preferred: nil, nominal: 48_000, ranges: ranges) == nil)
        t.check("rates: already at the preferred rate → leave it", MeasurementDeviceFacts.rateToSet(preferred: 48_000, nominal: 48_000, ranges: ranges) == nil)
        t.check("rates: an offered rate is set", MeasurementDeviceFacts.rateToSet(preferred: 96_000, nominal: 48_000, ranges: ranges) == 96_000)
        t.check("rates: a rate the device does not offer is not set", MeasurementDeviceFacts.rateToSet(preferred: 192_000, nominal: 48_000, ranges: ranges) == nil)
        t.check("host time: ticks per frame", abs(MeasurementIOCore.hostTicksPerFrame(sampleRate: 48_000) * 48_000 - MeasurementIOCore.hostTicksPerFrame(sampleRate: 1)) < 1e-3
                && MeasurementIOCore.hostTicksPerFrame(sampleRate: 0) == 0)
    }
}
