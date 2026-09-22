import Foundation
import JoseonCore

// The session timeline, CPU side: what of a `SessionSnapshot` a window of N seconds shows. No drawing here, so the numbers
// (runs, spans, gaps, statistics, the sample under a time) can be tested without a Metal device.
//
// Two clocks. `SessionSample.time` is AUDIO time: it stands still while no audio arrives. `SessionSample.date` is the wall
// clock. The x axis is audio time (one second of music = the same width everywhere); the labels are wall-clock times looked
// up from the samples. Where the wall clock jumps between two neighbor samples the axis carries a gap mark.
//
// A sample stands for the second of audio that ENDS at its `time` (the recorder writes it when the second is complete), so
// an event belongs to the first sample whose time is not before the event's time.

struct TimelineModel {
    /// A stress flag from raise to clear.
    struct Span: Equatable {
        var start: Double
        var end: Double
        var title: String
        var flagID: String
        /// Row of the span bar, 0 = top. Overlapping spans stack. Rows from `maxSpanRows` on are not drawn, only counted.
        var row: Int
        /// Still raised at the newest sample.
        var isOpen: Bool
    }

    /// The wall clock jumped between two neighbor samples: no audio arrived for a while (pause, or silence that stops the clock).
    struct Gap: Equatable {
        /// Audio time of the gap (between the two samples).
        var time: Double
        /// Wall seconds that the audio clock did not count.
        var skippedSeconds: Double
        /// Index (into `samples`) of the first sample after the gap.
        var sampleAfter: Int
    }

    struct Statistics: Equatable {
        /// 10th and 95th percentile of the short-term loudness of the seconds with signal (the percentiles of EBU loudness
        /// range): "mostly between". Nil with no measured second.
        var shortTermLow: Float?
        var shortTermHigh: Float?
        var momentaryMax: Float?
        var truePeakMax: Float?
        var levelAMax: Float?
        /// Seconds that carry a clip event, and the sum of their counts.
        var clipEvents = 0
        var clippedRuns = 0
        var overs = 0
        var flags = 0
        var tracks = 0
    }

    static let maxSpanRows = 3
    /// A wall-clock step between neighbor samples that is this much longer than the audio step is a gap.
    static let gapThreshold = 2.0

    let windowSeconds: Double
    /// The samples inside the window, oldest first.
    let samples: [SessionSample]
    /// The events inside the window (time > the left edge), oldest first.
    let events: [SessionEvent]
    let newestTime: Double
    let spans: [Span]
    /// Spans that found no row (more than `maxSpanRows` at once).
    let hiddenSpans: Int
    /// Rows in use, 0...maxSpanRows.
    let spanRows: Int
    let silences: [ClosedRange<Double>]
    let gaps: [Gap]
    let stats: Statistics
    let hasLevelA: Bool
    /// Event indices (into `events`) per sample index.
    private let eventsOfSample: [Int: [Int]]

    var isEmpty: Bool { samples.isEmpty }
    var oldestTime: Double { samples.first?.time ?? newestTime }
    var leftEdgeTime: Double { newestTime - windowSeconds }

    init(snapshot: SessionSnapshot, windowSeconds w: Int) {
        let window = Double(max(w, 10))
        windowSeconds = window
        let all = snapshot.samples
        let newest = all.last?.time ?? 0
        newestTime = newest
        let left = newest - window
        // First sample inside the window.
        var lo = 0, hi = all.count
        while lo < hi { let m = (lo + hi) / 2; if all[m].time > left { hi = m } else { lo = m + 1 } }
        let visible = Array(all[lo...])
        samples = visible
        hasLevelA = visible.contains { $0.levelA != nil }

        // ---- Stress spans: over the WHOLE record, so a flag raised before the window still shows, then cut to the window.
        var open: [String: (start: Double, title: String)] = [:]
        var raw: [(start: Double, end: Double, title: String, id: String, open: Bool)] = []
        let recordStart = all.first?.time ?? 0
        for e in snapshot.events {
            let key = e.detail.isEmpty ? e.label : e.detail
            switch e.kind {
            case .stressFlagRaised:
                if open[key] == nil { open[key] = (e.time, e.label) }
            case .stressFlagCleared:
                // A clear without its raise: the raise is older than the record.
                let o = open.removeValue(forKey: key) ?? (recordStart, e.label)
                raw.append((o.start, e.time, o.title.isEmpty ? e.label : o.title, key, false))
            default: break
            }
        }
        for (key, o) in open { raw.append((o.start, newest, o.title, key, true)) }
        raw = raw.filter { $0.end > left && $0.end >= $0.start }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var rowEnds: [Double] = []
        var placed: [Span] = []
        var hidden = 0
        for s in raw {
            var row = rowEnds.firstIndex { $0 <= s.start }
            if row == nil, rowEnds.count < Self.maxSpanRows { rowEnds.append(0); row = rowEnds.count - 1 }
            guard let r = row else { hidden += 1; continue }
            rowEnds[r] = s.end
            placed.append(Span(start: max(s.start, left), end: s.end, title: s.title, flagID: s.id, row: r, isOpen: s.open))
        }
        spans = placed
        hiddenSpans = hidden
        spanRows = rowEnds.count

        // ---- Events of the window, and which sample each belongs to.
        let inWindow = snapshot.events.filter { $0.time > left }
        events = inWindow
        var map: [Int: [Int]] = [:]
        if !visible.isEmpty {
            var si = 0
            for (ei, e) in inWindow.enumerated() {
                while si < visible.count - 1, visible[si].time < e.time - 1e-6 { si += 1 }
                map[si, default: []].append(ei)
            }
        }
        eventsOfSample = map

        // ---- Silence (the clock ran, the signal was digital silence) and gaps (the clock stood still).
        var sil: [ClosedRange<Double>] = []
        var gp: [Gap] = []
        var runStart: Double?
        for (i, s) in visible.enumerated() {
            if s.isSilent {
                if runStart == nil { runStart = s.time - 1 }
            } else if let r = runStart {
                sil.append(max(r, left)...visible[i - 1].time); runStart = nil
            }
            if i > 0 {
                let p = visible[i - 1]
                let skipped = s.date.timeIntervalSince(p.date) - (s.time - p.time)
                if skipped > Self.gapThreshold { gp.append(Gap(time: (p.time + s.time) / 2, skippedSeconds: skipped, sampleAfter: i)) }
            }
        }
        if let r = runStart, let last = visible.last { sil.append(max(r, left)...last.time) }
        silences = sil
        gaps = gp

        // ---- Statistics of the window.
        var st = Statistics()
        var shortTerm: [Float] = []
        shortTerm.reserveCapacity(visible.count)
        for s in visible where !s.isSilent {
            if Self.isMeasured(s.shortTermLUFS) { shortTerm.append(s.shortTermLUFS) }
            if Self.isMeasured(s.momentaryMaxLUFS) { st.momentaryMax = max(st.momentaryMax ?? -.infinity, s.momentaryMaxLUFS) }
            if Self.isMeasured(s.truePeakDBTP) { st.truePeakMax = max(st.truePeakMax ?? -.infinity, s.truePeakDBTP) }
            if let a = s.levelA, a > SPLReading.floorDB { st.levelAMax = max(st.levelAMax ?? -.infinity, a) }
        }
        if !shortTerm.isEmpty {
            shortTerm.sort()
            st.shortTermLow = shortTerm[Int((Float(shortTerm.count - 1) * 0.10).rounded())]
            st.shortTermHigh = shortTerm[Int((Float(shortTerm.count - 1) * 0.95).rounded())]
        }
        for e in inWindow {
            switch e.kind {
            case .clip: st.clipEvents += 1; st.clippedRuns += max(Int(e.value.rounded()), 1)
            case .interSampleOver: st.overs += 1
            case .trackStart: st.tracks += 1
            default: break
            }
        }
        st.flags = placed.count + hidden
        stats = st
    }

    /// A loudness or level number that is a measurement (not the floor, not NaN).
    static func isMeasured(_ v: Float) -> Bool { v.isFinite && v > -119 }

    // MARK: Lookup

    /// Index of the sample nearest to an audio time. Nil with no samples, or when the time is more than `tolerance` seconds
    /// outside the recorded samples.
    func sampleIndex(atTime t: Double, tolerance: Double = 2) -> Int? {
        guard let first = samples.first, let last = samples.last else { return nil }
        guard t >= first.time - 1 - tolerance, t <= last.time + tolerance else { return nil }
        var lo = 0, hi = samples.count - 1
        while lo < hi { let m = (lo + hi) / 2; if samples[m].time < t { lo = m + 1 } else { hi = m } }
        // `lo` = the first sample that ends at or after `t`: the second that contains `t`.
        return lo
    }

    func events(ofSample i: Int) -> [SessionEvent] { (eventsOfSample[i] ?? []).map { events[$0] } }

    /// The flags that were up during the second of sample `i`.
    func spans(atSample i: Int) -> [Span] {
        guard samples.indices.contains(i) else { return [] }
        let t = samples[i].time
        return spans.filter { $0.start <= t && $0.end > t - 1 }
    }

    func isInSilence(_ i: Int) -> Bool { samples.indices.contains(i) && samples[i].isSilent }

    /// The gap that ends at sample `i` (the first sample after a pause).
    func gap(before i: Int) -> Gap? { gaps.first { $0.sampleAfter == i } }

    // MARK: Wall-clock marks

    struct MinuteMark: Equatable {
        var time: Double      // audio time, for x
        var date: Date        // the round minute
    }

    /// The round minutes (multiples of `stepMinutes` on the local clock) that fall on recorded audio, with their audio time.
    /// A round minute inside a gap has no place on the axis and is left out.
    func minuteMarks(stepMinutes: Int, timeZone: TimeZone) -> [MinuteMark] {
        guard let first = samples.first, let last = samples.last, stepMinutes > 0 else { return [] }
        let step = Double(stepMinutes * 60)
        let offset = Double(timeZone.secondsFromGMT(for: last.date))
        var local = ((first.date.timeIntervalSince1970 - 1 + offset) / step).rounded(.up) * step
        let end = last.date.timeIntervalSince1970 + offset
        var out: [MinuteMark] = []
        var i = 0
        while local <= end + 0.001, out.count < 64 {
            let target = local - offset
            while i < samples.count - 1, samples[i].date.timeIntervalSince1970 < target { i += 1 }
            // samples[i] is the first sample that ends at or after the minute. The minute has a place on the axis when it lies
            // inside that sample's own second; a minute inside a pause lies before the second of the sample after the pause.
            let d = samples[i].date.timeIntervalSince1970 - target
            if d >= -0.001, d <= 1.001 { out.append(MinuteMark(time: samples[i].time - d, date: Date(timeIntervalSince1970: target))) }
            local += step
        }
        return out
    }

    // MARK: Text

    /// "last 15 minutes: short-term mostly −18 to −9 LUFS, 3 clip events, 2 stress flags".
    var accessibilityValue: String {
        let minutes = Int((windowSeconds / 60).rounded())
        let head = "last \(minutes) minute\(minutes == 1 ? "" : "s")"
        guard !isEmpty else { return head + ": nothing recorded yet" }
        var parts: [String] = []
        if let lo = stats.shortTermLow, let hi = stats.shortTermHigh {
            parts.append("short-term mostly \(Fmt.number(lo, digits: 0)) to \(Fmt.number(hi, digits: 0)) LUFS")
        } else {
            parts.append("no loudness measured")
        }
        if let tp = stats.truePeakMax { parts.append("true peak max \(Fmt.number(tp, digits: 1, signed: true)) dBTP") }
        if let a = stats.levelAMax { parts.append("at the ear up to about \(Fmt.number(a, digits: 0)) dB(A)") }
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        parts.append(count(stats.clipEvents, "second with clipped samples", "seconds with clipped samples"))
        if stats.overs > 0 { parts.append(count(stats.overs, "true-peak over", "true-peak overs")) }
        parts.append(count(stats.flags, "stress flag", "stress flags"))
        if stats.tracks > 0 { parts.append(count(stats.tracks, "track start", "track starts")) }
        if !gaps.isEmpty { parts.append(count(gaps.count, "pause", "pauses")) }
        return head + ": " + parts.joined(separator: ", ")
    }
}

enum TimelineFormat {
    /// "21:42" or "21:42:07" on the local 24 h clock.
    static func clock(_ date: Date, seconds: Bool, timeZone: TimeZone) -> String {
        let local = Int((date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))).rounded(.down))
        let day = ((local % 86_400) + 86_400) % 86_400
        let h = day / 3600, m = day % 3600 / 60, s = day % 60
        return seconds ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", h, m)
    }

    /// "now", "−42 s", "−3:12".
    static func ago(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s <= 0 { return "now" }
        if s < 60 { return "\(Fmt.minus)\(s) s" }
        return "\(Fmt.minus)\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// "20 s", "3:08".
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s) s" : "\(s / 60):" + String(format: "%02d", s % 60) + " min"
    }
}
