import XCTest
@testable import MGCore

final class UpdatesTests: XCTestCase {
    // MARK: manifest

    static let sample = """
    {"version":"0.2.0","published":"2026-11-28T12:00:00Z",
     "app":{"file":"MacGaming-0.2.0.zip","sha256":"\(String(repeating: "a", count: 64))"},
     "mgx":{"file":"mgx-0.2.0-macos-arm64.tar.gz","sha256":"\(String(repeating: "B", count: 64))"},
     "runtime":[
       {"kind":"dxvk","file":"dxvk-macos-1.10.3-20230507-repack.tar.xz","version":"1.10.3-20230507-repack","sha256":"\(String(repeating: "c", count: 64))"},
       {"kind":"wine","file":"wine-crossover-26.3.0-wow64.tar.xz","version":"crossover-26.3.0-wow64","sha256":"\(String(repeating: "d", count: 64))"},
       {"kind":"metalfx","file":"metalfx-1.tar.xz","version":"1","sha256":"\(String(repeating: "e", count: 64))"},
       {"kind":"dxmt","file":"dxmt-0.80.tar.xz","version":"0.80","sha256":"\(String(repeating: "f", count: 64)) ","extra":true}
     ],
     "notes":"ignored"}
    """

    func testDecodeManifest() throws {
        let m = try ReleaseManifest.decode(Data(Self.sample.replacingOccurrences(of: " \",\"extra\"", with: "\",\"extra\"").utf8))
        XCTAssertEqual(m.version, "0.2.0")
        XCTAssertEqual(m.semver, SemVer(major: 0, minor: 2, patch: 0))
        XCTAssertEqual(m.published, "2026-11-28T12:00:00Z")
        XCTAssertEqual(m.app?.file, "MacGaming-0.2.0.zip")
        XCTAssertEqual(m.mgx?.file, "mgx-0.2.0-macos-arm64.tar.gz")
        XCTAssertEqual(m.runtime.count, 4)
        // Known kinds only, in install order; an unknown kind from a newer release is skipped.
        XCTAssertEqual(m.runtimeComponents.map(\.kind), ["wine", "dxmt", "dxvk"])
        XCTAssertEqual(m.runtimeComponents[0].version, "crossover-26.3.0-wow64")

        let minimal = try ReleaseManifest.decode(Data(#"{"version":"1.0.0"}"#.utf8))
        XCTAssertEqual(minimal.runtime, [])
        XCTAssertNil(minimal.app)
    }

    func testRejectInvalidManifests() {
        let sha = String(repeating: "0", count: 64)
        func rejects(_ json: String, _ needle: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try ReleaseManifest.decode(Data(json.utf8)), file: file, line: line) { e in
                guard case MGError.update(let msg) = e else { return XCTFail("\(e)", file: file, line: line) }
                XCTAssertTrue(msg.contains(needle), msg, file: file, line: line)
            }
        }
        rejects("not json", "not valid")
        rejects(#"{"runtime":[]}"#, "missing \"version\"")
        rejects(#"{"version":"latest"}"#, "invalid version")
        rejects(#"{"version":"1.0.0","mgx":{"file":"../../bin/mgx","sha256":"\#(sha)"}}"#, "unsafe file")
        rejects(#"{"version":"1.0.0","mgx":{"file":"a/b.tar.gz","sha256":"\#(sha)"}}"#, "unsafe file")
        rejects(#"{"version":"1.0.0","mgx":{"file":".hidden","sha256":"\#(sha)"}}"#, "unsafe file")
        rejects(#"{"version":"1.0.0","mgx":{"file":"mgx.tar.gz","sha256":"abc"}}"#, "invalid sha256")
        rejects(#"{"version":"1.0.0","runtime":[{"kind":"wine","file":"a.tar.xz","version":"1","sha256":"\#(sha)"},{"kind":"wine","file":"b.tar.xz","version":"2","sha256":"\#(sha)"}]}"#, "more than one wine")
        // The sample's dxmt sha has a trailing space.
        rejects(Self.sample, "invalid sha256 for dxmt-0.80.tar.xz")
    }

    // MARK: versions

    func testSemVerParsing() {
        XCTAssertEqual(SemVer("v1.2.3"), SemVer(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemVer("1.2"), SemVer(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(SemVer("1.2.3+build.5"), SemVer(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemVer("1.2.3-beta.1")?.prerelease, ["beta", "1"])
        XCTAssertEqual(SemVer(" 0.1.0\n")?.description, "0.1.0")
        XCTAssertEqual(SemVer("1.0.0-rc.1")?.description, "1.0.0-rc.1")
        for bad in ["", "x", "1.2.3.4", "1..2", "1.2.a", "1.2.3-", "1.2.3-a..b", "-1.0.0"] {
            XCTAssertNil(SemVer(bad), bad)
        }
        XCTAssertNotNil(SemVer(MGVersion.string), "mgx --version must be a semver")
    }

    func testSemVerOrdering() {
        let ordered = ["0.1.0", "0.1.1", "0.2.0", "0.10.0", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta",
                       "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "2.0.0", "10.0.0"]
        let v = ordered.map { SemVer($0)! }
        for i in 0..<v.count - 1 {
            XCTAssertLessThan(v[i], v[i + 1], "\(ordered[i]) < \(ordered[i + 1])")
            XCTAssertFalse(v[i + 1] < v[i])
        }
        XCTAssertEqual(v.shuffled().sorted(), v)
        XCTAssertFalse(SemVer("1.0.0")! < SemVer("v1.0.0")!)
    }

    func testIsNewer() throws {
        let sb = try Sandbox()
        let u = Updater(paths: sb.paths, source: .default, currentVersion: "0.1.0")
        XCTAssertTrue(u.isNewer(ReleaseManifest(version: "0.1.1")))
        XCTAssertTrue(u.isNewer(ReleaseManifest(version: "v0.2.0")))
        XCTAssertFalse(u.isNewer(ReleaseManifest(version: "0.1.0")))
        XCTAssertFalse(u.isNewer(ReleaseManifest(version: "0.1.0-rc.1")))
        XCTAssertFalse(u.isNewer(ReleaseManifest(version: "0.0.9")))
        XCTAssertFalse(u.isNewer(ReleaseManifest(version: "garbage")))
    }

    // MARK: sources and URLs

    func testDefaultSourceURLs() {
        let s = UpdateSource.default
        XCTAssertEqual(s.manifestURL.absoluteString, "https://github.com/wezn/mac-gaming/releases/latest/download/manifest.json")
        XCTAssertEqual(s.assetURL("mgx-0.2.0-macos-arm64.tar.gz", version: "0.2.0").absoluteString,
                       "https://github.com/wezn/mac-gaming/releases/download/v0.2.0/mgx-0.2.0-macos-arm64.tar.gz")
        XCTAssertEqual(s.assetURL("MacGaming-1.0.0.zip", version: "v1.0.0").absoluteString,
                       "https://github.com/wezn/mac-gaming/releases/download/v1.0.0/MacGaming-1.0.0.zip")
    }

    func testCustomSources() throws {
        // A fork's releases keep the GitHub layout.
        let fork = try UpdateSource(string: "https://github.com/someone/mac-gaming/releases/latest/download/")
        XCTAssertEqual(fork.layout, .githubReleases("someone/mac-gaming"))
        XCTAssertEqual(fork.assetURL("a.zip", version: "1.0.0").absoluteString,
                       "https://github.com/someone/mac-gaming/releases/download/v1.0.0/a.zip")

        let flat = try UpdateSource(string: "https://example.com/mg/stable/manifest.json")
        XCTAssertEqual(flat.layout, .flat)
        XCTAssertEqual(flat.assetURL("a.zip", version: "1.0.0").absoluteString, "https://example.com/mg/stable/a.zip")

        let dir = try UpdateSource(string: "https://example.com/mg")
        XCTAssertEqual(dir.manifestURL.absoluteString, "https://example.com/mg/manifest.json")

        let local = try UpdateSource(string: "http://127.0.0.1:8765/")
        XCTAssertEqual(local.manifestURL.absoluteString, "http://127.0.0.1:8765/manifest.json")
        XCTAssertEqual(local.assetURL("x.tar.xz", version: "1.0.0").absoluteString, "http://127.0.0.1:8765/x.tar.xz")
        XCTAssertNoThrow(try UpdateSource(string: "http://localhost:9/m.json"))

        let path = try UpdateSource(string: "/tmp/release")
        XCTAssertTrue(path.manifestURL.isFileURL)
        XCTAssertEqual(path.manifestURL.path, "/tmp/release/manifest.json")
        XCTAssertEqual(path.assetURL("x.tar.xz", version: "1").path, "/tmp/release/x.tar.xz")
        XCTAssertEqual(try UpdateSource(string: "file:///tmp/r/manifest.json").assetURL("y", version: "1").path, "/tmp/r/y")

        for bad in ["", "http://example.com/manifest.json", "ftp://example.com/m.json", "https://"] {
            XCTAssertThrowsError(try UpdateSource(string: bad), bad)
        }
    }

    func testSourcePrecedence() throws {
        let config = GlobalConfig(updateURL: "https://example.com/config/")
        XCTAssertEqual(try UpdateSource.resolve(environment: [:], config: GlobalConfig()), .default)
        XCTAssertEqual(try UpdateSource.resolve(environment: [:], config: config).manifestURL.absoluteString,
                       "https://example.com/config/manifest.json")
        XCTAssertEqual(try UpdateSource.resolve(environment: ["MG_UPDATE_URL": "https://example.com/env/"], config: config).manifestURL.absoluteString,
                       "https://example.com/env/manifest.json")
        XCTAssertEqual(try UpdateSource.resolve(environment: ["MG_UPDATE_URL": ""], config: GlobalConfig()), .default)
    }

    func testSetUpdateURLValidates() throws {
        let sb = try Sandbox()
        let l = Launcher(paths: sb.paths)
        XCTAssertThrowsError(try l.setUpdateURL("http://example.com/"))
        try l.setUpdateURL("https://example.com/r/")
        XCTAssertEqual(try GlobalConfig.load(sb.paths).updateURL, "https://example.com/r/")
        try l.setUpdateURL(nil)
        XCTAssertNil(try GlobalConfig.load(sb.paths).updateURL)
    }

    func testDownloaderProtocols() throws {
        XCTAssertEqual(try Downloader.allowedProtocols(URL(string: "https://example.com/a")!), "=https")
        XCTAssertEqual(try Downloader.allowedProtocols(URL(string: "http://127.0.0.1:8000/a")!), "=http,https")
        XCTAssertThrowsError(try Downloader.allowedProtocols(URL(string: "http://example.com/a")!))
        XCTAssertThrowsError(try Downloader.allowedProtocols(URL(string: "http://127.0.0.1.example.com/a")!))
        XCTAssertThrowsError(try Downloader.download(URL(string: "ftp://example.com/a")!, to: URL(fileURLWithPath: "/tmp/never-\(UUID())")))
        let headers = "HTTP/2 302\r\ncontent-length: 0\r\nlocation: x\r\n\r\nHTTP/2 200\r\nContent-Length: 12345\r\n\r\n"
        XCTAssertEqual(Downloader.parseContentLength(headers: headers), 12345)
        XCTAssertNil(Downloader.parseContentLength(headers: "HTTP/2 200\r\n\r\n"))
    }

    // MARK: checksums and fetching

    func testSHA256() throws {
        let sb = try Sandbox()
        try sb.write("abc.txt", "abc")
        XCTAssertEqual(try Checksum.sha256(of: sb.root.appendingPathComponent("abc.txt")),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try sb.write("empty", "")
        XCTAssertEqual(try Checksum.sha256(of: sb.root.appendingPathComponent("empty")),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// A release folder served as file:// with the given files.
    private func release(_ sb: Sandbox, _ files: [URL]) throws -> UpdateSource {
        let dir = sb.root.appendingPathComponent("release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files { try FileManager.default.copyItem(at: f, to: dir.appendingPathComponent(f.lastPathComponent)) }
        return try UpdateSource(string: dir.path)
    }

    private func asset(_ url: URL) throws -> ReleaseManifest.Asset {
        ReleaseManifest.Asset(file: url.lastPathComponent, sha256: try Checksum.sha256(of: url))
    }

    func testFetchRejectsChecksumMismatch() throws {
        let sb = try Sandbox()
        try sb.write("payload.tar.gz", "the real thing")
        let src = try release(sb, [sb.root.appendingPathComponent("payload.tar.gz")])
        let u = Updater(paths: sb.paths, source: src)
        let wrong = ReleaseManifest.Asset(file: "payload.tar.gz", sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try u.fetch(wrong, version: "1.0.0")) { e in
            guard case MGError.update(let msg) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(msg.contains("failed verification"), msg)
        }
        let cached = u.cache.downloads(version: "1.0.0").appendingPathComponent("payload.tar.gz")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path), "a file that fails verification is deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.appendingPathExtension("part").path))

        let good = try u.fetch(try asset(sb.root.appendingPathComponent("payload.tar.gz")), version: "1.0.0")
        XCTAssertEqual(good, cached)
        XCTAssertEqual(sb.read(good), "the real thing")
    }

    func testFetchReusesVerifiedCacheAndReplacesTamperedCopy() throws {
        let sb = try Sandbox()
        try sb.write("f.bin", "content")
        let src = try release(sb, [sb.root.appendingPathComponent("f.bin")])
        var downloads = 0
        let u = Updater(paths: sb.paths, source: src, download: { downloads += 1; try Downloader.download($0, to: $1, quiet: true) })
        let a = try asset(sb.root.appendingPathComponent("f.bin"))
        let first = try u.fetch(a, version: "1.0.0")
        _ = try u.fetch(a, version: "1.0.0")
        XCTAssertEqual(downloads, 1)
        try Data("tampered".utf8).write(to: first)
        _ = try u.fetch(a, version: "1.0.0")
        XCTAssertEqual(downloads, 2)
        XCTAssertEqual(sb.read(first), "content")
    }

    func testFetchManifestCachesIt() throws {
        let sb = try Sandbox()
        try sb.write("manifest.json", #"{"version":"3.0.0","runtime":[]}"#)
        let src = try release(sb, [sb.root.appendingPathComponent("manifest.json")])
        let u = Updater(paths: sb.paths, source: src)
        XCTAssertEqual(try u.fetchManifest().version, "3.0.0")
        XCTAssertEqual(u.cache.load()?.manifest.version, "3.0.0")
        XCTAssertEqual(u.cache.load()?.source, src.description)

        let missing = Updater(paths: sb.paths, source: try UpdateSource(string: sb.root.appendingPathComponent("nowhere").path))
        XCTAssertThrowsError(try missing.fetchManifest()) { e in
            guard case MGError.update(let msg) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(msg.contains("cannot download the release manifest"), msg)
        }
    }

    // MARK: runtime update

    private func runtimeManifest(_ files: [(String, URL, String)], version: String = "1.0.0") throws -> ReleaseManifest {
        ReleaseManifest(version: version, runtime: try files.map { kind, url, v in
            ReleaseManifest.RuntimeAsset(kind: kind, file: url.lastPathComponent, version: v, sha256: try Checksum.sha256(of: url))
        })
    }

    func testRuntimeUpdateInstallsThenSkipsInstalled() throws {
        let sb = try Sandbox()
        let a = try sb.makeArchives()
        let src = try release(sb, [a.wine, a.dxmt, a.dxvk])
        var fetched: [String] = []
        let u = Updater(paths: sb.paths, source: src, download: {
            fetched.append($0.lastPathComponent)
            try Downloader.download($0, to: $1, quiet: true)
        })
        let m = try runtimeManifest([("wine", a.wine, "crossover-26.3.0-wow64"), ("dxmt", a.dxmt, "0.61"), ("dxvk", a.dxvk, "1.10.3")])

        let plan = try u.planRuntimeUpdate(m)
        XCTAssertEqual(plan.runtime, "crossover-26.3.0-wow64")
        XCTAssertTrue(plan.isNewRuntime)
        XCTAssertEqual(plan.install.map(\.kind), ["wine", "dxmt", "dxvk"])
        let report = try XCTUnwrap(try u.updateRuntime(m, plan: plan))
        XCTAssertEqual(report.runtime, "crossover-26.3.0-wow64")
        XCTAssertTrue(report.madeDefault)
        XCTAssertEqual(fetched.sorted(), [a.dxmt, a.dxvk, a.wine].map(\.lastPathComponent).sorted())
        let rt = try RuntimeStore(paths: sb.paths).get("crossover-26.3.0-wow64")
        XCTAssertTrue(rt.hasWine && rt.hasDXMT && rt.hasDXVK)
        XCTAssertEqual(rt.manifest().components["dxmt"]?.archive, a.dxmt.lastPathComponent)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: u.cache.downloads(version: "1.0.0").path), [],
                       "downloaded archives are removed after install")

        // Same release again: nothing to do, nothing downloaded.
        fetched = []
        let again = try u.planRuntimeUpdate(m)
        XCTAssertTrue(again.isUpToDate)
        XCTAssertFalse(again.isNewRuntime)
        XCTAssertEqual(again.current.map(\.kind), ["wine", "dxmt", "dxvk"])
        XCTAssertNil(try u.updateRuntime(m, plan: again))
        XCTAssertEqual(fetched, [])

        // A release with only a newer DXMT installs just that, into the same runtime.
        let s = sb.root.appendingPathComponent("pack-dxmt", isDirectory: true)
        try sb.makeDXMTTree(at: s.appendingPathComponent("dxmt"))
        try sb.write("dxmt/x86_64-windows/d3d11.dll", "dxmt-0.62", in: s)
        let dxmt2 = try sb.tar(s, "dxmt", as: "dxmt-0.62.tar.xz")
        let src2 = try release(sb, [a.wine, dxmt2, a.dxvk])
        let u2 = Updater(paths: sb.paths, source: src2, download: {
            fetched.append($0.lastPathComponent)
            try Downloader.download($0, to: $1, quiet: true)
        })
        let m2 = try runtimeManifest([("wine", a.wine, "crossover-26.3.0-wow64"), ("dxmt", dxmt2, "0.62"), ("dxvk", a.dxvk, "1.10.3")], version: "1.1.0")
        let plan2 = try u2.planRuntimeUpdate(m2)
        XCTAssertEqual(plan2.install.map(\.kind), ["dxmt"])
        XCTAssertEqual(plan2.current.map(\.kind), ["wine", "dxvk"])
        let r2 = try XCTUnwrap(try u2.updateRuntime(m2, plan: plan2))
        XCTAssertEqual(r2.installed.keys.sorted(), ["dxmt"])
        XCTAssertEqual(fetched, ["dxmt-0.62.tar.xz"])

        // The recorded version alone is enough (release-manifest.py spells it like runtime.json does).
        var renamed = m2
        renamed.runtime[2].file = "dxvk-macos-1.10.3-renamed.tar.xz"
        XCTAssertEqual(try u2.planRuntimeUpdate(renamed).install, [])
        XCTAssertEqual(sb.read(rt.dxmtRoot.appendingPathComponent("x86_64-windows/d3d11.dll")), "dxmt-0.62")
        XCTAssertTrue(BackendFiles.isDXMTOverlayCurrent(rt), "the DXMT overlay is rebuilt")
    }

    func testRuntimeUpdateRefusesBadChecksumAndInstallsNothing() throws {
        let sb = try Sandbox()
        let a = try sb.makeArchives()
        let src = try release(sb, [a.wine, a.dxmt, a.dxvk])
        let u = Updater(paths: sb.paths, source: src)
        var m = try runtimeManifest([("wine", a.wine, "crossover-26.3.0-wow64"), ("dxmt", a.dxmt, "0.61"), ("dxvk", a.dxvk, "1.10.3")])
        m.runtime[2].sha256 = String(repeating: "1", count: 64)
        XCTAssertThrowsError(try u.updateRuntime(m, plan: try u.planRuntimeUpdate(m)))
        XCTAssertEqual(RuntimeStore(paths: sb.paths).list(), [], "nothing is installed when any file fails verification")
        XCTAssertNil(try GlobalConfig.load(sb.paths).defaultRuntime)
    }

    func testRuntimeUpdateWithoutWineNeedsARuntime() throws {
        let sb = try Sandbox()
        let a = try sb.makeArchives()
        let u = Updater(paths: sb.paths, source: try release(sb, [a.dxvk]))
        let m = try runtimeManifest([("dxvk", a.dxvk, "1.10.3")])
        XCTAssertThrowsError(try u.planRuntimeUpdate(m)) { XCTAssertEqual($0 as? MGError, .noRuntime) }
        XCTAssertThrowsError(try u.planRuntimeUpdate(ReleaseManifest(version: "1.0.0")))

        try RuntimeStore(paths: sb.paths).install(sources: [a.wine], name: "mine")
        let plan = try u.planRuntimeUpdate(m)
        XCTAssertEqual(plan.runtime, "mine")
        XCTAssertEqual(plan.install.map(\.kind), ["dxvk"])
    }

    // MARK: doctor

    func testDoctorReportsCachedUpdates() throws {
        let sb = try Sandbox()
        XCTAssertEqual(Updater.doctorChecks(paths: sb.paths), [], "no cached manifest: nothing, and no network")

        let a = try sb.makeArchives()
        let m = try runtimeManifest([("wine", a.wine, "crossover-26.3.0-wow64")], version: "9.0.0")
        try UpdateCache(paths: sb.paths).save(m, source: .default)
        var checks = Updater.doctorChecks(paths: sb.paths, currentVersion: "0.1.0")
        XCTAssertEqual(checks.map(\.status), [.warning, .warning])
        XCTAssertTrue(checks[0].title.contains("9.0.0 is available"), checks[0].title)
        XCTAssertTrue(checks[0].detail.contains("mgx self-update"))
        XCTAssertTrue(checks[1].title.contains("runtime crossover-26.3.0-wow64 is available"), checks[1].title)
        XCTAssertTrue(checks[1].detail.contains("mgx runtime update"))

        try RuntimeStore(paths: sb.paths).install(sources: [a.wine])
        checks = Updater.doctorChecks(paths: sb.paths, currentVersion: "9.0.0")
        XCTAssertEqual(checks.map(\.status), [.ok])

        var doctor = Doctor(paths: sb.paths)
        doctor.rosettaInstalled = { nil }
        doctor.currentVersion = "0.1.0"
        XCTAssertTrue(doctor.run().contains { $0.title.contains("9.0.0 is available") })
    }

    // MARK: self-update (mgx)

    private func fakeMGX(_ sb: Sandbox, printing version: String, name: String) throws -> URL {
        let s = sb.root.appendingPathComponent("mgx-pack-\(UUID().uuidString)", isDirectory: true)
        try sb.write("mgx", "#!/bin/sh\necho \(version)\n", executable: true, in: s)
        return try sb.tar(s, "mgx", as: name)
    }

    func testInstallCLIReplacesBinary() throws {
        let sb = try Sandbox()
        try sb.write("bin/mgx", "#!/bin/sh\necho 0.1.0\n", executable: true)
        let installed = sb.root.appendingPathComponent("bin/mgx")
        let tarball = try fakeMGX(sb, printing: "0.2.0", name: "mgx-0.2.0-macos-arm64.tar.gz")
        let u = Updater(paths: sb.paths, source: try release(sb, [tarball]))
        try u.installCLI(ReleaseManifest(version: "0.2.0", mgx: try asset(tarball)), replacing: installed)
        XCTAssertEqual(sb.read(installed), "#!/bin/sh\necho 0.2.0\n")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path), ["mgx"],
                       "no staging files left next to the binary")
    }

    func testInstallCLIRefusesBadBinaries() throws {
        let sb = try Sandbox()
        let original = "#!/bin/sh\necho 0.1.0\n"
        try sb.write("bin/mgx", original, executable: true)
        let installed = sb.root.appendingPathComponent("bin/mgx")

        // Reports another version than the release claims.
        let wrong = try fakeMGX(sb, printing: "0.1.5", name: "mgx-0.2.0-macos-arm64.tar.gz")
        let u = Updater(paths: sb.paths, source: try release(sb, [wrong]))
        XCTAssertThrowsError(try u.installCLI(ReleaseManifest(version: "0.2.0", mgx: try asset(wrong)), replacing: installed)) { e in
            XCTAssertTrue("\(e)".contains("expected 0.2.0"), "\(e)")
        }
        // Checksum mismatch.
        let bad = ReleaseManifest.Asset(file: wrong.lastPathComponent, sha256: String(repeating: "9", count: 64))
        XCTAssertThrowsError(try u.installCLI(ReleaseManifest(version: "0.2.0", mgx: bad), replacing: installed))
        // No mgx in the release.
        XCTAssertThrowsError(try u.installCLI(ReleaseManifest(version: "0.2.0"), replacing: installed))
        XCTAssertEqual(sb.read(installed), original, "the installed binary is untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.deletingLastPathComponent().path), ["mgx"])
    }

    #if os(macOS)
    // MARK: app bundle (macOS)

    /// An ad-hoc signed bundle whose executable is a copy of /usr/bin/true.
    private func makeApp(_ sb: Sandbox, at dir: URL, version: String, id: String = "io.github.wezn.mac-gaming") throws -> URL {
        let app = dir.appendingPathComponent("MacGaming.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/MacGaming").path)
        let plist: [String: Any] = ["CFBundleExecutable": "MacGaming", "CFBundleIdentifier": id, "CFBundlePackageType": "APPL",
                                    "CFBundleShortVersionString": version, "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(try Subprocess.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", app.path],
                                          environment: [:], output: .null), 0)
        return app
    }

    private func zip(_ app: URL, as name: String, in sb: Sandbox) throws -> URL {
        let out = sb.root.appendingPathComponent(name)
        XCTAssertEqual(try Subprocess.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", app.path, out.path],
                                          environment: [:], output: .null), 0)
        return out
    }

    private func bundleVersion(of app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleShortVersionString"] as? String
    }

    func testAppUpdateSwapsBundle() throws {
        let sb = try Sandbox()
        let installedDir = sb.root.appendingPathComponent("Applications", isDirectory: true)
        let installed = try makeApp(sb, at: installedDir, version: "0.1.0")
        let newApp = try makeApp(sb, at: sb.root.appendingPathComponent("build", isDirectory: true), version: "0.2.0")
        let z = try zip(newApp, as: "MacGaming-0.2.0.zip", in: sb)
        let u = Updater(paths: sb.paths, source: try release(sb, [z]))
        try u.installApp(ReleaseManifest(version: "0.2.0", app: try asset(z)), replacing: installed,
                         bundleIdentifier: "io.github.wezn.mac-gaming")
        XCTAssertEqual(bundleVersion(of: installed), "0.2.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installedDir.path), ["MacGaming.app"])
        XCTAssertEqual(try Subprocess.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", installed.path],
                                          environment: [:], output: .null), 0)
    }

    func testAppUpdateRefusesBadBundles() throws {
        let sb = try Sandbox()
        let installed = try makeApp(sb, at: sb.root.appendingPathComponent("Applications", isDirectory: true), version: "0.1.0")
        func attempt(_ app: URL, release version: String, sha: String? = nil, needle: String) throws {
            let z = try zip(app, as: "MacGaming-\(version)-\(UUID().uuidString).zip", in: sb)
            var a = try asset(z)
            if let sha { a.sha256 = sha }
            let u = Updater(paths: sb.paths, source: try release(sb, [z]))
            XCTAssertThrowsError(try u.installApp(ReleaseManifest(version: version, app: a), replacing: installed,
                                                  bundleIdentifier: "io.github.wezn.mac-gaming")) { e in
                XCTAssertTrue("\(e)".contains(needle), "\(e)")
            }
            XCTAssertEqual(bundleVersion(of: installed), "0.1.0", "the installed app is untouched")
        }
        let build = { sb.root.appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true) }
        try attempt(try makeApp(sb, at: build(), version: "0.2.0"), release: "0.2.0", sha: String(repeating: "0", count: 64), needle: "failed verification")
        try attempt(try makeApp(sb, at: build(), version: "0.1.9"), release: "0.2.0", needle: "is version '0.1.9'")
        try attempt(try makeApp(sb, at: build(), version: "0.2.0", id: "com.example.other"), release: "0.2.0", needle: "bundle identifier")
        // Modified after signing.
        let tampered = try makeApp(sb, at: build(), version: "0.2.0")
        try Data("changed".utf8).write(to: tampered.appendingPathComponent("Contents/MacOS/MacGaming"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tampered.appendingPathComponent("Contents/MacOS/MacGaming").path)
        try attempt(tampered, release: "0.2.0", needle: "code signature")
    }

    func testAppUpdateNeedsAWritableLocation() throws {
        XCTAssertThrowsError(try AppBundleUpdate.checkReplaceable(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/MacGaming.app"))) {
            XCTAssertTrue("\($0)".contains("Applications folder"), "\($0)")
        }
        let sb = try Sandbox()
        let dir = sb.root.appendingPathComponent("ro", isDirectory: true)
        let app = try makeApp(sb, at: dir, version: "0.1.0")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        XCTAssertThrowsError(try AppBundleUpdate.checkReplaceable(app)) { XCTAssertTrue("\($0)".contains("not writable"), "\($0)") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertNoThrow(try AppBundleUpdate.checkReplaceable(app))
    }
    #endif
}
