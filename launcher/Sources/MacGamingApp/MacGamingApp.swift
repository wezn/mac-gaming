import AppKit
import MGCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct MacGamingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Mac Gaming", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bottle…") { model.showingNewBottle = true }
                    .keyboardShortcut("n")
                Button("Run Program…") { model.beginRun() }
                    .keyboardShortcut("r")
                    .disabled(model.bottles.isEmpty)
            }
            CommandGroup(after: .sidebar) {
                Button("Reload") { model.reload() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        AcknowledgementsWindow()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary is started directly (CI, `swift run`) rather than through Launch Services.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Open panels. NSOpenPanel instead of `.fileImporter`: SwiftUI only honours one file importer per
/// view hierarchy on macOS 13, and the GPTK can be an `.app` package or a plain folder.
enum Panels {
    static var programTypes: [UTType] {
        ["exe", "msi", "bat", "cmd"].compactMap { UTType(filenameExtension: $0) }
    }

    @MainActor
    static func chooseProgram() -> URL? {
        let p = NSOpenPanel()
        p.message = "Choose a Windows program (.exe, .msi, .bat) to run"
        p.prompt = "Choose"
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.allowedContentTypes = programTypes
        return p.runModal() == .OK ? p.url : nil
    }

    @MainActor
    static func chooseRuntimeSources() -> [URL] {
        let p = NSOpenPanel()
        p.message = "Choose wine-crossover-*.tar.xz, dxmt-*.tar.xz, dxvk-macos-*.tar.xz, zipped CI artifacts, or a folder containing them"
        p.prompt = "Install"
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        return p.runModal() == .OK ? p.urls : []
    }

    @MainActor
    static func chooseGPTK() -> URL? {
        let p = NSOpenPanel()
        p.message = "Choose the Game Porting Toolkit: the mounted “Evaluation environment for Windows games” volume, its redist/lib folder, or the app"
        p.prompt = "Use"
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        p.treatsFilePackagesAsDirectories = false
        return p.runModal() == .OK ? p.url : nil
    }

    @MainActor
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
