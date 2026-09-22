import Foundation
import JoseonCore

// Pure tree walk that finds the track text in a player's accessibility tree.
// No AX calls here: the tree comes in through `AXNodeLike`, so tests use a fake tree and the
// real reader (`AccessibilityNowPlayingReader`) wraps `AXUIElement`.

/// One node of an accessibility tree, as far as the parser needs it.
/// Every property may cost an IPC round trip in the real adapter, so the parser reads each one at most once per node.
public protocol AXNodeLike {
    /// "AXGroup", "AXLink", "AXStaticText", "AXWebArea", ...
    var role: String { get }
    /// The DOM `id` of a web node ("" elsewhere).
    var domIdentifier: String { get }
    /// The DOM `class` list of a web node ([] elsewhere).
    var domClasses: [String] { get }
    /// AXDescription: the accessible name of a link or a button.
    var description: String { get }
    /// AXValue as text: the text of a static text node.
    var value: String { get }
    var children: [Self] { get }
}

/// Finds the Qobuz player bar (`#bottomPlayerContainer`) and reads title, artist, album and the hi-res flag.
///
/// Proven structure (Qobuz 8.2.0, Electron 32): the first `AXWebArea` of the window holds an `AXGroup`
/// with `AXDOMIdentifier` `bottomPlayerContainer` and classes `["player", "hires"]` (`hires` only for a hi-res stream).
/// Inside it: `.player__track-infos` → an `AXLink.player__track-name` (title), and a group
/// `.player__track-album` with two `AXLink`s: artist, then album.
///
/// The walk does not depend on the exact nesting depth. It searches by identifier and class, and it visits at most
/// `nodeCap` nodes in total, so a huge page cannot stall a poll.
public enum NowPlayingParser {
    public static let defaultNodeCap = 5000
    public static let containerIdentifier = "bottomPlayerContainer"
    public static let titleClass = "player__track-name"
    public static let albumClass = "player__track-album"
    public static let hiResClass = "hires"

    /// Nil when the player bar or the title or the artist is missing (no track loaded), or when the cap is hit first.
    public static func parse<Node: AXNodeLike>(root: Node, source: String = "Qobuz", nodeCap: Int = defaultNodeCap) -> NowPlaying? {
        parseCounting(root: root, source: source, nodeCap: nodeCap).value
    }

    /// `parse` plus the number of nodes it visited (tests check the cap with it).
    static func parseCounting<Node: AXNodeLike>(root: Node, source: String, nodeCap: Int) -> (value: NowPlaying?, visited: Int) {
        var budget = Budget(remaining: max(0, nodeCap))
        // The player bar sits a few levels under the window whatever the page shows, so a level-order search finds it
        // without walking the page content first (a depth-first walk would explore a long track list before it).
        guard let container = firstBreadthFirst(from: root, budget: &budget, where: { $0.domIdentifier == containerIdentifier }) else {
            return (nil, budget.visited)
        }
        guard let titleNode = firstDepthFirst(from: container, budget: &budget, where: { $0.domClasses.contains(titleClass) }) else {
            return (nil, budget.visited)
        }
        let title = text(of: titleNode, budget: &budget)
        guard !title.isEmpty else { return (nil, budget.visited) }

        var artist = "", album = ""
        if let albumGroup = firstDepthFirst(from: container, budget: &budget, where: { $0.domClasses.contains(albumClass) }) {
            // Position carries the meaning: first link = artist, second = album. An empty first link stays empty,
            // so an album never slides into the artist slot.
            var texts = allDepthFirst(from: albumGroup, budget: &budget, where: { $0.role == "AXLink" })
                .map { text(of: $0, budget: &budget) }
            if texts.isEmpty {   // no links: plain text children, for example "Various Artists"
                texts = allDepthFirst(from: albumGroup, budget: &budget, where: { $0.role == "AXStaticText" })
                    .map { trim($0.value) }
            }
            artist = texts.first ?? ""
            album = texts.count > 1 ? texts[1] : ""
        }
        guard !artist.isEmpty else { return (nil, budget.visited) }
        let value = NowPlaying(title: title, artist: artist, album: album, source: source,
                               isHiRes: container.domClasses.contains(hiResClass))
        return (value, budget.visited)
    }

    // MARK: - Walks

    /// Shared node budget of one parse. Every visited node takes one unit; at zero every walk stops.
    struct Budget {
        var remaining: Int
        var visited = 0
        mutating func take() -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            visited += 1
            return true
        }
    }

    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Text of a link or a label: its description, else its value, else the first non-empty static text under it.
    static func text<Node: AXNodeLike>(of node: Node, budget: inout Budget) -> String {
        let description = trim(node.description)
        if !description.isEmpty { return description }
        let own = trim(node.value)
        if !own.isEmpty { return own }
        guard let label = firstDepthFirst(from: node, budget: &budget, where: { $0.role == "AXStaticText" && !trim($0.value).isEmpty }) else {
            return ""
        }
        return trim(label.value)
    }

    static func firstBreadthFirst<Node: AXNodeLike>(from root: Node, budget: inout Budget, where match: (Node) -> Bool) -> Node? {
        var queue = [root]
        var head = 0
        while head < queue.count {
            let node = queue[head]
            head += 1
            guard budget.take() else { return nil }
            if match(node) { return node }
            queue.append(contentsOf: node.children)
        }
        return nil
    }

    static func firstDepthFirst<Node: AXNodeLike>(from root: Node, budget: inout Budget, where match: (Node) -> Bool) -> Node? {
        var stack = [root]
        while let node = stack.popLast() {
            guard budget.take() else { return nil }
            if match(node) { return node }
            stack.append(contentsOf: node.children.reversed())
        }
        return nil
    }

    /// Every match under `root`, in document order. Matched nodes are not descended into.
    static func allDepthFirst<Node: AXNodeLike>(from root: Node, budget: inout Budget, where match: (Node) -> Bool) -> [Node] {
        var found: [Node] = []
        var stack = Array(root.children.reversed())
        while let node = stack.popLast() {
            guard budget.take() else { break }
            if match(node) { found.append(node); continue }
            stack.append(contentsOf: node.children.reversed())
        }
        return found
    }
}
