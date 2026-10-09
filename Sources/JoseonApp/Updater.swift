import AppKit
import CryptoKit
import JoseonCore
import Security

/// Updates: looks for a newer release on the project page, fetches it, checks it, puts it in the place of
/// this app and starts it. Nothing is sent but the request for the release list.
///
/// A new app is taken only when macOS says its signature is valid and it comes from the same team as this
/// app. So an update can never be a program of somebody else, and the permissions of Joseon stay.
final class Updater {
    /// JOSEON_UPDATE_FEED (a test): another release list, whose files may then also be local files. The
    /// signature check stays, so a test cannot put a foreign app in place either.
    private static let testFeed = ProcessInfo.processInfo.environment["JOSEON_UPDATE_FEED"].flatMap(URL.init(string:))
    static let releasesURL = testFeed ?? URL(string: "https://api.github.com/repos/jasas1/Joseon/releases?per_page=10")!
    static let allowedPrefixes = ["https://github.com/jasas1/"] + (testFeed == nil ? [] : ["file:///"])
    /// JOSEON_UPDATE_ACCEPT=1 with a test feed: take the update without the question.
    static let acceptsWithoutAsking = testFeed != nil && ProcessInfo.processInfo.environment["JOSEON_UPDATE_ACCEPT"] == "1"
    static let assetSuffix = "-macos.zip"

    enum Failure: LocalizedError {
        case noAnswer, list(String), download, checksum, unpack, noApp, signature(String), wrongVersion, place(String)

        var errorDescription: String? {
            switch self {
            case .noAnswer: return "The update server did not answer."
            case .list(let why): return "The list of versions could not be read (\(why))."
            case .download: return "The download did not finish."
            case .checksum: return "The download is not the file of the release (checksum)."
            case .unpack: return "The download could not be unpacked."
            case .noApp: return "The release holds no Joseon app."
            case .signature(let why): return "The new app was not accepted: \(why)"
            case .wrongVersion: return "The new app is not the version the release names."
            case .place(let why): return "Joseon could not be replaced: \(why)"
            }
        }
    }

    private(set) var isBusy = false

    static var currentVersion: AppVersion {
        AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? AppVersion(0, 0, 0)
    }

    /// The release that is newer than this app. `nil` when this app is the newest.
    func check() async throws -> UpdateRelease? {
        var request = URLRequest(url: Self.releasesURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Joseon/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { throw Failure.noAnswer }
        do {
            let newest = try UpdateFeed.newestRelease(json: data, assetSuffix: Self.assetSuffix, allowedPrefixes: Self.allowedPrefixes)
            return newest.flatMap { $0.version > Self.currentVersion ? $0 : nil }
        } catch UpdateFeedError.refused(let message) {
            throw Failure.list(message)
        } catch {
            throw Failure.list("not a list")
        }
    }

    /// Fetches `release`, checks it and puts it in the place of this app. The caller then calls `relaunch`.
    func install(_ release: UpdateRelease) async throws {
        isBusy = true
        defer { isBusy = false }
        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else { throw Failure.place("this Joseon does not run from an app bundle.") }
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw Failure.place("the folder \(current.deletingLastPathComponent().path) cannot be written.")
        }
        guard let (file, _) = try? await URLSession.shared.download(from: release.assetURL) else { throw Failure.download }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("joseon-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let newApp = try await Task.detached(priority: .userInitiated) {
            try Self.unpackAndCheck(zip: file, work: work, release: release, team: Self.teamIdentifier(of: current))
        }.value
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp)
        } catch {
            throw Failure.place(error.localizedDescription)
        }
    }

    /// Starts the app again when this process is gone, and ends this process.
    @MainActor func relaunch() {
        let script = "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: Checks (off the main thread)

    private static func unpackAndCheck(zip: URL, work: URL, release: UpdateRelease, team: String?) throws -> URL {
        guard let bytes = try? Data(contentsOf: zip) else { throw Failure.download }
        if let wanted = release.sha256 {
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard digest == wanted else { throw Failure.checksum }
        }
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, work.path]
        guard (try? ditto.run()) != nil else { throw Failure.unpack }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Failure.unpack }
        let app = work.appendingPathComponent("Joseon.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw Failure.noApp }
        try checkSignature(of: app, team: team)
        let version = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard version.flatMap(AppVersion.init) == release.version else { throw Failure.wrongVersion }
        return app
    }

    /// The team that signed the app at `url`. `nil` for an app with no team (signed ad hoc, or not signed).
    static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The new app must be Joseon, whole, and signed by the team that signed this app.
    private static func checkSignature(of app: URL, team: String?) throws {
        guard let team, !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw Failure.signature("this Joseon has no signing team, so it cannot tell whose app the new one is. Build it from the source.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure.signature("it has no signature.")
        }
        let text = "anchor apple generic and identifier \"app.joseon.Joseon\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw Failure.signature("the check could not be set up.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw Failure.signature("its signature is not valid, or it is not from the maker of this Joseon.")
        }
    }
}

// MARK: - The menu item and the questions

@MainActor
extension AppDelegate {
    /// "Check for Updates…" in the app menu.
    @objc func checkForUpdates(_ sender: Any?) {
        runUpdateCheck(userAsked: true)
    }

    /// The check the app makes by itself: after the start and once a day, when the setting is on.
    func startAutomaticUpdateChecks() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            while let self {
                self.automaticUpdateCheck()
                try? await Task.sleep(nanoseconds: 24 * 3600 * 1_000_000_000)
            }
        }
    }

    private func automaticUpdateCheck() {
        guard settings.checkUpdatesAutomatically else { return }
        runUpdateCheck(userAsked: false)
    }

    /// `userAsked` = say also "you have the newest" and why a check failed. The check the app makes by itself
    /// speaks only when there is a new version, and only once per version.
    private func runUpdateCheck(userAsked: Bool) {
        guard !updater.isBusy else { return }
        Task { @MainActor in
            do {
                guard let release = try await updater.check() else {
                    if Updater.acceptsWithoutAsking { FileHandle.standardError.write(Data("update check: nothing newer\n".utf8)) }
                    if userAsked { self.updateAlert("Joseon \(Updater.currentVersion) is the newest version.", "") }
                    return
                }
                let offered = "updateLastOffered"
                if !userAsked && UserDefaults.standard.string(forKey: offered) == release.version.description { return }
                UserDefaults.standard.set(release.version.description, forKey: offered)
                self.offer(release)
            } catch {
                if userAsked { self.updateAlert("Joseon could not look for updates.", error.localizedDescription) }
                if Updater.acceptsWithoutAsking {
                    FileHandle.standardError.write(Data("update check failed: \(error.localizedDescription)\n".utf8))
                }
            }
        }
    }

    private func offer(_ release: UpdateRelease) {
        if Updater.acceptsWithoutAsking {
            Task { @MainActor in
                do { try await updater.install(release); updater.relaunch() } catch {
                    FileHandle.standardError.write(Data("update failed: \(error.localizedDescription)\n".utf8))
                }
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Joseon \(release.version) is there."
        alert.informativeText = "You have \(Updater.currentVersion). Joseon fetches the new version, checks that it comes from the same maker, puts it in place and starts again. Your settings stay."
        alert.addButton(withTitle: "Update and Relaunch")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            do {
                try await updater.install(release)
                updater.relaunch()
            } catch {
                self.updateAlert("The update did not work.", error.localizedDescription)
            }
        }
    }

    private func updateAlert(_ message: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
