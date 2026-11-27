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

    /// Steam's Chromium UI needs these under Wine on macOS.
    public var clientArguments: [String] { self == .steam ? ["-cef-disable-gpu-compositing", "-cef-in-process-gpu"] : [] }
}

public enum Downloader {
    /// Downloads with the system curl (HTTPS only, follows redirects, retries), atomically replacing `destination`.
    public static func download(_ url: URL, to destination: URL, quiet: Bool = false) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        var args = ["-fL", "--proto", "=https", "--proto-redir", "=https", "--retry", "3", "-o", part.path]
        args.insert(quiet ? "-sS" : "--progress-bar", at: 0)
        args.append(url.absoluteString)
        let code = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/curl"), args,
                                      environment: ProcessInfo.processInfo.environment, output: .inherit)
        guard code == 0 else {
            try? FileManager.default.removeItem(at: part)
            throw MGError.processFailed("downloading \(url.absoluteString)", code)
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: part, to: destination)
    }
}
