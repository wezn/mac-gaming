import XCTest
@testable import MGCore

final class BackendFilesTests: XCTestCase {
    func installedRuntime(_ sb: Sandbox) throws -> Runtime {
        let a = try sb.makeArchives()
        let store = RuntimeStore(paths: sb.paths)
        return try store.get(store.install(sources: [a.wine, a.dxmt, a.dxvk]).runtime)
    }

    func testDXMTSetup() throws {
        let sb = try Sandbox()
        let rt = try installedRuntime(sb)
        let prefix = sb.paths.bottle("b")
        let s = BackendFiles.setup(for: .dxmt, runtime: rt, prefix: prefix, gptk: nil)
        XCTAssertEqual(s.wineRoot, rt.wineRoot)
        let dests = s.copies.map { $0.destination.path.replacingOccurrences(of: prefix.path + "/", with: "") }.sorted()
        XCTAssertEqual(dests, [
            "drive_c/windows/system32/d3d10core.dll", "drive_c/windows/system32/d3d11.dll", "drive_c/windows/system32/dxgi.dll",
            "drive_c/windows/syswow64/d3d10core.dll", "drive_c/windows/syswow64/d3d11.dll", "drive_c/windows/syswow64/dxgi.dll",
        ])
        XCTAssertEqual(s.overrides["d3d11"], "n,b")
        XCTAssertEqual(s.overrides["dxgi"], "n,b")
        XCTAssertEqual(s.overrides["d3d10core"], "n,b")
        XCTAssertEqual(s.overrides["winemetal"], "b")
        XCTAssertEqual(s.overrides["d3d9"], "b", "DLLs DXMT doesn't provide stay builtin")
        XCTAssertEqual(s.overrides["d3d12"], "b")
    }

    func testDXVKSetup() throws {
        let sb = try Sandbox()
        let rt = try installedRuntime(sb)
        let s = BackendFiles.setup(for: .dxvk, runtime: rt, prefix: sb.paths.bottle("b"), gptk: nil)
        XCTAssertEqual(s.copies.count, 8)
        XCTAssertEqual(s.overrides["d3d9"], "n,b")
        XCTAssertEqual(s.overrides["d3d11"], "n,b")
        XCTAssertEqual(s.overrides["d3d12"], "b")
        XCTAssertTrue(s.copies.contains { $0.source.path.hasSuffix("dxvk/x32/d3d9.dll") && $0.destination.path.hasSuffix("syswow64/d3d9.dll") })
    }

    func testWined3dPinsEverythingBuiltin() throws {
        let sb = try Sandbox()
        let rt = try installedRuntime(sb)
        let s = BackendFiles.setup(for: .wined3d, runtime: rt, prefix: sb.paths.bottle("b"), gptk: nil)
        XCTAssertEqual(s.copies, [])
        for d in BackendFiles.d3dDLLs { XCTAssertEqual(s.overrides[d], "b", d) }
    }

    func testDeployCopiesOnceAndRefreshesOnChange() throws {
        let sb = try Sandbox()
        let rt = try installedRuntime(sb)
        let prefix = sb.paths.bottle("b")
        let s = BackendFiles.setup(for: .dxvk, runtime: rt, prefix: prefix, gptk: nil)
        XCTAssertEqual(try BackendFiles.deploy(s.copies), 8)
        XCTAssertEqual(try BackendFiles.deploy(s.copies), 0, "second launch does no copying")
        let d3d9 = BackendFiles.system32(prefix).appendingPathComponent("d3d9.dll")
        XCTAssertEqual(sb.read(d3d9), "dxvk64-d3d9.dll")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: d3d9.path), "real copy, not a symlink")
        // Something (e.g. wineboot) replaced the DLL: the next launch restores it.
        try Data("wine fake dll, longer".utf8).write(to: d3d9)
        XCTAssertEqual(try BackendFiles.deploy(s.copies), 1)
        XCTAssertEqual(sb.read(d3d9), "dxvk64-d3d9.dll")
    }

    func testGPTKResolution() throws {
        let sb = try Sandbox()
        let base = try sb.makeGPTK()
        let lib = base.appendingPathComponent("redist/lib").standardizedFileURL
        XCTAssertEqual(GPTKInstall.resolve(base.path)?.libRoot, lib)
        XCTAssertEqual(GPTKInstall.resolve(base.appendingPathComponent("redist").path)?.libRoot, lib)
        XCTAssertEqual(GPTKInstall.resolve(lib.path)?.libRoot, lib)
        XCTAssertNil(GPTKInstall.resolve(sb.root.path))
        let g = GPTKInstall.resolve(base.path)!
        XCTAssertTrue(g.hasFramework)
        XCTAssertEqual(g.dlls, ["d3d11.dll", "d3d12.dll", "dxgi.dll", "nvapi64.dll"])
    }

    func testD3DMetalOverlay() throws {
        let sb = try Sandbox()
        let rt = try installedRuntime(sb)
        let g = GPTKInstall.resolve(try sb.makeGPTK().path)!
        let s = BackendFiles.setup(for: .d3dmetal, runtime: rt, prefix: sb.paths.bottle("b"), gptk: g)
        XCTAssertEqual(s.wineRoot, rt.d3dmetalWineRoot)
        XCTAssertEqual(s.copies, [])
        XCTAssertEqual(s.overrides["d3d12"], "b")
        XCTAssertEqual(s.overrides["nvapi64"], "b")
        XCTAssertEqual(s.libraryDirs, [rt.d3dmetalWineRoot.appendingPathComponent("lib/external")])

        XCTAssertTrue(try BackendFiles.ensureD3DMetalOverlay(runtime: rt, gptk: g))
        XCTAssertFalse(try BackendFiles.ensureD3DMetalOverlay(runtime: rt, gptk: g), "cached")
        let o = rt.d3dmetalWineRoot
        XCTAssertEqual(sb.read(o.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")), "gptk-d3d11.dll")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: o.appendingPathComponent("bin/wine").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: o.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so").path), "Wine files kept")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: o.appendingPathComponent("lib/external/D3DMetal.framework/D3DMetal").path),
                       "Versions/A/D3DMetal", "framework symlinks preserved")
        // The base Wine tree is untouched.
        XCTAssertEqual(sb.read(rt.wineRoot.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")), "wine-builtin-d3d11")

        // Reinstalling Wine drops the overlay so it is rebuilt from the new tree.
        let t = sb.root.appendingPathComponent("t2", isDirectory: true)
        try sb.makeWineTree(at: t.appendingPathComponent("wine"))
        try RuntimeStore(paths: sb.paths).install(sources: [t], name: rt.name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: o.path))
    }
}
