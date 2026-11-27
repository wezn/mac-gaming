import Foundation
import XCTest
@testable import MGCore

/// Physical path (`/private/var/...` on macOS), matching what `pwd` prints in a child process.
func realPath(_ url: URL) -> String {
    guard let p = realpath(url.path, nil) else { return url.path }
    defer { free(p) }
    return String(cString: p)
}

enum Fixture {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent(name)
    }
}

/// A throwaway MG root with helpers to fake runtimes and GPTK installs.
final class Sandbox {
    let root: URL
    let paths: MGPaths
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("mg-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        paths = MGPaths(root: root.appendingPathComponent("home", isDirectory: true))
    }

    deinit { try? fm.removeItem(at: root) }

    func write(_ path: String, _ contents: String = "x", executable: Bool = false, in base: URL? = nil) throws {
        let url = (base ?? root).appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    /// A `wine/` tree whose `bin/wine` is a script that records how it was called.
    /// (Only tests use a shell script; mg itself never goes through a shell.)
    func makeWineTree(at dir: URL) throws {
        let wine = """
        #!/bin/sh
        echo "wine $*"
        echo "WINEPREFIX=$WINEPREFIX"
        echo "WINEDLLOVERRIDES=$WINEDLLOVERRIDES"
        echo "WINEMSYNC=$WINEMSYNC"
        echo "PWD=$(pwd)"
        if [ "$1" = "wineboot" ]; then
          mkdir -p "$WINEPREFIX/drive_c/windows/system32" "$WINEPREFIX/drive_c/windows/syswow64"
          echo "WINE REGISTRY" > "$WINEPREFIX/system.reg"
        fi
        if [ "$1" = "reg" ]; then echo "$*" >> "$WINEPREFIX/reg.log"; fi
        exit ${FAKE_WINE_EXIT:-0}
        """
        try write("bin/wine", wine, executable: true, in: dir)
        try write("bin/wineserver", "#!/bin/sh\nexit 0\n", executable: true, in: dir)
        try write("lib/libMoltenVK.dylib", in: dir)
        try write("lib/wine/x86_64-windows/d3d11.dll", "wine-builtin-d3d11", in: dir)
        try write("lib/wine/x86_64-unix/ntdll.so", in: dir)
    }

    func makeDXMTTree(at dir: URL) throws {
        for f in ["d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll"] {
            try write("x86_64-windows/\(f)", "dxmt64-\(f)", in: dir)
            try write("i386-windows/\(f)", "dxmt32-\(f)", in: dir)
        }
        try write("x86_64-unix/winemetal.so", "winemetal-unix", in: dir)
    }

    func makeDXVKTree(at dir: URL, d3d8: Bool = false) throws {
        var files = ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"]
        if d3d8 { files.append("d3d8.dll") }
        for f in files {
            try write("x64/\(f)", "dxvk64-\(f)", in: dir)
            try write("x32/\(f)", "dxvk32-\(f)", in: dir)
        }
    }

    /// Fake GPTK `redist/lib` under `<root>/gptk`; returns the folder a user would point at.
    func makeGPTK() throws -> URL {
        let base = root.appendingPathComponent("gptk", isDirectory: true)
        let lib = base.appendingPathComponent("redist/lib", isDirectory: true)
        for f in ["d3d11.dll", "d3d12.dll", "dxgi.dll", "nvapi64.dll"] {
            try write("wine/x86_64-windows/\(f)", "gptk-\(f)", in: lib)
        }
        try write("wine/x86_64-unix/d3d12.so", in: lib)
        try write("external/D3DMetal.framework/Versions/A/D3DMetal", in: lib)
        try fm.createSymbolicLink(atPath: lib.appendingPathComponent("external/D3DMetal.framework/D3DMetal").path,
                                  withDestinationPath: "Versions/A/D3DMetal")
        try write("external/libd3dshared.dylib", in: lib)
        return base
    }

    /// Packs `dirName` (a child of `staging`) into `<root>/<archiveName>` with the system tar.
    func tar(_ staging: URL, _ dirName: String, as archiveName: String) throws -> URL {
        let out = root.appendingPathComponent(archiveName)
        let flags = archiveName.hasSuffix(".xz") ? "-cJf" : "-czf"
        let code = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/tar"), [flags, out.path, "-C", staging.path, dirName],
                                      environment: ProcessInfo.processInfo.environment, output: .null)
        XCTAssertEqual(code, 0, "tar failed")
        return out
    }

    /// Builds wine/dxmt/dxvk tarballs like the CI artifacts.
    func makeArchives() throws -> (wine: URL, dxmt: URL, dxvk: URL) {
        let s = root.appendingPathComponent("pack-\(UUID().uuidString)", isDirectory: true)
        try makeWineTree(at: s.appendingPathComponent("wine"))
        try makeDXMTTree(at: s.appendingPathComponent("dxmt"))
        try makeDXVKTree(at: s.appendingPathComponent("dxvk"))
        return (try tar(s, "wine", as: "wine-crossover-26.3.0-wow64.tar.xz"),
                try tar(s, "dxmt", as: "dxmt-0.61.tar.xz"),
                try tar(s, "dxvk", as: "dxvk-macos-1.10.3.tar.gz"))
    }

    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}
