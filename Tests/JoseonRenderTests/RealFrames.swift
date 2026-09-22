import Foundation
import JoseonCore
@testable import JoseonRender

/// Frames from the real analyzers: the demo music signal of `TestSignals` through `AnalysisEngine.processNow`,
/// the same path `joseon-probe render` uses. Design review and trust tests use these, not only `SyntheticFrames`.
enum RealFrames {
    private static var cache: [String: [AnalysisFrame]] = [:]

    static func demo(seconds: Double, headphone: Bool = false) -> [AnalysisFrame] {
        let key = "\(seconds)-\(headphone)"
        if let c = cache[key] { return c }
        let engine = AnalysisEngine()
        let sampleRate = 48_000.0
        engine.streamInfo = StreamInfo(sampleRate: sampleRate, channelCount: 2, deviceName: "Demo signal", bitDepth: 32, activeSources: ["Joseon demo"])
        let block = Int(sampleRate / 60)
        var frames: [AnalysisFrame] = []
        let total = max(1, Int(seconds * 60))
        frames.reserveCapacity(total)
        for k in 0..<total {
            let samples = TestSignals.demoBlock(startSample: k * block, count: block, sampleRate: sampleRate)
            var frame = engine.processNow(left: samples.left, right: samples.right, count: block, sampleRate: sampleRate)
            frame.hostTime = Double(k) / 60
            if headphone { frame.headphone = demoHeadphone(for: frame.spectrum) }
            frames.append(frame)
        }
        cache[key] = frames
        return frames
    }

    /// The test target cannot link JoseonHeadphones: the made-up demo curves of `SyntheticFrames` stand in.
    static func demoHeadphone(for s: SpectrumReading) -> HeadphoneReading {
        let response = s.frequencies.map { SyntheticFrames.demoResponse(log2Hz: log2($0)) }
        let target = s.frequencies.map { SyntheticFrames.demoTarget(log2Hz: log2($0)) }
        let predicted = zip(s.mid, response).map { $0 + $1 }
        return HeadphoneReading(modelName: "Demo headphone", responseDB: response, targetDB: target, predictedAtEarDB: predicted, stressFlags: [])
    }

    /// Real frames plus what the real pipeline does not fill in this worktree yet: a headphone reading with stress flags
    /// that carry a frequency span, the top peaks and the lowest strong content (stand-ins from `SyntheticFrames`).
    static func annotated(_ frames: [AnalysisFrame]) -> [AnalysisFrame] {
        frames.map { f in
            var g = f
            var hp = demoHeadphone(for: f.spectrum)
            hp.stressFlags = SyntheticFrames.demoStressFlags()
            g.headphone = hp
            g.topPeaks = SyntheticFrames.demoTopPeaks(of: f.spectrum, first: f.peak)
            g.lowestStrongHz = SyntheticFrames.demoLowestStrong(of: f.spectrum)
            return g
        }
    }
}
