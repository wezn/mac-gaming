import Foundation

/// What is installed and usable for a given runtime.
public struct BackendAvailability: Equatable, Sendable {
    public var dxmt: Bool
    public var dxvk: Bool
    /// dxvk ships d3d8.dll (DXVK 2.4+).
    public var dxvkD3D8: Bool
    public var d3dmetal: Bool

    public init(dxmt: Bool = false, dxvk: Bool = false, dxvkD3D8: Bool = false, d3dmetal: Bool = false) {
        self.dxmt = dxmt
        self.dxvk = dxvk
        self.dxvkD3D8 = dxvkD3D8
        self.d3dmetal = d3dmetal
    }

    public func has(_ b: Backend) -> Bool {
        switch b {
        case .auto, .wined3d: return true
        case .dxmt: return dxmt
        case .dxvk: return dxvk
        case .d3dmetal: return d3dmetal
        }
    }
}

public struct BackendChoice: Equatable, Sendable {
    /// Never `.auto`.
    public var backend: Backend
    public var reason: String
    public var warnings: [String]

    public init(backend: Backend, reason: String, warnings: [String] = []) {
        self.backend = backend
        self.reason = reason
        self.warnings = warnings
    }
}

public enum BackendSelector {
    /// Precedence: `--backend` > per-game override > bottle default > auto-detection.
    ///
    /// Auto policy (see docs/PLAN.md):
    /// - DX12 → D3DMetal, else an error (nothing else runs DX12 on macOS yet).
    /// - DX11/DX10 → DXMT, then D3DMetal, then DXVK, then wined3d.
    /// - DX9 → DXVK, then wined3d. DX8 → DXVK if it ships d3d8, then wined3d.
    /// - DX7 and older, or nothing detected → wined3d.
    public static func select(requested: Backend?, override: GameOverride?, bottleBackend: Backend,
                              detection: DirectXDetection, available: BackendAvailability,
                              executableName: String) throws -> BackendChoice {
        let explicit: (Backend, String)? = {
            if let r = requested, r != .auto { return (r, "requested with --backend") }
            if let o = override?.backend, o != .auto { return (o, "per-game override for \(executableName)") }
            if bottleBackend != .auto { return (bottleBackend, "bottle default") }
            return nil
        }()
        if let (b, why) = explicit {
            guard available.has(b) else { throw MGError.backendUnavailable(b, hint(for: b)) }
            return BackendChoice(backend: b, reason: why)
        }

        var detection = detection
        if let dx = override?.dx {
            detection = DirectXDetection(level: dx, source: .override, evidence: "per-game override says \(dx)")
        }
        let why = detection.evidence.map { "auto: \($0)" } ?? "auto"

        switch detection.level {
        case .dx12:
            guard available.d3dmetal else { throw MGError.dx12NeedsD3DMetal(executableName) }
            return BackendChoice(backend: .d3dmetal, reason: why)
        case .dx11, .dx10:
            if available.dxmt { return BackendChoice(backend: .dxmt, reason: why) }
            if available.d3dmetal {
                return BackendChoice(backend: .d3dmetal, reason: why, warnings: ["DXMT is not installed; using D3DMetal"])
            }
            if available.dxvk {
                return BackendChoice(backend: .dxvk, reason: why, warnings: ["DXMT and D3DMetal are unavailable; using DXVK"])
            }
            return BackendChoice(backend: .wined3d, reason: why,
                                 warnings: ["no DX10/11 backend is installed; falling back to wined3d (slow). Install DXMT with `mgx runtime install dxmt-*.tar.xz`"])
        case .dx9:
            if available.dxvk { return BackendChoice(backend: .dxvk, reason: why) }
            return BackendChoice(backend: .wined3d, reason: why, warnings: ["DXVK is not installed; using wined3d"])
        case .dx8:
            if available.dxvk && available.dxvkD3D8 { return BackendChoice(backend: .dxvk, reason: why) }
            return BackendChoice(backend: .wined3d, reason: why)
        case .dx7:
            return BackendChoice(backend: .wined3d, reason: why)
        case .none:
            return BackendChoice(backend: .wined3d, reason: why == "auto" ? "auto: no DirectX imports found" : why,
                                 warnings: detection.source == .none && detection.evidence != nil
                                    ? ["no Direct3D imports found; using wined3d. Launchers (Steam, Battle.net) pass their environment to games, so set the bottle's backend with `mgx bottle set <name> --backend ...`"]
                                    : [])
        }
    }

    static func hint(for b: Backend) -> String {
        switch b {
        case .d3dmetal:
            return "point mgx at your Game Porting Toolkit with `mgx config set gptk <path>` (D3DMetal cannot be bundled)"
        case .dxmt:
            return "install it into the runtime with `mgx runtime install dxmt-<version>.tar.xz`"
        case .dxvk:
            return "install it into the runtime with `mgx runtime install dxvk-macos-<version>.tar.xz`"
        case .auto, .wined3d:
            return "always available"
        }
    }
}
