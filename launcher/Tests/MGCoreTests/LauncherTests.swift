import XCTest
@testable import MGCore

final class LauncherTests: XCTestCase {
    func setUp(_ sb: Sandbox, gptk: Bool = false) throws -> Launcher {
        let a = try sb.makeArchives()
        try RuntimeStore(paths: sb.paths).install(sources: [a.wine, a.dxmt, a.dxvk])
        var env = ["HOME": "/home/test", "PATH": "/usr/bin:/bin"]
        if gptk { env["MG_GPTK"] = try sb.makeGPTK().path }
        _ = try BottleStore(paths: sb.paths).create(BottleConfig(name: "b"))
        return Launcher(paths: sb.paths, baseEnvironment: env)
    }

    func game(_ sb: Sandbox, _ fixture: String, as name: String) throws -> URL {
        let dir = sb.root.appendingPathComponent("Games/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: Fixture.url(fixture), to: url)
        return url
    }

    func testPlanDX11PicksDXMT() throws {
        let sb = try Sandbox()
        let l = try setUp(sb)
        let exe = try game(sb, "dx11.exe", as: "Game.exe")
        let p = try l.plan(RunRequest(bottle: "b", program: exe.path, arguments: ["-windowed"]))
        XCTAssertEqual(p.choice.backend, .dxmt)
        XCTAssertEqual(p.detection.level, .dx11)
        XCTAssertEqual(p.executable, p.runtime.dxmtWineRoot.appendingPathComponent("bin/wine"))
        XCTAssertEqual(p.arguments, [exe.path, "-windowed"])
        XCTAssertEqual(p.workingDirectory, exe.deletingLastPathComponent())
        XCTAssertEqual(p.environment["WINEPREFIX"], sb.paths.bottle("b").path)
        XCTAssertEqual(p.environment["WINEMSYNC"], "1")
        XCTAssertEqual(DLLOverrides(parsing: p.environment["WINEDLLOVERRIDES"]!)["d3d11"], "b")
        XCTAssertEqual(DLLOverrides(parsing: p.environment["WINEDLLOVERRIDES"]!)["winemetal"], "b")
        XCTAssertTrue(p.logFile.path.hasPrefix(sb.paths.logs.appendingPathComponent("b").path))
        XCTAssertFalse(p.retina)
    }

    func testPlanDX12NeedsGPTK() throws {
        let sb = try Sandbox()
        let exe = try game(sb, "dx12.exe", as: "Game.exe")
        XCTAssertThrowsError(try setUp(sb).plan(RunRequest(bottle: "b", program: exe.path))) {
            XCTAssertEqual($0 as? MGError, .dx12NeedsD3DMetal("Game.exe"))
        }
        let sb2 = try Sandbox()
        let exe2 = try game(sb2, "dx12.exe", as: "Game.exe")
        let p = try setUp(sb2, gptk: true).plan(RunRequest(bottle: "b", program: exe2.path))
        XCTAssertEqual(p.choice.backend, .d3dmetal)
        XCTAssertEqual(p.executable, p.runtime.d3dmetalWineRoot.appendingPathComponent("bin/wine"))
        XCTAssertTrue(p.environment["DYLD_FALLBACK_LIBRARY_PATH"]!.hasPrefix(p.runtime.d3dmetalWineRoot.appendingPathComponent("lib/external").path))
    }

    func testPlanUsesOverrideTableByFileName() throws {
        let sb = try Sandbox()
        let l = try setUp(sb, gptk: true)
        let ow = try game(sb, "plain.exe", as: "Overwatch.exe")
        XCTAssertEqual(try l.plan(RunRequest(bottle: "b", program: ow.path)).choice.backend, .d3dmetal)
        let cs2 = try game(sb, "plain.exe", as: "cs2.exe")
        XCTAssertEqual(try l.plan(RunRequest(bottle: "b", program: cs2.path)).choice.backend, .dxmt)
        try sb.write("home/overrides.json", #"{"games":{"Overwatch.exe":{"backend":"dxvk","env":{"X":"1"},"retina":true}}}"#)
        let p = try l.plan(RunRequest(bottle: "b", program: ow.path))
        XCTAssertEqual(p.choice.backend, .dxvk)
        XCTAssertEqual(p.environment["X"], "1")
        XCTAssertTrue(p.retina)
    }

    func testPlanBuiltinProgramAndRequestFlags() throws {
        let sb = try Sandbox()
        let l = try setUp(sb)
        let p = try l.plan(RunRequest(bottle: "b", backend: .wined3d, program: "notepad.exe", env: ["FOO": "bar"],
                                      metalHUD: true, msync: false, retina: true, wineDebug: "+loaddll"))
        XCTAssertEqual(p.arguments, ["notepad.exe"])
        XCTAssertNil(p.workingDirectory)
        XCTAssertEqual(p.detection, .unknown)
        XCTAssertEqual(p.choice.backend, .wined3d)
        XCTAssertEqual(p.environment["FOO"], "bar")
        XCTAssertEqual(p.environment["MTL_HUD_ENABLED"], "1")
        XCTAssertNil(p.environment["WINEMSYNC"])
        XCTAssertEqual(p.environment["WINEDEBUG"], "+loaddll")
        XCTAssertTrue(p.retina)
        let w = try l.plan(RunRequest(bottle: "b", program: #"C:\Games\x.exe"#))
        XCTAssertEqual(w.programName, "x.exe")
        XCTAssertEqual(w.arguments, [#"C:\Games\x.exe"#])
    }

    func testInstallerTypes() throws {
        let sb = try Sandbox()
        let l = try setUp(sb)
        let msi = try game(sb, "plain.exe", as: "setup.msi")
        XCTAssertEqual(try l.plan(RunRequest(bottle: "b", program: msi.path)).arguments, ["msiexec", "/i", msi.path])
    }

    func testPrepareAndExecuteEndToEnd() throws {
        let sb = try Sandbox()
        let l = try setUp(sb)
        let exe = try game(sb, "dx9.exe", as: "Old Game.exe")
        let p = try l.plan(RunRequest(bottle: "b", program: exe.path, arguments: ["a b"], retina: true))
        XCTAssertEqual(p.choice.backend, .dxvk)
        var notes: [String] = []
        try l.prepare(p, log: { notes.append($0) })
        let bottle = try BottleStore(paths: sb.paths).get("b")
        XCTAssertTrue(bottle.isInitialized, "wineboot --init ran")
        XCTAssertEqual(sb.read(BackendFiles.system32(bottle.prefix).appendingPathComponent("d3d9.dll")), "dxvk64-d3d9.dll")
        let reg = sb.read(bottle.prefix.appendingPathComponent("reg.log"))
        XCTAssertTrue(reg.contains("RetinaMode /t REG_SZ /d y /f"), reg)
        XCTAssertTrue(reg.contains(#"HKCU\Control Panel\Desktop /v LogPixels /t REG_DWORD /d 192 /f"#), reg)
        XCTAssertEqual(notes.count, 3, "\(notes)")

        // A second prepare does nothing.
        notes = []
        try l.prepare(p, log: { notes.append($0) })
        XCTAssertEqual(notes, [])

        let code = try l.execute(p)
        XCTAssertEqual(code, 0)
        let log = sb.read(p.logFile)
        XCTAssertTrue(log.contains("# backend: dxvk"), log)
        XCTAssertTrue(log.contains("wine \(exe.path) a b"), log)
        XCTAssertTrue(log.contains("WINEPREFIX=\(bottle.prefix.path)"), log)
        XCTAssertTrue(log.contains("PWD=\(realPath(exe.deletingLastPathComponent()))"), log)
        XCTAssertEqual(LogStore(paths: sb.paths).list(bottle: "b").first?.url, p.logFile)
    }

    func testDXMTRunUsesOverlayAndDeploysWinemetal() throws {
        let sb = try Sandbox()
        let l = try setUp(sb)
        let rt = try RuntimeStore(paths: sb.paths).resolve(nil, config: GlobalConfig.load(sb.paths))
        try FileManager.default.removeItem(at: rt.dxmtWineRoot)
        let p = try l.plan(RunRequest(bottle: "b", backend: .dxmt, program: "cmd.exe", arguments: ["/c", "echo", "hi"]))
        var notes: [String] = []
        try l.prepare(p, log: { notes.append($0) })
        XCTAssertTrue(notes.contains { $0.contains("wine-dxmt") }, "missing overlay rebuilt: \(notes)")
        let prefix = sb.paths.bottle("b")
        XCTAssertEqual(sb.read(BackendFiles.system32(prefix).appendingPathComponent("winemetal.dll")), "dxmt64-winemetal.dll")
        XCTAssertEqual(sb.read(BackendFiles.syswow64(prefix).appendingPathComponent("winemetal.dll")), "dxmt32-winemetal.dll")
        XCTAssertEqual(try l.execute(p), 0)
        let log = sb.read(p.logFile)
        XCTAssertTrue(log.contains("# command: \(rt.dxmtWineRoot.appendingPathComponent("bin/wine").path) cmd.exe /c echo hi"), log)
        XCTAssertTrue(log.contains("WINEDLLOVERRIDES=d3d10,d3d10_1,d3d10core,d3d11,d3d12,d3d12core,d3d8,d3d9,dxgi,winemetal=b"), log)
    }

    func testFreshBottleWithRetinaOffSkipsRegistryWrite() throws {
        let sb = try Sandbox()
        let l = try setUp(sb)
        let p = try l.plan(RunRequest(bottle: "b", backend: .wined3d, program: "notepad.exe"))
        try l.prepare(p)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sb.paths.bottle("b").appendingPathComponent("reg.log").path))
    }

    func testRetinaOffRestoresDPIAndOldBottlesGetDPI() throws {
        let sb = try Sandbox()
        let l = try setUp(sb)
        let reg = sb.paths.bottle("b").appendingPathComponent("reg.log")
        try l.prepare(try l.plan(RunRequest(bottle: "b", backend: .wined3d, program: "notepad.exe", retina: true)))
        try FileManager.default.removeItem(at: reg)

        var notes: [String] = []
        try l.prepare(try l.plan(RunRequest(bottle: "b", backend: .wined3d, program: "notepad.exe", retina: false)),
                      log: { notes.append($0) })
        XCTAssertEqual(notes, ["setting RetinaMode=n, LogPixels=96"])
        XCTAssertTrue(sb.read(reg).contains("LogPixels /t REG_DWORD /d 96 /f"))

        // A bottle that got Retina before mgx wrote LogPixels only needs the DPI.
        let bottle = try BottleStore(paths: sb.paths).get("b")
        try BottleStore(paths: sb.paths).saveState(BottleState(retinaApplied: true), bottle)
        notes = []
        try l.prepare(try l.plan(RunRequest(bottle: "b", backend: .wined3d, program: "notepad.exe", retina: true)),
                      log: { notes.append($0) })
        XCTAssertEqual(notes, ["setting LogPixels=192"])
    }

    func testExecuteReportsExitCode() throws {
        let sb = try Sandbox()
        var l = try setUp(sb)
        l.baseEnvironment["FAKE_WINE_EXIT"] = "3"
        let p = try l.plan(RunRequest(bottle: "b", backend: .wined3d, program: "cmd.exe"))
        XCTAssertEqual(try l.execute(p), 3)
    }
}

final class SubprocessTests: XCTestCase {
    func testExitCodesAndOutput() throws {
        let sb = try Sandbox()
        let out = sb.root.appendingPathComponent("out.log")
        XCTAssertEqual(try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo hi; echo err >&2; exit 7"],
                                          environment: [:], output: .file(out)), 7)
        XCTAssertEqual(sb.read(out), "hi\nerr\n")
        XCTAssertEqual(try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "kill -9 $$"], environment: [:], output: .null), 128 + 9)
    }

    func testEnvironmentIsExact() throws {
        let (code, out) = try Subprocess.capture(URL(fileURLWithPath: "/usr/bin/env"), [], environment: ["ONLY": "this"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(out, "ONLY=this\n")
    }

    func testTeeStopsWhenChildExitsEvenIfPipeStaysOpen() throws {
        let sb = try Sandbox()
        let out = sb.root.appendingPathComponent("tee.log")
        let start = Date()
        // The background sleep inherits the pipe, like wineserver does.
        XCTAssertEqual(try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo teed; (sleep 5 &) ; exit 0"],
                                          environment: ["PATH": "/usr/bin:/bin"], output: .tee(out)), 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(sb.read(out), "teed\n")
    }

    func testWorkingDirectoryIsRestored() throws {
        let before = FileManager.default.currentDirectoryPath
        let sb = try Sandbox()
        let f = sb.root.appendingPathComponent("pwd.log")
        _ = try Subprocess.run(URL(fileURLWithPath: "/bin/pwd"), ["-P"], environment: [:], workingDirectory: sb.root, output: .file(f))
        let printed = URL(fileURLWithPath: sb.read(f).trimmingCharacters(in: .newlines))
        XCTAssertEqual(realPath(printed), realPath(sb.root))
        XCTAssertEqual(FileManager.default.currentDirectoryPath, before)
    }

    func testMissingBinary() {
        XCTAssertThrowsError(try Subprocess.run(URL(fileURLWithPath: "/nonexistent/wine"), [], environment: [:]))
    }
}

final class DoctorAndLogsTests: XCTestCase {
    func testDoctorOnEmptyRoot() throws {
        let sb = try Sandbox()
        var d = Doctor(paths: sb.paths, environment: [:])
        d.rosettaInstalled = { false }
        let checks = d.run()
        XCTAssertTrue(checks.contains { $0.status == .error && $0.title == "no runtime" })
        XCTAssertTrue(checks.contains { $0.status == .error && $0.title == "Rosetta 2 missing" })
        XCTAssertTrue(checks.contains { $0.status == .warning && $0.title == "D3DMetal not configured" })
    }

    func testDoctorHealthy() throws {
        let sb = try Sandbox()
        let a = try sb.makeArchives()
        try RuntimeStore(paths: sb.paths).install(sources: [a.wine, a.dxmt, a.dxvk])
        var d = Doctor(paths: sb.paths, environment: ["MG_GPTK": try sb.makeGPTK().path])
        d.rosettaInstalled = { true }
        d.machine = "arm64"
        d.osVersion = OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)
        let checks = d.run()
        let errors = checks.filter { $0.status == .error }
        XCTAssertEqual(errors, [], "\(errors)")
        XCTAssertTrue(checks.contains { $0.status == .ok && $0.title == "D3DMetal (GPTK)" })
        XCTAssertTrue(checks.contains { $0.status == .ok && $0.title.contains("DXMT 0.61") && $0.detail.hasPrefix("winemetal integrated") })
        XCTAssertFalse(checks.contains { $0.title.contains("DXMT built for another Wine") })
        XCTAssertTrue(checks.contains { $0.status == .ok && $0.title.contains("Wine crossover-26.3.0-wow64") })
        XCTAssertFalse(checks.contains { $0.title.contains("no GnuTLS") })
    }

    func testDoctorFlagsWineWithoutGnuTLS() throws {
        let sb = try Sandbox()
        let a = try sb.makeArchives()
        let r = try RuntimeStore(paths: sb.paths).install(sources: [a.wine])
        let rt = try RuntimeStore(paths: sb.paths).get(r.runtime)
        try FileManager.default.removeItem(at: rt.wineRoot.appendingPathComponent("lib/libgnutls.30.dylib"))
        var d = Doctor(paths: sb.paths, environment: [:])
        d.rosettaInstalled = { nil }
        let checks = d.run()
        XCTAssertTrue(checks.contains { $0.status == .warning && $0.title.hasSuffix("no GnuTLS") && $0.detail.contains("Battle.net") }, "\(checks)")
    }

    func testDoctorFlagsDXMTForAnotherWineAndStaleOverlay() throws {
        let sb = try Sandbox()
        let a = try sb.makeArchives()
        let store = RuntimeStore(paths: sb.paths)
        try store.install(sources: [a.wine])
        let t = sb.root.appendingPathComponent("t", isDirectory: true)
        try sb.makeDXMTTree(at: t.appendingPathComponent("dxmt"), builtAgainst: "wine-crossover-25.0.1-wow64")
        let r = try store.install(sources: [t])
        try FileManager.default.removeItem(at: try store.get(r.runtime).dxmtWineRoot)
        var d = Doctor(paths: sb.paths, environment: [:])
        d.rosettaInstalled = { nil }
        let checks = d.run()
        XCTAssertTrue(checks.contains { $0.status == .warning && $0.title.contains("DXMT built for another Wine")
            && $0.detail.contains("wine-crossover-25.0.1-wow64") && $0.detail.contains("wine-crossover-26.3.0-wow64") }, "\(checks)")
        XCTAssertTrue(checks.contains { $0.status == .warning && $0.title.contains("DXMT") && $0.detail.contains("missing or stale") })
    }

    func testDoctorFlagsBadGPTKAndMissingRuntimeForBottle() throws {
        let sb = try Sandbox()
        try GlobalConfig(gptkPath: sb.root.path).save(sb.paths)
        _ = try BottleStore(paths: sb.paths).create(BottleConfig(name: "x", runtime: "gone"))
        var d = Doctor(paths: sb.paths, environment: [:])
        d.rosettaInstalled = { nil }
        let checks = d.run()
        XCTAssertTrue(checks.contains { $0.status == .error && $0.title == "D3DMetal (GPTK)" })
        XCTAssertTrue(checks.contains { $0.status == .error && $0.title == "bottle x" })
    }

    func testLogNamingAndPruning() throws {
        let sb = try Sandbox()
        var store = LogStore(paths: sb.paths)
        store.keepPerBottle = 3
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let a = store.newLogFile(bottle: "b", executable: "My Game!.exe", date: date)
        XCTAssertTrue(a.lastPathComponent.hasSuffix("-My_Game_.exe.log"), a.lastPathComponent)
        for i in 0..<5 {
            let u = store.newLogFile(bottle: "b", executable: "g.exe", date: date)
            try sb.write(u.path.replacingOccurrences(of: sb.root.path + "/", with: ""), "\(i)")
            try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(Double(i))], ofItemAtPath: u.path)
        }
        XCTAssertEqual(store.list(bottle: "b").count, 5)
        XCTAssertEqual(sb.read(store.list().first!.url), "4", "newest first")
        store.prune(bottle: "b")
        XCTAssertEqual(store.list(bottle: "b").map { sb.read($0.url) }, ["4", "3", "2"])
    }
}
