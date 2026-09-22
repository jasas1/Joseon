import Foundation
import CoreGraphics
import simd

/// Every color a panel uses, derived from `Theme` (plus the Increase Contrast setting).
/// Panels never hard-code a color outside this file.
struct Palette {
    var background: SIMD4<Float>
    var panel: SIMD4<Float>
    var plot: SIMD4<Float>          // plot area fill, a little deeper than the panel
    var grid: SIMD4<Float>
    var gridStrong: SIMD4<Float>
    var gridMajor: SIMD4<Float>     // labeled grid lines: 12 % white
    var gridMinor: SIMD4<Float>     // minor log lines: 5 % white
    var rms: SIMD4<Float>
    var text: SIMD4<Float>
    var textDim: SIMD4<Float>
    var textFaint: SIMD4<Float>
    var accent: SIMD4<Float>
    var warn: SIMD4<Float>
    var danger: SIMD4<Float>
    var good: SIMD4<Float>
    var left: SIMD4<Float>
    var right: SIMD4<Float>
    /// L and R in the spectrum: desaturated tints at 75 %, so neither can be taken for the Mid hue (R was the Mid hue under 100 Hz).
    var spectrumLeft: SIMD4<Float>
    var spectrumRight: SIMD4<Float>
    var peakHold: SIMD4<Float>
    var average: SIMD4<Float>
    var side: SIMD4<Float>
    var hpResponse: SIMD4<Float>
    var hpTarget: SIMD4<Float>
    var hpAtEar: SIMD4<Float>
    /// Third-octave SPL bars of the spectrum and their right-hand axis: a pale ice blue that no curve uses. The layer
    /// multiplies the alpha down (it stands behind the curves); the axis text uses it opaque.
    var splBand: SIMD4<Float>
    /// The ghost trace of the linked cursor (the spectrum at a past moment): the spectrogram's cyan #39C2FF at 85 %, drawn dashed.
    var cursorGhost: SIMD4<Float>
    var track: SIMD4<Float>         // empty meter track
    var highContrast: Bool

    init(theme: Theme, highContrast: Bool) {
        self.highContrast = highContrast
        background = theme.background
        panel = theme.panel
        plot = SIMD4(theme.background.x * 0.72, theme.background.y * 0.72, theme.background.z * 0.78, 1)
        var g = theme.grid
        if highContrast { g.w = min(g.w * 2.3, 0.75) }
        grid = g
        gridStrong = SIMD4(g.x, g.y, g.z, min(g.w * 1.9, 0.9))
        // The theme's grid alpha (default 0.22) scales both: a theme can still make the grid stronger or lighter.
        let gk = theme.grid.w / 0.22 * (highContrast ? 2.2 : 1)
        gridMajor = SIMD4(1, 1, 1, min(0.12 * gk, 0.5))
        gridMinor = SIMD4(1, 1, 1, min(0.05 * gk, 0.25))
        let t = highContrast ? SIMD4<Float>(1, 1, 1, 1) : theme.text
        text = t
        // Opaque, so the contrast is known: ticks and headers stay at 7:1 or better on the panel background.
        let bgc = theme.background
        textDim = highContrast ? SIMD4(0.94, 0.95, 0.97, 1) : SIMD4(t.x + (bgc.x - t.x) * 0.16, t.y + (bgc.y - t.y) * 0.16, t.z + (bgc.z - t.z) * 0.16, 1)
        textFaint = highContrast ? SIMD4(0.86, 0.88, 0.92, 1) : SIMD4(t.x + (bgc.x - t.x) * 0.27, t.y + (bgc.y - t.y) * 0.27, t.z + (bgc.z - t.z) * 0.27, 1)
        rms = SIMD4(0.357, 0.420, 0.541, 1)
        accent = theme.accent
        warn = theme.warn
        danger = theme.danger
        good = SIMD4(0.30, 0.92, 0.62, 1)
        left = SIMD4(0.42, 0.70, 1.0, 0.9)
        right = SIMD4(1.0, 0.56, 0.42, 0.8)    // a little see-through: where L and R coincide, both colors show
        spectrumLeft = SIMD4(0x7F / 255.0, 0xA6 / 255.0, 0xD9 / 255.0, highContrast ? 0.9 : 0.75)     // #7FA6D9
        spectrumRight = SIMD4(0xD9 / 255.0, 0x90 / 255.0, 0x7F / 255.0, highContrast ? 0.9 : 0.75)    // #D9907F
        peakHold = SIMD4(0.949, 0.914, 0.847, highContrast ? 0.95 : 0.80)    // #F2E9D8 warm white
        average = SIMD4(0.478, 0.525, 0.627, highContrast ? 0.85 : 0.60)      // #7A86A0 cool grey
        side = SIMD4(0.780, 0.490, 1.0, highContrast ? 0.95 : 0.80)           // #C77DFF magenta-violet
        hpResponse = theme.warn
        hpTarget = highContrast ? SIMD4(0.85, 0.88, 0.94, 1) : SIMD4(0.604, 0.643, 0.722, 1)
        hpAtEar = SIMD4(1.0, 0.36, 0.80, 1)
        splBand = highContrast ? SIMD4(0.90, 0.95, 1.0, 1) : SIMD4(0.72, 0.84, 1.0, 1)
        cursorGhost = SIMD4(0x39 / 255.0, 0xC2 / 255.0, 1.0, highContrast ? 1.0 : 0.85)
        track = SIMD4(theme.panel.x * 1.5, theme.panel.y * 1.5, theme.panel.z * 1.45, 1)
    }

    // MARK: Color maps

    /// Hue across the log frequency axis: warm lows, green mids, cyan to violet highs.
    /// `t` = 0 at 10 Hz, 1 at 24 kHz.
    static let spectrumStops: [(Float, SIMD3<Float>)] = [
        (0.00, SIMD3(0.96, 0.22, 0.30)),   // 10 Hz   deep rose red
        (0.14, SIMD3(1.00, 0.38, 0.20)),   // 30 Hz   red orange
        (0.27, SIMD3(1.00, 0.62, 0.14)),   // 80 Hz   amber
        (0.40, SIMD3(0.96, 0.86, 0.22)),   // 220 Hz  yellow
        (0.53, SIMD3(0.50, 0.94, 0.34)),   // 600 Hz  green
        (0.65, SIMD3(0.16, 0.92, 0.66)),   // 1.6 kHz sea green
        (0.76, SIMD3(0.14, 0.80, 0.98)),   // 3.7 kHz cyan
        (0.87, SIMD3(0.32, 0.54, 1.00)),   // 8.7 kHz blue
        (1.00, SIMD3(0.70, 0.42, 1.00)),   // 24 kHz  violet
    ]

    func spectrumLUT(count: Int = 256) -> [SIMD3<Float>] {
        ColorMap.sample(Self.spectrumStops, count: count)
    }

    static func spectrumColor(atHz hz: Float) -> SIMD3<Float> {
        let t = log(max(hz, 10) / 10) / log(Float(2400))
        return ColorMap.evaluate(spectrumStops, at: min(max(t, 0), 1))
    }

    /// Spectrogram map: exactly the plot background at 0 (no haze under the floor), a short navy toe, then blue, cyan,
    /// green, yellow, hot white. Lightness rises steadily.
    func heatLUT(count: Int = 256) -> [SIMD3<Float>] {
        let bg = SIMD3(plot.x, plot.y, plot.z)
        // Positions are linear in dB between the floor (-75) and the automatic top. With the top at -18: -65 dB = 0.18,
        // -59 dB = 0.28, -46 dB = 0.51. The lightness climbs fastest between 0.15 and 0.55, where quiet tones meet the noise.
        let stops: [(Float, SIMD3<Float>)] = [
            (0.00, bg),
            (0.07, SIMD3(0.030, 0.060, 0.200)),
            (0.18, SIMD3(0.055, 0.130, 0.420)),   // a noise floor 10 dB over the black point: dark navy
            (0.30, SIMD3(0.075, 0.270, 0.720)),
            (0.42, SIMD3(0.060, 0.470, 0.880)),
            (0.53, SIMD3(0.090, 0.680, 0.900)),   // 20 dB over that floor: bright cyan-blue
            (0.64, SIMD3(0.080, 0.810, 0.700)),
            (0.75, SIMD3(0.350, 0.900, 0.400)),
            (0.86, SIMD3(0.960, 0.880, 0.240)),
            (0.94, SIMD3(1.000, 0.640, 0.260)),
            (1.00, SIMD3(1.000, 0.970, 0.920)),
        ]
        return ColorMap.sample(stops, count: count)
    }

    /// Vectorscope density ramp: black, deep blue #0B3A8C, cyan #39C2FF, warm white capped at 90 % luminance.
    /// The ramp never reaches pure white: the densest core keeps its texture.
    func scopeLUT(count: Int = 256) -> [SIMD3<Float>] {
        let stops: [(Float, SIMD3<Float>)] = [
            (0.00, SIMD3(0, 0, 0)),
            (0.22, SIMD3(0.043, 0.227, 0.549)),
            (0.62, SIMD3(0.224, 0.761, 1.000)),
            (0.86, SIMD3(0.560, 0.860, 0.970)),
            (1.00, SIMD3(0.800, 0.920, 0.960)),   // luminance 0.90: the core keeps its texture
        ]
        return ColorMap.sample(stops, count: count)
    }
}

enum ColorMap {
    /// Interpolates in OKLab so the ramp has no muddy or dark bands between stops.
    static func evaluate(_ stops: [(Float, SIMD3<Float>)], at t: Float) -> SIMD3<Float> {
        guard let first = stops.first, let last = stops.last else { return .zero }
        if t <= first.0 { return first.1 }
        if t >= last.0 { return last.1 }
        for i in 1..<stops.count where t <= stops[i].0 {
            let a = stops[i - 1], b = stops[i]
            var k = (t - a.0) / max(b.0 - a.0, 1e-6)
            k = k * k * (3 - 2 * k) * 0.35 + k * 0.65      // slight ease, keeps the ramp smooth at the stops
            let la = oklab(fromSRGB: a.1), lb = oklab(fromSRGB: b.1)
            return srgb(fromOKLab: la + (lb - la) * k)
        }
        return last.1
    }

    static func sample(_ stops: [(Float, SIMD3<Float>)], count: Int) -> [SIMD3<Float>] {
        (0..<count).map { evaluate(stops, at: Float($0) / Float(count - 1)) }
    }

    private static func toLinear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func toGamma(_ c: Float) -> Float {
        let v = max(c, 0)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    static func oklab(fromSRGB c: SIMD3<Float>) -> SIMD3<Float> {
        let r = toLinear(c.x), g = toLinear(c.y), b = toLinear(c.z)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func srgb(fromOKLab c: SIMD3<Float>) -> SIMD3<Float> {
        let l_ = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z
        let m_ = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z
        let s_ = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return SIMD3(min(toGamma(r), 1), min(toGamma(g), 1), min(toGamma(b), 1))
    }
}

extension SIMD4 where Scalar == Float {
    func withAlpha(_ a: Float) -> SIMD4<Float> { SIMD4(x, y, z, a) }
    func scaledAlpha(_ k: Float) -> SIMD4<Float> { SIMD4(x, y, z, w * k) }
    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(x), green: CGFloat(y), blue: CGFloat(z), alpha: CGFloat(w))
    }
}

extension SIMD3 where Scalar == Float {
    func rgba(_ a: Float = 1) -> SIMD4<Float> { SIMD4(x, y, z, a) }
}
