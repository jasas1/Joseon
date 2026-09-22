import XCTest
@testable import JoseonCore

/// `SpectrumReading.midLayers`: the three mid curves before the blend, for the spectrogram.
final class SpectrumLayersTests: XCTestCase {

    private func demoReading(seconds: Double, rate: Double = 48_000, tilt: Float = 0) -> SpectrumReading {
        var settings = SpectrumSettings()
        settings.tiltDBPerOctave = tilt
        let analyzer = SpectrumAnalyzer(settings: settings)
        let block = Int(rate / 60)
        var reading = analyzer.read().spectrum
        for k in 0..<Int(seconds * 60) {
            let s = TestSignals.demoBlock(startSample: k * block, count: block, sampleRate: rate)
            analyzer.process(left: s.left, right: s.right, count: block, sampleRate: rate)
            reading = analyzer.read().spectrum
        }
        return reading
    }

    func testThreeLayersWithWeightsThatSumToOneAndHalfWindowLatency() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let reading = demoReading(seconds: 1.5, rate: rate)
            XCTAssertEqual(reading.midLayers.count, 3)
            let n = reading.frequencies.count
            for layer in reading.midLayers {
                XCTAssertEqual(layer.levelsDB.count, n)
                XCTAssertEqual(layer.weights.count, n)
            }
            for i in 0..<n {
                let sum = reading.midLayers.reduce(Float(0)) { $0 + $1.weights[i] }
                XCTAssertEqual(sum, 1, accuracy: 1e-5, "weights at \(reading.frequencies[i]) Hz")
            }
            // Window lengths scale with the rate: 32768 / 8192 / 2048 at 48 kHz, doubled at 96 kHz.
            let scale = rate == 96_000 ? 2.0 : 1.0
            let expected = [32_768.0, 8_192.0, 2_048.0].map { Float($0 * scale / 2 / rate) }
            for (layer, latency) in zip(reading.midLayers, expected) {
                XCTAssertEqual(layer.latencySeconds, latency, accuracy: 1e-6)
            }
            XCTAssertGreaterThan(reading.midLayers[0].latencySeconds, reading.midLayers[1].latencySeconds)
            XCTAssertGreaterThan(reading.midLayers[1].latencySeconds, reading.midLayers[2].latencySeconds)
        }
    }

    /// The contract: blending the layers in the power domain with their weights gives `mid`.
    /// Checked on every display bin, tonal peaks included, with and without a display tilt.
    func testBlendingTheLayersReproducesMid() {
        for tilt in [Float(0), 4.5] {
            let reading = demoReading(seconds: 4, tilt: tilt)
            var worst: Float = 0, worstHz: Float = 0
            for (i, f) in reading.frequencies.enumerated() {
                var power: Float = 0
                for layer in reading.midLayers where layer.weights[i] > 0 {
                    power += layer.weights[i] * pow(10, layer.levelsDB[i] / 10)
                }
                let blended = max(10 * log10(max(power, 1e-30)), SpectrumReading.floorDB)
                let e = abs(blended - reading.mid[i])
                if e > worst { worst = e; worstHz = f }
            }
            XCTAssertLessThanOrEqual(worst, 0.5, "tilt \(tilt): blend and mid differ by \(worst) dB at \(worstHz) Hz")
        }
    }

    /// Each layer is the mid curve where it has all the weight, and a layer says nothing where
    /// it has none.
    func testALayerIsMidWhereItStandsAlone() {
        let reading = demoReading(seconds: 3)
        for layer in reading.midLayers {
            for (i, w) in layer.weights.enumerated() where w == 1 {
                XCTAssertEqual(layer.levelsDB[i], reading.mid[i], accuracy: 0.001, "\(reading.frequencies[i]) Hz")
            }
        }
    }

    /// Silence: layers at the floor, not NaN, not -300.
    func testSilentLayersSitOnTheFloor() {
        let analyzer = SpectrumAnalyzer()
        let zeros = [Float](repeating: 0, count: 48_000)
        analyzer.process(left: zeros, right: zeros, count: zeros.count, sampleRate: 48_000)
        let reading = analyzer.read().spectrum
        for layer in reading.midLayers {
            XCTAssertTrue(layer.levelsDB.allSatisfy { $0 == SpectrumReading.floorDB })
        }
        XCTAssertTrue(reading.mid.allSatisfy { $0 == SpectrumReading.floorDB })
    }
}
