import Combine
import MGCore
import SwiftUI

/// Downloading the runtime (Wine, DXMT, DXVK) from the latest release, like `mgx runtime update`: the
/// first-run "Download Runtime" action and the "Update Runtime" banner.
@MainActor
final class RuntimeDownloadModel: ObservableObject {
    static let shared = RuntimeDownloadModel()

    enum Phase: Equatable {
        /// No manifest seen yet.
        case unknown
        case checking
        case available(ReleaseManifest, RuntimeUpdatePlan)
        case upToDate(String)
        case downloading(String)
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .unknown
    @Published private(set) var progress: DownloadProgress?
    private var watch: AnyCancellable?

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading: return true
        default: return false
        }
    }

    /// From the last manifest fetched (no network).
    func loadCached(paths: MGPaths) {
        guard !isBusy, let entry = UpdateCache(paths: paths).load() else { return }
        update(from: entry.manifest, paths: paths)
    }

    /// Recomputes what the release would install.
    func update(from m: ReleaseManifest, paths: MGPaths) {
        guard !isBusy else { return }
        do {
            let plan = try Updater(paths: paths, source: .default).planRuntimeUpdate(m)
            phase = plan.isUpToDate ? .upToDate(m.version) : .available(m, plan)
        } catch {
            phase = .failed(AppModel.describe(error))
        }
    }

    /// Fetches the latest manifest.
    func refresh(paths: MGPaths) {
        guard !isBusy else { return }
        phase = .checking
        Task {
            do {
                let m = try await Blocking.run { try Updater.standard(paths: paths).fetchManifest() }
                phase = .unknown
                update(from: m, paths: paths)
            } catch {
                phase = .failed(AppModel.describe(error))
            }
        }
    }

    func refreshIfNeeded(paths: MGPaths) {
        switch phase {
        case .unknown, .failed: refresh(paths: paths)
        default: break
        }
    }

    /// Downloads, verifies and installs, tracked as a job under Activity (which reloads the runtime list).
    func install(model: AppModel) {
        guard case .available(let m, _) = phase else { return }
        let p = model.paths
        var sizes: [String: Int64] = [:]
        for a in m.runtime { if let s = a.size { sizes[a.file] = s } }
        phase = .downloading("Starting…")
        progress = nil
        let job = model.start("Download runtime (release \(m.version))") { r in
            var u = try Updater.standard(paths: p)
            u.download = UpdateDownloads.reporting(sizes: sizes) { RuntimeDownloadModel.shared.progress = $0 }
            let plan = try u.planRuntimeUpdate(m)
            let report = try u.updateRuntime(m, plan: plan, log: { line in
                r.log(line)
                Task { @MainActor in RuntimeDownloadModel.shared.status(line) }
            })
            guard let report else { return "Runtime \(plan.runtime) is already up to date" }
            return "Runtime \(report.runtime): installed \(report.installed.keys.sorted().joined(separator: ", "))"
        }
        watch = job.$state.sink { state in
            Task { @MainActor in RuntimeDownloadModel.shared.jobChanged(state) }
        }
    }

    private func status(_ line: String) {
        guard case .downloading = phase else { return }
        if !line.hasPrefix("downloading") { progress = nil }
        phase = .downloading(line.prefix(1).uppercased() + line.dropFirst())
    }

    private func jobChanged(_ state: Job.State) {
        switch state {
        case .running: return
        case .succeeded(let s): phase = .done(s)
        case .failed(let e): phase = .failed(e)
        }
        progress = nil
        watch = nil
    }
}

/// First run: shown in Runtimes while nothing is installed.
struct RuntimeDownloadCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Download the runtime", systemImage: "arrow.down.circle.fill")
                .font(.title3.weight(.semibold))
            Text("Mac Gaming runs Windows games with Wine and the DXMT and DXVK graphics layers. Download them from the latest release; every file is checked (SHA-256) before it is installed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RuntimeUpdateRow(model: model, style: .onboarding)
            Text("Or install archives you already have: drop them below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
        .onAppear { RuntimeDownloadModel.shared.refreshIfNeeded(paths: model.paths) }
    }
}

/// The release's runtime status with its action.
struct RuntimeUpdateRow: View {
    enum Style {
        /// The first-run card: every state, with a prominent button.
        case onboarding
        /// Above the runtime list: only when there is something to do or to report.
        case banner
        /// The Software Update window.
        case window
    }

    @ObservedObject var model: AppModel
    let style: Style
    @ObservedObject private var dl = RuntimeDownloadModel.shared

    var body: some View {
        switch dl.phase {
        case .unknown:
            if style == .onboarding {
                Button("Check the Latest Release") { dl.refresh(paths: model.paths) }
            }
        case .checking:
            if style != .banner {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking the latest release…").foregroundStyle(.secondary)
                }
            }
        case .available(let m, let plan):
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.isNewRuntime ? "Runtime \(plan.runtime)" : "Runtime update for \(plan.runtime)")
                        .font(.headline)
                    Text("\(RuntimeUpdatePlan.describe(plan.install))\(sizeText(plan)) · release \(m.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.runtimes.isEmpty ? "Download Runtime" : "Update Runtime") { dl.install(model: model) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(style == .onboarding ? .large : .regular)
            }
        case .downloading(let s):
            VStack(alignment: .leading, spacing: 4) {
                if let p = dl.progress, let f = p.fraction {
                    ProgressView(value: f)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(dl.progress?.text ?? s)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .upToDate(let v):
            if style == .window {
                Label("The runtime is up to date (release \(v)).", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .done(let s):
            Label(s, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let e):
            VStack(alignment: .leading, spacing: 6) {
                Label(e, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { dl.refresh(paths: model.paths) }
            }
        }
    }

    private func sizeText(_ plan: RuntimeUpdatePlan) -> String {
        let sizes = plan.install.compactMap(\.size)
        guard sizes.count == plan.install.count, !sizes.isEmpty else { return "" }
        return " · " + ByteCountFormatter.string(fromByteCount: sizes.reduce(0, +), countStyle: .file)
    }
}
