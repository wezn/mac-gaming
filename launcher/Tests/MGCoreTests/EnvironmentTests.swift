import XCTest
@testable import MGCore

final class DLLOverridesTests: XCTestCase {
    func testParseAndFormat() {
        let o = DLLOverrides(parsing: "d3d11,dxgi=n,b;D3D12.dll=b;mscoree=;winemenubuilder")
        XCTAssertEqual(o["d3d11"], "n,b")
        XCTAssertEqual(o["dxgi.dll"], "n,b")
        XCTAssertEqual(o["d3d12"], "b")
        XCTAssertEqual(o["mscoree"], "")
        XCTAssertEqual(o["winemenubuilder"], "")
        XCTAssertEqual(o.description, "d3d11,dxgi=n,b;d3d12=b;mscoree,winemenubuilder=")
    }

    func testRoundTrip() {
        let o = DLLOverrides(["a": "n,b", "b": "b", "c": "n,b"])
        XCTAssertEqual(DLLOverrides(parsing: o.description), o)
    }

    func testMergeLaterWins() {
        let base = DLLOverrides(["d3d11": "b", "dxgi": "b"])
        let m = base.merging(DLLOverrides(parsing: "d3d11=n"))
        XCTAssertEqual(m["d3d11"], "n")
        XCTAssertEqual(m["dxgi"], "b")
    }
}

final class EnvironmentTests: XCTestCase {
    let prefix = URL(fileURLWithPath: "/mg/bottles/b")
    let wine = URL(fileURLWithPath: "/mg/runtimes/r/wine")

    func spec(_ f: (inout EnvironmentSpec) -> Void = { _ in }) -> EnvironmentSpec {
        var s = EnvironmentSpec(prefix: prefix, wineRoot: wine, dllOverrides: DLLOverrides(["d3d11": "n,b"]))
        f(&s)
        return s
    }

    func testDefaults() {
        let env = EnvironmentBuilder.build(base: ["HOME": "/Users/me", "PATH": "/usr/bin"], spec: spec())
        XCTAssertEqual(env["WINEPREFIX"], "/mg/bottles/b")
        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertEqual(env["WINEDEBUG"], "-all")
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "d3d11=n,b")
        XCTAssertEqual(env["DYLD_FALLBACK_LIBRARY_PATH"], "/mg/runtimes/r/wine/lib:/usr/local/lib:/usr/lib")
        XCTAssertNil(env["MTL_HUD_ENABLED"])
        XCTAssertEqual(env["HOME"], "/Users/me")
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    func testMsyncOffRemovesInherited() {
        let env = EnvironmentBuilder.build(base: ["WINEMSYNC": "1"], spec: spec { $0.msync = false })
        XCTAssertNil(env["WINEMSYNC"])
    }

    func testHUDAndDebug() {
        let env = EnvironmentBuilder.build(base: ["WINEDEBUG": "+loaddll"], spec: spec { $0.metalHUD = true })
        XCTAssertEqual(env["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(env["WINEDEBUG"], "+loaddll", "an inherited WINEDEBUG is kept")
        let env2 = EnvironmentBuilder.build(base: ["WINEDEBUG": "+loaddll"], spec: spec { $0.wineDebug = "+d3d" })
        XCTAssertEqual(env2["WINEDEBUG"], "+d3d")
    }

    func testStaleWineVariablesAreDropped() {
        let env = EnvironmentBuilder.build(base: ["WINEPREFIX": "/elsewhere", "WINELOADER": "/x", "WINEDLLPATH": "/y"], spec: spec())
        XCTAssertEqual(env["WINEPREFIX"], "/mg/bottles/b")
        XCTAssertNil(env["WINELOADER"])
        XCTAssertNil(env["WINEDLLPATH"])
    }

    func testLayerPrecedence() {
        let s = spec {
            $0.backendEnv = ["A": "backend", "B": "backend", "C": "backend", "D": "backend"]
            $0.gameEnv = ["B": "game", "C": "game", "D": "game"]
            $0.bottleEnv = ["C": "bottle", "D": "bottle", "WINEPREFIX": "/hijack"]
            $0.cliEnv = ["D": "cli"]
        }
        let env = EnvironmentBuilder.build(base: ["A": "base"], spec: s)
        XCTAssertEqual(env["A"], "backend")
        XCTAssertEqual(env["B"], "game")
        XCTAssertEqual(env["C"], "bottle")
        XCTAssertEqual(env["D"], "cli")
        XCTAssertEqual(env["WINEPREFIX"], "/mg/bottles/b", "WINEPREFIX always points at the bottle")
    }

    func testDLLOverridesMergeAcrossLayers() {
        let s = spec {
            $0.dllOverrides = DLLOverrides(["d3d11": "n,b", "dxgi": "n,b", "d3d12": "b"])
            $0.bottleEnv = ["WINEDLLOVERRIDES": "dxgi=b"]
            $0.cliEnv = ["WINEDLLOVERRIDES": "mscoree="]
        }
        let env = EnvironmentBuilder.build(base: ["WINEDLLOVERRIDES": "winemenubuilder.exe=d"], spec: s)
        let o = DLLOverrides(parsing: env["WINEDLLOVERRIDES"]!)
        XCTAssertEqual(o["d3d11"], "n,b")
        XCTAssertEqual(o["dxgi"], "b")
        XCTAssertEqual(o["d3d12"], "b")
        XCTAssertEqual(o["mscoree"], "")
        XCTAssertEqual(o["winemenubuilder.exe"], "d")
    }

    func testLibraryPathOrderAndExisting() {
        let s = spec { $0.libraryDirs = [URL(fileURLWithPath: "/gptk/external")] }
        let env = EnvironmentBuilder.build(base: ["DYLD_FALLBACK_LIBRARY_PATH": "/opt/lib:/usr/lib"], spec: s)
        XCTAssertEqual(env["DYLD_FALLBACK_LIBRARY_PATH"], "/gptk/external:/mg/runtimes/r/wine/lib:/opt/lib:/usr/lib")
    }

    func testParseAssignments() throws {
        XCTAssertEqual(try EnvironmentBuilder.parseAssignments(["A=1", "B=x=y", "C="]), ["A": "1", "B": "x=y", "C": ""])
        XCTAssertThrowsError(try EnvironmentBuilder.parseAssignments(["NOEQUALS"]))
        XCTAssertThrowsError(try EnvironmentBuilder.parseAssignments(["=1"]))
    }
}
