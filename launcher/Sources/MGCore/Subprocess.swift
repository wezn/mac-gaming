import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Direct `posix_spawn` of a binary: no shell, no `Process` run loop.
public enum Subprocess {
    public enum Output: Equatable, Sendable {
        /// Share mgx's stdout/stderr.
        case inherit
        /// stdout and stderr both go to this file (appended), nothing to the terminal.
        case file(URL)
        /// stdout and stderr go to the file and are echoed to mgx's stderr.
        case tee(URL)
        /// Discard.
        case null
    }

    /// Runs `executable` and waits. Returns the exit code, or 128 + signal number.
    /// `onSpawn` is called with the child's pid right after it starts (the async overload uses it to cancel).
    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                           workingDirectory: URL? = nil, output: Output = .inherit,
                           onSpawn: ((pid_t) -> Void)? = nil) throws -> Int32 {
        var fileFD: Int32 = -1
        var pipeFDs: [Int32] = [-1, -1]
        defer {
            if fileFD >= 0 { close(fileFD) }
        }

        switch output {
        case .inherit: break
        case .null:
            fileFD = open("/dev/null", O_WRONLY)
        case .file(let url), .tee(let url):
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fileFD = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fileFD < 0 { throw MGError.io("cannot open log file \(url.path): \(String(cString: strerror(errno)))") }
        }
        let tee: Bool
        if case .tee = output { tee = true } else { tee = false }
        if tee {
            guard pipe(&pipeFDs) == 0 else { throw MGError.io("pipe failed: \(String(cString: strerror(errno)))") }
        }

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        #else
        var actions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        let sink = tee ? pipeFDs[1] : fileFD
        if sink >= 0 {
            posix_spawn_file_actions_adddup2(&actions, sink, 1)
            posix_spawn_file_actions_adddup2(&actions, sink, 2)
            posix_spawn_file_actions_addclose(&actions, sink)
        }
        if tee { posix_spawn_file_actions_addclose(&actions, pipeFDs[0]) }

        // Per-spawn chdir (macOS 10.15+, glibc 2.29+): changing mgx's own cwd would race in a
        // multi-threaded front end.
        if let wd = workingDirectory {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: wd.path, isDirectory: &isDir), isDir.boolValue else {
                throw MGError.io("cannot enter \(wd.path)")
            }
            posix_spawn_file_actions_addchdir_np(&actions, wd.path)
        }

        // Start the child with no blocked signals and default handlers: a thread's mask and ignored
        // signals are otherwise inherited, so a child spawned from a worker thread of a GUI app could
        // not be stopped with SIGTERM.
        #if canImport(Darwin)
        var attr: posix_spawnattr_t?
        #else
        var attr = posix_spawnattr_t()
        #endif
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGALRM, SIGTERM, SIGCHLD, SIGUSR1, SIGUSR2, SIGTSTP, SIGTTIN, SIGTTOU] {
            sigaddset(&defaults, sig)
        }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        let argv = [executable.path] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }.sorted()
        var pid = pid_t()
        let rc = withCStrings(argv) { cargv in
            withCStrings(envp) { cenv in
                posix_spawn(&pid, executable.path, &actions, &attr, cargv, cenv)
            }
        }
        if tee { close(pipeFDs[1]) }
        guard rc == 0 else {
            if tee { close(pipeFDs[0]) }
            throw MGError.io("cannot start \(executable.path): \(String(cString: strerror(rc)))")
        }
        onSpawn?(pid)

        guard tee else { return try wait(pid) }

        // Poll instead of reading to EOF: wineserver inherits the pipe and outlives wine by a few
        // seconds, so EOF would arrive late. Stop as soon as the child itself has exited.
        let readFD = pipeFDs[0]
        defer { close(readFD) }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        func pump() -> Bool {
            let n = buffer.withUnsafeMutableBytes { read(readFD, $0.baseAddress, $0.count) }
            guard n > 0 else { return false }
            buffer.withUnsafeBytes { raw in
                _ = write(fileFD, raw.baseAddress, n)
                _ = write(2, raw.baseAddress, n)
            }
            return true
        }
        while true {
            var status: Int32 = 0
            let done = waitpid(pid, &status, WNOHANG)
            if done == pid {
                _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
                while pump() {}
                return decode(status)
            }
            if done < 0 && errno != EINTR { throw MGError.io("waitpid: \(String(cString: strerror(errno)))") }
            var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 200)
            if ready > 0 {
                if pfd.revents & Int16(POLLIN) != 0 { _ = pump() }
                else if pfd.revents & Int16(POLLHUP) != 0 { return try wait(pid) }
            }
        }
    }

    static func decode(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }

    static func wait(_ pid: pid_t) throws -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { throw MGError.io("waitpid: \(String(cString: strerror(errno)))") }
        }
        return decode(status)
    }

    static func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        let ptrs = strings.map { strdup($0) } + [nil]
        defer { ptrs.forEach { free($0) } }
        return body(ptrs)
    }

    /// Runs and captures stdout as a string (stderr discarded). For short helper commands only.
    public static func capture(_ executable: URL, _ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> (Int32, String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mg-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let code = try run(executable, arguments, environment: environment, output: .file(tmp))
        let out = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
        return (code, out)
    }
}
