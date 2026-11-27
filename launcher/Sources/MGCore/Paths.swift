import Foundation

/// On-disk layout. Everything lives under one root so a GUI and the CLI share state.
///
///     <root>/config.json            global settings (default runtime, GPTK path)
///     <root>/overrides.json         per-game overrides, merged over the built-in table
///     <root>/runtimes/<name>/       wine/, dxmt/, dxvk/, runtime.json
///     <root>/bottles/<name>/        the Wine prefix itself, plus bottle.json
///     <root>/logs/<bottle>/         one log file per run
///     <root>/cache/                 downloaded installers
public struct MGPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// `MG_HOME` overrides the default root (used by tests and CI).
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> MGPaths {
        if let home = environment["MG_HOME"], !home.isEmpty {
            return MGPaths(root: URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return MGPaths(root: home.appendingPathComponent("Library/Application Support/mac-gaming", isDirectory: true))
        #else
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return MGPaths(root: URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("mac-gaming", isDirectory: true))
        }
        return MGPaths(root: home.appendingPathComponent(".local/share/mac-gaming", isDirectory: true))
        #endif
    }

    public var configFile: URL { root.appendingPathComponent("config.json") }
    public var overridesFile: URL { root.appendingPathComponent("overrides.json") }
    public var runtimes: URL { root.appendingPathComponent("runtimes", isDirectory: true) }
    public var bottles: URL { root.appendingPathComponent("bottles", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }

    public func runtime(_ name: String) -> URL { runtimes.appendingPathComponent(name, isDirectory: true) }
    public func bottle(_ name: String) -> URL { bottles.appendingPathComponent(name, isDirectory: true) }
}
