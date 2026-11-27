import Foundation

public struct DirectXDetection: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        /// The executable imports a Direct3D DLL.
        case executable
        /// The executable imports nothing Direct3D-related, but a DLL next to it does
        /// (engines that load their renderer at run time, e.g. Source 2's rendersystemdx11.dll).
        case siblingDLL
        /// Set by the per-game override table.
        case override
        /// Nothing found (or not a file on disk, e.g. `notepad.exe` or a `C:\` path).
        case none
    }

    public var level: DirectXLevel
    public var source: Source
    /// Human-readable reason, e.g. "Game.exe imports d3d11.dll".
    public var evidence: String?
    public var is64Bit: Bool?

    public init(level: DirectXLevel, source: Source, evidence: String? = nil, is64Bit: Bool? = nil) {
        self.level = level
        self.source = source
        self.evidence = evidence
        self.is64Bit = is64Bit
    }

    public static let unknown = DirectXDetection(level: .none, source: .none)
}

public enum DirectXDetector {
    /// Import name → Direct3D level. dxgi on its own implies at least D3D10/11; treat as 11.
    public static let dllLevels: [String: DirectXLevel] = [
        "d3d12.dll": .dx12, "d3d12core.dll": .dx12,
        "d3d11.dll": .dx11, "d3d11on12.dll": .dx11, "dxgi.dll": .dx11,
        "d3d10.dll": .dx10, "d3d10_1.dll": .dx10, "d3d10core.dll": .dx10, "d3d10_1core.dll": .dx10,
        "d3d9.dll": .dx9,
        "d3d8.dll": .dx8,
        "ddraw.dll": .dx7, "d3dim.dll": .dx7, "d3dim700.dll": .dx7,
    ]

    /// Highest Direct3D level among `imports` (lower-case DLL names), with the DLL that decided it.
    public static func level(forImports imports: Set<String>) -> (DirectXLevel, String?) {
        var best: (DirectXLevel, String?) = (.none, nil)
        for dll in imports.sorted() {
            if let l = dllLevels[dll], l > best.0 { best = (l, dll) }
        }
        return best
    }

    /// Bound on how many neighbouring DLLs get opened when the executable itself is inconclusive.
    public static let maxSiblingDLLs = 256

    public static func detect(executable: URL, scanSiblings: Bool = true) -> DirectXDetection {
        let exeName = executable.lastPathComponent
        guard let pe = try? PEParser.parse(contentsOf: executable) else {
            return DirectXDetection(level: .none, source: .none, evidence: "\(exeName) is not a readable PE file")
        }
        let (level, dll) = level(forImports: pe.allLowercased)
        if level != .none {
            return DirectXDetection(level: level, source: .executable, evidence: "\(exeName) imports \(dll!)", is64Bit: pe.is64Bit)
        }
        guard scanSiblings else {
            return DirectXDetection(level: .none, source: .none, evidence: "\(exeName) imports no Direct3D DLL", is64Bit: pe.is64Bit)
        }

        let dir = executable.deletingLastPathComponent()
        let siblings = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".dll") && dllLevels[$0.lowercased()] == nil }
            .sorted()
            .prefix(maxSiblingDLLs)
        var best: (DirectXLevel, String) = (.none, "")
        for name in siblings {
            guard let sib = try? PEParser.parse(contentsOf: dir.appendingPathComponent(name)),
                  sib.is64Bit == pe.is64Bit else { continue }
            let (l, d) = self.level(forImports: sib.allLowercased)
            if l > best.0 { best = (l, "\(name) imports \(d!)") }
        }
        if best.0 != .none {
            return DirectXDetection(level: best.0, source: .siblingDLL, evidence: best.1, is64Bit: pe.is64Bit)
        }
        return DirectXDetection(level: .none, source: .none, evidence: "\(exeName) imports no Direct3D DLL", is64Bit: pe.is64Bit)
    }
}
