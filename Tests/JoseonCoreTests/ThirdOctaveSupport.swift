import Foundation
import XCTest
@testable import JoseonCore

/// Shared harness for the third-octave band tests.
enum ThirdOctave {
    static let bandCount = ThirdOctaveBank.bandCount
    /// A full-scale sine reads this, by the contract's convention.
    static let fullScaleSineDB: Float = -3.0103

    /// Index of a nominal centre in `ThirdOctaveReading.nominalCentersHz`.
    static func band(_ nominalHz: Float) -> Int {
        guard let i = ThirdOctaveReading.nominalCentersHz.firstIndex(of: nominalHz) else {
            fatalError("no third-octave band with nominal centre \(nominalHz)")
        }
        return i
    }

    /// Feed a signal in 800-frame blocks, the way the engine drives the analyzer.
    @discardableResult
    static func feed(_ analyzer: SpectrumAnalyzer, left: [Float], right: [Float],
                     rate: Double, block: Int = 800) -> ThirdOctaveReading? {
        precondition(left.count == right.count)
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                var i = 0
                while i + block <= left.count {
                    analyzer.process(left: l.baseAddress! + i, right: r.baseAddress! + i, count: block, sampleRate: rate)
                    i += block
                }
            }
        }
        return analyzer.thirdOctave
    }

    /// Feed, and take a reading after every block. Used for the time-response tests.
    static func trace(_ analyzer: SpectrumAnalyzer, left: [Float], right: [Float],
                      rate: Double, block: Int = 800,
                      each: (_ seconds: Double, _ reading: ThirdOctaveReading?) -> Void) {
        precondition(left.count == right.count)
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                var i = 0
                while i + block <= left.count {
                    analyzer.process(left: l.baseAddress! + i, right: r.baseAddress! + i, count: block, sampleRate: rate)
                    i += block
                    each(Double(i) / rate, analyzer.thirdOctave)
                }
            }
        }
    }

    /// Power-average the band readings taken after `fromSeconds`.
    ///
    /// One 125 ms reading of a 4.6 Hz-wide band scatters by a couple of dB: that is the
    /// chi-square of the estimate, not an error in the band level. Averaging the *power* of many
    /// readings is unbiased and is what a measurement of a steady noise signal would do anyway.
    /// Returns levels in dBFS RMS, same convention as the reading.
    static func averageLevels(_ analyzer: SpectrumAnalyzer, left: [Float], right: [Float],
                              rate: Double, fromSeconds: Double,
                              block: Int = 800) -> (left: [Double], right: [Double]) {
        var sumL = [Double](repeating: 0, count: bandCount)
        var sumR = [Double](repeating: 0, count: bandCount)
        var n = 0
        trace(analyzer, left: left, right: right, rate: rate, block: block) { seconds, reading in
            guard seconds >= fromSeconds, let reading else { return }
            n += 1
            for b in 0..<bandCount {
                sumL[b] += pow(10, Double(reading.left[b]) / 10)
                sumR[b] += pow(10, Double(reading.right[b]) / 10)
            }
        }
        XCTAssertGreaterThan(n, 0, "no readings were taken")
        let count = Double(max(n, 1))
        return ((0..<bandCount).map { 10 * log10(max(sumL[$0] / count, 1e-300)) },
                (0..<bandCount).map { 10 * log10(max(sumR[$0] / count, 1e-300)) })
    }

    /// Mean square of a buffer: the "known RMS" the noise tests measure against.
    static func meanSquare(_ x: [Float]) -> Double {
        var s = 0.0
        for v in x { s += Double(v) * Double(v) }
        return s / Double(x.count)
    }

    /// Sum of band powers as a mean square. `sum(10^(L/10))` is exactly the mean square of the
    /// signal inside the summed bands, because `L = 10 log10(power / 2)` and the power array sums
    /// to twice the mean square (see `ThirdOctaveBank`).
    static func meanSquare(ofBands levels: [Double], _ range: Range<Int>) -> Double {
        range.reduce(0.0) { $0 + pow(10, levels[$1] / 10) }
    }

    /// Exact base-10 band edges.
    static func edges(_ band: Int) -> (lower: Double, upper: Double) {
        (ThirdOctaveBank.lowerEdgeHz(band), ThirdOctaveBank.upperEdgeHz(band))
    }

    /// One line per band, for the report.
    static func describe(_ levels: [Float]) -> String {
        zip(ThirdOctaveReading.nominalCentersHz, levels)
            .map { String(format: "%.0f:%.2f", $0.0, $0.1) }
            .joined(separator: " ")
    }
}
