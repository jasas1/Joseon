import XCTest
@testable import JoseonHeadphones

final class EmbeddedCurvesTests: XCTestCase {

    private var everything: [HeadphoneCurve] { EmbeddedCurves.headphones + EmbeddedCurves.targets }

    func testCurvesAndTargetsArePresent() {
        XCTAssertGreaterThanOrEqual(EmbeddedCurves.headphones.count, 10)
        XCTAssertGreaterThanOrEqual(EmbeddedCurves.targets.count, 3)
        let names = Set(EmbeddedCurves.headphones.map(\.name))
        for wanted in [
            "HiFiMAN Susvara Unveiled", "Sennheiser HD 600", "Sennheiser HD 650",
            "Sennheiser HD 800 S", "Focal Utopia", "Meze Empyrean (leather earpads)",
            "Apple AirPods Max", "Apple AirPods Pro 2", "Sony WH-1000XM5",
        ] {
            XCTAssertTrue(names.contains(wanted), "missing embedded curve \(wanted)")
        }
        XCTAssertTrue(EmbeddedCurves.targets.contains { $0.name == "Harman over-ear 2018" })
        XCTAssertTrue(EmbeddedCurves.targets.contains { $0.name == "Harman in-ear 2019" })
    }

    func testEveryCurveIsWellFormed() {
        for c in everything {
            XCTAssertGreaterThanOrEqual(c.frequenciesHz.count, 50, "\(c.name): too few points")
            XCTAssertEqual(c.frequenciesHz.count, c.levelsDB.count, "\(c.name): ragged arrays")
            XCTAssertFalse(c.source.isEmpty, "\(c.name): no source")

            for i in 1..<c.frequenciesHz.count {
                XCTAssertGreaterThan(c.frequenciesHz[i], c.frequenciesHz[i - 1],
                                     "\(c.name): frequencies not strictly ascending at \(i)")
            }
            XCTAssertLessThanOrEqual(c.frequenciesHz.first!, 20, "\(c.name): starts above 20 Hz")
            XCTAssertGreaterThanOrEqual(c.frequenciesHz.last!, 20_000, "\(c.name): stops below 20 kHz")
            XCTAssertTrue(c.frequenciesHz.allSatisfy { $0.isFinite && $0 > 0 }, "\(c.name): bad frequency")
            XCTAssertTrue(c.levelsDB.allSatisfy { $0.isFinite }, "\(c.name): non-finite level")
            // Real measurements live inside a sane dB window.
            XCTAssertTrue(c.levelsDB.allSatisfy { $0 > -80 && $0 < 80 }, "\(c.name): level out of range")
        }
    }

    func testCurveNamesAreUnique() {
        let names = everything.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate curve names")
    }

    func testHeadphoneCurvesAreNotAllIdentical() {
        // Guards against a generation bug that writes the same block many times.
        let signatures = Set(EmbeddedCurves.headphones.map { c in
            c.levelsDB.prefix(20).map { String(format: "%.2f", $0) }.joined(separator: ",")
        })
        XCTAssertEqual(signatures.count, EmbeddedCurves.headphones.count)
    }

    func testFlatTargetIsFlat() {
        guard let flat = EmbeddedCurves.targets.first(where: { $0.name == "Flat (zero)" }) else {
            return XCTFail("no flat target")
        }
        XCTAssertTrue(flat.levelsDB.allSatisfy { $0 == 0 })
    }

    func testAllCurvesShareTheStandardGrid() {
        for c in everything {
            XCTAssertEqual(c.frequenciesHz, EmbeddedCurves.standardFrequenciesHz, "\(c.name): off-grid")
        }
        XCTAssertEqual(EmbeddedCurves.standardFrequenciesHz.count, 200)
    }
}
