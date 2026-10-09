import XCTest
@testable import JoseonCore

final class UpdateFeedTests: XCTestCase {
    private let prefixes = ["https://github.com/jasas1/"]
    private let list = """
    [
      {"tag_name": "v0.3.0", "draft": true, "assets": [
        {"name": "Joseon-v0.3.0-macos.zip", "browser_download_url": "https://github.com/jasas1/Joseon/releases/download/v0.3.0/Joseon-v0.3.0-macos.zip"}]},
      {"tag_name": "v0.1.1", "assets": [
        {"name": "Joseon-v0.1.1-macos.zip", "digest": "sha256:ABCDEF",
         "browser_download_url": "https://github.com/jasas1/Joseon/releases/download/v0.1.1/Joseon-v0.1.1-macos.zip"}]},
      {"tag_name": "v0.2.0", "prerelease": true, "assets": [
        {"name": "notes.txt", "browser_download_url": "https://github.com/jasas1/Joseon/releases/download/v0.2.0/notes.txt"},
        {"name": "Joseon-v0.2.0-macos.zip", "browser_download_url": "https://github.com/jasas1/Joseon/releases/download/v0.2.0/Joseon-v0.2.0-macos.zip"}]},
      {"tag_name": "v0.9.0", "assets": [
        {"name": "Joseon-v0.9.0-macos.zip", "browser_download_url": "https://example.com/Joseon-v0.9.0-macos.zip"}]},
      {"tag_name": "v0.8.0", "assets": [
        {"name": "Joseon-v0.8.0-windows-x64.zip", "browser_download_url": "https://github.com/jasas1/x.zip"}]},
      {"tag_name": "nightly", "assets": []}
    ]
    """

    func testVersionsAreReadAndCompared() {
        XCTAssertEqual(AppVersion("v0.1.2"), AppVersion(0, 1, 2))
        XCTAssertEqual(AppVersion("1.20.3"), AppVersion(1, 20, 3))
        for bad in ["", "v1.2", "v1.2.3.4", "nightly", "v1.x.3", "v-1.2.3", "v1..3"] {
            XCTAssertNil(AppVersion(bad), bad)
        }
        XCTAssertTrue(AppVersion(0, 1, 0) > AppVersion(0, 0, 99))
        XCTAssertTrue(AppVersion(1, 0, 0) > AppVersion(0, 99, 99))
        XCTAssertEqual(AppVersion(0, 1, 2).description, "0.1.2")
    }

    /// v0.3.0 is a draft, v0.9.0 comes from a foreign place, v0.8.0 has no Mac file.
    func testTheNewestReleaseWithAFileForThisSystemIsChosen() throws {
        let release = try XCTUnwrap(UpdateFeed.newestRelease(json: Data(list.utf8), assetSuffix: "-macos.zip", allowedPrefixes: prefixes))
        XCTAssertEqual(release.version, AppVersion(0, 2, 0))
        XCTAssertEqual(release.assetName, "Joseon-v0.2.0-macos.zip")
        XCTAssertNil(release.sha256)
        let older = try XCTUnwrap(UpdateFeed.newestRelease(
            json: Data(list.replacingOccurrences(of: "v0.2.0", with: "v0.1.0").utf8), assetSuffix: "-macos.zip", allowedPrefixes: prefixes))
        XCTAssertEqual(older.version, AppVersion(0, 1, 1))
        XCTAssertEqual(older.sha256, "abcdef")
    }

    func testAnAnswerThatIsNoListIsAnError() {
        XCTAssertNil(try UpdateFeed.newestRelease(json: Data("[]".utf8), assetSuffix: "-macos.zip", allowedPrefixes: prefixes))
        XCTAssertThrowsError(try UpdateFeed.newestRelease(json: Data(#"{"message": "Not Found"}"#.utf8), assetSuffix: "-macos.zip", allowedPrefixes: prefixes)) {
            XCTAssertEqual($0 as? UpdateFeedError, .refused("Not Found"))
        }
        XCTAssertThrowsError(try UpdateFeed.newestRelease(json: Data("<html>".utf8), assetSuffix: "-macos.zip", allowedPrefixes: prefixes)) {
            XCTAssertEqual($0 as? UpdateFeedError, .unreadable)
        }
    }
}
