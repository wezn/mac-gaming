import Foundation

/// Follows a growing log file: each `poll` returns what was appended since the previous one.
///
/// A multi-byte UTF-8 character split across two polls is held back until it is complete. If the
/// file shrinks (truncated or replaced), reading starts over from the beginning and `reset` is true.
public struct LogTail: Sendable {
    public let url: URL
    /// Bytes consumed so far (including held-back partial characters).
    public private(set) var offset: UInt64
    private var pending: [UInt8] = []

    /// `tailBytes`: on the first poll, skip to the last `tailBytes` of an existing file (nil reads it all).
    public init(url: URL, tailBytes: Int? = nil) {
        self.url = url
        if let n = tailBytes, let size = LogTail.size(of: url), size > UInt64(n) {
            offset = size - UInt64(n)
        } else {
            offset = 0
        }
    }

    static func size(of url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    public struct Chunk: Equatable, Sendable {
        public var text: String
        /// The file was truncated or replaced: discard what was shown before `text`.
        public var reset: Bool
        /// The file does not exist (yet).
        public var missing: Bool
    }

    /// Reads up to `maxBytes` of new data.
    public mutating func poll(maxBytes: Int = 1 << 20) -> Chunk {
        guard let size = LogTail.size(of: url) else { return Chunk(text: "", reset: false, missing: true) }
        var reset = false
        if size < offset {
            offset = 0
            pending = []
            reset = true
        }
        guard size > offset, let h = try? FileHandle(forReadingFrom: url) else {
            return Chunk(text: "", reset: reset, missing: false)
        }
        defer { try? h.close() }
        let data: Data
        do {
            try h.seek(toOffset: offset)
            data = try h.read(upToCount: Int(min(UInt64(maxBytes), size - offset))) ?? Data()
        } catch {
            return Chunk(text: "", reset: reset, missing: false)
        }
        offset += UInt64(data.count)
        var bytes = pending + data
        let keep = LogTail.incompleteSuffixLength(bytes)
        pending = Array(bytes.suffix(keep))
        bytes.removeLast(keep)
        return Chunk(text: String(decoding: bytes, as: UTF8.self), reset: reset, missing: false)
    }

    /// Length of a trailing UTF-8 sequence that is cut short (0 if the bytes end on a character boundary).
    static func incompleteSuffixLength(_ b: [UInt8]) -> Int {
        // Walk back over at most 3 continuation bytes to the lead byte.
        var i = b.count - 1
        var continuation = 0
        while i >= 0, b[i] & 0xC0 == 0x80, continuation < 3 {
            continuation += 1
            i -= 1
        }
        guard i >= 0 else { return 0 }
        let lead = b[i]
        let needed: Int
        switch lead {
        case 0xC0...0xDF: needed = 2
        case 0xE0...0xEF: needed = 3
        case 0xF0...0xF7: needed = 4
        default: return 0 // ASCII or invalid: nothing to wait for
        }
        let have = continuation + 1
        return have < needed ? have : 0
    }
}

/// Splits a user-typed argument string the way a POSIX shell would for words and quotes, without
/// expanding anything: `-w "My Game" 'a b' c\ d` → `["-w", "My Game", "a b", "c d"]`.
public enum ArgumentSplitter {
    public static func split(_ s: String) throws -> [String] {
        var out: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escape = false
        for c in s {
            if escape {
                word.append(c); escape = false; inWord = true
                continue
            }
            if let q = quote {
                if c == q { quote = nil }
                else if c == "\\" && q == "\"" { escape = true }
                else { word.append(c) }
                continue
            }
            switch c {
            case "\\": escape = true; inWord = true
            case "\"", "'": quote = c; inWord = true
            case " ", "\t", "\n":
                if inWord { out.append(word); word = ""; inWord = false }
            default:
                word.append(c); inWord = true
            }
        }
        if quote != nil { throw MGError.invalidConfig("unterminated quote in arguments") }
        if escape { word.append("\\") }
        if inWord { out.append(word) }
        return out
    }
}
