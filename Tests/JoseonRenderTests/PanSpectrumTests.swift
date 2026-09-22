import XCTest
import JoseonCore
@testable import JoseonRender

/// Critic r2 defect 5: stereo placement geometry. A tone in one channel is a compact dot at that side.
final class PanSpectrumTests: XCTestCase {
    /// A 6 kHz tone in the right channel only, over digital silence.
    static func rightOnlyToneFrames(count: Int, hz: Float = 6000) -> [AnalysisFrame] {
        var s = SpectrumReading.silent(binCount: 1024)
        let i = s.frequencies.indices.min(by: { abs(s.frequencies[$0] - hz) < abs(s.frequencies[$1] - hz) })!
        for (k, db) in [(-2, -58), (-1, -32), (0, -20), (1, -32), (2, -58)] as [(Int, Float)] {
            s.right[i + k] = db; s.mid[i + k] = db - 6; s.side[i + k] = db - 6
        }
        return (0..<count).map { k in
            var f = AnalysisFrame(hostTime: 10 + Double(k) / 60, spectrum: s, isSilent: false)
            f.stream = StreamInfo(sampleRate: 48_000, channelCount: 2, deviceName: "Test")
            return f
        }
    }

    func testRightOnlyToneIsACompactDotAtTheFarRight() throws {
        try RenderTestSupport.requireMetal()
        var settings = OffscreenRenderer.Settings(); settings.vectorscopeMode = .panSpectrum
        let size = CGSize(width: 1200, height: 600)
        let session = try OffscreenRenderer.Session(panel: .vectorscope, size: size, scale: 2, theme: Theme(), settings: settings)
        let r = try XCTUnwrap(session.renderer as? VectorscopeRenderer)
        r.keepsSplatsForTesting = true
        try session.feed(Self.rightOnlyToneFrames(count: 40))
        let lit = try RenderTestSupport.decode(png: session.snapshotPNG())
        RenderTestSupport.write(try session.snapshotPNG(), "panspectrum-right-only.png")

        // The numbers: every splat is at pan +1 and sits at 6 kHz.
        XCTAssertFalse(r.lastSplats.isEmpty)
        for s in r.lastSplats {
            XCTAssertGreaterThan(s.x, 0.99, "pan of a right-only tone")
            XCTAssertEqual(s.y, log(Float(6000) / 20) / log(Float(1000)), accuracy: 0.01)
        }

        // The picture: the light the tone adds over an empty field.
        let emptySession = try OffscreenRenderer.Session(panel: .vectorscope, size: size, scale: 2, theme: Theme(), settings: settings)
        var quiet = Self.rightOnlyToneFrames(count: 2)
        for i in quiet.indices { quiet[i].spectrum = .silent(binCount: 1024) }
        try emptySession.feed(quiet)
        let dark = try RenderTestSupport.decode(png: emptySession.snapshotPNG())
        let g = r.panGeometryForTesting            // points
        var sum = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0
        let x0 = Int(g.field.minX * 2), x1 = Int(g.field.maxX * 2), y0 = Int(g.field.minY * 2) + 60, y1 = Int(g.field.maxY * 2) - 60
        for y in y0..<y1 {
            for x in x0..<x1 {
                let a = lit.rgb(x, y), b = dark.rgb(x, y)
                let d = Double(max(a.0 - b.0, 0) + max(a.1 - b.1, 0) + max(a.2 - b.2, 0))
                guard d > 24 else { continue }
                sum += d; sx += d * Double(x); sy += d * Double(y); sxx += d * Double(x * x); syy += d * Double(y * y)
            }
        }
        XCTAssertGreaterThan(sum, 0, "the tone draws light")
        let cx = sx / sum / 2, cy = sy / sum / 2
        let spreadX = (sxx / sum - (sx / sum) * (sx / sum)).squareRoot() / 2, spreadY = (syy / sum - (sy / sum) * (sy / sum)).squareRoot() / 2
        let panOfCentroid = (cx - Double(g.centerX)) / Double(g.half)
        print(String(format: "PAN right-only tone: centroid pan %.3f, spread %.1f x %.1f pt (half width %.0f pt)", panOfCentroid, spreadX, spreadY, Double(g.half)))
        XCTAssertGreaterThan(panOfCentroid, 0.9, "centroid at the far right")
        XCTAssertLessThan(spreadX, Double(g.half) * 0.05, "compact across")
        XCTAssertLessThan(spreadY, 8, "compact in height")
    }

    /// The same level in both channels is the center; 6 dB more on the right is pan +0.6.
    func testPanFollowsThePowerRatio() {
        let field = PanField()
        var s = SpectrumReading.silent(binCount: 1024)
        for i in 0..<1024 { s.left[i] = -30; s.right[i] = i < 512 ? -30 : -24 }
        for _ in 0..<60 { field.update(s, dt: 1.0 / 60, sampleRate: 48_000) }
        XCTAssertEqual(field.pan[300], 0, accuracy: 1e-4)
        let expected = (pow(10, -2.4) - pow(10, -3.0)) / (pow(10, -2.4) + pow(10, -3.0))
        XCTAssertEqual(Double(field.pan[800]), expected, accuracy: 1e-3)
        XCTAssertEqual(field.light(800, topDB: -20, bottomDB: -80), (field.levelDB[800] + 70) / 50, accuracy: 1e-3, "the gate is the floor of the light scale")
        s.left = s.left.map { _ in -90 }; s.right = s.left
        for _ in 0..<600 { field.update(s, dt: 1.0 / 60, sampleRate: 48_000) }
        XCTAssertEqual(field.light(300, topDB: -20, bottomDB: -120), 0, "under the -70 dB gate: no light")
    }

    /// Power smoothing: a step from left to right takes about 150 ms to cross the center.
    func testPanSmoothingTimeConstant() {
        let field = PanField()
        var s = SpectrumReading.silent(binCount: 1024)
        for i in 0..<1024 { s.left[i] = -20; s.right[i] = -120 }
        for _ in 0..<60 { field.update(s, dt: 1.0 / 60, sampleRate: 48_000) }
        XCTAssertLessThan(field.pan[900], -0.99)
        for i in 0..<1024 { s.left[i] = -120; s.right[i] = -20 }
        var frames = 0, lowFrames = 0
        while field.pan[200] < 0, frames < 400 {
            field.update(s, dt: 1.0 / 60, sampleRate: 48_000); frames += 1
            if field.pan[900] < 0 { lowFrames = frames }
        }
        // Bin 900 is 9.4 kHz (43 ms window): tau = 150 ms. Bin 200 is 46 Hz (683 ms window): tau = 1.2 windows.
        XCTAssertEqual(Double(lowFrames + 1) / 60, 0.15 * log(2), accuracy: 0.03, "pan crosses 0 after tau * ln 2")
        XCTAssertEqual(Double(frames) / 60, 0.6827 * 1.2 * log(2), accuracy: 0.05, "the lows settle with their analysis window")
    }
}
