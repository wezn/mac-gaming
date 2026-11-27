import XCTest
@testable import MGCore

final class RuntimeTests: XCTestCase {
    func testVersionFromArchiveName() {
        XCTAssertEqual(RuntimeComponent.version(fromArchive: "wine-crossover-26.3.0-wow64.tar.xz"), "crossover-26.3.0-wow64")
        XCTAssertEqual(RuntimeComponent.version(fromArchive: "dxmt-0.61.tar.xz"), "0.61")
        XCTAssertEqual(RuntimeComponent.version(fromArchive: "dxvk-macos-1.10.3-20230507.tar.gz"), "1.10.3-20230507")
        // Names build-graphics.yml produces.
        XCTAssertEqual(RuntimeComponent.version(fromArchive: "dxmt-0.80.tar.xz"), "0.80")
        XCTAssertEqual(RuntimeComponent.version(fromArchive: "dxvk-macos-1.10.3-20230507-repack.tar.xz"), "1.10.3-20230507-repack")
        XCTAssertNil(RuntimeComponent.version(fromArchive: "random.tar.xz"))
    }

    func testInstallAllArchives() throws {
        let sb = try Sandbox()
        let a = try sb.makeArchives()
        let store = RuntimeStore(paths: sb.paths)
        let r = try store.install(sources: [a.wine, a.dxmt, a.dxvk])
        XCTAssertEqual(r.runtime, "crossover-26.3.0-wow64")
        XCTAssertEqual(Set(r.installed.keys), ["wine", "dxmt", "dxvk"])
        XCTAssertTrue(r.madeDefault)

        let rt = try store.get(r.runtime)
        XCTAssertTrue(rt.hasWine)
        XCTAssertTrue(rt.hasDXMT)
        XCTAssertTrue(rt.hasDXVK)
        XCTAssertFalse(rt.dxvkHasD3D8)
        XCTAssertEqual(rt.manifest().components["dxmt"]?.version, "0.61")
        XCTAssertEqual(try GlobalConfig.load(sb.paths).defaultRuntime, r.runtime)
        // DXMT was merged into wine-dxmt/ (a clone of wine/).
        XCTAssertTrue(BackendFiles.isDXMTOverlayCurrent(rt))
        XCTAssertEqual(sb.read(rt.dxmtWineRoot.appendingPathComponent("lib/wine/x86_64-windows/winemetal.dll")), "dxmt64-winemetal.dll")
        XCTAssertEqual(sb.read(rt.dxmtWineRoot.appendingPathComponent("lib/wine/i386-windows/winemetal.dll")), "dxmt32-winemetal.dll")
        XCTAssertEqual(rt.dxmtBuiltAgainst, "wine-crossover-26.3.0-wow64")
        XCTAssertEqual(store.list().map(\.name), [r.runtime], "staging dirs are not listed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sb.paths.runtimes.path).filter { $0.hasPrefix(".") }, [])
    }

    func testInstallFromDirectoryAndGraphicsOnlyIntoDefault() throws {
        let sb = try Sandbox()
        let a = try sb.makeArchives()
        let dl = sb.root.appendingPathComponent("artifact/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: a.wine, to: dl.appendingPathComponent(a.wine.lastPathComponent))
        let store = RuntimeStore(paths: sb.paths)
        XCTAssertEqual(try store.install(sources: [sb.root.appendingPathComponent("artifact")]).installed.keys.sorted(), ["wine"])

        // Graphics archives on their own go into the default runtime.
        let r = try store.install(sources: [a.dxvk])
        XCTAssertEqual(r.runtime, "crossover-26.3.0-wow64")
        XCTAssertFalse(r.madeDefault)
        XCTAssertTrue(try store.get(r.runtime).hasDXVK)
        XCTAssertTrue(try store.get(r.runtime).hasWine, "earlier components are kept")
    }

    /// `gh run download` without `--name` makes one folder per artifact: `<dir>/<artifact>/<artifact>.tar.xz`.
    func testInstallGraphicsFromGhRunDownloadLayout() throws {
        let sb = try Sandbox()
        let a = try sb.makeArchives()
        let store = RuntimeStore(paths: sb.paths)
        try store.install(sources: [a.wine])
        let dl = sb.root.appendingPathComponent("graphics-artifacts", isDirectory: true)
        for (src, artifact) in [(a.dxmt, "dxmt-0.80"), (a.dxvk, "dxvk-macos-1.10.3-20230507-repack")] {
            let dir = dl.appendingPathComponent(artifact, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: src, to: dir.appendingPathComponent("\(artifact).tar.xz"))
        }
        let r = try store.install(sources: [dl])
        XCTAssertEqual(r.runtime, "crossover-26.3.0-wow64")
        XCTAssertEqual(r.installed.keys.sorted(), ["dxmt", "dxvk"])
        let rt = try store.get(r.runtime)
        XCTAssertEqual(rt.manifest().components["dxmt"]?.version, "0.80")
        XCTAssertEqual(rt.manifest().components["dxvk"]?.version, "1.10.3-20230507-repack")
        XCTAssertTrue(rt.hasDXMT && rt.hasDXVK)
        XCTAssertTrue(BackendFiles.isDXMTOverlayCurrent(rt))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rt.dxmtRoot.appendingPathComponent("LICENSE").path), "license kept with the DLLs")
    }

    func testInstallExtractedTreeCopiesRatherThanMoves() throws {
        let sb = try Sandbox()
        let tree = sb.root.appendingPathComponent("tree", isDirectory: true)
        try sb.makeWineTree(at: tree.appendingPathComponent("wine"))
        let r = try RuntimeStore(paths: sb.paths).install(sources: [tree], name: "dev")
        XCTAssertEqual(r.runtime, "dev")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.appendingPathComponent("wine/bin/wine").path))
    }

    func testReinstallReplacesComponent() throws {
        let sb = try Sandbox()
        let a = try sb.makeArchives()
        let store = RuntimeStore(paths: sb.paths)
        try store.install(sources: [a.wine, a.dxvk])
        // dxvk v2 with d3d8
        let s = sb.root.appendingPathComponent("pack2", isDirectory: true)
        try sb.makeDXVKTree(at: s.appendingPathComponent("dxvk"), d3d8: true)
        try store.install(sources: [try sb.tar(s, "dxvk", as: "dxvk-macos-2.0.tar.gz")])
        let rt = try store.get("crossover-26.3.0-wow64")
        XCTAssertTrue(rt.dxvkHasD3D8)
        XCTAssertEqual(rt.manifest().components["dxvk"]?.version, "2.0")
    }

    func testRejectsBadInput() throws {
        let sb = try Sandbox()
        let store = RuntimeStore(paths: sb.paths)
        let s = sb.root.appendingPathComponent("junk", isDirectory: true)
        try sb.write("stuff/readme.txt", in: s)
        let junk = try sb.tar(s, "stuff", as: "junk.tar.gz")
        XCTAssertThrowsError(try store.install(sources: [junk])) { e in
            XCTAssertTrue("\(e)".contains("expected a top-level wine/"), "\(e)")
        }
        // Graphics only with no runtime yet.
        let a = try sb.makeArchives()
        XCTAssertThrowsError(try store.install(sources: [a.dxmt])) { XCTAssertEqual($0 as? MGError, .noRuntime) }
        // Wine archive without bin/wine.
        let w = sb.root.appendingPathComponent("w", isDirectory: true)
        try sb.write("wine/lib/x", in: w)
        XCTAssertThrowsError(try store.install(sources: [try sb.tar(w, "wine", as: "wine-broken.tar.gz")]))
        XCTAssertThrowsError(try store.install(sources: [sb.root.appendingPathComponent("missing.tar.xz")]))
        XCTAssertEqual(store.list(), [])
    }

    func testResolve() throws {
        let sb = try Sandbox()
        let store = RuntimeStore(paths: sb.paths)
        XCTAssertThrowsError(try store.resolve(nil, config: GlobalConfig())) { XCTAssertEqual($0 as? MGError, .noRuntime) }
        let t = sb.root.appendingPathComponent("t", isDirectory: true)
        try sb.makeWineTree(at: t.appendingPathComponent("wine"))
        try store.install(sources: [t], name: "a")
        try store.install(sources: [t], name: "b")
        XCTAssertEqual(try store.resolve(nil, config: GlobalConfig.load(sb.paths)).name, "a", "first install became the default")
        XCTAssertThrowsError(try store.resolve(nil, config: GlobalConfig())) { e in
            XCTAssertEqual(e as? MGError, .ambiguousRuntime(["a", "b"]))
        }
        XCTAssertEqual(try store.resolve("b", config: GlobalConfig()).name, "b")
        try store.remove("a")
        XCTAssertNil(try GlobalConfig.load(sb.paths).defaultRuntime)
        XCTAssertEqual(try store.resolve(nil, config: GlobalConfig.load(sb.paths)).name, "b")
    }
}
