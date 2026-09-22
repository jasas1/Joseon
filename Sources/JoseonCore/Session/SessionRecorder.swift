import Foundation
import os

/// Rolling, in-memory record of the last `capacitySeconds` of listening: one `SessionSample` per second
/// of AUDIO time, plus `SessionEvent`s. Nothing is ever written to disk and no audio is kept — only the
/// numbers of the contract.
///
/// Threading
/// ---------
/// `ingest` and `noteTrackStart` run on the analysis thread (about 60 calls per second). `snapshot` and
/// `clear` run on any thread. One `os_unfair_lock` guards the two rings and the revision. The analysis
/// thread takes it at most twice per ingest, for a few nanoseconds each time; a reader takes it for one
/// bulk copy of the rings (no malloc inside: the output arrays are reserved before the lock).
///
/// Storage
/// -------
/// The sample ring is a preallocated `[SessionSample]` of `capacitySeconds` entries, each one built at
/// init with its own 8-element `bands` array. Closing a second writes the fields of one slot in place,
/// so a warm recorder allocates nothing per ingest. A snapshot shares those band buffers with the
/// reader (copy on write); the next write to a shared slot makes one 8-float buffer — at most one small
/// allocation per second, never 60 per second.
///
/// Clocks
/// ------
/// `SessionSample.time` is audio time: it advances by `dt` only, so a silence gap where the engine
/// sleeps does not stretch the timeline axis. Wall-clock dates come from the injected `now`.
public final class SessionRecorder: SessionRecording, @unchecked Sendable {

    // MARK: Constants

    public let capacitySeconds: Int
    /// Silence longer than this makes a `silenceStart`; the end of it makes a `silenceEnd`.
    /// Measured in audio seconds while frames flow, in wall seconds across a gap where `dt` is 0
    /// (the engine sleeps on silence and stops publishing).
    public static let silenceSeconds: Double = 2
    /// Hard cap on kept events. The oldest go first.
    public static let maxEvents = 2000

    private static let bandCount = 8
    private static let loudnessFloor = LoudnessReading.silenceLUFS
    private static let peakFloor: Float = -120

    // MARK: Shared state (guarded by `lock`)

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var samples: [SessionSample]
    /// Next slot to write.
    private var sampleHead = 0
    private var sampleCount = 0
    private var events: [SessionEvent]
    private var eventHead = 0
    private var eventCount = 0
    private var revision = 0
    /// `clear()` empties the rings at once and asks the analysis thread to drop its accumulators.
    private var clearPending = false

    // MARK: Analysis-thread state

    private let clock: () -> Date
    /// Seconds of audio since the start (or the last `clear`).
    private var audioTime: Double = 0
    private var acc = Accumulator()
    private var lastClipCount = 0
    private var lastIngestWall: Date?
    private var silenceRun: Double = 0
    private var inSilence = false
    private var silenceStartTime: Double = 0
    private var silenceStartWall: Date?
    private var activeFlags: [FlagState] = []
    private var nextEventID = 1
    /// Events made during one ingest, pushed under a single lock at the end of it.
    private var pending: [SessionEvent] = []

    // MARK: Init

    /// - Parameters:
    ///   - capacitySeconds: length of the record. 1800 = 30 minutes.
    ///   - now: wall clock, injectable for tests. Never used for the timeline axis, only for labels.
    public init(capacitySeconds: Int = 1800, now: @escaping () -> Date = Date.init) {
        let capacity = max(1, capacitySeconds)
        self.capacitySeconds = capacity
        self.clock = now
        let blank = SessionSample(time: 0, date: Date(timeIntervalSinceReferenceDate: 0),
                                  momentaryMaxLUFS: Self.loudnessFloor, shortTermLUFS: Self.loudnessFloor,
                                  truePeakDBTP: Self.peakFloor, correlation: 0,
                                  bands: [], levelA: nil, isSilent: true)
        // `map`, not `repeating:`, so every slot owns its band buffer from the start.
        samples = (0..<capacity).map { _ in
            var s = blank
            s.bands = [Float](repeating: SpectrumReading.floorDB, count: Self.bandCount)
            return s
        }
        let blankEvent = SessionEvent(id: 0, kind: .trackStart, time: 0, date: Date(timeIntervalSinceReferenceDate: 0))
        events = [SessionEvent](repeating: blankEvent, count: Self.maxEvents)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        pending.reserveCapacity(16)
        activeFlags.reserveCapacity(8)
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: SessionRecording

    /// Analysis thread. `dt` = seconds of audio since the previous call (0 when no new audio arrived).
    public func ingest(_ frame: AnalysisFrame, dt: Double) {
        os_unfair_lock_lock(lock)
        let mustClear = clearPending
        clearPending = false
        os_unfair_lock_unlock(lock)
        if mustClear { resetAnalysisState() }

        let wall = clock()
        let step = (dt.isFinite && dt > 0) ? min(dt, Double(capacitySeconds)) : 0
        let wallGap = lastIngestWall.map { max(0, wall.timeIntervalSince($0)) } ?? 0
        lastIngestWall = wall

        audioTime += step
        accumulate(frame, step: step)
        trackSilence(isSilent: frame.isSilent, step: step, wallGap: wallGap, wall: wall)
        diffStressFlags(frame, wall: wall)

        if acc.elapsed >= 1 {
            let remainder = acc.elapsed.truncatingRemainder(dividingBy: 1)
            closeSample(at: audioTime - remainder, date: wall)
            acc.reset(elapsed: remainder)
        }
        flushPending()
    }

    /// Analysis thread: the measurement was reset (a new track). The clip count starts from 0 again.
    public func noteTrackStart() {
        let wall = clock()
        lastClipCount = 0
        emit(.trackStart, time: audioTime, date: wall, label: "Track start")
        flushPending()
    }

    /// Any thread. Consistent copy of both rings, oldest first.
    public func snapshot() -> SessionSnapshot {
        // Reserve outside the lock: no malloc runs while the analysis thread may be waiting.
        var outSamples = [SessionSample]()
        outSamples.reserveCapacity(capacitySeconds)
        var outEvents = [SessionEvent]()
        outEvents.reserveCapacity(64)

        os_unfair_lock_lock(lock)
        let sStart = (sampleHead - sampleCount + samples.count) % samples.count
        if sampleCount > 0 {
            let tail = min(sampleCount, samples.count - sStart)
            outSamples.append(contentsOf: samples[sStart..<(sStart + tail)])
            if tail < sampleCount { outSamples.append(contentsOf: samples[0..<(sampleCount - tail)]) }
        }
        let eStart = (eventHead - eventCount + events.count) % events.count
        if eventCount > 0 {
            let tail = min(eventCount, events.count - eStart)
            outEvents.append(contentsOf: events[eStart..<(eStart + tail)])
            if tail < eventCount { outEvents.append(contentsOf: events[0..<(eventCount - tail)]) }
        }
        let rev = revision
        os_unfair_lock_unlock(lock)

        return SessionSnapshot(samples: outSamples, events: outEvents, revision: rev)
    }

    /// Any thread: forget everything. The revision rises, so panels redraw. Event ids keep rising.
    public func clear() {
        os_unfair_lock_lock(lock)
        sampleHead = 0
        sampleCount = 0
        eventHead = 0
        eventCount = 0
        revision += 1
        clearPending = true
        os_unfair_lock_unlock(lock)
    }

    // MARK: Accumulation

    private struct Accumulator {
        var frames = 0
        /// Audio seconds in the second being built.
        var elapsed: Double = 0
        var momentaryMax = SessionRecorder.loudnessFloor
        var shortTerm = SessionRecorder.loudnessFloor
        var truePeak = SessionRecorder.peakFloor
        var correlationSum: Double = 0
        var bandPower = SIMD8<Double>()
        var levelAEnergy: Double = 0
        var levelAFrames = 0
        var allSilent = true
        /// New clipped-sample runs seen in this second.
        var clipRuns = 0
        /// Highest true peak over 0 dBTP in this second, and whether there was one.
        var overDBTP: Float = 0
        var sawOver = false

        mutating func reset(elapsed: Double) {
            let keep = elapsed
            self = Accumulator()
            self.elapsed = keep
        }
    }

    private func accumulate(_ frame: AnalysisFrame, step: Double) {
        acc.frames += 1
        acc.elapsed += step

        let l = frame.loudness
        acc.momentaryMax = max(acc.momentaryMax, Self.finite(l.momentaryLUFS, floor: Self.loudnessFloor))
        acc.shortTerm = Self.finite(l.shortTermLUFS, floor: Self.loudnessFloor)     // last one wins
        let peak = max(Self.finite(l.truePeakLeftDBTP, floor: Self.peakFloor),
                       Self.finite(l.truePeakRightDBTP, floor: Self.peakFloor))
        acc.truePeak = max(acc.truePeak, peak)
        if peak > 0 {
            acc.sawOver = true
            acc.overDBTP = max(acc.overDBTP, peak)
        }
        // A measurement reset makes the count fall: that is a new baseline, never negative clips.
        if l.clipCount < lastClipCount {
            lastClipCount = l.clipCount
        } else if l.clipCount > lastClipCount {
            acc.clipRuns += l.clipCount - lastClipCount
            lastClipCount = l.clipCount
        }

        let correlation = frame.stereo.correlation
        acc.correlationSum += correlation.isFinite ? Double(min(max(correlation, -1), 1)) : 0

        // Bands: mean of the POWER, not of the decibels.
        let b = frame.bands
        acc.bandPower[0] += Self.power(b.subBass)
        acc.bandPower[1] += Self.power(b.bass)
        acc.bandPower[2] += Self.power(b.lowMid)
        acc.bandPower[3] += Self.power(b.mid)
        acc.bandPower[4] += Self.power(b.upperMid)
        acc.bandPower[5] += Self.power(b.presence)
        acc.bandPower[6] += Self.power(b.brilliance)
        acc.bandPower[7] += Self.power(b.air)

        // A-weighted level at the ear: mean of the energy, when the estimate is there.
        if let spl = frame.spl {
            acc.levelAEnergy += Self.power(Self.finite(spl.levelASlow, floor: SPLReading.floorDB))
            acc.levelAFrames += 1
        }
        if !frame.isSilent { acc.allSilent = false }
    }

    /// Write the finished second into the ring and make the events that belong to it.
    private func closeSample(at time: Double, date: Date) {
        let n = max(acc.frames, 1)

        os_unfair_lock_lock(lock)
        // A `clear` landed while this ingest ran: the second belongs to the record that was thrown away.
        if clearPending {
            os_unfair_lock_unlock(lock)
            return
        }
        let slot = sampleHead
        samples[slot].time = time
        samples[slot].date = date
        samples[slot].momentaryMaxLUFS = acc.momentaryMax
        samples[slot].shortTermLUFS = acc.shortTerm
        samples[slot].truePeakDBTP = acc.truePeak
        samples[slot].correlation = Float(acc.correlationSum / Double(n))
        for i in 0..<Self.bandCount {
            samples[slot].bands[i] = max(Self.decibels(acc.bandPower[i] / Double(n)), SpectrumReading.floorDB)
        }
        samples[slot].levelA = acc.levelAFrames > 0
            ? max(Self.decibels(acc.levelAEnergy / Double(acc.levelAFrames)), SPLReading.floorDB)
            : nil
        samples[slot].isSilent = acc.allSilent
        sampleHead = (sampleHead + 1) % samples.count
        if sampleCount < samples.count { sampleCount += 1 }
        revision += 1
        // Events older than the oldest second in the ring are gone.
        if sampleCount == samples.count {
            let oldest = samples[sampleHead].time - 1
            while eventCount > 0 {
                let first = (eventHead - eventCount + events.count) % events.count
                if events[first].time < oldest { eventCount -= 1 } else { break }
            }
        }
        os_unfair_lock_unlock(lock)

        if acc.clipRuns > 0 {
            emit(.clip, time: time, date: date, label: "Clip", value: Float(acc.clipRuns))
        }
        if acc.sawOver {
            emit(.interSampleOver, time: time, date: date, label: "Over 0 dBTP", value: acc.overDBTP)
        }
    }

    // MARK: Silence

    private func trackSilence(isSilent: Bool, step: Double, wallGap: Double, wall: Date) {
        guard isSilent else {
            if inSilence {
                inSilence = false
                emit(.silenceEnd, time: audioTime, date: wall, label: "Sound")
            }
            silenceRun = 0
            silenceStartWall = nil
            return
        }
        // Audio time while frames flow; wall time across a gap where the engine slept (`dt` is 0).
        let covered = step > 0 ? step : wallGap
        if silenceRun == 0 {
            silenceStartTime = audioTime - step
            silenceStartWall = wall.addingTimeInterval(-covered)
        }
        silenceRun += covered
        if !inSilence && silenceRun > Self.silenceSeconds {
            inSilence = true
            emit(.silenceStart, time: silenceStartTime, date: silenceStartWall ?? wall, label: "Silence")
        }
    }

    // MARK: Stress flags

    private struct FlagState {
        var id: String
        var title: String
        var seen: Bool
    }

    private func diffStressFlags(_ frame: AnalysisFrame, wall: Date) {
        for i in activeFlags.indices { activeFlags[i].seen = false }
        if let flags = frame.headphone?.stressFlags {
            for flag in flags {
                if let i = activeFlags.firstIndex(where: { $0.id == flag.id }) {
                    activeFlags[i].seen = true
                    activeFlags[i].title = flag.title
                } else {
                    activeFlags.append(FlagState(id: flag.id, title: flag.title, seen: true))
                    emit(.stressFlagRaised, time: audioTime, date: wall,
                         label: flag.title, detail: flag.id, value: Float(flag.severity.rawValue))
                }
            }
        }
        var i = activeFlags.count - 1
        while i >= 0 {
            if !activeFlags[i].seen {
                emit(.stressFlagCleared, time: audioTime, date: wall,
                     label: activeFlags[i].title, detail: activeFlags[i].id)
                activeFlags.remove(at: i)
            }
            i -= 1
        }
    }

    // MARK: Events

    private func emit(_ kind: SessionEvent.Kind, time: Double, date: Date, label: String = "", detail: String = "", value: Float = 0) {
        pending.append(SessionEvent(id: nextEventID, kind: kind, time: time, date: date,
                                    label: label, detail: detail, value: value))
        nextEventID += 1
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        os_unfair_lock_lock(lock)
        if clearPending {       // same as a closed sample: a `clear` in flight wins
            os_unfair_lock_unlock(lock)
            pending.removeAll(keepingCapacity: true)
            return
        }
        // The oldest second in the record, when the record is full. `silenceStart` carries the time the
        // silence began, which can be before the event was made: an event that lands outside the record
        // is dropped, like one the record has grown past.
        let windowStart = sampleCount == samples.count ? samples[sampleHead].time - 1 : -Double.infinity
        for event in pending where event.time >= windowStart {
            push(event)
        }
        os_unfair_lock_unlock(lock)
        pending.removeAll(keepingCapacity: true)
    }

    /// Lock held. Append, then walk the event back while it is older than its neighbour, so the ring
    /// stays oldest first even for a `silenceStart` that is dated back to the start of the silence.
    private func push(_ event: SessionEvent) {
        var slot = eventHead
        events[slot] = event
        eventHead = (eventHead + 1) % events.count
        if eventCount < events.count { eventCount += 1 }   // else the oldest was overwritten
        var steps = eventCount - 1
        while steps > 0 {
            let previous = (slot - 1 + events.count) % events.count
            if events[previous].time <= events[slot].time { break }
            events.swapAt(previous, slot)
            slot = previous
            steps -= 1
        }
        revision += 1
    }

    // MARK: Helpers

    private func resetAnalysisState() {
        audioTime = 0
        acc = Accumulator()
        lastClipCount = 0
        lastIngestWall = nil
        silenceRun = 0
        inSilence = false
        silenceStartWall = nil
        silenceStartTime = 0
        activeFlags.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
    }

    @inline(__always)
    private static func finite(_ value: Float, floor: Float) -> Float {
        value.isFinite ? max(value, floor) : floor
    }

    /// dB -> linear power. 10^(dB/10) = 2^(dB * log2(10) / 10).
    @inline(__always)
    private static func power(_ db: Float) -> Double {
        let clamped = db.isFinite ? max(db, -200) : -200
        return Double(exp2(clamped * 0.332_192_81))
    }

    /// Linear power -> dB.
    @inline(__always)
    private static func decibels(_ power: Double) -> Float {
        guard power > 0, power.isFinite else { return SpectrumReading.floorDB }
        return Float(log2(power)) * 3.010_3
    }
}
