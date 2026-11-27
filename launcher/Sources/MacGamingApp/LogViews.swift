import AppKit
import MGCore
import SwiftUI

/// Follows a log file with `LogTail`. File reads happen on a private serial queue.
@MainActor
final class LogTailModel: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var missing = false

    /// Keep the view responsive on chatty logs (WINEDEBUG=+all can write megabytes per second).
    static let maxBytes = 512 * 1024
    private let queue = DispatchQueue(label: "mg.logtail")

    private final class Box: @unchecked Sendable {
        var tail: LogTail
        init(_ tail: LogTail) { self.tail = tail }
    }

    func follow(_ url: URL) async {
        text = ""
        missing = false
        let box = Box(LogTail(url: url, tailBytes: Self.maxBytes / 2))
        let queue = self.queue
        while !Task.isCancelled {
            let chunk = await withCheckedContinuation { (cont: CheckedContinuation<LogTail.Chunk, Never>) in
                queue.async { cont.resume(returning: box.tail.poll(maxBytes: 256 * 1024)) }
            }
            guard !Task.isCancelled else { return }
            if chunk.reset { text = "" }
            missing = chunk.missing
            if !chunk.text.isEmpty {
                var t = text + chunk.text
                if t.utf8.count > Self.maxBytes {
                    t = String(t.suffix(Self.maxBytes / 4 * 3 / 2)) // characters ≈ bytes for logs
                }
                text = t
            }
            try? await Task.sleep(nanoseconds: chunk.text.isEmpty ? 500_000_000 : 100_000_000)
        }
    }
}

struct LogViewer: View {
    let url: URL
    @StateObject private var tail = LogTailModel()
    @State private var follow = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text")
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if tail.missing {
                    Text("waiting for output…").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.checkbox)
                Button {
                    Panels.reveal(url)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show in Finder")
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .help("Open in the default app (Console)")
            }
            .padding(8)
            Divider()
            LogTextView(text: tail.text, follow: follow)
        }
        .task(id: url) { await tail.follow(url) }
    }
}

/// NSTextView: SwiftUI `Text` gets slow with hundreds of kilobytes, and this gives Find (⌘F) for free.
struct LogTextView: NSViewRepresentable {
    let text: String
    let follow: Bool

    final class Coordinator {
        var shown = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor]
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.isRichText = false
            tv.usesFindBar = true
            tv.isIncrementalSearchingEnabled = true
            tv.textContainerInset = NSSize(width: 6, height: 6)
            tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            tv.textColor = .textColor
            tv.backgroundColor = .textBackgroundColor
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, let storage = tv.textStorage else { return }
        let c = context.coordinator
        guard text != c.shown else { return }
        if !c.shown.isEmpty, text.hasPrefix(c.shown), let added = String(text.utf8.dropFirst(c.shown.utf8.count)) {
            storage.append(NSAttributedString(string: added, attributes: Self.attributes))
        } else {
            storage.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes))
        }
        c.shown = text
        if follow { tv.scrollToEndOfDocument(nil) }
    }
}

/// Every per-run log under `logs/`, newest first.
struct LogsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var entries: [LogStore.Entry] = []
    @State private var selected: URL?

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        HSplitView {
            List(entries, id: \.url, selection: $selected) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.url.deletingPathExtension().lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(e.bottle) · \(Self.dateFormat.string(from: e.modified)) · \(ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(e.url)
            }
            .frame(minWidth: 220, idealWidth: 290, maxWidth: 420)

            Group {
                if let selected {
                    LogViewer(url: selected).id(selected)
                } else {
                    Placeholder(symbol: "doc.text", title: entries.isEmpty ? "No logs yet" : "Select a log",
                                message: "Every run writes Wine's output to its own log file.")
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Logs")
        .toolbar {
            ToolbarItem {
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        entries = LogStore(paths: model.paths).list()
        if selected == nil || !entries.contains(where: { $0.url == selected }) { selected = entries.first?.url }
    }
}

/// A job under Activity: status, mg's progress lines, and the run's log tailing live.
struct JobDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                JobStatusIcon(job: job).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.title3.weight(.semibold))
                    Text(statusText)
                        .foregroundStyle(statusColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if job.isRunning, let b = job.bottle, job.kind == .program {
                    Button(role: .destructive) {
                        model.stop(bottle: b)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("End every Wine process in bottle \(b)")
                }
            }
            if !job.messages.isEmpty {
                ScrollView {
                    Text(job.messages.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
            if let log = job.logFile {
                LogViewer(url: log)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            } else {
                Spacer()
            }
        }
        .padding()
        .navigationTitle(job.title)
        .toolbar {
            ToolbarItem {
                Button("Clear Finished") { model.clearFinishedJobs() }
                    .disabled(!model.jobs.contains { !$0.isRunning })
            }
        }
    }

    private var statusText: String {
        let started = DateFormatter.localizedString(from: job.started, dateStyle: .none, timeStyle: .medium)
        switch job.state {
        case .running: return "Running since \(started)"
        case .succeeded(let s): return s
        case .failed(let e): return e
        }
    }

    private var statusColor: Color {
        switch job.state {
        case .running: return .secondary
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}
