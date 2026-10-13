import AppKit
import SwiftUI
import TextLensKit

/// The searchable list of past captures.
@MainActor
final class HistoryWindow: NSObject, NSWindowDelegate {
    static let shared = HistoryWindow()
    private var window: NSWindow?
    private let model = HistoryViewModel()

    func show(selecting id: UUID? = nil) {
        if window == nil {
            let hosting = NSHostingController(rootView: HistoryView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "TextLens History"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 860, height: 560))
            window.minSize = NSSize(width: 620, height: 380)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("TextLensHistory")
            window.delegate = self
            if window.frame.origin == .zero { window.center() }
            self.window = window
        }
        if let id { model.query = ""; model.kind = nil; model.selection = id }
        else if model.selection == nil { model.selection = HistoryStore.shared.entries.first?.id }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@Observable
@MainActor
final class HistoryViewModel {
    var query = ""
    var kind: HistoryEntry.Kind?
    var selection: UUID?
}

struct HistoryView: View {
    @Bindable var model: HistoryViewModel
    @State private var store = HistoryStore.shared
    @State private var prefs = Preferences.shared
    @State private var confirmClear = false

    private var results: [HistoryEntry] {
        HistoryQuery.search(store.entries, query: model.query, kind: model.kind)
    }

    private var selected: HistoryEntry? {
        model.selection.flatMap { id in store.entries.first { $0.id == id } }
    }

    var body: some View {
        NavigationSplitView {
            List(results, selection: $model.selection) { entry in
                HistoryRow(entry: entry).tag(entry.id)
                    .contextMenu { rowMenu(entry) }
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView(model.query.isEmpty ? "No Captures Yet" : "No Matches",
                                           systemImage: model.query.isEmpty ? "text.viewfinder" : "magnifyingglass",
                                           description: Text(model.query.isEmpty
                                                             ? (prefs.historyEnabled ? "Text you capture shows up here." : "History is turned off in Settings.")
                                                             : "Nothing in your history contains “\(model.query)”."))
                }
            }
            .onDeleteCommand { if let id = model.selection { delete(id) } }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text("\(results.count) of \(store.entries.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear…") { confirmClear = true }.controlSize(.small).disabled(store.entries.isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
            }
        } detail: {
            if let entry = selected {
                HistoryDetail(entry: entry) { delete(entry.id) }
            } else {
                ContentUnavailableView("Select a Capture", systemImage: "doc.text.magnifyingglass")
            }
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: "Search captured text")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $model.kind) {
                    Text("All").tag(HistoryEntry.Kind?.none)
                    ForEach(HistoryEntry.Kind.allCases, id: \.self) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(Optional(kind))
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .onCopyCommand {
            guard let entry = selected else { return [] }
            return [NSItemProvider(object: (entry.translation ?? entry.text) as NSString)]
        }
        .confirmationDialog("Clear your capture history?", isPresented: $confirmClear) {
            Button("Clear All but Pinned", role: .destructive) { store.clear(keepPinned: true) }
            Button("Clear Everything", role: .destructive) { store.clear(keepPinned: false) }
        } message: {
            Text("Captured text and pictures are deleted from this Mac. This can't be undone.")
        }
    }

    @ViewBuilder private func rowMenu(_ entry: HistoryEntry) -> some View {
        Button("Copy") { copy(entry.text) }
        if let translation = entry.translation { Button("Copy Translation") { copy(translation) } }
        Button(entry.pinned ? "Unpin" : "Pin") { store.togglePin(entry.id) }
        Divider()
        Button("Delete", role: .destructive) { delete(entry.id) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func delete(_ id: UUID) {
        let ordered = results.map(\.id)
        if let index = ordered.firstIndex(of: id) {
            model.selection = ordered.indices.contains(index + 1) ? ordered[index + 1] : (index > 0 ? ordered[index - 1] : nil)
        }
        store.delete([id])
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind.symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(HistoryQuery.snippet(entry.translation ?? entry.text)).lineLimit(2)
                HStack(spacing: 4) {
                    Text(entry.date, format: .relative(presentation: .named))
                    if let app = entry.appName { Text("· \(app)") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if entry.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
        }
        .padding(.vertical, 3)
    }
}

private struct HistoryDetail: View {
    let entry: HistoryEntry
    let onDelete: () -> Void
    @State private var store = HistoryStore.shared
    @State private var speech = Speech.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Label(entry.kind.title, systemImage: entry.kind.symbol)
                    Text("·")
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    if let app = entry.appName { Text("· \(app)") }
                }
                .font(.callout).foregroundStyle(.secondary)

                if let image = store.image(for: entry) {
                    Image(nsImage: image)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }

                section(entry.translation == nil ? "Text" : "Original\(languageName(entry.sourceLanguage))", entry.text)
                if let translation = entry.translation {
                    section("Translation\(languageName(entry.targetLanguage))", translation)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { copy(entry.translation ?? entry.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy the text")
                Button {
                    speech.isSpeaking ? speech.stop() : speech.speak(entry.translation ?? entry.text)
                } label: { Label(speech.isSpeaking ? "Stop" : "Speak", systemImage: speech.isSpeaking ? "stop.fill" : "speaker.wave.2") }
                    .help("Read the text aloud")
                Button { TranslationPanelController.shared.translate(text: entry.text, near: nil, image: nil, app: SourceApp(name: entry.appName, bundleID: entry.appBundleID), saveToHistory: false) } label: {
                    Label("Translate", systemImage: "translate")
                }
                .help("Translate the text")
                Button { store.togglePin(entry.id) } label: { Label(entry.pinned ? "Unpin" : "Pin", systemImage: entry.pinned ? "pin.slash" : "pin") }
                    .help("Pinned captures are never removed automatically")
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
                    .help("Delete this capture")
            }
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text)
                .textSelection(.enabled)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func languageName(_ code: String?) -> String {
        guard let code, let name = Locale.current.localizedString(forIdentifier: code) else { return "" }
        return " (\(name))"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
