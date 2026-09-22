import XCTest
@testable import JoseonCore

/// Budgets: `ingest` under 2 us per call, `snapshot` of a full 30-minute record under 0.2 ms.
/// The hard assertions only run in a release build (`swift test -c release`): `swift test` is `-Onone`.
final class SessionPerformanceTests: XCTestCase {

    /// A recorder with the whole record full of samples, and the event ring full too.
    private func makeFullRecorder(capacity: Int = 1800) -> SessionRecorder {
        let recorder = SessionRecorder(capacitySeconds: capacity)
        let flag = SessionTestFrame.flag("load", title: "Sub-bass load high", severity: .high)
        for second in 0..<(capacity + 5) {
            for frame in 0..<60 {
                recorder.ingest(SessionTestFrame.make(momentary: Float(-30 + frame % 7),
                                                      shortTerm: -24, truePeakLeft: -2, truePeakRight: -1.5,
                                                      clipCount: second, correlation: 0.4,
                                                      bandsDB: -20, levelA: 78, flags: [flag]),
                                dt: 1.0 / 60)
            }
        }
        // Fill the event ring at the newest end, so nothing is dropped for age.
        for _ in 0..<SessionRecorder.maxEvents { recorder.noteTrackStart() }
        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.samples.count, capacity)
        XCTAssertEqual(snapshot.events.count, SessionRecorder.maxEvents)
        return recorder
    }

    func testIngestCost() {
        let recorder = SessionRecorder(capacitySeconds: 1800)
        let flag = SessionTestFrame.flag("load", title: "Sub-bass load high", severity: .high)
        let frames = (0..<8).map { i in
            SessionTestFrame.make(momentary: Float(-30 + i), shortTerm: Float(-26 + i),
                                  truePeakLeft: Float(-3 + i % 3), truePeakRight: -2,
                                  clipCount: i / 4, correlation: 0.3, bandsDB: Float(-40 + i),
                                  levelA: Float(75 + i), flags: [flag], isSilent: false)
        }
        // Warm up: every allocation path once (ring slots, flag state, event ring).
        for i in 0..<6_000 { recorder.ingest(frames[i % frames.count], dt: 1.0 / 60) }

        let iterations = 300_000
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<iterations { recorder.ingest(frames[i % frames.count], dt: 1.0 / 60) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
        let perCall = elapsed / Double(iterations) / 1_000
        print(String(format: "SessionRecorder.ingest: %.3f us per call over %d calls", perCall, iterations))
        #if DEBUG
        XCTAssertLessThan(perCall, 20, "debug build (-Onone): loose bound only")
        #else
        XCTAssertLessThan(perCall, 2, "ingest must stay under 2 us per call")
        #endif
    }

    func testSnapshotCostOfAFullRecord() {
        let recorder = makeFullRecorder()
        for _ in 0..<20 { _ = recorder.snapshot() }      // warm

        let iterations = 500
        let start = DispatchTime.now().uptimeNanoseconds
        var kept = 0
        for _ in 0..<iterations {
            let snapshot = recorder.snapshot()
            kept += snapshot.samples.count + snapshot.events.count
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
        let perCall = elapsed / Double(iterations) / 1_000
        print(String(format: "SessionRecorder.snapshot (1800 samples + 2000 events): %.1f us per call", perCall))
        XCTAssertEqual(kept, iterations * 3_800)
        #if DEBUG
        XCTAssertLessThan(perCall, 2_000, "debug build (-Onone): loose bound only")
        #else
        XCTAssertLessThan(perCall, 200, "copy-out of a full record must stay under 0.2 ms")
        #endif
    }

    /// What the analysis thread really pays: an ingest that closes a second while readers take
    /// snapshots. The lock is held for one bulk copy, so the writer is never blocked for long.
    /// Two readers at 1000 snapshots per second are already a thousand times the load a timeline
    /// panel makes (it redraws about once per second).
    func testIngestStaysFastWhileReadersSnapshot() {
        let recorder = makeFullRecorder(capacity: 1800)
        let stop = DispatchTime.now() + .milliseconds(600)
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while DispatchTime.now() < stop {
                    _ = recorder.snapshot()
                    usleep(1_000)
                }
                group.leave()
            }
        }
        let frame = SessionTestFrame.make(momentary: -18, shortTerm: -20, truePeakLeft: -2,
                                          truePeakRight: -3, correlation: 0.5, bandsDB: -30, levelA: 80)
        var worst: Double = 0
        var total: Double = 0
        var calls = 0
        while DispatchTime.now() < stop {
            let start = DispatchTime.now().uptimeNanoseconds
            recorder.ingest(frame, dt: 0.5)     // every second call closes a second
            let took = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000
            worst = max(worst, took)
            total += took
            calls += 1
        }
        group.wait()
        print(String(format: "ingest under 2 readers: mean %.3f us, worst %.1f us over %d calls", total / Double(max(calls, 1)), worst, calls))
        XCTAssertGreaterThan(calls, 1_000)
        #if !DEBUG
        XCTAssertLessThan(total / Double(max(calls, 1)), 2, "mean ingest stays under budget while readers copy")
        // The worst single call is scheduling noise, not the lock: one copy-out is about 40 us.
        XCTAssertLessThan(worst, 5_000, "no ingest waits for a reader for long")
        #endif
    }
}
