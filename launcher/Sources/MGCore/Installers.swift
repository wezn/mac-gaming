import Foundation

/// Official Windows installers for game stores.
public enum Store: String, CaseIterable, Sendable {
    case steam
    case battlenet

    public var displayName: String { self == .steam ? "Steam" : "Battle.net" }

    public var installerURL: URL {
        switch self {
        case .steam:
            return URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
        case .battlenet:
            return URL(string: "https://www.battle.net/download/getInstallerForGame?os=win&gameProgram=BATTLENET_APP&version=Live")!
        }
    }

    public var installerFileName: String { self == .steam ? "SteamSetup.exe" : "Battle.net-Setup.exe" }

    /// Steam's NSIS installer has a silent mode; Battle.net's installer is interactive.
    public var installerArguments: [String] { self == .steam ? ["/S"] : [] }

    /// Where the client ends up inside the prefix.
    public var clientPath: String {
        switch self {
        case .steam: return #"C:\Program Files (x86)\Steam\steam.exe"#
        case .battlenet: return #"C:\Program Files (x86)\Battle.net\Battle.net Launcher.exe"#
        }
    }

    /// Saved into the store's bottle (values the user already set are kept), so the installer, the
    /// client and the games it starts all get them. Battle.net's Chromium (libcef) writes to its own
    /// copy-on-write mapped pages; without Wine's write-copy simulation its renderer and GPU processes
    /// hit a breakpoint (0x80000003 in libcef) and the client closes. Verified by the Battle.net probe
    /// workflow: 18-19 crashes per run without it, none with it.
    public var bottleEnvironment: [String: String] {
        self == .battlenet ? ["WINE_SIMULATE_WRITECOPY": "1"] : [:]
    }

    /// Chromium switches for the client's built-in browser under Wine on macOS (Steam spells them with `-cef-`).
    /// Battle.net: Battle.net Launcher.exe passes them on to Battle.net.exe. Without --in-process-gpu, DXMT
    /// cannot present from Chromium's GPU process ("cross-process swapchain not supported yet") and the
    /// window freezes; with it alone the window stays black; with --disable-gpu-compositing as well the login
    /// window renders on DXMT and wined3d. Verified by the Battle.net probe workflow.
    public var clientArguments: [String] {
        switch self {
        case .steam: return ["-cef-disable-gpu-compositing", "-cef-in-process-gpu"]
        case .battlenet: return ["--in-process-gpu", "--disable-gpu-compositing"]
        }
    }
}

public enum Downloader {
    /// Downloads with the system curl (HTTPS only, follows redirects, retries), atomically replacing `destination`.
    ///
    /// Two exceptions, for local test servers and fixtures: `file://` URLs are copied, and plain `http://`
    /// is accepted for loopback hosts (127.0.0.1, ::1, localhost) only. Redirects must always be HTTPS.
    /// `progress` gets the number of bytes received so far, a few times a second, from another thread.
    public static func download(_ url: URL, to destination: URL, quiet: Bool = false, maxTime: Int? = nil,
                                progress: ((Int64) -> Void)? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = destination.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        if url.isFileURL {
            do { try fm.copyItem(at: url, to: part) } catch {
                throw MGError.io("cannot read \(url.path): \(error.localizedDescription)")
            }
        } else {
            var args = ["-fL", "--proto", try allowedProtocols(url), "--proto-redir", "=https", "--retry", "3",
                        "--connect-timeout", "30", "-o", part.path]
            args.insert(quiet ? "-sS" : "--progress-bar", at: 0)
            if let maxTime { args += ["--max-time", "\(maxTime)"] }
            args.append(url.absoluteString)
            let poller = progress.map { ProgressPoller(file: part, report: $0) }
            let code: Int32
            do {
                code = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/curl"), args,
                                          environment: ProcessInfo.processInfo.environment, output: .inherit)
                poller?.stop()
            } catch {
                poller?.stop()
                throw error
            }
            guard code == 0 else {
                try? fm.removeItem(at: part)
                throw MGError.processFailed("downloading \(url.absoluteString)", code)
            }
        }
        if let progress, let size = fileSize(part) { progress(size) }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: part, to: destination)
    }

    /// Best-effort size of what `url` serves (a HEAD request, following redirects); nil if unknown.
    public static func contentLength(_ url: URL) -> Int64? {
        if url.isFileURL { return fileSize(url) }
        guard let proto = try? allowedProtocols(url) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mgx-head-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let args = ["-sSIL", "--proto", proto, "--proto-redir", "=https", "--max-time", "20", "-o", out.path, url.absoluteString]
        guard (try? Subprocess.run(URL(fileURLWithPath: "/usr/bin/curl"), args,
                                   environment: ProcessInfo.processInfo.environment, output: .null)) == 0,
              let text = try? String(contentsOf: out, encoding: .utf8) else { return nil }
        return parseContentLength(headers: text)
    }

    /// The last `Content-Length` in `curl -I -L` output (one header block per redirect).
    static func parseContentLength(headers: String) -> Int64? {
        var last: Int64?
        for line in headers.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
            last = Int64(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return last.flatMap { $0 > 0 ? $0 : nil }
    }

    /// curl `--proto` value: HTTPS, or HTTP too for a loopback host.
    static func allowedProtocols(_ url: URL) throws -> String {
        switch url.scheme?.lowercased() {
        case "https": return "=https"
        case "http" where isLoopback(url): return "=http,https"
        default: throw MGError.io("refusing to download \(url.absoluteString): only HTTPS is allowed")
        }
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

/// Reports the size of a growing file a few times a second until stopped.
final class ProgressPoller: @unchecked Sendable {
    private let timer: DispatchSourceTimer

    init(file: URL, report: @escaping (Int64) -> Void) {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler {
            if let size = Downloader.fileSize(file) { report(size) }
        }
        timer.resume()
    }

    func stop() { timer.cancel() }
}
