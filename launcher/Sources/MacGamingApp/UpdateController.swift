import AppKit
import Combine
import MGCore
import SwiftUI

/// Bytes received of one file.
struct DownloadProgress: Equatable {
    var file: String
    var received: Int64
    var total: Int64?

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(received) / Double(total))
    }

    var text: String {
        let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard let total else { return "\(file): \(got)" }
        return "\(file): \(got) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }
}

enum UpdateDownloads {
    /// A download closure for `Updater` (curl, like the CLI) that reports progress on the main actor.
    /// `sizes` (file name → bytes, from the manifest) avoids a HEAD request when the release states sizes.
    static func reporting(sizes: [String: Int64], _ report: @escaping @MainActor (DownloadProgress) -> Void) -> (URL, URL) throws -> Void {
        { url, dest in
            let name = url.lastPathComponent
            let total = sizes[name] ?? Downloader.contentLength(url)
            Task { @MainActor in report(DownloadProgress(file: name, received: 0, total: total)) }
            try Downloader.download(url, to: dest, quiet: true, progress: { bytes in
                Task { @MainActor in report(DownloadProgress(file: name, received: bytes, total: total)) }
            })
        }
    }
}

/// "Check for Updates…": checks the latest release's manifest, downloads MacGaming-<version>.zip with curl
/// (not quarantined, so no new "Open Anyway"), verifies it, swaps it in place of the running bundle and
/// relaunches. Also checks once a day unless turned off.
///
/// Launch arguments for CI: `-MGCheckForUpdatesOnLaunch YES` checks right away (as if chosen from the menu),
/// `-MGAutoInstallUpdate YES` installs and relaunches without asking, `-MGAutomaticUpdateChecks NO` turns the
/// daily check off.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(ReleaseManifest)
        case installing(String)
        /// Swapped in; waiting for the user to relaunch.
        case installed(String)
        case failed(String)
    }

    enum Keys {
        static let automatic = "MGAutomaticUpdateChecks"
        static let lastCheck = "MGLastUpdateCheck"
        static let checkOnLaunch = "MGCheckForUpdatesOnLaunch"
        static let autoInstall = "MGAutoInstallUpdate"
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: DownloadProgress?
    @Published private(set) var lastChecked: Date?
    @Published var automaticChecks: Bool {
        didSet { defaults.set(automaticChecks, forKey: Keys.automatic) }
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var window: NSWindow?
    private(set) weak var model: AppModel?
    private var started = false

    private init() {
        defaults.register(defaults: [Keys.automatic: true])
        automaticChecks = defaults.bool(forKey: Keys.automatic)
        lastChecked = defaults.object(forKey: Keys.lastCheck) as? Date
    }

    var paths: MGPaths { model?.paths ?? .standard() }
    var bundleURL: URL { Bundle.main.bundleURL }
    /// Only a real .app can replace itself (not `swift run`).
    var isBundled: Bool { bundleURL.pathExtension == "app" }

    /// Called once the main window is up.
    func start(model: AppModel) {
        self.model = model
        guard !started else { return }
        started = true
        RuntimeDownloadModel.shared.loadCached(paths: model.paths)
        if defaults.bool(forKey: Keys.checkOnLaunch) {
            check(userInitiated: true)
        } else {
            // Not right at launch: let the window settle first.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                UpdateController.shared.checkIfDue()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in UpdateController.shared.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard automaticChecks else { return }
        switch phase {
        case .checking, .installing, .installed, .available: return
        default: break
        }
        if let last = lastChecked, Date().timeIntervalSince(last) < 24 * 3600 { return }
        check(userInitiated: false)
    }

    /// An automatic check stays silent unless it finds an update.
    func check(userInitiated: Bool) {
        if userInitiated { showWindow() }
        switch phase {
        case .checking, .installing, .installed: return
        default: break
        }
        phase = .checking
        let p = paths
        Task {
            do {
                let m = try await Blocking.run { try Updater.standard(paths: p).fetchManifest() }
                lastChecked = Date()
                defaults.set(lastChecked, forKey: Keys.lastCheck)
                RuntimeDownloadModel.shared.update(from: m, paths: p)
                if Updater(paths: p, source: .default).isNewer(m) {
                    phase = .available(m)
                    showWindow()
                    if defaults.bool(forKey: Keys.autoInstall) { install() }
                } else {
                    phase = .upToDate(m.version)
                }
            } catch {
                phase = .failed(AppModel.describe(error))
            }
        }
    }

    func install() {
        guard case .available(let m) = phase else { return }
        guard isBundled else {
            phase = .failed("This copy of Mac Gaming is not an app bundle (it was started with swift run), so it cannot replace itself.")
            return
        }
        let bundle = bundleURL, id = Bundle.main.bundleIdentifier, p = paths
        let sizes = m.app.flatMap { a in a.size.map { [a.file: $0] } } ?? [:]
        phase = .installing("Downloading Mac Gaming \(m.version)…")
        progress = nil
        Task {
            do {
                try await Blocking.run {
                    var u = try Updater.standard(paths: p)
                    u.download = UpdateDownloads.reporting(sizes: sizes) { UpdateController.shared.progress = $0 }
                    try u.installApp(m, replacing: bundle, bundleIdentifier: id, log: { line in
                        Task { @MainActor in UpdateController.shared.status(line) }
                    })
                }
                progress = nil
                phase = .installed(m.version)
                if defaults.bool(forKey: Keys.autoInstall) { relaunch() }
            } catch {
                progress = nil
                phase = .failed(AppModel.describe(error))
            }
        }
    }

    private func status(_ line: String) {
        guard case .installing = phase else { return }
        if line.hasPrefix("verifying") || line.hasPrefix("unpacking") || line.hasPrefix("replacing") { progress = nil }
        phase = .installing(line.prefix(1).uppercased() + line.dropFirst())
    }

    /// Waits for this process to exit, then opens the (new) bundle.
    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$2\"",
                       "sh", "\(ProcessInfo.processInfo.processIdentifier)", bundleURL.path]
        do {
            try p.run()
        } catch {
            phase = .failed("The update is installed, but Mac Gaming cannot restart itself (\(error.localizedDescription)). Quit and open it again.")
            return
        }
        NSApp.terminate(nil)
    }

    func showWindow() {
        if window == nil {
            let host = NSHostingController(rootView: UpdateWindowView())
            let w = NSWindow(contentViewController: host)
            w.title = "Software Update"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: views

struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdateController.shared.check(userInitiated: true) }
        }
    }
}

struct UpdateWindowView: View {
    @ObservedObject private var updater = UpdateController.shared
    @ObservedObject private var runtime = RuntimeDownloadModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    message
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let p = updater.progress {
                        if let f = p.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                        Text(p.text).font(.caption).foregroundStyle(.secondary)
                    } else if updater.phase == .checking || isInstalling {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
            if let m = updater.model {
                RuntimeUpdateRow(model: m, style: .window)
            }
            Divider()
            HStack {
                Toggle("Check automatically every day", isOn: $updater.automaticChecks)
                    .toggleStyle(.checkbox)
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var isInstalling: Bool {
        if case .installing = updater.phase { return true }
        return false
    }

    private var title: String {
        switch updater.phase {
        case .idle: return "Mac Gaming \(MGVersion.string)"
        case .checking: return "Checking for updates…"
        case .upToDate: return "Mac Gaming is up to date"
        case .available(let m): return "Mac Gaming \(m.version) is available"
        case .installing: return "Installing the update…"
        case .installed(let v): return "Mac Gaming \(v) is installed"
        case .failed: return "Update failed"
        }
    }

    @ViewBuilder
    private var message: some View {
        switch updater.phase {
        case .idle:
            Text(lastCheckedText)
        case .checking:
            Text("Contacting the release server.")
        case .upToDate(let v):
            Text("You have \(MGVersion.string); the latest release is \(v). \(lastCheckedText)")
        case .available(let m):
            Text("You have \(MGVersion.string). The new version is downloaded and checked (SHA-256 and code signature), then replaces this copy and Mac Gaming restarts. Running games keep running.\(m.published.map { "\nPublished \($0)." } ?? "")")
        case .installing(let s):
            Text(s)
        case .installed:
            Text("Restart Mac Gaming to use it. Until then this window keeps running the old version.")
        case .failed(let e):
            Text(e).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    private var lastCheckedText: String {
        guard let d = updater.lastChecked else { return "Not checked yet." }
        return "Last checked \(d.formatted(date: .abbreviated, time: .shortened))."
    }

    @ViewBuilder
    private var buttons: some View {
        switch updater.phase {
        case .available:
            Button("Later") { NSApp.keyWindow?.close() }
            Button("Install and Restart") { updater.install() }
                .keyboardShortcut(.defaultAction)
        case .installed:
            Button("Later") { NSApp.keyWindow?.close() }
            Button("Restart Now") { updater.relaunch() }
                .keyboardShortcut(.defaultAction)
        case .checking, .installing:
            EmptyView()
        default:
            Button("Check Now") { updater.check(userInitiated: true) }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// For the Settings window.
struct UpdateSettingsSection: View {
    @ObservedObject private var updater = UpdateController.shared

    var body: some View {
        Section {
            Toggle("Check for updates automatically every day", isOn: $updater.automaticChecks)
            LabeledContent("Last checked") {
                Text(updater.lastChecked.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
            }
            Button("Check for Updates…") { updater.check(userInitiated: true) }
        } header: {
            Text("Updates")
        } footer: {
            Text("Updates come from the project's GitHub releases and are verified before they are installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
