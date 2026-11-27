import XCTest
@testable import MGCore

final class PEParserTests: XCTestCase {
    func testPE32PlusImports() throws {
        let pe = try PEParser.parse(contentsOf: Fixture.url("dx11.exe"))
        XCTAssertTrue(pe.is64Bit)
        XCTAssertEqual(pe.machine, 0x8664)
        XCTAssertEqual(pe.imports, ["KERNEL32.dll", "USER32.dll", "D3D11.dll", "dxgi.dll"])
        XCTAssertEqual(pe.delayImports, [])
        XCTAssertEqual(pe.allLowercased, ["kernel32.dll", "user32.dll", "d3d11.dll", "dxgi.dll"])
    }

    func testPE32Imports() throws {
        let pe = try PEParser.parse(contentsOf: Fixture.url("dx9.exe"))
        XCTAssertFalse(pe.is64Bit)
        XCTAssertEqual(pe.machine, 0x14C)
        XCTAssertEqual(pe.imports, ["kernel32.dll", "d3d9.dll"])
    }

    func testDelayImports() throws {
        let pe = try PEParser.parse(contentsOf: Fixture.url("delay11.exe"))
        XCTAssertEqual(pe.imports, ["kernel32.dll"])
        XCTAssertEqual(pe.delayImports, ["d3d11.dll"])
    }

    func testOldStyleDelayImportsUseVirtualAddresses() throws {
        let pe = try PEParser.parse(contentsOf: Fixture.url("delay9-old.exe"))
        XCTAssertEqual(pe.delayImports, ["d3d9.dll"])
    }

    func testNoImports() throws {
        let pe = try PEParser.parse(contentsOf: Fixture.url("noimports.exe"))
        XCTAssertEqual(pe.imports, [])
        XCTAssertEqual(pe.delayImports, [])
    }

    func testRejectsNonPE() {
        XCTAssertThrowsError(try PEParser.parse(contentsOf: Fixture.url("notpe.txt"))) { e in
            XCTAssertEqual(e as? PEError, .notPE("missing PE signature"))
        }
        XCTAssertThrowsError(try PEParser.parse(Data("hello".utf8))) { e in
            XCTAssertEqual(e as? PEError, .notPE("file is smaller than a DOS header"))
        }
        var notMZ = Data(count: 128)
        notMZ[0] = 0x7F
        XCTAssertThrowsError(try PEParser.parse(notMZ)) { e in
            XCTAssertEqual(e as? PEError, .notPE("missing MZ signature"))
        }
    }

    func testRejectsTruncatedHeader() {
        XCTAssertThrowsError(try PEParser.parse(contentsOf: Fixture.url("truncated.exe")))
    }

    func testBadImportRVAIsIgnoredNotFatal() throws {
        let pe = try PEParser.parse(contentsOf: Fixture.url("badimportrva.exe"))
        XCTAssertEqual(pe.imports, [])
    }

    func testEveryTruncationIsHandled() throws {
        // No prefix of a valid file may crash the parser.
        let data = try Data(contentsOf: Fixture.url("dx12.exe"))
        for n in stride(from: 0, to: data.count, by: 7) {
            _ = try? PEParser.parse(data.prefix(n))
        }
    }

    func testRandomCorruptionIsHandled() throws {
        let data = try Data(contentsOf: Fixture.url("dx11.exe"))
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var d = data
            for _ in 0..<8 { d[Int.random(in: 0..<d.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            _ = try? PEParser.parse(d)
        }
    }
}
