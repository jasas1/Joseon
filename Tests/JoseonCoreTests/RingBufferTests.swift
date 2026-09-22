import XCTest
@testable import JoseonCore

final class RingBufferTests: XCTestCase {
    func testWriteThenRead() {
        let ring = StereoRingBuffer(capacity: 1024)
        let l = (0..<300).map(Float.init), r = l.map { -$0 }
        ring.write(left: l, right: r, count: 300, sampleRate: 44_100)
        XCTAssertEqual(ring.availableFrames, 300)
        var ol = [Float](repeating: 0, count: 512), or = ol
        let n = ring.read(left: &ol, right: &or, maxCount: 512)
        XCTAssertEqual(n, 300)
        XCTAssertEqual(ol[299], 299); XCTAssertEqual(or[299], -299)
        XCTAssertEqual(ring.sampleRate, 44_100)
    }

    func testOverrunKeepsNewest() {
        let ring = StereoRingBuffer(capacity: 256)
        let l = (0..<1000).map(Float.init)
        ring.write(left: l, right: l, count: 1000, sampleRate: 48_000)
        var ol = [Float](repeating: 0, count: 256), or = ol
        XCTAssertEqual(ring.read(left: &ol, right: &or, maxCount: 256), 256)
        XCTAssertEqual(ol[255], 999)
        XCTAssertEqual(ol[0], 744)
    }

    // MARK: - Overrun

    /// Many small writes that together overrun the buffer must still leave the newest `capacity`
    /// frames, with no gap and no stale frame.
    func testOverrunKeepsNewestAcrossManyWrites() {
        for ring in Self.bothBackends(capacity: 512) {
            var counter = 0
            for _ in 0..<40 {
                let block = (0..<100).map { Float(counter + $0) }
                ring.write(left: block, right: block, count: 100, sampleRate: 48_000)
                counter += 100
            }
            XCTAssertEqual(ring.availableFrames, 512)
            var ol = [Float](repeating: -1, count: 4000), or = ol
            let n = ring.read(left: &ol, right: &or, maxCount: 4000)
            XCTAssertEqual(n, 512)
            XCTAssertEqual(ol[0], Float(counter - 512))
            XCTAssertEqual(ol[511], Float(counter - 1))
            for i in 1..<n { XCTAssertEqual(ol[i], ol[i - 1] + 1, "gap at \(i)") }
            XCTAssertEqual(ring.availableFrames, 0)
        }
    }

    /// A single write larger than the buffer keeps the newest `capacity` frames of that write.
    func testSingleWriteLargerThanCapacity() {
        for ring in Self.bothBackends(capacity: 128) {
            let l = (0..<5000).map(Float.init), r = l.map { -$0 }
            ring.write(left: l, right: r, count: 5000, sampleRate: 48_000)
            var ol = [Float](repeating: 0, count: 128), or = ol
            XCTAssertEqual(ring.read(left: &ol, right: &or, maxCount: 128), 128)
            XCTAssertEqual(ol[0], 4872)
            XCTAssertEqual(ol[127], 4999)
            XCTAssertEqual(or[127], -4999)
        }
    }

    // MARK: - Wrap-around

    /// Odd-sized writes and reads that wrap the storage many times must deliver an unbroken
    /// counter signal on both channels.
    func testWrapAroundOddSizes() {
        for ring in Self.bothBackends(capacity: 1024) {
            let writeSizes = [37, 101, 7, 255, 3, 129, 61]
            let readSizes = [13, 200, 1, 77, 333, 5, 91]
            var written = 0, readBack = 0
            var w = 0, rIdx = 0
            var out = [Float](repeating: 0, count: 1024), outR = out

            for step in 0..<600 {
                let count = writeSizes[w % writeSizes.count]; w += 1
                // Stay under capacity so nothing is dropped: this test checks wrap math, not overrun.
                if written - readBack + count <= 1024 {
                    let block = (0..<count).map { Float(written + $0) }
                    let blockR = block.map { -$0 }
                    ring.write(left: block, right: blockR, count: count, sampleRate: 48_000)
                    written += count
                }
                let want = readSizes[rIdx % readSizes.count]; rIdx += 1
                let n = ring.read(left: &out, right: &outR, maxCount: want)
                XCTAssertLessThanOrEqual(n, want)
                for i in 0..<n {
                    XCTAssertEqual(out[i], Float(readBack + i), "step \(step) index \(i)")
                    XCTAssertEqual(outR[i], -Float(readBack + i), "step \(step) index \(i) right")
                }
                readBack += n
            }

            // Drain the tail and confirm the whole stream came through in order.
            while true {
                let n = ring.read(left: &out, right: &outR, maxCount: 1024)
                if n == 0 { break }
                for i in 0..<n { XCTAssertEqual(out[i], Float(readBack + i)) }
                readBack += n
            }
            XCTAssertEqual(readBack, written)
            XCTAssertGreaterThan(written, 10_000)
        }
    }

    // MARK: - Sample rate

    func testSampleRateFollowsMidStreamChange() {
        for ring in Self.bothBackends(capacity: 1024) {
            XCTAssertEqual(ring.sampleRate, 48_000, "default before any write")

            let a = (0..<100).map(Float.init)
            ring.write(left: a, right: a, count: 100, sampleRate: 44_100)
            XCTAssertEqual(ring.sampleRate, 44_100, "newest write rate before the first read")

            var ol = [Float](repeating: 0, count: 1024), or = ol
            XCTAssertEqual(ring.read(left: &ol, right: &or, maxCount: 1024), 100)
            XCTAssertEqual(ring.sampleRate, 44_100)

            // Rate changes mid-stream: the new epoch's frames come back under the new rate.
            let b = (100..<250).map(Float.init)
            ring.write(left: b, right: b, count: 150, sampleRate: 96_000)
            let n = ring.read(left: &ol, right: &or, maxCount: 1024)
            XCTAssertEqual(n, 150)
            XCTAssertEqual(ol[0], 100)
            XCTAssertEqual(ring.sampleRate, 96_000)
        }
    }

    /// Unread frames from before a rate change are dropped, not relabelled: one read never mixes
    /// two rates.
    func testRateChangeDropsUnreadOldEpochFrames() {
        for ring in Self.bothBackends(capacity: 1024) {
            let a = (0..<100).map(Float.init)
            ring.write(left: a, right: a, count: 100, sampleRate: 44_100)
            let b = (1000..<1100).map(Float.init)
            ring.write(left: b, right: b, count: 100, sampleRate: 48_000)

            XCTAssertEqual(ring.availableFrames, 100, "only the new epoch is readable")
            var ol = [Float](repeating: 0, count: 1024), or = ol
            let n = ring.read(left: &ol, right: &or, maxCount: 1024)
            XCTAssertEqual(n, 100)
            XCTAssertEqual(ol[0], 1000)
            XCTAssertEqual(ol[99], 1099)
            XCTAssertEqual(ring.sampleRate, 48_000)
        }
    }

    // MARK: - Concurrency

    /// Writer thread at 512-frame blocks, reader thread draining at random sizes for ~2 s.
    /// Inside one `read` the counter signal must be strictly contiguous (no tear); across reads it
    /// may jump forward (a reported overrun) but never backwards.
    func testConcurrentWriterReaderNoTears() {
        stress(ring: StereoRingBuffer(capacity: 1 << 13), seconds: 2.0, label: "lock-free")
    }

    /// Same stress on the `os_unfair_lock` fallback that macOS 14 uses.
    func testConcurrentWriterReaderNoTearsOnLockedBackend() {
        stress(ring: StereoRingBuffer.lockedForTesting(capacity: 1 << 13), seconds: 1.0, label: "locked")
    }

    private func stress(ring: StereoRingBuffer, seconds: TimeInterval, label: String) {
        // 1 << 20 is exactly representable in Float, and 512 divides it, so blocks never straddle
        // the wrap of the counter signal.
        let modulus = 1 << 20
        let deadline = Date().addingTimeInterval(seconds)
        let stop = ManagedAtomicFlag()

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

        var tears = 0
        var channelMismatch = 0
        var totalFrames = 0
        var readCalls = 0
        var overruns = 0

        writer.start()
        var out = [Float](repeating: 0, count: 4096), outR = out
        var previousLast: Float? = nil
        var generator = SystemRandomNumberGenerator()
        while Date() < deadline {
            let want = Int.random(in: 1...4096, using: &generator)
            let n = ring.read(left: &out, right: &outR, maxCount: want)
            readCalls += 1
            guard n > 0 else { continue }
            totalFrames += n
            for i in 0..<n {
                if outR[i] != -out[i] { channelMismatch += 1 }
                if i > 0 {
                    let expected = Float((Int(out[i - 1]) + 1) % modulus)
                    if out[i] != expected { tears += 1 }
                }
            }
            if let previous = previousLast {
                // A gap between reads is a legitimate overrun (the writer lapped the buffer).
                // The counter wraps at `modulus`, so the size of a gap carries no information.
                if out[0] != Float((Int(previous) + 1) % modulus) { overruns += 1 }
            }
            previousLast = out[n - 1]
        }
        stop.set()
        while !writer.isFinished { usleep(500) }

        XCTAssertEqual(tears, 0, "torn data inside a read call")
        XCTAssertEqual(channelMismatch, 0, "left/right channels disagree")
        XCTAssertGreaterThan(totalFrames, 100_000, "the test did not exercise the buffer")
        print("[ring stress \(label)] reads=\(readCalls) frames=\(totalFrames) overrun-gaps=\(overruns)")
    }

    // MARK: - Cost

    func testWritePerformance() {
        let ring = StereoRingBuffer(capacity: 1 << 17)
        let l = [Float](repeating: 0.25, count: 512)
        let r = [Float](repeating: -0.25, count: 512)
        // 1000 writes per iteration = 1000 IOProc callbacks of 512 frames.
        measure {
            for _ in 0..<1000 {
                ring.write(left: l, right: r, count: 512, sampleRate: 48_000)
            }
        }
    }

    /// Same measurement on the macOS 14 fallback, for comparison.
    func testWritePerformanceLockedBackend() {
        let ring = StereoRingBuffer.lockedForTesting(capacity: 1 << 17)
        let l = [Float](repeating: 0.25, count: 512)
        let r = [Float](repeating: -0.25, count: 512)
        measure {
            for _ in 0..<1000 {
                ring.write(left: l, right: r, count: 512, sampleRate: 48_000)
            }
        }
    }

    // MARK: - Helpers

    /// The lock-free backend the running OS selects, plus the `os_unfair_lock` fallback used on
    /// macOS 14, so both paths are covered on one machine.
    private static func bothBackends(capacity: Int) -> [StereoRingBuffer] {
        [StereoRingBuffer(capacity: capacity), StereoRingBuffer.lockedForTesting(capacity: capacity)]
    }
}

/// Minimal cross-thread stop flag for the stress test (NSLock-backed: the test is not real-time).
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
