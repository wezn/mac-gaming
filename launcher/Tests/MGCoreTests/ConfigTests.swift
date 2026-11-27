import XCTest
@testable import MGCore

final class ConfigTests: XCTestCase {
    func testBottleConfigRoundTrip() throws {
        let c = BottleConfig(name: "ow", runtime: "crossover-26.3.0-wow64", backend: .d3dmetal,
                             env: ["D3DM_SUPPORT_DXR": "1"], msync: false, retina: true, metalHUD: true,
                             created: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONFile.encoder.encode(c)
        XCTAssertEqual(try JSONFile.decoder.decode(BottleConfig.self, from: data), c)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""backend" : "d3dmetal""#), json)
        XCTAssertTrue(json.contains(#""created" : "2027-01-15T08:00:00Z""#), json)
    }

    func testBottleConfigDefaultsForMissingKeys() throws {
        let c = try JSONFile.decoder.decode(BottleConfig.self, from: Data(#"{"name":"x"}"#.utf8))
        XCTAssertEqual(c, BottleConfig(name: "x"))
        XCTAssertTrue(c.msync)
        XCTAssertEqual(c.backend, .auto)
    }

    func testBottleConfigRejectsUnknownBackend() {
        XCTAssertThrowsError(try JSONFile.decoder.decode(BottleConfig.self, from: Data(#"{"name":"x","backend":"opengl"}"#.utf8)))
    }

    func testGlobalConfigRoundTripOnDisk() throws {
        let sb = try Sandbox()
        XCTAssertEqual(try GlobalConfig.load(sb.paths), GlobalConfig())
        let c = GlobalConfig(defaultRuntime: "r", defaultBottle: "b", gptkPath: "/Volumes/GPTK")
        try c.save(sb.paths)
        XCTAssertEqual(try GlobalConfig.load(sb.paths), c)
    }

    func testCorruptConfigIsReported() throws {
        let sb = try Sandbox()
        try sb.write("home/config.json", "{not json")
        XCTAssertThrowsError(try GlobalConfig.load(sb.paths)) { e in
            guard case .invalidConfig? = e as? MGError else { return XCTFail("\(e)") }
        }
    }

    func testOverrideTableMergesUserFileOverBuiltIns() throws {
        let sb = try Sandbox()
        try sb.write("home/overrides.json", """
        { "games": {
            "Overwatch.exe": { "backend": "dxmt" },
            "OldGame.exe": { "dx": "dx9", "env": { "DXVK_HUD": "fps" }, "retina": true },
            "Other.exe": { "dx": 10 }
        } }
        """)
        let t = try GameOverrideTable.load(sb.paths)
        XCTAssertEqual(t.lookup(executable: "overwatch.exe")?.backend, .dxmt)
        XCTAssertEqual(t.lookup(executable: "OLDGAME.EXE"), GameOverride(dx: .dx9, env: ["DXVK_HUD": "fps"], retina: true))
        XCTAssertEqual(t.lookup(executable: "other.exe")?.dx, .dx10)
        XCTAssertEqual(t.lookup(executable: "cs2.exe")?.dx, .dx11, "built-ins survive")
        let data = try JSONFile.encoder.encode(t)
        XCTAssertEqual(try JSONFile.decoder.decode(GameOverrideTable.self, from: data), t)
    }

    func testNames() {
        for ok in ["default", "ow2", "Steam-1", "a.b_c"] { XCTAssertNoThrow(try Names.validate(ok), ok) }
        for bad in ["", "../x", "a/b", ".hidden", "-x", "spa ce", String(repeating: "a", count: 65), "é"] {
            XCTAssertThrowsError(try Names.validate(bad), bad)
        }
    }

    func testBottleStoreLifecycle() throws {
        let sb = try Sandbox()
        let store = BottleStore(paths: sb.paths)
        let b = try store.create(BottleConfig(name: "test", backend: .dxvk))
        XCTAssertNotNil(b.config.created)
        XCTAssertThrowsError(try store.create(BottleConfig(name: "test"))) { XCTAssertEqual($0 as? MGError, .bottleExists("test")) }
        var loaded = try store.get("test")
        XCTAssertEqual(loaded.config.backend, .dxvk)
        loaded.config.retina = true
        try store.save(loaded)
        XCTAssertTrue(try store.get("test").config.retina)
        try sb.write("home/bottles/broken/bottle.json", "[]")
        let (list, errors) = store.list()
        XCTAssertEqual(list.map(\.name), ["test"])
        XCTAssertEqual(Array(errors.keys), ["broken"])
        try store.delete("test")
        XCTAssertThrowsError(try store.get("test")) { XCTAssertEqual($0 as? MGError, .bottleNotFound("test")) }
        XCTAssertThrowsError(try store.get("../etc"))
    }

    func testWindowsPathMapping() {
        let b = Bottle(config: BottleConfig(name: "b"), root: URL(fileURLWithPath: "/p"))
        XCTAssertEqual(b.unixPath(forWindowsPath: #"C:\Program Files (x86)\Steam\steam.exe"#)?.path,
                       "/p/drive_c/Program Files (x86)/Steam/steam.exe")
        XCTAssertNil(b.unixPath(forWindowsPath: "notepad.exe"))
    }
}
