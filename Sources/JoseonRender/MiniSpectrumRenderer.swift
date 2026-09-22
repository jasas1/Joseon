import AppKit
import Accelerate
import JoseonCore

/// Draws the menu bar mini spectrum. Must be cheap: called about 30 times per second.
///
/// Core Graphics only. One bitmap context is kept per pixel size, so a call does no large allocation.
/// By default the result is a template image: macOS tints it for the light or dark menu bar.
/// Set `accentColor` to draw in a fixed color instead (non-template).
///
/// The bitmap is BGRA, premultiplied alpha first: the format Core Animation takes as layer contents without
/// a conversion. Every column is a whole number of device pixels wide. The silhouette runs through the column
/// centers, so a tone has sloped flanks and a thin peak stays about one column wide at half height.
///
/// Column level = the mean power of the spectrum bins under a triangle two columns wide, centered on the column.
/// Round 4 took the maximum per column: a tone is a lobe about four display bins wide, so it filled two or three
/// columns to the same height with vertical sides — a flat-topped box. The mean follows the lobe: the column under
/// the tone is the highest and its neighbors are shoulders.
///
/// The renderer keeps a little state between calls (column ballistics and the adaptive range).
/// The time step comes from `AnalysisFrame.hostTime`, so the motion does not depend on the call rate.
public final class MiniSpectrumRenderer {
    /// Log columns across the image. Used as is when `scalesBandCountWithWidth` is off.
    public var bandCount = 56 { didSet { bandCount = min(max(bandCount, 8), Self.capacity) } }
    /// On: one column per `columnPixels` device pixels, so the column edges sit on whole pixels.
    public var scalesBandCountWithWidth = true
    /// Column width in device pixels when `scalesBandCountWithWidth` is on. 1 = the finest picture the menu bar
    /// can show: two tones a third of an octave apart keep a valley between them at every width.
    public var columnPixels = 1 { didSet { columnPixels = max(columnPixels, 1) } }
    /// The outer columns are scaled down over this width (in points, at least 2 device pixels), so neither strong
    /// bass nor a bright top end makes a full-height wall at an edge of the picture. The taper scales the real
    /// data: two columns at 1/3 and 2/3. It is short on purpose. A long taper ends every picture in the same ramp.
    public var edgeTaperPoints: CGFloat = 1
    /// The first column starts here. 30 Hz stays clear of the level shelf below 20–30 Hz in the spectrum data,
    /// which showed as a false cliff at the left edge.
    public var minHz: Float = 30
    /// The last column ends here. Up to round 5 it was 16 kHz: the picture stopped in the middle of the roll-off
    /// of the top octave, so every picture ended in the same shoulder. At 20 kHz the picture ends where the
    /// music ends: a bright master ends high, a lossy file ends at its cut-off.
    public var maxHz: Float = 20_000
    /// Lowest level of interest. The adaptive window top never goes below `minDB + adaptiveWindowDB`.
    public var minDB: Float = -96
    public var maxDB: Float = -6
    /// The mini graph's own display tilt in dB per octave, pivot 1 kHz. Music falls about 4.5 dB per octave
    /// (pink noise 3, most masters more): with less tilt real music is a bass blob and a flat line for the top
    /// 60 % of the width. This is a drawing choice, not a measurement, and it does not follow the Tilt setting of
    /// the main spectrum. It adds to `SpectrumSettings.tiltDBPerOctave` when the engine already tilts the
    /// spectrum data: the caller subtracts the engine tilt, so the total stays `defaultTiltDBPerOctave`.
    public var tiltDBPerOctave: Float = MiniSpectrumRenderer.defaultTiltDBPerOctave
    public static let defaultTiltDBPerOctave: Float = 4.5
    /// The renderer tilt for spectrum data the engine tilted by `engineTilt` already: the total stays +4.5.
    public static func tilt(engineTilt: Float) -> Float { max(0, defaultTiltDBPerOctave - engineTilt) }
    /// Contrast curve on the 0...1 level. Above 1 quiet parts sink and peaks stand out.
    public var contrast: Float = 1.6
    /// Columns fall with this time constant.
    public var releaseSeconds: Float = 0.15
    /// Columns rise with this time constant: at 20 pictures per second a new sound is at 92 % on its first
    /// picture. An instant attack kept every column a tone touched for one frame at the top for the whole release:
    /// that widened a tone that moves by one column into a box.
    public var attackSeconds: Float = 0.02

    /// Follows the music level: the window `adaptiveWindowDB` slides inside minDB...maxDB so the shape stays
    /// readable at any volume. It moves slowly (see `rangeAttackSeconds`, `rangeReleaseSeconds`) so the picture
    /// does not pump with the beat. Off = fixed minDB...maxDB.
    public var adaptiveRange = true
    public var adaptiveWindowDB: Float = 48
    public var rangeAttackSeconds: Float = 0.2
    public var rangeReleaseSeconds: Float = 8

    /// nil = template image (black + alpha, the menu bar tints it). A color = draw in that color, non-template.
    public var accentColor: NSColor? {
        didSet { accentCG = accentColor?.usingColorSpace(.sRGB)?.cgColor ?? accentColor?.cgColor }
    }

    private static let capacity = 320
    /// Distance of the loudest column to the top of the adaptive window.
    private static let headroomDB: Float = 3
    /// The soft knee starts here (0...1 of the window). `headroomDB` of 3 in a 48 dB window puts the top at 0.9375.
    private static let kneeStart: Float = 0.94
    private var accentCG: CGColor?
    private let black = CGColor(gray: 0, alpha: 1)
    /// Top of the adaptive window in dB. Internal for tests.
    private(set) var ceilingDB: Float?
    private var lastHostTime: TimeInterval?
    private var lastCount = 0
    private var tilted = [Float](repeating: -200, count: capacity)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private var context: CGContext?
    private var contextWidth = 0, contextHeight = 0
    // Per column: first bin, bin count and offset into `weights`. Cached while the spectrum layout stays the same.
    private var bandLo = [Int](repeating: 0, count: capacity), bandCountBins = [Int](repeating: 0, count: capacity)
    private var bandOffset = [Int](repeating: 0, count: capacity)
    /// Triangle weights of every column, one after the other. Each column's weights sum to 1.
    private var weights = [Float]()
    /// Bin power (linear) of the frame. Reused.
    private var power = [Float]()
    private var bandOctave = [Float](repeating: 0, count: capacity)
    private var layoutKey: (Int, Float, Float, Int, Float, Float) = (0, 0, 0, 0, 0, 0)
    /// Edge taper per column, 0...1. Rebuilt when the column count or the taper width changes.
    private var edgeGain = [Float](repeating: 1, count: capacity)
    private var edgeKey: (Int, CGFloat) = (0, 0)
    private var pointsPerColumnKey: CGFloat = 0
    /// The per-column level in dB before tilt and mapping. Internal for tests.
    private(set) var columnDB = [Float](repeating: -200, count: capacity)
    /// Shown level per column, 0...1, after ballistics. Internal for tests.
    private(set) var shown = [Float](repeating: 0, count: capacity)
    private var points = [CGPoint]()

    public init() {}

    /// Columns used for an image `widthPoints` wide with `pixelWidth` pixels.
    func columnCount(widthPoints: CGFloat, pixelWidth: Int) -> Int {
        guard scalesBandCountWithWidth else { return min(bandCount, max(pixelWidth, 1)) }
        return min(max(pixelWidth / columnPixels, 1), Self.capacity)
    }

    /// Left edge of column `i` in device pixels: a whole number, and the last edge is the image width.
    @inline(__always) private func columnEdge(_ i: Int, count n: Int, pixelWidth pw: Int) -> CGFloat {
        CGFloat((i * pw + n / 2) / n)
    }

    /// Image of the current spectrum, sized for an NSStatusItem (for example 64x18 pt).
    public func image(for frame: AnalysisFrame, size: CGSize, scale: CGFloat) -> NSImage {
        let w = max(size.width, 1), h = max(size.height, 1)
        guard let cgImage = cgImage(for: frame, size: size, scale: scale) else { return NSImage(size: size) }
        let image = NSImage(cgImage: cgImage, size: CGSize(width: w, height: h))
        image.isTemplate = accentCG == nil
        return image
    }

    /// The same picture as a bitmap in the layer-native format (BGRA, premultiplied alpha first).
    /// Use it as `CALayer.contents`: no NSImage, no channel swap, no color match on commit.
    public func cgImage(for frame: AnalysisFrame, size: CGSize, scale: CGFloat) -> CGImage? {
        let w = max(size.width, 1), h = max(size.height, 1)
        let sc = max(scale, 1)
        let pw = max(Int((w * sc).rounded()), 1), ph = max(Int((h * sc).rounded()), 1)
        guard let cg = bitmap(width: pw, height: ph) else { return nil }

        cg.clear(CGRect(x: 0, y: 0, width: pw, height: ph))
        let n = columnCount(widthPoints: w, pixelWidth: pw)
        let any = update(frame, count: n, pointsPerColumn: w / CGFloat(n))

        let hair = max(sc.rounded(), 1)                 // one point tall baseline
        let usable = CGFloat(ph) - 1 - hair

        cg.setFillColor(accentCG ?? black)
        // Hairline: the whole picture at silence.
        cg.fill(CGRect(x: 0, y: 0, width: CGFloat(pw), height: hair))

        if any {
            // One filled silhouette through the column centers. Round 4 drew a flat top per column: a tone that
            // sits between two columns was a box two pixels wide with vertical sides. Lines between the column
            // centers give the same tone sloped flanks, so it reads as a lobe. A one-column peak is a spike one
            // column wide at half height: still thin.
            if points.count != n + 4 { points = [CGPoint](repeating: .zero, count: n + 4) }
            points[0] = CGPoint(x: 0, y: hair)
            points[1] = CGPoint(x: 0, y: hair + CGFloat(shown[0]) * usable)
            for i in 0..<n {
                let x = (columnEdge(i, count: n, pixelWidth: pw) + columnEdge(i + 1, count: n, pixelWidth: pw)) / 2
                points[i + 2] = CGPoint(x: x, y: hair + CGFloat(shown[i]) * usable)
            }
            points[n + 2] = CGPoint(x: CGFloat(pw), y: hair + CGFloat(shown[n - 1]) * usable)
            points[n + 3] = CGPoint(x: CGFloat(pw), y: hair)
            cg.beginPath()
            cg.addLines(between: points)
            cg.closePath()
            cg.fillPath()
        }

        // `CGContext.makeImage()` costs about 0.15 ms after a draw. A plain copy of the 18 KB bitmap is far cheaper.
        guard let base = cg.data, let provider = CGDataProvider(data: NSData(bytes: base, length: cg.bytesPerRow * ph)) else { return nil }
        return CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cg.bytesPerRow,
                       space: colorSpace, bitmapInfo: Self.bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    /// BGRA in memory, premultiplied: Core Animation uses this layout as it is.
    private static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    private func bitmap(width: Int, height: Int) -> CGContext? {
        if width == contextWidth, height == contextHeight, let context { return context }
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: Self.bitmapInfo.rawValue)
        context?.setShouldAntialias(true)
        context?.interpolationQuality = .none
        contextWidth = width; contextHeight = height
        return context
    }

    /// Updates `shown` from the frame. Returns false when there is nothing to draw but the hairline.
    private func update(_ frame: AnalysisFrame, count n: Int, pointsPerColumn: CGFloat) -> Bool {
        let s = frame.spectrum
        // Time step from the frame clock. The same frame again = no time passed. A jump = start over.
        var dt: Float = 0
        var restart = n != lastCount
        if let last = lastHostTime {
            let d = frame.hostTime - last
            if d < 0 || d > 1 { restart = true } else { dt = Float(d) }
        } else {
            restart = true
        }
        lastHostTime = frame.hostTime
        lastCount = n
        if restart {
            for i in 0..<n { shown[i] = 0 }
            ceilingDB = nil
        }

        let bins = min(s.mid.count, s.frequencies.count)
        guard bins >= 2, let f0 = s.frequencies.first, f0 > 0, s.frequencies[bins - 1] > f0 else {
            for i in 0..<n { shown[i] = 0 }
            return false
        }
        let key = (bins, f0, s.frequencies[bins - 1], n, minHz, maxHz)
        if key != layoutKey {
            layoutKey = key
            let lnF0 = log(f0), lnSpan = log(s.frequencies[bins - 1]) - lnF0
            let lnMin = log(minHz), lnBand = (log(maxHz) - lnMin) / Float(n)
            weights.removeAll(keepingCapacity: true)
            for b in 0..<n {
                // Bin coordinates of the column center and of the triangle's half width (one column).
                let center = (lnMin + lnBand * (Float(b) + 0.5) - lnF0) / lnSpan * Float(bins - 1)
                let half = max(lnBand / lnSpan * Float(bins - 1), 1)
                let i0 = min(max(Int((center - half).rounded(.up)), 0), bins - 1)
                let i1 = min(max(Int((center + half).rounded(.down)), i0), bins - 1)
                bandLo[b] = i0
                bandCountBins[b] = i1 - i0 + 1
                bandOffset[b] = weights.count
                var sum: Float = 0
                for i in i0...i1 {
                    let w = max(1 - abs(Float(i) - center) / half, 0.02)
                    weights.append(w)
                    sum += w
                }
                for k in bandOffset[b]..<weights.count { weights[k] /= sum }
                bandOctave[b] = (lnMin + lnBand * (Float(b) + 0.5) - log(Float(1000))) / log(Float(2))
            }
        }

        if edgeKey != (n, edgeTaperPoints) || pointsPerColumnKey != pointsPerColumn {
            edgeKey = (n, edgeTaperPoints)
            pointsPerColumnKey = pointsPerColumn
            // A short linear scale on the real data: with 2 columns the gains are 1/3 and 2/3. No column is forced
            // to the baseline, so the shape of the music is what ends the picture, not a ramp.
            let reach = min(max(Int((edgeTaperPoints / max(pointsPerColumn, 0.01)).rounded()), 2), max(n / 4, 1))
            for b in 0..<n {
                let d = min(b, n - 1 - b)
                edgeGain[b] = d >= reach ? 1 : Float(d + 1) / Float(reach + 1)
            }
        }

        // Per column: the mean power of the mid bins under the column's triangle, plus the display tilt.
        let tilt = tiltDBPerOctave
        let floorDB = SpectrumReading.floorDB + 1
        var top: Float = -200
        if power.count != bins { power = [Float](repeating: 0, count: bins) }
        s.mid.withUnsafeBufferPointer { mid in
            power.withUnsafeMutableBufferPointer { pw in
                // dB -> power: 10^(dB / 10) = exp(dB * ln(10) / 10)
                var count = Int32(bins), k: Float = 0.2302585093
                vDSP_vsmul(mid.baseAddress!, 1, &k, pw.baseAddress!, 1, vDSP_Length(bins))
                vvexpf(pw.baseAddress!, pw.baseAddress!, &count)
            }
        }
        let floorPower = pow(10, floorDB / 10)
        power.withUnsafeBufferPointer { pw in
            weights.withUnsafeBufferPointer { wt in
                for b in 0..<n {
                    var mean: Float = 0
                    vDSP_dotpr(pw.baseAddress! + bandLo[b], 1, wt.baseAddress! + bandOffset[b], 1, &mean, vDSP_Length(bandCountBins[b]))
                    let db: Float = mean <= floorPower ? -200 : 10 * log10(mean)
                    columnDB[b] = db
                    let v = db < -199 ? -200 : db + tilt * bandOctave[b]
                    tilted[b] = v
                    if v > top { top = v }
                }
            }
        }

        // Vertical window. The top follows the loudest column: up within about half a second, down over many
        // seconds. It rides the peaks, so a kick drum does not make the whole picture breathe.
        var lo = minDB, hi = maxDB
        if adaptiveRange {
            let window = min(adaptiveWindowDB, maxDB - minDB)
            if top > -199 {
                // The loudest column sits `headroomDB` under the top of the window, below the soft knee:
                // in the steady state no peak touches the knee, so every peak keeps its shape.
                let target = min(max(top + Self.headroomDB, minDB + window), maxDB)
                if let c = ceilingDB {
                    let tau = target > c ? rangeAttackSeconds : rangeReleaseSeconds
                    ceilingDB = c + (target - c) * (1 - exp(-dt / max(tau, 0.001)))
                } else {
                    ceilingDB = target
                }
            }
            hi = ceilingDB ?? maxDB
            lo = hi - window
        }

        let keep = dt > 0 ? exp(-dt / max(releaseSeconds, 0.001)) : 1
        // The first picture after a restart shows the level at once.
        let rise: Float = restart ? 1 : (dt > 0 ? 1 - exp(-dt / max(attackSeconds, 0.001)) : 0)
        let invRange = 1 / max(hi - lo, 1)
        let gamma = contrast
        var any = false
        for b in 0..<n {
            var t = tilted[b] < -199 ? 0 : max((tilted[b] - lo) * invRange, 0)
            // Soft knee: only a transient that beats the window (before the ceiling follows) bends toward the
            // top edge. It starts above the steady-state top, so it does not flatten the normal peaks.
            if t > Self.kneeStart { t = Self.kneeStart + (1 - Self.kneeStart) * (1 - exp(-(t - Self.kneeStart) / (1 - Self.kneeStart))) }
            var level = gamma == 1 ? t : pow(t, gamma)
            // The two outer columns are scaled down: no full-height wall at the image border.
            level *= edgeGain[b]
            let old = shown[b]
            let v = level > old ? old + (level - old) * rise : max(level, old * keep)   // fast attack, exponential release
            shown[b] = v < 0.004 ? 0 : v
            if shown[b] > 0 { any = true }
        }
        return any
    }
}
