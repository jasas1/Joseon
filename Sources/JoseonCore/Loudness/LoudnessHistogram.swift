import Foundation

/// Fixed-size loudness distribution.
///
/// Gating needs the mean power of the blocks that pass a threshold, and EBU
/// Tech 3342 needs percentiles. Both come from a histogram, so memory stays
/// constant no matter how long the measurement runs. Each bin keeps a count and
/// the exact sum of the block powers that landed in it, so the gated mean is
/// exact; only the threshold comparison is quantised, to one bin.
struct LoudnessHistogram {
    /// Bin width in LU. The brief asks for 0.1 LU or finer.
    static let binWidth = 0.05
    /// Bottom of the histogram, which is also the BS.1770 absolute gate.
    static let minLUFS = -70.0
    /// -70 LUFS up to +30 LUFS.
    static let binCount = 2000

    private(set) var counts: [Int32]
    private(set) var powers: [Double]
    private(set) var totalCount = 0
    private(set) var totalPower = 0.0

    init() {
        counts = [Int32](repeating: 0, count: Self.binCount)
        powers = [Double](repeating: 0, count: Self.binCount)
    }

    mutating func removeAll() {
        for i in 0..<Self.binCount { counts[i] = 0; powers[i] = 0 }
        totalCount = 0
        totalPower = 0
    }

    /// Loudness that represents bin `index` (its centre).
    static func loudness(ofBin index: Int) -> Double {
        minLUFS + (Double(index) + 0.5) * binWidth
    }

    /// First bin that can hold `loudness`. Clamped to the histogram.
    static func bin(forLoudness loudness: Double) -> Int {
        let raw = Int(((loudness - minLUFS) / binWidth).rounded(.down))
        return max(0, min(binCount - 1, raw))
    }

    /// Add one gating block. `power` is the BS.1770 weighted channel sum for the
    /// block; `loudness` is -0.691 + 10 log10(power). Blocks at or below the
    /// absolute gate are dropped.
    mutating func add(loudness: Double, power: Double) {
        guard loudness.isFinite, loudness > Self.minLUFS, power > 0 else { return }
        let index = Self.bin(forLoudness: loudness)
        counts[index] += 1
        powers[index] += power
        totalCount += 1
        totalPower += power
    }

    /// Count and power of every block at or above `threshold` LUFS.
    func gated(aboveLUFS threshold: Double) -> (count: Int, power: Double) {
        let start = Self.bin(forLoudness: threshold)
        var count = 0
        var power = 0.0
        for i in start..<Self.binCount {
            let c = counts[i]
            if c != 0 { count += Int(c); power += powers[i] }
        }
        return (count, power)
    }

    /// Loudness at percentile `fraction` (0...1) of the blocks at or above
    /// `threshold`. Returns nil when nothing passes the threshold.
    func percentile(_ fraction: Double, aboveLUFS threshold: Double) -> Double? {
        let start = Self.bin(forLoudness: threshold)
        var total = 0
        for i in start..<Self.binCount { total += Int(counts[i]) }
        guard total > 0 else { return nil }
        let target = Int((Double(total - 1) * fraction).rounded())
        var seen = 0
        for i in start..<Self.binCount {
            seen += Int(counts[i])
            if seen > target { return Self.loudness(ofBin: i) }
        }
        return Self.loudness(ofBin: Self.binCount - 1)
    }
}
