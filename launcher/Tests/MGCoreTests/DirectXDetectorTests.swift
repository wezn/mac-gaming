import XCTest
@testable import MGCore

final class DirectXDetectorTests: XCTestCase {
    func detect(_ name: String) -> DirectXDetection { DirectXDetector.detect(executable: Fixture.url(name)) }

    func testLevels() {
        XCTAssertEqual(detect("dx12.exe").level, .dx12)
        XCTAssertEqual(detect("dx11.exe").level, .dx11)
        XCTAssertEqual(detect("dx10.exe").level, .dx10)
        XCTAssertEqual(detect("dx9.exe").level, .dx9)
        XCTAssertEqual(detect("dx8.exe").level, .dx8)
        XCTAssertEqual(detect("ddraw.exe").level, .dx7)
        XCTAssertEqual(detect("delay11.exe").level, .dx11)
        XCTAssertEqual(detect("delay9-old.exe").level, .dx9)
    }

    func testEvidenceAndSource() {
        let d = detect("dx12.exe")
        XCTAssertEqual(d.source, .executable)
        XCTAssertEqual(d.evidence, "dx12.exe imports d3d12.dll")
        XCTAssertEqual(d.is64Bit, true)
        XCTAssertEqual(detect("dx11.exe").evidence, "dx11.exe imports d3d11.dll") // case-insensitive
    }

    func testNothingFound() {
        let d = detect("plain.exe")
        XCTAssertEqual(d.level, .none)
        XCTAssertEqual(d.source, .none)
        XCTAssertEqual(detect("notpe.txt").level, .none)
        XCTAssertEqual(DirectXDetector.detect(executable: URL(fileURLWithPath: "/nonexistent/x.exe")).level, .none)
    }

    func testSiblingDLLScan() {
        let d = detect("engine/game.exe")
        XCTAssertEqual(d.level, .dx11)
        XCTAssertEqual(d.source, .siblingDLL)
        XCTAssertEqual(d.evidence, "rendersystemdx11.dll imports d3d11.dll")
        XCTAssertEqual(DirectXDetector.detect(executable: Fixture.url("engine/game.exe"), scanSiblings: false).level, .none)
    }

    func testImportTableMapping() {
        XCTAssertEqual(DirectXDetector.level(forImports: ["d3d9.dll", "d3d11.dll"]).0, .dx11)
        XCTAssertEqual(DirectXDetector.level(forImports: ["dxgi.dll"]).0, .dx11)
        XCTAssertEqual(DirectXDetector.level(forImports: ["d3d10_1.dll"]).0, .dx10)
        XCTAssertEqual(DirectXDetector.level(forImports: ["d3d12core.dll"]).0, .dx12)
        XCTAssertEqual(DirectXDetector.level(forImports: ["opengl32.dll"]).0, .none)
    }
}
