import Foundation

/// A Game Porting Toolkit `lib` folder: `external/D3DMetal.framework`, `external/libd3dshared.dylib`,
/// `wine/x86_64-windows/*.dll` and `wine/x86_64-unix/*.so`.
public struct GPTKInstall: Equatable, Sendable {
    public let libRoot: URL

    public var windowsDir: URL { libRoot.appendingPathComponent("wine/x86_64-windows", isDirectory: true) }
    public var unixDir: URL { libRoot.appendingPathComponent("wine/x86_64-unix", isDirectory: true) }
    public var externalDir: URL { libRoot.appendingPathComponent("external", isDirectory: true) }
    public var hasFramework: Bool {
        FileManager.default.fileExists(atPath: externalDir.appendingPathComponent("D3DMetal.framework").path)
    }

    public var dlls: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: windowsDir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".dll") }.sorted()
    }

    /// Accepts the folder the user is likely to name: the mounted GPTK volume or its `redist` folder,
    /// `redist/lib` itself, a Wine tree that already has D3DMetal merged in, or the GPTK app bundle.
    public static func resolve(_ path: String) -> GPTKInstall? {
        let base = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        let candidates = ["", "lib", "redist/lib", "Contents/Resources/wine/lib", "wine/lib"]
        for c in candidates {
            let lib = c.isEmpty ? base : base.appendingPathComponent(c, isDirectory: true)
            let gptk = GPTKInstall(libRoot: lib)
            let win = gptk.windowsDir
            if FileManager.default.fileExists(atPath: win.appendingPathComponent("d3d12.dll").path)
                || FileManager.default.fileExists(atPath: win.appendingPathComponent("d3d11.dll").path),
               gptk.hasFramework || FileManager.default.fileExists(atPath: gptk.externalDir.path) {
                return gptk
            }
        }
        return nil
    }
}

/// A DLL to place in the bottle before launch.
public struct DLLCopy: Equatable, Sendable {
    public var source: URL
    public var destination: URL
}

/// Everything a backend needs for one run in one bottle.
public struct BackendSetup: Equatable, Sendable {
    public var backend: Backend
    /// Wine tree to run (`wine/`, or the D3DMetal overlay).
    public var wineRoot: URL
    public var copies: [DLLCopy]
    public var overrides: DLLOverrides
    public var libraryDirs: [URL]
    public var env: [String: String]
    /// Set when the D3DMetal overlay must exist before launch.
    public var gptk: GPTKInstall?
}

public enum BackendFiles {
    /// Direct3D/DXGI DLLs any backend may replace. Every run pins all of them, so a DLL that a
    /// previous run copied into the bottle for another backend is never picked up by accident.
    public static let d3dDLLs = ["d3d8", "d3d9", "d3d10", "d3d10_1", "d3d10core", "d3d11", "d3d12", "d3d12core", "dxgi"]

    public static func system32(_ prefix: URL) -> URL { prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true) }
    public static func syswow64(_ prefix: URL) -> URL { prefix.appendingPathComponent("drive_c/windows/syswow64", isDirectory: true) }

    public static func setup(for backend: Backend, runtime: Runtime, prefix: URL, gptk: GPTKInstall?) -> BackendSetup {
        var overrides = DLLOverrides()
        overrides.set(d3dDLLs, "b")
        var setup = BackendSetup(backend: backend, wineRoot: runtime.wineRoot, copies: [], overrides: overrides,
                                 libraryDirs: [], env: [:], gptk: nil)

        func native(_ dir: URL, to dest: URL) {
            for name in runtime.dlls(in: dir) {
                setup.copies.append(DLLCopy(source: dir.appendingPathComponent(name), destination: dest.appendingPathComponent(name.lowercased())))
                setup.overrides.set(name, "n,b")
            }
        }

        switch backend {
        case .auto, .wined3d:
            break
        case .dxmt:
            // DXMT's DLLs are Wine builtins linked against this Wine (-Dwine_builtin_dll=true). Wine
            // loads a builtin from its own lib/wine even when a copy sits in system32, so DXMT runs
            // from wine-dxmt/ (ensureDXMTOverlay) and every D3D DLL stays builtin; an `n,b` override
            // would be wrong. wineboot does not put winemetal.dll in the prefix, so it is copied there.
            setup.wineRoot = runtime.dxmtWineRoot
            setup.overrides.set("winemetal", "b")
            for (arch, dest) in [("x86_64-windows", system32(prefix)), ("i386-windows", syswow64(prefix))] {
                let dir = runtime.dxmtRoot.appendingPathComponent(arch, isDirectory: true)
                for name in runtime.dlls(in: dir) where name.lowercased() == "winemetal.dll" {
                    setup.copies.append(DLLCopy(source: dir.appendingPathComponent(name), destination: dest.appendingPathComponent("winemetal.dll")))
                }
            }
        case .dxvk:
            native(runtime.dxvkRoot.appendingPathComponent("x64"), to: system32(prefix))
            native(runtime.dxvkRoot.appendingPathComponent("x32"), to: syswow64(prefix))
        case .d3dmetal:
            // D3DMetal replaces Wine's builtins, so it runs from a clone of the Wine tree with the
            // GPTK files merged in (the layout Apple's own evaluation environment uses).
            setup.wineRoot = runtime.d3dmetalWineRoot
            setup.gptk = gptk
            for name in gptk?.dlls ?? [] { setup.overrides.set(name, "b") }
            setup.libraryDirs = [runtime.d3dmetalWineRoot.appendingPathComponent("lib/external")]
        }
        return setup
    }

    /// What `wine-dxmt/` was built from; a mismatch means it is stale.
    struct DXMTOverlayStamp: Codable, Equatable {
        var wineInstalled: Double?
        var dxmtInstalled: Double?
    }

    /// DXMT's directories and the `lib/wine` directories their files go to.
    static let dxmtLayout: [(from: String, to: String, suffix: String)] = [
        ("x86_64-windows", "x86_64-windows", ".dll"),
        ("i386-windows", "i386-windows", ".dll"),
        ("x86_64-unix", "x86_64-unix", ".so"),
    ]

    static func dxmtOverlayStamp(_ runtime: Runtime) -> DXMTOverlayStamp {
        let m = runtime.manifest()
        return DXMTOverlayStamp(wineInstalled: m.components["wine"]?.installed.timeIntervalSince1970.rounded(.down),
                                dxmtInstalled: m.components["dxmt"]?.installed.timeIntervalSince1970.rounded(.down))
    }

    /// True when `wine-dxmt/` exists, was built from the installed Wine and DXMT, and has `winemetal.so`.
    public static func isDXMTOverlayCurrent(_ runtime: Runtime) -> Bool {
        let o = runtime.dxmtWineRoot
        let fm = FileManager.default
        guard let old = try? JSONFile.loadIfPresent(DXMTOverlayStamp.self, from: o.appendingPathComponent(".mg-overlay.json")),
              old == dxmtOverlayStamp(runtime),
              fm.isExecutableFile(atPath: Runtime.wineBinary(in: o).path) else { return false }
        let so = runtime.dxmtRoot.appendingPathComponent("x86_64-unix/winemetal.so")
        return !fm.fileExists(atPath: so.path)
            || fm.fileExists(atPath: o.appendingPathComponent("lib/wine/x86_64-unix/winemetal.so").path)
    }

    /// Builds (or reuses) `wine-dxmt/`: a clone of `wine/` with DXMT's PE DLLs copied over Wine's
    /// builtins in `lib/wine/{x86_64,i386}-windows` and `winemetal.so` added to `lib/wine/x86_64-unix`.
    /// This is the install recipe in docs/ARTIFACTS.md, applied to a copy so `wine/` stays stock for
    /// wined3d and DXVK bottles. Returns true when it (re)built the tree.
    @discardableResult
    public static func ensureDXMTOverlay(runtime: Runtime) throws -> Bool {
        if isDXMTOverlayCurrent(runtime) { return false }
        let fm = FileManager.default
        let tmp = runtime.root.appendingPathComponent(".wine-dxmt-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.copyItem(at: runtime.wineRoot, to: tmp)
        let lib = tmp.appendingPathComponent("lib/wine", isDirectory: true)
        for (from, to, suffix) in dxmtLayout {
            let src = runtime.dxmtRoot.appendingPathComponent(from, isDirectory: true)
            let names = ((try? fm.contentsOfDirectory(atPath: src.path)) ?? []).filter { $0.lowercased().hasSuffix(suffix) }
            guard !names.isEmpty else { continue }
            let dst = lib.appendingPathComponent(to, isDirectory: true)
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for name in names {
                // Wine looks builtins up by lower-case name.
                let d = dst.appendingPathComponent(name.lowercased())
                if fm.fileExists(atPath: d.path) || (try? fm.destinationOfSymbolicLink(atPath: d.path)) != nil { try fm.removeItem(at: d) }
                try fm.copyItem(at: src.appendingPathComponent(name), to: d)
            }
        }
        try JSONFile.save(dxmtOverlayStamp(runtime), to: tmp.appendingPathComponent(".mg-overlay.json"))
        if fm.fileExists(atPath: runtime.dxmtWineRoot.path) { try fm.removeItem(at: runtime.dxmtWineRoot) }
        try fm.moveItem(at: tmp, to: runtime.dxmtWineRoot)
        return true
    }

    /// Places the backend's DLLs in the bottle. Returns how many files changed.
    @discardableResult
    public static func deploy(_ copies: [DLLCopy]) throws -> Int {
        var changed = 0
        for c in copies where try copyIfChanged(c.source, to: c.destination) { changed += 1 }
        return changed
    }

    /// Real copies, not symlinks: wineboot rewrites system32 on prefix updates and would write
    /// through a symlink into the runtime. On APFS the copy is a clone, so it costs no space.
    /// Size + modification time decide whether to copy, so repeat launches do no I/O.
    @discardableResult
    static func copyIfChanged(_ src: URL, to dst: URL) throws -> Bool {
        let fm = FileManager.default
        let sa = try fm.attributesOfItem(atPath: src.path)
        if let da = try? fm.attributesOfItem(atPath: dst.path),
           (da[.size] as? NSNumber) == (sa[.size] as? NSNumber),
           (da[.modificationDate] as? Date) == (sa[.modificationDate] as? Date),
           (da[.type] as? FileAttributeType) == .typeRegular {
            return false
        }
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".mg-\(UUID().uuidString)")
        try fm.copyItem(at: src, to: tmp)
        if let m = sa[.modificationDate] as? Date { try fm.setAttributes([.modificationDate: m], ofItemAtPath: tmp.path) }
        if fm.fileExists(atPath: dst.path) || (try? fm.destinationOfSymbolicLink(atPath: dst.path)) != nil {
            try fm.removeItem(at: dst)
        }
        try fm.moveItem(at: tmp, to: dst)
        return true
    }

    /// Dates as plain seconds: ISO 8601 in JSON drops sub-second precision and would never match.
    struct OverlayStamp: Codable, Equatable {
        var gptk: String
        var gptkModified: Double?
        var wineInstalled: Double?
    }

    /// Builds (or reuses) `wine-d3dmetal/`: a clone of `wine/` with the GPTK `lib` folder merged into `lib/`.
    @discardableResult
    public static func ensureD3DMetalOverlay(runtime: Runtime, gptk: GPTKInstall) throws -> Bool {
        let fm = FileManager.default
        let probe = ["d3d12.dll", "d3d11.dll"].map { gptk.windowsDir.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        let stamp = OverlayStamp(
            gptk: gptk.libRoot.path,
            gptkModified: probe.flatMap { ((try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 },
            wineInstalled: runtime.manifest().components["wine"]?.installed.timeIntervalSince1970.rounded(.down))
        let stampFile = runtime.d3dmetalWineRoot.appendingPathComponent(".mg-overlay.json")
        if let old = try? JSONFile.loadIfPresent(OverlayStamp.self, from: stampFile), old == stamp,
           fm.isExecutableFile(atPath: Runtime.wineBinary(in: runtime.d3dmetalWineRoot).path) {
            return false
        }

        let tmp = runtime.root.appendingPathComponent(".wine-d3dmetal-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.copyItem(at: runtime.wineRoot, to: tmp)
        try merge(gptk.libRoot, into: tmp.appendingPathComponent("lib", isDirectory: true))
        try JSONFile.save(stamp, to: tmp.appendingPathComponent(".mg-overlay.json"))
        if fm.fileExists(atPath: runtime.d3dmetalWineRoot.path) { try fm.removeItem(at: runtime.d3dmetalWineRoot) }
        try fm.moveItem(at: tmp, to: runtime.d3dmetalWineRoot)
        return true
    }

    /// Recursive copy of `src`'s contents into `dst`, overwriting files. Symlinks and bundles
    /// (`.framework`) are copied whole.
    static func merge(_ src: URL, into dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: src.path) {
            let s = src.appendingPathComponent(name), d = dst.appendingPathComponent(name)
            let isLink = (try? fm.destinationOfSymbolicLink(atPath: s.path)) != nil
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: s.path, isDirectory: &isDir)
            var dIsDir: ObjCBool = false
            let dExists = fm.fileExists(atPath: d.path, isDirectory: &dIsDir)
            if isDir.boolValue && !isLink && dExists && dIsDir.boolValue && !name.hasSuffix(".framework") {
                try merge(s, into: d)
            } else {
                if dExists || (try? fm.destinationOfSymbolicLink(atPath: d.path)) != nil { try fm.removeItem(at: d) }
                try fm.copyItem(at: s, to: d)
            }
        }
    }
}
