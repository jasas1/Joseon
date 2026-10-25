import Foundation

/// Several `NowPlayingSource`s as one. The track that started or changed last wins; when it goes away, the newest of
/// the others shows. Main queue only, like the sources' `onChange`.
public final class MergedNowPlayingSource: NowPlayingSource {
    public let sources: [NowPlayingSource]
    public private(set) var current: NowPlaying?
    public var onChange: ((NowPlaying?) -> Void)?

    private var values: [NowPlaying?]
    /// When each value last changed to a track, as a running count. Higher wins.
    private var stamps: [Int]
    private var clock = 0

    public init(_ sources: [NowPlayingSource]) {
        self.sources = sources
        values = Array(repeating: nil, count: sources.count)
        stamps = Array(repeating: 0, count: sources.count)
        for (index, source) in sources.enumerated() {
            source.onChange = { [weak self] value in self?.update(index, value) }
        }
    }

    public func start() {
        for (index, source) in sources.enumerated() {
            source.start()
            update(index, source.current)
        }
    }

    public func stop() {
        for (index, source) in sources.enumerated() {
            source.stop()
            update(index, nil)
        }
    }

    private func update(_ index: Int, _ value: NowPlaying?) {
        guard values[index] != value else { return }
        values[index] = value
        if value != nil {
            clock += 1
            stamps[index] = clock
        }
        let newest = values.indices.filter { values[$0] != nil }.max { stamps[$0] < stamps[$1] }
        let shown = newest.flatMap { values[$0] }
        guard shown != current else { return }
        current = shown
        onChange?(shown)
    }
}
