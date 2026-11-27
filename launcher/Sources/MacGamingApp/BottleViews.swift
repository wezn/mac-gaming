import MGCore
import SwiftUI

struct BottleDetailView: View {
    @EnvironmentObject private var model: AppModel
    let bottle: Bottle
    @State private var draft: BottleConfig
    @State private var confirmDelete = false

    init(bottle: Bottle) {
        self.bottle = bottle
        _draft = State(initialValue: bottle.config)
    }

    private var isDefault: Bool { model.config.defaultBottle == bottle.name }
    private var dirty: Bool { draft != bottle.config }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Button {
                        model.beginRun(in: bottle.name)
                    } label: {
                        Label("Run…", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Choose a Windows program and review how it will be launched")
                    Menu {
                        ForEach(["winecfg", "regedit", "explorer", "taskmgr", "notepad"], id: \.self) { tool in
                            Button(tool) { model.runTool(tool, in: bottle.name) }
                        }
                    } label: {
                        Label("Wine Tools", systemImage: "wrench.and.screwdriver")
                    }
                    .fixedSize()
                    Button {
                        model.stop(bottle: bottle.name)
                    } label: {
                        Label("Stop All", systemImage: "stop.fill")
                    }
                    .help("End every Wine process in this bottle (wineserver -k)")
                    Spacer()
                    if isDefault {
                        Label("Default bottle", systemImage: "star.fill").foregroundStyle(.secondary)
                    } else {
                        Button("Make Default") { model.setDefaultBottle(bottle.name) }
                    }
                }
                LabeledContent("Location") {
                    HStack {
                        Text(bottle.prefix.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button {
                            Panels.reveal(bottle.prefix)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                    }
                }
                LabeledContent("Prefix") {
                    Text(bottle.isInitialized ? "Initialised" : "Not initialised yet (set up on first run)")
                }
            }

            Section("Settings") {
                Picker("Runtime", selection: $draft.runtime) {
                    Text("Default (\(model.defaultRuntimeName ?? "none"))").tag(String?.none)
                    ForEach(model.runtimes, id: \.name) { rt in
                        Text(rt.name).tag(Optional(rt.name))
                    }
                }
                Picker("Graphics backend", selection: $draft.backend) {
                    ForEach(Backend.allCases, id: \.self) { b in
                        Text(b.label).tag(b)
                    }
                }
                Toggle("msync", isOn: $draft.msync)
                Toggle("Retina mode (full resolution on HiDPI displays)", isOn: $draft.retina)
                Toggle("Metal performance HUD", isOn: $draft.metalHUD)
            }

            Section {
                EnvironmentEditor(env: $draft.env)
            } header: {
                Text("Environment")
            } footer: {
                Text("Set for every program in this bottle. WINEDLLOVERRIDES is merged with mgx's own overrides.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                StoreRow(store: .steam, bottle: bottle)
                StoreRow(store: .battlenet, bottle: bottle)
            } header: {
                Text("Stores")
            } footer: {
                if bottle.config.backend == .auto {
                    Text("Games started from Steam or Battle.net inherit this bottle's backend, so auto-detection cannot help them. Pick one above: D3DMetal for Overwatch 2, DXMT for Counter-Strike 2.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Delete Bottle…", role: .destructive) { confirmDelete = true }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(bottle.name)
        .toolbar {
            ToolbarItemGroup(placement: .confirmationAction) {
                if dirty {
                    Button("Revert") { draft = bottle.config }
                    Button("Save") { model.saveBottle(bottle.name, draft) }
                        .keyboardShortcut("s")
                }
            }
        }
        .confirmationDialog("Delete bottle “\(bottle.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteBottle(bottle.name) }
        } message: {
            Text("This removes \(bottle.prefix.path) and every program installed in it.")
        }
    }
}

struct StoreRow: View {
    @EnvironmentObject private var model: AppModel
    let store: Store
    let bottle: Bottle

    var body: some View {
        let installed = model.launcher.clientExecutable(store, in: bottle) != nil
        HStack {
            Label(store.displayName, systemImage: store == .steam ? "cloud" : "bolt.horizontal")
            Spacer()
            Text(installed ? "Installed" : "Not installed")
                .foregroundStyle(.secondary)
            Button(installed ? "Reinstall" : "Install") {
                model.installStore(store, bottle: bottle.name)
            }
            .help(store == .steam ? "Download SteamSetup.exe and install silently" : "Download the Battle.net installer and run it (it is interactive)")
            Button("Open") {
                model.runStore(store, bottle: bottle.name)
            }
            .disabled(!installed)
        }
    }
}

/// Keys are fixed once added (remove and re-add to rename); values are editable in place.
struct EnvironmentEditor: View {
    @Binding var env: [String: String]
    @State private var newKey = ""
    @State private var newValue = ""

    private var keyIsValid: Bool {
        let k = newKey.trimmingCharacters(in: .whitespaces)
        return !k.isEmpty && !k.contains("=") && !k.contains(where: \.isWhitespace) && env[k] == nil
    }

    var body: some View {
        ForEach(env.keys.sorted(), id: \.self) { key in
            HStack {
                Text(key)
                    .font(.body.monospaced())
                    .frame(minWidth: 180, alignment: .leading)
                TextField("", text: Binding(get: { env[key] ?? "" }, set: { env[key] = $0 }), prompt: Text("value"))
                    .labelsHidden()
                    .font(.body.monospaced())
                Button {
                    env[key] = nil
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove \(key)")
            }
        }
        HStack {
            TextField("", text: $newKey, prompt: Text("NAME"))
                .labelsHidden()
                .font(.body.monospaced())
                .frame(minWidth: 180)
            TextField("", text: $newValue, prompt: Text("value"))
                .labelsHidden()
                .font(.body.monospaced())
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(!keyIsValid)
        }
    }

    private func add() {
        guard keyIsValid else { return }
        env[newKey.trimmingCharacters(in: .whitespaces)] = newValue
        newKey = ""
        newValue = ""
    }
}

struct NewBottleSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var runtime: String?
    @State private var backend: Backend = .auto
    @State private var msync = true
    @State private var retina = false
    @State private var hud = false
    @State private var makeDefault = false

    private var problem: String? {
        if model.runtimes.isEmpty { return "Install a runtime first (Runtimes in the sidebar)." }
        if runtime == nil && model.defaultRuntimeName == nil {
            return "Several runtimes are installed: pick one, or set a default in Settings."
        }
        if name.isEmpty { return nil }
        if !Names.isValid(name) { return "Use letters, digits, '.', '_' or '-' (max 64, starting with a letter or digit)." }
        if model.bottle(named: name) != nil || model.brokenBottles[name] != nil { return "A bottle named \(name) already exists." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Bottle").font(.title2.weight(.semibold)).padding([.top, .horizontal])
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. steam"))
                Picker("Runtime", selection: $runtime) {
                    Text("Default (\(model.defaultRuntimeName ?? "none"))").tag(String?.none)
                    ForEach(model.runtimes, id: \.name) { rt in
                        Text(rt.name).tag(Optional(rt.name))
                    }
                }
                Picker("Graphics backend", selection: $backend) {
                    ForEach(Backend.allCases, id: \.self) { b in Text(b.label).tag(b) }
                }
                Toggle("msync", isOn: $msync)
                Toggle("Retina mode", isOn: $retina)
                Toggle("Metal performance HUD", isOn: $hud)
                Toggle("Make this the default bottle", isOn: $makeDefault)
            }
            .formStyle(.grouped)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }
            HStack {
                Text("Creating a bottle runs wineboot, which takes a minute the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    model.createBottle(BottleConfig(name: name, runtime: runtime, backend: backend,
                                                    msync: msync, retina: retina, metalHUD: hud),
                                       makeDefault: makeDefault)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || problem != nil)
            }
            .padding()
        }
        .frame(width: 480)
        .onAppear { makeDefault = model.bottles.isEmpty }
    }
}
