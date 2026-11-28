import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// Updates come from GitHub Releases. Each release publishes `manifest.json`:
//
//     {"version": "0.2.0", "published": "2026-11-28T12:00:00Z",
//      "app": {"file": "MacGaming-0.2.0.zip", "sha256": "…"},
//      "mgx": {"file": "mgx-0.2.0-macos-arm64.tar.gz", "sha256": "…"},
//      "runtime": [{"kind": "wine", "file": "wine-crossover-26.3.0-wow64.tar.xz", "version": "crossover-26.3.0-wow64", "sha256": "…"}, …]}
//
// mgx and the app download it themselves (curl, never a browser), so nothing they fetch is quarantined and
// an ad-hoc signed build keeps working after an update without another "Open Anyway". Every file is checked
// against the manifest's SHA-256 before it is used.

// MARK: versions

/// A semantic version (`1.2.3`, `v1.2.3`, `1.2.3-beta.1`, `1.2.3+build`). Build metadata is ignored.
public struct SemVer: Comparable, Hashable, CustomStringConvertible, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Also accepts `1` and `1.2` (missing parts are 0).
    public init?(_ string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let ok = pre.allSatisfy { id in !id.isEmpty && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") } }
            guard ok else { return nil }
            s = s[..<dash]
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            nums.append(n)
        }
        while nums.count < 3 { nums.append(0) }
        self.init(major: nums[0], minor: nums[1], patch: nums[2], prerelease: pre)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    /// Semver precedence: a pre-release sorts before its release; numeric identifiers compare as numbers
    /// and sort before alphanumeric ones.
    public static func < (a: SemVer, b: SemVer) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): if i != j { return i < j }
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

// MARK: manifest

/// `manifest.json` of a release.
public struct ReleaseManifest: Codable, Equatable, Sendable {
    public struct Asset: Codable, Equatable, Sendable {
        public var file: String
        public var sha256: String
        /// Bytes, if the release states it (used for progress bars only).
        public var size: Int64?

        public init(file: String, sha256: String, size: Int64? = nil) {
            self.file = file
            self.sha256 = sha256
            self.size = size
        }
    }

    public struct RuntimeAsset: Codable, Equatable, Sendable {
        /// `wine`, `dxmt` or `dxvk`. Kept as a string so a release can add kinds older builds skip.
        public var kind: String
        public var file: String
        public var version: String
        public var sha256: String
        public var size: Int64?

        public init(kind: String, file: String, version: String, sha256: String, size: Int64? = nil) {
            self.kind = kind
            self.file = file
            self.version = version
            self.sha256 = sha256
            self.size = size
        }

        public var component: RuntimeComponent? { RuntimeComponent(rawValue: kind) }
        public var asset: Asset { Asset(file: file, sha256: sha256, size: size) }
    }

    public var version: String
    public var published: String?
    public var app: Asset?
    public var mgx: Asset?
    public var runtime: [RuntimeAsset]

    public init(version: String, published: String? = nil, app: Asset? = nil, mgx: Asset? = nil, runtime: [RuntimeAsset] = []) {
        self.version = version
        self.published = published
        self.app = app
        self.mgx = mgx
        self.runtime = runtime
    }

    enum CodingKeys: String, CodingKey { case version, published, app, mgx, runtime }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        published = try c.decodeIfPresent(String.self, forKey: .published)
        app = try c.decodeIfPresent(Asset.self, forKey: .app)
        mgx = try c.decodeIfPresent(Asset.self, forKey: .mgx)
        runtime = try c.decodeIfPresent([RuntimeAsset].self, forKey: .runtime) ?? []
    }

    public var semver: SemVer? { SemVer(version) }

    /// The runtime components this build knows, in a stable order (wine, dxmt, dxvk).
    public var runtimeComponents: [RuntimeAsset] {
        RuntimeComponent.allCases.compactMap { c in runtime.first { $0.component == c } }
    }

    /// Decodes and validates. Errors are `MGError.update` with a readable reason.
    public static func decode(_ data: Data) throws -> ReleaseManifest {
        let m: ReleaseManifest
        do { m = try JSONDecoder().decode(ReleaseManifest.self, from: data) } catch {
            throw MGError.update("the release manifest is not valid: \(Self.describe(error))")
        }
        try m.validate()
        return m
    }

    /// File names become paths in the cache and URL path components, so keep them to one plain name.
    public func validate() throws {
        guard semver != nil else { throw MGError.update("the release manifest has an invalid version '\(version)'") }
        var all: [Asset] = []
        if let app { all.append(app) }
        if let mgx { all.append(mgx) }
        all += runtime.map(\.asset)
        for a in all {
            guard Self.isSafeFileName(a.file) else { throw MGError.update("the release manifest names an unsafe file '\(a.file)'") }
            guard Self.isSHA256(a.sha256) else { throw MGError.update("the release manifest has an invalid sha256 for \(a.file)") }
        }
        for c in RuntimeComponent.allCases where runtime.filter({ $0.component == c }).count > 1 {
            throw MGError.update("the release manifest lists more than one \(c.rawValue) runtime file")
        }
    }

    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 200 && !name.hasPrefix(".") && !name.hasPrefix("-")
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._+-".unicodeScalars.contains($0)) }
    }

    static func isSHA256(_ s: String) -> Bool {
        s.count == 64 && s.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, let ctx):
            return "missing \"\(key.stringValue)\"" + (ctx.codingPath.isEmpty ? "" : " in \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
        case DecodingError.typeMismatch(_, let ctx), DecodingError.valueNotFound(_, let ctx):
            return "wrong type at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.dataCorrupted(let ctx):
            return ctx.debugDescription
        default:
            return "\(error)"
        }
    }
}

// MARK: where releases come from

/// Where the manifest and the release files are downloaded from.
///
/// The default is this repository's latest GitHub release. `MG_UPDATE_URL` (or `update-url` in
/// config.json) points elsewhere: a `…/manifest.json` URL, a directory URL, or a local path. Files are then
/// taken from the manifest's directory, except for a `github.com/<owner>/<repo>/releases/latest/download`
/// URL, which uses that repository's release layout (a fork).
public struct UpdateSource: Equatable, Sendable, CustomStringConvertible {
    public enum Layout: Equatable, Sendable {
        /// `https://github.com/<repo>/releases/download/v<version>/<file>`.
        case githubReleases(String)
        /// Next to the manifest.
        case flat
    }

    public static let repository = "wezn/mac-gaming"
    public static let environmentKey = "MG_UPDATE_URL"
    public static let `default` = UpdateSource.github(repository)

    public let manifestURL: URL
    public let layout: Layout

    public init(manifestURL: URL, layout: Layout) {
        self.manifestURL = manifestURL
        self.layout = layout
    }

    public static func github(_ repo: String) -> UpdateSource {
        UpdateSource(manifestURL: URL(string: "https://github.com/\(repo)/releases/latest/download/manifest.json")!,
                     layout: .githubReleases(repo))
    }

    /// Parses a configured source. Accepts https URLs, http on a loopback host, file URLs and paths.
    public init(string raw: String) throws {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw MGError.invalidConfig("update URL is empty") }
        var url: URL
        if s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix(".") {
            url = URL(fileURLWithPath: (s as NSString).expandingTildeInPath).standardizedFileURL
        } else if let u = URL(string: s), let scheme = u.scheme?.lowercased() {
            switch scheme {
            case "https", "file": break
            case "http" where Downloader.isLoopback(u): break
            default: throw MGError.invalidConfig("update URL must be https:// (or http:// on 127.0.0.1, or a local path): \(s)")
            }
            guard scheme == "file" || u.host != nil else { throw MGError.invalidConfig("update URL has no host: \(s)") }
            url = u
        } else {
            throw MGError.invalidConfig("not a URL or path: \(s)")
        }
        if url.pathExtension.lowercased() != "json" {
            url = url.appendingPathComponent("manifest.json")
        }
        let comps = url.pathComponents   // ["/", owner, repo, "releases", "latest", "download", "manifest.json"]
        if url.scheme == "https", url.host?.lowercased() == "github.com", comps.count == 7,
           Array(comps[3...5]) == ["releases", "latest", "download"] {
            self.init(manifestURL: url, layout: .githubReleases("\(comps[1])/\(comps[2])"))
        } else {
            self.init(manifestURL: url, layout: .flat)
        }
    }

    /// `MG_UPDATE_URL`, then config.json's `updateURL`, then GitHub.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               config: GlobalConfig) throws -> UpdateSource {
        if let e = environment[environmentKey], !e.isEmpty { return try UpdateSource(string: e) }
        if let c = config.updateURL, !c.isEmpty { return try UpdateSource(string: c) }
        return .default
    }

    /// The URL of one of a release's files. Pinned to the release (not `latest`), so a release published
    /// between fetching the manifest and the file cannot mix versions.
    public func assetURL(_ file: String, version: String) -> URL {
        switch layout {
        case .githubReleases(let repo):
            let tag = version.hasPrefix("v") ? version : "v\(version)"
            return URL(string: "https://github.com/\(repo)/releases/download/\(tag)/\(file)")!
        case .flat:
            return manifestURL.deletingLastPathComponent().appendingPathComponent(file)
        }
    }

    public var description: String { manifestURL.isFileURL ? manifestURL.path : manifestURL.absoluteString }
}

// MARK: checksums

public enum Checksum {
    /// Lowercase hex SHA-256 of a file, read in chunks (runtime tarballs are hundreds of MB).
    public static func sha256(of file: URL) throws -> String {
        #if canImport(CryptoKit)
        let fh: FileHandle
        do { fh = try FileHandle(forReadingFrom: file) } catch {
            throw MGError.io("cannot read \(file.path): \(error.localizedDescription)")
        }
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        // Linux builds (tests only): coreutils.
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mgx-sha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let code = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/sha256sum"), [file.path], environment: [:], output: .file(out))
        guard code == 0, let text = try? String(contentsOf: out, encoding: .utf8),
              let hex = text.split(separator: " ").first else { throw MGError.io("cannot hash \(file.path)") }
        return String(hex).lowercased()
        #endif
    }

    /// Throws (and deletes `file`) unless its SHA-256 is `expected`.
    public static func verify(_ file: URL, sha256 expected: String) throws {
        let actual = try sha256(of: file)
        guard actual == expected.lowercased() else {
            try? FileManager.default.removeItem(at: file)
            throw MGError.update("\(file.lastPathComponent) failed verification (SHA-256 \(actual), expected \(expected.lowercased())); it was deleted")
        }
    }
}

// MARK: cache

/// `cache/updates/`: the last manifest fetched (what `mgx doctor` reads, never the network) and downloads.
public struct UpdateCache: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var fetched: Date
        public var source: String
        public var manifest: ReleaseManifest
    }

    public let paths: MGPaths

    public init(paths: MGPaths) { self.paths = paths }

    public var directory: URL { paths.cache.appendingPathComponent("updates", isDirectory: true) }
    public var latestFile: URL { directory.appendingPathComponent("latest.json") }
    public func downloads(version: String) -> URL { directory.appendingPathComponent(version, isDirectory: true) }

    public func load() -> Entry? { try? JSONFile.loadIfPresent(Entry.self, from: latestFile) }

    public func save(_ manifest: ReleaseManifest, source: UpdateSource, at date: Date = Date()) throws {
        try JSONFile.save(Entry(fetched: date, source: source.description, manifest: manifest), to: latestFile)
    }
}

// MARK: runtime updates

/// What `mgx runtime update` would do.
public struct RuntimeUpdatePlan: Equatable, Sendable {
    /// The runtime the files go into: named after the release's Wine archive, like `mgx runtime install`.
    public var runtime: String
    /// The runtime does not exist yet.
    public var isNewRuntime: Bool
    public var install: [ReleaseManifest.RuntimeAsset]
    public var current: [ReleaseManifest.RuntimeAsset]

    public var isUpToDate: Bool { install.isEmpty }

    /// `wine crossover-26.3.0-wow64, dxmt 0.80`.
    public static func describe(_ assets: [ReleaseManifest.RuntimeAsset]) -> String {
        assets.map { "\($0.kind) \($0.version)" }.joined(separator: ", ")
    }
}

// MARK: updater

/// Fetches the manifest and release files, verifies them and installs them.
public struct Updater {
    public let paths: MGPaths
    public let source: UpdateSource
    public var currentVersion: String
    /// (url, destination). Defaults to `Downloader.download`.
    public var download: (URL, URL) throws -> Void

    public init(paths: MGPaths, source: UpdateSource, currentVersion: String = MGVersion.string,
                download: @escaping (URL, URL) throws -> Void = { try Downloader.download($0, to: $1, quiet: true) }) {
        self.paths = paths
        self.source = source
        self.currentVersion = currentVersion
        self.download = download
    }

    /// Source from `MG_UPDATE_URL` / config.json.
    public static func standard(paths: MGPaths, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Updater {
        Updater(paths: paths, source: try UpdateSource.resolve(environment: environment, config: GlobalConfig.load(paths)))
    }

    public var cache: UpdateCache { UpdateCache(paths: paths) }

    /// Downloads, validates and caches the latest manifest.
    @discardableResult
    public func fetchManifest() throws -> ReleaseManifest {
        let dest = cache.directory.appendingPathComponent("manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dest) }
        do {
            try download(source.manifestURL, dest)
        } catch let e as MGError {
            throw MGError.update("cannot download the release manifest from \(source): \(e.description)")
        }
        let data: Data
        do { data = try Data(contentsOf: dest) } catch { throw MGError.update("cannot read the release manifest: \(error.localizedDescription)") }
        let m = try ReleaseManifest.decode(data)
        try cache.save(m, source: source)
        return m
    }

    /// The release is newer than this build.
    public func isNewer(_ m: ReleaseManifest) -> Bool {
        guard let theirs = m.semver, let ours = SemVer(currentVersion) else { return false }
        return theirs > ours
    }

    /// Downloads one release file into the cache (or reuses a cached copy that still verifies) and checks its
    /// SHA-256. A file that does not match is deleted and never returned.
    public func fetch(_ asset: ReleaseManifest.Asset, version: String, log: (String) -> Void = { _ in }) throws -> URL {
        guard ReleaseManifest.isSafeFileName(asset.file) else { throw MGError.update("unsafe file name '\(asset.file)'") }
        let dest = cache.downloads(version: version).appendingPathComponent(asset.file)
        if FileManager.default.fileExists(atPath: dest.path) {
            if (try? Checksum.sha256(of: dest)) == asset.sha256.lowercased() {
                log("using cached \(asset.file)")
                return dest
            }
            try? FileManager.default.removeItem(at: dest)
        }
        let url = source.assetURL(asset.file, version: version)
        log("downloading \(url.isFileURL ? url.path : url.absoluteString)")
        try download(url, dest)
        log("verifying \(asset.file)")
        try Checksum.verify(dest, sha256: asset.sha256)
        return dest
    }

    // MARK: runtime

    /// Compares the release's runtime files with what is installed. A component counts as installed when
    /// the target runtime has it on disk and its runtime.json records the same archive (or version).
    public func planRuntimeUpdate(_ m: ReleaseManifest) throws -> RuntimeUpdatePlan {
        let assets = m.runtimeComponents
        guard !assets.isEmpty else { throw MGError.update("release \(m.version) has no runtime files") }
        let store = RuntimeStore(paths: paths)
        let name: String
        if let wine = assets.first(where: { $0.component == .wine }) {
            name = (RuntimeComponent.version(fromArchive: wine.file) ?? "default").replacingOccurrences(of: " ", with: "-")
            try Names.validate(name)
        } else {
            name = try store.resolve(nil, config: GlobalConfig.load(paths)).name
        }
        let existing = try? store.get(name)
        let components = existing?.manifest().components ?? [:]
        var plan = RuntimeUpdatePlan(runtime: name, isNewRuntime: existing == nil, install: [], current: [])
        for a in assets {
            let onDisk: Bool
            switch a.component {
            case .wine?: onDisk = existing?.hasWine == true
            case .dxmt?: onDisk = existing?.hasDXMT == true
            case .dxvk?: onDisk = existing?.hasDXVK == true
            case nil: continue
            }
            if onDisk, let c = components[a.kind], c.archive == a.file || c.version == a.version {
                plan.current.append(a)
            } else {
                plan.install.append(a)
            }
        }
        return plan
    }

    /// Downloads, verifies and installs the plan's files in one `RuntimeStore.install`, so a failure leaves
    /// the runtime as it was. A new runtime becomes the default. Downloaded archives are deleted afterwards.
    @discardableResult
    public func updateRuntime(_ m: ReleaseManifest, plan: RuntimeUpdatePlan,
                              log: (String) -> Void = { _ in }) throws -> RuntimeInstallReport? {
        guard !plan.install.isEmpty else { return nil }
        var files: [URL] = []
        for a in plan.install { files.append(try fetch(a.asset, version: m.version, log: log)) }
        let report = try RuntimeStore(paths: paths).install(sources: files, name: plan.runtime,
                                                           makeDefault: plan.isNewRuntime, log: log)
        for f in files { try? FileManager.default.removeItem(at: f) }
        return report
    }

    // MARK: mgx

    /// Replaces the `mgx` binary at `binary` with the release's, atomically (rename in the same folder).
    /// The new binary must run and report the release's version first.
    public func installCLI(_ m: ReleaseManifest, replacing binary: URL, log: (String) -> Void = { _ in }) throws {
        guard let asset = m.mgx else { throw MGError.update("release \(m.version) has no mgx binary") }
        let fm = FileManager.default
        let target = binary.resolvingSymlinksInPath()
        let dir = target.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: dir.path) else {
            throw MGError.update("cannot replace \(target.path): \(dir.path) is not writable. Move mgx to a folder you own (for example ~/bin) or run the update with sudo")
        }
        let tarball = try fetch(asset, version: m.version, log: log)
        let work = cache.downloads(version: m.version).appendingPathComponent("mgx-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try Archive.untar(tarball, into: work)
        let candidates = [work.appendingPathComponent("mgx")]
            + ((try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []).map { $0.appendingPathComponent("mgx") }
        guard let new = candidates.first(where: { Self.isRegularFile($0) }) else {
            throw MGError.update("\(asset.file) does not contain an mgx binary")
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: new.path)
        try Self.checkReportsVersion(new, m.version)

        // Copy next to the target first: rename(2) is atomic only within one file system.
        let staged = dir.appendingPathComponent(".mgx-update-\(UUID().uuidString)")
        try fm.copyItem(at: new, to: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        guard rename(staged.path, target.path) == 0 else {
            let err = String(cString: strerror(errno))
            try? fm.removeItem(at: staged)
            throw MGError.update("cannot replace \(target.path): \(err)")
        }
        log("replaced \(target.path)")
    }

    /// Runs `binary --version` and checks it prints `version`. Catches a broken download or a release whose
    /// binary was built with the wrong version string (which would otherwise "update" forever).
    static func checkReportsVersion(_ binary: URL, _ version: String) throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mgx-version-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let code = try Subprocess.run(binary, ["--version"], environment: ProcessInfo.processInfo.environment, output: .file(out))
        let printed = ((try? String(contentsOf: out, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0 else { throw MGError.update("the new mgx does not run (exit code \(code)): \(printed.prefix(200))") }
        guard let got = SemVer(printed.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""), got == SemVer(version) else {
            throw MGError.update("the new mgx reports version '\(printed.prefix(80))', expected \(version); not installed")
        }
    }

    static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    // MARK: doctor

    /// What `mgx doctor` says about updates, from the cached manifest only (no network).
    public static func doctorChecks(paths: MGPaths, currentVersion: String = MGVersion.string) -> [DoctorCheck] {
        let cache = UpdateCache(paths: paths)
        guard let entry = cache.load() else { return [] }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let checked = "release \(entry.manifest.version), checked \(f.string(from: entry.fetched))"
        let u = Updater(paths: paths, source: .default, currentVersion: currentVersion)
        var out: [DoctorCheck] = []
        if u.isNewer(entry.manifest) {
            out.append(.init(.warning, "Mac Gaming \(entry.manifest.version) is available (this is \(currentVersion))",
                             "run `mgx self-update`, or Check for Updates… in the app (\(checked))"))
        }
        if let plan = try? u.planRuntimeUpdate(entry.manifest), !plan.isUpToDate {
            let what = RuntimeUpdatePlan.describe(plan.install)
            out.append(.init(.warning, plan.isNewRuntime ? "runtime \(plan.runtime) is available" : "runtime update available: \(what)",
                             "run `mgx runtime update` (\(plan.isNewRuntime ? what + ", " : "")\(checked))"))
        }
        if out.isEmpty { out.append(.init(.ok, "up to date", checked)) }
        return out
    }
}
