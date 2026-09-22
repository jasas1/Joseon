import Foundation

// K-weighting for ITU-R BS.1770-4.
//
// The recommendation prints coefficients for 48 kHz only. Joseon plays back at
// 44.1 kHz through 768 kHz, so the coefficients are derived from the analogue
// prototype at the actual sample rate. At 48 kHz this derivation reproduces the
// table in BS.1770-4 to the printed precision (see KWeightingTests).

/// One second-order section, direct form II transposed, double-precision state.
/// Double state keeps the RLB high-pass stable over hours of listening.
struct BiquadCoefficients: Equatable {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0

    static let identity = BiquadCoefficients()
}

struct BiquadState {
    var z1: Double = 0
    var z2: Double = 0

    mutating func clear() { z1 = 0; z2 = 0 }
}

@inline(__always)
func biquadStep(_ c: BiquadCoefficients, _ s: inout BiquadState, _ x: Double) -> Double {
    let y = c.b0 * x + s.z1
    s.z1 = c.b1 * x - c.a1 * y + s.z2
    s.z2 = c.b2 * x - c.a2 * y
    return y
}

/// The two BS.1770 pre-filter stages and their design parameters.
enum KWeighting {
    /// Analogue prototype of stage 1, the head-shadow high shelf.
    /// These are the values that regenerate the 48 kHz table in BS.1770-4.
    static let shelfCenterHz = 1681.974450955533
    static let shelfGainDB = 3.999843853973347
    static let shelfQ = 0.7071752369554196
    /// Exponent that links the shelf mid-band gain to its high-band gain.
    static let shelfVbExponent = 0.4996667741545416

    /// Analogue prototype of stage 2, the RLB high-pass.
    static let highPassCenterHz = 38.13547087602444
    static let highPassQ = 0.5003270373238773

    /// Stage 1: high shelf, about +4 dB above 2 kHz.
    static func shelf(sampleRate: Double) -> BiquadCoefficients {
        let k = tan(Double.pi * shelfCenterHz / sampleRate)
        let k2 = k * k
        let vh = pow(10.0, shelfGainDB / 20.0)
        let vb = pow(vh, shelfVbExponent)
        let a0 = 1.0 + k / shelfQ + k2
        return BiquadCoefficients(
            b0: (vh + vb * k / shelfQ + k2) / a0,
            b1: 2.0 * (k2 - vh) / a0,
            b2: (vh - vb * k / shelfQ + k2) / a0,
            a1: 2.0 * (k2 - 1.0) / a0,
            a2: (1.0 - k / shelfQ + k2) / a0
        )
    }

    /// Stage 2: RLB high-pass. BS.1770 keeps the numerator at (1, -2, 1) and
    /// normalises only the denominator, so this form matches the printed table.
    static func highPass(sampleRate: Double) -> BiquadCoefficients {
        let k = tan(Double.pi * highPassCenterHz / sampleRate)
        let k2 = k * k
        let d = 1.0 + k / highPassQ + k2
        return BiquadCoefficients(
            b0: 1, b1: -2, b2: 1,
            a1: 2.0 * (k2 - 1.0) / d,
            a2: (1.0 - k / highPassQ + k2) / d
        )
    }
}

/// K-weighting for one channel: shelf then high-pass, with its own state.
struct KWeightingFilter {
    private(set) var shelf = BiquadCoefficients.identity
    private(set) var highPass = BiquadCoefficients.identity
    private var shelfState = BiquadState()
    private var highPassState = BiquadState()

    mutating func configure(sampleRate: Double) {
        shelf = KWeighting.shelf(sampleRate: sampleRate)
        highPass = KWeighting.highPass(sampleRate: sampleRate)
        clear()
    }

    mutating func clear() {
        shelfState.clear()
        highPassState.clear()
    }

    @inline(__always)
    mutating func step(_ x: Double) -> Double {
        biquadStep(highPass, &highPassState, biquadStep(shelf, &shelfState, x))
    }

    /// Filter `count` samples and return the sum of their squares. The state
    /// lives in locals for the whole loop, which is what keeps the hot path fast.
    mutating func sumOfSquares(_ x: UnsafePointer<Float>, count: Int) -> Double {
        let sc = shelf, hc = highPass
        var s1 = shelfState.z1, s2 = shelfState.z2
        var h1 = highPassState.z1, h2 = highPassState.z2
        var sum = 0.0
        for i in 0..<count {
            let input = Double(x[i])
            let mid = sc.b0 * input + s1
            s1 = sc.b1 * input - sc.a1 * mid + s2
            s2 = sc.b2 * input - sc.a2 * mid
            let out = hc.b0 * mid + h1
            h1 = hc.b1 * mid - hc.a1 * out + h2
            h2 = hc.b2 * mid - hc.a2 * out
            sum += out * out
        }
        shelfState.z1 = s1; shelfState.z2 = s2
        highPassState.z1 = h1; highPassState.z2 = h2
        return sum
    }

    /// Magnitude of the whole K-weighting chain at `hz`. Used by tests and design checks.
    func magnitude(atHz hz: Double, sampleRate: Double) -> Double {
        func mag(_ c: BiquadCoefficients) -> Double {
            let w = 2.0 * Double.pi * hz / sampleRate
            let cr = cos(w), ci = -sin(w)
            let c2r = cos(2 * w), c2i = -sin(2 * w)
            let nr = c.b0 + c.b1 * cr + c.b2 * c2r
            let ni = c.b1 * ci + c.b2 * c2i
            let dr = 1.0 + c.a1 * cr + c.a2 * c2r
            let di = c.a1 * ci + c.a2 * c2i
            return ((nr * nr + ni * ni) / (dr * dr + di * di)).squareRoot()
        }
        return mag(shelf) * mag(highPass)
    }
}
