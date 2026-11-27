import AppKit
import Foundation
import MGCore
import SwiftUI

enum SidebarItem: Hashable {
    case bottle(String)
    case runtimes
    case doctor
    case logs
    case job(UUID)
}

struct AlertMessage: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// The program picked with "Run…", before its plan is confirmed.
struct RunDraft: Identifiable {
    let id = UUID()
    var bottle: String
    var program: URL
}

/// One piece of background work (wineboot, an install, a running program), listed under Activity.
///
/// Not actor-isolated so background work can report through `JobReporter`; every mutation happens on
/// the main queue.
final class Job: ObservableObject, Identifiable, @unchecked Sendable {
    enum State: Equatable {
        case running
        case succeeded(String)
        case failed(String)
    }

    enum Kind {
        /// Setup work: creating a bottle, installing a runtime.
        case task
        /// A Windows program (game, installer, store client, Wine tool).
        case program
    }

    let id = UUID()
    let title: String
    let bottle: String?
    let kind: Kind
    let started = Date()
    @Published var state: State = .running
    /// Progress lines from MGCore (`log:` callbacks).
    @Published var messages: [String] = []
    /// The run's Wine log, once known.
    @Published var logFile: URL?

    init(title: String, bottle: String?, kind: Kind) {
        self.title = title
        self.bottle = bottle
        self.kind = kind
    }

    var isRunning: Bool { state == .running }
}

/// Handed to background work so it can report progress from any thread.
struct JobReporter: Sendable {
    let job: Job

    func log(_ line: String) {
        DispatchQueue.main.async { self.job.messages.append(line) }
    }

    func logFile(_ url: URL) {
        DispatchQueue.main.async { self.job.logFile = url }
    }
}

/// App state. Views read it and call its methods; all MGCore work that can block (wineboot, installs,
/// downloads, a running game, the doctor's Rosetta probe) runs off the main actor via `Blocking.run`.
/// Quick reads (listing bottles, loading small JSON files) stay on the main actor.
@MainActor
final class AppModel: ObservableObject {
    let launcher: Launcher
    var paths: MGPaths { launcher.paths }

    @Published private(set) var bottles: [Bottle] = []
    /// Bottles whose bottle.json does not load (name → error).
    @Published private(set) var brokenBottles: [String: String] = [:]
    @Published private(set) var runtimes: [Runtime] = []
    @Published private(set) var config = GlobalConfig()
    /// The runtime bottles without an explicit runtime use (nil if none or ambiguous).
    @Published private(set) var defaultRuntimeName: String?
    @Published private(set) var jobs: [Job] = []

    @Published var selection: SidebarItem?
    @Published var alert: AlertMessage?
    @Published var runDraft: RunDraft?
    @Published var showingNewBottle = false

    @Published private(set) var doctorChecks: [DoctorCheck] = []
    @Published private(set) var doctorRunning = false

    init(paths: MGPaths = .standard()) {
        launcher = Launcher(paths: paths)
        reload()
        applyLaunchArguments()
    }

    // MARK: state

    func reload() {
        let listed = launcher.bottles.list()
        bottles = listed.bottles
        brokenBottles = listed.errors
        runtimes = launcher.runtimes.list()
        do {
            config = try GlobalConfig.load(paths)
        } catch {
            config = GlobalConfig()
            report("Cannot read settings", error)
        }
        defaultRuntimeName = try? launcher.runtimes.resolve(nil, config: config).name
        if case .bottle(let name)? = selection, bottle(named: name) == nil { selection = nil }
    }

    func bottle(named name: String) -> Bottle? { bottles.first { $0.name == name } }

    func job(id: UUID) -> Job? { jobs.first { $0.id == id } }

    func isBusy(bottle name: String) -> Bool { jobs.contains { $0.bottle == name && $0.isRunning } }

    var selectedBottleName: String? {
        if case .bottle(let name)? = selection { return name }
        return nil
    }

    /// `-MGInitialSection runtimes|doctor|logs|bottle:<name>` and `-MGPreviewRun <path>` pick what the
    /// window shows first (used by CI to take screenshots; harmless otherwise).
    private func applyLaunchArguments() {
        let defaults = UserDefaults.standard
        if let s = defaults.string(forKey: "MGInitialSection") {
            switch s {
            case "runtimes": selection = .runtimes
            case "doctor": selection = .doctor
            case "logs": selection = .logs
            case let b where b.hasPrefix("bottle:"): selection = .bottle(String(b.dropFirst("bottle:".count)))
            default: break
            }
        } else if let first = config.defaultBottle.flatMap(bottle(named:)) ?? bottles.first {
            selection = .bottle(first.name)
        } else {
            selection = .runtimes
        }
        if let program = defaults.string(forKey: "MGPreviewRun"), let b = runTargetBottle() {
            runDraft = RunDraft(bottle: b, program: URL(fileURLWithPath: program))
        }
    }

    // MARK: errors

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as MGError: return e.description
        case let e as PEError: return e.description
        default: return error.localizedDescription
        }
    }

    func report(_ title: String, _ error: Error) {
        alert = AlertMessage(title: title, message: Self.describe(error))
    }

    // MARK: jobs

    /// Runs `work` on its own thread and tracks it under Activity. The returned string is the
    /// success summary; a thrown error marks the job failed. State is reloaded afterwards.
    @discardableResult
    func start(_ title: String, bottle: String? = nil, kind: Job.Kind = .task, select: Bool = false,
               onSuccess: (@MainActor () -> Void)? = nil,
               _ work: @escaping @Sendable (JobReporter) throws -> String) -> Job {
        let job = Job(title: title, bottle: bottle, kind: kind)
        jobs.insert(job, at: 0)
        if select { selection = .job(job.id) }
        let reporter = JobReporter(job: job)
        Task {
            do {
                let summary = try await Blocking.run { try work(reporter) }
                job.state = .succeeded(summary)
                reload()
                onSuccess?()
            } catch {
                job.state = .failed(Self.describe(error))
                reload()
            }
        }
        return job
    }

    func clearFinishedJobs() {
        jobs.removeAll { !$0.isRunning }
        if case .job(let id)? = selection, job(id: id) == nil { selection = nil }
    }

    // MARK: bottles

    func createBottle(_ config: BottleConfig, makeDefault: Bool) {
        let l = launcher
        let name = config.name
        start("Create bottle \(name)", bottle: name, select: true, onSuccess: { [weak self] in
            self?.selection = .bottle(name)
        }) { r in
            try l.createBottle(config, makeDefault: makeDefault, log: r.log)
            return "Bottle \(name) is ready"
        }
    }

    func saveBottle(_ name: String, _ draft: BottleConfig) {
        do {
            try launcher.updateBottle(name) { $0 = draft }
        } catch {
            report("Cannot save \(name)", error)
        }
        reload()
    }

    func deleteBottle(_ name: String) {
        let l = launcher
        if selection == .bottle(name) { selection = nil }
        start("Delete bottle \(name)", bottle: name) { _ in
            try l.deleteBottle(name)
            return "Deleted"
        }
    }

    func setDefaultBottle(_ name: String?) {
        do { try launcher.setDefaultBottle(name) } catch { report("Cannot set the default bottle", error) }
        reload()
    }

    /// `wineserver -k`: ends every Wine process in the bottle (the game's job then finishes).
    func stop(bottle name: String) {
        guard let b = bottle(named: name) else { return }
        let l = launcher, c = config
        Task {
            do {
                _ = try await Blocking.run { try l.stop(b, config: c) }
            } catch {
                report("Cannot stop \(name)", error)
            }
        }
    }

    // MARK: running programs

    /// The bottle "Run…" uses: the selected one, else the default, else the only/first one.
    func runTargetBottle() -> String? {
        selectedBottleName ?? config.defaultBottle.flatMap { bottle(named: $0)?.name } ?? bottles.first?.name
    }

    /// Picks a program, then shows its plan (`RunPlanSheet`) before anything is launched.
    func beginRun(in bottle: String? = nil) {
        guard let target = bottle ?? runTargetBottle() else {
            alert = AlertMessage(title: "No bottle", message: "Create a bottle first (File → New Bottle…).")
            return
        }
        guard let url = Panels.chooseProgram() else { return }
        runDraft = RunDraft(bottle: target, program: url)
    }

    /// Plans off the main actor: scanning a large game binary and its sibling DLLs touches the disk.
    func plan(_ request: RunRequest) async -> Result<LaunchPlan, Error> {
        let l = launcher
        do {
            return .success(try await Blocking.run { try l.plan(request) })
        } catch {
            return .failure(error)
        }
    }

    func launch(_ plan: LaunchPlan, title: String? = nil) {
        let l = launcher
        start(title ?? "\(plan.programName) in \(plan.bottle.name)", bottle: plan.bottle.name, kind: .program, select: true) { r in
            r.logFile(plan.logFile)
            return try AppModel.prepareAndExecute(l, plan, r)
        }
    }

    /// Runs a program Wine provides (winecfg, regedit, …) without a plan preview.
    func runTool(_ program: String, in bottle: String) {
        let l = launcher
        start("\(program) in \(bottle)", bottle: bottle, kind: .program, select: true) { r in
            let plan = try l.plan(RunRequest(bottle: bottle, program: program))
            r.logFile(plan.logFile)
            return try AppModel.prepareAndExecute(l, plan, r)
        }
    }

    nonisolated static func prepareAndExecute(_ l: Launcher, _ plan: LaunchPlan, _ r: JobReporter) throws -> String {
        for w in plan.choice.warnings { r.log("warning: \(w)") }
        r.log("\(plan.programName): \(plan.choice.backend.rawValue) (\(plan.choice.reason))")
        try l.prepare(plan, log: r.log)
        r.log("started \(plan.commandLine)")
        let code = try l.execute(plan)
        guard code == 0 else { throw MGError.processFailed(plan.programName, code) }
        return "\(plan.programName) exited normally"
    }

    // MARK: stores

    func installStore(_ store: Store, bottle: String) {
        let l = launcher
        start("Install \(store.displayName) in \(bottle)", bottle: bottle, kind: .program, select: true) { r in
            let plan = try l.planStoreInstall(store, bottle: bottle, log: r.log)
            r.logFile(plan.logFile)
            _ = try AppModel.prepareAndExecute(l, plan, r)
            return "\(store.displayName) installed"
        }
    }

    func runStore(_ store: Store, bottle: String) {
        let l = launcher
        start("\(store.displayName) in \(bottle)", bottle: bottle, kind: .program, select: true) { r in
            let plan = try l.planStoreClient(store, bottle: bottle)
            r.logFile(plan.logFile)
            return try AppModel.prepareAndExecute(l, plan, r)
        }
    }

    // MARK: runtimes

    func installRuntime(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        let l = launcher
        let label = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        start("Install runtime from \(label)", select: true) { r in
            let report = try l.runtimes.install(sources: urls, log: r.log)
            return "Runtime \(report.runtime): installed \(report.installed.keys.sorted().joined(separator: ", "))"
        }
    }

    func removeRuntime(_ name: String) {
        let l = launcher
        start("Remove runtime \(name)") { _ in
            try l.runtimes.remove(name)
            return "Removed"
        }
    }

    func setDefaultRuntime(_ name: String?) {
        do { try launcher.setDefaultRuntime(name) } catch { report("Cannot set the default runtime", error) }
        reload()
    }

    // MARK: settings

    func setGPTKPath(_ path: String?) {
        do { try launcher.setGPTKPath(path) } catch { report("Not a Game Porting Toolkit", error) }
        reload()
    }

    // MARK: doctor

    func runDoctor() async {
        guard !doctorRunning else { return }
        doctorRunning = true
        defer { doctorRunning = false }
        let p = paths
        doctorChecks = (try? await Blocking.run { Doctor(paths: p).run() }) ?? []
    }
}

extension Backend {
    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .d3dmetal: return "D3DMetal (Game Porting Toolkit)"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK (MoltenVK)"
        case .wined3d: return "wined3d (OpenGL)"
        }
    }
}
