import MGCore
import SwiftUI

struct DoctorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let checks = model.doctorChecks
        let errors = checks.filter { $0.status == .error }.count
        let warnings = checks.filter { $0.status == .warning }.count
        List {
            Section {
                ForEach(Array(checks.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        icon(c.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title)
                            if !c.detail.isEmpty {
                                Text(c.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                if model.collectingReport {
                    ProgressView("Collecting diagnostics…").controlSize(.small)
                } else if model.doctorRunning && checks.isEmpty {
                    ProgressView().controlSize(.small)
                } else if !checks.isEmpty {
                    Text(errors == 0 && warnings == 0 ? "Everything looks good"
                         : "\(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")")
                }
            }
        }
        .listStyle(.inset)
        .navigationTitle("Doctor")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.copyDiagnostics() }
                } label: {
                    Label("Copy Diagnostics", systemImage: "doc.on.clipboard")
                }
                .help("Copy a redacted report (doctor, settings, runtimes, bottles) for a bug report")
                .disabled(model.collectingReport)
                Button {
                    Task { await model.saveReport() }
                } label: {
                    Label("Save Report…", systemImage: "archivebox")
                }
                .help("Save the full report with recent logs as a .tar.gz (same as `mgx report`)")
                .disabled(model.collectingReport)
                Button {
                    Task { await model.runDoctor() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .disabled(model.doctorRunning)
            }
        }
        .task { await model.runDoctor() }
    }

    @ViewBuilder
    private func icon(_ s: DoctorCheck.Status) -> some View {
        switch s {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
