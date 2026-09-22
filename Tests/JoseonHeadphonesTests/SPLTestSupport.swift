import Foundation
import JoseonCore
@testable import JoseonHeadphones

// Synthetic third-octave readings, built by hand. The real analyzer bands come from
// JoseonCore/Spectrum; nothing here is presented as a measurement.

enum SPLFixture {

    /// Index of a nominal third-octave center, e.g. 1000 Hz -> 17.
    static func bandIndex(_ centerHz: Float) -> Int {
        ThirdOctaveReading.nominalCentersHz.firstIndex(of: centerHz)!
    }

    /// Every band at the reading floor (digital silence out of the analyzer).
    static var floorBands: [Float] {
        [Float](repeating: ThirdOctaveReading.floorDB, count: ThirdOctaveReading.nominalCentersHz.count)
    }

    /// One band at `dBFS`, the rest at the floor, identical on both channels.
    static func oneBand(atHz hz: Float, dBFS: Float) -> ThirdOctaveReading {
        var bands = floorBands
        bands[bandIndex(hz)] = dBFS
        return ThirdOctaveReading(left: bands, right: bands)
    }

    /// One band at `dBFS` on the left only; the right channel is at the floor.
    static func leftOnly(atHz hz: Float, dBFS: Float) -> ThirdOctaveReading {
        var left = floorBands
        left[bandIndex(hz)] = dBFS
        return ThirdOctaveReading(left: left, right: floorBands)
    }

    /// Digital silence.
    static var silence: ThirdOctaveReading {
        ThirdOctaveReading(left: floorBands, right: floorBands)
    }

    // MARK: A reference chain with round numbers

    /// 100 dB SPL per volt, 300 Ω. A round number, not a real headphone.
    static let sensitivity100 = HeadphoneSensitivity(
        dbSPLPerVolt: 100, impedanceOhms: 300, source: "synthetic test fixture"
    )

    /// 1 V RMS for a full-scale sine, so the voltage term is 0 dB.
    static func calibration(fullScaleVrms: Double = 1.0, uncertaintyDB: Double = 2) -> PlaybackCalibration {
        PlaybackCalibration(
            name: "test bench",
            method: .measuredVoltage,
            fullScaleVrms: fullScaleVrms,
            uncertaintyDB: uncertaintyDB
        )
    }

    /// A curve that is flat 0 dB everywhere.
    static func flatCurve() -> HeadphoneCurve {
        let f = (0..<200).map { 20 * pow(Float(1_000), Float($0) / 199) }
        return HeadphoneCurve(name: "Flat test", source: "synthetic test fixture",
                              frequenciesHz: f, levelsDB: f.map { _ in 0 })
    }

    /// Flat 0 dB, with a +`boostDB` plateau over `range` — wide enough that a whole
    /// third-octave band can sit inside it.
    static func plateauCurve(boostDB: Float, from lowHz: Float, to highHz: Float) -> HeadphoneCurve {
        let f = (0..<200).map { 20 * pow(Float(1_000), Float($0) / 199) }
        return HeadphoneCurve(name: "Plateau test", source: "synthetic test fixture",
                              frequenciesHz: f,
                              levelsDB: f.map { $0 >= lowHz && $0 <= highHz ? boostDB : 0 })
    }

    /// The reference estimator: flat curve, 100 dB/V, 1 V full scale.
    static func estimator(
        curve: HeadphoneCurve? = nil,
        fullScaleVrms: Double = 1.0,
        options: SPLDoseOptions = SPLDoseOptions(),
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_789_948_800) }  // 2026-09-21 UTC
    ) -> SPLEstimator {
        SPLEstimator(
            curve: curve ?? flatCurve(),
            sensitivity: sensitivity100,
            calibration: calibration(fullScaleVrms: fullScaleVrms),
            options: options,
            now: now
        )
    }

    // MARK: Driving a level

    /// The dBFS RMS a 1 kHz band needs so the reference chain reports exactly `target` dBA.
    ///
    /// Solved from the chain itself rather than hard-coded, so the fixture stays correct
    /// whatever the diffuse-field offset is set to.
    ///
    ///     levelA(1 kHz) = dBFS + 3.01 + 20·log10(V) + dbSPLPerVolt + 0 − DF(1 kHz) + A(1 kHz)
    ///     A(1 kHz) = 0 by definition
    static func dBFS(forADBA target: Double, fullScaleVrms: Double = 1.0) -> Float {
        let chain = 3.01 + 20 * log10(fullScaleVrms) + sensitivity100.dbSPLPerVolt
        let df = SPLEstimator.diffuseFieldTermDB(centerHz: 1_000)
        return Float(target - chain + df)
    }

    /// A 1 kHz reading that makes the reference chain report `dBA`.
    static func reading(atDBA dBA: Double, fullScaleVrms: Double = 1.0) -> ThirdOctaveReading {
        oneBand(atHz: 1_000, dBFS: dBFS(forADBA: dBA, fullScaleVrms: fullScaleVrms))
    }

    /// Feed a steady level for `seconds` of audio time in `frameSeconds` steps.
    @discardableResult
    static func run(
        _ estimator: SPLEstimator,
        atDBA dBA: Double,
        seconds: Double,
        frameSeconds: Double = 1.0,
        isSilent: Bool = false
    ) -> SPLReading {
        let bands = reading(atDBA: dBA)
        var left = seconds
        var last = estimator.evaluate(thirdOctave: bands, dt: 0, isSilent: isSilent)
        while left > 1e-9 {
            let dt = min(frameSeconds, left)
            last = estimator.evaluate(thirdOctave: bands, dt: dt, isSilent: isSilent)
            left -= dt
        }
        return last
    }
}

/// A stop flag two threads can share, local to the SPL tests.
final class SPLStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var isSet: Bool { lock.withLock { value } }
    func clear() { lock.withLock { value = false } }
}
