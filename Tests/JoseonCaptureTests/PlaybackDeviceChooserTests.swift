import CoreAudio
import XCTest
@testable import JoseonCapture

/// The pure chooser behind `SystemAudioTap`: which output device clocks the capture aggregate.
/// The measured case (2026-09-22): Qobuz plays to "Woo Audio" (96 kHz) while the default output is
/// "LG UltraFine Display Audio" (48 kHz). The tap must follow Qobuz.
final class PlaybackDeviceChooserTests: XCTestCase {
    let woo = "AppleUSBAudioEngine:Woo Audio:WA33:0001"
    let lg = "AppleUSBAudioEngine:LG UltraFine Display Audio:0002"
    let speakers = "BuiltInSpeakerDevice"

    func qobuz(_ uids: [String]) -> ProcessPlayback { ProcessPlayback(name: "Qobuz", deviceUIDs: uids) }
    func music(_ uids: [String]) -> ProcessPlayback { ProcessPlayback(name: "Music", deviceUIDs: uids) }
    func safari(_ uids: [String]) -> ProcessPlayback { ProcessPlayback(name: "Safari", deviceUIDs: uids) }

    // MARK: Rule (c): nothing plays

    func testNothingPlaysUsesDefault() {
        XCTAssertEqual(PlaybackDeviceChooser.choose(playing: [], current: nil, defaultOutput: lg), lg)
    }

    func testEmptyInputAndNoDefaultIsNil() {
        XCTAssertNil(PlaybackDeviceChooser.choose(playing: [], current: nil, defaultOutput: nil))
        XCTAssertNil(PlaybackDeviceChooser.choose(playing: [], current: nil, defaultOutput: ""))
    }

    func testProcessWithoutDevicesFallsBackToDefault() {
        let playing = [qobuz([]), music([""])]
        XCTAssertEqual(PlaybackDeviceChooser.choose(playing: playing, current: nil, defaultOutput: lg), lg)
    }

    func testStaleCurrentWithNothingPlayingFallsBackToDefault() {
        // The Woo was chosen, Qobuz stopped: back to the default (rule a fails, b empty, c).
        XCTAssertEqual(PlaybackDeviceChooser.choose(playing: [], current: woo, defaultOutput: lg), lg)
    }

    // MARK: Rule (b): the playing process wins over the default

    func testQobuzOnWooBeatsDefaultLG() {
        XCTAssertEqual(PlaybackDeviceChooser.choose(playing: [qobuz([woo])], current: nil, defaultOutput: lg), woo)
    }

    func testMostProcessesOnADeviceWins() {
        let playing = [qobuz([woo]), music([lg]), safari([lg])]
        XCTAssertEqual(PlaybackDeviceChooser.choose(playing: playing, current: nil, defaultOutput: speakers), lg)
    }

    func testTieBreaksByProcessNameThenUID() {
        // One process each: the device of the process that sorts first by name ("Music" < "Qobuz").
        let playing = [qobuz([woo]), music([lg])]
        XCTAssertEqual(PlaybackDeviceChooser.choose(playing: playing, current: nil, defaultOutput: speakers), lg)
        // Same process name on two devices: lowest UID.
        let twoSame = [ProcessPlayback(name: "Music", deviceUIDs: ["zzz"]), ProcessPlayback(name: "Music", deviceUIDs: ["aaa"])]
        XCTAssertEqual(PlaybackDeviceChooser.choose(playing: twoSame, current: nil, defaultOutput: nil), "aaa")
        XCTAssertEqual(PlaybackDeviceChooser.rank(playing), [lg, woo])
    }

    func testOrderOfInputDoesNotMatter() {
        let a = [qobuz([woo]), music([lg]), safari([lg])]
        let b = [safari([lg]), qobuz([woo]), music([lg])]
        XCTAssertEqual(PlaybackDeviceChooser.choose(playing: a, current: nil, defaultOutput: nil),
                       PlaybackDeviceChooser.choose(playing: b, current: nil, defaultOutput: nil))
    }

    func testProcessWithTwoDevicesCountsOnceEach() {
        // Qobuz plays to both; Music to the LG only: LG has 2, Woo has 1.
        let playing = [qobuz([woo, lg]), music([lg])]
        XCTAssertEqual(PlaybackDeviceChooser.choose(playing: playing, current: nil, defaultOutput: speakers), lg)
        // Alone with two devices: a tie of one each, broken by UID ("AppleUSBAudioEngine:LG..." < "...Woo...").
        XCTAssertEqual(PlaybackDeviceChooser.choose(playing: [qobuz([woo, lg])], current: nil, defaultOutput: speakers), lg)
        // A repeated UID inside one process is still one process.
        XCTAssertEqual(PlaybackDeviceChooser.rank([qobuz([woo, woo]), music([lg]), safari([lg])]), [lg, woo])
    }

    // MARK: Rule (a): no flapping

    func testCurrentChoiceIsKeptWhileItsProcessPlays() {
        // Music joins on the LG (the default) while Qobuz still plays to the Woo: stay on the Woo.
        let playing = [qobuz([woo]), music([lg]), safari([lg])]
        XCTAssertEqual(PlaybackDeviceChooser.choose(playing: playing, current: woo, defaultOutput: lg), woo)
    }

    func testCurrentChoiceIsKeptEvenWhenItIsTheDefault() {
        let playing = [qobuz([woo]), music([lg])]
        XCTAssertEqual(PlaybackDeviceChooser.choose(playing: playing, current: lg, defaultOutput: lg), lg)
    }

    func testSwitchesOnlyAfterTheProcessStops() {
        var playing = [qobuz([woo]), music([lg])]
        var choice = PlaybackDeviceChooser.choose(playing: playing, current: nil, defaultOutput: lg)
        XCTAssertEqual(choice, lg, "Music sorts before Qobuz: the LG on a tie")
        // Now set the Woo as the current choice (as if it had been chosen first) and let Music play on: keep.
        choice = PlaybackDeviceChooser.choose(playing: playing, current: woo, defaultOutput: lg)
        XCTAssertEqual(choice, woo)
        // Qobuz stops: the Woo has no process, switch to the LG (Music) even though the default is the speakers.
        playing = [music([lg])]
        choice = PlaybackDeviceChooser.choose(playing: playing, current: choice, defaultOutput: speakers)
        XCTAssertEqual(choice, lg)
        // Everything stops: default.
        choice = PlaybackDeviceChooser.choose(playing: [], current: choice, defaultOutput: speakers)
        XCTAssertEqual(choice, speakers)
    }

    func testVanishedCurrentDeviceIsNotKept() {
        // The Woo was unplugged: no process lists it any more, so rule (a) does not hold it.
        let playing = [qobuz([lg])]
        XCTAssertEqual(PlaybackDeviceChooser.choose(playing: playing, current: woo, defaultOutput: speakers), lg)
    }

    func testEmptyCurrentIsTreatedAsNone() {
        XCTAssertEqual(PlaybackDeviceChooser.choose(playing: [qobuz([woo])], current: "", defaultOutput: lg), woo)
    }

    // MARK: The HAL scope trap

    func testProcessDevicesAreReadInOutputScope() {
        // Global scope answers an empty list for a playing process. The wrapper must ask in output scope.
        let address = HAL.processOutputDevicesAddress
        XCTAssertEqual(address.mSelector, kAudioProcessPropertyDevices)
        XCTAssertEqual(address.mScope, kAudioObjectPropertyScopeOutput)
        XCTAssertEqual(address.mElement, kAudioObjectPropertyElementMain)
    }

    // MARK: Joseon itself is never a player

    func testOwnProcessesAreExcluded() {
        // This pid, the app by bundle id, the probe by bundle id: all Joseon, none plays.
        XCTAssertTrue(AudioSystem.isOwnProcess(pid: 7, bundleID: "", me: 7, ownBundleID: nil))
        XCTAssertTrue(AudioSystem.isOwnProcess(pid: 24432, bundleID: "app.joseon.Joseon", me: 7, ownBundleID: nil))
        XCTAssertTrue(AudioSystem.isOwnProcess(pid: 8, bundleID: "app.joseon.probe", me: 7, ownBundleID: nil))
        XCTAssertTrue(AudioSystem.isOwnProcess(pid: 8, bundleID: "com.example.Host", me: 7, ownBundleID: "com.example.Host"))
        XCTAssertFalse(AudioSystem.isOwnProcess(pid: 11462, bundleID: "com.qobuz.desktop", me: 7, ownBundleID: "app.joseon.Joseon"))
        XCTAssertFalse(AudioSystem.isOwnProcess(pid: 9, bundleID: "", me: 7, ownBundleID: ""))
    }

    func testProcessPlaybackConvenienceInit() {
        let p = ProcessPlayback(name: "Qobuz", deviceUIDs: [woo, lg])
        XCTAssertEqual(p.deviceUIDs, [woo, lg])
        XCTAssertEqual(p.pid, 0)
        XCTAssertEqual(p.devices.map(\.name), ["", ""])
    }
}
