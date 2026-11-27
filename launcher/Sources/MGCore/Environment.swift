import Foundation

/// Inputs for one run's environment. Pure data so it can be unit tested.
public struct EnvironmentSpec: Equatable, Sendable {
    public var prefix: URL
    public var wineRoot: URL
    /// Extra directories for `DYLD_FALLBACK_LIBRARY_PATH`, searched before the Wine tree's lib/.
    public var libraryDirs: [URL]
    public var dllOverrides: DLLOverrides
    public var msync: Bool
    public var metalHUD: Bool
    /// `WINEDEBUG`; nil keeps an inherited value or falls back to `-all` (logging costs frames).
    public var wineDebug: String?
    /// Backend-specific variables (lowest priority among the explicit layers).
    public var backendEnv: [String: String]
    /// Per-game override env.
    public var gameEnv: [String: String]
    public var bottleEnv: [String: String]
    /// `--env K=V` on the command line (highest priority).
    public var cliEnv: [String: String]

    public init(prefix: URL, wineRoot: URL, libraryDirs: [URL] = [], dllOverrides: DLLOverrides = DLLOverrides(),
                msync: Bool = true, metalHUD: Bool = false, wineDebug: String? = nil,
                backendEnv: [String: String] = [:], gameEnv: [String: String] = [:],
                bottleEnv: [String: String] = [:], cliEnv: [String: String] = [:]) {
        self.prefix = prefix
        self.wineRoot = wineRoot
        self.libraryDirs = libraryDirs
        self.dllOverrides = dllOverrides
        self.msync = msync
        self.metalHUD = metalHUD
        self.wineDebug = wineDebug
        self.backendEnv = backendEnv
        self.gameEnv = gameEnv
        self.bottleEnv = bottleEnv
        self.cliEnv = cliEnv
    }
}

public enum EnvironmentBuilder {
    /// dyld's own default fallback list, kept so system libraries still resolve once we set the variable.
    static let defaultFallback = ["/usr/local/lib", "/usr/lib"]

    /// Layers, lowest to highest priority: inherited `base` → mgx defaults → backend → game override →
    /// bottle → `--env`. `WINEDLLOVERRIDES` is merged entry by entry across all layers rather than
    /// replaced, and `WINEPREFIX` always points at the bottle.
    public static func build(base: [String: String], spec: EnvironmentSpec) -> [String: String] {
        var env = base
        // Variables from another Wine setup in the user's shell would silently redirect the run.
        for k in ["WINEPREFIX", "WINELOADER", "WINESERVER", "WINEDLLPATH", "WINEARCH"] { env[k] = nil }

        var overrides = spec.dllOverrides
        if let inherited = env["WINEDLLOVERRIDES"] { overrides = overrides.merging(DLLOverrides(parsing: inherited)) }

        if spec.msync { env["WINEMSYNC"] = "1" } else { env["WINEMSYNC"] = nil }
        if spec.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if let dbg = spec.wineDebug { env["WINEDEBUG"] = dbg } else if env["WINEDEBUG"] == nil { env["WINEDEBUG"] = "-all" }

        let libDirs = spec.libraryDirs.map(\.path) + [spec.wineRoot.appendingPathComponent("lib").path]
        let existing = (env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "").split(separator: ":").map(String.init)
        env["DYLD_FALLBACK_LIBRARY_PATH"] = unique(libDirs + (existing.isEmpty ? defaultFallback : existing)).joined(separator: ":")

        for layer in [spec.backendEnv, spec.gameEnv, spec.bottleEnv, spec.cliEnv] {
            for (k, v) in layer {
                if k == "WINEDLLOVERRIDES" {
                    overrides = overrides.merging(DLLOverrides(parsing: v))
                } else {
                    env[k] = v
                }
            }
        }

        env["WINEDLLOVERRIDES"] = overrides.isEmpty ? nil : overrides.description
        env["WINEPREFIX"] = spec.prefix.path
        return env
    }

    static func unique(_ xs: [String]) -> [String] {
        var seen = Set<String>()
        return xs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Parses `KEY=VALUE` strings from the command line.
    public static func parseAssignments(_ items: [String]) throws -> [String: String] {
        var out: [String: String] = [:]
        for item in items {
            guard let eq = item.firstIndex(of: "="), eq != item.startIndex else {
                throw MGError.invalidConfig("expected KEY=VALUE, got '\(item)'")
            }
            out[String(item[..<eq])] = String(item[item.index(after: eq)...])
        }
        return out
    }
}
