import XCTest
import JoseonCore
@testable import JoseonCapture

/// Apple Music, Spotify and Roon: the pure parts of their readers (docs/EXAMPLES.md, 2026-10-25).
final class PlayerSourcesTests: XCTestCase {
    func testMusicPlayingTrackShowsAndPausedTrackDoesNot() {
        let info: [AnyHashable: Any] = ["Name": "Roygbiv", "Artist": "Boards of Canada", "Album": "Music Has the Right to Children",
                                        "Player State": "Playing"]
        XCTAssertEqual(PlayerInfoParser.parse(info, source: "Apple Music"),
                       NowPlaying(title: "Roygbiv", artist: "Boards of Canada", album: "Music Has the Right to Children", source: "Apple Music"))
        var paused = info
        paused["Player State"] = "Paused"
        XCTAssertNil(PlayerInfoParser.parse(paused, source: "Apple Music"))
    }

    func testSpotifyAdShowsNothing() {
        let ad: [AnyHashable: Any] = ["Name": "Advertisement", "Artist": "", "Player State": "Playing", "Track ID": "spotify:ad:000"]
        XCTAssertNil(PlayerInfoParser.parse(ad, source: "Spotify"))
    }

    func testMooMessageRoundTrips() {
        let message = MooMessage(verb: .request, name: "com.roonlabs.transport:2/subscribe_zones", requestID: 3, json: ["subscription_key": 1])
        XCTAssertEqual(MooMessage.decode(message.encoded()), message)
        let ping = Data("MOO/1 REQUEST com.roonlabs.ping:1/ping\nRequest-Id: 7\n\n".utf8)
        XCTAssertEqual(MooMessage.decode(ping), MooMessage(verb: .request, name: "com.roonlabs.ping:1/ping", requestID: 7))
        XCTAssertNil(MooMessage.decode(Data("HTTP/1.1 200 OK\n\n".utf8)))
    }

    private func zone(_ id: String, _ name: String, _ state: String, _ title: String, _ artist: String, _ album: String = "") -> [String: Any] {
        ["zone_id": id, "display_name": name, "state": state,
         "now_playing": ["three_line": ["line1": title, "line2": artist, "line3": album]]]
    }

    func testRoonPlayingZoneShowsThenGoesAwayOnPause() {
        var book = RoonZoneBook()
        book.apply(["zones": [zone("a", "MacBook", "playing", "Says", "Nils Frahm", "Spaces"), zone("b", "Kitchen", "stopped", "X", "Y")]])
        XCTAssertEqual(book.pick(), NowPlaying(title: "Says", artist: "Nils Frahm", album: "Spaces", source: "Roon"))
        book.apply(["zones_changed": [zone("a", "MacBook", "paused", "Says", "Nils Frahm", "Spaces")]])
        XCTAssertNil(book.pick())
    }

    func testRoonKeepsTheShownZoneWhileItPlays() {
        var book = RoonZoneBook()
        book.apply(["zones": [zone("b", "Study", "playing", "Two", "B")]])
        XCTAssertEqual(book.pick()?.title, "Two")
        book.apply(["zones_added": [zone("a", "Attic", "playing", "One", "A")]])
        XCTAssertEqual(book.pick()?.title, "Two")
        book.apply(["zones_removed": ["b"]])
        XCTAssertEqual(book.pick()?.title, "One")
    }

    func testMergedSourceShowsTheLastChangedPlayer() {
        let qobuz = StubSource(), roon = StubSource()
        let merged = MergedNowPlayingSource([qobuz, roon])
        merged.start()
        qobuz.emit(NowPlaying(title: "Q", artist: "Qa", source: "Qobuz"))
        roon.emit(NowPlaying(title: "R", artist: "Ra", source: "Roon"))
        XCTAssertEqual(merged.current?.source, "Roon")
        roon.emit(nil)
        XCTAssertEqual(merged.current?.source, "Qobuz")
        qobuz.emit(nil)
        XCTAssertNil(merged.current)
    }
}

final class StubSource: NowPlayingSource {
    var current: NowPlaying?
    var onChange: ((NowPlaying?) -> Void)?
    func start() {}
    func stop() { emit(nil) }
    func emit(_ value: NowPlaying?) { current = value; onChange?(value) }
}
