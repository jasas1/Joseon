import XCTest
@testable import JoseonHeadphones

final class HeadphoneLibraryTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JoseonHeadphoneLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root = tempRoot { try? FileManager.default.removeItem(at: root) }
    }

    private func writeCSV(_ name: String, _ text: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private var sampleCSV: String {
        var lines = ["frequency,raw"]
        lines += (0..<40).map { i -> String in
            let hz = 20 * pow(1_000.0, Double(i) / 39)
            return String(format: "%.2f,%.2f", hz, sin(Double(i) / 5) * 3)
        }
        return lines.joined(separator: "\n")
    }

    func testEmbeddedCurvesAreAlwaysAvailable() {
        let library = HeadphoneLibrary(userCurvesDirectory: tempRoot.appendingPathComponent("Curves"))
        XCTAssertEqual(library.allCurves().count, EmbeddedCurves.headphones.count)
        XCTAssertEqual(library.allTargets().count, EmbeddedCurves.targets.count)
        XCTAssertNotNil(library.curve(named: "Sennheiser HD 650"))
        XCTAssertNotNil(library.target(named: "Harman over-ear 2018"))
        XCTAssertNil(library.curve(named: "No Such Headphone"))
    }

    func testImportRoundTrip() throws {
        let curvesDir = tempRoot.appendingPathComponent("Curves", isDirectory: true)
        let library = HeadphoneLibrary(userCurvesDirectory: curvesDir)
        let source = try writeCSV("My Cans.csv", sampleCSV)

        let imported = try library.importCurve(from: source)
        XCTAssertEqual(imported.name, "My Cans")
        XCTAssertEqual(imported.source, "User import")
        XCTAssertEqual(imported.frequenciesHz.count, 40)

        let copied = curvesDir.appendingPathComponent("My Cans.csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))

        // A fresh library reads it back from disk.
        let reread = HeadphoneLibrary(userCurvesDirectory: curvesDir)
        let user = reread.userCurves()
        XCTAssertEqual(user.count, 1)
        XCTAssertEqual(user[0].name, "My Cans")
        XCTAssertEqual(user[0].levelsDB, imported.levelsDB)
        XCTAssertEqual(reread.allCurves().count, EmbeddedCurves.headphones.count + 1)
        XCTAssertNotNil(reread.curve(named: "My Cans"))
    }

    func testImportTwiceReplacesTheFile() throws {
        let curvesDir = tempRoot.appendingPathComponent("Curves", isDirectory: true)
        let library = HeadphoneLibrary(userCurvesDirectory: curvesDir)
        let source = try writeCSV("Dup.csv", sampleCSV)
        _ = try library.importCurve(from: source)
        _ = try library.importCurve(from: source)
        XCTAssertEqual(library.userCurves().count, 1)
    }

    func testImportRejectsABadFileAndLeavesNothingBehind() throws {
        let curvesDir = tempRoot.appendingPathComponent("Curves", isDirectory: true)
        let library = HeadphoneLibrary(userCurvesDirectory: curvesDir)
        let bad = try writeCSV("Bad.csv", "hello\nthere\n")
        XCTAssertThrowsError(try library.importCurve(from: bad))
        XCTAssertFalse(FileManager.default.fileExists(atPath: curvesDir.appendingPathComponent("Bad.csv").path))
    }

    func testMissingDirectoryYieldsNoUserCurves() {
        let library = HeadphoneLibrary(userCurvesDirectory: tempRoot.appendingPathComponent("does-not-exist"))
        XCTAssertEqual(library.userCurves(), [])
    }

    func testTxtFilesAreReadAndOtherExtensionsIgnored() throws {
        let curvesDir = tempRoot.appendingPathComponent("Curves", isDirectory: true)
        try FileManager.default.createDirectory(at: curvesDir, withIntermediateDirectories: true)
        try sampleCSV.write(to: curvesDir.appendingPathComponent("REW Export.txt"),
                            atomically: true, encoding: .utf8)
        try "junk".write(to: curvesDir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        let library = HeadphoneLibrary(userCurvesDirectory: curvesDir)
        XCTAssertEqual(library.userCurves().map(\.name), ["REW Export"])
    }

    func testDefaultDirectoryIsUnderApplicationSupport() {
        let path = HeadphoneLibrary.defaultUserCurvesDirectory.path
        XCTAssertTrue(path.hasSuffix("/Joseon/Curves"), path)
        XCTAssertTrue(path.contains("Application Support"), path)
        XCTAssertEqual(HeadphoneLibrary().userCurvesDirectory, HeadphoneLibrary.defaultUserCurvesDirectory)
    }
}
