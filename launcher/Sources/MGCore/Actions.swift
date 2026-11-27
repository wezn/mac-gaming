import Foundation

// Operations shared by the CLI and the app. Each validates its input and leaves disk in a
// consistent state on failure; none prints anything (progress goes to `log`).

extension Launcher {
    // MARK: bottles

    /// Creates a bottle and, unless `initialize` is false, runs `wineboot --init` in it. A bottle whose
    /// init fails is deleted again, so a failed create can simply be retried.
    @discardableResult
    public func createBottle(_ config: BottleConfig, initialize: Bool = true, makeDefault: Bool = false,
                             output: Subprocess.Output = .null, log: (String) -> Void = { _ in }) throws -> Bottle {
        let global = try GlobalConfig.load(paths)
        let rt = try runtimes.resolve(config.runtime, config: global)
        let bottle = try bottles.create(config)
        if initialize {
            log("initialising \(bottle.prefix.path) with \(rt.name)")
            do {
                try initializePrefix(bottle, runtime: rt, output: output)
            } catch {
                try? bottles.delete(bottle.name)
                throw error
            }
        }
        if makeDefault {
            var c = try GlobalConfig.load(paths)
            c.defaultBottle = bottle.name
            try c.save(paths)
        }
        return bottle
    }

    /// Loads, edits and saves a bottle's config. The name cannot change; a runtime must be installed.
    @discardableResult
    public func updateBottle(_ name: String, _ edit: (inout BottleConfig) throws -> Void) throws -> Bottle {
        var b = try bottles.get(name)
        try edit(&b.config)
        b.config.name = name
        if let r = b.config.runtime { _ = try runtimes.get(r) }
        try bottles.save(b)
        return b
    }

    /// Stops the bottle's Wine processes (best effort), then deletes it.
    public func deleteBottle(_ name: String) throws {
        let b = try bottles.get(name)
        if let config = try? GlobalConfig.load(paths) { _ = try? stop(b, config: config) }
        try bottles.delete(name)
    }

    // MARK: settings

    /// Sets (or with nil, clears) the Game Porting Toolkit path. Returns the resolved install.
    @discardableResult
    public func setGPTKPath(_ path: String?) throws -> GPTKInstall? {
        var c = try GlobalConfig.load(paths)
        var install: GPTKInstall?
        if let path {
            let full = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
            guard let g = GPTKInstall.resolve(full) else {
                throw MGError.invalidConfig("\(full) does not look like a Game Porting Toolkit: expected lib/wine/x86_64-windows/d3d12.dll and lib/external/ (e.g. the mounted 'Evaluation environment for Windows games' volume or its redist/lib folder)")
            }
            c.gptkPath = full
            install = g
        } else {
            c.gptkPath = nil
        }
        try c.save(paths)
        return install
    }

    public func setDefaultRuntime(_ name: String?) throws {
        var c = try GlobalConfig.load(paths)
        if let name { _ = try runtimes.get(name) }
        c.defaultRuntime = name
        try c.save(paths)
    }

    public func setDefaultBottle(_ name: String?) throws {
        var c = try GlobalConfig.load(paths)
        if let name { _ = try bottles.get(name) }
        c.defaultBottle = name
        try c.save(paths)
    }

    // MARK: stores

    /// Where the store's installer is cached.
    public func installerFile(for store: Store) -> URL {
        paths.cache.appendingPathComponent("installers/\(store.installerFileName)")
    }

    /// The store client inside the bottle, if it is installed.
    public func clientExecutable(_ store: Store, in bottle: Bottle) -> URL? {
        guard let exe = bottle.unixPath(forWindowsPath: store.clientPath),
              FileManager.default.fileExists(atPath: exe.path) else { return nil }
        return exe
    }

    /// Everything before running a store installer: creates and initialises the bottle if it is missing
    /// (with `backend` as its default), downloads the installer unless it is cached, and plans the
    /// installer run (always wined3d: installers don't need a fast renderer). Run the plan with
    /// `prepare` + `execute`.
    public func planStoreInstall(_ store: Store, bottle name: String, backend: Backend = .auto, redownload: Bool = false,
                                 download: (URL, URL) throws -> Void = { try Downloader.download($0, to: $1, quiet: true) },
                                 log: (String) -> Void = { _ in }) throws -> LaunchPlan {
        if !bottles.exists(name) {
            try createBottle(BottleConfig(name: name, backend: backend), log: log)
            log("created bottle '\(name)'")
        }
        let file = installerFile(for: store)
        if redownload || !FileManager.default.fileExists(atPath: file.path) {
            log("downloading \(store.installerURL.absoluteString)")
            try download(store.installerURL, file)
        }
        return try plan(RunRequest(bottle: name, backend: .wined3d, program: file.path, arguments: store.installerArguments))
    }

    /// Plans starting the store client in a bottle. Throws if the client is not installed there.
    public func planStoreClient(_ store: Store, bottle name: String, backend: Backend? = nil, arguments: [String] = []) throws -> LaunchPlan {
        let b = try bottles.get(name)
        guard let exe = clientExecutable(store, in: b) else {
            throw MGError.io("\(store.displayName) is not installed in bottle '\(name)': run `mgx \(store.rawValue) install --bottle \(name)`")
        }
        return try plan(RunRequest(bottle: name, backend: backend, program: exe.path, arguments: store.clientArguments + arguments))
    }
}

/// One variable a launch sets, changes or removes relative to the environment mgx was started with.
public struct EnvironmentChange: Equatable, Sendable {
    public var key: String
    /// nil: the launch removes the variable.
    public var value: String?
    /// nil: the variable was not set before.
    public var previous: String?

    public init(key: String, value: String?, previous: String?) {
        self.key = key
        self.value = value
        self.previous = previous
    }
}

extension LaunchPlan {
    /// The plan's environment compared with `base`: set or changed variables, then removed ones, each sorted by name.
    public func environmentChanges(from base: [String: String]) -> [EnvironmentChange] {
        let set = environment.keys.sorted().compactMap { k -> EnvironmentChange? in
            base[k] == environment[k] ? nil : EnvironmentChange(key: k, value: environment[k], previous: base[k])
        }
        let unset = base.keys.sorted().filter { environment[$0] == nil }.map {
            EnvironmentChange(key: $0, value: nil, previous: base[$0])
        }
        return set + unset
    }

    /// The command line as one string (for display only: arguments are passed without a shell).
    public var commandLine: String { ([executable.path] + arguments).joined(separator: " ") }
}
