#if DEBUG
import AppKit
import Carbon.HIToolbox

/// Debug builds only. `TEXTLENS_DEBUG_SHORTCUT_EDITOR=<folder>` (with `TEXTLENS_DEFAULTS_SUITE`,
/// so nothing real is touched): opens Settings › Shortcuts, works the shortcut editor (typing
/// "+", a bare letter, an F-key alone, pressing another shortcut's keys so they move, Esc,
/// Clear), draws the editor to PNGs, writes report.txt, and quits. Nothing else starts.
@MainActor
enum DebugShortcutEditorTest {
    static func run(folder: String) {
        guard ProcessInfo.processInfo.environment["TEXTLENS_DEFAULTS_SUITE"] != nil else {
            NSLog("TextLens: this test needs TEXTLENS_DEFAULTS_SUITE")
            exit(2)
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var report: [String] = []
        func note(_ line: String) {
            report.append(line)
            try? report.joined(separator: "\n").appending("\n").write(to: out.appending(path: "report.txt"), atomically: true, encoding: .utf8)
        }
        func render(_ view: NSView?, _ name: String) {
            guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { note("no view for \(name)"); return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appending(path: name))
        }
        func recorders(in view: NSView) -> [ShortcutRecorder.RecorderButton] {
            ((view as? ShortcutRecorder.RecorderButton).map { [$0] } ?? []) + view.subviews.flatMap(recorders)
        }
        func press(_ key: HotKey, in window: NSWindow, model: ShortcutEditorModel) -> Bool {
            var flags: NSEvent.ModifierFlags = []
            if key.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
            if key.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
            if key.modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
            if key.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: "",
                                               charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(key.keyCode)) else { return false }
            return model.handle(event)
        }
        /// The popover's close animation takes most of a second.
        func waitClosed(_ button: ShortcutRecorder.RecorderButton) async {
            for _ in 0..<40 where button.debugModel != nil { try? await Task.sleep(for: .milliseconds(100)) }
        }
        func state() -> String {
            HotKeyCenter.Action.allCases.map { "\($0)=\($0.hotKey?.display ?? "none")" }.joined(separator: " ")
        }

        Task {
            let prefs = Preferences.shared
            note("running \(AppInfo.version)")
            HotKeyCenter.shared.apply()
            note("before: \(state()); registered \(HotKeyCenter.shared.reportedShortcuts.count)")
            SettingsWindow.shared.show(tab: "Shortcuts")
            try? await Task.sleep(for: .seconds(2))
            guard let window = SettingsWindow.shared.debugWindow,
                  let tabs = window.contentViewController as? NSTabViewController,
                  let pane = tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController?.view else {
                note("no Settings window"); exit(1)
            }
            let buttons = recorders(in: pane)
            note("boxes: \(buttons.map(\.debugTitle))")
            guard let capture = buttons.first, let history = buttons.last else { note("no boxes"); exit(1) }

            // 1. "+" → ⇧ + "=", a bare letter refused, an F-key alone, another shortcut's keys.
            capture.performClick(nil)
            try? await Task.sleep(for: .milliseconds(400))
            guard let model = capture.debugModel else { note("editor did not open"); exit(1) }
            note("open: shown \(capture.debugPopoverShown) window visible \(capture.debugPopoverView?.window?.isVisible == true) app active \(NSApp.isActive); title '\(capture.debugTitle)', registered while open \(HotKeyCenter.shared.reportedShortcuts.count)")
            model.control = false; model.option = false; model.shift = false; model.command = false
            model.typed("+")
            note("plus alone → key '\(model.keyText)' shift \(model.shift) combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
            model.control = true; model.option = true; model.command = true
            note("plus with ⌃⌥⌘ → combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
            model.control = false; model.option = false; model.shift = false; model.command = false
            model.typed("k")
            note("bare k → combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
            model.choose(Int(kVK_F6))
            note("F6 alone → combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
            try? await Task.sleep(for: .milliseconds(300))
            render(capture.debugPopoverView, "editor-f6.png")
            func fields(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(fields) }
            if let field = capture.debugPopoverView.flatMap({ fields($0).first(where: { $0.isEditable }) }) {
                let editor = field.currentEditor() as? NSTextView
                note("key field: value '\(field.stringValue)' editing \(editor != nil) editor '\(editor?.string ?? "-")' width \(field.frame.width)")
                field.window?.makeFirstResponder(nil)
                try? await Task.sleep(for: .milliseconds(300))
                render(capture.debugPopoverView, "editor-f6-unfocused.png")
            }
            model.control = true; model.option = true; model.command = true
            model.choose(Int(kVK_ANSI_Q))
            note("⌃⌥⌘Q → combo \(model.combo?.display ?? "-") system \(model.systemUse ?? "-")")
            model.control = false; model.option = false
            note("⌘Q → combo \(model.combo?.display ?? "-") system \(model.systemUse ?? "-")")
            guard let historyKey = prefs.historyHotKey else { note("no history key"); exit(1) }
            let used = press(historyKey, in: window, model: model)
            note("pressed \(historyKey.display) (used \(used)) → combo \(model.combo?.display ?? "-") moves from \(model.movesFrom)")
            try? await Task.sleep(for: .milliseconds(300))
            render(capture.debugPopoverView, "editor-move.png")
            model.finish?(.set(model.combo))
            await waitClosed(capture)
            note("after Set: \(state()); box '\(capture.debugTitle)' history box '\(history.debugTitle)'; registered \(HotKeyCenter.shared.reportedShortcuts.count); popover gone \(capture.debugModel == nil)")

            // 2. An F-key alone on the now-empty history shortcut.
            history.performClick(nil)
            try? await Task.sleep(for: .milliseconds(400))
            if let m = history.debugModel {
                note("history editor: Clear enabled \(m.original != nil)")
                m.choose(Int(kVK_F6))
                m.finish?(.set(m.combo))
                await waitClosed(history)
                note("history F6 set: \(prefs.historyHotKey?.display ?? "none") box '\(history.debugTitle)'")
            } else { note("history editor did not open") }

            // 3. Esc cancels without changing anything.
            capture.performClick(nil)
            try? await Task.sleep(for: .milliseconds(400))
            if let m = capture.debugModel {
                m.choose(Int(kVK_ANSI_J))
                if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                              charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: UInt16(kVK_Escape)) {
                    _ = m.handle(esc)
                }
                await waitClosed(capture)
                note("after Esc: capture \(prefs.captureTextHotKey?.display ?? "none") closed \(capture.debugModel == nil)")
            }

            // 4. Clear.
            capture.performClick(nil)
            try? await Task.sleep(for: .milliseconds(400))
            if let m = capture.debugModel {
                m.finish?(.set(nil))
                await waitClosed(capture)
                note("after Clear: capture \(prefs.captureTextHotKey?.display ?? "none") box '\(capture.debugTitle)'; registered \(HotKeyCenter.shared.reportedShortcuts.count)")
            }
            note("final: \(state())")
            note("done")
            HotKeyCenter.shared.unregisterAll()
            exit(0)
        }
    }
}
#endif
