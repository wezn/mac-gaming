import ArgumentParser
import Foundation
import MGCore

extension Backend: ExpressibleByArgument {}

@main
struct MG: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mgx",
        abstract: "Run Windows games on Apple Silicon Macs.",
        version: MG.version,
        subcommands: [Run.self, BottleCommand.self, RuntimeCommand.self, SteamCommand.self, BattlenetCommand.self,
                      ConfigCommand.self, Detect.self, Doctor.self, Logs.self, Report.self, SelfUpdate.self, Licenses.self]
    )
    static let version = MGVersion.string
}

// MARK: shared helpers

enum Context {
    static var paths: MGPaths { MGPaths.standard() }
    static var launcher: Launcher { Launcher(paths: paths) }

    static func note(_ s: String) {
        FileHandle.standardError.write(Data("mgx: \(s)\n".utf8))
    }
}

/// Prints MGCore errors as one line (no usage text: they are not command-line mistakes) and exits 1.
func guarded<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch let e as MGError {
        Context.note("error: \(e.description)")
        throw ExitCode.failure
    } catch let e as PEError {
        Context.note("error: \(e.description)")
        throw ExitCode.failure
    } catch let e as CocoaError {
        Context.note("error: \(e.localizedDescription)")
        throw ExitCode.failure
    }
}

func onOff(_ b: Bool) -> String { b ? "on" : "off" }

// MARK: run

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a Windows program in a bottle.",
        discussion: """
        Everything after the program is passed to it unchanged. The program can be a path on disk,
        a C:\\ path inside the bottle, or a program Wine provides (notepad.exe, winecfg, regedit).

        Backend precedence: --backend, then the per-game override table, then the bottle's backend,
        then auto-detection from the executable's imports (DX12 → d3dmetal, DX11/10 → dxmt,
        DX9 and older → dxvk or wined3d).
        """
    )

    @Option(name: .shortAndLong, help: "Bottle to run in (default: the configured default bottle, else 'default', created on first use).")
    var bottle: String?

    @Option(help: "Graphics backend: \(Backend.allCases.map(\.rawValue).joined(separator: ", ")).")
    var backend: Backend?

    @Option(name: .customLong("env"), help: ArgumentHelp("Extra environment variable (repeatable).", valueName: "KEY=VALUE"))
    var env: [String] = []

    @Flag(inversion: .prefixedNo, help: "Show Apple's Metal performance HUD.")
    var hud: Bool?

    @Flag(inversion: .prefixedNo, help: "Use msync (default: on).")
    var msync: Bool?

    @Flag(inversion: .prefixedNo, help: "Render at full Retina resolution.")
    var retina: Bool?

    @Option(help: ArgumentHelp("WINEDEBUG channels (default: -all).", valueName: "channels"))
    var debug: String?

    @Flag(name: .shortAndLong, help: "Also print Wine's output to the terminal (it always goes to the log).")
    var verbose = false

    @Flag(help: "Print the resolved backend, command and environment, then exit.")
    var dryRun = false

    @Argument(help: "Program to run.")
    var program: String

    @Argument(parsing: .captureForPassthrough, help: "Arguments for the program.")
    var arguments: [String] = []

    func run() throws {
        let code: Int32 = try guarded {
            let launcher = Context.launcher
            let config = try GlobalConfig.load(launcher.paths)
            let name = launcher.bottleName(bottle, config: config)
            if bottle == nil, !launcher.bottles.exists(name) {
                _ = try launcher.bottles.create(BottleConfig(name: name))
                Context.note("created bottle '\(name)'")
            }
            let req = RunRequest(bottle: name, backend: backend, program: program, arguments: arguments,
                                 env: try EnvironmentBuilder.parseAssignments(env),
                                 metalHUD: hud, msync: msync, retina: retina, wineDebug: debug)
            let plan = try launcher.plan(req)
            for w in plan.choice.warnings { Context.note("warning: \(w)") }

            if dryRun {
                printPlan(plan, base: launcher.baseEnvironment)
                return 0
            }
            Context.note("\(plan.programName): \(plan.choice.backend.rawValue) (\(plan.choice.reason)); log: \(plan.logFile.path)")
            try launcher.prepare(plan, output: verbose ? .inherit : .null, log: { Context.note($0) })
            return try launcher.execute(plan, echo: verbose)
        }
        if code != 0 {
            Context.note("exited with code \(code)")
            throw ExitCode(code)
        }
    }

    func printPlan(_ plan: LaunchPlan, base: [String: String]) {
        print("bottle:    \(plan.bottle.name) (\(plan.bottle.prefix.path))")
        print("runtime:   \(plan.runtime.name)")
        print("detected:  \(plan.detection.level)\(plan.detection.evidence.map { " — \($0)" } ?? "")")
        if let note = plan.override?.note { print("override:  \(note)") }
        print("backend:   \(plan.choice.backend.rawValue) (\(plan.choice.reason))")
        print("retina:    \(onOff(plan.retina))")
        for c in plan.setup.copies { print("copy:      \(c.source.path) -> \(c.destination.path)") }
        if let wd = plan.workingDirectory { print("cwd:       \(wd.path)") }
        print("command:   \(plan.commandLine)")
        print("log:       \(plan.logFile.path)")
        print("env (changed from the current environment):")
        for c in plan.environmentChanges(from: base) {
            print(c.value.map { "  \(c.key)=\($0)" } ?? "  unset \(c.key)")
        }
    }
}

// MARK: detect

struct Detect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the DirectX version an executable uses and its imported DLLs.")

    @Argument(help: "Path to a .exe or .dll.")
    var file: String

    @Flag(help: "Don't look at DLLs next to the executable.")
    var noSiblings = false

    func run() throws {
        try guarded {
            let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            let pe = try PEParser.parse(contentsOf: url)
            let d = DirectXDetector.detect(executable: url, scanSiblings: !noSiblings)
            print("\(url.lastPathComponent): \(pe.is64Bit ? "64" : "32")-bit, \(d.level)\(d.evidence.map { " (\($0))" } ?? "")")
            if !pe.imports.isEmpty { print("imports: \(pe.imports.joined(separator: ", "))") }
            if !pe.delayImports.isEmpty { print("delay-load: \(pe.delayImports.joined(separator: ", "))") }
        }
    }
}

// MARK: bottles

struct BottleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottle", abstract: "Create and manage bottles (Wine prefixes).",
        subcommands: [Create.self, List.self, Show.self, Set.self, Delete.self, Stop.self])

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a bottle and initialise its Wine prefix.")
        @Argument var name: String
        @Option(help: "Runtime (default: the default runtime).") var runtime: String?
        @Option(help: "Default backend for programs in this bottle.") var backend: Backend = .auto
        @Flag(inversion: .prefixedNo, help: "msync.") var msync = true
        @Flag(help: "Retina mode.") var retina = false
        @Flag(help: "Metal HUD.") var hud = false
        @Option(name: .customLong("env"), help: ArgumentHelp("Environment variable (repeatable).", valueName: "KEY=VALUE"))
        var env: [String] = []
        @Flag(help: "Only write bottle.json; Wine creates the prefix on first run.") var noInit = false
        @Flag(help: "Make this the default bottle for `mgx run`.") var setDefault = false

        func run() throws {
            try guarded {
                try Context.launcher.createBottle(
                    BottleConfig(name: name, runtime: runtime, backend: backend, env: try EnvironmentBuilder.parseAssignments(env),
                                 msync: msync, retina: retina, metalHUD: hud),
                    initialize: !noInit, makeDefault: setDefault, log: { Context.note($0) })
                print("created bottle \(name)")
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List bottles.")
        func run() throws {
            try guarded {
                let paths = Context.paths
                let config = try GlobalConfig.load(paths)
                let (bottles, errors) = BottleStore(paths: paths).list()
                if bottles.isEmpty && errors.isEmpty { print("no bottles (create one with `mgx bottle create <name>`)") }
                for b in bottles {
                    let c = b.config
                    let star = b.name == config.defaultBottle ? "*" : " "
                    print("\(star) \(b.name)\truntime=\(c.runtime ?? "default") backend=\(c.backend.rawValue) msync=\(onOff(c.msync)) retina=\(onOff(c.retina)) hud=\(onOff(c.metalHUD))\(b.isInitialized ? "" : " (not initialised)")")
                }
                for (n, e) in errors.sorted(by: { $0.key < $1.key }) { print("! \(n)\t\(e)") }
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a bottle's config and path.")
        @Argument var name: String
        func run() throws {
            try guarded {
                let b = try BottleStore(paths: Context.paths).get(name)
                print("path: \(b.prefix.path)")
                print((try? String(contentsOf: b.configFile, encoding: .utf8)) ?? "", terminator: "")
            }
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a bottle's settings.")
        @Argument var name: String
        @Option(help: "Runtime name, or 'default'.") var runtime: String?
        @Option(help: "Default backend.") var backend: Backend?
        @Flag(inversion: .prefixedNo, help: "msync.") var msync: Bool?
        @Flag(inversion: .prefixedNo, help: "Retina mode.") var retina: Bool?
        @Flag(inversion: .prefixedNo, help: "Metal HUD.") var hud: Bool?
        @Option(name: .customLong("env"), help: ArgumentHelp("Set an environment variable (repeatable).", valueName: "KEY=VALUE"))
        var env: [String] = []
        @Option(name: .customLong("unset-env"), help: ArgumentHelp("Remove an environment variable (repeatable).", valueName: "KEY"))
        var unsetEnv: [String] = []

        func run() throws {
            try guarded {
                let assignments = try EnvironmentBuilder.parseAssignments(env)
                let b = try Context.launcher.updateBottle(name) { c in
                    if let r = runtime { c.runtime = r == "default" ? nil : r }
                    if let v = backend { c.backend = v }
                    if let v = msync { c.msync = v }
                    if let v = retina { c.retina = v }
                    if let v = hud { c.metalHUD = v }
                    for (k, v) in assignments { c.env[k] = v }
                    for k in unsetEnv { c.env[k] = nil }
                }
                print((try? String(contentsOf: b.configFile, encoding: .utf8)) ?? "", terminator: "")
            }
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a bottle and everything installed in it.")
        @Argument var name: String
        @Flag(name: .shortAndLong, help: "Don't ask for confirmation.") var yes = false

        func run() throws {
            try guarded {
                let launcher = Context.launcher
                let b = try launcher.bottles.get(name)
                if !yes {
                    guard isatty(0) != 0 else { throw MGError.invalidConfig("refusing to delete \(b.prefix.path) without --yes (stdin is not a terminal)") }
                    print("Delete \(b.prefix.path) and everything installed in it? [y/N] ", terminator: "")
                    guard let line = readLine(), ["y", "yes"].contains(line.lowercased()) else {
                        print("cancelled")
                        return
                    }
                }
                try launcher.deleteBottle(name)
                print("deleted bottle \(name)")
            }
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Kill every Wine process in a bottle (wineserver -k).")
        @Argument var name: String
        func run() throws {
            try guarded {
                let launcher = Context.launcher
                let b = try launcher.bottles.get(name)
                _ = try launcher.stop(b, config: GlobalConfig.load(launcher.paths))
            }
        }
    }
}

// MARK: runtimes

struct RuntimeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runtime", abstract: "Install and manage Wine runtimes and graphics backends.",
        subcommands: [Install.self, Update.self, List.self, Remove.self])

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install Wine and graphics archives into a runtime.",
            discussion: """
            Accepts wine-crossover-*.tar.xz, dxmt-*.tar.xz and dxvk-macos-*.tar.xz files, zipped CI
            artifacts, or a directory containing any of them (searched recursively). Components are
            recognised by their top-level folder (wine/, dxmt/, dxvk/). Graphics-only installs go into
            the default runtime unless --name is given.
            """)
        @Argument(help: "Archives or directories.") var sources: [String]
        @Option(help: "Runtime name (default: from the Wine archive, e.g. crossover-26.3.0-wow64).") var name: String?
        @Flag(help: "Make this the default runtime.") var setDefault = false

        func run() throws {
            try guarded {
                let urls = sources.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                let r = try RuntimeStore(paths: Context.paths).install(sources: urls, name: name, makeDefault: setDefault,
                                                                      log: { Context.note($0) })
                print("runtime \(r.runtime): installed \(r.installed.keys.sorted().joined(separator: ", "))\(r.madeDefault ? " (default)" : "")")
            }
        }
    }

    struct Update: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download and install the latest release's Wine, DXMT and DXVK.",
            discussion: """
            Reads the latest release's manifest.json (GitHub Releases, or MG_UPDATE_URL / `mgx config set
            update-url`), skips components the runtime already has at that version, and checks every
            download's SHA-256 before installing. A new Wine version becomes a new runtime (named after its
            archive, e.g. crossover-26.3.0-wow64) and the default; older runtimes stay until removed.
            """)
        @Flag(help: "Only report what would be installed.") var check = false

        func run() throws {
            try guarded {
                var updater = try Updater.standard(paths: Context.paths)
                Context.note("checking \(updater.source)")
                let m = try updater.fetchManifest()
                let plan = try updater.planRuntimeUpdate(m)
                for a in plan.current { print("up to date: \(a.kind) \(a.version) (\(a.file))") }
                if plan.isUpToDate {
                    print("runtime \(plan.runtime) is up to date (release \(m.version))")
                    return
                }
                for a in plan.install { print("\(check ? "available" : "installing"): \(a.kind) \(a.version) (\(a.file))") }
                if check {
                    print("run `mgx runtime update` to install \(plan.isNewRuntime ? "runtime \(plan.runtime)" : "into runtime \(plan.runtime)")")
                    return
                }
                fflush(stdout)
                updater.download = { try Downloader.download($0, to: $1) }   // with a progress bar
                guard let r = try updater.updateRuntime(m, plan: plan, log: { Context.note($0) }) else { return }
                print("runtime \(r.runtime): installed \(r.installed.keys.sorted().joined(separator: ", "))\(r.madeDefault ? " (default)" : "")")
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List installed runtimes.")
        func run() throws {
            try guarded {
                let paths = Context.paths
                let store = RuntimeStore(paths: paths)
                let def = try? store.resolve(nil, config: GlobalConfig.load(paths)).name
                let all = store.list()
                if all.isEmpty { print("no runtimes (install one with `mgx runtime install <path>`)") }
                for rt in all {
                    let m = rt.manifest()
                    let parts = ["wine", "dxmt", "dxvk"].compactMap { c in m.components[c].map { "\(c) \($0.version ?? $0.archive)" } }
                    print("\(rt.name == def ? "*" : " ") \(rt.name)\t\(parts.joined(separator: ", "))")
                }
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a runtime.")
        @Argument var name: String
        func run() throws {
            try guarded {
                try RuntimeStore(paths: Context.paths).remove(name)
                print("removed runtime \(name)")
            }
        }
    }
}

// MARK: stores

protocol StoreCommand {
    static var store: Store { get }
}

struct StoreInstall<S: StoreCommand>: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(commandName: "install", abstract: "Download the official \(S.store.displayName) installer and run it in a bottle.")
    }
    @Option(name: .shortAndLong, help: "Bottle (created if missing).") var bottle: String
    @Option(help: "Backend for the bottle if it is created (games launched from the client inherit it).") var backend: Backend = .auto
    @Flag(help: "Download again even if the installer is cached.") var redownload = false

    func run() throws {
        let code: Int32 = try guarded {
            let launcher = Context.launcher
            let s = S.store
            let plan = try launcher.planStoreInstall(s, bottle: bottle, backend: backend, redownload: redownload,
                                                     download: { try Downloader.download($0, to: $1) },
                                                     log: { Context.note($0) })
            Context.note("running \(s.installerFileName); log: \(plan.logFile.path)")
            try launcher.prepare(plan, log: { Context.note($0) })
            let code = try launcher.execute(plan)
            if code == 0 { print("\(s.displayName) installed. Start it with `mgx \(s.rawValue) run --bottle \(bottle)`") }
            return code
        }
        if code != 0 { throw ExitCode(code) }
    }
}

struct StoreRun<S: StoreCommand>: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(commandName: "run", abstract: "Start \(S.store.displayName) in a bottle.")
    }
    @Option(name: .shortAndLong) var bottle: String
    @Option(help: "Backend (default: the bottle's).") var backend: Backend?
    @Flag(name: .shortAndLong, help: "Also print output to the terminal.") var verbose = false
    @Argument(parsing: .captureForPassthrough, help: "Extra client arguments.") var arguments: [String] = []

    func run() throws {
        let code: Int32 = try guarded {
            let launcher = Context.launcher
            let s = S.store
            let plan = try launcher.planStoreClient(s, bottle: bottle, backend: backend, arguments: arguments)
            Context.note("\(s.displayName): \(plan.choice.backend.rawValue) (\(plan.choice.reason)); log: \(plan.logFile.path)")
            try launcher.prepare(plan, log: { Context.note($0) })
            return try launcher.execute(plan, echo: verbose)
        }
        if code != 0 { throw ExitCode(code) }
    }
}

struct SteamCommand: ParsableCommand, StoreCommand {
    static let store = Store.steam
    static let configuration = CommandConfiguration(commandName: "steam", abstract: "Install and run Steam.",
                                                    subcommands: [StoreInstall<SteamCommand>.self, StoreRun<SteamCommand>.self])
}

struct BattlenetCommand: ParsableCommand, StoreCommand {
    static let store = Store.battlenet
    static let configuration = CommandConfiguration(commandName: "battlenet", abstract: "Install and run Battle.net.",
                                                    subcommands: [StoreInstall<BattlenetCommand>.self, StoreRun<BattlenetCommand>.self])
}

// MARK: config

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config", abstract: "Global settings: gptk, default-runtime, default-bottle, update-url.",
        subcommands: [Show.self, SetValue.self, Unset.self], defaultSubcommand: Show.self)

    enum Key: String, ExpressibleByArgument, CaseIterable {
        case gptk, defaultRuntime = "default-runtime", defaultBottle = "default-bottle", updateURL = "update-url"
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Print settings and paths.")
        func run() throws {
            try guarded {
                let paths = Context.paths
                let c = try GlobalConfig.load(paths)
                print("root:            \(paths.root.path)")
                print("gptk:            \(c.gptkPath ?? "(not set)")")
                print("default-runtime: \(c.defaultRuntime ?? "(not set)")")
                print("default-bottle:  \(c.defaultBottle ?? "(not set: 'default')")")
                print("update-url:      \(c.updateURL ?? "(not set: \(UpdateSource.default))")")
                print("overrides:       \(paths.overridesFile.path)")
            }
        }
    }

    struct SetValue: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a value.")
        @Argument var key: Key
        @Argument var value: String
        func run() throws {
            try guarded {
                let launcher = Context.launcher
                switch key {
                case .gptk:
                    if let g = try launcher.setGPTKPath(value) { print("D3DMetal from \(g.libRoot.path)") }
                case .defaultRuntime: try launcher.setDefaultRuntime(value)
                case .defaultBottle: try launcher.setDefaultBottle(value)
                case .updateURL: try launcher.setUpdateURL(value)
                }
            }
        }
    }

    struct Unset: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "unset", abstract: "Clear a value.")
        @Argument var key: Key
        func run() throws {
            try guarded {
                let launcher = Context.launcher
                switch key {
                case .gptk: try launcher.setGPTKPath(nil)
                case .defaultRuntime: try launcher.setDefaultRuntime(nil)
                case .defaultBottle: try launcher.setDefaultBottle(nil)
                case .updateURL: try launcher.setUpdateURL(nil)
                }
            }
        }
    }
}

// MARK: doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check Rosetta, macOS, runtimes, backends and the GPTK path.")
    @Flag(help: "Print the checks as JSON.") var json = false

    func run() throws {
        let checks = MGCore.Doctor(paths: Context.paths).run()
        print(json ? MGCore.Doctor.json(checks) : MGCore.Doctor.render(checks), terminator: "")
        if checks.contains(where: { $0.status == .error }) { throw ExitCode(1) }
    }
}

// MARK: self-update

struct SelfUpdate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-update",
        abstract: "Replace this mgx with the latest release's.",
        discussion: """
        Downloads mgx-<version>-macos-arm64.tar.gz from the latest release (or MG_UPDATE_URL), checks its
        SHA-256, checks that the new binary runs and reports that version, then renames it over this one
        (atomic: a failed update leaves the old mgx). The app updates itself with Check for Updates….
        """)
    @Flag(help: "Only report whether an update is available.") var check = false
    @Flag(help: "Install even if this version is the same or newer.") var force = false

    func run() throws {
        try guarded {
            var updater = try Updater.standard(paths: Context.paths)
            Context.note("checking \(updater.source)")
            let m = try updater.fetchManifest()
            guard force || updater.isNewer(m) else {
                print("mgx \(MG.version) is up to date (latest release: \(m.version))")
                return
            }
            if check {
                print("mgx \(m.version) is available (this is \(MG.version)); run `mgx self-update`")
                return
            }
            guard let exe = Bundle.main.executableURL else { throw MGError.update("cannot tell where this mgx is installed") }
            updater.download = { try Downloader.download($0, to: $1) }
            try updater.installCLI(m, replacing: exe, log: { Context.note($0) })
            print("mgx \(m.version) installed (was \(MG.version))")
        }
    }
}

// MARK: report

struct Report: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Bundle doctor output, settings and recent logs for a bug report.",
        discussion: """
        Writes a .tar.gz (or a directory, if --output does not end in .tar.gz or .tgz) with host facts,
        `mgx doctor` as text and JSON, config.json, overrides.json, runtime manifests, the D3DMetal overlay
        state, bottle settings and the newest run logs. Your home directory is replaced with ~ and your
        account name with USER. Skim the files before posting them publicly.
        """)
    @Option(name: .shortAndLong, help: "Output file or directory (default: ./mgx-report-<time>.tar.gz).") var output: String?
    @Option(help: "How many of the newest logs to include.") var logs = 10
    @Option(help: "Keep only the last N KiB of each log.") var logKib = 512

    func run() throws {
        try guarded {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = f.string(from: Date())
            let folder = "mgx-report-\(stamp)"
            let out = URL(fileURLWithPath: ((output ?? "\(folder).tar.gz") as NSString).expandingTildeInPath)
            let report = DiagnosticReport.collect(paths: Context.paths, doctor: MGCore.Doctor(paths: Context.paths),
                                                  toolVersion: MG.version, logCount: logs, maxLogBytes: max(1, logKib) * 1024)
            if out.pathExtension == "tgz" || out.lastPathComponent.hasSuffix(".tar.gz") {
                try report.writeArchive(to: out, folderName: folder)
            } else {
                try report.write(to: out)
            }
            print(out.path)
        }
    }
}

// MARK: logs

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List run logs, or print one.")
    @Option(name: .shortAndLong, help: "Only this bottle.") var bottle: String?
    @Flag(help: "Print the newest log.") var last = false
    @Flag(help: "Print paths only.") var path = false
    @Option(name: .short, help: "How many to list.") var count = 20

    func run() throws {
        let entries = LogStore(paths: Context.paths).list(bottle: bottle)
        if last {
            guard let e = entries.first else { throw ValidationError("no logs yet") }
            if path { print(e.url.path); return }
            FileHandle.standardOutput.write((try? Data(contentsOf: e.url)) ?? Data())
            return
        }
        if entries.isEmpty { print("no logs yet") }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for e in entries.prefix(count) {
            print(path ? e.url.path : "\(f.string(from: e.modified))  \(e.bottle)\t\(ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file))\t\(e.url.path)")
        }
    }
}
