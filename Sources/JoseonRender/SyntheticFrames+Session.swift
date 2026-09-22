import Foundation
import JoseonCore

// A believable session record for the demo mode, the tests and the design review. Made-up numbers, never shown as a
// measurement of real audio: the app uses it only in its demo mode.

extension SyntheticFrames {
    /// End of the demo session when the caller gives none: a fixed moment, so pictures and tests repeat exactly.
    public static let demoSessionEnd = Date(timeIntervalSince1970: 1_790_019_900)   // 45 minutes past a round hour (UTC)

    /// A record of `minutes` of listening: four tracks with different loudness and dynamics (a loud pop master, a quiet
    /// acoustic piece, a bass-heavy electronic track, a rock track), two clip bursts, one inter-sample over, a sub-bass
    /// stress flag (with a treble flag over part of it, and a short return later), one 20 s digital silence between tracks two
    /// and three, and one pause of about three minutes before track four (the audio clock stands still, the wall clock jumps).
    /// Deterministic. `includeLevelA` adds the level at the ear (a calibrated headphone). The newest sample is at `endingAt`.
    public static func demoSession(minutes: Int, includeLevelA: Bool = true, endingAt: Date? = nil) -> SessionSnapshot {
        let total = max(minutes, 1) * 60
        let end = endingAt ?? demoSessionEnd
        let n = Double(total)

        struct Track {
            var start: Int; var level: Float; var dynamics: Float; var crest: Float; var ceiling: Float
            var correlation: Float; var tilt: [Float]
        }
        // Band tilt, dB relative to the short-term loudness: sub, bass, low mid, mid, upper mid, presence, brilliance, air.
        let silenceStart = Int(n * 0.50), silenceLength = min(20, total / 8)
        let tracks = [
            Track(start: 0, level: -9.5, dynamics: 1.2, crest: 9.6, ceiling: -0.1, correlation: 0.55, tilt: [-10, -4, -9, -11, -15, -19, -22, -30]),
            Track(start: Int(n * 0.247), level: -20, dynamics: 5.0, crest: 15, ceiling: -3, correlation: 0.82, tilt: [-30, -10, -6, -5, -12, -18, -24, -34]),
            Track(start: silenceStart + silenceLength, level: -12.5, dynamics: 2.4, crest: 10.5, ceiling: -0.3, correlation: 0.35, tilt: [-2, -3, -13, -14, -18, -21, -22, -27]),
            Track(start: Int(n * 0.76), level: -11, dynamics: 3.2, crest: 10, ceiling: -0.2, correlation: 0.62, tilt: [-16, -6, -7, -6, -9, -13, -19, -29]),
        ]
        let pauseAt = tracks[3].start                 // the pause stands before track four
        let pauseSeconds = 190.0

        // Smooth value noise, -1...1.
        func hash(_ i: Int, _ channel: Int) -> Float {
            var x = UInt64(bitPattern: Int64(i &* 73_856_093 ^ channel &* 19_349_663)) &+ 0x9E37_79B9_7F4A_7C15
            x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
            x ^= x >> 31
            return Float(x & 0xFFFF) / 32_767.5 - 1
        }
        func noise(_ t: Double, period: Double, channel: Int) -> Float {
            let u = t / period
            let i = Int(u.rounded(.down))
            let f = Float(u - Double(i))
            let s = f * f * (3 - 2 * f)
            return hash(i, channel) * (1 - s) + hash(i + 1, channel) * s
        }

        // Events by the second they belong to.
        let clipBursts: [(start: Int, counts: [Float])] = [
            (Int(n * 0.147), [3, 11, 19, 7, 2]),
            (Int(n * 0.89), [5, 14, 4]),
        ]
        let overAt = Int(n * 0.201)
        let flags: [(id: String, title: String, from: Int, to: Int)] = [
            ("sub-bass", "Strong sub-bass in the signal", Int(n * 0.573), Int(n * 0.71)),
            ("treble-peak", "Treble peak over the target", Int(n * 0.668), Int(n * 0.735)),
            ("sub-bass", "Strong sub-bass in the signal", Int(n * 0.843), Int(n * 0.873)),
        ]

        var samples: [SessionSample] = []
        samples.reserveCapacity(total)
        var events: [SessionEvent] = []
        var nextID = 1
        let wallLength = n + (pauseAt > 0 && pauseAt < total ? pauseSeconds : 0)
        let startDate = end.addingTimeInterval(-wallLength)

        func add(_ kind: SessionEvent.Kind, _ time: Double, _ date: Date, label: String = "", detail: String = "", value: Float = 0) {
            events.append(SessionEvent(id: nextID, kind: kind, time: time, date: date, label: label, detail: detail, value: value))
            nextID += 1
        }

        for k in 0..<total {
            let time = Double(k + 1)                                    // the second that ends here
            let wall = time + (k >= pauseAt && pauseAt > 0 ? pauseSeconds : 0)
            let date = startDate.addingTimeInterval(wall)
            let eventTime = time - 0.5
            let eventDate = date.addingTimeInterval(-0.5)
            let silent = k >= silenceStart && k < silenceStart + silenceLength
            // Starts happen just inside the second they open.
            let startTime = time - 0.98, startDate = date.addingTimeInterval(-0.98)
            if k == silenceStart { add(.silenceStart, startTime, startDate) }
            if k == silenceStart + silenceLength { add(.silenceEnd, startTime, startDate) }

            let ti = tracks.lastIndex { $0.start <= k } ?? 0
            let tr = tracks[ti]
            if k == tr.start { add(.trackStart, startTime, startDate) }
            if silent {
                samples.append(SessionSample(time: time, date: date, momentaryMaxLUFS: LoudnessReading.silenceLUFS, shortTermLUFS: LoudnessReading.silenceLUFS,
                                             truePeakDBTP: -120, correlation: 0, bands: [Float](repeating: -120, count: 8), levelA: includeLevelA ? SPLReading.floorDB : nil, isSilent: true))
                continue
            }
            let into = Double(k - tr.start)
            let trackEnd = ti + 1 < tracks.count ? (ti == 1 ? silenceStart : tracks[ti + 1].start) : total
            let left = Double(trackEnd - k)
            // Song form: a quieter intro and a bridge at two thirds, a short fade at the end.
            let length = Double(trackEnd - tr.start)
            var form: Float = 0
            if into < 18 { form -= Float(18 - into) / 18 * (2 + tr.dynamics) }
            let bridge = abs(into - length * 0.64) / max(length * 0.06, 1)
            if bridge < 1 { form -= Float(1 - bridge) * tr.dynamics * 1.6 }
            if left < 7 { form -= Float(7 - left) * 2.2 }
            let slow = noise(time, period: 37, channel: ti) * tr.dynamics * 0.55 + noise(time, period: 9, channel: ti + 10) * tr.dynamics * 0.3
            let shortTerm = tr.level + form + slow
            let momentary = shortTerm + 1.4 + abs(noise(time, period: 2.3, channel: ti + 20)) * (1.2 + tr.dynamics * 0.5)
            var peak = min(momentary + tr.crest + noise(time, period: 1.7, channel: ti + 30) * 1.3, tr.ceiling - abs(noise(time, period: 1.1, channel: 40)) * 0.25)

            for b in clipBursts where k >= b.start && k < b.start + b.counts.count {
                peak = 0
                add(.clip, eventTime, eventDate, value: b.counts[k - b.start])
            }
            if k == overAt {
                peak = 0.4
                add(.interSampleOver, eventTime, eventDate, value: peak)
            }
            for f in flags {
                if k == f.from { add(.stressFlagRaised, eventTime, eventDate, label: f.title, detail: f.id) }
                if k == f.to { add(.stressFlagCleared, eventTime, eventDate, label: f.title, detail: f.id) }
            }
            var bands = tr.tilt.enumerated().map { i, tilt in shortTerm + tilt + noise(time, period: 5 + Double(i) * 1.7, channel: 50 + i) * 2.5 }
            // The sub-bass swells where its flag is up.
            if flags.contains(where: { $0.id == "sub-bass" && k >= $0.from && k < $0.to }) { bands[0] += 5 }
            let correlation = min(max(tr.correlation + noise(time, period: 13, channel: 60 + ti) * 0.22, -1), 1)
            let levelA: Float? = includeLevelA ? shortTerm + demoSPLOffsetDB + noise(time, period: 6, channel: 70) * 0.8 : nil
            samples.append(SessionSample(time: time, date: date, momentaryMaxLUFS: momentary, shortTermLUFS: shortTerm, truePeakDBTP: peak,
                                         correlation: correlation, bands: bands, levelA: levelA, isSilent: false))
        }
        events.sort { ($0.time, $0.id) < ($1.time, $1.id) }
        return SessionSnapshot(samples: samples, events: events, revision: samples.count + events.count)
    }
}
