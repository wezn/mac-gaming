import Foundation

/// A parsed `WINEDLLOVERRIDES` value: `d3d11,dxgi=n,b;d3d12=b;mscoree=`.
public struct DLLOverrides: Equatable, Sendable, CustomStringConvertible {
    /// DLL base name (lower-case, no `.dll`) → load order (`n,b`, `b`, `n`, or empty to disable).
    public private(set) var entries: [String: String] = [:]

    public init() {}

    public init(_ entries: [String: String]) {
        for (k, v) in entries { set(k, v) }
    }

    public init(parsing value: String) {
        for part in value.split(separator: ";", omittingEmptySubsequences: true) {
            let s = String(part)
            let names: Substring, mode: String
            if let eq = s.firstIndex(of: "=") {
                names = s[..<eq]
                mode = String(s[s.index(after: eq)...])
            } else {
                names = Substring(s)
                mode = ""
            }
            for n in names.split(separator: ",") { set(String(n), mode) }
        }
    }

    static func normalize(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if n.hasSuffix(".dll") { n.removeLast(4) }
        return n
    }

    public mutating func set(_ name: String, _ mode: String) {
        let n = DLLOverrides.normalize(name)
        guard !n.isEmpty else { return }
        entries[n] = mode.replacingOccurrences(of: " ", with: "")
    }

    public mutating func set(_ names: [String], _ mode: String) {
        for n in names { set(n, mode) }
    }

    /// Entries from `other` win.
    public func merging(_ other: DLLOverrides) -> DLLOverrides {
        var out = self
        for (k, v) in other.entries { out.entries[k] = v }
        return out
    }

    public subscript(name: String) -> String? { entries[DLLOverrides.normalize(name)] }

    public var isEmpty: Bool { entries.isEmpty }

    /// Deterministic: groups names by mode, modes and names sorted.
    public var description: String {
        Dictionary(grouping: entries, by: \.value)
            .map { mode, items in items.map(\.key).sorted().joined(separator: ",") + "=" + mode }
            .sorted()
            .joined(separator: ";")
    }
}
