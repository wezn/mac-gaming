import MGCore
import SwiftUI

/// Shows the LaunchPlan for a picked program (detected DirectX level, backend and why, environment
/// changes) and launches it on confirmation. Changing the bottle, backend or arguments re-plans.
struct RunPlanSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let draft: RunDraft

    @State private var bottle: String
    @State private var backend: Backend = .auto
    @State private var arguments = ""
    @State private var plan: LaunchPlan?
    @State private var error: String?
    @State private var planning = false

    init(draft: RunDraft) {
        self.draft = draft
        _bottle = State(initialValue: draft.bottle)
    }

    private struct Key: Hashable {
        var bottle: String
        var backend: Backend
        var arguments: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    options
                    if let error {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let plan {
                        PlanDetails(plan: plan, base: model.launcher.baseEnvironment)
                    } else if planning {
                        ProgressView("Planning…").frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            Divider()
            HStack {
                if let plan {
                    Text("Log: \(plan.logFile.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Launch") {
                    if let plan { model.launch(plan) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan == nil || planning)
            }
            .padding()
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 520, idealHeight: 640)
        .task(id: Key(bottle: bottle, backend: backend, arguments: arguments)) {
            await replan()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "app.badge")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Run \(draft.program.lastPathComponent)").font(.title2.weight(.semibold))
                Text(draft.program.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }

    private var options: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Bottle").gridColumnAlignment(.trailing)
                Picker("", selection: $bottle) {
                    ForEach(model.bottles, id: \.name) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            GridRow {
                Text("Backend")
                Picker("", selection: $backend) {
                    ForEach(Backend.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            GridRow {
                Text("Arguments")
                TextField("", text: $arguments, prompt: Text("e.g. -windowed -w 1920"))
                    .labelsHidden()
                    .font(.body.monospaced())
            }
        }
    }

    private func replan() async {
        // Debounce typing in the arguments field.
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !Task.isCancelled else { return }
        let args: [String]
        do {
            args = try ArgumentSplitter.split(arguments)
        } catch {
            self.error = AppModel.describe(error)
            plan = nil
            return
        }
        planning = true
        let result = await model.plan(RunRequest(bottle: bottle, backend: backend == .auto ? nil : backend,
                                                 program: draft.program.path, arguments: args))
        guard !Task.isCancelled else { return }
        planning = false
        switch result {
        case .success(let p):
            plan = p
            error = nil
        case .failure(let e):
            plan = nil
            error = AppModel.describe(e)
        }
    }
}

struct PlanDetails: View {
    let plan: LaunchPlan
    let base: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Detected", detectedText)
                    if let note = plan.override?.note { row("Override", note) }
                    row("Backend", "\(plan.choice.backend.label) — \(plan.choice.reason)", bold: true)
                    row("Runtime", plan.runtime.name)
                    row("Bottle", "\(plan.bottle.name)\(plan.bottle.isInitialized ? "" : " (wineboot runs first)")")
                    row("Options", "msync \(onOff(plan.environment["WINEMSYNC"] == "1")) · Retina \(onOff(plan.retina)) · Metal HUD \(onOff(plan.environment["MTL_HUD_ENABLED"] == "1"))")
                    if let wd = plan.workingDirectory { row("Folder", wd.path) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Launch plan")
            }

            if !plan.choice.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.choice.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            GroupBox("Command") {
                Text(plan.commandLine)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !plan.setup.copies.isEmpty {
                GroupBox {
                    DisclosureGroup("\(plan.setup.copies.count) \(plan.setup.backend.rawValue) DLL(s) are copied into the bottle (skipped when already in place)") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(plan.setup.copies, id: \.destination) { c in
                                Text("\(c.source.lastPathComponent) → \(c.destination.deletingLastPathComponent().lastPathComponent)/")
                                    .font(.caption.monospaced())
                                    .help("\(c.source.path) → \(c.destination.path)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            let changes = plan.environmentChanges(from: base)
            GroupBox {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(changes, id: \.key) { c in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(c.key)
                                .font(.caption.monospaced().weight(.semibold))
                                .frame(width: 230, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                if let v = c.value {
                                    Text(v).font(.caption.monospaced())
                                } else {
                                    Text("removed").font(.caption.italic()).foregroundStyle(.red)
                                }
                                if let old = c.previous {
                                    Text("was \(old)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Environment (\(changes.count) change\(changes.count == 1 ? "" : "s") from the app's environment)")
            }
        }
    }

    private var detectedText: String {
        let d = plan.detection
        if d.source == .none && d.evidence == nil { return "not scanned" }
        let bits = d.is64Bit.map { $0 ? "64-bit" : "32-bit" }
        return [d.level.description, d.evidence, bits].compactMap { $0 }.joined(separator: " · ")
    }

    private func onOff(_ b: Bool) -> String { b ? "on" : "off" }

    @ViewBuilder
    private func row(_ title: String, _ value: String, bold: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .fontWeight(bold ? .semibold : .regular)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
