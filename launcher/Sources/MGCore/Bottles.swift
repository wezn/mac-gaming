import Foundation

/// A Wine prefix plus its config. The bottle directory *is* the prefix (`WINEPREFIX`);
/// `bottle.json` and `.mg-state.json` sit next to `drive_c` and Wine ignores them.
public struct Bottle: Equatable, Sendable {
    public var config: BottleConfig
    public var root: URL

    public var name: String { config.name }
    public var prefix: URL { root }
    public var configFile: URL { root.appendingPathComponent("bottle.json") }
    var stateFile: URL { root.appendingPathComponent(".mg-state.json") }

    /// wineboot has populated the prefix.
    public var isInitialized: Bool {
        FileManager.default.fileExists(atPath: BackendFiles.system32(prefix).path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("system.reg").path)
    }

    /// `C:\...` path → path on disk inside this prefix (for checking what a launcher installed).
    public func unixPath(forWindowsPath path: String) -> URL? {
        let p = path.replacingOccurrences(of: "\\", with: "/")
        guard p.count >= 3, p.dropFirst().hasPrefix(":/"), let drive = p.first?.lowercased() else { return nil }
        return root.appendingPathComponent("drive_\(drive)").appendingPathComponent(String(p.dropFirst(3)))
    }
}

/// Things mg has applied to the prefix (so repeat launches skip them).
struct BottleState: Codable, Equatable {
    var retinaApplied: Bool?
}

public struct BottleStore {
    public let paths: MGPaths
    let fm = FileManager.default

    public init(paths: MGPaths) {
        self.paths = paths
    }

    public func create(_ config: BottleConfig) throws -> Bottle {
        try Names.validate(config.name)
        let root = paths.bottle(config.name)
        if fm.fileExists(atPath: root.path) { throw MGError.bottleExists(config.name) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var config = config
        if config.created == nil { config.created = Date() }
        let bottle = Bottle(config: config, root: root)
        try save(bottle)
        return bottle
    }

    public func get(_ name: String) throws -> Bottle {
        try Names.validate(name)
        let root = paths.bottle(name)
        let file = root.appendingPathComponent("bottle.json")
        guard fm.fileExists(atPath: file.path) else { throw MGError.bottleNotFound(name) }
        var config = try JSONFile.load(BottleConfig.self, from: file)
        config.name = name // the directory name is authoritative
        return Bottle(config: config, root: root)
    }

    public func exists(_ name: String) -> Bool {
        fm.fileExists(atPath: paths.bottle(name).appendingPathComponent("bottle.json").path)
    }

    /// Bottles that load; broken configs are reported separately so one bad file doesn't hide the rest.
    public func list() -> (bottles: [Bottle], errors: [String: String]) {
        var bottles: [Bottle] = [], errors: [String: String] = [:]
        for name in ((try? fm.contentsOfDirectory(atPath: paths.bottles.path)) ?? []).sorted() where !name.hasPrefix(".") {
            guard fm.fileExists(atPath: paths.bottle(name).appendingPathComponent("bottle.json").path) else { continue }
            do { bottles.append(try get(name)) } catch { errors[name] = "\(error)" }
        }
        return (bottles, errors)
    }

    public func save(_ bottle: Bottle) throws {
        try JSONFile.save(bottle.config, to: bottle.configFile)
    }

    public func delete(_ name: String) throws {
        let b = try get(name)
        try fm.removeItem(at: b.root)
        var config = try GlobalConfig.load(paths)
        if config.defaultBottle == name {
            config.defaultBottle = nil
            try config.save(paths)
        }
    }

    func state(_ b: Bottle) -> BottleState {
        (try? JSONFile.loadIfPresent(BottleState.self, from: b.stateFile)) ?? BottleState()
    }

    func saveState(_ s: BottleState, _ b: Bottle) throws {
        try JSONFile.save(s, to: b.stateFile)
    }
}
