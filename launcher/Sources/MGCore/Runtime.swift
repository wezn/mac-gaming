import Foundation

/// One installed runtime: `runtimes/<name>/{wine,dxmt,dxvk}` plus `runtime.json`, and the generated
/// `wine-dxmt/` and `wine-d3dmetal/` trees.
public struct Runtime: Equatable, Sendable {
    public var name: String
    public var root: URL

    public init(name: String, root: URL) {
        self.name = name
        self.root = root
    }

    public var wineRoot: URL { root.appendingPathComponent("wine", isDirectory: true) }
    public var dxmtRoot: URL { root.appendingPathComponent("dxmt", isDirectory: true) }
    public var dxvkRoot: URL { root.appendingPathComponent("dxvk", isDirectory: true) }
    /// Copy-on-write clone of `wine/` with DXMT's builtin DLLs and `winemetal.so` merged into `lib/wine`
    /// (built at install time, rebuilt on demand).
    public var dxmtWineRoot: URL { root.appendingPathComponent("wine-dxmt", isDirectory: true) }
    /// Copy-on-write clone of `wine/` with the user's D3DMetal files merged in (built on demand).
    public var d3dmetalWineRoot: URL { root.appendingPathComponent("wine-d3dmetal", isDirectory: true) }
    public var manifestFile: URL { root.appendingPathComponent("runtime.json") }

    public static func wineBinary(in wineRoot: URL) -> URL {
        let bin = wineRoot.appendingPathComponent("bin")
        let wine = bin.appendingPathComponent("wine")
        if FileManager.default.isExecutableFile(atPath: wine.path) { return wine }
        let wine64 = bin.appendingPathComponent("wine64")
        return FileManager.default.isExecutableFile(atPath: wine64.path) ? wine64 : wine
    }

    public var wineBinary: URL { Runtime.wineBinary(in: wineRoot) }
    public var wineserver: URL { wineRoot.appendingPathComponent("bin/wineserver") }

    public var hasWine: Bool { FileManager.default.isExecutableFile(atPath: wineBinary.path) }
    public var hasDXMT: Bool { !dlls(in: dxmtRoot.appendingPathComponent("x86_64-windows")).isEmpty }
    public var hasDXVK: Bool { !dlls(in: dxvkRoot.appendingPathComponent("x64")).isEmpty }
    public var dxvkHasD3D8: Bool { FileManager.default.fileExists(atPath: dxvkRoot.appendingPathComponent("x64/d3d8.dll").path) }

    /// The Wine build DXMT was linked against, from the `Built against Wine:` line of `dxmt/VERSION`
    /// (`wine-crossover-26.3.0-wow64`). DXMT's builtins only work with that Wine.
    public var dxmtBuiltAgainst: String? {
        guard let text = try? String(contentsOf: dxmtRoot.appendingPathComponent("VERSION"), encoding: .utf8) else { return nil }
        let key = "built against wine:"
        for line in text.split(whereSeparator: \.isNewline) where line.lowercased().hasPrefix(key) {
            let v = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return nil
    }

    public func manifest() -> RuntimeManifest {
        (try? JSONFile.loadIfPresent(RuntimeManifest.self, from: manifestFile)) ?? RuntimeManifest(name: name)
    }

    func dlls(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".dll") }
            .sorted()
    }
}

public struct RuntimeManifest: Codable, Equatable, Sendable {
    public struct Component: Codable, Equatable, Sendable {
        public var archive: String
        public var version: String?
        public var installed: Date
    }

    public var name: String
    public var components: [String: Component]

    public init(name: String, components: [String: Component] = [:]) {
        self.name = name
        self.components = components
    }
}

public enum RuntimeComponent: String, CaseIterable, Sendable {
    case wine, dxmt, dxvk

    /// `wine-crossover-26.3.0-wow64.tar.xz` → `wine-crossover-26.3.0-wow64`.
    public static func stripArchiveExtension(_ name: String) -> String {
        var base = name
        for ext in RuntimeStore.archiveSuffixes where base.lowercased().hasSuffix(ext) {
            base.removeLast(ext.count)
            break
        }
        return base
    }

    /// Version from an archive name: `wine-crossover-26.3.0-wow64.tar.xz` → `crossover-26.3.0-wow64`,
    /// `dxmt-0.61.tar.xz` → `0.61`, `dxvk-macos-1.10.3-20230507.tar.xz` → `1.10.3-20230507`.
    public static func version(fromArchive name: String) -> String? {
        let base = stripArchiveExtension(name)
        for prefix in ["wine-", "dxvk-macos-", "dxvk-", "dxmt-"] where base.lowercased().hasPrefix(prefix) {
            let v = String(base.dropFirst(prefix.count))
            return v.isEmpty ? nil : v
        }
        return nil
    }
}

public struct RuntimeInstallReport: Equatable, Sendable {
    public var runtime: String
    public var installed: [String: String]   // component → archive name
    public var madeDefault: Bool
}

public struct RuntimeStore {
    public let paths: MGPaths
    let fm = FileManager.default

    public init(paths: MGPaths) {
        self.paths = paths
    }

    public func list() -> [Runtime] {
        ((try? fm.contentsOfDirectory(atPath: paths.runtimes.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { Runtime(name: $0, root: paths.runtime($0)) }
            .filter { fm.fileExists(atPath: $0.root.path) }
    }

    public func get(_ name: String) throws -> Runtime {
        try Names.validate(name)
        let rt = Runtime(name: name, root: paths.runtime(name))
        guard fm.fileExists(atPath: rt.root.path) else { throw MGError.runtimeNotFound(name) }
        return rt
    }

    /// Explicit name, else the configured default, else the only installed runtime.
    public func resolve(_ name: String?, config: GlobalConfig) throws -> Runtime {
        if let n = name ?? config.defaultRuntime { return try get(n) }
        let all = list()
        switch all.count {
        case 0: throw MGError.noRuntime
        case 1: return all[0]
        default: throw MGError.ambiguousRuntime(all.map(\.name))
        }
    }

    public func remove(_ name: String) throws {
        let rt = try get(name)
        try fm.removeItem(at: rt.root)
        var config = try GlobalConfig.load(paths)
        if config.defaultRuntime == name {
            config.defaultRuntime = nil
            try config.save(paths)
        }
    }

    // MARK: install

    static let archiveSuffixes = [".tar.xz", ".tar.gz", ".tar.bz2", ".tgz", ".txz", ".tar", ".zip"]

    static func isArchive(_ name: String) -> Bool {
        let l = name.lowercased()
        return archiveSuffixes.contains { l.hasSuffix($0) }
    }

    /// Installs Wine and/or graphics archives (or already-extracted `wine/`, `dxmt/`, `dxvk/` trees).
    /// Each source is a file or a directory searched recursively, so a downloaded CI artifact folder
    /// works as is. Components are recognised by their top-level directory, not by file name.
    ///
    /// The runtime name is `name`, else derived from the Wine archive (`crossover-26.3.0-wow64`),
    /// else (graphics-only installs) the default or only runtime.
    @discardableResult
    public func install(sources: [URL], name: String? = nil, makeDefault: Bool = false,
                        log: (String) -> Void = { _ in }) throws -> RuntimeInstallReport {
        if let name { try Names.validate(name) }
        try fm.createDirectory(at: paths.runtimes, withIntermediateDirectories: true)
        let staging = paths.runtimes.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // component → (staged directory, archive label)
        var staged: [RuntimeComponent: (URL, String)] = [:]
        var counter = 0

        func addTree(_ dir: URL, label: String) throws {
            for c in RuntimeComponent.allCases {
                let sub = dir.appendingPathComponent(c.rawValue, isDirectory: true)
                guard isDirectory(sub) else { continue }
                if staged[c] != nil { throw MGError.invalidArchive("more than one \(c.rawValue) component given (\(label))") }
                if sub.path.hasPrefix(staging.path + "/") {
                    staged[c] = (sub, label)
                } else {
                    // A tree the user pointed at: copy it, the final step moves staged trees into place.
                    counter += 1
                    let copy = staging.appendingPathComponent("\(counter)", isDirectory: true)
                    try fm.createDirectory(at: copy, withIntermediateDirectories: true)
                    let dest = copy.appendingPathComponent(c.rawValue, isDirectory: true)
                    try fm.copyItem(at: sub, to: dest)
                    staged[c] = (dest, label)
                }
            }
        }

        func extract(_ archive: URL) throws {
            counter += 1
            let dest = staging.appendingPathComponent("\(counter)", isDirectory: true)
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            log("extracting \(archive.lastPathComponent)")
            if archive.pathExtension.lowercased() == "zip" {
                try Archive.unzip(archive, into: dest)
                // CI artifacts are zips that wrap the tarball.
                let inner = try findSources(in: dest)
                if inner.archives.isEmpty && !RuntimeComponent.allCases.contains(where: { isDirectory(dest.appendingPathComponent($0.rawValue)) }) {
                    throw MGError.invalidArchive("\(archive.lastPathComponent) contains no runtime archive")
                }
                try addTree(dest, label: archive.lastPathComponent)
                for a in inner.archives { try extract(a) }
                return
            }
            try Archive.untar(archive, into: dest)
            let before = staged.count
            try addTree(dest, label: archive.lastPathComponent)
            if staged.count == before {
                let top = ((try? fm.contentsOfDirectory(atPath: dest.path)) ?? []).sorted().joined(separator: ", ")
                throw MGError.invalidArchive("\(archive.lastPathComponent): expected a top-level wine/, dxmt/ or dxvk/ directory, found: \(top.isEmpty ? "nothing" : top)")
            }
        }

        for src in sources {
            let src = src.standardizedFileURL
            guard fm.fileExists(atPath: src.path) else { throw MGError.io("\(src.path) does not exist") }
            if isDirectory(src) {
                let found = try findSources(in: src)
                let before = staged.count
                try addTree(src, label: src.lastPathComponent)
                for a in found.archives { try extract(a) }
                if staged.count == before && found.archives.isEmpty {
                    throw MGError.invalidArchive("no runtime archives (wine-*.tar.xz, dxmt-*.tar.xz, dxvk-macos-*.tar.xz) under \(src.path)")
                }
            } else {
                try extract(src)
            }
        }
        guard !staged.isEmpty else { throw MGError.invalidArchive("nothing to install") }

        try validate(staged)

        let runtimeName: String
        if let name {
            runtimeName = name
        } else if let wine = staged[.wine] {
            let derived = RuntimeComponent.version(fromArchive: wine.1) ?? "default"
            runtimeName = derived.replacingOccurrences(of: " ", with: "-")
            try Names.validate(runtimeName)
        } else {
            runtimeName = try resolve(nil, config: GlobalConfig.load(paths)).name
        }

        let rt = Runtime(name: runtimeName, root: paths.runtime(runtimeName))
        try fm.createDirectory(at: rt.root, withIntermediateDirectories: true)
        var manifest = rt.manifest()
        manifest.name = runtimeName
        var report = RuntimeInstallReport(runtime: runtimeName, installed: [:], madeDefault: false)

        for c in RuntimeComponent.allCases {
            guard let (dir, label) = staged[c] else { continue }
            let dest = rt.root.appendingPathComponent(c.rawValue, isDirectory: true)
            try replaceDirectory(dest, with: dir)
            manifest.components[c.rawValue] = .init(archive: label, version: RuntimeComponent.version(fromArchive: label), installed: Date())
            report.installed[c.rawValue] = label
            log("installed \(c.rawValue) from \(label)")
        }
        // The overlays are clones of wine/; drop them so they are rebuilt from the new trees.
        if staged[.wine] != nil { try? fm.removeItem(at: rt.d3dmetalWineRoot) }
        if staged[.wine] != nil || staged[.dxmt] != nil { try? fm.removeItem(at: rt.dxmtWineRoot) }
        try JSONFile.save(manifest, to: rt.manifestFile)
        if rt.hasWine && rt.hasDXMT, try BackendFiles.ensureDXMTOverlay(runtime: rt) {
            log("built \(rt.dxmtWineRoot.lastPathComponent)/ (Wine with DXMT merged in)")
        }

        var config = try GlobalConfig.load(paths)
        if makeDefault || config.defaultRuntime == nil || (try? get(config.defaultRuntime!)) == nil {
            config.defaultRuntime = runtimeName
            try config.save(paths)
            report.madeDefault = true
        }
        return report
    }

    func validate(_ staged: [RuntimeComponent: (URL, String)]) throws {
        if let (dir, label) = staged[.wine] {
            let bin = Runtime.wineBinary(in: dir)
            guard fm.fileExists(atPath: bin.path) else {
                throw MGError.invalidArchive("\(label): wine/bin/wine is missing")
            }
        }
        if let (dir, label) = staged[.dxmt] {
            guard isDirectory(dir.appendingPathComponent("x86_64-windows")) else {
                throw MGError.invalidArchive("\(label): dxmt/x86_64-windows is missing")
            }
        }
        if let (dir, label) = staged[.dxvk] {
            guard isDirectory(dir.appendingPathComponent("x64")) else {
                throw MGError.invalidArchive("\(label): dxvk/x64 is missing")
            }
        }
    }

    struct Found { var archives: [URL] }

    func findSources(in dir: URL) throws -> Found {
        var archives: [URL] = []
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return Found(archives: [])
        }
        for case let url as URL in e {
            // Don't descend into extracted component trees.
            if RuntimeComponent.allCases.map(\.rawValue).contains(url.lastPathComponent), isDirectory(url) {
                e.skipDescendants()
                continue
            }
            if RuntimeStore.isArchive(url.lastPathComponent), !isDirectory(url) { archives.append(url) }
        }
        return Found(archives: archives.sorted { $0.path < $1.path })
    }

    func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    /// Swap `dest` for `src` with the old tree moved aside first, so a failure never leaves half a runtime.
    func replaceDirectory(_ dest: URL, with src: URL) throws {
        let old = dest.deletingLastPathComponent().appendingPathComponent(".old-\(dest.lastPathComponent)-\(UUID().uuidString)")
        let hadOld = fm.fileExists(atPath: dest.path)
        if hadOld { try fm.moveItem(at: dest, to: old) }
        do {
            try fm.moveItem(at: src, to: dest)
        } catch {
            if hadOld { try? fm.moveItem(at: old, to: dest) }
            throw error
        }
        if hadOld { try? fm.removeItem(at: old) }
    }
}

enum Archive {
    static func untar(_ archive: URL, into dir: URL) throws {
        // bsdtar (macOS) and GNU tar both detect the compression when reading.
        let code = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", archive.path, "-C", dir.path],
                                      environment: ProcessInfo.processInfo.environment, output: .inherit)
        guard code == 0 else { throw MGError.processFailed("tar -xf \(archive.lastPathComponent)", code) }
    }

    static func unzip(_ archive: URL, into dir: URL) throws {
        #if os(macOS)
        let tool = URL(fileURLWithPath: "/usr/bin/ditto"), args = ["-x", "-k", archive.path, dir.path]
        #else
        let tool = URL(fileURLWithPath: "/usr/bin/unzip"), args = ["-q", archive.path, "-d", dir.path]
        #endif
        let code = try Subprocess.run(tool, args, environment: ProcessInfo.processInfo.environment, output: .inherit)
        guard code == 0 else { throw MGError.processFailed("unzip \(archive.lastPathComponent)", code) }
    }
}
