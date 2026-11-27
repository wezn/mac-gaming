import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct DoctorCheck: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case ok, warning, error }
    public var status: Status
    public var title: String
    public var detail: String

    public init(_ status: Status, _ title: String, _ detail: String) {
        self.status = status
        self.title = title
        self.detail = detail
    }
}

/// Environment checks behind `mg doctor`. Host probes are injectable for tests.
public struct Doctor {
    public let paths: MGPaths
    public var environment: [String: String]
    public var osVersion: OperatingSystemVersion
    public var machine: String
    /// nil = not macOS (Rosetta is not applicable).
    public var rosettaInstalled: () -> Bool?

    public init(paths: MGPaths, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.environment = environment
        self.osVersion = ProcessInfo.processInfo.operatingSystemVersion
        self.machine = Doctor.hostMachine()
        self.rosettaInstalled = Doctor.probeRosetta
    }

    static func hostMachine() -> String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func probeRosetta() -> Bool? {
        #if os(macOS)
        // Running an x86_64 binary is the only reliable test; it takes a few ms once Rosetta is warm.
        let code = try? Subprocess.run(URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", "/usr/bin/true"],
                                       environment: [:], output: .null)
        return code == 0
        #else
        return nil
        #endif
    }

    /// The text `mg doctor` prints.
    public static func render(_ checks: [DoctorCheck]) -> String {
        checks.map { c in
            let mark = c.status == .ok ? "✓" : c.status == .warning ? "!" : "✗"
            return "\(mark) \(c.title)\(c.detail.isEmpty ? "" : "\n    \(c.detail)")\n"
        }.joined()
    }

    /// `mg doctor --json`: `{"ok": false, "errors": 1, "warnings": 2, "checks": [{"status", "title", "detail"}]}`.
    public static func json(_ checks: [DoctorCheck]) -> String {
        struct Out: Encodable {
            var ok: Bool
            var errors: Int
            var warnings: Int
            var checks: [DoctorCheck]
        }
        let errors = checks.filter { $0.status == .error }.count
        let out = Out(ok: errors == 0, errors: errors, warnings: checks.filter { $0.status == .warning }.count, checks: checks)
        return String(decoding: (try? JSONFile.encoder.encode(out)) ?? Data("{}".utf8), as: UTF8.self) + "\n"
    }

    public func run() -> [DoctorCheck] {
        var out: [DoctorCheck] = []
        let v = osVersion
        let vs = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #if os(macOS)
        if v.majorVersion < 13 {
            out.append(.init(.error, "macOS \(vs)", "macOS 13 or newer is required"))
        } else if v.majorVersion < 15 {
            out.append(.init(.warning, "macOS \(vs)", "macOS 15+ is recommended: Rosetta 2 only translates AVX/AVX2 from macOS 15, and many games need it"))
        } else {
            out.append(.init(.ok, "macOS \(vs)", ""))
        }
        #else
        out.append(.init(.warning, "not macOS (\(vs))", "mg only runs games on macOS; checks below are for testing"))
        #endif

        out.append(machine == "arm64" || machine == "aarch64"
                   ? .init(.ok, "Apple Silicon (\(machine))", "")
                   : .init(.warning, "CPU \(machine)", "mg targets Apple Silicon Macs"))

        switch rosettaInstalled() {
        case .some(true): out.append(.init(.ok, "Rosetta 2", ""))
        case .some(false): out.append(.init(.error, "Rosetta 2 missing", "run: softwareupdate --install-rosetta --agree-to-license"))
        case .none: break
        }

        let config: GlobalConfig
        do { config = try GlobalConfig.load(paths) } catch {
            out.append(.init(.error, "config.json", "\(error)"))
            return out
        }

        let store = RuntimeStore(paths: paths)
        let runtimes = store.list()
        if runtimes.isEmpty {
            out.append(.init(.error, "no runtime", MGError.noRuntime.description))
        }
        let defaultName = (try? store.resolve(nil, config: config))?.name
        for rt in runtimes {
            let tag = rt.name == defaultName ? " (default)" : ""
            let m = rt.manifest()
            if rt.hasWine {
                let ver = m.components["wine"]?.version.map { " \($0)" } ?? ""
                out.append(.init(.ok, "runtime \(rt.name)\(tag): Wine\(ver)", rt.wineBinary.path))
                let mvk = rt.wineRoot.appendingPathComponent("lib/libMoltenVK.dylib")
                if !FileManager.default.fileExists(atPath: mvk.path) {
                    out.append(.init(.warning, "runtime \(rt.name): MoltenVK missing", "\(mvk.path) not found; DXVK and Vulkan games will fail"))
                }
            } else {
                out.append(.init(.error, "runtime \(rt.name)\(tag): no Wine", "\(rt.wineBinary.path) missing or not executable"))
            }
            if rt.hasDXMT {
                let title = "runtime \(rt.name): DXMT \(m.components["dxmt"]?.version ?? "")"
                if !rt.hasWine {
                    out.append(.init(.warning, title, "no Wine in this runtime to merge DXMT into"))
                } else if BackendFiles.isDXMTOverlayCurrent(rt) {
                    out.append(.init(.ok, title, "winemetal integrated: \(rt.dxmtWineRoot.path)"))
                } else {
                    out.append(.init(.warning, title, "\(rt.dxmtWineRoot.path) is missing or stale; the next DXMT run rebuilds it"))
                }
                // DXMT's builtins are linked against one Wine build (dxmt/VERSION records which).
                if let built = rt.dxmtBuiltAgainst, let wineArchive = m.components["wine"]?.archive {
                    let wine = RuntimeComponent.stripArchiveExtension(wineArchive)
                    if wine.lowercased() != built.lowercased() {
                        out.append(.init(.warning, "runtime \(rt.name): DXMT built for another Wine",
                                         "DXMT was built against \(built), this runtime has \(wine); DX10/11 games may fail to start"))
                    }
                }
            } else {
                out.append(.init(.warning, "runtime \(rt.name): DXMT not installed", "DX10/11 games fall back to D3DMetal, DXVK or wined3d"))
            }
            out.append(rt.hasDXVK
                       ? .init(.ok, "runtime \(rt.name): DXVK \(m.components["dxvk"]?.version ?? "")", "")
                       : .init(.warning, "runtime \(rt.name): DXVK not installed", "DX9 games fall back to wined3d"))
        }

        let gptkPath = environment["MG_GPTK"].flatMap { $0.isEmpty ? nil : $0 } ?? config.gptkPath
        if let p = gptkPath {
            if let g = GPTKInstall.resolve(p) {
                let version = g.version.map { " \($0)" } ?? ""
                out.append(g.hasFramework
                           ? .init(.ok, "D3DMetal (GPTK)\(version)", g.libRoot.path)
                           : .init(.warning, "D3DMetal (GPTK)", "\(g.libRoot.path) has no external/D3DMetal.framework"))
                for rt in runtimes where FileManager.default.fileExists(atPath: rt.d3dmetalWineRoot.path) {
                    let fw = rt.d3dmetalWineRoot.appendingPathComponent("lib/external/D3DMetal.framework")
                    out.append(FileManager.default.fileExists(atPath: fw.path)
                               ? .init(.ok, "runtime \(rt.name): D3DMetal overlay", rt.d3dmetalWineRoot.path)
                               : .init(.error, "runtime \(rt.name): D3DMetal overlay is broken",
                                       "\(fw.path) is missing; the next D3DMetal run rebuilds it only if Wine or the GPTK changed. Remove \(rt.d3dmetalWineRoot.path) to force a rebuild"))
                }
            } else {
                out.append(.init(.error, "D3DMetal (GPTK)", "\(p) does not look like a Game Porting Toolkit (no lib/wine/x86_64-windows/d3d12.dll)"))
            }
        } else {
            out.append(.init(.warning, "D3DMetal not configured", "DX12 games need it: install Apple's Game Porting Toolkit, then `mg config set gptk <path>`"))
        }

        let (bottles, errors) = BottleStore(paths: paths).list()
        for (name, err) in errors.sorted(by: { $0.key < $1.key }) {
            out.append(.init(.error, "bottle \(name)", err))
        }
        for b in bottles {
            if let r = b.config.runtime, (try? store.get(r)) == nil {
                out.append(.init(.error, "bottle \(b.name)", "uses runtime '\(r)', which is not installed"))
            }
        }
        out.append(.init(.ok, "\(bottles.count) bottle(s)", paths.bottles.path))

        do { _ = try GameOverrideTable.load(paths) } catch {
            out.append(.init(.error, "overrides.json", "\(error)"))
        }
        return out
    }
}
