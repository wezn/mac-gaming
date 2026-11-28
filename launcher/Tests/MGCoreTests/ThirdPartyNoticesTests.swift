import Foundation
import XCTest
@testable import MGCore

final class ThirdPartyNoticesTests: XCTestCase {
    func testOnlineURLPointsAtTheVersionTag() {
        XCTAssertEqual(ThirdPartyNotices.onlineURL(version: "1.2.3").absoluteString,
                       "https://github.com/wezn/mac-gaming/blob/v1.2.3/THIRD_PARTY_NOTICES.md")
        XCTAssertTrue(ThirdPartyNotices.onlineURL().absoluteString.contains("/v\(MGVersion.string)/"))
    }

    func testCandidateOrder() {
        let c = ThirdPartyNotices.candidates(executable: URL(fileURLWithPath: "/nonexistent/Foo.app/Contents/MacOS/Foo"))
        XCTAssertEqual(c.map(\.path), [
            "/nonexistent/Foo.app/Contents/MacOS/THIRD_PARTY_NOTICES.md",
            "/nonexistent/Foo.app/Contents/Resources/THIRD_PARTY_NOTICES.md",
            "/nonexistent/Foo.app/Contents/share/mac-gaming/THIRD_PARTY_NOTICES.md",
        ])
    }

    func testFindsTheFileNextToTheBinary() throws {
        let s = try Sandbox()
        try s.write("dist/mgx", "bin", executable: true)
        try s.write("dist/THIRD_PARTY_NOTICES.md", "notices")
        let found = ThirdPartyNotices.locate(executable: s.root.appendingPathComponent("dist/mgx"))
        XCTAssertEqual(found.map(realPath), realPath(s.root.appendingPathComponent("dist/THIRD_PARTY_NOTICES.md")))
    }

    func testFindsTheFileInAnAppBundle() throws {
        let s = try Sandbox()
        try s.write("A.app/Contents/MacOS/A", "bin", executable: true)
        try s.write("A.app/Contents/Resources/THIRD_PARTY_NOTICES.md", "notices")
        let found = ThirdPartyNotices.locate(executable: s.root.appendingPathComponent("A.app/Contents/MacOS/A"))
        XCTAssertEqual(found.map(realPath), realPath(s.root.appendingPathComponent("A.app/Contents/Resources/THIRD_PARTY_NOTICES.md")))
    }

    func testFindsTheFileInAnInstallPrefix() throws {
        let s = try Sandbox()
        try s.write("prefix/bin/mgx", "bin", executable: true)
        try s.write("prefix/share/mac-gaming/THIRD_PARTY_NOTICES.md", "notices")
        let found = ThirdPartyNotices.locate(executable: s.root.appendingPathComponent("prefix/bin/mgx"))
        XCTAssertEqual(found.map(realPath), realPath(s.root.appendingPathComponent("prefix/share/mac-gaming/THIRD_PARTY_NOTICES.md")))
    }

    func testFollowsASymlinkedBinary() throws {
        let s = try Sandbox()
        try s.write("dist/mgx", "bin", executable: true)
        try s.write("dist/THIRD_PARTY_NOTICES.md", "notices")
        try s.fm.createDirectory(at: s.root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let link = s.root.appendingPathComponent("bin/mgx")
        try s.fm.createSymbolicLink(at: link, withDestinationURL: s.root.appendingPathComponent("dist/mgx"))
        let found = ThirdPartyNotices.locate(executable: link)
        XCTAssertEqual(found.map(realPath), realPath(s.root.appendingPathComponent("dist/THIRD_PARTY_NOTICES.md")))
    }

    func testMissingFileAndDirectoriesAreIgnored() throws {
        let s = try Sandbox()
        try s.write("dist/mgx", "bin", executable: true)
        XCTAssertNil(ThirdPartyNotices.locate(executable: s.root.appendingPathComponent("dist/mgx")))
        // A directory with the file's name is not the file.
        try s.fm.createDirectory(at: s.root.appendingPathComponent("dist/THIRD_PARTY_NOTICES.md"), withIntermediateDirectories: true)
        XCTAssertNil(ThirdPartyNotices.locate(executable: s.root.appendingPathComponent("dist/mgx")))
    }

    /// The repository's own copy: the file that releases ship.
    func testRepositoryNoticesCoverWhatShips() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // Tests/MGCoreTests
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: repo.appendingPathComponent(ThirdPartyNotices.fileName), encoding: .utf8)
        for needle in ["Wine", "LGPL-2.1-or-later", "DXMT", "DXVK-macOS", "MoltenVK", "LLVM", "mingw-w64",
                       "FreeType", "GnuTLS", "GMP", "Nettle", "swift-argument-parser", "D3DMetal",
                       "crossover-sources-"] {
            XCTAssertTrue(text.contains(needle), "THIRD_PARTY_NOTICES.md does not mention \(needle)")
        }
    }
}
