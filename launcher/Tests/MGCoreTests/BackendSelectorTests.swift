import XCTest
@testable import MGCore

final class BackendSelectorTests: XCTestCase {
    let all = BackendAvailability(dxmt: true, dxvk: true, dxvkD3D8: true, d3dmetal: true)
    let open = BackendAvailability(dxmt: true, dxvk: true, dxvkD3D8: false, d3dmetal: false)

    func pick(_ level: DirectXLevel, _ avail: BackendAvailability, requested: Backend? = nil,
              override: GameOverride? = nil, bottle: Backend = .auto) throws -> BackendChoice {
        try BackendSelector.select(requested: requested, override: override, bottleBackend: bottle,
                                   detection: DirectXDetection(level: level, source: level == .none ? .none : .executable),
                                   available: avail, executableName: "Game.exe")
    }

    func testAutoPolicyWithEverything() throws {
        XCTAssertEqual(try pick(.dx12, all).backend, .d3dmetal)
        XCTAssertEqual(try pick(.dx11, all).backend, .dxmt)
        XCTAssertEqual(try pick(.dx10, all).backend, .dxmt)
        XCTAssertEqual(try pick(.dx9, all).backend, .dxvk)
        XCTAssertEqual(try pick(.dx8, all).backend, .dxvk)
        XCTAssertEqual(try pick(.dx7, all).backend, .wined3d)
        XCTAssertEqual(try pick(.none, all).backend, .wined3d)
    }

    func testDX12WithoutD3DMetalIsAClearError() {
        XCTAssertThrowsError(try pick(.dx12, open)) { e in
            XCTAssertEqual(e as? MGError, .dx12NeedsD3DMetal("Game.exe"))
            XCTAssertTrue("\(e)".contains("mg config set gptk"))
        }
    }

    func testDX11Fallbacks() throws {
        XCTAssertEqual(try pick(.dx11, BackendAvailability(d3dmetal: true)).backend, .d3dmetal)
        XCTAssertEqual(try pick(.dx11, BackendAvailability(dxvk: true)).backend, .dxvk)
        let c = try pick(.dx11, BackendAvailability())
        XCTAssertEqual(c.backend, .wined3d)
        XCTAssertFalse(c.warnings.isEmpty)
    }

    func testDX9AndDX8Fallbacks() throws {
        XCTAssertEqual(try pick(.dx9, BackendAvailability()).backend, .wined3d)
        XCTAssertEqual(try pick(.dx8, open).backend, .wined3d) // dxvk without d3d8.dll
    }

    func testPrecedence() throws {
        let ov = GameOverride(backend: .dxvk)
        XCTAssertEqual(try pick(.dx11, all, requested: .wined3d, override: ov, bottle: .d3dmetal).backend, .wined3d)
        XCTAssertEqual(try pick(.dx11, all, override: ov, bottle: .d3dmetal).backend, .dxvk)
        XCTAssertEqual(try pick(.dx11, all, bottle: .d3dmetal).backend, .d3dmetal)
        XCTAssertEqual(try pick(.dx11, all, requested: .auto, bottle: .dxvk).reason, "bottle default")
        XCTAssertEqual(try pick(.dx11, all, requested: .dxmt).reason, "requested with --backend")
    }

    func testOverrideDXLevelFeedsAuto() throws {
        let c = try pick(.none, all, override: GameOverride(dx: .dx9))
        XCTAssertEqual(c.backend, .dxvk)
        XCTAssertTrue(c.reason.contains("per-game override"))
    }

    func testExplicitUnavailableBackend() {
        XCTAssertThrowsError(try pick(.dx11, open, requested: .d3dmetal)) { e in
            guard case .backendUnavailable(.d3dmetal, let hint)? = e as? MGError else { return XCTFail("\(e)") }
            XCTAssertTrue(hint.contains("gptk"))
        }
        XCTAssertThrowsError(try pick(.dx11, BackendAvailability(), requested: .dxmt))
        XCTAssertEqual(try pick(.dx11, BackendAvailability(), requested: .wined3d).backend, .wined3d)
    }

    func testBuiltInOverrides() {
        let t = GameOverrideTable.builtIn
        XCTAssertEqual(t.lookup(executable: "Overwatch.exe")?.backend, .d3dmetal)
        XCTAssertEqual(t.lookup(executable: "cs2.exe")?.dx, .dx11)
        XCTAssertNil(t.lookup(executable: "notepad.exe"))
    }
}
