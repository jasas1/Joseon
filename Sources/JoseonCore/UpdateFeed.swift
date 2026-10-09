import Foundation

/// A version as the release tags write it: "v1.2.3".
public struct AppVersion: Comparable, Equatable, CustomStringConvertible, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    /// "v0.1.2", "0.1.2". `nil` for everything else: a tag such as "nightly" is no version.
    public init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("v") { body.removeFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// A release that has a file for this system.
public struct UpdateRelease: Equatable, Sendable {
    public var version: AppVersion
    public var assetName: String
    public var assetURL: URL
    /// The SHA-256 of the file as the release list tells it, in lowercase hex. `nil` when the list has none.
    public var sha256: String?
}

public enum UpdateFeedError: Error, Equatable {
    /// The answer is not a release list.
    case unreadable
    /// The server answered with a message in place of a list (a limit, a missing project).
    case refused(String)
}

/// Reads the release list of the project (the JSON of the GitHub releases API).
public enum UpdateFeed {
    /// The newest release of the list that has a file whose name ends with `assetSuffix`.
    /// Drafts do not count. A file from a place outside `allowedPrefixes` does not count.
    public static func newestRelease(json: Data, assetSuffix: String, allowedPrefixes: [String]) throws -> UpdateRelease? {
        guard let parsed = try? JSONSerialization.jsonObject(with: json) else { throw UpdateFeedError.unreadable }
        guard let list = parsed as? [[String: Any]] else {
            if let object = parsed as? [String: Any], let message = object["message"] as? String {
                throw UpdateFeedError.refused(message)
            }
            throw UpdateFeedError.unreadable
        }
        var best: UpdateRelease?
        for release in list {
            if release["draft"] as? Bool == true { continue }
            guard let tag = release["tag_name"] as? String, let version = AppVersion(tag),
                  let assets = release["assets"] as? [[String: Any]] else { continue }
            guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(assetSuffix) == true }),
                  let name = asset["name"] as? String,
                  let address = asset["browser_download_url"] as? String,
                  allowedPrefixes.contains(where: { address.hasPrefix($0) }),
                  let url = URL(string: address) else { continue }
            if best == nil || version > best!.version {
                let digest = (asset["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
                best = UpdateRelease(version: version, assetName: name, assetURL: url, sha256: digest)
            }
        }
        return best
    }
}
