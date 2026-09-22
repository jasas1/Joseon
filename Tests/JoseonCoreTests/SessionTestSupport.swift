import Foundation
@testable import JoseonCore

/// A wall clock the tests move by hand. The recorder never uses it for the timeline axis,
/// only for the dates on samples and events.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(start: Date = Date(timeIntervalSinceReferenceDate: 0)) { date = start }

    var now: Date { lock.withLock { date } }

    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }

    /// Pass this to `SessionRecorder(now:)`.
    func read() -> Date { now }
}

enum SessionTestFrame {
    /// A frame with only the numbers the recorder reads. Everything else is at its floor.
    static func make(momentary: Float = LoudnessReading.silenceLUFS,
                     shortTerm: Float = LoudnessReading.silenceLUFS,
                     truePeakLeft: Float = -120,
                     truePeakRight: Float = -120,
                     clipCount: Int = 0,
                     measuredSeconds: Double = 0,
                     correlation: Float = 0,
                     bandsDB: Float = SpectrumReading.floorDB,
                     levelA: Float? = nil,
                     flags: [StressFlag] = [],
                     isSilent: Bool = false) -> AnalysisFrame {
        var loudness = LoudnessReading()
        loudness.momentaryLUFS = momentary
        loudness.shortTermLUFS = shortTerm
        loudness.truePeakLeftDBTP = truePeakLeft
        loudness.truePeakRightDBTP = truePeakRight
        loudness.clipCount = clipCount
        loudness.measuredSeconds = measuredSeconds
        var stereo = StereoReading()
        stereo.correlation = correlation
        let bands = BandEnergy(subBass: bandsDB, bass: bandsDB, lowMid: bandsDB, mid: bandsDB,
                               upperMid: bandsDB, presence: bandsDB, brilliance: bandsDB, air: bandsDB)
        var frame = AnalysisFrame(spectrum: .silent(binCount: 8),
                                  bands: bands,
                                  loudness: loudness,
                                  stereo: stereo,
                                  isSilent: isSilent)
        if !flags.isEmpty {
            let zeros = [Float](repeating: 0, count: 8)
            frame.headphone = HeadphoneReading(modelName: "Test", responseDB: zeros, targetDB: zeros,
                                               predictedAtEarDB: zeros, stressFlags: flags)
        }
        if let levelA { frame.spl = splReading(levelASlow: levelA) }
        return frame
    }

    static func splReading(levelASlow: Float) -> SPLReading {
        SPLReading(calibrationName: "Test", uncertaintyDB: 2,
                   levelAFast: levelASlow, levelASlow: levelASlow, levelZEardrum: levelASlow,
                   leqATrack: levelASlow, leqASession: levelASlow, maxAFast: levelASlow,
                   bandLevelsEardrum: [Float](repeating: levelASlow, count: 31),
                   doseNIOSH: 0, doseWHOWeekly: 0, doseSeconds: 0, secondsToNIOSHLimit: .infinity)
    }

    static func flag(_ id: String, title: String, severity: StressFlag.Severity = .watch) -> StressFlag {
        StressFlag(id: id, severity: severity, title: title, detail: "detail of \(id)")
    }
}
