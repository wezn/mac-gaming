import Foundation

/// One log file per run: `logs/<bottle>/<yyyyMMdd-HHmmss>-<exe>.log`.
public struct LogStore {
    public let paths: MGPaths
    /// Older logs beyond this count (per bottle) are pruned when a new one is created.
    public var keepPerBottle = 50

    public init(paths: MGPaths) {
        self.paths = paths
    }

    public struct Entry: Equatable, Sendable {
        public var bottle: String
        public var url: URL
        public var modified: Date
        public var size: Int
    }

    static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    public func newLogFile(bottle: String, executable: String, date: Date = Date()) -> URL {
        let safe = String(executable.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" }.prefix(80))
        let dir = paths.logs.appendingPathComponent(bottle, isDirectory: true)
        var url = dir.appendingPathComponent("\(LogStore.stampFormat.string(from: date))-\(safe).log")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(LogStore.stampFormat.string(from: date))-\(safe)-\(n).log")
            n += 1
        }
        return url
    }

    /// Newest first.
    public func list(bottle: String? = nil) -> [Entry] {
        let fm = FileManager.default
        let bottles = bottle.map { [$0] } ?? ((try? fm.contentsOfDirectory(atPath: paths.logs.path)) ?? [])
        var out: [Entry] = []
        for b in bottles {
            let dir = paths.logs.appendingPathComponent(b, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".log") {
                let url = dir.appendingPathComponent(name)
                let a = try? fm.attributesOfItem(atPath: url.path)
                out.append(Entry(bottle: b, url: url,
                                 modified: a?[.modificationDate] as? Date ?? .distantPast,
                                 size: (a?[.size] as? NSNumber)?.intValue ?? 0))
            }
        }
        return out.sorted { ($0.modified, $0.url.lastPathComponent) > ($1.modified, $1.url.lastPathComponent) }
    }

    public func prune(bottle: String) {
        for e in list(bottle: bottle).dropFirst(keepPerBottle) { try? FileManager.default.removeItem(at: e.url) }
    }
}
