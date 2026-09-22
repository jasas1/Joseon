import XCTest
@testable import JoseonCore

/// Regression tests for the reader's overrun validation in `StereoRingBuffer`.
///
/// The deterministic tests drive the exact interleaving that used to be returned to the caller: the
/// writer laps the buffer *between the two channel copies of one `read`*. They use the reader-side
/// test hooks, so the "writer" runs inline on the test thread. The ring is indexed, not
/// thread-identified, so its state afterwards is the same as with a real concurrent writer — and
/// unlike the stress test, the interleaving happens every single run.
///
/// Each of them fails on a `read` that samples `claimEnd` before its copy instead of after it,
/// which is precisely the reordering the missing barrier used to allow.
final class RingBufferRaceTests: XCTestCase {

    private static let capacity = 1024

    private static func backends() -> [(String, StereoRingBuffer)] {
        [("lock-free", StereoRingBuffer(capacity: capacity)),
         ("locked", StereoRingBuffer.lockedForTesting(capacity: capacity))]
    }

    /// Counter signal: left is the frame index, right is its negation. Any mix of frames from two
    /// different writes is then visible both as a jump in `left` and as a channel disagreement.
    private func writeCounter(_ ring: StereoRingBuffer, from: Int, count: Int) {
        let l = (0..<count).map { Float(from + $0) }
        let r = l.map { -$0 }
        ring.write(left: l, right: r, count: count, sampleRate: 48_000)
    }

    private func assertIntact(_ l: [Float], _ r: [Float], _ n: Int, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        for i in 0..<n {
            XCTAssertEqual(r[i], -l[i], "\(label): channels disagree at \(i)", file: file, line: line)
            if i > 0 {
                XCTAssertEqual(l[i], l[i - 1] + 1, "\(label): torn at \(i)", file: file, line: line)
            }
        }
    }

    /// Arms a one-shot lap that runs after the left channel of the first copy segment.
    private func lapOnce(_ ring: StereoRingBuffer, from: Int, count: Int) {
        var fired = false
        ring.readerHookAfterLeftChannel = { [unowned ring] in
            guard !fired else { return }
            fired = true
            self.writeCounter(ring, from: from, count: count)
        }
    }

    // MARK: - The interleaving that used to escape

    /// `C` = 1024. The reader takes frames 0..<100 out of slots 0..<100. Between the left copy and
    /// the right copy the writer appends 925 frames and so reaches frame 1024 — the first frame
    /// that reuses slot 0. The right channel of frame 0 in the output is therefore the right
    /// channel of frame 1024, and `read` must throw that copy away and come back with a clean one.
    ///
    /// `claimEnd` is 1025 afterwards and `1025 - 0 > 1024`, so the copy is rejected. Read *before*
    /// the copy, `claimEnd` is 100, `100 - 0 <= 1024`, and the torn copy is handed to the caller.
    func testLapBetweenChannelCopiesIsRejected() {
        for (label, ring) in Self.backends() {
            writeCounter(ring, from: 0, count: 100)
            lapOnce(ring, from: 100, count: 925)

            var l = [Float](repeating: .nan, count: 1024), r = l
            let n = ring.read(left: &l, right: &r, maxCount: 100)
            ring.readerHookAfterLeftChannel = nil

            XCTAssertEqual(n, 100, "\(label)")
            assertIntact(l, r, n, label)
            // The retry resyncs to the newest 1024 frames, which now start at frame 1.
            XCTAssertEqual(l[0], 1, "\(label): did not resync after rejecting the lapped copy")
        }
    }

    /// The same lap, but with a copy that wraps the storage, so it happens between the two segments
    /// of one channel rather than between the two channels of one segment.
    ///
    /// 1000 frames are consumed first, so the copy starts at slot 1000 and splits into slots
    /// 1000..<1024 and 0..<76. The lap reaches frame 2024, which reuses slot 1000 — inside the
    /// first segment, which has already been copied.
    func testLapBetweenWrappedCopySegmentsIsRejected() {
        for (label, ring) in Self.backends() {
            writeCounter(ring, from: 0, count: 1000)
            var sink = [Float](repeating: 0, count: 1024), sinkR = sink
            XCTAssertEqual(ring.read(left: &sink, right: &sinkR, maxCount: 1000), 1000, "\(label)")
            writeCounter(ring, from: 1000, count: 100)

            lapOnce(ring, from: 1100, count: 925)   // reaches frame 2024 = slot 1000
            var l = [Float](repeating: .nan, count: 1024), r = l
            let n = ring.read(left: &l, right: &r, maxCount: 100)
            ring.readerHookAfterLeftChannel = nil

            XCTAssertEqual(n, 100, "\(label)")
            assertIntact(l, r, n, label)
            XCTAssertEqual(l[0], 1001, "\(label): did not resync after rejecting the lapped copy")
        }
    }

    /// A single write longer than the whole buffer takes the same path: it claims `base + count`
    /// but stores only the last `capacity` frames, so the claim still bounds every slot it touches.
    func testLapByOneOversizedWriteIsRejected() {
        for (label, ring) in Self.backends() {
            writeCounter(ring, from: 0, count: 100)
            lapOnce(ring, from: 100, count: 3000)

            var l = [Float](repeating: .nan, count: 1024), r = l
            let n = ring.read(left: &l, right: &r, maxCount: 100)
            ring.readerHookAfterLeftChannel = nil

            XCTAssertEqual(n, 100, "\(label)")
            assertIntact(l, r, n, label)
            XCTAssertEqual(l[0], 2076, "\(label): should hold the newest 1024 frames")
        }
    }

    // MARK: - The bound is exactly `<= capacity`

    /// The boundary case on the safe side. The lap stops one frame short: it writes frames
    /// 100..<1024, so `claimEnd` is exactly `start + capacity`. Frame 1023 lives in slot 1023 and
    /// the copy read slots 0..<100, so nothing it took was touched — the copy is intact and must be
    /// accepted. A strict `claimEnd - start < capacity` would reject it, resync, and return frames
    /// that start somewhere other than 0.
    func testWriteEndingExactlyAtTheCapacityBoundaryIsAccepted() {
        for (label, ring) in Self.backends() {
            writeCounter(ring, from: 0, count: 100)
            lapOnce(ring, from: 100, count: 924)   // claimEnd = 1024 = start + capacity

            var l = [Float](repeating: .nan, count: 1024), r = l
            let n = ring.read(left: &l, right: &r, maxCount: 100)
            ring.readerHookAfterLeftChannel = nil

            XCTAssertEqual(n, 100, "\(label)")
            assertIntact(l, r, n, label)
            XCTAssertEqual(l[0], 0, "\(label): an intact copy was rejected — the bound is too strict")
            XCTAssertEqual(l[99], 99, "\(label)")
        }
    }

    /// One frame further and slot 0 is gone. This is the first index the bound must reject.
    func testWriteOneFramePastTheCapacityBoundaryIsRejected() {
        for (label, ring) in Self.backends() {
            writeCounter(ring, from: 0, count: 100)
            lapOnce(ring, from: 100, count: 925)   // claimEnd = 1025, frame 1024 lands in slot 0

            var l = [Float](repeating: .nan, count: 1024), r = l
            let n = ring.read(left: &l, right: &r, maxCount: 100)
            ring.readerHookAfterLeftChannel = nil

            XCTAssertEqual(n, 100, "\(label)")
            assertIntact(l, r, n, label)
            XCTAssertNotEqual(l[0], 0, "\(label): a lapped copy was accepted")
        }
    }

    // MARK: - Retries

    /// Every attempt is lapped, so `read` gives up. It must report nothing rather than whatever the
    /// last rejected attempt happened to leave in the caller's buffers.
    func testEveryAttemptLappedReturnsNothing() {
        for (label, ring) in Self.backends() {
            writeCounter(ring, from: 0, count: 100)
            var next = 100
            ring.readerHookAfterLeftChannel = { [unowned ring] in
                self.writeCounter(ring, from: next, count: 2048)
                next += 2048
            }
            var l = [Float](repeating: .nan, count: 1024), r = l
            let n = ring.read(left: &l, right: &r, maxCount: 100)
            ring.readerHookAfterLeftChannel = nil

            XCTAssertEqual(n, 0, "\(label): torn frames reported after every attempt was lapped")
            // And the reader has resynced, so the next read comes back clean.
            let m = ring.read(left: &l, right: &r, maxCount: 512)
            assertIntact(l, r, m, label)
        }
    }

    // MARK: - Load

    /// The stress test of record, with the machine deliberately oversubscribed so the reader is
    /// preempted in the middle of its copy. Both backends, short enough to run in CI.
    func testConcurrentReadWriteUnderCPULoad() {
        for (label, ring) in [("lock-free", StereoRingBuffer(capacity: 1 << 12)),
                              ("locked", StereoRingBuffer.lockedForTesting(capacity: 1 << 12))] {
            let result = Self.stressUnderLoad(ring: ring, seconds: 1.5)
            XCTAssertEqual(result.tears, 0, "\(label): torn data inside a read call")
            XCTAssertEqual(result.channelMismatch, 0, "\(label): left/right channels disagree")
            XCTAssertGreaterThan(result.frames, 50_000, "\(label): the test did not exercise the buffer")
            print("[ring race \(label)] reads=\(result.reads) frames=\(result.frames) "
                  + "overrun-gaps=\(result.overruns)")
        }
    }

    struct StressResult {
        var tears = 0, channelMismatch = 0, frames = 0, reads = 0, overruns = 0
    }

    /// One writer, one reader, and `ProcessInfo.activeProcessorCount` spinning threads so both of
    /// them get descheduled mid-operation.
    static func stressUnderLoad(ring: StereoRingBuffer, seconds: TimeInterval) -> StressResult {
        let modulus = 1 << 20                       // exactly representable in Float, divisible by 512
        let deadline = Date().addingTimeInterval(seconds)
        let stop = StopFlag()

        var threads: [Thread] = []
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            let spinner = Thread {
                var x = 1.0
                while !stop.isSet { for _ in 0..<5000 { x = x * 1.0000001 + 1 } }
                if x == 0 { print("") }             // keep the loop alive
            }
            spinner.stackSize = 1 << 19
            threads.append(spinner)
        }

        let writer = Thread {
            var counter = 0
            var l = [Float](repeating: 0, count: 512)
            var r = [Float](repeating: 0, count: 512)
            while !stop.isSet {
                for i in 0..<512 {
                    l[i] = Float((counter + i) % modulus)
                    r[i] = -l[i]
                }
                ring.write(left: l, right: r, count: 512, sampleRate: 48_000)
                counter += 512
            }
        }
        writer.stackSize = 1 << 19
        writer.qualityOfService = .userInitiated
        threads.append(writer)
        for t in threads { t.start() }

        var result = StressResult()
        var out = [Float](repeating: 0, count: 4096), outR = out
        var generator = SystemRandomNumberGenerator()
        var previousLast: Float? = nil
        while Date() < deadline {
            let want = Int.random(in: 1...4096, using: &generator)
            let n = ring.read(left: &out, right: &outR, maxCount: want)
            result.reads += 1
            guard n > 0 else { continue }
            result.frames += n
            for i in 0..<n {
                if outR[i] != -out[i] { result.channelMismatch += 1 }
                if i > 0, out[i] != Float((Int(out[i - 1]) + 1) % modulus) { result.tears += 1 }
            }
            if let previous = previousLast, out[0] != Float((Int(previous) + 1) % modulus) {
                result.overruns += 1
            }
            previousLast = out[n - 1]
        }
        stop.set()
        for t in threads { while !t.isFinished { usleep(500) } }
        return result
    }
}

/// Cross-thread stop flag for the stress test (NSLock-backed: the test is not real-time).
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
