import XCTest
@testable import MGCore

final class LogTailTests: XCTestCase {
    func append(_ url: URL, _ bytes: [UInt8]) throws {
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(bytes))
    }

    func testFollowsAppends() throws {
        let sb = try Sandbox()
        let url = sb.root.appendingPathComponent("run.log")
        var tail = LogTail(url: url)
        XCTAssertTrue(tail.poll().missing)
        try append(url, Array("one\n".utf8))
        XCTAssertEqual(tail.poll(), .init(text: "one\n", reset: false, missing: false))
        XCTAssertEqual(tail.poll().text, "")
        try append(url, Array("two\n".utf8))
        XCTAssertEqual(tail.poll().text, "two\n")
        XCTAssertEqual(tail.offset, 8)
    }

    func testHoldsBackSplitUTF8() throws {
        let sb = try Sandbox()
        let url = sb.root.appendingPathComponent("run.log")
        let e = Array("é€😀".utf8) // 2 + 3 + 4 bytes
        var tail = LogTail(url: url)
        try append(url, [UInt8(ascii: "a")] + e.prefix(1))
        XCTAssertEqual(tail.poll().text, "a")
        try append(url, Array(e[1..<4]))
        XCTAssertEqual(tail.poll().text, "é", "the € is still incomplete")
        try append(url, Array(e[4..<7]))
        XCTAssertEqual(tail.poll().text, "€")
        try append(url, Array(e[7...]))
        XCTAssertEqual(tail.poll().text, "😀")
    }

    func testMaxBytesAndTailStart() throws {
        let sb = try Sandbox()
        let url = sb.root.appendingPathComponent("run.log")
        try append(url, Array("0123456789".utf8))
        var tail = LogTail(url: url)
        XCTAssertEqual(tail.poll(maxBytes: 4).text, "0123")
        XCTAssertEqual(tail.poll(maxBytes: 4).text, "4567")
        XCTAssertEqual(tail.poll().text, "89")
        var end = LogTail(url: url, tailBytes: 3)
        XCTAssertEqual(end.poll().text, "789")
        var all = LogTail(url: url, tailBytes: 100)
        XCTAssertEqual(all.poll().text, "0123456789")
    }

    func testTruncationResets() throws {
        let sb = try Sandbox()
        let url = sb.root.appendingPathComponent("run.log")
        try append(url, Array("long first run\n".utf8))
        var tail = LogTail(url: url)
        _ = tail.poll()
        try Data("new\n".utf8).write(to: url)
        XCTAssertEqual(tail.poll(), .init(text: "new\n", reset: true, missing: false))
    }

    func testIncompleteSuffixLength() {
        XCTAssertEqual(LogTail.incompleteSuffixLength([]), 0)
        XCTAssertEqual(LogTail.incompleteSuffixLength(Array("ab".utf8)), 0)
        XCTAssertEqual(LogTail.incompleteSuffixLength([0xE2, 0x82]), 2)
        XCTAssertEqual(LogTail.incompleteSuffixLength([0xE2, 0x82, 0xAC]), 0)
        XCTAssertEqual(LogTail.incompleteSuffixLength([0x80, 0x80, 0x80, 0x80]), 0, "stray continuation bytes are not held")
    }

    func testArgumentSplitter() throws {
        XCTAssertEqual(try ArgumentSplitter.split(""), [])
        XCTAssertEqual(try ArgumentSplitter.split("  -windowed   -w 1920 "), ["-windowed", "-w", "1920"])
        XCTAssertEqual(try ArgumentSplitter.split(#"-name "My Game" 'a "b"' c\ d"#), ["-name", "My Game", #"a "b""#, "c d"])
        XCTAssertEqual(try ArgumentSplitter.split(#"x"" "" '' "a\"b""#), ["x", "", "", #"a"b"#])
        XCTAssertEqual(try ArgumentSplitter.split(#"C:\Games\x.exe"#), [#"C:Gamesx.exe"#], "backslash escapes outside quotes, like sh")
        XCTAssertEqual(try ArgumentSplitter.split(#"'C:\Games\x.exe'"#), [#"C:\Games\x.exe"#])
        XCTAssertThrowsError(try ArgumentSplitter.split(#"-a "open"#))
    }
}
