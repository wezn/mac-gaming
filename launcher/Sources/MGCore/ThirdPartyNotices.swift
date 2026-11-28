import Foundation

/// `THIRD_PARTY_NOTICES.md`: the licenses of everything MacGaming ships. Release builds put it next to
/// `mgx` (in the mgx tarball) and into `MacGaming.app/Contents/Resources`. `mgx licenses` prints it
/// and the app's Acknowledgements window shows it.
public enum ThirdPartyNotices {
    public static let fileName = "THIRD_PARTY_NOTICES.md"

    /// The copy in the repository at the tag of `version`, for builds that do not carry the file.
    public static func onlineURL(version: String = MGVersion.string) -> URL {
        URL(string: "https://github.com/wezn/mac-gaming/blob/v\(version)/\(fileName)")!
    }

    /// Where to look for the file, in order, given the running executable. Both the path as invoked and
    /// the path with symlinks resolved are tried, so `/usr/local/bin/mgx -> ~/mgx/mgx` still finds
    /// `~/mgx/THIRD_PARTY_NOTICES.md`.
    ///
    /// - `<dir>/THIRD_PARTY_NOTICES.md`: the mgx tarball.
    /// - `<dir>/../Resources/THIRD_PARTY_NOTICES.md`: an app bundle (`Contents/MacOS` → `Contents/Resources`).
    /// - `<dir>/../share/mac-gaming/THIRD_PARTY_NOTICES.md`: an install prefix (`bin/` + `share/`).
    public static func candidates(executable: URL) -> [URL] {
        var dirs: [URL] = []
        for exe in [executable.standardizedFileURL, executable.resolvingSymlinksInPath()] {
            let dir = exe.deletingLastPathComponent().standardizedFileURL
            if !dirs.contains(dir) { dirs.append(dir) }
        }
        var out: [URL] = []
        for dir in dirs {
            out.append(dir.appendingPathComponent(fileName))
            out.append(dir.deletingLastPathComponent().appendingPathComponent("Resources/\(fileName)").standardizedFileURL)
            out.append(dir.deletingLastPathComponent().appendingPathComponent("share/mac-gaming/\(fileName)").standardizedFileURL)
        }
        return out
    }

    /// The first candidate that is a readable regular file.
    public static func locate(executable: URL, fileManager: FileManager = .default) -> URL? {
        candidates(executable: executable).first { url in
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
                && fileManager.isReadableFile(atPath: url.path)
        }
    }

    /// The running process's executable.
    public static var currentExecutable: URL {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }
}
