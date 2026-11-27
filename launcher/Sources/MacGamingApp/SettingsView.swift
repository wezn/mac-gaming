import MGCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    Text(model.config.gptkPath ?? "Not set")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let path = model.config.gptkPath {
                    if let g = GPTKInstall.resolve(path) {
                        Label("D3DMetal from \(g.libRoot.path)", systemImage: g.hasFramework ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(g.hasFramework ? .green : .orange)
                    } else {
                        Label("This folder no longer looks like a Game Porting Toolkit (is the volume mounted?)", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
                HStack {
                    Button("Choose…") {
                        if let url = Panels.chooseGPTK() { model.setGPTKPath(url.path) }
                    }
                    Button("Clear") { model.setGPTKPath(nil) }
                        .disabled(model.config.gptkPath == nil)
                }
            } header: {
                Text("Game Porting Toolkit (D3DMetal)")
            } footer: {
                Text("D3DMetal cannot be bundled. Install Apple's Game Porting Toolkit, then choose the mounted “Evaluation environment for Windows games” volume or its redist/lib folder. DirectX 12 games need it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Defaults") {
                Picker("Default runtime", selection: Binding(get: { model.config.defaultRuntime },
                                                             set: { model.setDefaultRuntime($0) })) {
                    Text(model.runtimes.count == 1 ? "Automatic (\(model.runtimes[0].name))" : "Not set").tag(String?.none)
                    ForEach(model.runtimes, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                }
                Picker("Default bottle", selection: Binding(get: { model.config.defaultBottle },
                                                            set: { model.setDefaultBottle($0) })) {
                    Text("Not set").tag(String?.none)
                    ForEach(model.bottles, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                }
            }

            Section {
                LabeledContent("Data folder") {
                    HStack {
                        Text(model.paths.root.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button {
                            Panels.reveal(model.paths.root)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                LabeledContent("Version", value: MGVersion.string)
            } header: {
                Text("Storage")
            } footer: {
                Text("Shared with the mgx command-line tool. Set MG_HOME to use another folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 480)
    }
}
