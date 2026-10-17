import AppKit
import SwiftUI

MainActor.assumeIsolated {
    // `TextLens --selftest <image-or-pdf> [target-language]` reads a file, prints its text,
    // codes and translation, and exits; used to check recognition without the UI.
    if let index = CommandLine.arguments.firstIndex(of: "--selftest"), CommandLine.arguments.count > index + 1 {
        SelfTest.run(path: CommandLine.arguments[index + 1],
                     target: CommandLine.arguments.count > index + 2 ? CommandLine.arguments[index + 2] : nil)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(AppPresence.showInDock ? .regular : .accessory)
    app.run()
}

/// Launch, the menu bar item, the Dock menu, and reopening.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let capture = Capture.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = AppPresence.mainMenu(appName: AppInfo.name, settingsTitle: "Settings…",
                                            target: self, settings: #selector(showSettings))
        // Right below About in the app menu.
        mainMenu.items.first?.submenu?.insertItem(item("Our other apps…", #selector(showOtherApps)), at: 1)
        NSApp.mainMenu = mainMenu
        // Set at the end of the first launch, so its absence means a brand-new install.
        let newInstall = !AppDefaults.store.bool(forKey: "welcomed")
        if newInstall { SettingsSync.shared.adoptOnNewInstall() }
        SettingsSync.shared.start()
        ActivitySync.shared.start()
        HistorySync.shared.start()
        // CloudKit tells the sync engine about other Macs' changes by push.
        NSApp.registerForRemoteNotifications()
        #if DEBUG
        SyncDebugHook.run()
        #endif

        HotKeyCenter.shared.perform = { [weak self] action in self?.perform(action) }
        HotKeyCenter.shared.apply()

        setUpStatusItem()
        NotificationCenter.default.addObserver(forName: AppPresence.menuBarDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.statusItem?.isVisible = AppPresence.showInMenuBar }
        }

        HistoryStore.shared.prune()
        AutoUpdater.shared.start()
        // Sync is on but waiting for a passphrase (just updated from an unencrypted version,
        // or joining another Mac): say so where it can be entered, once per version.
        let sync = SettingsSync.shared
        let syncNeedsPassphrase = sync.isEnabled && [.needsPassphrase, .needsNewPassphrase].contains(sync.keyState)
            && AppDefaults.store.string(forKey: "sync.passphrasePromptVersion") != AppInfo.version
        if syncNeedsPassphrase { AppDefaults.store.set(AppInfo.version, forKey: "sync.passphrasePromptVersion") }
        if newInstall {
            AppDefaults.store.set(true, forKey: "welcomed")
            // Ask for Screen Recording up front, so the first capture just works.
            if !ScreenAccess.granted { ScreenAccess.request() }
            SettingsWindow.shared.show(tab: syncNeedsPassphrase ? "General" : nil)
        } else if syncNeedsPassphrase {
            SettingsWindow.shared.show(tab: "General")
        } else if !AppPresence.showInMenuBar && !AppPresence.showInDock {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        WatchManager.shared.stopAll()
        LiveTranslator.shared.stop()
        ActivitySync.shared.flush()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = AppPresence.dockMenu(title: "Settings…", target: self, action: #selector(showSettings))
        menu.insertItem(.separator(), at: 0)
        for item in captureItems().reversed() { menu.insertItem(item, at: 0) }
        return menu
    }

    /// Opening the app again (from Applications, Spotlight, or the Dock tile) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Pictures and PDFs dropped on the Dock icon or opened with TextLens get read, and
    /// `textlens://` URLs (from ToolHUD, Shortcuts or a script) run the action they name.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "textlens" {
            if let action = Self.urlActions[url.host ?? ""] { perform(action) }
        }
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { capture.recognize(files: files) }
    }

    /// The `textlens://<host>` actions. Their names and titles are also listed under
    /// ToolHUDActions in Info.plist, which is how ToolHUD finds them.
    private static let urlActions: [String: HotKeyCenter.Action] = [
        "capture": .captureText, "recapture": .captureAgain, "qr": .captureCode, "translate": .translate,
        "live-translate": .liveTranslate, "watch": .watch, "history": .history,
    ]

    private func perform(_ action: HotKeyCenter.Action) {
        switch action {
        case .captureText: capture.captureText()
        case .captureCode: capture.captureCode()
        case .captureAgain: capture.captureAgain()
        case .translate: capture.captureAndTranslate()
        case .liveTranslate: capture.toggleLiveTranslation()
        case .watch: capture.watchRegion()
        case .history: HistoryWindow.shared.show()
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = AppPresence.showInMenuBar
        let image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: AppInfo.name)
        image?.isTemplate = true
        item.button?.image = image
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = Preferences.shared

        if !ScreenAccess.granted {
            let warn = item("Allow Screen Recording…", #selector(allowScreenRecording))
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        for item in captureItems() { menu.addItem(item) }

        let watches = WatchManager.shared.watches
        if !watches.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Watching", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for watch in watches {
                let entry = NSMenuItem(title: watch.name, action: nil, keyEquivalent: "")
                entry.image = NSImage(systemSymbolName: watch.lastError == nil ? "eye" : "exclamationmark.triangle",
                                      accessibilityDescription: nil)
                let sub = NSMenu()
                let info = NSMenuItem(title: "Alerts on \(watch.summary), every \(WatchManager.format(watch.interval))",
                                      action: nil, keyEquivalent: "")
                info.isEnabled = false
                sub.addItem(info)
                let changes = NSMenuItem(title: watch.changes == 0 ? "No alerts yet"
                                         : "\(watch.changes) alert\(watch.changes == 1 ? "" : "s"), last \(watch.lastChange!.formatted(date: .omitted, time: .shortened))",
                                         action: nil, keyEquivalent: "")
                changes.isEnabled = false
                sub.addItem(changes)
                if let error = watch.lastError {
                    let e = NSMenuItem(title: error, action: nil, keyEquivalent: "")
                    e.isEnabled = false
                    sub.addItem(e)
                }
                sub.addItem(.separator())
                let stop = NSMenuItem(title: "Stop Watching", action: #selector(stopWatch(_:)), keyEquivalent: "")
                stop.target = self
                stop.representedObject = watch.id
                sub.addItem(stop)
                entry.submenu = sub
                menu.addItem(entry)
            }
            if watches.count > 1 { menu.addItem(item("Stop All Watches", #selector(stopAllWatches))) }
        }

        menu.addItem(.separator())
        menu.addItem(item("Read Text in Files…", #selector(recognizeFile)))
        menu.addItem(item("Read Text in Copied Picture", #selector(recognizeClipboard)))
        menu.addItem(item("Make QR Code…", #selector(makeQRCode)))
        menu.addItem(item("History…", #selector(showHistory), hotKey: prefs.historyHotKey))

        menu.addItem(.separator())
        menu.addItem(toggle("Keep Line Breaks", prefs.keepLineBreaks, #selector(toggleLineBreaks)))
        menu.addItem(toggle("Additive Clipboard", prefs.additiveClipboard, #selector(toggleAdditive)))
        menu.addItem(toggle("Read Aloud After Capture", prefs.speakAfterCapture, #selector(toggleSpeak)))
        if Speech.shared.isSpeaking { menu.addItem(item("Stop Speaking", #selector(stopSpeaking))) }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        #if !APPSTORE
        if let staged = AutoUpdater.shared.staged {
            menu.addItem(item("Update to \(staged.version) Now (Otherwise Installs When Idle)", #selector(installUpdateNow)))
        } else if let pending = UpdateAvailability.shared.pending {
            menu.addItem(item("Update to \(pending)…", #selector(checkForUpdates)))
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        }
        #endif
        menu.addItem(item("About \(AppInfo.name)", #selector(showAbout)))
        menu.addItem(item("Our other apps…", #selector(showOtherApps)))
        menu.addItem(.separator())
        let version = NSMenuItem(title: "\(AppInfo.name) \(AppInfo.displayVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item("Quit \(AppInfo.name)", #selector(quit), key: "q"))
    }

    private func captureItems() -> [NSMenuItem] {
        let prefs = Preferences.shared
        let again = item("Capture Same Area Again", #selector(captureAgain), hotKey: prefs.captureAgainHotKey)
        again.isEnabled = capture.lastRegion != nil
        let live = LiveTranslator.shared.isRunning
        return [
            item("Capture Text", #selector(captureText), hotKey: prefs.captureTextHotKey, symbol: "text.viewfinder"),
            again,
            item("Read QR or Bar Code", #selector(captureCode), hotKey: prefs.captureCodeHotKey, symbol: "qrcode.viewfinder"),
            item("Capture and Translate", #selector(captureTranslate), hotKey: prefs.translateHotKey, symbol: "translate"),
            item(live ? "Stop Live Translation" : "Live Translate Area…", #selector(liveTranslate),
                 hotKey: prefs.liveTranslateHotKey, symbol: live ? "stop.circle" : "dot.radiowaves.left.and.right"),
            item("Watch Area for Changes…", #selector(watchRegion), hotKey: prefs.watchHotKey, symbol: "eye"),
        ]
    }

    private func item(_ title: String, _ action: Selector, key: String = "", hotKey: HotKey? = nil,
                      symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let shortcut = hotKey?.menuKeyEquivalent {
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.mask
        }
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private func toggle(_ title: String, _ on: Bool, _ action: Selector) -> NSMenuItem {
        let item = item(title, action)
        item.state = on ? .on : .off
        return item
    }

    // MARK: - Actions

    @objc func captureText() { capture.captureText() }
    @objc func captureAgain() { capture.captureAgain() }
    @objc func captureCode() { capture.captureCode() }
    @objc func captureTranslate() { capture.captureAndTranslate() }
    @objc func liveTranslate() { capture.toggleLiveTranslation() }
    @objc func watchRegion() { capture.watchRegion() }
    @objc func recognizeFile() { capture.recognizeFile() }
    @objc func recognizeClipboard() { capture.recognizeClipboardImage() }
    @objc func makeQRCode() {
        let text = NSPasteboard.general.string(forType: .string).flatMap { $0.count <= 1_000 ? $0 : nil }
        QRMakerWindow.shared.show(text: text)
    }
    @objc func showHistory() { HistoryWindow.shared.show() }
    @objc func toggleLineBreaks() { Preferences.shared.keepLineBreaks.toggle() }
    @objc func toggleAdditive() { Preferences.shared.additiveClipboard.toggle() }
    @objc func toggleSpeak() { Preferences.shared.speakAfterCapture.toggle() }
    @objc func stopSpeaking() { Speech.shared.stop() }
    @objc func stopWatch(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let watch = WatchManager.shared.watches.first(where: { $0.id == id }) else { return }
        WatchManager.shared.stop(watch)
    }
    @objc func stopAllWatches() { WatchManager.shared.stopAll() }
    @objc func allowScreenRecording() {
        if !ScreenAccess.request() { ScreenAccess.openSettings() }
    }
    @objc func showSettings() { SettingsWindow.shared.show() }
    @objc func checkForUpdates() { UpdateController.checkForUpdates() }
    @objc func installUpdateNow() { AutoUpdater.shared.installNow() }
    @objc func quit() { NSApp.terminate(nil) }

    /// The developer's site, which lists every app.
    @objc func showOtherApps() {
        if let url = URL(string: "https://stevemanke.com/") { NSWorkspace.shared.open(url) }
    }
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}

@MainActor
enum SelfTest {
    static func run(path: String, target: String?) {
        Task {
            let url = URL(fileURLWithPath: path)
            let images = url.pathExtension.lowercased() == "pdf" ? Recognizer.pageImages(ofPDF: url)
                : [NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)].compactMap { $0 }
            guard let image = images.first else { print("ERROR: can't open \(path)"); exit(1) }
            for keep in [true, false] {
                let text = (try? await Recognizer.text(in: image, keepLineBreaks: keep, options: Recognizer.Options())) ?? "ERROR"
                print("=== TEXT keepLineBreaks=\(keep)\n\(text)")
            }
            print("=== CODES\n\((try? await Recognizer.codes(in: image))?.joined(separator: "\n") ?? "ERROR")")
            if let target {
                let text = (try? await Recognizer.text(in: image, keepLineBreaks: true, options: Recognizer.Options())) ?? ""
                do {
                    let result = try await Translator.shared.translate(text, to: Locale.Language(identifier: target), allowDownload: false)
                    print("=== TRANSLATION \(result.source.minimalIdentifier) -> \(result.target.minimalIdentifier)\n\(result.text)")
                } catch {
                    print("=== TRANSLATION ERROR \(error.localizedDescription)")
                }
            }
            exit(0)
        }
        RunLoop.main.run()
    }
}
