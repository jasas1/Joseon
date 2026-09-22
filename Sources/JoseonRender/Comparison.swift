import Foundation
import JoseonCore

/// What the difference lane of the spectrum shows while a comparison is set.
public enum ComparisonMode: Sendable {
    /// `B − A` of the two long-term spectra: what changed in the music (another master, another track).
    case signal
    /// `response_B − response_A` of the two headphone curves: what changing the headphone changes at the ear,
    /// independent of the music. Needs a headphone in A and another one (by name) in the live frame.
    case headphone
}

/// The math of A/B compare: the reference "A" (a `ComparisonSnapshot`) against the live long-term curve "B".
/// One instance per panel; the buffers keep their size, so a frame allocates nothing.
///
/// Rules of the A/B compare design:
/// - Only long-term curves are compared (`snapshot.averageDB` against `spectrum.average`), never the live Mid curve.
/// - Like with like: the display tilt of each curve is taken out first (`tilt * log2(f / 1 kHz)`), so a change of the
///   tilt setting between capture and now changes nothing in the difference.
/// - A is resampled onto the live bins: linear in log frequency, in the dB domain. Outside A's range there is no value.
/// - Level match: the difference of the two power means over 100 Hz ... 10 kHz (tilt-free curves, the bins where both
///   curves stand 6 dB or more over the analyzer floor). Bias: a power mean follows the loudest region. A change that is
///   not broadband moves it a little: +4 dB above 5 kHz on a flat spectrum reads as "+0.9 dB louder", and the lane then
///   shows +3.1 dB there and −0.9 dB elsewhere. On music (most power under 1 kHz) the same change moves it under 0.1 dB.
/// - The difference is smoothed over 1/6 octave in the dB domain. It has no value where either curve, as drawn, is
///   within 6 dB of the display floor: the difference of two floors is not a measurement.
final class ComparisonCurves {
    static let matchRangeHz: ClosedRange<Float> = 100...10_000
    static let smoothingOctaves: Float = 1.0 / 6
    static let floorGuardDB: Float = 6
    /// B needs this much long-term data before it is compared.
    static let minimumSecondsB = 5.0

    /// A on the live bins, tilt-free. NaN outside A's frequency range.
    private(set) var referenceFlat: [Float] = []
    /// A on the live bins with the live tilt: the trace the plot draws. NaN outside A's range.
    private(set) var referenceDrawn: [Float] = []
    /// A's headphone response on the live bins (dB re 1 kHz). Empty when A has none.
    private(set) var referenceResponse: [Float] = []
    /// `B − A` per live bin after level match (when on) and smoothing. NaN = no value.
    private(set) var difference: [Float] = []
    /// `response_B − response_A` per live bin, smoothed like `difference`. NaN = no value. Empty = not available.
    private(set) var responseDifference: [Float] = []
    /// Power mean of B minus power mean of A over `matchRangeHz`, dB. Nil when no bin can be compared.
    private(set) var levelOffsetDB: Float?
    /// `B − A` of the eight listening bands (`BandEnergy.edgesHz`) from the two long-term curves, after level match
    /// when on. Nil = under half of the band can be compared.
    private(set) var bandDeltas = [Float?](repeating: nil, count: 8)
    /// First and last live bin inside A's frequency range.
    private(set) var overlap: ClosedRange<Int>?

    private var frequencies: [Float] = []
    private var octaves: [Float] = []        // log2(f / 1 kHz) per live bin
    private var windowLo: [Int32] = [], windowHi: [Int32] = []
    private var raw: [Float] = []
    private var flatB: [Float] = []
    private var prefix: [Float] = [], prefixCount: [Int32] = []
    private var referencePower: [Float] = []
    private var referenceOK: [Bool] = []
    private var key = Key()

    private struct Key: Equatable {
        var id: UUID?; var tilt: Float = 0; var sourceCount = 0; var liveCount = 0; var liveFirst: Float = 0; var liveLast: Float = 0
    }

    /// Prepares A for the live bins. Cheap when nothing changed.
    func setReference(_ s: ComparisonSnapshot, liveFrequencies f: [Float]) {
        let k = Key(id: s.id, tilt: s.tiltDBPerOctave, sourceCount: s.averageDB.count, liveCount: f.count, liveFirst: f.first ?? 0, liveLast: f.last ?? 0)
        guard k != key else { return }
        key = k
        let n = f.count
        frequencies = f
        octaves = f.map { log2(max($0, 1e-3) / 1000) }
        let half = pow(2, Self.smoothingOctaves / 2)
        windowLo = [Int32](repeating: 0, count: n); windowHi = [Int32](repeating: 0, count: n)
        var a = 0, b = 0
        for i in 0..<n {
            while a < i, f[a] < f[i] / half { a += 1 }
            while b + 1 < n, f[b + 1] <= f[i] * half { b += 1 }
            b = max(b, i)
            windowLo[i] = Int32(a); windowHi[i] = Int32(b)
        }
        referenceFlat = Self.resample(s.averageDB, from: s.frequencies, onto: f)
        // The analyzer puts its floor under the curve after the tilt: the test for "A has content here" reads A as captured.
        let gate = SpectrumReading.floorDB + Self.floorGuardDB
        referenceOK = referenceFlat.map { $0.isFinite && $0 > gate }
        for i in 0..<n where referenceFlat[i].isFinite { referenceFlat[i] -= s.tiltDBPerOctave * octaves[i] }
        referencePower = referenceFlat.map { $0.isFinite ? exp($0 * Self.lnPerDB) : 0 }
        if let r = s.responseDB, r.count == s.frequencies.count { referenceResponse = Self.resample(r, from: s.frequencies, onto: f) } else { referenceResponse = [] }
        let first = referenceFlat.firstIndex { $0.isFinite }, last = referenceFlat.lastIndex { $0.isFinite }
        overlap = first.flatMap { a in last.map { a...$0 } }
        referenceDrawn = [Float](repeating: .nan, count: n)
        difference = [Float](repeating: .nan, count: n)
        raw = difference; flatB = difference
        responseDifference = []
        prefix = [Float](repeating: 0, count: n + 1); prefixCount = [Int32](repeating: 0, count: n + 1)
        levelOffsetDB = nil
        for i in 0..<8 { bandDeltas[i] = nil }
    }

    func clear() { key = Key(); referenceDrawn = []; difference = []; responseDifference = []; referenceResponse = []; levelOffsetDB = nil; overlap = nil }

    private static let lnPerDB = Float(M_LN10 / 10)

    /// The signal comparison for the newest long-term curve of B.
    /// - Parameters:
    ///   - liveAverage: `frame.spectrum.average`, on the bins given to `setReference`, with the live display tilt.
    ///   - liveTilt: the display tilt those values carry, dB per octave around 1 kHz.
    ///   - displayFloorDB: the bottom of the plot the curves are drawn on. Use `SpectrumReading.floorDB` for "no plot".
    func update(liveAverage b: [Float], liveTilt: Float, levelMatch: Bool, displayFloorDB: Float) {
        let n = frequencies.count
        guard n >= 2, b.count >= n, referenceFlat.count == n else { levelOffsetDB = nil; return }
        let analyzerGate = SpectrumReading.floorDB + Self.floorGuardDB
        let displayGate = max(displayFloorDB, SpectrumReading.floorDB) + Self.floorGuardDB

        // Level offset: fixed bins (not a matter of the plot range), so every panel finds the same number.
        var sumA = 0.0, sumB = 0.0, bins = 0
        for i in 0..<n {
            let a = referenceFlat[i]
            guard a.isFinite, b[i].isFinite else { referenceDrawn[i] = .nan; flatB[i] = .nan; continue }
            let tilt = liveTilt * octaves[i]
            referenceDrawn[i] = a + tilt
            flatB[i] = b[i] - tilt
            let f = frequencies[i]
            if f >= Self.matchRangeHz.lowerBound, f <= Self.matchRangeHz.upperBound, referenceOK[i], b[i] > analyzerGate {
                sumA += Double(referencePower[i]); sumB += Double(exp(flatB[i] * Self.lnPerDB)); bins += 1
            }
        }
        levelOffsetDB = bins >= 3 && sumA > 0 && sumB > 0 ? Float(10 * log10(sumB / sumA)) : nil
        let shift = levelMatch ? (levelOffsetDB ?? 0) : 0

        for i in 0..<n {
            let ok = flatB[i].isFinite && referenceOK[i] && referenceDrawn[i] > displayGate && b[i] > displayGate
            raw[i] = ok ? flatB[i] - referenceFlat[i] - shift : .nan
        }
        smooth(raw, into: &difference)

        // The listening bands, from the same two curves: power summed over each band, a display bin weighted by its
        // width in Hz (the bins are log spaced, their values are levels per analysis bin).
        let edges = BandEnergy.edgesHz
        var i = 0
        for band in 0..<8 {
            var pa = 0.0, pb = 0.0, valid = 0, total = 0
            while i < n, frequencies[i] < edges[band] { i += 1 }
            while i < n, frequencies[i] < edges[band + 1] {
                total += 1
                if flatB[i].isFinite, referenceOK[i], b[i] > analyzerGate {
                    let w = Double(frequencies[i])
                    pa += w * Double(referencePower[i]); pb += w * Double(exp(flatB[i] * Self.lnPerDB)); valid += 1
                }
                i += 1
            }
            bandDeltas[band] = valid >= 2 && valid * 2 >= total && pa > 0 && pb > 0 ? Float(10 * log10(pb / pa)) - shift : nil
        }
    }

    /// The headphone comparison: `liveResponse` (dB re 1 kHz on the live bins) minus A's response.
    func updateHeadphone(liveResponse r: [Float]?) {
        let n = frequencies.count
        guard let r, r.count >= n, referenceResponse.count == n, n >= 2 else { responseDifference = []; return }
        for i in 0..<n { raw[i] = referenceResponse[i].isFinite && r[i].isFinite ? r[i] - referenceResponse[i] : .nan }
        if responseDifference.count != n { responseDifference = [Float](repeating: .nan, count: n) }
        smooth(raw, into: &responseDifference)
    }

    /// Mean over ±1/12 octave of the values that exist. A bin without a value stays without one.
    private func smooth(_ v: [Float], into out: inout [Float]) {
        let n = v.count
        prefix[0] = 0; prefixCount[0] = 0
        for i in 0..<n {
            let ok = v[i].isFinite
            prefix[i + 1] = prefix[i] + (ok ? v[i] : 0)
            prefixCount[i + 1] = prefixCount[i] + (ok ? 1 : 0)
        }
        for i in 0..<n {
            guard v[i].isFinite else { out[i] = .nan; continue }
            let a = Int(windowLo[i]), b = Int(windowHi[i]) + 1
            out[i] = (prefix[b] - prefix[a]) / Float(max(prefixCount[b] - prefixCount[a], 1))
        }
    }

    /// Value of a per-bin array of this comparison at a frequency (linear in log f). Nil where there is none.
    func value(of values: [Float], atHz hz: Float) -> Float? {
        guard values.count == frequencies.count, let v = CursorMath.level(of: values, frequencies: frequencies, atHz: hz), v.isFinite else { return nil }
        return v
    }

    /// Resamples `values` (on `src` frequencies, ascending) onto `dst` frequencies: linear in log frequency, in dB.
    /// NaN outside the range of `src`.
    static func resample(_ values: [Float], from src: [Float], onto dst: [Float]) -> [Float] {
        let n = min(values.count, src.count)
        var out = [Float](repeating: .nan, count: dst.count)
        guard n >= 2, src[0] > 0 else { return out }
        let ln = src.prefix(n).map { log($0) }
        var k = 0
        let slack = (ln[n - 1] - ln[0]) * 1e-6
        for (j, f) in dst.enumerated() where f > 0 {
            let x = log(f)
            guard x >= ln[0] - slack, x <= ln[n - 1] + slack else { continue }
            while k < n - 2, ln[k + 1] < x { k += 1 }
            while k > 0, ln[k] > x { k -= 1 }
            let t = min(max((x - ln[k]) / max(ln[k + 1] - ln[k], 1e-9), 0), 1)
            out[j] = values[k] * (1 - t) + values[k + 1] * t
        }
        return out
    }
}

/// The words of A/B compare, shared by the spectrum and the meters.
enum ComparisonText {
    static let measuring = "measuring B\u{2026}"
    static let deltaName = "B \u{2212} A"
    /// B is the live signal's long-term curve: the legend says so ("live" read as "the curve of this moment").
    static let liveLegend = "B \u{00B7} long-term"
    /// Said once, in the lane's strip, while level match is on: the curves of the plot keep their levels, only the lane is matched.
    static let asPlayedNotes = ["curves as played \u{00B7} lane level-matched", "curves as played"]
    static let bandHidden = ["headphone band hidden", "hp band hidden"]

    /// "B is +2.3 dB louder", "B is 1.0 dB quieter", "same level".
    static func louder(_ offset: Float) -> String {
        let r = (offset * 10).rounded() / 10
        if r == 0 { return "same level" }
        return r > 0 ? "B is \(Fmt.number(r, signed: true)) dB louder" : "B is \(Fmt.number(-r)) dB quieter"
    }
    static func louderShort(_ offset: Float) -> String {
        let r = (offset * 10).rounded() / 10
        return r == 0 ? "same level" : "B \(Fmt.number(r, signed: true)) dB"
    }

    /// "measuring B… 3 / 5 s".
    static func measuring(seconds: Double) -> String {
        "\(measuring) \(Int(min(max(seconds, 0), ComparisonCurves.minimumSecondsB))) / \(Int(ComparisonCurves.minimumSecondsB)) s"
    }

    /// Legend forms of the reference, longest first: "A · 21:42 · Qobuz", "A · 21:42", "A". A name that does not start
    /// with "A" gets the letter.
    static func referenceLegends(_ name: String) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let full = trimmed.isEmpty ? "A" : (trimmed == "A" || trimmed.hasPrefix("A ") || trimmed.hasPrefix("A\u{00B7}") ? trimmed : "A \u{00B7} \(trimmed)")
        let parts = full.components(separatedBy: " \u{00B7} ")
        var out = [full]
        if parts.count > 2 { out.append(parts.prefix(2).joined(separator: " \u{00B7} ")) }
        if full != "A" { out.append("A") }
        return out
    }

    /// The reference's headphone in a legend: "A · Susvara".
    static func referenceHeadphone(_ name: String) -> String { "A \u{00B7} \(name)" }
}

extension Palette {
    /// The reference trace "A": saturated gold #E3B341 at 90 %. No fill, no glow, but never to be taken for a grey line.
    var reference: SIMD4<Float> { SIMD4(0xE3 / 255.0, 0xB3 / 255.0, 0x41 / 255.0, highContrast ? 1.0 : 0.90) }
    /// B's long-term curve while a reference is set: the cool grey of "Long-term", lighter and at 90 %.
    var liveLongTerm: SIMD4<Float> { highContrast ? SIMD4(0.80, 0.86, 0.96, 1) : SIMD4(0.66, 0.73, 0.86, 0.90) }
    /// The difference lane: where B has more (above zero) a light neutral tone, where B has less a darker one.
    var deltaAbove: SIMD4<Float> { highContrast ? SIMD4(0.92, 0.94, 0.98, 1) : SIMD4(0.80, 0.84, 0.92, 1) }
    var deltaBelow: SIMD4<Float> { highContrast ? SIMD4(0.56, 0.62, 0.74, 1) : SIMD4(0.40, 0.45, 0.57, 1) }
    var deltaLine: SIMD4<Float> { highContrast ? SIMD4(1, 1, 1, 1) : SIMD4(0.88, 0.91, 0.96, 0.95) }
}
