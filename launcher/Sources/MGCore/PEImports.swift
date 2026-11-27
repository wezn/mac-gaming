import Foundation

public enum PEError: Error, Equatable, CustomStringConvertible {
    case notPE(String)
    case truncated(String)

    public var description: String {
        switch self {
        case .notPE(let m): return "not a PE file: \(m)"
        case .truncated(let m): return "truncated PE file: \(m)"
        }
    }
}

/// DLL names a PE image imports, read straight from the import and delay-import directories.
public struct PEImports: Equatable, Sendable {
    public var machine: UInt16
    public var is64Bit: Bool
    /// As written in the file (case preserved), in table order.
    public var imports: [String]
    public var delayImports: [String]

    /// Lower-cased union of normal and delay-load imports.
    public var allLowercased: Set<String> {
        Set((imports + delayImports).map { $0.lowercased() })
    }
}

/// Minimal, allocation-light PE reader. It only touches the headers, the section table and the
/// import descriptors, so memory-mapping a multi-gigabyte game executable stays cheap.
public enum PEParser {
    static let maxDescriptors = 4096
    static let maxNameLength = 260

    public static func parse(contentsOf url: URL) throws -> PEImports {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> PEImports {
        try data.withUnsafeBytes { raw in try parse(Reader(raw)) }
    }

    struct Reader {
        let buf: UnsafeRawBufferPointer
        init(_ buf: UnsafeRawBufferPointer) { self.buf = buf }
        var count: Int { buf.count }

        func has(_ off: Int, _ len: Int) -> Bool { off >= 0 && len >= 0 && off <= buf.count - len }

        func u16(_ off: Int) throws -> UInt16 {
            guard has(off, 2) else { throw PEError.truncated("read past end at \(off)") }
            return UInt16(buf[off]) | UInt16(buf[off + 1]) << 8
        }

        func u32(_ off: Int) throws -> UInt32 {
            guard has(off, 4) else { throw PEError.truncated("read past end at \(off)") }
            return UInt32(buf[off]) | UInt32(buf[off + 1]) << 8 | UInt32(buf[off + 2]) << 16 | UInt32(buf[off + 3]) << 24
        }

        func u64(_ off: Int) throws -> UInt64 {
            UInt64(try u32(off)) | UInt64(try u32(off + 4)) << 32
        }

        func cString(_ off: Int, max: Int) -> String? {
            guard has(off, 1) else { return nil }
            var end = off
            let limit = Swift.min(buf.count, off + max)
            while end < limit, buf[end] != 0 { end += 1 }
            guard end < limit || end == buf.count, end > off else { return nil }
            return String(decoding: UnsafeRawBufferPointer(rebasing: buf[off..<end]), as: UTF8.self)
        }
    }

    struct Section { let va: UInt32, vsize: UInt32, rawPtr: UInt32, rawSize: UInt32 }

    static func parse(_ r: Reader) throws -> PEImports {
        guard r.count >= 0x40 else { throw PEError.notPE("file is smaller than a DOS header") }
        guard try r.u16(0) == 0x5A4D else { throw PEError.notPE("missing MZ signature") }
        let peOff = Int(try r.u32(0x3C))
        guard r.has(peOff, 24) else { throw PEError.truncated("PE header offset \(peOff) is outside the file") }
        guard try r.u32(peOff) == 0x0000_4550 else { throw PEError.notPE("missing PE signature") }

        let coff = peOff + 4
        let machine = try r.u16(coff)
        let sectionCount = Int(try r.u16(coff + 2))
        let optSize = Int(try r.u16(coff + 16))
        let opt = coff + 20
        guard optSize >= 2, r.has(opt, optSize) else { throw PEError.truncated("optional header") }

        let magic = try r.u16(opt)
        let is64: Bool
        let dirOff: Int, rvaCountOff: Int
        let imageBase: UInt64
        switch magic {
        case 0x10B: is64 = false; dirOff = opt + 96; rvaCountOff = opt + 92; imageBase = UInt64(try r.u32(opt + 28))
        case 0x20B: is64 = true; dirOff = opt + 112; rvaCountOff = opt + 108; imageBase = try r.u64(opt + 24)
        default: throw PEError.notPE(String(format: "unknown optional header magic 0x%04x", magic))
        }
        guard rvaCountOff + 4 <= opt + optSize else { throw PEError.truncated("optional header has no data directories") }
        let rvaCount = min(Int(try r.u32(rvaCountOff)), 16, max(0, (opt + optSize - dirOff) / 8))

        var sections: [Section] = []
        let secTable = opt + optSize
        guard r.has(secTable, sectionCount * 40) else { throw PEError.truncated("section table") }
        sections.reserveCapacity(sectionCount)
        for i in 0..<sectionCount {
            let s = secTable + i * 40
            sections.append(Section(va: try r.u32(s + 12), vsize: try r.u32(s + 8),
                                    rawPtr: try r.u32(s + 20), rawSize: try r.u32(s + 16)))
        }

        func offset(ofRVA rva: UInt32) -> Int? {
            for s in sections {
                let size = max(s.vsize, s.rawSize)
                if rva >= s.va, UInt64(rva) < UInt64(s.va) + UInt64(size) {
                    let delta = rva - s.va
                    guard delta < s.rawSize else { return nil } // lives in zero-filled (uninitialised) data
                    let off = Int(s.rawPtr) + Int(delta)
                    return r.has(off, 1) ? off : nil
                }
            }
            // Headers are mapped at RVA 0 unchanged.
            if let first = sections.map(\.va).min(), rva < first { return r.has(Int(rva), 1) ? Int(rva) : nil }
            return nil
        }

        func directory(_ index: Int) throws -> (rva: UInt32, size: UInt32)? {
            guard index < rvaCount else { return nil }
            let rva = try r.u32(dirOff + index * 8)
            let size = try r.u32(dirOff + index * 8 + 4)
            return rva == 0 ? nil : (rva, size)
        }

        func name(atRVA rva: UInt32) -> String? {
            guard rva != 0, let off = offset(ofRVA: rva) else { return nil }
            return r.cString(off, max: maxNameLength)
        }

        var imports: [String] = []
        if let dir = try directory(1), let start = offset(ofRVA: dir.rva) {
            for i in 0..<maxDescriptors {
                let d = start + i * 20
                guard r.has(d, 20) else { break }
                let nameRVA = try r.u32(d + 12)
                if nameRVA == 0 {
                    // Terminator is an all-zero descriptor; a zero name alone also ends a broken table.
                    break
                }
                if let n = name(atRVA: nameRVA) { imports.append(n) }
            }
        }

        var delay: [String] = []
        if let dir = try directory(13), let start = offset(ofRVA: dir.rva) {
            for i in 0..<maxDescriptors {
                let d = start + i * 32
                guard r.has(d, 32) else { break }
                let attributes = try r.u32(d)
                var nameRef = try r.u32(d + 4)
                if nameRef == 0 { break }
                // Old (VC6) delay-load descriptors hold virtual addresses instead of RVAs.
                if attributes & 1 == 0, !is64, UInt64(nameRef) >= imageBase {
                    nameRef = UInt32(truncatingIfNeeded: UInt64(nameRef) - imageBase)
                }
                if let n = name(atRVA: nameRef) { delay.append(n) }
            }
        }

        return PEImports(machine: machine, is64Bit: is64, imports: imports, delayImports: delay)
    }
}
