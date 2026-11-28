import Foundation

/// Graphics translation layer used for a run.
public enum Backend: String, Codable, CaseIterable, Sendable {
    /// Pick from the game's DirectX version.
    case auto
    /// Apple's D3DMetal from the user's own Game Porting Toolkit install (DX11/DX12).
    case d3dmetal
    /// DXMT: DX10/DX11 → Metal.
    case dxmt
    /// DXVK + MoltenVK: DX9/10/11 → Vulkan → Metal.
    case dxvk
    /// Wine's own wined3d (no DLL overrides).
    case wined3d
}

/// The newest Direct3D API an executable links against.
public enum DirectXLevel: Int, Codable, Comparable, CaseIterable, Sendable, CustomStringConvertible {
    case none = 0
    /// DirectDraw / Direct3D 7 and older.
    case dx7 = 7
    case dx8 = 8
    case dx9 = 9
    case dx10 = 10
    case dx11 = 11
    case dx12 = 12

    public static func < (a: DirectXLevel, b: DirectXLevel) -> Bool { a.rawValue < b.rawValue }

    public var description: String { self == .none ? "none" : "DirectX \(rawValue)" }

    /// Accepts 11, "11", "dx11" or "DX11" in JSON.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self), let v = DirectXLevel(rawValue: n) { self = v; return }
        let s = try c.decode(String.self).lowercased()
        let digits = s.hasPrefix("dx") ? String(s.dropFirst(2)) : s
        if s == "none" { self = .none; return }
        guard let n = Int(digits), let v = DirectXLevel(rawValue: n) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unknown DirectX level '\(s)'")
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// `bottles/<name>/bottle.json`. Missing keys fall back to defaults so old files keep loading.
public struct BottleConfig: Codable, Equatable, Sendable {
    public var name: String
    /// Runtime name; nil means the global default runtime.
    public var runtime: String?
    /// Default backend for this bottle. A launcher bottle (Steam, Battle.net) should set this,
    /// because games started by the launcher inherit the launcher's environment.
    public var backend: Backend
    /// Extra environment variables for every run in this bottle.
    public var env: [String: String]
    public var msync: Bool
    /// Wine mac driver Retina mode (full-resolution rendering on HiDPI displays).
    public var retina: Bool
    /// Apple's Metal performance HUD (MTL_HUD_ENABLED=1).
    public var metalHUD: Bool
    public var created: Date?

    public init(name: String, runtime: String? = nil, backend: Backend = .auto, env: [String: String] = [:],
                msync: Bool = true, retina: Bool = false, metalHUD: Bool = false, created: Date? = nil) {
        self.name = name
        self.runtime = runtime
        self.backend = backend
        self.env = env
        self.msync = msync
        self.retina = retina
        self.metalHUD = metalHUD
        self.created = created
    }

    enum CodingKeys: String, CodingKey { case name, runtime, backend, env, msync, retina, metalHUD, created }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime)
        backend = try c.decodeIfPresent(Backend.self, forKey: .backend) ?? .auto
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        msync = try c.decodeIfPresent(Bool.self, forKey: .msync) ?? true
        retina = try c.decodeIfPresent(Bool.self, forKey: .retina) ?? false
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        created = try c.decodeIfPresent(Date.self, forKey: .created)
    }
}

/// `config.json`.
public struct GlobalConfig: Codable, Equatable, Sendable {
    public var defaultRuntime: String?
    public var defaultBottle: String?
    /// Path to the user's Game Porting Toolkit (the folder holding `redist/lib`, the `lib` folder itself, or the app).
    public var gptkPath: String?
    /// Where updates come from (see `UpdateSource`); nil = this repository's GitHub releases.
    public var updateURL: String?

    public init(defaultRuntime: String? = nil, defaultBottle: String? = nil, gptkPath: String? = nil, updateURL: String? = nil) {
        self.defaultRuntime = defaultRuntime
        self.defaultBottle = defaultBottle
        self.gptkPath = gptkPath
        self.updateURL = updateURL
    }

    public static func load(_ paths: MGPaths) throws -> GlobalConfig {
        try JSONFile.loadIfPresent(GlobalConfig.self, from: paths.configFile) ?? GlobalConfig()
    }

    public func save(_ paths: MGPaths) throws {
        try JSONFile.save(self, to: paths.configFile)
    }
}
