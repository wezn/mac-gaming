import ArgumentParser
import Foundation
import MGCore

extension Backend: ExpressibleByArgument {}

@main
struct MG: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mg",
        abstract: "Run Windows games on Apple Silicon Macs.",
        version: "0.1.0",
        subcommands: [Run.self, BottleCommand.self, RuntimeCommand.self, SteamCommand.self, BattlenetCommand.self,
                      ConfigCommand.self, Detect.self, Doctor.self, Logs.self]
    )
}

// MARK: shared helpers

enum Context {
    static var paths: MGPaths { MGPaths.standard() }
    static var launcher: Launcher { Launcher(paths: paths) }

    static func note(_ s: String) {
        FileHandle.standardError.write(Data("mg: \(s)\n".utf8))
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
        print("command:   \(([plan.executable.path] + plan.arguments).joined(separator: " "))")
        print("log:       \(plan.logFile.path)")
        print("env (changed from the current environment):")
        for (k, v) in plan.environment.sorted(by: { $0.key < $1.key }) where base[k] != v {
            print("  \(k)=\(v)")
        }
        for k in base.keys.sorted() where plan.environment[k] == nil { print("  unset \(k)") }
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
        @Flag(help: "Make this the default bottle for `mg run`.") var setDefault = false

        func run() throws {
            try guarded {
                let launcher = Context.launcher
                let config = try GlobalConfig.load(launcher.paths)
                let rt = try launcher.runtimes.resolve(runtime, config: config)
                let bottle = try launcher.bottles.create(BottleConfig(
                    name: name, runtime: runtime, backend: backend, env: try EnvironmentBuilder.parseAssignments(env),
                    msync: msync, retina: retina, metalHUD: hud))
                if !noInit {
                    Context.note("initialising \(bottle.prefix.path) with \(rt.name)")
                    do {
                        try launcher.initializePrefix(bottle, runtime: rt)
                    } catch {
                        try? launcher.bottles.delete(name)
                        throw error
                    }
                }
                if setDefault {
                    var c = config
                    c.defaultBottle = name
                    try c.save(launcher.paths)
                }
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
                if bottles.isEmpty && errors.isEmpty { print("no bottles (create one with `mg bottle create <name>`)") }
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
                let store = BottleStore(paths: Context.paths)
                var b = try store.get(name)
                if let r = runtime {
                    if r == "default" { b.config.runtime = nil } else { _ = try RuntimeStore(paths: Context.paths).get(r); b.config.runtime = r }
                }
                if let v = backend { b.config.backend = v }
                if let v = msync { b.config.msync = v }
                if let v = retina { b.config.retina = v }
                if let v = hud { b.config.metalHUD = v }
                for (k, v) in try EnvironmentBuilder.parseAssignments(env) { b.config.env[k] = v }
                for k in unsetEnv { b.config.env[k] = nil }
                try store.save(b)
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
                _ = try? launcher.stop(b, config: GlobalConfig.load(launcher.paths))
                try launcher.bottles.delete(name)
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
        subcommands: [Install.self, List.self, Remove.self])

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

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List installed runtimes.")
        func run() throws {
            try guarded {
                let paths = Context.paths
                let store = RuntimeStore(paths: paths)
                let def = try? store.resolve(nil, config: GlobalConfig.load(paths)).name
                let all = store.list()
                if all.isEmpty { print("no runtimes (install one with `mg runtime install <path>`)") }
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
            if !launcher.bottles.exists(bottle) {
                let rt = try launcher.runtimes.resolve(nil, config: GlobalConfig.load(launcher.paths))
                let b = try launcher.bottles.create(BottleConfig(name: bottle, backend: backend))
                Context.note("created bottle '\(bottle)'")
                try launcher.initializePrefix(b, runtime: rt)
            }
            let file = launcher.paths.cache.appendingPathComponent("installers/\(s.installerFileName)")
            if redownload || !FileManager.default.fileExists(atPath: file.path) {
                Context.note("downloading \(s.installerURL.absoluteString)")
                try Downloader.download(s.installerURL, to: file)
            }
            let plan = try launcher.plan(RunRequest(bottle: bottle, backend: .wined3d, program: file.path, arguments: s.installerArguments))
            Context.note("running \(s.installerFileName); log: \(plan.logFile.path)")
            try launcher.prepare(plan, log: { Context.note($0) })
            let code = try launcher.execute(plan)
            if code == 0 { print("\(s.displayName) installed. Start it with `mg \(s.rawValue) run --bottle \(bottle)`") }
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
            let b = try launcher.bottles.get(bottle)
            guard let exe = b.unixPath(forWindowsPath: s.clientPath), FileManager.default.fileExists(atPath: exe.path) else {
                throw MGError.io("\(s.displayName) is not installed in bottle '\(bottle)': run `mg \(s.rawValue) install --bottle \(bottle)`")
            }
            let plan = try launcher.plan(RunRequest(bottle: bottle, backend: backend, program: exe.path, arguments: s.clientArguments + arguments))
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
        commandName: "config", abstract: "Global settings: gptk, default-runtime, default-bottle.",
        subcommands: [Show.self, SetValue.self, Unset.self], defaultSubcommand: Show.self)

    enum Key: String, ExpressibleByArgument, CaseIterable {
        case gptk, defaultRuntime = "default-runtime", defaultBottle = "default-bottle"
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
                let paths = Context.paths
                var c = try GlobalConfig.load(paths)
                switch key {
                case .gptk:
                    let full = URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL.path
                    guard let g = GPTKInstall.resolve(full) else {
                        throw MGError.invalidConfig("\(full) does not look like a Game Porting Toolkit: expected lib/wine/x86_64-windows/d3d12.dll and lib/external/ (e.g. the mounted 'Evaluation environment for Windows games' volume or its redist/lib folder)")
                    }
                    c.gptkPath = full
                    print("D3DMetal from \(g.libRoot.path)")
                case .defaultRuntime:
                    _ = try RuntimeStore(paths: paths).get(value)
                    c.defaultRuntime = value
                case .defaultBottle:
                    _ = try BottleStore(paths: paths).get(value)
                    c.defaultBottle = value
                }
                try c.save(paths)
            }
        }
    }

    struct Unset: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "unset", abstract: "Clear a value.")
        @Argument var key: Key
        func run() throws {
            try guarded {
                let paths = Context.paths
                var c = try GlobalConfig.load(paths)
                switch key {
                case .gptk: c.gptkPath = nil
                case .defaultRuntime: c.defaultRuntime = nil
                case .defaultBottle: c.defaultBottle = nil
                }
                try c.save(paths)
            }
        }
    }
}

// MARK: doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check Rosetta, macOS, runtimes, backends and the GPTK path.")
    func run() throws {
        let checks = MGCore.Doctor(paths: Context.paths).run()
        for c in checks {
            let mark = c.status == .ok ? "✓" : c.status == .warning ? "!" : "✗"
            print("\(mark) \(c.title)\(c.detail.isEmpty ? "" : "\n    \(c.detail)")")
        }
        if checks.contains(where: { $0.status == .error }) { throw ExitCode(1) }
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
