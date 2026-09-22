import XCTest
@testable import JoseonCore

final class SessionConcurrencyTests: XCTestCase {

    /// Check everything a panel may rely on in one snapshot.
    private func assertConsistent(_ snapshot: SessionSnapshot, capacity: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(snapshot.samples.count, capacity, file: file, line: line)
        var previousTime = -Double.infinity
        for sample in snapshot.samples {
            XCTAssertGreaterThan(sample.time, previousTime, "samples are oldest first", file: file, line: line)
            previousTime = sample.time
            XCTAssertEqual(sample.bands.count, 8, file: file, line: line)
            XCTAssertTrue(sample.bands.allSatisfy { $0.isFinite }, file: file, line: line)
            XCTAssertTrue(sample.momentaryMaxLUFS.isFinite && sample.correlation.isFinite, file: file, line: line)
        }
        var previousEventTime = -Double.infinity
        var ids = Set<Int>()
        for event in snapshot.events {
            XCTAssertGreaterThanOrEqual(event.time, previousEventTime, "events are oldest first", file: file, line: line)
            previousEventTime = event.time
            XCTAssertTrue(ids.insert(event.id).inserted, "event ids are unique", file: file, line: line)
            XCTAssertGreaterThan(event.id, 0, file: file, line: line)
            XCTAssertTrue(event.value.isFinite, file: file, line: line)
        }
        if let oldest = snapshot.samples.first, snapshot.samples.count == capacity {
            for event in snapshot.events {
                XCTAssertGreaterThanOrEqual(event.time, oldest.time - 1.0001, "no event older than the record", file: file, line: line)
            }
        }
    }

    /// One writer at about 600 ingests per second, two readers, for a second of wall time.
    func testSnapshotIsConsistentUnderAConcurrentReader() {
        let capacity = 30
        let recorder = SessionRecorder(capacitySeconds: capacity)
        let stop = DispatchTime.now() + .seconds(1)
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            var n = 0
            let flag = SessionTestFrame.flag("load", title: "Load")
            while DispatchTime.now() < stop {
                n += 1
                let frame = SessionTestFrame.make(momentary: Float(-40 + n % 20),
                                                  shortTerm: Float(-30 + n % 10),
                                                  truePeakLeft: n % 97 == 0 ? 1.2 : -4,
                                                  truePeakRight: -5,
                                                  clipCount: n / 50,
                                                  correlation: Float(n % 3) / 2 - 0.5,
                                                  bandsDB: Float(-60 + n % 40),
                                                  levelA: Float(70 + n % 10),
                                                  flags: (n / 37) % 2 == 0 ? [flag] : [],
                                                  isSilent: (n / 211) % 3 == 0)
                recorder.ingest(frame, dt: 0.1)
                if n % 997 == 0 { recorder.noteTrackStart() }
            }
            group.leave()
        }

        var reads = 0
        let readLock = NSLock()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var lastRevision = -1
                var local = 0
                while DispatchTime.now() < stop {
                    let snapshot = recorder.snapshot()
                    self.assertConsistent(snapshot, capacity: capacity)
                    XCTAssertGreaterThanOrEqual(snapshot.revision, lastRevision, "the revision never falls")
                    lastRevision = snapshot.revision
                    local += 1
                }
                readLock.withLock { reads += local }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        let final = recorder.snapshot()
        assertConsistent(final, capacity: capacity)
        XCTAssertEqual(final.samples.count, capacity, "the ring filled during the run")
        XCTAssertGreaterThan(final.revision, 0)
        XCTAssertGreaterThan(reads, 100, "the readers really ran")
    }

    /// `clear` from another thread while the analysis thread feeds: no crash, no torn record.
    func testClearRacingWithIngest() {
        let recorder = SessionRecorder(capacitySeconds: 8)
        let stop = DispatchTime.now() + .milliseconds(400)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            while DispatchTime.now() < stop {
                recorder.ingest(SessionTestFrame.make(momentary: -18, clipCount: 1), dt: 0.3)
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            while DispatchTime.now() < stop {
                recorder.clear()
                self.assertConsistent(recorder.snapshot(), capacity: 8)
                usleep(500)
            }
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        assertConsistent(recorder.snapshot(), capacity: 8)
    }
}
