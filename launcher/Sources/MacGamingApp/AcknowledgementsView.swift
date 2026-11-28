import AppKit
import MGCore
import SwiftUI

/// The Acknowledgements window (MacGaming → Acknowledgements…): THIRD_PARTY_NOTICES.md from the app
/// bundle's Resources, which `Scripts/make_app.sh` copies in.
struct AcknowledgementsWindow: Scene {
    static let id = "acknowledgements"

    var body: some Scene {
        Window("Acknowledgements", id: Self.id) {
            AcknowledgementsView()
                .frame(minWidth: 560, minHeight: 400)
        }
        .defaultSize(width: 760, height: 640)
        .commands { AcknowledgementsCommands() }
    }
}

private struct AcknowledgementsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Acknowledgements…") { openWindow(id: AcknowledgementsWindow.id) }
        }
    }
}

struct AcknowledgementsView: View {
    @State private var text: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Mac Gaming includes open-source software. Their licenses and notices:")
                    .foregroundStyle(.secondary)
                Spacer()
                Link("View Online", destination: ThirdPartyNotices.onlineURL())
            }
            .padding(12)
            Divider()
            if let text {
                NoticesTextView(text: text)
            } else if loaded {
                VStack(spacing: 8) {
                    Text("\(ThirdPartyNotices.fileName) is missing from this copy of the app.")
                    Link(ThirdPartyNotices.onlineURL().absoluteString, destination: ThirdPartyNotices.onlineURL())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
                ?? ThirdPartyNotices.locate(executable: ThirdPartyNotices.currentExecutable)
            text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            loaded = true
        }
    }
}

/// A read-only, selectable NSTextView: SwiftUI's Text is slow with a 200 KB string.
private struct NoticesTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.textContainerInset = NSSize(width: 10, height: 10)
            view.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? NSTextView, view.string != text { view.string = text }
    }
}
