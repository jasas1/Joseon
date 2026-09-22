import AppKit
import ApplicationServices
import Foundation
import JoseonCore

// Reads the track text of the Qobuz desktop app through the Accessibility API.
//
// Qobuz (Electron) hides its web content from the Accessibility API until a client sets
// `AXManualAccessibility` = true on the application element. After that, the player bar shows up in the
// window's first AXWebArea and `NowPlayingParser` reads it. The AX tree of an Electron app takes a moment
// to populate after the flag is set, so the first polls after a launch may read nothing.
//
// This file never plays audio, never opens an input, and never shows the Accessibility prompt on its own:
// `requestTrust()` is a separate call the app makes when it decides to.

/// `AXNodeLike` over a live `AXUIElement`. Attribute reads are IPC calls; each one is cached after the first read.
public final class AXElementNode: AXNodeLike {
    public let element: AXUIElement

    public init(_ element: AXUIElement) { self.element = element }

    public private(set) lazy var role: String = string(kAXRoleAttribute)
    public private(set) lazy var domIdentifier: String = string("AXDOMIdentifier")
    public private(set) lazy var domClasses: [String] = (attribute("AXDOMClassList") as? [String]) ?? []
    public private(set) lazy var description: String = string(kAXDescriptionAttribute)
    public private(set) lazy var value: String = string(kAXValueAttribute)
    public private(set) lazy var children: [AXElementNode] = Self.elements(attribute(kAXChildrenAttribute)).map(AXElementNode.init)

    func attribute(_ name: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &out) == .success ? out : nil
    }

    func string(_ name: String) -> String {
        guard let raw = attribute(name) else { return "" }
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return ""
    }

    static func elements(_ raw: CFTypeRef?) -> [AXUIElement] {
        guard let array = raw as? [AnyObject] else { return [] }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    /// The application element of a running process.
    public static func application(pid: pid_t) -> AXElementNode { AXElementNode(AXUIElementCreateApplication(pid)) }

    /// The windows of an application element (`kAXWindowsAttribute`), without the menu bar and the rest.
    public var windows: [AXElementNode] { Self.elements(attribute(kAXWindowsAttribute)).map(AXElementNode.init) }
}

/// Polls the player's accessibility tree on a background queue and reports changes on the main queue.
public final class AccessibilityNowPlayingReader: NowPlayingSource {
    public static let qobuzBundleIdentifier = "com.qobuz.desktop"

    /// This process may use the Accessibility API (System Settings › Privacy & Security › Accessibility).
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that asks the user to grant Accessibility access. The reader never calls it.
    public static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first { !$0.isTerminated }
    }

    public let bundleIdentifier: String
    public let source: String
    /// Poll period while the player runs and the permission is granted.
    public let interval: TimeInterval
    /// Poll period while the player is absent or the permission is missing: only a running-app check runs then.
    public let idleInterval: TimeInterval
    /// Nodes one poll may visit. See `NowPlayingParser`.
    public var nodeCap = NowPlayingParser.defaultNodeCap
    /// Seconds one AX call may block when the player hangs, so a stuck player cannot freeze the poll.
    public var messagingTimeout: Float = 0.5

    public var onChange: ((NowPlaying?) -> Void)?
    public var current: NowPlaying? { lock.withLock { latest } }

    private let queue = DispatchQueue(label: "app.joseon.now-playing", qos: .utility)
    private let lock = NSLock()
    private var latest: NowPlaying?
    private var timer: DispatchSourceTimer?
    /// The pid that has `AXManualAccessibility` set. A new launch of the player needs the flag again.
    private var flaggedPID: pid_t = 0

    public init(bundleIdentifier: String = qobuzBundleIdentifier, source: String = "Qobuz",
                interval: TimeInterval = 1.0, idleInterval: TimeInterval = 5.0) {
        self.bundleIdentifier = bundleIdentifier
        self.source = source
        self.interval = interval
        self.idleInterval = idleInterval
    }

    deinit { timer?.cancel() }

    public var isPlayerRunning: Bool { Self.runningApplication(bundleIdentifier: bundleIdentifier) != nil }

    // MARK: NowPlayingSource

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.setEventHandler { [weak self] in self?.poll() }
        t.schedule(deadline: .now())
        t.resume()
        timer = t
    }

    public func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
        publish(nil)
    }

    // MARK: Reading

    /// One synchronous read: sets the flag when this launch of the player has none yet, then parses its windows.
    /// Nil when the player is absent, the permission is missing, or no track is loaded.
    /// Call it off the main thread: it makes AX calls that can block up to `messagingTimeout` each.
    public func readNow() -> NowPlaying? {
        guard Self.isTrusted, let app = Self.runningApplication(bundleIdentifier: bundleIdentifier) else { return nil }
        let pid = app.processIdentifier
        let root = AXElementNode.application(pid: pid)
        AXUIElementSetMessagingTimeout(root.element, messagingTimeout)
        if pid != flaggedPID {
            let status = AXUIElementSetAttributeValue(root.element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if status == .success { flaggedPID = pid }
        }
        for window in root.windows {
            if let found = NowPlayingParser.parse(root: window, source: source, nodeCap: nodeCap) { return found }
        }
        return nil
    }

    private func poll() {
        let active = Self.isTrusted && isPlayerRunning
        publish(active ? readNow() : nil)
        lock.lock()
        timer?.schedule(deadline: .now() + (active ? interval : idleInterval))
        lock.unlock()
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
