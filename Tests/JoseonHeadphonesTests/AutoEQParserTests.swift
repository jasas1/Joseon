import XCTest
@testable import JoseonHeadphones

final class AutoEQParserTests: XCTestCase {

    func testAutoEQCSVPicksRawColumn() throws {
        let csv = """
        frequency,raw,smoothed,error,equalization,equalized_raw,target
        20.00,-6.91,-6.92,-10.18,6.00,-0.91,3.27
        20.20,-6.87,-6.86,-10.16,6.00,-0.87,3.30
        100.00,-1.50,-1.49,-2.00,1.00,-0.50,0.50
        200.00,-0.50,-0.49,-1.00,1.00,0.50,0.50
        1000.00,0.00,0.01,0.00,0.00,0.00,0.00
        2000.00,1.20,1.21,-1.00,1.00,2.20,2.20
        8000.00,-3.00,-3.01,2.00,-2.00,-5.00,-1.00
        16000.00,-9.00,-9.01,5.00,-5.00,-14.00,-4.00
        20000.00,-12.00,-12.01,6.00,-6.00,-18.00,-6.00
        """
        let c = try AutoEQParser.parse(csv: csv, name: "X", source: "unit test")
        XCTAssertEqual(c.frequenciesHz.count, 9)
        XCTAssertEqual(c.levelsDB.count, 9)
        XCTAssertEqual(c.levelsDB[0], -6.91, accuracy: 1e-4)   // raw, not smoothed
        XCTAssertEqual(c.levelsDB[5], 1.20, accuracy: 1e-4)
        XCTAssertEqual(c.levelsDB[8], -12.00, accuracy: 1e-4)  // not equalized_raw (-18)
        XCTAssertEqual(c.name, "X")
        XCTAssertEqual(c.source, "unit test")
    }

    func testTwoPlainColumnsNoHeader() throws {
        let csv = (0..<10).map { "\(20 * (1 << $0)),\(Float($0) * 0.5)" }.joined(separator: "\n")
        let c = try AutoEQParser.parse(csv: csv, name: "two", source: "s")
        XCTAssertEqual(c.frequenciesHz.count, 10)
        XCTAssertEqual(c.frequenciesHz.first, 20)
        XCTAssertEqual(c.levelsDB[3], 1.5, accuracy: 1e-5)
    }

    func testTabSeparated() throws {
        let csv = (0..<12).map { "\(20 + $0 * 100)\t\(-Float($0))" }.joined(separator: "\n")
        let c = try AutoEQParser.parse(csv: csv, name: "tab", source: "s")
        XCTAssertEqual(c.frequenciesHz.count, 12)
        XCTAssertEqual(c.levelsDB[11], -11, accuracy: 1e-5)
    }

    func testSpaceSeparatedWithCommentsREWStyle() throws {
        var lines = [
            "* Measurement data measured by REW V5.20",
            "* Source: sound card",
            "# Freq(Hz) SPL(dB) Phase(degrees)",
            "",
        ]
        lines += (0..<9).map { "  \(20 + $0 * 250)   \(Float($0) * -0.25)   0.0" }
        let c = try AutoEQParser.parse(csv: lines.joined(separator: "\r\n"), name: "rew", source: "s")
        XCTAssertEqual(c.frequenciesHz.count, 9)
        XCTAssertEqual(c.frequenciesHz[0], 20, accuracy: 1e-5)
        XCTAssertEqual(c.levelsDB[8], -2.0, accuracy: 1e-5)
    }

    func testHeaderWithoutRawUsesNextColumn() throws {
        var lines = ["Frequency,SPL"]
        lines += (0..<9).map { "\(100 + $0 * 100),\(Float($0))" }
        let c = try AutoEQParser.parse(csv: lines.joined(separator: "\n"), name: "h", source: "s")
        XCTAssertEqual(c.frequenciesHz.count, 9)
        XCTAssertEqual(c.levelsDB[4], 4, accuracy: 1e-5)
    }

    func testBadRowsAreDropped() throws {
        var lines = ["frequency,raw"]
        lines += (0..<10).map { "\(100 + $0 * 100),\(Float($0))" }
        lines += ["not,numbers", "500", "-40,1.0", "0,2.0", "700,NaNish", ",,", "800,"]
        let c = try AutoEQParser.parse(csv: lines.joined(separator: "\n"), name: "bad", source: "s")
        XCTAssertEqual(c.frequenciesHz.count, 10)
        XCTAssertTrue(c.frequenciesHz.allSatisfy { $0 > 0 })
        XCTAssertTrue(c.levelsDB.allSatisfy { $0.isFinite })
    }

    func testTooFewRowsThrowsNoData() {
        let csv = "frequency,raw\n20,0\n100,1\n1000,2\n"
        XCTAssertThrowsError(try AutoEQParser.parse(csv: csv, name: "t", source: "s")) { error in
            guard case CurveParseError.noData = error else {
                return XCTFail("expected noData, got \(error)")
            }
        }
    }

    func testEmptyInputThrowsNoData() {
        XCTAssertThrowsError(try AutoEQParser.parse(csv: "", name: "t", source: "s"))
        XCTAssertThrowsError(try AutoEQParser.parse(csv: "# only a comment\n", name: "t", source: "s"))
    }

    func testOutOfOrderRowsAreSorted() throws {
        let freqs: [Int] = [1000, 20, 500, 8000, 100, 2000, 40, 16000, 300, 60]
        let csv = freqs.map { "\($0),\(Float($0) / 1000)" }.joined(separator: "\n")
        let c = try AutoEQParser.parse(csv: csv, name: "sort", source: "s")
        XCTAssertEqual(c.frequenciesHz, freqs.sorted().map(Float.init))
        XCTAssertEqual(c.levelsDB[0], 0.02, accuracy: 1e-5)
    }

    func testDuplicateFrequenciesAreAveraged() throws {
        var lines = (0..<9).map { "\(100 + $0 * 100),\(Float($0))" }
        lines.append("100,4.0")  // duplicate of the first row (value 0.0)
        let c = try AutoEQParser.parse(csv: lines.joined(separator: "\n"), name: "dup", source: "s")
        XCTAssertEqual(c.frequenciesHz.count, 9)
        XCTAssertEqual(c.levelsDB[0], 2.0, accuracy: 1e-5)
    }
}
