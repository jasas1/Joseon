import Foundation
import Accelerate

/// One biquad section in the vDSP coefficient order (b0, b1, b2, a1, a2) for
/// `y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] − a1·y[n-1] − a2·y[n-2]`.
struct BiquadSection {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double

    /// Unity gain, no state.
    static let passThrough = BiquadSection(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// One 8th-order Linkwitz-Riley skirt: two cascaded 4th-order Butterworth filters,
    /// each a pair of sections with these Q values. 48 dB per octave, -6 dB at the corner.
    static let linkwitzRiley8Qs: [Double] = [0.5411961001461969, 1.3065629648763766,
                                             0.5411961001461969, 1.3065629648763766]

    /// Second-order low-pass (RBJ cookbook).
    static func lowPass(hz: Double, sampleRate: Double, q: Double) -> BiquadSection {
        let w0 = angularFrequency(hz: hz, sampleRate: sampleRate)
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let b = (1 - cosW) / 2
        return BiquadSection(b0: b / a0, b1: (1 - cosW) / a0, b2: b / a0,
                             a1: (-2 * cosW) / a0, a2: (1 - alpha) / a0)
    }

    /// Second-order high-pass (RBJ cookbook).
    static func highPass(hz: Double, sampleRate: Double, q: Double) -> BiquadSection {
        let w0 = angularFrequency(hz: hz, sampleRate: sampleRate)
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let b = (1 + cosW) / 2
        return BiquadSection(b0: b / a0, b1: (-(1 + cosW)) / a0, b2: b / a0,
                             a1: (-2 * cosW) / a0, a2: (1 - alpha) / a0)
    }

    private static func angularFrequency(hz: Double, sampleRate: Double) -> Double {
        let limit = sampleRate * 0.49
        let f = min(max(hz, 0.1), limit)
        return 2 * Double.pi * f / sampleRate
    }
}

/// A band-pass filter bank: one 8th-order Linkwitz-Riley band-pass per listening band.
///
/// Each band runs a 4-section low-pass at the high edge followed by a 4-section high-pass
/// at the low edge, so both skirts fall at 48 dB per octave with -6 dB at the corner.
/// 24 dB per octave is not enough here: a strong tone two and a half octaves away still
/// lands 64 dB into a neighbouring band, which is loud enough to give an otherwise empty
/// band a confident, wrong correlation and balance.
///
/// The low-pass runs first on purpose. With the high-pass first, a mid-band tone walks
/// straight into the 20 Hz high-pass and its start-up transient then leaks through the
/// 60 Hz low-pass into the sub-bass band.
///
/// Left and right use the same coefficients and separate delay state. Coefficients are
/// computed for the sample rate the bank is built with; a rate change builds a new bank.
///
/// Filtering runs in double precision: the lowest band edge (20 Hz) sits at a normalized
/// frequency near 2·10⁻⁴ at 96 kHz, where single-precision direct-form biquads lose
/// accuracy.
///
/// ## All bands of a channel in one pass, eight at a time
///
/// Round 2 called `vDSP_biquadD` once per band per channel: sixteen serial cascades over the
/// same block. The bands are independent, so they can run *together* - one lane of a
/// `SIMD8<Double>` each - with the section loop outside and the sample loop inside, which
/// keeps a section's two state words in registers for the whole block.
///
/// `vDSP_biquadm`, the framework's own multichannel biquad, is the obvious thing to reach for
/// and was measured first. In double precision it is *slower* than the single-channel calls on
/// this M-series Mac (8 channels of 8 sections over 800 frames: 66.7 us for `vDSP_biquadmD`
/// against 41.5 us for eight `vDSP_biquadD`), and the float version cannot hold 20 Hz at
/// 96 kHz. The cascade below measures 27.4 us for the same work.
///
/// Arithmetic: transposed direct form II, where `vDSP_biquadD` uses direct form I. They are the
/// same filter; in double precision they agree to about 1e-13 relative, far inside the 1e-6 the
/// rewrite was allowed. `StereoFilterBankTests` checks it against an independent scalar
/// reference at 44.1, 48 and 96 kHz, in whichever build it runs in.
///
/// ## Why the debug build still calls vDSP
///
/// At `-Onone` every `SIMD8<Double>` operator is an out-of-line generic call on a 64-byte
/// value, so the same cascade measures 6757 us against vDSP's 54 us: a debug build of the app
/// would spend most of a 60 Hz tick in the filter bank. vDSP is compiled library code and does
/// not care how the caller was built, so the unoptimized build uses it. Same coefficients, same
/// filter, same test.
///
/// The one rule this adds: **ask for the bands of a block in ascending order starting at 0.**
/// Band 0 is what filters the block and advances the state.
final class BandSplitFilterBank {
    /// Sections per band: 4 low-pass then 4 high-pass.
    static let sectionsPerBand = 8
    /// Bands carried together in one `SIMD8<Double>`.
    private static let lanes = 8
    /// Frames the scratch is sized for at first use. A longer block grows it, once.
    private static let defaultCapacity = 1024

    let bandCount: Int
    let sampleRate: Double

    private let groupCount: Int
#if DEBUG
    private var setupsLeft: [vDSP_biquad_SetupD] = []
    private var setupsRight: [vDSP_biquad_SetupD] = []
    private let delays: UnsafeMutablePointer<Double>
    private let delayCount: Int
    /// vDSP wants 2*M + 2 delay slots per setup.
    private static let delayStride = 2 * sectionsPerBand + 2
#else
    /// `groupCount * sectionsPerBand` coefficient vectors, one lane per band.
    private var b0: [SIMD8<Double>]
    private var b1: [SIMD8<Double>]
    private var b2: [SIMD8<Double>]
    private var a1: [SIMD8<Double>]
    private var a2: [SIMD8<Double>]
    /// Delay state, one set per side.
    private var z1Left: [SIMD8<Double>]
    private var z2Left: [SIMD8<Double>]
    private var z1Right: [SIMD8<Double>]
    private var z2Right: [SIMD8<Double>]
#endif

    /// `bandCount * capacity` doubles: one filtered row per band, for one side.
    private var outLeft: UnsafeMutablePointer<Double>
    private var outRight: UnsafeMutablePointer<Double>
    /// The block being filtered, all bands interleaved across the lanes.
    private var lane: UnsafeMutablePointer<SIMD8<Double>>
    private var capacity: Int
    /// Frames currently held in `outLeft` / `outRight`.
    private var heldLeft = 0
    private var heldRight = 0

    /// Builds the bank. Returns nil when the edges or the sample rate make no sense.
    init?(edgesHz: [Float], sampleRate: Double) {
        guard edgesHz.count >= 2, sampleRate > 0, sampleRate.isFinite else { return nil }
        let bands = edgesHz.count - 1
        self.bandCount = bands
        self.sampleRate = sampleRate
        self.groupCount = (bands + Self.lanes - 1) / Self.lanes

        let slots = groupCount * Self.sectionsPerBand
#if DEBUG
        delayCount = bands * 2 * Self.delayStride
        delays = .allocate(capacity: delayCount)
        delays.initialize(repeating: 0, count: delayCount)
        var flat = [Double](repeating: 0, count: Self.sectionsPerBand * 5)
#else
        // Lanes with no band carry a pass-through section: they cost nothing and stay finite.
        b0 = [SIMD8<Double>](repeating: .init(repeating: 1), count: slots)
        b1 = [SIMD8<Double>](repeating: .zero, count: slots)
        b2 = [SIMD8<Double>](repeating: .zero, count: slots)
        a1 = [SIMD8<Double>](repeating: .zero, count: slots)
        a2 = [SIMD8<Double>](repeating: .zero, count: slots)
#endif

        for band in 0..<bands {
            let lowEdge = Double(edgesHz[band])
            let highEdge = Double(edgesHz[band + 1])
            // A top band that reaches past Nyquist keeps its high-pass only: a low-pass
            // that close to Nyquist buys nothing and is numerically awkward.
            let keepLowPass = highEdge < sampleRate * 0.45
            var sections: [BiquadSection] = []
            for q in BiquadSection.linkwitzRiley8Qs {
                sections.append(keepLowPass ? BiquadSection.lowPass(hz: highEdge, sampleRate: sampleRate, q: q) : .passThrough)
            }
            for q in BiquadSection.linkwitzRiley8Qs {
                sections.append(lowEdge > 0 ? BiquadSection.highPass(hz: lowEdge, sampleRate: sampleRate, q: q) : .passThrough)
            }
#if DEBUG
            for (i, s) in sections.enumerated() {
                flat[i * 5 + 0] = s.b0; flat[i * 5 + 1] = s.b1; flat[i * 5 + 2] = s.b2
                flat[i * 5 + 3] = s.a1; flat[i * 5 + 4] = s.a2
            }
            guard let left = vDSP_biquad_CreateSetupD(flat, vDSP_Length(Self.sectionsPerBand)),
                  let right = vDSP_biquad_CreateSetupD(flat, vDSP_Length(Self.sectionsPerBand)) else {
                for s in setupsLeft { vDSP_biquad_DestroySetupD(s) }
                for s in setupsRight { vDSP_biquad_DestroySetupD(s) }
                delays.deallocate()
                return nil
            }
            setupsLeft.append(left)
            setupsRight.append(right)
#else
            let group = band / Self.lanes, slot = band % Self.lanes
            for (i, s) in sections.enumerated() {
                let index = group * Self.sectionsPerBand + i
                b0[index][slot] = s.b0
                b1[index][slot] = s.b1
                b2[index][slot] = s.b2
                a1[index][slot] = s.a1
                a2[index][slot] = s.a2
            }
#endif
        }

#if !DEBUG
        z1Left = [SIMD8<Double>](repeating: .zero, count: slots)
        z2Left = [SIMD8<Double>](repeating: .zero, count: slots)
        z1Right = [SIMD8<Double>](repeating: .zero, count: slots)
        z2Right = [SIMD8<Double>](repeating: .zero, count: slots)
#else
        _ = slots
#endif

        capacity = Self.defaultCapacity
        outLeft = .allocate(capacity: bands * capacity)
        outLeft.initialize(repeating: 0, count: bands * capacity)
        outRight = .allocate(capacity: bands * capacity)
        outRight.initialize(repeating: 0, count: bands * capacity)
        lane = .allocate(capacity: capacity)
        lane.initialize(repeating: .zero, count: capacity)
    }

    deinit {
        outLeft.deallocate()
        outRight.deallocate()
        lane.deallocate()
#if DEBUG
        for s in setupsLeft { vDSP_biquad_DestroySetupD(s) }
        for s in setupsRight { vDSP_biquad_DestroySetupD(s) }
        delays.deallocate()
#endif
    }

    /// Clears the filter memory. Coefficients stay.
    func resetState() {
#if DEBUG
        delays.update(repeating: 0, count: delayCount)
#else
        for i in 0..<z1Left.count {
            z1Left[i] = .zero; z2Left[i] = .zero
            z1Right[i] = .zero; z2Right[i] = .zero
        }
#endif
        heldLeft = 0
        heldRight = 0
    }

    /// Runs the left-channel filter of one band. No allocation.
    ///
    /// `band == 0` filters the whole block through every band at once; the other bands read
    /// their row out of that result. Ask for the bands of a block in ascending order from 0.
    func filterLeft(band: Int, input: UnsafePointer<Double>, output: UnsafeMutablePointer<Double>, count: Int) {
        guard count > 0, band >= 0, band < bandCount else { return }
        if band == 0 || heldLeft != count {
            grow(to: count)
            runLeft(input: input, count: count)
            heldLeft = count
        }
        output.update(from: outLeft + band * capacity, count: count)
    }

    /// Runs the right-channel filter of one band. Same rule as `filterLeft`.
    func filterRight(band: Int, input: UnsafePointer<Double>, output: UnsafeMutablePointer<Double>, count: Int) {
        guard count > 0, band >= 0, band < bandCount else { return }
        if band == 0 || heldRight != count {
            grow(to: count)
            runRight(input: input, count: count)
            heldRight = count
        }
        output.update(from: outRight + band * capacity, count: count)
    }

#if DEBUG
    private func runLeft(input: UnsafePointer<Double>, count: Int) {
        for band in 0..<bandCount {
            vDSP_biquadD(setupsLeft[band], delays + band * Self.delayStride,
                         input, 1, outLeft + band * capacity, 1, vDSP_Length(count))
        }
    }

    private func runRight(input: UnsafePointer<Double>, count: Int) {
        for band in 0..<bandCount {
            vDSP_biquadD(setupsRight[band], delays + (bandCount + band) * Self.delayStride,
                         input, 1, outRight + band * capacity, 1, vDSP_Length(count))
        }
    }
#else
    private func runLeft(input: UnsafePointer<Double>, count: Int) {
        run(input: input, rows: outLeft, z1: &z1Left, z2: &z2Left, count: count)
    }

    private func runRight(input: UnsafePointer<Double>, count: Int) {
        run(input: input, rows: outRight, z1: &z1Right, z2: &z2Right, count: count)
    }

    /// One block through every band.
    private func run(input: UnsafePointer<Double>,
                     rows: UnsafeMutablePointer<Double>,
                     z1: inout [SIMD8<Double>],
                     z2: inout [SIMD8<Double>],
                     count: Int) {
        let sections = Self.sectionsPerBand
        for group in 0..<groupCount {
            let first = group * Self.lanes
            let last = Swift.min(first + Self.lanes, bandCount)
            for n in 0..<count { lane[n] = SIMD8<Double>(repeating: input[n]) }
            for s in 0..<sections {
                let index = group * sections + s
                let c0 = b0[index], c1 = b1[index], c2 = b2[index], d1 = a1[index], d2 = a2[index]
                var state1 = z1[index], state2 = z2[index]
                for n in 0..<count {
                    let x = lane[n]
                    let y = c0 * x + state1
                    state1 = c1 * x - d1 * y + state2
                    state2 = c2 * x - d2 * y
                    lane[n] = y
                }
                z1[index] = state1
                z2[index] = state2
            }
            for band in first..<last {
                let row = rows + band * capacity
                let slot = band - first
                for n in 0..<count { row[n] = lane[n][slot] }
            }
        }
    }
#endif

    /// Only runs when a caller sends a block longer than any before it, which in the analyzer
    /// means never after warm-up.
    private func grow(to count: Int) {
        guard count > capacity else { return }
        let wanted = Swift.max(count, capacity * 2)
        outLeft.deallocate()
        outRight.deallocate()
        lane.deallocate()
        capacity = wanted
        outLeft = .allocate(capacity: bandCount * capacity)
        outLeft.initialize(repeating: 0, count: bandCount * capacity)
        outRight = .allocate(capacity: bandCount * capacity)
        outRight.initialize(repeating: 0, count: bandCount * capacity)
        lane = .allocate(capacity: capacity)
        lane.initialize(repeating: .zero, count: capacity)
        heldLeft = 0
        heldRight = 0
    }
}
