import Foundation
import JoseonCore

/// The Accessibility permission as two seams, so the app builds and runs without the real reader.
/// The real reader (JoseonCapture) answers `isTrusted` from `AXIsProcessTrusted` and asks macOS in `requestTrust`.
struct NowPlayingTrust {
    var isTrusted: () -> Bool
    var requestTrust: () -> Void

    /// The fake reader needs no permission.
    static let fake = NowPlayingTrust(isTrusted: { true }, requestTrust: {})
}

/// A `NowPlayingSource` for runs without the real reader. Silent (nil) unless `JOSEON_NOWPLAYING_FAKE=1` is set; then
/// it cycles through a few sample tracks every 20 s so the marquee can be seen. Reads nothing, opens nothing.
final class FakeNowPlayingSource: NowPlayingSource {
    static let isEnabled = ProcessInfo.processInfo.environment["JOSEON_NOWPLAYING_FAKE"] == "1"
    static let cycleSeconds: TimeInterval = 20

    static let samples: [NowPlaying] = [
        NowPlaying(title: "Says", artist: "Nils Frahm", album: "Spaces", source: "Qobuz", isHiRes: false),
        NowPlaying(title: "Piano Concerto No. 2 in C Minor, Op. 18: II. Adagio sostenuto", artist: "Sergei Rachmaninoff, Yuja Wang",
                   album: "Rachmaninoff", source: "Qobuz", isHiRes: true),
        NowPlaying(title: "Roygbiv", artist: "", album: "Music Has the Right to Children", source: "Qobuz", isHiRes: false),
    ]

    private(set) var current: NowPlaying?
    var onChange: ((NowPlaying?) -> Void)?
    private var timer: Timer?
    private var index = 0

    func start() {
        guard Self.isEnabled, timer == nil else { return }
        advance()
        let t = Timer(timeInterval: Self.cycleSeconds, repeats: true) { [weak self] _ in self?.advance() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        set(nil)
    }

    private func advance() {
        set(Self.samples[index % Self.samples.count])
        index += 1
    }

    private func set(_ value: NowPlaying?) {
        guard value != current else { return }
        current = value
        onChange?(value)
    }
}
