import Foundation
import XCTest
@testable import JoseonCore

// Shared helpers for the loudness tests. EBU Tech 3341/3342 style: synthetic
// signals only, nothing read from disk, nothing recorded.

enum LoudnessTestSupport {
    /// Peak amplitude for a level in dBFS, where 0 dBFS is a full-scale sine.
    static func amplitude(dBFS: Double) -> Float { Float(pow(10.0, dBFS / 20.0)) }

    /// Continuous sine of `seconds` at `hz`, peak level `dBFS`.
    static func sine(hz: Double, dBFS: Double, sampleRate: Double, seconds: Double) -> [Float] {
        TestSignals.sine(hz: hz, amplitude: amplitude(dBFS: dBFS), sampleRate: sampleRate, seconds: seconds)
    }

    /// One continuous sine whose level follows `segments` of (dBFS, seconds).
    /// The phase never jumps, so no segment boundary adds a click.
    static func steppedSine(hz: Double, sampleRate: Double, segments: [(dBFS: Double, seconds: Double)]) -> [Float] {
        let total = segments.reduce(0.0) { $0 + $1.seconds }
        var out = TestSignals.sine(hz: hz, amplitude: 1, sampleRate: sampleRate, seconds: total)
        var start = 0
        for segment in segments {
            let n = Int(sampleRate * segment.seconds)
            let end = min(start + n, out.count)
            let gain = amplitude(dBFS: segment.dBFS)
            for i in start..<end { out[i] *= gain }
            start = end
        }
        if start < out.count {
            let gain = amplitude(dBFS: segments.last?.dBFS ?? 0)
            for i in start..<out.count { out[i] *= gain }
        }
        return out
    }

    /// Push a signal through the meter in realistic capture-sized blocks.
    static func feed(_ meter: LoudnessMetering,
                     left: [Float],
                     right: [Float],
                     sampleRate: Double,
                     blockFrames: Int = 800) {
        precondition(left.count == right.count)
        left.withUnsafeBufferPointer { lb in
            right.withUnsafeBufferPointer { rb in
                guard let lp = lb.baseAddress, let rp = rb.baseAddress else { return }
                var i = 0
                while i < left.count {
                    let n = min(blockFrames, left.count - i)
                    meter.process(left: lp + i, right: rp + i, count: n, sampleRate: sampleRate)
                    i += n
                }
            }
        }
    }

    /// Feed the same signal to both channels.
    static func feedMono(_ meter: LoudnessMetering, _ signal: [Float], sampleRate: Double, blockFrames: Int = 800) {
        feed(meter, left: signal, right: signal, sampleRate: sampleRate, blockFrames: blockFrames)
    }

}

extension XCTestCase {
    func assertClose(_ value: Float,
                     _ expected: Double,
                     _ tolerance: Double,
                     _ label: String,
                     file: StaticString = #filePath,
                     line: UInt = #line) {
        XCTAssertTrue(value.isFinite, "\(label) is not finite: \(value)", file: file, line: line)
        XCTAssertEqual(Double(value), expected, accuracy: tolerance,
                       "\(label): got \(value), want \(expected) ±\(tolerance)", file: file, line: line)
    }
}
