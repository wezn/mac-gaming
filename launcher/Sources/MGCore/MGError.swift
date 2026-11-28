import Foundation

/// Errors MGCore reports to a front end. `description` is meant to be shown to the user as is.
public enum MGError: Error, CustomStringConvertible, Equatable {
    case invalidName(String)
    case bottleExists(String)
    case bottleNotFound(String)
    case runtimeNotFound(String)
    case noRuntime
    case ambiguousRuntime([String])
    case backendUnavailable(Backend, String)
    case dx12NeedsD3DMetal(String)
    case invalidArchive(String)
    case invalidConfig(String)
    case processFailed(String, Int32)
    case io(String)
    /// Fetching, verifying or installing an update.
    case update(String)

    public var description: String {
        switch self {
        case .invalidName(let n):
            return "invalid name '\(n)': use letters, digits, '.', '_' or '-' (max 64 characters, no leading '.' or '-')"
        case .bottleExists(let n):
            return "bottle '\(n)' already exists"
        case .bottleNotFound(let n):
            return "bottle '\(n)' does not exist (create it with `mgx bottle create \(n)`)"
        case .runtimeNotFound(let n):
            return "runtime '\(n)' is not installed (see `mgx runtime list`)"
        case .noRuntime:
            return "no runtime installed: run `mgx runtime update` to download one, or `mgx runtime install <wine-crossover-*.tar.xz | dir>`"
        case .ambiguousRuntime(let names):
            return "several runtimes are installed (\(names.joined(separator: ", "))): pick one with `mgx config set default-runtime <name>` or `--runtime`"
        case .backendUnavailable(let b, let hint):
            return "backend '\(b.rawValue)' is not available: \(hint)"
        case .dx12NeedsD3DMetal(let exe):
            return "\(exe) uses DirectX 12, which needs D3DMetal. D3DMetal cannot be redistributed: install Apple's Game Porting Toolkit and run `mgx config set gptk <path-to-gptk>`, or force another backend with --backend"
        case .invalidArchive(let m):
            return m
        case .invalidConfig(let m):
            return m
        case .processFailed(let what, let code):
            return "\(what) failed with exit code \(code)"
        case .io(let m), .update(let m):
            return m
        }
    }
}

public enum Names {
    /// Bottle and runtime names become directory names, so keep them boring.
    public static func validate(_ name: String) throws {
        let ok = !name.isEmpty && name.count <= 64
            && name.first.map { $0.isLetter || $0.isNumber } == true
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
        if !ok { throw MGError.invalidName(name) }
    }

    public static func isValid(_ name: String) -> Bool { (try? validate(name)) != nil }
}
