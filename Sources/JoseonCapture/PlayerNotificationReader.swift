import AppKit
import Foundation
import JoseonCore

// Reads the track of Apple Music and Spotify from the distributed notifications they post on every play, pause and
// track change. No Accessibility, no Apple Events, no entitlement: a sandboxed test app receives them with every
// field (docs/EXAMPLES.md, 2026-10-25). The players post only on a change, so a track that already plays when the
// reader starts shows from the next play, pause or track.

/// Pure: the `userInfo` of one player notification as a track. Only a playing track counts.
public enum PlayerInfoParser {
    /// Nil while paused or stopped, for an ad, or when the player names neither title nor artist.
    public static func parse(_ info: [AnyHashable: Any], source: String) -> NowPlaying? {
        func text(_ key: String) -> String { ((info[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        guard text("Player State") == "Playing" else { return nil }
        // Spotify's free tier posts its ads as tracks.
        guard !text("Track ID").hasPrefix("spotify:ad:") else { return nil }
        let title = text("Name"), artist = text("Artist")
        guard !title.isEmpty || !artist.isEmpty else { return nil }
        return NowPlaying(title: title, artist: artist, album: text("Album"), source: source)
    }
}

/// Listens to one player's notifications on the main queue. Clears the track when the player quits.
public final class PlayerNotificationReader: NowPlayingSource {
    public struct Player: Equatable {
        public var bundleIdentifier: String
        public var notificationName: String
        public var source: String

        public init(bundleIdentifier: String, notificationName: String, source: String) {
            self.bundleIdentifier = bundleIdentifier
            self.notificationName = notificationName
            self.source = source
        }

        public static let appleMusic = Player(bundleIdentifier: "com.apple.Music", notificationName: "com.apple.Music.playerInfo",
                                              source: "Apple Music")
        public static let spotify = Player(bundleIdentifier: "com.spotify.client",
                                           notificationName: "com.spotify.client.PlaybackStateChanged", source: "Spotify")
    }

    public let player: Player
    public private(set) var current: NowPlaying?
    public var onChange: ((NowPlaying?) -> Void)?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init(player: Player) { self.player = player }

    deinit { removeObservers() }

    // MARK: NowPlayingSource

    public func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        let token = distributed.addObserver(forName: Notification.Name(player.notificationName), object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.set(PlayerInfoParser.parse(note.userInfo ?? [:], source: self.player.source))
        }
        observers.append((distributed, token))
        let workspace = NSWorkspace.shared.notificationCenter
        let quit = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let self, app?.bundleIdentifier == self.player.bundleIdentifier { self.set(nil) }
        }
        observers.append((workspace, quit))
    }

    public func stop() {
        removeObservers()
        set(nil)
    }

    private func removeObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    private func set(_ value: NowPlaying?) {
        guard value != current else { return }
        current = value
        onChange?(value)
    }
}
