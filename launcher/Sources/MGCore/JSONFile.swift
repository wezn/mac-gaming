import Foundation

enum JSONFile {
    static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw MGError.io("cannot read \(url.path): \(error.localizedDescription)")
        }
        do { return try decoder.decode(T.self, from: data) } catch {
            throw MGError.invalidConfig("\(url.path) is not valid: \(error)")
        }
    }

    static func loadIfPresent<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try load(type, from: url)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
