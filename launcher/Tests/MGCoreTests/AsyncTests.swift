import XCTest
@testable import MGCore

final class AsyncTests: XCTestCase {
    func testBlockingRunReturnsAndThrows() async throws {
        let v = try await Blocking.run { 21 * 2 }
        XCTAssertEqual(v, 42)
        do {
            _ = try await Blocking.run { () throws -> Int in throw MGError.io("boom") }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MGError, .io("boom"))
        }
    }

    func testBlockingRunDoesNotUseTheCallingThread() async throws {
        // Many concurrent blocking calls must not starve each other (each has its own thread).
        let start = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { try await Blocking.run { Thread.sleep(forTimeInterval: 0.3) } }
            }
            try await group.waitForAll()
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0)
    }

    func testAsyncSubprocessExitCodeAndOutput() async throws {
        let sb = try Sandbox()
        let log = sb.root.appendingPathComponent("out.log")
        let code = try await Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo hi; exit 3"],
                                            environment: ["PATH": "/usr/bin:/bin"], output: .file(log))
        XCTAssertEqual(code, 3)
        XCTAssertEqual(sb.read(log), "hi\n")
    }

    func testCancellingTheTaskTerminatesTheChild() async throws {
        let task = Task {
            try await Subprocess.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], environment: [:], output: .null)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        task.cancel()
        let code = try await task.value
        XCTAssertEqual(code, 128 + SIGTERM)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testCancelledBeforeSpawnStillTerminates() async throws {
        let task = Task {
            try await Subprocess.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], environment: [:], output: .null)
        }
        task.cancel()
        let code = try await task.value
        XCTAssertEqual(code, 128 + SIGTERM)
    }

    func testOnSpawnReportsThePid() throws {
        var pid: pid_t = 0
        let code = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 0"], environment: [:], output: .null,
                                      onSpawn: { pid = $0 })
        XCTAssertEqual(code, 0)
        XCTAssertGreaterThan(pid, 0)
    }
}
