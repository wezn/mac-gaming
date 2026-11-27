import Foundation

/// Per-game settings keyed by executable file name (case-insensitive).
public struct GameOverride: Codable, Equatable, Sendable {
    /// Force a backend for this game.
    public var backend: Backend?
    /// Treat the game as this DirectX level when `auto` picks a backend (for engines that
    /// load their renderer at run time and so import nothing).
    public var dx: DirectXLevel?
    public var env: [String: String]?
    public var retina: Bool?
    public var msync: Bool?
    /// Free-form note shown by `mg run --dry-run`.
    public var note: String?

    public init(backend: Backend? = nil, dx: DirectXLevel? = nil, env: [String: String]? = nil,
                retina: Bool? = nil, msync: Bool? = nil, note: String? = nil) {
        self.backend = backend
        self.dx = dx
        self.env = env
        self.retina = retina
        self.msync = msync
        self.note = note
    }
}

/// `overrides.json`: `{ "games": { "Overwatch.exe": { "backend": "d3dmetal" } } }`.
public struct GameOverrideTable: Codable, Equatable, Sendable {
    public var games: [String: GameOverride]

    public init(games: [String: GameOverride] = [:]) {
        self.games = games
    }

    /// Shipped defaults. User entries replace these per game.
    public static let builtIn = GameOverrideTable(games: [
        "overwatch.exe": GameOverride(backend: .d3dmetal,
                                      note: "CodeWeavers rates Overwatch 2 'Runs Well' on D3DMetal"),
        "cs2.exe": GameOverride(dx: .dx11,
                                note: "Source 2 loads its renderer at run time; cs2.exe itself imports no Direct3D DLL"),
    ])

    public func lookup(executable name: String) -> GameOverride? {
        let key = name.lowercased()
        return games.first { $0.key.lowercased() == key }?.value
    }

    /// Built-in table with the user's file layered on top.
    public static func load(_ paths: MGPaths) throws -> GameOverrideTable {
        var table = builtIn
        if let user = try JSONFile.loadIfPresent(GameOverrideTable.self, from: paths.overridesFile) {
            for (k, v) in user.games {
                table.games[k.lowercased()] = v
            }
        }
        return table
    }
}
