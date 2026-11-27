import Foundation

/// What the user asked for with `mg run`.
public struct RunRequest: Equatable, Sendable {
    public var bottle: String?
    public var backend: Backend?
    /// A path on disk, a `C:\` path, or a program in the prefix such as `notepad.exe` or `winecfg`.
    public var program: String
    public var arguments: [String]
    public var env: [String: String]
    public var metalHUD: Bool?
    public var msync: Bool?
    public var retina: Bool?
    public var wineDebug: String?

    public init(bottle: String? = nil, backend: Backend? = nil, program: String, arguments: [String] = [],
                env: [String: String] = [:], metalHUD: Bool? = nil, msync: Bool? = nil, retina: Bool? = nil,
                wineDebug: String? = nil) {
        self.bottle = bottle
        self.backend = backend
        self.program = program
        self.arguments = arguments
        self.env = env
        self.metalHUD = metalHUD
        self.msync = msync
        self.retina = retina
        self.wineDebug = wineDebug
    }
}

/// A fully resolved launch, computed without touching the bottle (so `--dry-run` is free).
public struct LaunchPlan: Equatable, Sendable {
    public var bottle: Bottle
    public var runtime: Runtime
    public var detection: DirectXDetection
    public var choice: BackendChoice
    public var setup: BackendSetup
    public var override: GameOverride?
    public var retina: Bool
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL?
    public var logFile: URL
    /// File name used for the per-game override lookup and the log name.
    public var programName: String
}

public struct Launcher: Sendable {
    public let paths: MGPaths
    public var baseEnvironment: [String: String]

    public init(paths: MGPaths, baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.baseEnvironment = baseEnvironment
    }

    public var bottles: BottleStore { BottleStore(paths: paths) }
    public var runtimes: RuntimeStore { RuntimeStore(paths: paths) }

    /// Bottle named on the command line, else the configured default, else `default`.
    public func bottleName(_ requested: String?, config: GlobalConfig) -> String {
        requested ?? config.defaultBottle ?? "default"
    }

    public func gptk(_ config: GlobalConfig) -> GPTKInstall? {
        let path = baseEnvironment["MG_GPTK"].flatMap { $0.isEmpty ? nil : $0 } ?? config.gptkPath
        return path.flatMap(GPTKInstall.resolve)
    }

    public func availability(runtime: Runtime, gptk: GPTKInstall?) -> BackendAvailability {
        BackendAvailability(dxmt: runtime.hasDXMT, dxvk: runtime.hasDXVK, dxvkD3D8: runtime.dxvkHasD3D8, d3dmetal: gptk != nil)
    }

    public func plan(_ req: RunRequest) throws -> LaunchPlan {
        let config = try GlobalConfig.load(paths)
        let bottle = try bottles.get(bottleName(req.bottle, config: config))
        let runtime = try runtimes.resolve(bottle.config.runtime, config: config)
        guard runtime.hasWine else {
            throw MGError.invalidArchive("runtime '\(runtime.name)' has no Wine (install a wine-crossover-*.tar.xz into it)")
        }
        let gptk = self.gptk(config)

        // Resolve the program: a file on disk gets scanned and run from its own folder.
        let expanded = (req.program as NSString).expandingTildeInPath
        let onDisk = FileManager.default.fileExists(atPath: expanded) && !req.program.contains("\\")
        let programURL = onDisk ? URL(fileURLWithPath: expanded).standardizedFileURL : nil
        let programName = programURL?.lastPathComponent
            ?? String(req.program.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? Substring(req.program))
        let detection = programURL.map { DirectXDetector.detect(executable: $0) } ?? .unknown

        let override = try GameOverrideTable.load(paths).lookup(executable: programName)
        let choice = try BackendSelector.select(requested: req.backend, override: override, bottleBackend: bottle.config.backend,
                                                detection: detection, available: availability(runtime: runtime, gptk: gptk),
                                                executableName: programName)
        let setup = BackendFiles.setup(for: choice.backend, runtime: runtime, prefix: bottle.prefix, gptk: gptk)

        let spec = EnvironmentSpec(
            prefix: bottle.prefix, wineRoot: setup.wineRoot, libraryDirs: setup.libraryDirs,
            dllOverrides: setup.overrides,
            msync: req.msync ?? override?.msync ?? bottle.config.msync,
            metalHUD: req.metalHUD ?? bottle.config.metalHUD,
            wineDebug: req.wineDebug,
            backendEnv: setup.env, gameEnv: override?.env ?? [:], bottleEnv: bottle.config.env, cliEnv: req.env)
        let env = EnvironmentBuilder.build(base: baseEnvironment, spec: spec)

        let target = programURL?.path ?? req.program
        let lower = programName.lowercased()
        let args: [String]
        if lower.hasSuffix(".msi") {
            args = ["msiexec", "/i", target] + req.arguments
        } else if lower.hasSuffix(".bat") || lower.hasSuffix(".cmd") {
            args = ["cmd", "/c", target] + req.arguments
        } else {
            args = [target] + req.arguments
        }

        return LaunchPlan(
            bottle: bottle, runtime: runtime, detection: detection, choice: choice, setup: setup, override: override,
            retina: req.retina ?? override?.retina ?? bottle.config.retina,
            executable: Runtime.wineBinary(in: setup.wineRoot), arguments: args, environment: env,
            workingDirectory: programURL?.deletingLastPathComponent(),
            logFile: LogStore(paths: paths).newLogFile(bottle: bottle.name, executable: programName),
            programName: programName)
    }

    /// Makes the bottle match the plan: prefix initialised, backend files in place, Retina applied.
    /// Each step is skipped when already done, so a repeat launch only stats a few files.
    public func prepare(_ plan: LaunchPlan, output: Subprocess.Output = .null, log: (String) -> Void = { _ in }) throws {
        if plan.setup.backend == .dxmt, try BackendFiles.ensureDXMTOverlay(runtime: plan.runtime) {
            log("built \(plan.runtime.dxmtWineRoot.path) (Wine with DXMT merged in)")
        }
        if let gptk = plan.setup.gptk, try BackendFiles.ensureD3DMetalOverlay(runtime: plan.runtime, gptk: gptk) {
            log("built D3DMetal overlay from \(gptk.libRoot.path)")
        }
        if !plan.bottle.isInitialized {
            log("initialising prefix \(plan.bottle.prefix.path)")
            try initializePrefix(plan.bottle, runtime: plan.runtime, output: output)
        }
        let changed = try BackendFiles.deploy(plan.setup.copies)
        if changed > 0 { log("copied \(changed) \(plan.setup.backend.rawValue) DLL(s) into the bottle") }

        var state = bottles.state(plan.bottle)
        // Wine's own default is RetinaMode off, so a fresh bottle only needs the registry write for "on".
        if (state.retinaApplied ?? false) != plan.retina {
            log("setting RetinaMode=\(plan.retina ? "y" : "n")")
            let code = try Subprocess.run(
                plan.executable,
                ["reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode", "/t", "REG_SZ", "/d", plan.retina ? "y" : "n", "/f"],
                environment: plan.environment, output: output)
            guard code == 0 else { throw MGError.processFailed("setting RetinaMode", code) }
            state.retinaApplied = plan.retina
            try bottles.saveState(state, plan.bottle)
        }
    }

    /// Runs the planned program and waits for it. Output goes to `plan.logFile` (and the terminal with `echo`).
    public func execute(_ plan: LaunchPlan, echo: Bool = false) throws -> Int32 {
        let header = """
        # mg run \(plan.programName) in bottle \(plan.bottle.name) at \(ISO8601DateFormatter().string(from: Date()))
        # backend: \(plan.choice.backend.rawValue) (\(plan.choice.reason))
        # command: \(([plan.executable.path] + plan.arguments).joined(separator: " "))
        # WINEDLLOVERRIDES=\(plan.environment["WINEDLLOVERRIDES"] ?? "")

        """
        try FileManager.default.createDirectory(at: plan.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(header.utf8).write(to: plan.logFile)
        LogStore(paths: paths).prune(bottle: plan.bottle.name)
        return try Subprocess.run(plan.executable, plan.arguments, environment: plan.environment,
                                  workingDirectory: plan.workingDirectory, output: echo ? .tee(plan.logFile) : .file(plan.logFile))
    }

    /// `wineboot --init` without the wine-mono/wine-gecko download prompts (they would block a headless run).
    public func initializePrefix(_ bottle: Bottle, runtime: Runtime, output: Subprocess.Output = .null) throws {
        var env = EnvironmentBuilder.build(base: baseEnvironment, spec: EnvironmentSpec(
            prefix: bottle.prefix, wineRoot: runtime.wineRoot,
            dllOverrides: DLLOverrides(["mscoree": "", "mshtml": ""]),
            msync: bottle.config.msync))
        env["WINEDEBUG"] = env["WINEDEBUG"] ?? "-all"
        let code = try Subprocess.run(runtime.wineBinary, ["wineboot", "--init"], environment: env, output: output)
        guard code == 0 else { throw MGError.processFailed("wineboot --init", code) }
        // Wait for wineserver so the registry is flushed before we read or copy anything.
        _ = try? Subprocess.run(runtime.wineserver, ["-w"], environment: env, output: output)
    }

    /// `wineserver -k`: ends every Wine process in the bottle.
    public func stop(_ bottle: Bottle, config: GlobalConfig) throws -> Int32 {
        let runtime = try runtimes.resolve(bottle.config.runtime, config: config)
        let env = EnvironmentBuilder.build(base: baseEnvironment, spec: EnvironmentSpec(prefix: bottle.prefix, wineRoot: runtime.wineRoot))
        return try Subprocess.run(runtime.wineserver, ["-k"], environment: env, output: .null)
    }
}
