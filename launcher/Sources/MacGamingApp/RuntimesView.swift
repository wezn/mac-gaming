import MGCore
import SwiftUI

struct RuntimesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false
    @State private var removing: String?

    var body: some View {
        VStack(spacing: 0) {
            List {
                if model.runtimes.isEmpty {
                    Text("No runtime installed yet. Download the Wine build (and optionally DXMT and DXVK) from this repository's “Build Wine” workflow, then drop the files below.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
                ForEach(model.runtimes, id: \.name) { rt in
                    RuntimeRow(runtime: rt, isDefault: rt.name == model.defaultRuntimeName,
                               explicitDefault: rt.name == model.config.defaultRuntime,
                               onRemove: { removing = rt.name })
                }
            }
            .listStyle(.inset)

            dropZone.padding()
        }
        .navigationTitle("Runtimes")
        .toolbar {
            ToolbarItem {
                Button {
                    model.installRuntime(from: Panels.chooseRuntimeSources())
                } label: {
                    Label("Install…", systemImage: "square.and.arrow.down")
                }
                .help("Install Wine, DXMT or DXVK archives")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.installRuntime(from: files)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .confirmationDialog("Remove runtime “\(removing ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let r = removing { model.removeRuntime(r) }
                removing = nil
            }
        } message: {
            Text("Bottles that use it will need another runtime.")
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 26))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            Text(verbatim: "Drop wine-crossover-*.tar.xz, dxmt-*.tar.xz, dxvk-macos-*.tar.xz, a zipped CI artifact, or a folder here")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose…") { model.installRuntime(from: Panels.chooseRuntimeSources()) }
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
    }
}

struct RuntimeRow: View {
    @EnvironmentObject private var model: AppModel
    let runtime: Runtime
    /// Bottles without an explicit runtime use this one.
    let isDefault: Bool
    /// Set as the default in config.json (rather than being the only runtime).
    let explicitDefault: Bool
    let onRemove: () -> Void

    var body: some View {
        let manifest = runtime.manifest()
        HStack(alignment: .top) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(runtime.hasWine ? Color.accentColor : .red)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(runtime.name).font(.headline)
                    if isDefault {
                        Text("Default")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                HStack(spacing: 14) {
                    component("Wine", installed: runtime.hasWine, version: manifest.components["wine"]?.version)
                    component("DXMT", installed: runtime.hasDXMT, version: manifest.components["dxmt"]?.version)
                    component("DXVK", installed: runtime.hasDXVK, version: manifest.components["dxvk"]?.version)
                }
                .font(.caption)
                if runtime.hasWine && runtime.hasDXMT {
                    dxmtStatus.font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !explicitDefault {
                Button("Make Default") { model.setDefaultRuntime(runtime.name) }
            }
            Button {
                Panels.reveal(runtime.root)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this runtime")
        }
        .padding(.vertical, 4)
    }

    /// DXMT runs from `wine-dxmt/`, a clone of `wine/` with DXMT's builtins merged in.
    @ViewBuilder
    private var dxmtStatus: some View {
        let built = runtime.dxmtBuiltAgainst
        let wine = runtime.manifest().components["wine"].map { RuntimeComponent.stripArchiveExtension($0.archive) }
        if BackendFiles.isDXMTOverlayCurrent(runtime) {
            Text("DXMT runs from \(runtime.dxmtWineRoot.lastPathComponent)/ (up to date)")
        } else {
            Text("\(runtime.dxmtWineRoot.lastPathComponent)/ is missing or stale; the next DXMT run rebuilds it")
        }
        if let built, let wine, built.lowercased() != wine.lowercased() {
            Label("DXMT was built against \(built), this runtime has \(wine)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func component(_ name: String, installed: Bool, version: String?) -> some View {
        Label {
            Text(installed ? "\(name) \(version ?? "")" : "\(name): not installed")
        } icon: {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(installed ? .green : .secondary)
        }
    }
}
