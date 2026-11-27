import Foundation
import XCTest
@testable import MGCore

final class RedactorTests: XCTestCase {
    func testHomeAndWineUserPaths() {
        let r = Redactor(home: "/Users/alex/", user: "alex")
        XCTAssertEqual(r.redact("log: /Users/alex/Library/x.log"), "log: ~/Library/x.log")
        XCTAssertEqual(r.redact(#"C:\users\alex\AppData and C:\Users\Alex\Desktop"#), #"C:\users\USER\AppData and C:\Users\USER\Desktop"#)
        XCTAssertEqual(r.redact("drive_c/users/alex/Temp"), "drive_c/users/USER/Temp")
        XCTAssertEqual(r.redact("/users/alexandra/x"), "/users/alexandra/x", "whole path component only")
        XCTAssertEqual(r.redact("/Users/alex"), "~")
        XCTAssertEqual(r.redact(#"users\alex"#), #"users\USER"#)
        XCTAssertEqual(r.redact("/Users/bob/x"), "/Users/bob/x")
    }

    func testDegenerateHomeIsIgnored() {
        XCTAssertEqual(Redactor(home: "/", user: nil).redact("/usr/bin/tar"), "/usr/bin/tar")
        XCTAssertEqual(Redactor(home: "/", user: "").redact("users/x"), "users/x")
    }
}

final class DoctorOutputTests: XCTestCase {
    func testRenderAndJSON() throws {
        let checks = [DoctorCheck(.ok, "macOS 15.1.0", ""), DoctorCheck(.warning, "w", "detail"), DoctorCheck(.error, "e", "")]
        XCTAssertEqual(Doctor.render(checks), "✓ macOS 15.1.0\n! w\n    detail\n✗ e\n")
        let obj = try JSONSerialization.jsonObject(with: Data(Doctor.json(checks).utf8)) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertEqual(obj?["errors"] as? Int, 1)
        XCTAssertEqual(obj?["warnings"] as? Int, 1)
        let list = obj?["checks"] as? [[String: String]]
        XCTAssertEqual(list?.map { $0["status"] }, ["ok", "warning", "error"])
        XCTAssertEqual(list?[1]["detail"], "detail")
        // Round-trips into the public type, so a GUI can decode it.
        struct Out: Decodable { var checks: [DoctorCheck] }
        XCTAssertEqual(try JSONDecoder().decode(Out.self, from: Data(Doctor.json(checks).utf8)).checks, checks)
    }

    func testBrokenD3DMetalOverlayIsAnError() throws {
        let sb = try Sandbox()
        let a = try sb.makeArchives()
        let r = try RuntimeStore(paths: sb.paths).install(sources: [a.wine])
        let rt = try RuntimeStore(paths: sb.paths).get(r.runtime)
        var d = Doctor(paths: sb.paths, environment: ["MG_GPTK": try sb.makeGPTK().path])
        d.rosettaInstalled = { nil }

        try BackendFiles.ensureD3DMetalOverlay(runtime: rt, gptk: XCTUnwrap(GPTKInstall.resolve(d.environment["MG_GPTK"]!)))
        XCTAssertTrue(d.run().contains { $0.status == .ok && $0.title == "runtime \(rt.name): D3DMetal overlay" })

        try FileManager.default.removeItem(at: rt.d3dmetalWineRoot.appendingPathComponent("lib/external/D3DMetal.framework"))
        XCTAssertTrue(d.run().contains { $0.status == .error && $0.title.contains("D3DMetal overlay is broken") })
    }
}

final class ReportTests: XCTestCase {
    func testGPTKVersionFromFrameworkPlist() throws {
        let sb = try Sandbox()
        let base = try sb.makeGPTK()
        let g = try XCTUnwrap(GPTKInstall.resolve(base.path))
        XCTAssertNil(g.version)
        let plist: [String: Any] = ["CFBundleShortVersionString": "2.1", "CFBundleVersion": "21.4"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let url = g.externalDir.appendingPathComponent("D3DMetal.framework/Versions/A/Resources/Info.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        XCTAssertEqual(g.version, "2.1 (21.4)")
    }

    func testCollectsDoctorConfigRuntimesBottlesAndRedactedLogs() throws {
        let sb = try Sandbox()
        let a = try sb.makeArchives()
        try RuntimeStore(paths: sb.paths).install(sources: [a.wine, a.dxmt, a.dxvk])
        let gptk = try sb.makeGPTK()
        try GlobalConfig(gptkPath: gptk.path).save(sb.paths)
        _ = try BottleStore(paths: sb.paths).create(BottleConfig(name: "ow", backend: .d3dmetal))

        // Pretend the sandbox root is the user's home.
        let home = sb.root.path
        let store = LogStore(paths: sb.paths)
        let old = store.newLogFile(bottle: "ow", executable: "old.exe", date: Date(timeIntervalSince1970: 1_800_000_000))
        let new = store.newLogFile(bottle: "ow", executable: "Overwatch.exe", date: Date(timeIntervalSince1970: 1_800_000_100))
        try FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old log\n".utf8).write(to: old)
        try Data(("x".repeated(5000) + "\nloaded \(home)/foo C:\\users\\tester\\AppData\nEND\n").utf8).write(to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_100)], ofItemAtPath: new.path)

        var d = Doctor(paths: sb.paths, environment: ["MG_HOME": sb.paths.root.path])
        d.rosettaInstalled = { true }
        d.machine = "arm64"
        let report = DiagnosticReport.collect(paths: sb.paths, doctor: d, toolVersion: "9.9", redactor: Redactor(home: home, user: "tester"),
                                              logCount: 1, maxLogBytes: 1024)
        let names = report.files.map(\.name)
        for n in ["summary.txt", "doctor.txt", "doctor.json", "config.json", "runtimes.txt", "gptk.txt", "bottles/ow.txt", "logs/index.txt"] {
            XCTAssertTrue(names.contains(n), "missing \(n) in \(names)")
        }
        XCTAssertEqual(names.filter { $0.hasSuffix(".log") }, ["logs/ow/\(new.lastPathComponent)"], "only the newest log")

        let log = try XCTUnwrap(report.file("logs/ow/\(new.lastPathComponent)")).contents
        XCTAssertTrue(log.hasPrefix("[mgx report: first "), "truncated from the front")
        XCTAssertTrue(log.contains(#"loaded ~/foo C:\users\USER\AppData"#), log)
        XCTAssertTrue(log.hasSuffix("END\n"))

        for f in report.files {
            XCTAssertFalse(f.contents.contains(home), "\(f.name) leaks the home path")
        }
        XCTAssertTrue(report.file("summary.txt")!.contents.contains("mgx 9.9"))
        XCTAssertTrue(report.file("summary.txt")!.contents.contains("MG_HOME=~/home"))
        XCTAssertTrue(report.file("doctor.txt")!.contents.contains("✓ D3DMetal (GPTK)"))
        XCTAssertTrue(report.file("doctor.json")!.contents.contains(#""status" : "ok""#))
        XCTAssertTrue(report.file("config.json")!.contents.contains(#""gptkPath" : "~/gptk""#))
        XCTAssertTrue(report.file("gptk.txt")!.contents.contains("D3DMetal.framework: present"))
        XCTAssertTrue(report.file("gptk.txt")!.contents.contains("  lib/"), "layout listing")
        let rts = report.file("runtimes.txt")!.contents
        XCTAssertTrue(rts.contains("missing: D3DMetal overlay ("), rts)
        XCTAssertTrue(rts.contains("present: DXMT overlay winemetal.so ("), rts)
        XCTAssertTrue(rts.contains("missing: stock wine/ winemetal.so (should be missing)"), rts)
        XCTAssertTrue(rts.contains("DXMT overlay current: true"), rts)
        XCTAssertTrue(rts.contains("wine-dxmt/lib/wine/x86_64-windows/d3d11.dll: DXMT's"), rts)
        XCTAssertTrue(rts.contains("wine-dxmt/lib/wine/i386-windows/winemetal.dll: DXMT's"), rts)
        XCTAssertTrue(rts.contains("DXMT overlay stamp:"), rts)
        XCTAssertTrue(report.file("runtimes.txt")!.contents.contains("\"dxmt\""))
        XCTAssertTrue(report.file("bottles/ow.txt")!.contents.contains(#""backend" : "d3dmetal""#))
    }

    func testWritesArchive() throws {
        let sb = try Sandbox()
        let report = DiagnosticReport(files: [.init(name: "summary.txt", contents: "hi\n"), .init(name: "logs/b/x.log", contents: "log\n")])
        let archive = sb.root.appendingPathComponent("out/r.tar.gz")
        try report.writeArchive(to: archive, folderName: "mgx-report-test")
        let unpack = sb.root.appendingPathComponent("unpack")
        try FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)
        let code = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", unpack.path],
                                      environment: ProcessInfo.processInfo.environment, output: .null)
        XCTAssertEqual(code, 0)
        XCTAssertEqual(sb.read(unpack.appendingPathComponent("mgx-report-test/summary.txt")), "hi\n")
        XCTAssertEqual(sb.read(unpack.appendingPathComponent("mgx-report-test/logs/b/x.log")), "log\n")
    }
}

private extension String {
    func repeated(_ n: Int) -> String { String(repeating: self, count: n) }
}

final class ReportPlainTextTests: XCTestCase {
    func testPlainTextSkipsLogsAndJSONByDefault() {
        let r = DiagnosticReport(files: [
            .init(name: "summary.txt", contents: "mgx 0.1.0\n"),
            .init(name: "doctor.txt", contents: "✓ ok"),
            .init(name: "doctor.json", contents: "{}"),
            .init(name: "logs/b/run.log", contents: "wine output\n"),
        ])
        XCTAssertEqual(r.plainText(), "==== summary.txt ====\nmgx 0.1.0\n\n==== doctor.txt ====\n✓ ok\n")
        XCTAssertTrue(r.plainText(includeLogs: true).hasSuffix("==== logs/b/run.log ====\nwine output\n"))
        XCTAssertFalse(r.plainText(includeLogs: true).contains("doctor.json"))
    }
}
