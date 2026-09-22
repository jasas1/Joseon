import Foundation
import Combine
import JoseonRender

/// Main window layout presets (⌘1 / ⌘2 / ⌘3).
enum LayoutPreset: String, CaseIterable, Identifiable {
    case essential, spectrum, metering
    var id: String { rawValue }
    var title: String {
        switch self {
        case .essential: return "Essential"
        case .spectrum: return "Spectrum"
        case .metering: return "Metering"
        }
    }
    var keyEquivalent: String {
        switch self {
        case .essential: return "1"
        case .spectrum: return "2"
        case .metering: return "3"
        }
    }
}

/// Loudness normalization targets the user can compare the integrated loudness with.
enum LoudnessTarget: Int, CaseIterable, Identifiable {
    case off = 0, streaming = -14, apple = -16, ebu = -23
    var id: Int { rawValue }
    var lufs: Float? { self == .off ? nil : Float(rawValue) }
    /// Menu and settings title.
    var title: String {
        switch self {
        case .off: return "Off"
        case .streaming: return "\(NumberText.signed(rawValue)) LUFS · Streaming"
        case .apple: return "\(NumberText.signed(rawValue)) LUFS · Apple"
        case .ebu: return "\(NumberText.signed(rawValue)) LUFS · EBU R128"
        }
    }
    /// Short text for the menu button.
    var shortTitle: String { self == .off ? "Loudness target" : "\(NumberText.signed(rawValue)) LUFS" }
}

/// Color of the menu bar mini graph.
enum MiniGraphColor: String, CaseIterable, Identifiable {
    /// Follows the menu bar: white on a dark menu bar, black on a light one.
    case template, orange, accent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .template: return "Template"
        case .orange: return "Orange"
        case .accent: return "Accent"
        }
    }
}

/// All user settings. Every property writes through to UserDefaults.
final class AppSettings: ObservableObject {
    static let binChoices = [512, 1024, 2048]
    static let tiltChoices: [Double] = [0, 3, 4.5]
    static let dbRangeChoices = [60, 96, 120]
    static let miniWidthChoices = [44, 64, 96]
    /// Now playing in the menu bar: points of scrolling text next to the mini graph.
    static let nowPlayingWidthChoices = [100, 140, 200]
    static let historyChoices = [10, 20, 60]
    /// Session timeline: seconds across the strip (5, 15 or 30 minutes).
    static let timelineWindowChoices = [300, 900, 1800]

    private let defaults: UserDefaults

    // Analysis
    @Published var displayBins: Int { didSet { defaults.set(displayBins, forKey: "displayBins") } }
    @Published var releaseSeconds: Double { didSet { defaults.set(releaseSeconds, forKey: "releaseSeconds") } }
    @Published var peakDecayDBPerSecond: Double { didSet { defaults.set(peakDecayDBPerSecond, forKey: "peakDecayDBPerSecond") } }
    @Published var tiltDBPerOctave: Double { didSet { defaults.set(tiltDBPerOctave, forKey: "tiltDBPerOctave") } }
    @Published var dbRange: Int { didSet { defaults.set(dbRange, forKey: "dbRange") } }

    // Spectrum panel traces
    @Published var showLeftRight: Bool { didSet { defaults.set(showLeftRight, forKey: "showLeftRight") } }
    @Published var showMid: Bool { didSet { defaults.set(showMid, forKey: "showMid") } }
    /// Side = (L−R)/2 as its own trace in the spectrum.
    @Published var showSide: Bool { didSet { defaults.set(showSide, forKey: "showSide") } }
    @Published var showPeakHold: Bool { didSet { defaults.set(showPeakHold, forKey: "showPeakHold") } }
    /// Spectrum picks its own 72 dB window that follows the music. Off = the fixed "Level range".
    @Published var spectrumAutoRange: Bool { didSet { defaults.set(spectrumAutoRange, forKey: "spectrumAutoRange") } }
    /// Vectorscope card shows stereo placement by frequency (pan spectrum), not the Lissajous scope.
    @Published var stereoPlacementMode: Bool { didSet { defaults.set(stereoPlacementMode, forKey: "stereoPlacementMode") } }
    /// "Spectrum" layout: the stereo placement card sits beside the spectrogram.
    @Published var spectrumShowsPlacement: Bool { didSet { defaults.set(spectrumShowsPlacement, forKey: "spectrumShowsPlacement") } }
    @Published var showAverage: Bool { didSet { defaults.set(showAverage, forKey: "showAverage") } }
    @Published var showHeadphoneOverlay: Bool { didSet { defaults.set(showHeadphoneOverlay, forKey: "showHeadphoneOverlay") } }
    @Published var spectrogramHistorySeconds: Int { didSet { defaults.set(spectrogramHistorySeconds, forKey: "spectrogramHistorySeconds") } }

    // Session timeline strip
    /// The strip under the panels of the main window (⌘5).
    @Published var showTimeline: Bool { didSet { defaults.set(showTimeline, forKey: "showTimeline") } }
    @Published var timelineWindowSeconds: Int { didSet { defaults.set(timelineWindowSeconds, forKey: "timelineWindowSeconds") } }
    /// The tone lane of the timeline. The panel shows it only when it is 260 pt high or more.
    @Published var timelineShowBands: Bool { didSet { defaults.set(timelineShowBands, forKey: "timelineShowBands") } }
    /// The "At the ear" lane of the timeline. Off by default: the default screen stays calm, the level is in the pill.
    @Published var timelineShowEarLane: Bool { didSet { defaults.set(timelineShowEarLane, forKey: "timelineShowEarLane") } }

    // A/B compare (the references themselves are memory only: see `ComparisonController`)
    /// The difference lane and the band bars leave the broadband level difference out.
    @Published var comparisonLevelMatch: Bool { didSet { defaults.set(comparisonLevelMatch, forKey: "comparisonLevelMatch") } }
    /// The difference lane shows headphone B − headphone A (when both are known), not the signal difference.
    @Published var comparisonHeadphoneMode: Bool { didSet { defaults.set(comparisonHeadphoneMode, forKey: "comparisonHeadphoneMode") } }

    // App
    @Published var layoutPreset: LayoutPreset { didSet { defaults.set(layoutPreset.rawValue, forKey: "layoutPreset") } }
    @Published var miniGraphWidth: Int { didSet { defaults.set(miniGraphWidth, forKey: "miniGraphWidth") } }
    @Published var miniGraphColor: MiniGraphColor { didSet { defaults.set(miniGraphColor.rawValue, forKey: "miniGraphColor") } }
    @Published var showDockIcon: Bool { didSet { defaults.set(showDockIcon, forKey: "showDockIcon") } }

    // Now playing: the track title read from the player window (Qobuz) through macOS Accessibility.
    /// Read the title at all (popover header; the menu bar with `nowPlayingInMenuBar`).
    @Published var showNowPlaying: Bool { didSet { defaults.set(showNowPlaying, forKey: "showNowPlaying") } }
    /// The scrolling title next to the mini graph, while a track is known.
    @Published var nowPlayingInMenuBar: Bool { didSet { defaults.set(nowPlayingInMenuBar, forKey: "nowPlayingInMenuBar") } }
    @Published var nowPlayingMenuBarWidth: Int { didSet { defaults.set(nowPlayingMenuBarWidth, forKey: "nowPlayingMenuBarWidth") } }
    /// " · Hi-Res" after the title when the player marks the stream as hi-res.
    @Published var nowPlayingShowsHiRes: Bool { didSet { defaults.set(nowPlayingShowsHiRes, forKey: "nowPlayingShowsHiRes") } }
    @Published var demoMode: Bool { didSet { defaults.set(demoMode, forKey: "demoMode") } }
    /// Empty string means "None".
    @Published var headphoneName: String { didSet { defaults.set(headphoneName, forKey: "headphoneName") } }
    /// Empty string means "first target in the library".
    @Published var targetName: String { didSet { defaults.set(targetName, forKey: "targetName") } }
    @Published var loudnessTarget: LoudnessTarget { didSet { defaults.set(loudnessTarget.rawValue, forKey: "loudnessTarget") } }
    /// Reset the measurement when audio resumes after more than 2 s of silence (a new track or album).
    @Published var autoResetAfterSilence: Bool { didSet { defaults.set(autoResetAfterSilence, forKey: "autoResetAfterSilence") } }
    /// False until a headphone choice (also "None") is stored. The app then picks its default headphone.
    let hasStoredHeadphoneChoice: Bool
    @Published var hasSeenWelcome: Bool { didSet { defaults.set(hasSeenWelcome, forKey: "hasSeenWelcome") } }
    @Published var mainWindowWasOpen: Bool { didSet { defaults.set(mainWindowWasOpen, forKey: "mainWindowWasOpen") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "displayBins": 1024, "releaseSeconds": 0.25, "peakDecayDBPerSecond": 12.0, "tiltDBPerOctave": 0.0,
            "dbRange": 96, "showLeftRight": true, "showMid": true, "showSide": false, "showPeakHold": true, "spectrumAutoRange": true, "stereoPlacementMode": false, "spectrumShowsPlacement": true, "showAverage": true,
            "showHeadphoneOverlay": true, "spectrogramHistorySeconds": 20, "layoutPreset": LayoutPreset.essential.rawValue,
            "miniGraphWidth": 64, "miniGraphColor": MiniGraphColor.template.rawValue, "showDockIcon": true, "demoMode": false, "targetName": "",
            "hasSeenWelcome": false, "mainWindowWasOpen": true, "loudnessTarget": LoudnessTarget.off.rawValue,
            "autoResetAfterSilence": true,
            "showNowPlaying": true, "nowPlayingInMenuBar": true, "nowPlayingMenuBarWidth": 140, "nowPlayingShowsHiRes": true,
            "showTimeline": true, "timelineWindowSeconds": 900, "timelineShowBands": true, "timelineShowEarLane": false,
        ])
        defaults.register(defaults: ["comparisonLevelMatch": true, "comparisonHeadphoneMode": false])
        func pick<T: Equatable>(_ value: T, from choices: [T], fallback: T) -> T { choices.contains(value) ? value : fallback }
        displayBins = pick(defaults.integer(forKey: "displayBins"), from: Self.binChoices, fallback: 1024)
        releaseSeconds = min(max(defaults.double(forKey: "releaseSeconds"), 0.05), 2.0)
        peakDecayDBPerSecond = min(max(defaults.double(forKey: "peakDecayDBPerSecond"), 3), 48)
        tiltDBPerOctave = pick(defaults.double(forKey: "tiltDBPerOctave"), from: Self.tiltChoices, fallback: 0)
        dbRange = pick(defaults.integer(forKey: "dbRange"), from: Self.dbRangeChoices, fallback: 96)
        showLeftRight = defaults.bool(forKey: "showLeftRight")
        showMid = defaults.bool(forKey: "showMid")
        showSide = defaults.bool(forKey: "showSide")
        showPeakHold = defaults.bool(forKey: "showPeakHold")
        spectrumAutoRange = defaults.bool(forKey: "spectrumAutoRange")
        stereoPlacementMode = defaults.bool(forKey: "stereoPlacementMode")
        spectrumShowsPlacement = defaults.bool(forKey: "spectrumShowsPlacement")
        showAverage = defaults.bool(forKey: "showAverage")
        showHeadphoneOverlay = defaults.bool(forKey: "showHeadphoneOverlay")
        spectrogramHistorySeconds = pick(defaults.integer(forKey: "spectrogramHistorySeconds"), from: Self.historyChoices, fallback: 20)
        showTimeline = defaults.bool(forKey: "showTimeline")
        timelineWindowSeconds = pick(defaults.integer(forKey: "timelineWindowSeconds"), from: Self.timelineWindowChoices, fallback: 900)
        timelineShowBands = defaults.bool(forKey: "timelineShowBands")
        timelineShowEarLane = defaults.bool(forKey: "timelineShowEarLane")
        layoutPreset = LayoutPreset(rawValue: defaults.string(forKey: "layoutPreset") ?? "") ?? .essential
        miniGraphWidth = pick(defaults.integer(forKey: "miniGraphWidth"), from: Self.miniWidthChoices, fallback: 64)
        miniGraphColor = MiniGraphColor(rawValue: defaults.string(forKey: "miniGraphColor") ?? "") ?? .template
        showDockIcon = defaults.bool(forKey: "showDockIcon")
        showNowPlaying = defaults.bool(forKey: "showNowPlaying")
        nowPlayingInMenuBar = defaults.bool(forKey: "nowPlayingInMenuBar")
        nowPlayingMenuBarWidth = pick(defaults.integer(forKey: "nowPlayingMenuBarWidth"), from: Self.nowPlayingWidthChoices, fallback: 140)
        nowPlayingShowsHiRes = defaults.bool(forKey: "nowPlayingShowsHiRes")

        demoMode = defaults.bool(forKey: "demoMode")
        // "headphoneName" has no registered default: a missing value means the user never chose.
        hasStoredHeadphoneChoice = defaults.object(forKey: "headphoneName") != nil
        headphoneName = defaults.string(forKey: "headphoneName") ?? ""
        loudnessTarget = LoudnessTarget(rawValue: defaults.integer(forKey: "loudnessTarget")) ?? .off
        autoResetAfterSilence = defaults.bool(forKey: "autoResetAfterSilence")
        targetName = defaults.string(forKey: "targetName") ?? ""
        hasSeenWelcome = defaults.bool(forKey: "hasSeenWelcome")
        mainWindowWasOpen = defaults.bool(forKey: "mainWindowWasOpen")
        comparisonLevelMatch = defaults.bool(forKey: "comparisonLevelMatch")
        comparisonHeadphoneMode = defaults.bool(forKey: "comparisonHeadphoneMode")
    }

    /// "Level range" as one choice: 0 = Auto (the spectrum follows the music), else the fixed range in dB.
    var levelRangeChoice: Int {
        get { spectrumAutoRange ? 0 : dbRange }
        set {
            if newValue == 0 { spectrumAutoRange = true } else { dbRange = newValue; spectrumAutoRange = false }
        }
    }

    /// Options for the main spectrum panel, from the stored toggles.
    var spectrumViewOptions: SpectrumViewOptions {
        var o = SpectrumViewOptions()
        o.showLeftRight = showLeftRight
        o.showMid = showMid
        o.showSide = showSide
        o.showPeakHold = showPeakHold
        o.showAverage = showAverage
        o.showHeadphoneOverlay = showHeadphoneOverlay
        o.minDB = -Float(dbRange)
        o.maxDB = 0
        return o
    }
}
