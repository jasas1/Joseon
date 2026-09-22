import SwiftUI
import AppKit
import JoseonCore

/// The one way the app prints a frequency: one decimal under 1 kHz, `x.xx kHz` from 1 kHz up.
/// The analyzer does not resolve more, so more digits would claim a precision it does not have.
enum FrequencyText {
    static func format(_ hz: Float) -> String {
        guard hz.isFinite, hz > 0 else { return "—" }
        // 999.96 Hz rounds to "1000.0 Hz": switch to kHz at the rounded value.
        if (hz * 10).rounded() / 10 >= 1000 { return String(format: "%.2f kHz", hz / 1000) }
        return String(format: "%.1f Hz", hz)
    }

    static func spoken(_ hz: Float) -> String {
        guard hz.isFinite, hz > 0 else { return "no value" }
        if (hz * 10).rounded() / 10 >= 1000 { return String(format: "%.2f kilohertz", hz / 1000) }
        return String(format: "%.1f hertz", hz)
    }
}

/// Estimated level at the ear of one track. Only there when the playback chain was calibrated.
struct TrackSPL: Equatable {
    /// A-weighted equivalent level of the track, diffuse-field equivalent, dB SPL.
    var leqA: Float
    /// Highest fast A-level of the track.
    var maxA: Float
    var uncertaintyDB: Float
}

/// The measurement of one track: from a reset to the next reset. It lives in memory only.
/// Joseon cannot know track titles, so a summary is labelled by its time.
struct TrackSummary: Identifiable, Equatable {
    let id = UUID()
    var start: Date
    var end: Date
    /// The app that played, for example "Qobuz". Empty when unknown.
    var source: String
    var integratedLUFS: Float
    var loudnessRangeLU: Float
    var plrDB: Float
    var truePeakMaxDBTP: Float
    var clipCount: Int
    /// Seconds of audio in the measurement.
    var durationSeconds: Double
    /// 0 = unknown.
    var lowestStrongHz: Float
    /// Nil when the level at the ear was not calibrated while the track played.
    var spl: TrackSPL?

    init?(loudness: LoudnessReading, start: Date, end: Date, source: String, lowestStrongHz: Float, spl: TrackSPL? = nil) {
        guard loudness.isIntegratedValid else { return nil }
        self.start = start
        self.end = end
        self.source = source
        integratedLUFS = loudness.integratedLUFS
        loudnessRangeLU = loudness.loudnessRangeLU
        plrDB = loudness.plrDB
        truePeakMaxDBTP = loudness.truePeakMaxDBTP
        clipCount = loudness.clipCount
        durationSeconds = loudness.measuredSeconds
        self.lowestStrongHz = lowestStrongHz
        self.spl = spl
    }

    // MARK: Text

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// "21:04": the start time labels the track.
    var timeText: String { Self.clock.string(from: start) }
    var sourceText: String { source.isEmpty ? "—" : source }
    /// "3:42", "1:02:07".
    var durationText: String {
        let s = Int(durationSeconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    var integratedText: String { Self.signed(integratedLUFS) }
    var rangeText: String { NumberText.signed(loudnessRangeLU) }
    var plrText: String { NumberText.signed(plrDB) }
    var truePeakText: String { truePeakMaxDBTP <= -119 ? "—" : Self.signed(truePeakMaxDBTP, plus: true) }
    var clipText: String { String(clipCount) }
    var lowestText: String { FrequencyText.format(lowestStrongHz) }
    var isOver: Bool { truePeakMaxDBTP > -1 }
    /// Whole dB with "≈": an estimate.
    var leqAText: String { spl.map { "≈ \(Int($0.leqA.rounded()))" } ?? "—" }
    var maxAText: String { spl.map { "≈ \(Int($0.maxA.rounded()))" } ?? "—" }
    /// "Level at the ear ≈ 76 dB(A) LAeq · max ≈ 84 · ± 2 dB"
    var splLine: String? {
        spl.map { "At the ear \(leqAText) dB(A) LAeq · max \(maxAText) · ± \(NumberText.signed($0.uncertaintyDB, decimals: 0)) dB" }
    }

    /// A real minus sign, one decimal.
    static func signed(_ value: Float, plus: Bool = false) -> String {
        NumberText.signed(value, plus: plus)
    }

    /// One line for tooltips: "I −11.5 LUFS · LRA 6.2 LU · PLR 10.4 dB".
    var oneLine: String { "I \(integratedText) LUFS · LRA \(rangeText) LU · PLR \(plrText) dB · TP \(truePeakText) dBTP" }

    var spoken: String {
        var s = "Track at \(timeText), \(sourceText), duration \(durationText). Integrated \(integratedText) LUFS, loudness range \(rangeText) LU, "
            + "peak to loudness ratio \(plrText) dB, true peak maximum \(truePeakText) dB TP, \(clipCount) clips"
        if lowestStrongHz > 0 { s += ", lowest strong content \(FrequencyText.spoken(lowestStrongHz))" }
        if let spl {
            s += ". Estimated level at the ear: average about \(Int(spl.leqA.rounded())) dB A, maximum about \(Int(spl.maxA.rounded())) dB A, plus or minus \(Int(spl.uncertaintyDB.rounded())) dB"
        }
        return s + "."
    }

    static let columns = ["Time", "Source", "Duration", "I (LUFS)", "LRA (LU)", "PLR (dB)", "TP max (dBTP)", "Clips", "Lowest strong"]
    /// The two columns a calibrated session adds.
    static let splColumns = ["LAeq (dB)", "LAmax (dB)"]
    var cells: [String] { [timeText, sourceText, durationText, integratedText, rangeText, plrText, truePeakText, clipText, lowestText] }
    var splCells: [String] { [leqAText, maxAText] }

    static func columns(withSPL: Bool) -> [String] { withSPL ? columns + splColumns : columns }
    func cells(withSPL: Bool) -> [String] { withSPL ? cells + splCells : cells }

    /// Tab-separated table for the clipboard, newest first. `current` leads when it has a value.
    /// The level columns are there when at least one track has a calibrated level.
    static func clipboardText(current: TrackSummary?, history: [TrackSummary]) -> String {
        let all = (current.map { [$0] } ?? []) + history
        let withSPL = all.contains { $0.spl != nil }
        var lines = [(["Track"] + columns(withSPL: withSPL)).joined(separator: "\t")]
        if let current { lines.append((["This track"] + current.cells(withSPL: withSPL)).joined(separator: "\t")) }
        for (index, track) in history.enumerated() {
            lines.append(([index == 0 ? "Last track" : "Track \(NumberText.signed(-(index + 1)))"] + track.cells(withSPL: withSPL)).joined(separator: "\t"))
        }
        if withSPL, let u = all.compactMap({ $0.spl?.uncertaintyDB }).max() {
            lines.append("LAeq and LAmax: estimated level at the ear in dB(A), diffuse-field equivalent, ± \(NumberText.signed(u, decimals: 0)) dB (depends on the calibration).")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Session popover

/// Header button that opens the session popover.
struct SessionButton: View {
    @ObservedObject var model: AppModel
    var showsTitle: Bool
    @State private var isOpen = false

    private var helpText: String {
        if let last = model.trackHistory.first { return "Session: per-track summaries. Last track (\(last.timeText)): \(last.oneLine)" }
        return "Session: per-track summaries (integrated loudness, range, PLR, true peak, clips)"
    }

    var body: some View {
        Button(action: { isOpen.toggle() }) {
            if showsTitle {
                Label("Session", systemImage: "list.bullet.rectangle")
            } else {
                Image(systemName: "list.bullet.rectangle")
            }
        }
        .fixedSize()
        .help(helpText)
        .accessibilityLabel("Session")
        .accessibilityValue(model.trackHistory.isEmpty ? "No finished track" : "\(model.trackHistory.count) finished tracks")
        .accessibilityHint("Shows the per-track summaries")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SessionView(model: model)
        }
    }
}

/// "This track" and "Last track" as two compact cards, then the table of the last 20 tracks, newest first,
/// then the events of the session record, newest first. One source of truth for clips: cards, table and events all
/// come from the `LoudnessReading.clipCount` of the engine (the events are its growth per second). The record is
/// the one the engine made, also in a snapshot run: the made-up record of the review pictures never gets in here.
struct SessionView: View {
    @ObservedObject var model: AppModel
    /// False in snapshot mode: draw once from the values of this moment, without a timer.
    var isLive = true
    @State private var copied = false

    var body: some View {
        if !isLive {
            content(current: model.currentTrackSummary(), events: SessionEventList.rows(from: model.recordedSessionProvider()))
        } else {
            // Read the engine and the session record once per second, only while the popover is open.
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { _ in
                content(current: model.currentTrackSummary(), events: SessionEventList.rows(from: model.recordedSessionProvider()))
            }
        }
    }

    private func content(current: TrackSummary?, events: [SessionEventRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Session").font(.headline)
                Spacer()
                Text("In memory only. Joseon never writes audio, summaries or events to disk.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 10) {
                TrackCard(title: "This track", track: current,
                          empty: "No measurement yet. It starts with the audio.")
                TrackCard(title: "Last track", track: model.trackHistory.first,
                          empty: model.settings.autoResetAfterSilence
                              ? "A track ends when audio resumes after more than 2 s of silence, or when you reset."
                              : "A track ends when you reset the measurement.")
            }
            // The cards keep their full height: the table below is the part that gives way.
            .fixedSize(horizontal: false, vertical: true)
            if !model.trackHistory.isEmpty {
                table
            }
            eventList(events)
            HStack {
                Button(copied ? "Copied" : "Copy as Text") {
                    var text = TrackSummary.clipboardText(current: current, history: model.trackHistory)
                    if !events.isEmpty { text += "\n" + SessionEventList.clipboardText(events) }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .disabled(current == nil && model.trackHistory.isEmpty && events.isEmpty)
                .help("Copy the tracks and the events as tab-separated text")
                Button("Clear") { model.clearTrackHistory() }
                    .disabled(model.trackHistory.isEmpty)
                    .help("Forget the finished tracks")
                Spacer()
                Text("Tracks are labelled by time: Joseon cannot read track titles.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: showsSPL ? 760 : 640)
    }

    /// The level columns show when a finished track has a calibrated level.
    private var showsSPL: Bool { model.trackHistory.contains { $0.spl != nil } }

    private var table: some View {
        ScrollView(.vertical) {
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    ForEach(Array(TrackSummary.columns(withSPL: showsSPL).enumerated()), id: \.offset) { index, title in
                        Text(title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(index < 2 ? .leading : .trailing)
                    }
                }
                .accessibilityHidden(true)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(model.trackHistory) { track in
                    GridRow {
                        ForEach(Array(track.cells(withSPL: showsSPL).enumerated()), id: \.offset) { index, cell in
                            Text(cell)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(color(for: track, column: index))
                                .lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(track.spoken)
                }
            }
            .padding(.vertical, 2)
        }
        // A scroll view takes all the height it is offered: give it the height of its rows, so the events list
        // below stands directly under the table.
        .frame(height: min(240, 24 + 20 * CGFloat(model.trackHistory.count)))
        .accessibilityLabel("Finished tracks, newest first")
    }

    /// The events of the session record, newest first, at most `SessionEventList.limit`.
    private func eventList(_ events: [SessionEventRow]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("EVENTS").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                Text("last \(model.engine.session.capacitySeconds / 60) minutes, newest first").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            if events.isEmpty {
                Text("No events yet. Track starts, clips, inter-sample overs, stress flags and silences show here.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(events) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(event.timeText).foregroundStyle(.secondary)
                                Text(event.text).foregroundStyle(event.isAlert ? Color.joseonDanger : Color.primary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 12).monospacedDigit())
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(event.spoken)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: min(154, 19 * CGFloat(events.count) + 2))
                .accessibilityLabel("Events, newest first")
            }
        }
    }

    private func color(for track: TrackSummary, column: Int) -> Color {
        if column == 6, track.isOver { return .joseonDanger }
        if column == 7, track.clipCount > 0 { return .joseonDanger }
        return column < 2 ? Color.secondary : Color.primary
    }
}

/// One track as labelled numbers.
struct TrackCard: View {
    var title: String
    var track: TrackSummary?
    var empty: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                if let track {
                    Text("\(track.timeText) · \(track.sourceText) · \(track.durationText)")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let track {
                HStack(alignment: .top, spacing: 0) {
                    number("I", track.integratedText, "LUFS")
                    number("LRA", track.rangeText, "LU")
                    number("PLR", track.plrText, "dB")
                    number("TP MAX", track.truePeakText, "dBTP", color: track.isOver ? .joseonDanger : nil)
                }
                HStack(spacing: 12) {
                    Text("Clips \(track.clipText)")
                        .foregroundStyle(track.clipCount > 0 ? Color.joseonDanger : Color.secondary)
                    if track.lowestStrongHz > 0 {
                        Text("Lowest strong content \(track.lowestText)").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                if let splLine = track.splLine {
                    Text(splLine).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(empty).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.joseonPanel))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: Palette.cardBorder), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(track?.spoken ?? empty)
    }

    private func number(_ label: String, _ value: String, _ unit: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .medium).monospacedDigit()).foregroundStyle(color ?? Color.primary)
            Text(unit).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
