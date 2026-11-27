import XCTest
@testable import MGCore

final class ActionsTests: XCTestCase {
    func launcher(_ sb: Sandbox) throws -> Launcher {
        let a = try sb.makeArchives()
        try RuntimeStore(paths: sb.paths).install(sources: [a.wine, a.dxmt, a.dxvk])
        return Launcher(paths: sb.paths, baseEnvironment: ["HOME": "/home/test", "PATH": "/usr/bin:/bin"])
    }

    func testCreateBottleInitialisesAndSetsDefault() throws {
        let sb = try Sandbox()
        let l = try launcher(sb)
        var lines: [String] = []
        let b = try l.createBottle(BottleConfig(name: "ow", backend: .d3dmetal), makeDefault: true, log: { lines.append($0) })
        XCTAssertTrue(b.isInitialized)
        XCTAssertEqual(try GlobalConfig.load(sb.paths).defaultBottle, "ow")
        XCTAssertEqual(try l.bottles.get("ow").config.backend, .d3dmetal)
        XCTAssertTrue(lines.contains { $0.hasPrefix("initialising") }, "\(lines)")

        let lazy = try l.createBottle(BottleConfig(name: "lazy"), initialize: false)
        XCTAssertFalse(lazy.isInitialized)
        XCTAssertEqual(try GlobalConfig.load(sb.paths).defaultBottle, "ow")
    }

    func testCreateBottleRollsBackWhenWinebootFails() throws {
        let sb = try Sandbox()
        var l = try launcher(sb)
        l.baseEnvironment["FAKE_WINE_EXIT"] = "1"
        XCTAssertThrowsError(try l.createBottle(BottleConfig(name: "x"))) {
            XCTAssertEqual($0 as? MGError, .processFailed("wineboot --init", 1))
        }
        XCTAssertFalse(l.bottles.exists("x"))
    }

    func testCreateBottleNeedsARuntime() throws {
        let sb = try Sandbox()
        let l = Launcher(paths: sb.paths, baseEnvironment: [:])
        XCTAssertThrowsError(try l.createBottle(BottleConfig(name: "x"))) { XCTAssertEqual($0 as? MGError, .noRuntime) }
        XCTAssertFalse(l.bottles.exists("x"))
    }

    func testUpdateBottleValidatesRuntimeAndKeepsName() throws {
        let sb = try Sandbox()
        let l = try launcher(sb)
        try l.createBottle(BottleConfig(name: "b"), initialize: false)
        let b = try l.updateBottle("b") { c in
            c.name = "renamed"
            c.retina = true
            c.env["DXVK_HUD"] = "fps"
        }
        XCTAssertEqual(b.name, "b")
        XCTAssertEqual(try l.bottles.get("b").config.env, ["DXVK_HUD": "fps"])
        XCTAssertTrue(try l.bottles.get("b").config.retina)
        XCTAssertThrowsError(try l.updateBottle("b") { $0.runtime = "nope" }) { XCTAssertEqual($0 as? MGError, .runtimeNotFound("nope")) }
        XCTAssertNil(try l.bottles.get("b").config.runtime, "failed update is not saved")
    }

    func testDeleteBottleClearsDefault() throws {
        let sb = try Sandbox()
        let l = try launcher(sb)
        try l.createBottle(BottleConfig(name: "b"), initialize: false, makeDefault: true)
        try l.deleteBottle("b")
        XCTAssertFalse(l.bottles.exists("b"))
        XCTAssertNil(try GlobalConfig.load(sb.paths).defaultBottle)
        XCTAssertThrowsError(try l.deleteBottle("b")) { XCTAssertEqual($0 as? MGError, .bottleNotFound("b")) }
    }

    func testSettings() throws {
        let sb = try Sandbox()
        let l = try launcher(sb)
        let gptk = try sb.makeGPTK()
        let g = try l.setGPTKPath(gptk.path)
        XCTAssertEqual(g?.libRoot.lastPathComponent, "lib")
        XCTAssertEqual(try GlobalConfig.load(sb.paths).gptkPath, gptk.standardizedFileURL.path)
        XCTAssertThrowsError(try l.setGPTKPath(sb.root.path)) { e in
            guard case .invalidConfig? = e as? MGError else { return XCTFail("\(e)") }
        }
        XCTAssertNotNil(try GlobalConfig.load(sb.paths).gptkPath, "a rejected path leaves the old one")
        XCTAssertNil(try l.setGPTKPath(nil))
        XCTAssertNil(try GlobalConfig.load(sb.paths).gptkPath)

        try l.setDefaultRuntime("crossover-26.3.0-wow64")
        XCTAssertEqual(try GlobalConfig.load(sb.paths).defaultRuntime, "crossover-26.3.0-wow64")
        XCTAssertThrowsError(try l.setDefaultRuntime("nope"))
        XCTAssertThrowsError(try l.setDefaultBottle("nope"))
        try l.createBottle(BottleConfig(name: "b"), initialize: false)
        try l.setDefaultBottle("b")
        try l.setDefaultRuntime(nil)
        XCTAssertEqual(try GlobalConfig.load(sb.paths), GlobalConfig(defaultBottle: "b"))
    }

    func testStoreInstallCreatesBottleDownloadsOnceAndPlansInstaller() throws {
        let sb = try Sandbox()
        let l = try launcher(sb)
        var downloads: [URL] = []
        let fakeDownload: (URL, URL) throws -> Void = { url, dest in
            downloads.append(url)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("MZ".utf8).write(to: dest)
        }
        let p = try l.planStoreInstall(.steam, bottle: "steam", backend: .dxmt, download: fakeDownload)
        XCTAssertEqual(downloads, [Store.steam.installerURL])
        XCTAssertTrue(l.bottles.exists("steam"))
        XCTAssertTrue(try l.bottles.get("steam").isInitialized)
        XCTAssertEqual(try l.bottles.get("steam").config.backend, .dxmt)
        XCTAssertEqual(p.choice.backend, .wined3d, "installers run with wined3d")
        XCTAssertEqual(p.arguments, [l.installerFile(for: .steam).path, "/S"])

        _ = try l.planStoreInstall(.steam, bottle: "steam", download: fakeDownload)
        XCTAssertEqual(downloads.count, 1, "cached installer is reused")
        _ = try l.planStoreInstall(.steam, bottle: "steam", redownload: true, download: fakeDownload)
        XCTAssertEqual(downloads.count, 2)
    }

    func testStoreClientPlan() throws {
        let sb = try Sandbox()
        let l = try launcher(sb)
        let b = try l.createBottle(BottleConfig(name: "bn", backend: .dxvk), initialize: false)
        XCTAssertNil(l.clientExecutable(.battlenet, in: b))
        XCTAssertThrowsError(try l.planStoreClient(.battlenet, bottle: "bn")) { e in
            guard case .io(let m)? = e as? MGError else { return XCTFail("\(e)") }
            XCTAssertTrue(m.contains("not installed"), m)
        }
        try sb.write(#"Program Files (x86)/Battle.net/Battle.net Launcher.exe"#, "MZ", in: b.root.appendingPathComponent("drive_c"))
        XCTAssertNotNil(l.clientExecutable(.battlenet, in: b))
        let p = try l.planStoreClient(.battlenet, bottle: "bn", arguments: ["--x"])
        XCTAssertEqual(p.choice.backend, .dxvk)
        XCTAssertEqual(p.choice.reason, "bottle default")
        XCTAssertEqual(p.arguments.last, "--x")
        XCTAssertEqual(p.programName, "Battle.net Launcher.exe")
        XCTAssertEqual(p.environment["WINE_SIMULATE_WRITECOPY"], "1", "added to bottles that predate it")
        XCTAssertEqual(try l.bottles.get("bn").config.env["WINE_SIMULATE_WRITECOPY"], "1", "saved, so games get it too")
    }

    func testStoreEnvironmentIsSavedAndKeepsUserValues() throws {
        let sb = try Sandbox()
        let l = try launcher(sb)
        let fakeDownload: (URL, URL) throws -> Void = { _, dest in
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("MZ".utf8).write(to: dest)
        }
        let p = try l.planStoreInstall(.battlenet, bottle: "bn", download: fakeDownload)
        XCTAssertEqual(p.environment["WINE_SIMULATE_WRITECOPY"], "1")
        XCTAssertEqual(try l.bottles.get("bn").config.env, ["WINE_SIMULATE_WRITECOPY": "1"])

        try l.updateBottle("bn") { $0.env["WINE_SIMULATE_WRITECOPY"] = "0" }
        let p2 = try l.planStoreInstall(.battlenet, bottle: "bn", download: fakeDownload)
        XCTAssertEqual(p2.environment["WINE_SIMULATE_WRITECOPY"], "0", "a value the user set wins")

        _ = try l.planStoreInstall(.steam, bottle: "steam", download: fakeDownload)
        XCTAssertEqual(try l.bottles.get("steam").config.env, [:], "Steam needs nothing extra")
    }

    func testEnvironmentChanges() throws {
        let sb = try Sandbox()
        let l = try launcher(sb)
        try l.createBottle(BottleConfig(name: "b"), initialize: false)
        let base = ["HOME": "/home/test", "PATH": "/usr/bin:/bin", "WINEARCH": "win32", "WINEDEBUG": "+all"]
        var l2 = l
        l2.baseEnvironment = base
        let p = try l2.plan(RunRequest(bottle: "b", program: "notepad.exe"))
        let changes = p.environmentChanges(from: base)
        let keys = changes.map(\.key)
        XCTAssertFalse(keys.contains("HOME"))
        XCTAssertFalse(keys.contains("WINEDEBUG"), "inherited WINEDEBUG is kept, so it is not a change")
        XCTAssertEqual(changes.last, EnvironmentChange(key: "WINEARCH", value: nil, previous: "win32"))
        XCTAssertEqual(changes.first { $0.key == "WINEPREFIX" }?.value, sb.paths.bottle("b").path)
        XCTAssertNil(changes.first { $0.key == "WINEPREFIX" }?.previous)
        let setKeys = changes.filter { $0.value != nil }.map(\.key)
        XCTAssertEqual(setKeys, setKeys.sorted())
        XCTAssertEqual(p.commandLine, "\(p.executable.path) notepad.exe")
    }
}
