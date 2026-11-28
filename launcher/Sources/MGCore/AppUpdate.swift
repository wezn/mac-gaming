#if os(macOS)
import Darwin
import Foundation

/// Replacing the running MacGaming.app with a release's `MacGaming-<version>.zip`.
///
/// The zip is downloaded by `Updater.fetch` (curl: no quarantine flag, so an ad-hoc signed build opens
/// without another "Open Anyway"), unpacked with ditto next to the installed bundle, checked (codesign,
/// bundle id, version) and swapped in with one `renamex_np(RENAME_SWAP)`. The caller relaunches.
public enum AppBundleUpdate {
    /// Throws a readable error if `bundle` cannot be replaced in place.
    public static func checkReplaceable(_ bundle: URL) throws {
        let path = bundle.path
        if path.contains("/AppTranslocation/") {
            throw MGError.update("Mac Gaming is running from a temporary read-only copy that macOS made because the app was opened from Downloads (App Translocation). Move Mac Gaming to the Applications folder with Finder, open it from there, and check for updates again.")
        }
        let parent = bundle.deletingLastPathComponent()
        guard access(parent.path, W_OK) == 0, access(path, W_OK) == 0 else {
            let reason = errno == EROFS ? "is on a read-only volume" : "is not writable by your account"
            throw MGError.update("Mac Gaming cannot update itself because \(parent.path) \(reason). Move Mac Gaming to the Applications folder (or ~/Applications), open it from there, and check for updates again.")
        }
    }

    /// Unpacks `zip` into `workDir` and returns the verified `.app` inside.
    public static func unpackAndVerify(zip: URL, into workDir: URL, expectedVersion: String,
                                       bundleIdentifier: String?) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let code = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, workDir.path],
                                      environment: ProcessInfo.processInfo.environment, output: .null)
        guard code == 0 else { throw MGError.update("cannot unpack \(zip.lastPathComponent) (ditto exit code \(code))") }
        let apps = ((try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else {
            throw MGError.update("\(zip.lastPathComponent) should contain exactly one .app, found \(apps.count)")
        }
        try verify(app, expectedVersion: expectedVersion, bundleIdentifier: bundleIdentifier)
        return app
    }

    /// Info.plist (identifier, version, executable) and a valid code signature (ad-hoc is fine).
    public static func verify(_ app: URL, expectedVersion: String, bundleIdentifier: String?) throws {
        let name = app.lastPathComponent
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw MGError.update("\(name) has no readable Contents/Info.plist")
        }
        if let want = bundleIdentifier, (info["CFBundleIdentifier"] as? String) != want {
            throw MGError.update("\(name) has bundle identifier \(info["CFBundleIdentifier"] as? String ?? "none"), expected \(want)")
        }
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        guard let got = SemVer(version), got == SemVer(expectedVersion) else {
            throw MGError.update("\(name) is version '\(version)', but the release says \(expectedVersion)")
        }
        guard let exe = info["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(exe)").path) else {
            throw MGError.update("\(name) has no executable")
        }
        let code = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", app.path],
                                      environment: ProcessInfo.processInfo.environment, output: .null)
        guard code == 0 else { throw MGError.update("\(name) has an invalid code signature (codesign --verify exit code \(code))") }
    }

    /// Atomically exchanges `installed` and `new` (same volume), then deletes the old bundle.
    public static func swap(_ installed: URL, with new: URL) throws {
        if renamex_np(new.path, installed.path, UInt32(RENAME_SWAP)) == 0 {
            try? FileManager.default.removeItem(at: new)   // now holds the old version
            return
        }
        let swapError = String(cString: strerror(errno))
        do {
            _ = try FileManager.default.replaceItemAt(installed, withItemAt: new)
        } catch {
            throw MGError.update("cannot replace \(installed.path): \(swapError); \(error.localizedDescription)")
        }
    }

    /// A scratch directory on the same volume as `bundle` (so the swap is a rename), else next to it.
    static func workDirectory(for bundle: URL) throws -> URL {
        if let d = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: bundle, create: true) {
            return d
        }
        let d = bundle.deletingLastPathComponent().appendingPathComponent(".MacGaming-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
}

extension Updater {
    /// Downloads, verifies and installs the release's app over `bundle`. Does not relaunch.
    public func installApp(_ m: ReleaseManifest, replacing bundle: URL, bundleIdentifier: String?,
                           log: (String) -> Void = { _ in }) throws {
        guard let asset = m.app else { throw MGError.update("release \(m.version) has no app") }
        try AppBundleUpdate.checkReplaceable(bundle)
        let zip = try fetch(asset, version: m.version, log: log)
        let work = try AppBundleUpdate.workDirectory(for: bundle)
        defer { try? FileManager.default.removeItem(at: work) }
        log("unpacking \(asset.file)")
        let app = try AppBundleUpdate.unpackAndVerify(zip: zip, into: work.appendingPathComponent("unpacked", isDirectory: true),
                                                      expectedVersion: m.version, bundleIdentifier: bundleIdentifier)
        log("replacing \(bundle.path)")
        try AppBundleUpdate.swap(bundle, with: app)
        try? FileManager.default.removeItem(at: zip)
    }
}
#endif
