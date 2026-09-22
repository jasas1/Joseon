import Foundation
import Combine
import JoseonCore
import JoseonRender

/// One kept reference: the frozen summary. Its name is the time and the source (`21:42 · Qobuz`), or what the user
/// typed. A stored reference has NO letter: "A" is always the ACTIVE reference and "B" the live signal, everywhere.
struct ComparisonReference: Identifiable {
    var snapshot: ComparisonSnapshot
    var id: UUID { snapshot.id }

    /// `21:42`: the capture time. It stays when the user renames the reference.
    var clockText: String { ComparisonController.clock(snapshot.date) }
    /// `A · 21:42`: the header chip, for the ACTIVE reference only.
    var activeChipName: String { "A \u{00B7} \(clockText)" }
}

/// A/B compare: the references ("A") the live signal ("B") is drawn against.
///
/// - Memory only. Nothing here is written to disk, and no audio is kept: a reference is a `ComparisonSnapshot`
///   (long-term spectrum and measurement numbers).
/// - At most `limit` references, one of them active, or none.
/// - A measurement reset (also the automatic one at a track change) does NOT touch the references: nothing in
///   `AppModel.resetMeasurement` or `closeTrack` calls into this class.
/// - A finished track can not become a reference: its long-term spectrum is gone with the reset. Only the running
///   measurement (`engine.latestFrame`) can be captured, so the session popover offers no capture action.
final class ComparisonController: ObservableObject {
    static let limit = 4
    /// The long-term curve of a shorter measurement is not a fair reference.
    static let minimumSeconds: Double = 5

    /// Why "Capture reference" is off now.
    enum CaptureBlock: Equatable {
        /// No audio plays now.
        case silent
        /// The running measurement is shorter than `minimumSeconds`.
        case tooShort

        /// Short, beside the button.
        var reason: String {
            switch self {
            case .silent: return "needs music that plays now"
            case .tooShort: return "needs \(Int(ComparisonController.minimumSeconds)) s of music"
            }
        }
    }

    /// Why the difference lane can not show "Headphone".
    enum HeadphoneModeBlock: Equatable {
        case noReference
        case referenceHasNoHeadphone
        case noHeadphoneNow(reference: String)
        case sameHeadphone(String)

        var reason: String {
            switch self {
            case .noReference: return "It needs an active reference."
            case .referenceHasNoHeadphone: return "This reference was captured without a headphone."
            case .noHeadphoneNow(let reference): return "Pick a headphone to compare with \(reference)."
            case .sameHeadphone(let name): return "Same headphone as the reference (\(name)). Pick another headphone in the header."
            }
        }
    }

    /// Oldest first.
    @Published private(set) var references: [ComparisonReference] = []
    @Published private(set) var activeID: UUID?
    /// Nil = a capture is possible now. The app model's 10 Hz supervisor keeps it current.
    @Published private(set) var captureBlock: CaptureBlock? = .silent

    private let engine: AnalysisEngine
    private let settings: AppSettings
    /// The app that plays, or "Demo signal". The app model sets it.
    var sourceName: () -> String = { "" }

    init(engine: AnalysisEngine, settings: AppSettings) {
        self.engine = engine
        self.settings = settings
    }

    var active: ComparisonReference? { references.first { $0.id == activeID } }
    var canCapture: Bool { captureBlock == nil }

    // MARK: Capture

    static func captureBlock(for frame: AnalysisFrame) -> CaptureBlock? {
        if frame.isSilent { return .silent }
        if frame.loudness.measuredSeconds < minimumSeconds { return .tooShort }
        return nil
    }

    /// 10 Hz, main thread. Publishes only when the answer changes, so SwiftUI stays idle.
    func update(frame: AnalysisFrame) {
        let block = Self.captureBlock(for: frame)
        if block != captureBlock { captureBlock = block }
    }

    /// Keeps what plays now as a new reference and makes it the active one. The live frame, never the frozen one:
    /// a frozen display freezes the picture, the measurement goes on.
    @discardableResult
    func captureReference() -> ComparisonReference? {
        let frame = engine.latestFrame
        guard Self.captureBlock(for: frame) == nil else { return nil }
        let date = Date()
        makeRoom()
        let name = Self.defaultName(date: date, source: sourceName())
        var snapshot = ComparisonSnapshot.capture(from: frame, name: name, date: date)
        snapshot.tiltDBPerOctave = Float(settings.tiltDBPerOctave)
        let reference = ComparisonReference(snapshot: snapshot)
        references.append(reference)
        activeID = reference.id
        DebugLog.log("comparison: captured \(name), \(Int(snapshot.measuredSeconds)) s")
        return reference
    }

    /// `21:42 · Qobuz`: time and source, no letter.
    static func defaultName(date: Date, source: String) -> String {
        clock(date) + (source.isEmpty ? "" : " \u{00B7} \(source)")
    }

    /// With four references kept, the oldest one that is not active goes.
    private func makeRoom() {
        if references.count >= Self.limit, let index = references.firstIndex(where: { $0.id != activeID }) {
            references.remove(at: index)
        }
    }

    // MARK: List

    /// Nil = no comparison. The references stay.
    func setActive(_ id: UUID?) {
        guard id == nil || references.contains(where: { $0.id == id }) else { return }
        if activeID != id { activeID = id }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = references.firstIndex(where: { $0.id == id }) else { return }
        references[index].snapshot.name = String(trimmed.prefix(60))
    }

    func delete(_ id: UUID) {
        references.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
    }

    /// "Clear Active Reference": the active reference goes, the comparison ends.
    func clearActive() {
        if let id = activeID { delete(id) }
    }

    func clearAll() {
        references = []
        activeID = nil
    }

    // MARK: Difference lane mode

    /// Nil = the lane can show "Headphone": the active reference carries a headphone response, and the headphone
    /// of now is another one.
    func headphoneModeBlock(currentHeadphone: String?) -> HeadphoneModeBlock? {
        guard let snapshot = active?.snapshot else { return .noReference }
        guard let name = snapshot.headphoneName, snapshot.responseDB != nil else { return .referenceHasNoHeadphone }
        guard let currentHeadphone else { return .noHeadphoneNow(reference: name) }
        return currentHeadphone == name ? .sameHeadphone(name) : nil
    }

    /// What the spectrum gets: "Headphone" only while it is possible, else the signal difference.
    func effectiveMode(currentHeadphone: String?) -> ComparisonMode {
        wantsHeadphoneMode && headphoneModeBlock(currentHeadphone: currentHeadphone) == nil ? .headphone : .signal
    }

    /// The stored choice. A snapshot run can ask for headphone mode without a write to the user's settings.
    var wantsHeadphoneMode: Bool { settings.comparisonHeadphoneMode || Self.snapshotSeedMode == "headphone" }

    // MARK: Text

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    /// "62 s", "3 min 05 s": how much music a reference covers.
    static func durationText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s) s" : String(format: "%d min %02d s", s / 60, s % 60)
    }

    /// Second line of a list row: what the reference covers, and its headphone.
    static func detailText(_ snapshot: ComparisonSnapshot) -> String {
        var parts = [durationText(snapshot.measuredSeconds)]
        let integrated = snapshot.loudness.integratedLUFS
        if integrated.isFinite, integrated > -119 { parts.append("I \(NumberText.signed(integrated, plus: false)) LUFS") }
        parts.append(snapshot.headphoneName ?? "no headphone")
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Snapshot mode (layout review only)

/// SNAPSHOT MODE ONLY (JOSEON_SNAPSHOT_DIR), like `SnapshotOnlySessionSeed`: a snapshot run has one signal, so it has
/// nothing to compare. JOSEON_SNAPSHOT_COMPARE picks a MADE-UP reference from `SyntheticFrames.demoComparison`
/// (the live long-term curve, reshaped like another master: brighter, 2 dB quieter), so the review pictures show
/// the feature. A normal run (also demo mode) never sees it.
///   unset / "off"   no reference
///   "1" / "signal"  a reference with the headphone of now: the lane shows the signal difference
///   "headphone"     a reference with another (made-up) headphone, the lane in headphone mode
extension ComparisonController {
    static var snapshotSeedMode: String? {
        guard DebugSnapshot.directory != nil,
              let raw = ProcessInfo.processInfo.environment["JOSEON_SNAPSHOT_COMPARE"], !raw.isEmpty, raw != "off", raw != "0" else { return nil }
        return raw == "headphone" ? "headphone" : "signal"
    }

    /// Adds a made-up reference and makes it active. `headphone` nil = the headphone of the frame.
    @discardableResult
    func addSnapshotOnlySeed(headphone: SyntheticFrames.DemoHeadphone? = nil, minutesAgo: Double = 0, activate: Bool = true) -> ComparisonReference? {
        precondition(DebugSnapshot.directory != nil, "the comparison seed is for snapshot runs only")
        let frame = engine.latestFrame
        let date = Date().addingTimeInterval(-minutesAgo * 60)
        let previous = activeID
        makeRoom()
        var snapshot = SyntheticFrames.demoComparison(
            from: frame, brighter: true, louderDB: -2, headphone: headphone,
            name: Self.defaultName(date: date, source: SignalState.demo.label), tiltDBPerOctave: Float(settings.tiltDBPerOctave))
        snapshot.date = date
        let reference = ComparisonReference(snapshot: snapshot)
        references.append(reference)
        activeID = activate ? reference.id : previous
        return reference
    }

    /// The popover pictures show each reason beside "Capture reference".
    func setSnapshotOnlyCaptureBlock(_ block: CaptureBlock?) {
        precondition(DebugSnapshot.directory != nil, "snapshot runs only")
        captureBlock = block
    }

    /// Called once, when the snapshot pre-roll is over and the long-term values are measurements.
    func seedForSnapshotIfRequested() {
        guard let mode = Self.snapshotSeedMode, references.isEmpty else { return }
        addSnapshotOnlySeed(headphone: mode == "headphone" ? .hd800sLike : nil)
    }
}
