import Foundation
import os
#if canImport(Synchronization)
import Synchronization
#endif

// MARK: - Published index words

/// One consistent view of the writer's published state.
internal struct RingSnapshot {
    /// Total frames fully written and published.
    var writeIndex: Int
    /// Frame index where the current sample rate began.
    var epochStart: Int
    /// `Double.bitPattern` of the current sample rate.
    var rateBits: UInt64
}

/// The words the writer and the reader share. Every method touches index words only —
/// never audio samples — so no implementation ever holds a lock across a copy.
///
/// Word roles:
/// - `claimEnd`: published *before* the writer touches the sample storage. It marks the end of the
///   region the writer may be overwriting right now. The reader uses it to validate a finished copy.
/// - `writeIndex`: published *after* the copy. Frames below it are complete and safe to read.
/// - `epochStart` / `rateBits`: the current sample rate and the frame index where it started.
/// - `readIndex` / `readRateBits`: published by the reader after each successful read.
internal protocol RingSync: AnyObject, Sendable {
    /// Writer, before the sample copy: announce the end of the region about to be written.
    func claim(_ end: Int)
    /// Writer, after the sample copy: publish the new frame count and the rate epoch.
    func publish(writeIndex: Int, epochStart: Int, rateBits: UInt64)
    /// Reader, after its copy: the end of the writer's in-flight region. Call
    /// `ringReaderCopyFence()` first — the value only validates a copy once every load that copy
    /// issued has completed.
    func claimEndValue() -> Int
    /// Reader: total frames published.
    func writeIndexValue() -> Int
    /// Reader: a consistent (writeIndex, epochStart, rateBits) triple.
    func snapshot() -> RingSnapshot
    /// Reader: publish how far it has consumed and the rate of the frames it took.
    func commitRead(readIndex: Int, rateBits: UInt64)
    /// Any thread: frames consumed so far.
    func readIndexValue() -> Int
    /// Any thread: rate of the frames the last successful read returned (0 when there was none).
    func readRateBitsValue() -> UInt64
}

/// Lock-free implementation. Every writer operation is a single atomic store or exchange, so the
/// writer is wait-free: it never waits for the reader, and the reader never waits for the writer.
@available(macOS 15, iOS 18, *)
internal final class AtomicRingSync: RingSync {
    private let _writeIndex = Atomic<Int>(0)
    private let _claimEnd = Atomic<Int>(0)
    private let _epochStart = Atomic<Int>(0)
    private let _rateBits: Atomic<UInt64>
    private let _readIndex = Atomic<Int>(0)
    private let _readRateBits = Atomic<UInt64>(0)

    init(rateBits: UInt64) { _rateBits = Atomic<UInt64>(rateBits) }

    func claim(_ end: Int) {
        // An acquire+release read-modify-write, not a plain store: the release half keeps earlier
        // work from sinking below it, the acquire half keeps the sample stores that follow from
        // floating above it. On Apple silicon (LSE) this is one `swpal` instruction.
        _ = _claimEnd.exchange(end, ordering: .acquiringAndReleasing)
    }

    func publish(writeIndex: Int, epochStart: Int, rateBits: UInt64) {
        // The order of these two stores is part of `snapshot`'s proof: the epoch start goes first
        // and the rate is released, so a reader that sees a new rate also sees the new epoch start.
        _epochStart.store(epochStart, ordering: .relaxed)
        _rateBits.store(rateBits, ordering: .releasing)
        // Releasing: a reader that acquires this value also sees the samples and the epoch words.
        _writeIndex.store(writeIndex, ordering: .releasing)
    }

    func claimEndValue() -> Int { _claimEnd.load(ordering: .acquiring) }
    func writeIndexValue() -> Int { _writeIndex.load(ordering: .acquiring) }

    func snapshot() -> RingSnapshot {
        // Seqlock, using writeIndex itself as the sequence counter: it grows on every publish, so
        // reading the same value before and after the epoch words means no publish *completed*
        // between them.
        //
        // A publish that is only half done is still visible, so the epoch words are read in the
        // reverse of the order `publish` writes them: rate first, epoch start second. `publish`
        // releases the rate after storing the epoch start, so seeing a new rate here also makes the
        // new epoch start visible. That rules out the one skewed pair that would matter — an old
        // epoch start with a new rate, which would label old-epoch frames with the new rate. The
        // other skewed pair, a new epoch start with the old rate, is harmless: a new epoch starts
        // at the writer's `base`, which is exactly the writeIndex held here, so it yields no
        // readable frames and the next call sees the finished publish.
        var w1 = 0, es = 0, rb: UInt64 = 0
        for _ in 0..<64 {
            w1 = _writeIndex.load(ordering: .acquiring)
            rb = _rateBits.load(ordering: .acquiring)
            es = _epochStart.load(ordering: .acquiring)
            if _writeIndex.load(ordering: .acquiring) == w1 {
                return RingSnapshot(writeIndex: w1, epochStart: es, rateBits: rb)
            }
        }
        // Unreachable in practice. Report an empty epoch rather than a possibly mismatched one:
        // the caller then reads zero frames instead of labelling frames with the wrong rate.
        return RingSnapshot(writeIndex: w1, epochStart: w1, rateBits: rb)
    }

    func commitRead(readIndex: Int, rateBits: UInt64) {
        _readRateBits.store(rateBits, ordering: .relaxed)
        _readIndex.store(readIndex, ordering: .releasing)
    }

    func readIndexValue() -> Int { _readIndex.load(ordering: .acquiring) }
    func readRateBitsValue() -> UInt64 { _readRateBits.load(ordering: .acquiring) }
}

/// Fallback for macOS 14, where `Synchronization.Atomic` does not exist.
///
/// The words live under one `os_unfair_lock`, but no critical section does more than read or write
/// a handful of machine words — never a sample copy. The writer's wait is therefore bounded by a
/// few instructions plus `os_unfair_lock`'s priority donation, instead of by a 32768-frame memcpy.
internal final class LockedRingSync: RingSync, @unchecked Sendable {
    // Out of line so the lock has a stable address for its whole lifetime.
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var _writeIndex = 0
    private var _claimEnd = 0
    private var _epochStart = 0
    private var _rateBits: UInt64
    private var _readIndex = 0
    private var _readRateBits: UInt64 = 0

    init(rateBits: UInt64) {
        _rateBits = rateBits
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit { lock.deallocate() }

    func claim(_ end: Int) {
        os_unfair_lock_lock(lock); _claimEnd = end; os_unfair_lock_unlock(lock)
    }

    func publish(writeIndex: Int, epochStart: Int, rateBits: UInt64) {
        os_unfair_lock_lock(lock)
        _writeIndex = writeIndex; _epochStart = epochStart; _rateBits = rateBits
        os_unfair_lock_unlock(lock)
    }

    func claimEndValue() -> Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return _claimEnd
    }

    func writeIndexValue() -> Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return _writeIndex
    }

    func snapshot() -> RingSnapshot {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return RingSnapshot(writeIndex: _writeIndex, epochStart: _epochStart, rateBits: _rateBits)
    }

    func commitRead(readIndex: Int, rateBits: UInt64) {
        os_unfair_lock_lock(lock)
        _readIndex = readIndex; _readRateBits = rateBits
        os_unfair_lock_unlock(lock)
    }

    func readIndexValue() -> Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return _readIndex
    }

    func readRateBitsValue() -> UInt64 {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return _readRateBits
    }
}

// MARK: - Reader barrier

/// Orders every load the reader's sample copy performed *before* the `claimEnd` load that
/// validates that copy. Reader thread only; the writer never calls it.
///
/// Without it the validation is unsound, and this was the bug the concurrent stress test caught
/// about once in thirty runs. Publishing `claimEnd` is a message-passing handshake, and message
/// passing needs a barrier on *both* sides:
///
/// - Writer: `claim` is an acquiring+releasing exchange, so the samples it stores afterwards
///   cannot become visible before the claim. Ordered.
/// - Reader: copy the samples, then load `claimEnd`. An *acquiring* load orders the accesses that
///   come after it, not the ones before it — `ldar` is free to be satisfied while the copy's plain
///   loads are still in flight. The reader could therefore pair samples from write *k* with a
///   `claimEnd` value from before write *k*'s claim, conclude that nothing had lapped its region,
///   and return torn frames. Nothing in the algorithm above it catches that: the arithmetic is
///   exact, and it was being fed a stale input.
///
/// `dmb ishld` closes it — every load issued before it completes before any load issued after it.
@inline(__always)
internal func ringReaderCopyFence() {
    #if canImport(Synchronization)
    if #available(macOS 15, iOS 18, *) {
        atomicMemoryFence(ordering: .acquiring)     // dmb ishld
        return
    }
    #endif
    // macOS 14 floor, where `Synchronization` is unavailable: a full `dmb ish`. Stronger than
    // needed, and reader-side only, so the writer's cost is unchanged either way.
    OSMemoryBarrier()
}

// MARK: - StereoRingBuffer

/// Single-writer, single-reader stereo float ring buffer.
/// The capture IO thread writes; the analysis thread reads. No allocation after init.
///
/// ## Writer guarantee
///
/// - **macOS 15 and later: `write` is wait-free.** It performs one atomic exchange, the sample
///   copy, and three atomic stores. It never takes a lock and never waits for the reader, so the
///   real-time IO thread cannot be blocked by the lower-priority analysis thread.
/// - **macOS 14 (the deployment floor, no `Synchronization.Atomic`): `write` is bounded to a few
///   instructions under a lock.** It takes `os_unfair_lock` twice, each time to store two or three
///   index words — tens of nanoseconds, with priority donation. No copy ever runs under the lock,
///   so the old failure mode (the IO thread waiting on a 32768-frame memcpy) is gone at every
///   deployment target. It is not formally wait-free.
///
/// The reader copies samples entirely outside any lock. It validates afterwards that the writer did
/// not lap the region it copied; on overrun it resyncs to the newest `capacity` frames and copies
/// again, so the documented "overrun keeps the newest frames" behaviour is unchanged. The
/// validation runs behind `ringReaderCopyFence()`, which is what makes "afterwards" true of the
/// hardware and not just of the source — see that function and the proof in `read`.
///
/// The cost of never blocking the writer: while the writer laps the buffer, the reader can read
/// storage the writer is overwriting. Those samples are discarded, never returned — the writer
/// publishes the end of its in-flight region *before* it touches a sample, and the reader rejects
/// any copy that region reaches. A single `Float` is naturally aligned, so a slot yields either the
/// old or the new value, never half of each; the copy as a whole can mix old and new frames, which
/// is exactly what the validation catches. Returned frames are always one contiguous, untorn run.
///
/// ## Sample rate
///
/// `sampleRate` describes exactly the frames the last successful `read` returned; before the first
/// read it is the rate of the newest write. A rate change starts a new epoch: unread frames written
/// at the old rate are dropped rather than returned under the new label, so a single `read` never
/// mixes rates.
///
/// ## Threading
///
/// One writer thread and one reader thread, as the capture graph uses it. `availableFrames` and
/// `sampleRate` are safe to read from any thread; `read` is not — it belongs to the reader.
public final class StereoRingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let sync: RingSync

    /// Writer-thread only. No other thread touches these.
    private var writerWriteIndex = 0
    private var writerEpochStart = 0
    private var writerRateBits = (48_000 as Double).bitPattern

    /// Reader-thread only.
    private var readerReadIndex = 0

    /// How many times `read` retries a copy the writer lapped before giving up for this call.
    private static let maxReadAttempts = 8

    /// Test seams. The reader calls these at the two instants where a concurrent lap has to be
    /// caught: after the left channel of a copy segment, and after the whole copy but before the
    /// validation. Both are `nil` in production, so the cost is one null check per copy segment,
    /// on the reader thread. The writer path never touches them.
    internal var readerHookAfterLeftChannel: (() -> Void)?
    internal var readerHookAfterCopy: (() -> Void)?

    public init(capacity: Int = 1 << 17) {
        self.capacity = max(1, capacity)
        let rateBits = (48_000 as Double).bitPattern
        if #available(macOS 15, iOS 18, *) {
            sync = AtomicRingSync(rateBits: rateBits)
        } else {
            sync = LockedRingSync(rateBits: rateBits)
        }
        left = .allocate(capacity: self.capacity); left.initialize(repeating: 0, count: self.capacity)
        right = .allocate(capacity: self.capacity); right.initialize(repeating: 0, count: self.capacity)
    }

    /// Test seam: build the buffer on a chosen synchronisation backend so both paths can be covered
    /// on one OS version.
    internal init(capacity: Int, sync: RingSync) {
        self.capacity = max(1, capacity)
        self.sync = sync
        left = .allocate(capacity: self.capacity); left.initialize(repeating: 0, count: self.capacity)
        right = .allocate(capacity: self.capacity); right.initialize(repeating: 0, count: self.capacity)
    }

    /// Test seam: a buffer forced onto the `os_unfair_lock` fallback backend.
    internal static func lockedForTesting(capacity: Int) -> StereoRingBuffer {
        StereoRingBuffer(capacity: capacity, sync: LockedRingSync(rateBits: (48_000 as Double).bitPattern))
    }

    deinit { left.deallocate(); right.deallocate() }

    /// Sample rate of the frames the last successful `read` returned.
    /// Before the first read, the rate of the newest write.
    public var sampleRate: Double {
        let rb = sync.readRateBitsValue()
        if rb != 0 { return Double(bitPattern: rb) }
        return Double(bitPattern: sync.snapshot().rateBits)
    }

    /// Write `count` frames. Old unread frames are overwritten when the reader is slow.
    /// Real-time safe: no allocation, no ObjC, and no unbounded wait (see the type's doc comment).
    public func write(left l: UnsafePointer<Float>, right r: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard count > 0 else { return }
        let rateBits = sampleRate.bitPattern
        var src = 0
        var n = count
        if n > capacity { src = n - capacity; n = capacity }
        let base = writerWriteIndex
        let end = base + count

        // Tell the reader which frames may be overwritten before touching a single sample.
        sync.claim(end)

        var pos = (base + src) % capacity
        var remaining = n
        var offset = src
        while remaining > 0 {
            let chunk = min(remaining, capacity - pos)
            (left + pos).update(from: l + offset, count: chunk)
            (right + pos).update(from: r + offset, count: chunk)
            pos = (pos + chunk) % capacity
            offset += chunk
            remaining -= chunk
        }

        writerWriteIndex = end
        if rateBits != writerRateBits {
            writerRateBits = rateBits
            writerEpochStart = base
        }
        sync.publish(writeIndex: end, epochStart: writerEpochStart, rateBits: rateBits)
    }

    /// Frames ready to read. Safe from any thread.
    public var availableFrames: Int {
        let s = sync.snapshot()
        let start = readStart(snapshot: s, consumed: sync.readIndexValue())
        return max(0, s.writeIndex - start)
    }

    /// Read up to `maxCount` frames into the given buffers. Returns the frame count read.
    /// Reader thread only. The sample copy runs outside every lock.
    @discardableResult
    public func read(left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        guard maxCount > 0 else { return 0 }
        for _ in 0..<Self.maxReadAttempts {
            let s = sync.snapshot()
            let start = readStart(snapshot: s, consumed: readerReadIndex)
            let available = s.writeIndex - start
            guard available > 0 else {
                // Nothing to take. Still record frames skipped by an overrun or a rate change.
                if start > readerReadIndex { commit(readIndex: start, rateBits: s.rateBits) }
                return 0
            }
            let n = min(maxCount, available)
            copyOut(from: start, count: n, left: l, right: r)
            readerHookAfterCopy?()

            // Validate the finished copy. `start` — the oldest frame index it touched — is the only
            // index that has to be checked. Write `C` for `capacity`:
            //
            //  1. The copy read the storage slots `start % C ... (start + n - 1) % C`.
            //  2. The writer only ever writes frames at or after the writeIndex it has published,
            //     and `start + n <= s.writeIndex`, so it never rewrites a frame this copy took. It
            //     can only overwrite a *slot*.
            //  3. Frame `f` lives in slot `f % C`, so the lowest frame index that collides with any
            //     slot this copy read is `start + C`: it reuses slot `start % C`. Every later
            //     colliding frame is larger still.
            //  4. The writer announces the end of its in-flight region before it touches a sample
            //     and `claimEnd` never decreases, so the highest frame index it has claimed at this
            //     point is `claimEnd - 1`.
            //
            //  => the copy is intact  <=>  claimEnd - 1 < start + C  <=>  claimEnd - start <= C.
            //
            // The bound is non-strict, and has to be: `<` would also be sound but would throw away
            // the legitimate case of a writer whose in-flight region ends exactly at `start + C`,
            // which is the frame *before* the oldest one this copy read.
            //
            // The fence is what makes step 4 true of the value actually loaded here. Without it the
            // load may be satisfied before the copy's loads complete and return a `claimEnd` from
            // before the lap — see `ringReaderCopyFence`.
            ringReaderCopyFence()
            if sync.claimEndValue() - start <= capacity {
                commit(readIndex: start + n, rateBits: s.rateBits)
                return n
            }
        }
        // The writer outran every retry (it would have to lap the whole buffer during a memcpy).
        // Report nothing rather than torn samples, and resync to the newest frames.
        let w = sync.writeIndexValue()
        if w > readerReadIndex { commit(readIndex: w, rateBits: sync.snapshot().rateBits) }
        return 0
    }

    /// First frame index the reader may take: not already consumed, not before the current rate
    /// epoch, and not older than the newest `capacity` frames.
    private func readStart(snapshot s: RingSnapshot, consumed: Int) -> Int {
        var start = max(consumed, s.epochStart)
        if s.writeIndex - start > capacity { start = s.writeIndex - capacity }
        return min(start, s.writeIndex)
    }

    private func commit(readIndex: Int, rateBits: UInt64) {
        readerReadIndex = readIndex
        sync.commitRead(readIndex: readIndex, rateBits: rateBits)
    }

    private func copyOut(from start: Int, count: Int,
                         left l: UnsafeMutablePointer<Float>, right r: UnsafeMutablePointer<Float>) {
        var pos = start % capacity
        var remaining = count
        var offset = 0
        while remaining > 0 {
            let chunk = min(remaining, capacity - pos)
            (l + offset).update(from: left + pos, count: chunk)
            readerHookAfterLeftChannel?()
            (r + offset).update(from: right + pos, count: chunk)
            pos = (pos + chunk) % capacity
            offset += chunk
            remaining -= chunk
        }
    }
}
