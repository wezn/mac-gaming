import AppKit
import MGCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 340)
        } detail: {
            DetailView()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.showingNewBottle = true
                } label: {
                    Label("New Bottle", systemImage: "plus")
                }
                .help("Create a bottle (a Wine prefix)")
                Button {
                    model.beginRun()
                } label: {
                    Label("Run…", systemImage: "play.fill")
                }
                .help("Choose a Windows program and review how it will be launched")
                .disabled(model.bottles.isEmpty)
            }
        }
        .sheet(item: $model.runDraft) { draft in
            RunPlanSheet(draft: draft)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingNewBottle) {
            NewBottleSheet()
                .environmentObject(model)
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
        // The CLI may have changed things while the app was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.reload()
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Bottles") {
                ForEach(model.bottles, id: \.name) { b in
                    BottleRow(bottle: b, isDefault: b.name == model.config.defaultBottle, busy: model.isBusy(bottle: b.name))
                        .tag(SidebarItem.bottle(b.name))
                }
                ForEach(model.brokenBottles.keys.sorted(), id: \.self) { name in
                    Label(name, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .help(model.brokenBottles[name] ?? "")
                }
                if model.bottles.isEmpty && model.brokenBottles.isEmpty {
                    Button("New Bottle…") { model.showingNewBottle = true }
                        .buttonStyle(.link)
                }
            }
            Section("Setup") {
                Label("Runtimes", systemImage: "shippingbox").tag(SidebarItem.runtimes)
                Label("Doctor", systemImage: "stethoscope").tag(SidebarItem.doctor)
                Label("Logs", systemImage: "doc.text.magnifyingglass").tag(SidebarItem.logs)
            }
            if !model.jobs.isEmpty {
                Section("Activity") {
                    ForEach(model.jobs) { job in
                        JobRow(job: job).tag(SidebarItem.job(job.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct BottleRow: View {
    let bottle: Bottle
    let isDefault: Bool
    let busy: Bool

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(bottle.name)
                    Text(bottle.config.backend == .auto ? "automatic backend" : bottle.config.backend.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "wineglass")
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            if isDefault {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .help("Default bottle")
            }
        }
    }
}

struct JobRow: View {
    @ObservedObject var job: Job

    var body: some View {
        HStack {
            JobStatusIcon(job: job)
            Text(job.title)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct JobStatusIcon: View {
    @ObservedObject var job: Job

    var body: some View {
        switch job.state {
        case .running:
            ProgressView().controlSize(.small).frame(width: 16)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.selection {
        case .bottle(let name)?:
            if let b = model.bottle(named: name) {
                BottleDetailView(bottle: b).id(name)
            } else {
                Placeholder(symbol: "wineglass", title: "No bottle named \(name)", message: "It may have been deleted from the command line.")
            }
        case .runtimes?:
            RuntimesView()
        case .doctor?:
            DoctorView()
        case .logs?:
            LogsView()
        case .job(let id)?:
            if let job = model.job(id: id) {
                JobDetailView(job: job).id(id)
            } else {
                Placeholder(symbol: "list.bullet", title: "Nothing selected", message: "")
            }
        case nil:
            Placeholder(symbol: "gamecontroller", title: "Mac Gaming",
                        message: "Install a runtime, create a bottle, then Run… a Windows program or install Steam or Battle.net.")
        }
    }
}

/// `ContentUnavailableView` needs macOS 14.
struct Placeholder: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            if !message.isEmpty {
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
