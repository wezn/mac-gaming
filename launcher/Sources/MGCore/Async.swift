import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Bridges MGCore's synchronous APIs (wineboot, installs, a running game) to Swift concurrency.
///
/// Each call gets its own thread: the work blocks in `waitpid`, `read` or `tar` for seconds to hours,
/// which must not tie up the main actor or a thread of Swift's small cooperative pool.
public enum Blocking {
    /// Runs `body` on a new thread and resumes with its result. Cancelling the calling task does not
    /// interrupt `body` (use `Subprocess.run(...) async` or `Launcher.stop` for that).
    public static func run<T>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let thread = Thread {
                cont.resume(with: Result { try body() })
            }
            thread.name = "mg.blocking"
            thread.stackSize = 4 << 20
            thread.start()
        }
    }
}

/// Tracks a child pid so a cancellation from another thread can signal it.
final class SpawnedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    private var finished = false
    let signal: Int32

    init(signal: Int32) { self.signal = signal }

    func spawned(_ p: pid_t) {
        lock.lock(); defer { lock.unlock() }
        pid = p
        if cancelled { kill(p, signal) }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if pid > 0 && !finished { kill(pid, signal) }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
    }
}

extension Subprocess {
    /// Async `run`: waits on its own thread. Cancelling the task sends `cancelSignal` (default SIGTERM)
    /// to the child; the call then returns the child's exit status (128 + signal) as usual.
    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                           workingDirectory: URL? = nil, output: Output = .inherit,
                           cancelSignal: Int32 = SIGTERM) async throws -> Int32 {
        let proc = SpawnedProcess(signal: cancelSignal)
        return try await withTaskCancellationHandler {
            try await Blocking.run {
                defer { proc.finish() }
                return try Subprocess.run(executable, arguments, environment: environment,
                                          workingDirectory: workingDirectory, output: output,
                                          onSpawn: { proc.spawned($0) })
            }
        } onCancel: {
            proc.cancel()
        }
    }
}
