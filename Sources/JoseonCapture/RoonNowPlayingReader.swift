import Foundation
import JoseonCore

// Reads the track Roon plays through the Roon extension API: a WebSocket to the Roon Core that carries MOO messages
// (a request/response frame with JSON bodies). Roon draws its own UI and posts no notifications, so this is its one
// documented source. The Core lists "Joseon" under Roon › Settings › Extensions; nothing arrives until the user
// enables it there once. The token the Core then sends is kept, so later connections need no second Enable.
//
// Only a Core on this Mac (`127.0.0.1`): a Core elsewhere needs discovery on the network and the Local Network prompt.
// Under the App Sandbox the socket needs `com.apple.security.network.client`. Reads only: never controls playback.

/// One MOO message: "MOO/1 VERB name", header lines, a blank line, then the body.
public struct MooMessage: Equatable {
    public enum Verb: String { case request = "REQUEST", complete = "COMPLETE", `continue` = "CONTINUE" }

    public var verb: Verb
    /// "service/method" for a request; "Success", "Registered", "Subscribed", "Changed" or an error for a reply.
    public var name: String
    public var requestID: Int
    /// JSON, or empty.
    public var body: Data

    public init(verb: Verb, name: String, requestID: Int, body: Data = Data()) {
        self.verb = verb
        self.name = name
        self.requestID = requestID
        self.body = body
    }

    public init(verb: Verb, name: String, requestID: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
        self.init(verb: verb, name: name, requestID: requestID, body: body)
    }

    public var json: [String: Any]? { body.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }

    public func encoded() -> Data {
        var head = "MOO/1 \(verb.rawValue) \(name)\nRequest-Id: \(requestID)\n"
        if !body.isEmpty { head += "Content-Length: \(body.count)\nContent-Type: application/json\n" }
        head += "\n"
        return Data(head.utf8) + body
    }

    /// Nil for anything that is not a well-formed MOO/1 message with a request id.
    public static func decode(_ data: Data) -> MooMessage? {
        let separator = Data("\n\n".utf8)
        guard let split = data.range(of: separator),
              let head = String(data: data[data.startIndex..<split.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\n")
        let first = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard first.count == 3, first[0] == "MOO/1", let verb = Verb(rawValue: first[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let id = headers["Request-Id"].flatMap(Int.init) else { return nil }
        var body = Data(data[split.upperBound...])
        if let length = headers["Content-Length"].flatMap(Int.init), length < body.count { body = body.prefix(length) }
        return MooMessage(verb: verb, name: first[2], requestID: id, body: body)
    }
}

/// One Roon zone, as far as the track line needs it.
public struct RoonZone: Equatable {
    public var id: String
    public var name: String
    /// "playing", "paused", "loading" or "stopped".
    public var state: String
    public var nowPlaying: NowPlaying?

    public init(id: String, name: String, state: String, nowPlaying: NowPlaying?) {
        self.id = id
        self.name = name
        self.state = state
        self.nowPlaying = nowPlaying
    }

    public var isPlaying: Bool { state == "playing" && nowPlaying != nil }

    /// A zone object of `com.roonlabs.transport:2`. Its `now_playing.three_line` is title, artist, album.
    public static func parse(_ object: Any) -> RoonZone? {
        guard let zone = object as? [String: Any], let id = zone["zone_id"] as? String else { return nil }
        func line(_ group: String, _ key: String) -> String {
            let lines = (zone["now_playing"] as? [String: Any])?[group] as? [String: Any]
            return ((lines?[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let title = line("three_line", "line1").isEmpty ? line("one_line", "line1") : line("three_line", "line1")
        let artist = line("three_line", "line2")
        let track = title.isEmpty && artist.isEmpty ? nil
            : NowPlaying(title: title, artist: artist, album: line("three_line", "line3"), source: "Roon")
        return RoonZone(id: id, name: (zone["display_name"] as? String) ?? "", state: (zone["state"] as? String) ?? "",
                        nowPlaying: track)
    }
}

/// The zone list one subscription keeps, and the zone whose track shows.
public struct RoonZoneBook: Equatable {
    public private(set) var zones: [String: RoonZone] = [:]
    /// The zone shown last. It keeps the line while it plays, so two playing zones do not swap places.
    public private(set) var shownID: String?

    public init() {}

    /// Applies the body of a "Subscribed" (`zones`) or "Changed" (`zones_added`, `zones_changed`, `zones_removed`) reply.
    public mutating func apply(_ body: [String: Any]) {
        if let all = body["zones"] as? [Any] {
            zones = [:]
            for zone in all.compactMap(RoonZone.parse) { zones[zone.id] = zone }
        }
        for key in ["zones_added", "zones_changed"] {
            for zone in (body[key] as? [Any] ?? []).compactMap(RoonZone.parse) { zones[zone.id] = zone }
        }
        for id in body["zones_removed"] as? [String] ?? [] { zones[id] = nil }
    }

    /// The playing track: the zone shown before while it still plays, else the first playing zone by name.
    public mutating func pick() -> NowPlaying? {
        if let id = shownID, let zone = zones[id], zone.isPlaying { return zone.nowPlaying }
        let next = zones.values.filter(\.isPlaying).min { ($0.name, $0.id) < ($1.name, $1.id) }
        shownID = next?.id
        return next?.nowPlaying
    }
}

/// Connects to the Roon Core on this Mac, registers as an extension, and follows the zones. Retries every
/// `retryInterval` while the Core is absent; a refused local connection costs next to nothing.
public final class RoonNowPlayingReader: NowPlayingSource {
    public static let extensionID = "app.joseon.Joseon"
    public static let defaultURL = URL(string: "ws://127.0.0.1:9330/api")!
    static let tokenKey = "roonExtensionToken"

    public let url: URL
    public let retryInterval: TimeInterval
    public var onChange: ((NowPlaying?) -> Void)?
    public var current: NowPlaying? { lock.withLock { latest } }

    private let queue = DispatchQueue(label: "app.joseon.roon", qos: .utility)
    private let session: URLSession
    private let lock = NSLock()
    private var latest: NowPlaying?
    private let defaults: UserDefaults

    // Owned by `queue`.
    private var running = false
    private var task: URLSessionWebSocketTask?
    /// Bumped on every connect, so callbacks of an old socket do nothing.
    private var generation = 0
    private var nextRequestID = 0
    private var registerID = -1
    private var subscribeID = -1
    private var book = RoonZoneBook()

    public init(url: URL = defaultURL, retryInterval: TimeInterval = 10, defaults: UserDefaults = .standard) {
        self.url = url
        self.retryInterval = retryInterval
        self.defaults = defaults
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: delegateQueue)
    }

    deinit { session.invalidateAndCancel() }

    // MARK: NowPlayingSource

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            connect()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            disconnect()
        }
    }

    // MARK: Connection (on `queue`)

    private func connect() {
        guard running, task == nil else { return }
        generation += 1
        book = RoonZoneBook()
        let socket = session.webSocketTask(with: url)
        task = socket
        socket.resume()
        receive(on: socket, generation: generation)
        registerID = send(.request, "com.roonlabs.registry:1/register", json: registration())
    }

    private func disconnect() {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        book = RoonZoneBook()
        publish(nil)
    }

    /// The socket closed or failed: show nothing and try again later.
    private func dropped(generation dropped: Int) {
        guard dropped == generation else { return }
        disconnect()
        let retry = generation
        queue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
            guard let self, self.generation == retry else { return }
            self.connect()
        }
    }

    private func receive(on socket: URLSessionWebSocketTask, generation current: Int) {
        socket.receive { [weak self] result in
            guard let self, current == self.generation else { return }
            switch result {
            case .failure:
                self.dropped(generation: current)
            case .success(let frame):
                let data: Data
                switch frame {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: data = Data()
                }
                if let message = MooMessage.decode(data) { self.handle(message) }
                self.receive(on: socket, generation: current)
            }
        }
    }

    private func handle(_ message: MooMessage) {
        switch message.verb {
        case .request:
            // The Core pings its extensions; anything else this reader does not offer.
            if message.name == "com.roonlabs.ping:1/ping" {
                reply(message.requestID, "Success")
            } else {
                reply(message.requestID, "InvalidRequest", json: ["error": "unknown request"])
            }
        case .continue, .complete:
            if message.requestID == registerID, message.name == "Registered" {
                if let token = message.json?["token"] as? String { defaults.set(token, forKey: Self.tokenKey) }
                subscribeID = send(.request, "com.roonlabs.transport:2/subscribe_zones", json: ["subscription_key": 1])
            } else if message.requestID == subscribeID, let body = message.json {
                book.apply(body)
                publish(book.pick())
            }
        }
    }

    private func registration() -> [String: Any] {
        var info: [String: Any] = [
            "extension_id": Self.extensionID,
            "display_name": "Joseon",
            "display_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            "publisher": "Caerul LLC",
            "email": "",
            "website": "https://github.com/jasas1/Joseon",
            "required_services": ["com.roonlabs.transport:2"],
            "optional_services": [String](),
            "provided_services": ["com.roonlabs.ping:1"],
        ]
        if let token = defaults.string(forKey: Self.tokenKey) { info["token"] = token }
        return info
    }

    @discardableResult
    private func send(_ verb: MooMessage.Verb, _ name: String, json: [String: Any]) -> Int {
        let id = nextRequestID
        nextRequestID += 1
        write(MooMessage(verb: verb, name: name, requestID: id, json: json))
        return id
    }

    private func reply(_ id: Int, _ name: String, json: [String: Any]? = nil) {
        write(json.map { MooMessage(verb: .complete, name: name, requestID: id, json: $0) }
              ?? MooMessage(verb: .complete, name: name, requestID: id))
    }

    private func write(_ message: MooMessage) {
        guard let socket = task else { return }
        let current = generation
        socket.send(.data(message.encoded())) { [weak self] error in
            if error != nil { self?.dropped(generation: current) }
        }
    }

    private func publish(_ value: NowPlaying?) {
        lock.lock()
        let changed = value != latest
        latest = value
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
    }
}
