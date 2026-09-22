import Foundation

/// Display ballistics of one peak meter channel: hold the highest level of the last
/// `holdSeconds`, then fall at `fallDBPerSecond`.
///
/// Why a sliding maximum and not a hold timer
/// ------------------------------------------
/// The obvious form — latch the display on a new peak, start a timer, fall when the
/// timer runs out — restarts the timer only when the input *exceeds* what is already
/// displayed. On repeating programme material that never happens: a kick drum hits the
/// same level every half second, but each hit lands a hair below the loudest hit so far,
/// so the timer runs on, the display falls 20 dB/s towards the material between the
/// hits, and only re-latches once it has fallen below the next hit. The display then
/// saw-tooths with a period of about `holdSeconds + fall time`, and two channels fed the
/// same mono kick saw-tooth on different phases, because their all-time maxima happen at
/// different moments. That is critic round 4 defect 10: live true peak L -5.2 dBTP
/// against R -13.8 dBTP on a mono kick whose per-channel sample peaks were 1 dB apart.
///
/// A sliding maximum has no such state: the held value is the largest level in the last
/// `holdSeconds` whatever the order of arrival, so a repeating peak holds the meter up
/// and two channels carrying the same peak read the same number.
///
/// Cost and accuracy
/// -----------------
/// The window is `slots` buckets of `holdSeconds / (slots - 1)`, so it covers between
/// `holdSeconds` and `holdSeconds · slots / (slots - 1)` — at 16 slots, 1.5 s to 1.6 s
/// of hold. Every call is a fixed number of comparisons and no allocation.
final class PeakHoldBallistics {
    /// Buckets of the sliding maximum. More slots means a tighter hold window.
    static let slots = 16

    private let floorDB: Double
    private let fallDBPerSecond: Double
    private let slotSeconds: Double
    /// Ring of bucket maxima. `write` is the newest bucket.
    private let bucket: UnsafeMutablePointer<Double>
    private var write = 0
    private var slotAge = 0.0

    /// What the meter shows, in dB.
    private(set) var display: Double

    init(holdSeconds: Double, fallDBPerSecond: Double, floorDB: Double) {
        self.floorDB = floorDB
        self.fallDBPerSecond = fallDBPerSecond
        self.slotSeconds = holdSeconds / Double(Self.slots - 1)
        self.display = floorDB
        bucket = .allocate(capacity: Self.slots)
        bucket.initialize(repeating: floorDB, count: Self.slots)
    }

    deinit { bucket.deallocate() }

    func clear() {
        bucket.update(repeating: floorDB, count: Self.slots)
        write = 0
        slotAge = 0
        display = floorDB
    }

    /// Feed the peak level of one chunk, in dB, and how long that chunk lasted.
    func update(level: Double, dt: Double) {
        slotAge += dt
        if slotAge >= slotSeconds {
            let steps = min(Int(slotAge / slotSeconds), Self.slots)
            for _ in 0..<steps {
                write += 1
                if write == Self.slots { write = 0 }
                bucket[write] = floorDB
            }
            slotAge -= Double(steps) * slotSeconds
            // A single chunk longer than the whole window has just cleared every bucket.
            if slotAge >= slotSeconds { slotAge = 0 }
        }
        if level > bucket[write] { bucket[write] = level }

        var held = floorDB
        for i in 0..<Self.slots where bucket[i] > held { held = bucket[i] }

        if held >= display {
            display = held
        } else {
            display = max(held, display - fallDBPerSecond * dt)
        }
    }
}
