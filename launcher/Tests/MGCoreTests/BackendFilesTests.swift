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
        XCTAssertEqual(s.wineRoot, rt.dxmtWineRoot, "DXMT's builtins load from the Wine tree")
        let copies = s.copies.map {
            ($0.source.path.replacingOccurrences(of: rt.root.path + "/", with: ""),
             $0.destination.path.replacingOccurrences(of: prefix.path + "/", with: ""))
        }
        XCTAssertEqual(copies.map(\.0), ["dxmt/x86_64-windows/winemetal.dll", "dxmt/i386-windows/winemetal.dll"])
        XCTAssertEqual(copies.map(\.1), ["drive_c/windows/system32/winemetal.dll", "drive_c/windows/syswow64/winemetal.dll"])
        // Builtin, never n,b: DXMT's DLLs are Wine builtins (docs/ARTIFACTS.md).
        for d in BackendFiles.d3dDLLs { XCTAssertEqual(s.overrides[d], "b", d) }
        XCTAssertEqual(s.overrides["winemetal"], "b")
    }

    func testDXMTOverlay() throws {
        let sb = try Sandbox()
        let rt = try installedRuntime(sb)
        let fm = FileManager.default
        let o = rt.dxmtWineRoot
        // Built by the install.
        XCTAssertTrue(BackendFiles.isDXMTOverlayCurrent(rt))
        XCTAssertFalse(try BackendFiles.ensureDXMTOverlay(runtime: rt), "cached")
        XCTAssertTrue(fm.isExecutableFile(atPath: o.appendingPathComponent("bin/wine").path))
        for (dir, tag) in [("x86_64-windows", "dxmt64"), ("i386-windows", "dxmt32")] {
            for f in ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"] {
                XCTAssertEqual(sb.read(o.appendingPathComponent("lib/wine/\(dir)/\(f)")), "\(tag)-\(f)")
            }
        }
        XCTAssertEqual(sb.read(o.appendingPathComponent("lib/wine/x86_64-unix/winemetal.so")), "winemetal-unix")
        XCTAssertEqual(sb.read(o.appendingPathComponent("lib/wine/x86_64-windows/wined3d.dll")), "wine-builtin-wined3d", "Wine files kept")
        XCTAssertFalse(fm.fileExists(atPath: o.appendingPathComponent("lib/wine/x86_64-windows/LICENSE").path))
        // wine/ is untouched, so wined3d and DXVK keep stock Wine.
        XCTAssertEqual(sb.read(rt.wineRoot.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")), "wine-builtin-d3d11")
        XCTAssertFalse(fm.fileExists(atPath: rt.wineRoot.appendingPathComponent("lib/wine/x86_64-unix/winemetal.so").path))
        XCTAssertFalse(fm.fileExists(atPath: rt.wineRoot.appendingPathComponent("lib/wine/x86_64-windows/winemetal.dll").path))

        // A missing overlay is rebuilt on demand.
        try fm.removeItem(at: o)
        XCTAssertFalse(BackendFiles.isDXMTOverlayCurrent(rt))
        XCTAssertTrue(try BackendFiles.ensureDXMTOverlay(runtime: rt))
        XCTAssertTrue(BackendFiles.isDXMTOverlayCurrent(rt))

        // Reinstalling DXMT rebuilds it from the new files.
        let t = sb.root.appendingPathComponent("t2", isDirectory: true)
        try sb.makeDXMTTree(at: t.appendingPathComponent("dxmt"))
        try sb.write("dxmt/x86_64-windows/d3d11.dll", "dxmt64-v2", in: t)
        try RuntimeStore(paths: sb.paths).install(sources: [t], name: rt.name)
        XCTAssertEqual(sb.read(o.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")), "dxmt64-v2")
        XCTAssertTrue(BackendFiles.isDXMTOverlayCurrent(rt))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: rt.root.path).filter { $0.hasPrefix(".") }, [], "no temp trees left")
    }

    func testDXMTDeployIntoPrefix() throws {
        let sb = try Sandbox()
        let rt = try installedRuntime(sb)
        let prefix = sb.paths.bottle("b")
        let s = BackendFiles.setup(for: .dxmt, runtime: rt, prefix: prefix, gptk: nil)
        XCTAssertEqual(try BackendFiles.deploy(s.copies), 2)
        XCTAssertEqual(sb.read(BackendFiles.system32(prefix).appendingPathComponent("winemetal.dll")), "dxmt64-winemetal.dll")
        XCTAssertEqual(sb.read(BackendFiles.syswow64(prefix).appendingPathComponent("winemetal.dll")), "dxmt32-winemetal.dll")
        XCTAssertFalse(FileManager.default.fileExists(atPath: BackendFiles.system32(prefix).appendingPathComponent("d3d11.dll").path))
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
