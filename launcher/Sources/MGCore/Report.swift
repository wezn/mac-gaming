import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Removes the user's home directory and account name from text that is about to leave the machine.
///
/// `/Users/alex/Games` → `~/Games`, and Wine's `C:\users\alex\` / `drive_c/users/alex/` →
/// `C:\users\USER\` / `drive_c/users/USER/` (the account name matched case-insensitively, as Wine
/// paths are, and only as a whole path component).
public struct Redactor: Sendable {
    public var home: String
    public var user: String?

    public init(home: String, user: String?) {
        var h = home
        while h.count > 1 && h.hasSuffix("/") { h.removeLast() }
        self.home = h
        self.user = user.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The current user's home and login name.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Redactor {
        Redactor(home: environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? FileManager.default.homeDirectoryForCurrentUser.path,
                 user: environment["USER"] ?? environment["LOGNAME"])
    }

    public func redact(_ text: String) -> String {
        var s = text
        // A home of "/" (or nothing) would turn every path into "~".
        if home.count > 1 {
            s = s.replacingOccurrences(of: home, with: "~")
        }
        if let u = user, let re = try? NSRegularExpression(
            pattern: #"(users[/\\])"# + NSRegularExpression.escapedPattern(for: u) + #"(?![A-Za-z0-9._-])"#,
            options: .caseInsensitive) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1USER")
        }
        return s
    }
}

/// `mg report`: one archive with what a remote helper needs to debug a setup: host facts, `mg doctor`
/// (text and JSON), settings, runtimes, the DXMT and D3DMetal overlay state, bottles and the newest run logs.
/// Every text file goes through `Redactor`.
public struct DiagnosticReport {
    public struct File: Equatable, Sendable {
        /// Relative path inside the report.
        public var name: String
        public var contents: String
    }

    public var files: [File]

    public init(files: [File]) {
        self.files = files
    }

    public func file(_ name: String) -> File? { files.first { $0.name == name } }

    /// Gathers everything. Missing pieces are noted in the files instead of failing the report.
    public static func collect(paths: MGPaths, doctor: Doctor, toolVersion: String, redactor: Redactor = .current(),
                               logCount: Int = 10, maxLogBytes: Int = 512 * 1024, date: Date = Date()) -> DiagnosticReport {
        var files: [File] = []
        func add(_ name: String, _ text: String) { files.append(File(name: name, contents: redactor.redact(text))) }

        let checks = doctor.run()
        let config = try? GlobalConfig.load(paths)
        let gptkPath = doctor.environment["MG_GPTK"].flatMap { $0.isEmpty ? nil : $0 } ?? config?.gptkPath
        let gptk = gptkPath.flatMap(GPTKInstall.resolve)

        // summary.txt
        let v = doctor.osVersion
        var summary = """
        mg \(toolVersion)
        date: \(ISO8601DateFormatter().string(from: date))
        root: \(paths.root.path)
        os: \(ProcessInfo.processInfo.operatingSystemVersionString) (\(v.majorVersion).\(v.minorVersion).\(v.patchVersion))
        machine: \(doctor.machine)
        cpu: \(Host.sysctlString("machdep.cpu.brand_string") ?? "unknown")
        model: \(Host.sysctlString("hw.model") ?? "unknown")
        memory: \(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
        gptk: \(gptkPath ?? "(not set)")
        gptk version: \(gptk?.version ?? "unknown")
        doctor: \(checks.filter { $0.status == .error }.count) error(s), \(checks.filter { $0.status == .warning }.count) warning(s)

        """
        let relevantEnv = ["MG_HOME", "MG_GPTK", "WINEDEBUG", "WINEDLLOVERRIDES", "WINEPREFIX", "WINEMSYNC",
                           "DYLD_FALLBACK_LIBRARY_PATH", "MTL_HUD_ENABLED"]
        let setEnv = relevantEnv.compactMap { k in doctor.environment[k].map { "  \(k)=\($0)" } }
        summary += "environment:\n" + (setEnv.isEmpty ? "  (none of \(relevantEnv.joined(separator: ", ")))" : setEnv.joined(separator: "\n")) + "\n"
        add("summary.txt", summary)

        add("doctor.txt", Doctor.render(checks))
        add("doctor.json", Doctor.json(checks))

        add("config.json", readText(paths.configFile) ?? "(no config.json)\n")
        if let o = readText(paths.overridesFile) { add("overrides.json", o) }

        // runtimes.txt: manifests plus the files each backend relies on.
        let store = RuntimeStore(paths: paths)
        var rts = ""
        for rt in store.list() {
            rts += "== \(rt.name)\n"
            rts += (readText(rt.manifestFile) ?? "(no runtime.json)\n")
            let fm = FileManager.default
            let probes: [(String, URL)] = [
                ("wine binary", rt.wineBinary),
                ("MoltenVK", rt.wineRoot.appendingPathComponent("lib/libMoltenVK.dylib")),
                ("DXMT VERSION", rt.dxmtRoot.appendingPathComponent("VERSION")),
                ("DXMT overlay", rt.dxmtWineRoot),
                ("DXMT overlay winemetal.so", rt.dxmtWineRoot.appendingPathComponent("lib/wine/x86_64-unix/winemetal.so")),
                ("DXMT overlay winemetal.dll", rt.dxmtWineRoot.appendingPathComponent("lib/wine/x86_64-windows/winemetal.dll")),
                ("DXMT overlay d3d11.dll", rt.dxmtWineRoot.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")),
                // DXMT must never leak into the stock tree other backends use.
                ("stock wine/ winemetal.so (should be missing)", rt.wineRoot.appendingPathComponent("lib/wine/x86_64-unix/winemetal.so")),
                ("DXVK VERSION", rt.dxvkRoot.appendingPathComponent("VERSION")),
                ("D3DMetal overlay", rt.d3dmetalWineRoot),
                ("D3DMetal overlay framework", rt.d3dmetalWineRoot.appendingPathComponent("lib/external/D3DMetal.framework")),
                ("D3DMetal overlay d3d12.dll", rt.d3dmetalWineRoot.appendingPathComponent("lib/wine/x86_64-windows/d3d12.dll")),
            ]
            for (label, url) in probes {
                rts += "\(fm.fileExists(atPath: url.path) ? "present" : "missing"): \(label) (\(url.path))\n"
            }
            if rt.hasDXMT {
                rts += "DXMT overlay current: \(BackendFiles.isDXMTOverlayCurrent(rt))\n"
                // Which d3d11/dxgi/d3d10core wine-dxmt/ really has: DXMT's, Wine's, or neither.
                for dir in ["x86_64-windows", "i386-windows"] {
                    for dll in ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"] {
                        let src = rt.dxmtRoot.appendingPathComponent("\(dir)/\(dll)")
                        let dst = rt.dxmtWineRoot.appendingPathComponent("lib/wine/\(dir)/\(dll)")
                        let state = !fm.fileExists(atPath: dst.path) ? "missing"
                            : fm.contentsEqual(atPath: src.path, andPath: dst.path) ? "DXMT's" : "NOT DXMT's"
                        rts += "wine-dxmt/lib/wine/\(dir)/\(dll): \(state)\n"
                    }
                }
            }
            for (label, url) in [("DXMT VERSION", rt.dxmtRoot.appendingPathComponent("VERSION")),
                                 ("DXVK VERSION", rt.dxvkRoot.appendingPathComponent("VERSION")),
                                 ("DXMT overlay stamp", rt.dxmtWineRoot.appendingPathComponent(".mg-overlay.json")),
                                 ("D3DMetal overlay stamp", rt.d3dmetalWineRoot.appendingPathComponent(".mg-overlay.json"))] {
                if let t = readText(url) { rts += "\(label):\n\(t.hasSuffix("\n") ? t : t + "\n")" }
            }
            rts += "\n"
        }
        add("runtimes.txt", rts.isEmpty ? "no runtimes installed\n" : rts)

        // gptk.txt: the layout mg found, so a wrong guess about Apple's folder structure is visible.
        var g = "configured: \(gptkPath ?? "(not set)")\n"
        if let p = gptkPath {
            if let gptk {
                g += "lib root: \(gptk.libRoot.path)\nversion: \(gptk.version ?? "unknown")\n"
                g += "D3DMetal.framework: \(gptk.hasFramework ? "present" : "missing")\n"
                g += "x86_64-windows DLLs: \(gptk.dlls.joined(separator: ", "))\n"
            } else {
                g += "not recognised as a Game Porting Toolkit\n"
            }
            g += "\nlisting (depth 4):\n" + listTree(URL(fileURLWithPath: (p as NSString).expandingTildeInPath), depth: 4, limit: 400)
        }
        add("gptk.txt", g)

        // bottles
        let (bottles, errors) = BottleStore(paths: paths).list()
        for b in bottles {
            var t = readText(b.configFile) ?? ""
            t += "\ninitialised: \(b.isInitialized)\n"
            // Which D3D DLLs are in the prefix now (Wine placeholder vs a backend's copy) is the first
            // thing to look at when the wrong backend loads.
            for dir in ["system32", "syswow64"] {
                let d = b.prefix.appendingPathComponent("drive_c/windows/\(dir)")
                let names = ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll", "winemetal.dll"]
                let sizes = names.map { n -> String in
                    let a = try? FileManager.default.attributesOfItem(atPath: d.appendingPathComponent(n).path)
                    return "\(n)=\((a?[.size] as? NSNumber).map { "\($0.intValue)B" } ?? "-")"
                }
                t += "\(dir): \(sizes.joined(separator: " "))\n"
            }
            add("bottles/\(b.name).txt", t)
        }
        for (n, e) in errors.sorted(by: { $0.key < $1.key }) { add("bottles/\(n).error.txt", e + "\n") }

        // newest logs, each cut to its last `maxLogBytes`
        let logs = LogStore(paths: paths).list().prefix(max(0, logCount))
        var index = ""
        for e in logs {
            index += "\(ISO8601DateFormatter().string(from: e.modified))  \(e.bottle)/\(e.url.lastPathComponent)  \(e.size) bytes\n"
            add("logs/\(e.bottle)/\(e.url.lastPathComponent)", tail(e.url, maxBytes: maxLogBytes))
        }
        add("logs/index.txt", index.isEmpty ? "no logs yet\n" : index)

        return DiagnosticReport(files: files)
    }

    /// Writes the files under `directory/<name>/`.
    public func write(to directory: URL) throws {
        let fm = FileManager.default
        for f in files {
            let url = directory.appendingPathComponent(f.name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(f.contents.utf8).write(to: url, options: .atomic)
        }
    }

    /// Writes a `.tar.gz` whose single top-level folder is `folderName`.
    public func writeArchive(to archive: URL, folderName: String) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("mg-report-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try write(to: staging.appendingPathComponent(folderName, isDirectory: true))
        try fm.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        let code = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-czf", archive.path, "-C", staging.path, folderName],
                                      environment: ProcessInfo.processInfo.environment, output: .null)
        guard code == 0 else { throw MGError.processFailed("tar", code) }
    }

    static func readText(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    static func tail(_ url: URL, maxBytes: Int) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "(unreadable)\n" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return start > 0 ? "[mg report: first \(start) bytes omitted]\n" + text : text
    }

    /// Names only, sorted, directories marked with `/`. Frameworks are not descended into.
    static func listTree(_ root: URL, depth: Int, limit: Int) -> String {
        var out: [String] = []
        func walk(_ dir: URL, _ prefix: String, _ level: Int) {
            guard level < depth, out.count < limit else { return }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            for n in names where out.count < limit {
                let u = dir.appendingPathComponent(n)
                var isDir: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: u.path)) != nil
                out.append("\(prefix)\(n)\(isDir.boolValue ? "/" : "")\(isLink ? " (symlink)" : "")")
                if isDir.boolValue && !isLink && !n.hasSuffix(".framework") { walk(u, prefix + "  ", level + 1) }
            }
        }
        walk(root, "", 0)
        if out.count >= limit { out.append("... (truncated at \(limit) entries)") }
        return out.isEmpty ? "(empty or unreadable)\n" : out.joined(separator: "\n") + "\n"
    }
}

enum Host {
    static func sysctlString(_ name: String) -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
        #else
        return nil
        #endif
    }
}

extension GPTKInstall {
    /// D3DMetal.framework's `CFBundleShortVersionString` (and build), e.g. "2.1 (21)".
    public var version: String? {
        let fw = externalDir.appendingPathComponent("D3DMetal.framework")
        for rel in ["Versions/A/Resources/Info.plist", "Resources/Info.plist", "Versions/Current/Resources/Info.plist", "Info.plist"] {
            guard let data = try? Data(contentsOf: fw.appendingPathComponent(rel)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            let short = plist["CFBundleShortVersionString"] as? String
            let build = plist["CFBundleVersion"] as? String
            switch (short, build) {
            case let (s?, b?) where s != b: return "\(s) (\(b))"
            case let (s?, _): return s
            case let (nil, b?): return b
            default: continue
            }
        }
        return nil
    }
}
