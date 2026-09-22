import Accelerate
import Foundation

// MARK: - Fixed-size scratch storage
//
// Every buffer the analyzer touches inside `process` is allocated here, at configure
// time. `process` then runs with raw pointers only: no Swift array, no copy-on-write,
// no heap traffic.

/// A fixed-size block of `Float`. Allocated once, reused forever.
final class FloatScratch {
    let count: Int
    let p: UnsafeMutablePointer<Float>

    init(_ count: Int) {
        self.count = Swift.max(count, 1)
        p = .allocate(capacity: self.count)
        p.initialize(repeating: 0, count: self.count)
    }

    deinit { p.deallocate() }

    func fill(_ value: Float) {
        var v = value
        vDSP_vfill(&v, p, 1, vDSP_Length(count))
    }

    func zero() { fill(0) }
}

/// A fixed-size block of `Int32`. Used for the display-bin maps.
final class Int32Scratch {
    let count: Int
    let p: UnsafeMutablePointer<Int32>

    init(_ count: Int) {
        self.count = Swift.max(count, 1)
        p = .allocate(capacity: self.count)
        p.initialize(repeating: 0, count: self.count)
    }

    deinit { p.deallocate() }

    func fill(_ value: Int32) {
        for i in 0..<count { p[i] = value }
    }
}

// MARK: - Small numeric helpers

@inline(__always) func joseonNextPow2(_ v: Int) -> Int {
    var n = 1
    while n < v { n <<= 1 }
    return n
}

/// Power of two closest to `v` on a log scale. Keeps window *durations* similar when the
/// sample rate changes: 32768 at 48 kHz stays 32768 at 44.1 kHz and becomes 65536 at 96 kHz.
@inline(__always) func joseonNearestPow2(_ v: Double, min lo: Int, max hi: Int) -> Int {
    guard v > 1 else { return lo }
    let exponent = Int(log2(v).rounded())
    return Swift.min(Swift.max(1 << Swift.max(exponent, 0), lo), hi)
}

// MARK: - Note names

/// Equal temperament with A4 = 440 Hz.
enum NoteNamer {
    static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Name plus offset in cents (-50...+50). Empty name when the frequency is not a usable note.
    static func note(forHz hz: Float) -> (name: String, cents: Float) {
        guard hz > 0, hz.isFinite else { return ("", 0) }
        // MIDI number as a real: 69 = A4 = 440 Hz.
        let midi = 12 * log2(Double(hz) / 440.0) + 69
        guard midi.isFinite, midi > -0.5, midi < 127.5 else { return ("", 0) }
        let nearest = Int(midi.rounded())
        let cents = Float((midi - Double(nearest)) * 100)
        let octave = nearest / 12 - 1
        return (names[nearest % 12] + String(octave), cents)
    }
}
