import Foundation
import JoseonCore

/// One line of the "Events" list in the session popover: a moment of the session record in plain words.
struct SessionEventRow: Identifiable, Equatable {
    let id: Int
    /// Wall-clock time with seconds, for example "21:42:07".
    var timeText: String
    /// "Clips ×12", "Inter-sample over +0.7 dBTP", "Strong sub-bass in the signal — raised", "Track start", "Silence 0:20".
    var text: String
    /// Clips and overs read in the danger color.
    var isAlert: Bool

    var spoken: String { "\(timeText), \(text.replacingOccurrences(of: "×", with: "times "))" }
}

/// The events of a `SessionSnapshot` as rows, newest first. The record lives in memory only, and so do the rows.
enum SessionEventList {
    static let limit = 50

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    static func rows(from snapshot: SessionSnapshot, limit: Int = SessionEventList.limit) -> [SessionEventRow] {
        var rows: [SessionEventRow] = []
        /// Index in `rows` of a silence that has no end yet.
        var openSilence: (row: Int, start: Date)?
        for event in snapshot.events {           // oldest first
            var text: String
            var isAlert = false
            switch event.kind {
            case .trackStart:
                text = "Track start"
            case .clip:
                // The same word and the same unit as the track cards and the table ("Clips"): one clip = one run of
                // full-scale samples, as `LoudnessReading.clipCount` counts them.
                text = "Clips ×\(clipRuns(event))"
                isAlert = true
            case .interSampleOver:
                text = "Inter-sample over \(NumberText.signed(event.value, plus: true)) dBTP"
                isAlert = true
            case .stressFlagRaised:
                text = "\(flagTitle(event)) — raised"
            case .stressFlagCleared:
                text = "\(flagTitle(event)) — cleared"
            case .silenceStart:
                text = "Silence started"
                openSilence = (rows.count, event.date)
            case .silenceEnd:
                // One row for the whole silence, at its start, with its length on the wall clock
                // (the audio clock can stand still while nothing plays).
                if let open = openSilence {
                    rows[open.row].text = "Silence \(duration(event.date.timeIntervalSince(open.start)))"
                    openSilence = nil
                    continue
                }
                text = "Silence ended"
            }
            rows.append(SessionEventRow(id: event.id, timeText: clock.string(from: event.date), text: text, isAlert: isAlert))
        }
        return Array(rows.reversed().prefix(limit))
    }

    static func clipRuns(_ event: SessionEvent) -> Int { max(Int(event.value.rounded()), 1) }

    /// Clips of all clip events from `start` on (nil = all). The self-check compares it with a track summary.
    static func clipTotal(in snapshot: SessionSnapshot, from start: Date? = nil, to end: Date? = nil) -> Int {
        snapshot.events.filter { event in
            event.kind == .clip && event.date >= (start ?? .distantPast) && event.date <= (end ?? .distantFuture)
        }.reduce(0) { $0 + clipRuns($1) }
    }

    private static func flagTitle(_ event: SessionEvent) -> String {
        event.label.isEmpty ? "Stress flag" : event.label
    }

    /// "0:20", "3:10", "1:02:07".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds.rounded()), 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Tab-separated lines for the clipboard, under the track table.
    static func clipboardText(_ rows: [SessionEventRow]) -> String {
        guard !rows.isEmpty else { return "" }
        return (["Events (newest first)", "Time\tEvent"] + rows.map { "\($0.timeText)\t\($0.text)" }).joined(separator: "\n") + "\n"
    }
}
