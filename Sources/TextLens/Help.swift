import AppKit
import SwiftUI

// MARK: - Content

/// One page of Help. `Help.resolve` swaps `{…}` tokens for the user's own settings, such
/// as their shortcuts, so the text matches what they've set up.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
enum HelpBlock {
    case text(String)
    case heading(String)
    /// Keys on the left, what they do on the right.
    case keys([(String, String)])
    case tip(String)

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s): Help.resolve(s)
        case .keys(let rows): rows.map { Help.resolve($0.0) + " " + Help.resolve($0.1) }.joined(separator: " ")
        }
    }
}

@MainActor
enum Help {
    /// `{hotkey:<name>}` shows the user's own shortcut for that action.
    static func resolve(_ text: String) -> String {
        guard text.contains("{hotkey:") else { return text }
        let p = Preferences.shared
        let keys: [(String, HotKey?)] = [
            ("capture", p.captureTextHotKey), ("again", p.captureAgainHotKey), ("qr", p.captureCodeHotKey),
            ("translate", p.translateHotKey), ("live", p.liveTranslateHotKey), ("watch", p.watchHotKey),
            ("history", p.historyHotKey),
        ]
        var out = text
        for (name, key) in keys { out = out.replacingOccurrences(of: "{hotkey:\(name)}", with: key?.display ?? "(no shortcut set)") }
        return out
    }

    static var debugTokens: String { resolve("{hotkey:capture} {hotkey:again} {hotkey:qr} {hotkey:translate} {hotkey:live} {hotkey:watch} {hotkey:history}") }

    /// The Settings tabs, for the Debug self-test.
    static let testTabs = ["Capture", "Translate", "Watch", "History", "Activity", "Shortcuts", "Privacy", "General"]

    /// The topic each Settings tab's Help button opens.
    static func topic(forSettingsTab tab: String) -> String {
        switch tab {
        case "Capture": "capture"
        case "Translate": "translate"
        case "Watch": "watch"
        case "History": "history"
        case "Activity": "history"
        case "Shortcuts": "shortcuts"
        case "Privacy": "privacy"
        default: "getting-started"
        }
    }

    static var topics: [HelpTopic] { [
        HelpTopic(id: "getting-started", title: "Getting Started", symbol: "sparkles", blocks: [
            .text("TextLens copies the text from anything on your screen: a screenshot, a video, a photo, a PDF, an app that won't let you select text. Press a shortcut, drag over the area, and the text is on your clipboard."),
            .keys([
                ("{hotkey:capture}", "Capture text"),
                ("{hotkey:qr}", "Read a QR or bar code"),
                ("{hotkey:translate}", "Capture and translate"),
                ("Menu bar icon", "Every action, plus reading text in files and copied pictures"),
            ]),
            .heading("Allow Screen Recording"),
            .text("TextLens needs Screen Recording permission to see the screen. If the menu bar menu shows \"Allow Screen Recording…\", choose it, switch TextLens on, and open TextLens again. Everything is read on this Mac; nothing is uploaded."),
            .tip("The screen freezes while you select, so a menu, tooltip or video frame stays put while you drag over it."),
            .tip("While ToolHUD is running, TextLens's menu moves into ToolHUD's menu bar menu as a submenu, and the icon here steps aside until ToolHUD quits. To keep the icon, turn off \"Put in ToolHUD's menu while ToolHUD is running\" in Settings."),
        ]),

        HelpTopic(id: "capture", title: "Capturing Text", symbol: "text.viewfinder", blocks: [
            .text("Press {hotkey:capture}, then drag over the text. When you let go, the text is copied. Press Esc to cancel."),
            .keys([
                ("{hotkey:capture}", "Capture text"),
                ("{hotkey:again}", "Capture the same area again, without dragging, handy for something that keeps changing"),
                ("Esc", "Cancel the selection"),
            ]),
            .heading("Options in Settings › Capture"),
            .keys([
                ("Keep line breaks", "Keep lines as they appear, or join them into paragraphs"),
                ("Additive clipboard", "Add each capture below what's already copied, to collect several pieces and paste them at once"),
                ("Open links automatically", "Open the first link in what you captured"),
                ("Language / Detect automatically", "Which language to read; detection works for most"),
                ("Recognition", "Accurate, or fast"),
                ("Custom words", "Names and jargon that recognition should prefer"),
                ("Read text aloud after capture", "Hear what was captured"),
            ]),
            .heading("Other ways in"),
            .text("In the menu bar menu, \"Read Text in Files…\" reads images and PDFs, and \"Read Text in Copied Picture\" reads an image you've copied. Keep Line Breaks, Additive Clipboard and Read Aloud After Capture switch on and off right in the menu."),
        ]),

        HelpTopic(id: "qr", title: "QR and Bar Codes", symbol: "qrcode.viewfinder", blocks: [
            .text("Press {hotkey:qr} and drag over a QR code or bar code. Its contents are copied; a single link opens if \"Open links automatically\" is on."),
            .text("\"Make QR Code…\" in the menu bar menu makes a QR code from text. It starts with what's on your clipboard."),
        ]),

        HelpTopic(id: "translate", title: "Translating", symbol: "translate", blocks: [
            .text("Press {hotkey:translate} and drag over text in another language. The translation appears in a panel next to the area."),
            .heading("Live translation"),
            .text("Press {hotkey:live} and drag over an area, such as subtitles or a chat. TextLens keeps reading it and translates whenever its text changes. Press the shortcut again to stop. Settings › Translate chooses whether the translation shows in a panel or over the original text."),
            .heading("Languages"),
            .text("Translation runs on this Mac with Apple's translation languages. Choose the language to translate into, and what to copy afterwards, in Settings › Translate. The first time you use a pair of languages, macOS offers to download them."),
        ]),

        HelpTopic(id: "watch", title: "Watching an Area", symbol: "eye", blocks: [
            .text("Press {hotkey:watch} (or choose \"Watch Area for Changes…\") and drag over part of the screen. TextLens reads it every few seconds and alerts you when it changes, when a word appears, or when a word disappears. Useful for a build status, a queue position, or a price."),
            .text("The menu bar menu lists what's being watched, how many alerts each has raised, and Stop Watching. Small flickers are ignored: a change has to show up twice in a row before it counts."),
            .keys([
                ("Play a sound", "When an alert fires"),
                ("Save each alert to History", "Keep a record of each change"),
                ("Outline watched areas", "Show what's being watched on screen"),
            ]),
        ]),

        HelpTopic(id: "history", title: "History", symbol: "clock.arrow.circlepath", blocks: [
            .text("Press {hotkey:history} (or choose History… in the menu bar menu) to see past captures and translations, with the picture of each. Search the text, or show one kind of capture."),
            .keys([
                ("Copy", "Copy the text (or the translation)"),
                ("Speak", "Read it aloud"),
                ("Translate", "Translate a past capture"),
                ("Pin", "Keep it no matter how old it gets"),
                ("Right-click", "Copy, Copy Translation, Pin, Delete"),
            ]),
            .text("Settings › History sets how many captures to keep and for how long, and whether to save pictures. Pinned captures are kept no matter what. With sync on, history goes to your other Macs end-to-end encrypted. Settings › Activity graphs how many captures you make."),
        ]),

        HelpTopic(id: "shortcuts", title: "Keyboard Shortcuts", symbol: "keyboard", blocks: [
            .keys([
                ("{hotkey:capture}", "Capture text"),
                ("{hotkey:again}", "Capture the same area again"),
                ("{hotkey:qr}", "Read a QR or bar code"),
                ("{hotkey:translate}", "Capture and translate"),
                ("{hotkey:live}", "Live translate an area (again to stop)"),
                ("{hotkey:watch}", "Watch an area for changes"),
                ("{hotkey:history}", "Show history"),
                ("Esc", "Cancel a selection"),
                ("⌘?", "This Help, from TextLens's menus"),
            ]),
            .text("Change them in Settings › Shortcuts: click a shortcut, then press the new keys. Delete clears it; shortcuts need ⌘, ⌥ or ⌃."),
        ]),

        HelpTopic(id: "privacy", title: "Privacy", symbol: "hand.raised", blocks: [
            .text("Text recognition and translation run entirely on this Mac. TextLens only looks at the screen when you capture, watch or live-translate an area. With sync on, settings and history travel through your iCloud account, encrypted with a passphrase only you know."),
            .text("You can remove TextLens's Screen Recording access at any time in System Settings › Privacy & Security; capturing then stops until you allow it again."),
        ]),

        HelpTopic(id: "automation", title: "Automation", symbol: "gearshape.2", blocks: [
            .keys([
                ("textlens://capture", "Capture text"),
                ("textlens://recapture", "Capture the same area again"),
                ("textlens://qr", "Read a QR or bar code"),
                ("textlens://translate", "Capture and translate"),
                ("textlens://live-translate", "Live translate (again to stop)"),
                ("textlens://watch", "Watch an area"),
                ("textlens://history", "Show history"),
            ]),
            .text("Use these links from Shortcuts, scripts or a launcher. ToolHUD's TextLens buttons use them."),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", symbol: "wrench.and.screwdriver", blocks: [
            .heading("Capturing shows only the desktop, or nothing"),
            .text("TextLens needs Screen Recording permission. Choose \"Allow Screen Recording…\" in the menu bar menu, switch TextLens on, then quit and reopen TextLens."),
            .heading("The text has mistakes"),
            .text("Choose the right language (or turn on automatic detection), use Accurate recognition, and add names and jargon as custom words in Settings › Capture. Bigger, sharper text reads better: zoom in first if you can."),
            .heading("Translation asks to download languages"),
            .text("That happens once per pair of languages; macOS keeps them on this Mac afterwards."),
            .heading("A shortcut does nothing"),
            .text("Another app may use the same keys. Pick a different one in Settings › Shortcuts."),
        ]),
    ] }
}

// MARK: - Window

@Observable
@MainActor
final class HelpState {
    var selection: String? = "getting-started"
    var query = ""
}

@MainActor
final class HelpWindow: NSObject, NSWindowDelegate {
    static let shared = HelpWindow()

    let state = HelpState()
    private(set) var window: NSWindow?

    /// Opens Help, on `topic` when given.
    func show(topic: String? = nil) {
        if let topic { state.query = ""; state.selection = topic }
        if window == nil {
            let hosting = NSHostingController(rootView: HelpView(state: state))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "\(AppInfo.name) Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            let screen = NSScreen.main?.visibleFrame.height ?? 800
            window.setContentSize(NSSize(width: 820, height: min(600, screen - 80)))
            window.contentMinSize = NSSize(width: 640, height: 400)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("TextLensHelp")
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HelpView: View {
    @Bindable var state: HelpState

    private var matches: [HelpTopic] {
        let query = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Help.topics }
        return Help.topics.filter { topic in
            topic.title.lowercased().contains(query) || topic.blocks.contains { $0.searchText.lowercased().contains(query) }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(matches, selection: $state.selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .overlay {
                if matches.isEmpty { Text("No matches").foregroundStyle(.secondary) }
            }
        } detail: {
            if let topic = Help.topics.first(where: { $0.id == state.selection }) {
                HelpPage(topic: topic, query: state.query)
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: state.query) {
            // Keep a matching topic on screen while searching.
            if let first = matches.first, !matches.contains(where: { $0.id == state.selection }) { state.selection = first.id }
        }
    }
}

struct HelpPage: View {
    let topic: HelpTopic
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: HelpBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true)
        case .heading(let s):
            Text(Help.resolve(s)).font(.title3.weight(.semibold)).padding(.top, 8)
        case .tip(let s):
            Label { Text(Help.resolve(s)).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .keys(let rows):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let keys = Help.resolve(row.0), what = Help.resolve(row.1)
                    let hit = !query.isEmpty && (keys + " " + what).lowercased().contains(query.lowercased())
                    GridRow {
                        Text(keys)
                            .font(.body.monospaced().weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            // The same key column width in every table on every page.
                            .frame(width: 210, alignment: .leading)
                        Text(what).fixedSize(horizontal: false, vertical: true)
                    }
                    .background(hit ? Color.yellow.opacity(0.25) : .clear)
                }
            }
        }
    }
}

/// The round "?" button macOS puts in the corner of settings panes.
struct HelpButton: NSViewRepresentable {
    let topic: String

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.open))
        button.bezelStyle = .helpButton
        button.toolTip = "\(AppInfo.name) Help"
        button.setAccessibilityLabel("Help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.topic = topic }

    func makeCoordinator() -> Coordinator { Coordinator(topic: topic) }

    @MainActor
    final class Coordinator: NSObject {
        var topic: String
        init(topic: String) { self.topic = topic }
        @objc func open() { HelpWindow.shared.show(topic: topic) }
    }
}
