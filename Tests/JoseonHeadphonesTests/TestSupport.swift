import Foundation
import JoseonCore
@testable import JoseonHeadphones

// Synthetic fixtures. These are test signals, never presented as measurements.

enum Fixture {
    /// A log-spaced display grid like the one the spectrum analyzer makes.
    static func grid(bins: Int = 256, minHz: Float = 10, maxHz: Float = 24_000) -> [Float] {
        let n = max(bins, 2)
        let ratio = maxHz / minHz
        return (0..<n).map { minHz * pow(ratio, Float($0) / Float(n - 1)) }
    }

    /// A spectrum whose `mid` is `level(hz)` and whose other channels copy it.
    static func spectrum(bins: Int = 256, level: (Float) -> Float) -> SpectrumReading {
        let f = grid(bins: bins)
        let m = f.map(level)
        return SpectrumReading(frequencies: f, left: m, right: m, mid: m, side: m, peakHold: m, average: m)
    }

    /// Digital silence on every bin.
    static func silentSpectrum(bins: Int = 256) -> SpectrumReading {
        spectrum(bins: bins) { _ in SpectrumReading.floorDB }
    }

    /// A curve that is `level(hz)` on a 200-point log grid from 20 Hz to 20 kHz.
    static func curve(name: String, level: (Float) -> Float) -> HeadphoneCurve {
        let f = (0..<200).map { 20 * pow(Float(1_000), Float($0) / 199) }
        return HeadphoneCurve(name: name, source: "synthetic test fixture",
                              frequenciesHz: f, levelsDB: f.map(level))
    }

    static func flatCurve(name: String = "Flat test") -> HeadphoneCurve {
        curve(name: name) { _ in 0 }
    }

    static func loudness(
        truePeakMax: Float = -120, plr: Float = 0, clipCount: Int = 0,
        measuredSeconds: Double = 0, integrated: Float = -120
    ) -> LoudnessReading {
        var l = LoudnessReading()
        l.truePeakMaxDBTP = truePeakMax
        l.plrDB = plr
        l.clipCount = clipCount
        l.measuredSeconds = measuredSeconds
        l.integratedLUFS = integrated
        l.isIntegratedValid = integrated > -119
        return l
    }

    static func bands(subBass: Float = -120) -> BandEnergy {
        var b = BandEnergy()
        b.subBass = subBass
        return b
    }
}

/// A clock the test moves by hand.
final class TestClock {
    var t: TimeInterval = 0
    var read: () -> TimeInterval { { [self] in t } }
    func advance(_ dt: TimeInterval) { t += dt }

    /// Hold a condition long enough for a level flag to go up: evaluate, move past the
    /// attack time, evaluate again. Level flags need `levelAttackSeconds` — 3 s by
    /// default — of a true condition before they appear (critic r4 defect 4).
    func settled(_ seconds: TimeInterval = 3.01, _ evaluate: () -> [StressFlag]) -> [StressFlag] {
        _ = evaluate()
        advance(seconds)
        return evaluate()
    }
}
