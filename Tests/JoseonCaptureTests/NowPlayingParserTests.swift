import XCTest
import JoseonCore
@testable import JoseonCapture

/// A fake accessibility node that mirrors what `AXElementNode` reads from Qobuz.
struct FakeNode: AXNodeLike {
    var role = "AXGroup"
    var domIdentifier = ""
    var domClasses: [String] = []
    var description = ""
    var value = ""
    var children: [FakeNode] = []
}

func group(id: String = "", classes: [String] = [], _ children: [FakeNode] = []) -> FakeNode {
    FakeNode(domIdentifier: id, domClasses: classes, children: children)
}
func link(_ classes: [String] = [], _ text: String) -> FakeNode {
    FakeNode(role: "AXLink", domClasses: classes, description: text, children: [staticText(text)])
}
func staticText(_ text: String) -> FakeNode { FakeNode(role: "AXStaticText", value: text) }

/// The proven Qobuz 8.2.0 player bar. `album: nil` leaves the album link out.
func playerBar(title: String = "Guess Who I Saw Today", artist: String = "Samara Joy", album: String? = "Linger Awhile",
               hiRes: Bool = true) -> FakeNode {
    var albumLinks = [link(["player__track-artist"], artist)]
    if let album { albumLinks.append(link(["player__track-album-name"], album)) }
    return group(id: "bottomPlayerContainer", classes: hiRes ? ["player", "hires"] : ["player"], [
        group(classes: ["player__controls"], [FakeNode(role: "AXButton", description: "Play")]),
        group(classes: ["player__track-infos"], [
            FakeNode(role: "AXImage", description: "cover"),
            group(classes: ["player__track-name-wrapper"], [link(["player__track-name"], title)]),
            group(classes: ["player__track-album"], albumLinks),
        ]),
        group(classes: ["player__progress"], [staticText("2:31"), staticText("4:10")]),
    ])
}

/// Window → web area → page shell → (page content, player bar). Depth is deliberately not what the parser assumes.
func window(page: [FakeNode] = [], bar: FakeNode?) -> FakeNode {
    var shell = [group(id: "root", classes: ["app"], [group(classes: ["page"], page)])]
    if let bar { shell.append(bar) }
    return FakeNode(role: "AXWindow", children: [FakeNode(role: "AXWebArea", children: [group(id: "app-shell", shell)])])
}

/// A page with `count` links, all with the text a decoy would carry, nested `depth` levels deep.
func decoyPage(links count: Int, depth: Int = 6, text: String = "Samara Joy") -> FakeNode {
    var node = group(classes: ["artist-page__tracks"], (0..<count).map { link(["track-row__artist"], "\(text) \($0 % 7 == 0 ? "" : " ")") })
    for _ in 0..<depth { node = group(classes: ["wrapper"], [node]) }
    return node
}

final class NowPlayingParserTests: XCTestCase {
    func testFullParse() {
        let got = NowPlayingParser.parse(root: window(bar: playerBar()))
        XCTAssertEqual(got, NowPlaying(title: "Guess Who I Saw Today", artist: "Samara Joy", album: "Linger Awhile", source: "Qobuz", isHiRes: true))
    }

    func testSourceIsPassedThrough() {
        XCTAssertEqual(NowPlayingParser.parse(root: window(bar: playerBar()), source: "Player")?.source, "Player")
    }

    func testNoAlbumGivesEmptyAlbum() {
        let got = NowPlayingParser.parse(root: window(bar: playerBar(album: nil)))
        XCTAssertEqual(got?.album, "")
        XCTAssertEqual(got?.artist, "Samara Joy")
        XCTAssertEqual(got?.title, "Guess Who I Saw Today")
    }

    func testMissingContainerGivesNil() {
        XCTAssertNil(NowPlayingParser.parse(root: window(page: [decoyPage(links: 40)], bar: nil)))
    }

    func testMissingTitleGivesNil() {
        // The player bar exists (the app is up) but shows no track: the title link is gone.
        let bar = group(id: "bottomPlayerContainer", classes: ["player"], [
            group(classes: ["player__track-infos"], [group(classes: ["player__track-album"], [link([], "Samara Joy")])]),
        ])
        XCTAssertNil(NowPlayingParser.parse(root: window(bar: bar)))
        XCTAssertNil(NowPlayingParser.parse(root: window(bar: playerBar(title: "   \n"))), "a blank title counts as missing")
    }

    func testMissingArtistGivesNil() {
        XCTAssertNil(NowPlayingParser.parse(root: window(bar: playerBar(artist: ""))))
        let noAlbumGroup = group(id: "bottomPlayerContainer", classes: ["player"], [link(["player__track-name"], "Title")])
        XCTAssertNil(NowPlayingParser.parse(root: window(bar: noAlbumGroup)))
    }

    func testHiResAbsentGivesFalse() {
        XCTAssertEqual(NowPlayingParser.parse(root: window(bar: playerBar(hiRes: false)))?.isHiRes, false)
        XCTAssertEqual(NowPlayingParser.parse(root: window(bar: playerBar(hiRes: true)))?.isHiRes, true)
    }

    func testWhitespaceIsTrimmed() {
        let got = NowPlayingParser.parse(root: window(bar: playerBar(title: "  Title \n", artist: "\tArtist  ", album: " Album ")))
        XCTAssertEqual(got?.title, "Title")
        XCTAssertEqual(got?.artist, "Artist")
        XCTAssertEqual(got?.album, "Album")
    }

    func testTitleFallsBackToStaticTextWhenDescriptionIsEmpty() {
        var bar = playerBar()
        // Drop the link description: only the child static text carries the title.
        bar.children[1].children[1].children[0].description = ""
        XCTAssertEqual(NowPlayingParser.parse(root: window(bar: bar))?.title, "Guess Who I Saw Today")
    }

    func testPlainTextArtistWithoutLinks() {
        let bar = group(id: "bottomPlayerContainer", classes: ["player"], [
            link(["player__track-name"], "Title"),
            group(classes: ["player__track-album"], [staticText("Various Artists"), staticText("Compilation")]),
        ])
        let got = NowPlayingParser.parse(root: window(bar: bar))
        XCTAssertEqual(got?.artist, "Various Artists")
        XCTAssertEqual(got?.album, "Compilation")
    }

    func testDeepDecoyPageDoesNotConfuseTheParser() {
        // An artist page with many "Samara Joy" links, plus decoy nodes that reuse the player classes outside the bar.
        let decoys = group(classes: ["search-result"], [
            link(["player__track-name"], "Wrong Title"),
            group(classes: ["player__track-album"], [link([], "Wrong Artist"), link([], "Wrong Album")]),
        ])
        let root = window(page: [decoyPage(links: 300), decoys], bar: playerBar(title: "Right Title", artist: "Right Artist", album: "Right Album"))
        let got = NowPlayingParser.parse(root: root)
        XCTAssertEqual(got, NowPlaying(title: "Right Title", artist: "Right Artist", album: "Right Album", source: "Qobuz", isHiRes: true))
    }

    func testPlayerBarAfterALongPageIsStillFound() {
        // The bar is the last sibling after a page with more nodes than the cap: the level-order search reaches it
        // before the page content is walked.
        let root = window(page: [decoyPage(links: 6000, depth: 2)], bar: playerBar())
        let (got, visited) = NowPlayingParser.parseCounting(root: root, source: "Qobuz", nodeCap: 5000)
        XCTAssertNotNil(got)
        XCTAssertLessThanOrEqual(visited, 5000)
        XCTAssertLessThan(visited, 100, "the bar is shallow: the walk must not touch the track list")
    }

    func testNodeCapIsRespectedWithoutAContainer() {
        // 6000 sibling groups, no player bar: the walk stops at the cap and returns nil.
        let root = FakeNode(role: "AXWindow", children: (0..<6000).map { _ in group(classes: ["row"], [staticText("x")]) })
        let (got, visited) = NowPlayingParser.parseCounting(root: root, source: "Qobuz", nodeCap: 5000)
        XCTAssertNil(got)
        XCTAssertEqual(visited, 5000)
    }

    func testNodeCapBoundsADeepChain() {
        var node = playerBar()
        for _ in 0..<7000 { node = group([node]) }
        let (got, visited) = NowPlayingParser.parseCounting(root: node, source: "Qobuz", nodeCap: 5000)
        XCTAssertNil(got)
        XCTAssertEqual(visited, 5000)
    }

    func testTinyCapReturnsNilNotACrash() {
        XCTAssertNil(NowPlayingParser.parse(root: window(bar: playerBar()), nodeCap: 0))
        XCTAssertNil(NowPlayingParser.parse(root: window(bar: playerBar()), nodeCap: 3))
    }
}

final class NowPlayingLineTests: XCTestCase {
    func testArtistAndTitle() {
        XCTAssertEqual(NowPlaying(title: "Title", artist: "Artist", source: "Qobuz").line, "Artist \u{2013} Title")
    }

    func testOneSideEmpty() {
        XCTAssertEqual(NowPlaying(title: "Title", artist: "", source: "Qobuz").line, "Title")
        XCTAssertEqual(NowPlaying(title: "", artist: "Artist", source: "Qobuz").line, "Artist")
        XCTAssertEqual(NowPlaying(title: "", artist: "", source: "Qobuz").line, "")
    }
}
