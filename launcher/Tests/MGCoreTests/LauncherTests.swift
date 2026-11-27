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
        XCTAssertEqual(p.executable, p.runtime.wineRoot.appendingPathComponent("bin/wine"))
        XCTAssertEqual(p.arguments, [exe.path, "-windowed"])
        XCTAssertEqual(p.workingDirectory, exe.deletingLastPathComponent())
        XCTAssertEqual(p.environment["WINEPREFIX"], sb.paths.bottle("b").path)
        XCTAssertEqual(p.environment["WINEMSYNC"], "1")
        XCTAssertEqual(DLLOverrides(parsing: p.environment["WINEDLLOVERRIDES"]!)["d3d11"], "n,b")
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
        XCTAssertTrue(sb.read(bottle.prefix.appendingPathComponent("reg.log")).contains("RetinaMode /t REG_SZ /d y /f"))
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

    func testFreshBottleWithRetinaOffSkipsRegistryWrite() throws {
        let sb = try Sandbox()
        let l = try setUp(sb)
        let p = try l.plan(RunRequest(bottle: "b", backend: .wined3d, program: "notepad.exe"))
        try l.prepare(p)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sb.paths.bottle("b").appendingPathComponent("reg.log").path))
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
        XCTAssertTrue(checks.contains { $0.status == .ok && $0.title.contains("DXMT 0.61") })
        XCTAssertTrue(checks.contains { $0.status == .ok && $0.title.contains("Wine crossover-26.3.0-wow64") })
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
