import AppKit
import SwiftUI
import TextLensKit
import UserNotifications

/// One region being watched for changes.
@Observable
@MainActor
final class Watch: Identifiable {
    let id = UUID()
    let name: String
    let region: ScreenRegion
    let globalFrame: CGRect
    let interval: TimeInterval
    let app: SourceApp
    private(set) var detector: ChangeDetector
    private(set) var lastText = ""
    private(set) var changes = 0
    private(set) var lastChange: Date?
    private(set) var lastError: String?

    @ObservationIgnored fileprivate var task: Task<Void, Never>?
    @ObservationIgnored fileprivate var outline: OutlineWindow?

    init(name: String, region: ScreenRegion, globalFrame: CGRect, interval: TimeInterval, detector: ChangeDetector, app: SourceApp) {
        self.name = name
        self.region = region
        self.globalFrame = globalFrame
        self.interval = interval
        self.detector = detector
        self.app = app
    }

    var summary: String {
        switch detector.trigger {
        case .anyChange: "any change"
        case .appears: "“\(detector.keyword)” appears"
        case .disappears: "“\(detector.keyword)” disappears"
        }
    }

    fileprivate func start() {
        let camera = region.camera()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let image = try await camera.capture()
                    let text = try await Recognizer.text(in: image, keepLineBreaks: true, options: .current)
                    guard !Task.isCancelled else { return }
                    self.lastError = nil
                    self.lastText = text
                    let outcome = self.detector.feed(text)
                    if case .fired(let old, let new) = outcome { self.fired(old: old, new: new, image: image) }
                } catch is CancellationError {
                    return
                } catch {
                    self.lastError = error.localizedDescription
                    NSLog("TextLens: watch \(self.name) capture failed: \(error.localizedDescription)")
                }
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
    }

    private func fired(old: String, new: String, image: CGImage) {
        changes += 1
        lastChange = Date()
        Activity.shared.touch()
        outline?.flash()
        Sounds.watchFired()
        let prefs = Preferences.shared
        var entry: HistoryEntry?
        if prefs.watchSaveToHistory {
            entry = HistoryStore.shared.add(kind: .watch, text: new, app: app, image: image)
        }
        let content = UNMutableNotificationContent()
        switch detector.trigger {
        case .anyChange: content.title = "\(name) changed"
        case .appears: content.title = "“\(detector.keyword)” appeared in \(name)"
        case .disappears: content.title = "“\(detector.keyword)” is gone from \(name)"
        }
        content.body = new.isEmpty ? "The text disappeared." : ChangeDetector.addedText(old: old, new: new)
        if let entry { content.userInfo = ["historyID": entry.id.uuidString] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watch-\(id)-\(changes)", content: content, trigger: nil))
    }
}

/// All watched regions.
@Observable
@MainActor
final class WatchManager {
    static let shared = WatchManager()
    private(set) var watches: [Watch] = []
    @ObservationIgnored private var setupPanel: FloatingPanel?
    @ObservationIgnored private var counter = 0

    /// Shows the setup panel for a freshly selected region.
    func setUp(_ selection: RegionSelector.Selection, app: SourceApp) {
        setupPanel?.close()
        counter += 1
        let model = WatchSetupModel(name: app.name.map { "Area in \($0)" } ?? "Area \(counter)")
        let panel = FloatingPanel(title: "Watch Area", size: CGSize(width: 420, height: 440), resizable: false)
        let outline = OutlineWindow(frame: selection.globalFrame, color: .systemGreen, label: "")
        outline.orderFrontRegardless()
        let view = WatchSetupView(model: model, image: selection.image) { [weak self] start in
            outline.orderOut(nil)
            self?.setupPanel?.close()
            self?.setupPanel = nil
            if start { self?.start(model: model, selection: selection, app: app) }
        }
        panel.host(view)
        panel.place(near: selection.globalFrame)
        panel.becomesKeyOnlyIfNeeded = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        setupPanel = panel
        // Show what the region reads right now, to help pick a keyword.
        Task {
            model.currentText = (try? await Recognizer.text(in: selection.image, keepLineBreaks: true, options: .current)) ?? ""
            model.reading = false
        }
    }

    private func start(model: WatchSetupModel, selection: RegionSelector.Selection, app: SourceApp) {
        let prefs = Preferences.shared
        prefs.watchTrigger = model.trigger
        prefs.watchInterval = model.interval
        AutoUpdater.shared.requestNotificationPermission()
        let detector = ChangeDetector(trigger: model.trigger, keyword: model.keyword, useRegex: model.useRegex)
        let name = model.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Watched region" : model.name
        let watch = Watch(name: name, region: selection.region, globalFrame: selection.globalFrame,
                          interval: model.interval, detector: detector, app: app)
        if prefs.watchShowOutline {
            let outline = OutlineWindow(frame: selection.globalFrame, color: .systemGreen, label: name)
            outline.orderFrontRegardless()
            watch.outline = outline
        }
        watches.append(watch)
        watch.start()
        Notice.shared.show("Watching \(name) every \(Self.format(model.interval))", symbol: "eye.fill", tint: .systemGreen,
                           near: selection.globalFrame)
    }

    func stop(_ watch: Watch) {
        watch.task?.cancel()
        watch.outline?.orderOut(nil)
        watches.removeAll { $0.id == watch.id }
        Activity.shared.touch()
    }

    func stopAll() {
        for watch in watches { stop(watch) }
    }

    /// Hides or shows every outline, following the setting.
    func refreshOutlines() {
        for watch in watches {
            if Preferences.shared.watchShowOutline {
                if watch.outline == nil {
                    watch.outline = OutlineWindow(frame: watch.globalFrame, color: .systemGreen, label: watch.name)
                }
                watch.outline?.orderFrontRegardless()
            } else {
                watch.outline?.orderOut(nil)
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : (seconds.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(seconds / 60)) min" : String(format: "%.1f min", seconds / 60))
    }
}

@Observable
@MainActor
final class WatchSetupModel {
    var name: String
    var trigger = Preferences.shared.watchTrigger
    var keyword = ""
    var useRegex = false
    var interval = Preferences.shared.watchInterval
    var currentText = ""
    var reading = true

    init(name: String) { self.name = name }

    var canStart: Bool {
        !trigger.needsKeyword || (!keyword.trimmingCharacters(in: .whitespaces).isEmpty
            && ChangeDetector(keyword: keyword, useRegex: useRegex).keywordIsValid)
    }
}

struct WatchSetupView: View {
    @Bindable var model: WatchSetupModel
    let image: CGImage
    let done: (Bool) -> Void

    private static let intervals: [Double] = [1, 2, 5, 10, 30, 60, 300, 900]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(decorative: image, scale: 2)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 90)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))

            GroupBox {
                ScrollView {
                    Text(model.reading ? "Reading…" : (model.currentText.isEmpty ? "No text found here yet." : model.currentText))
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 54)
            } label: {
                Text("Reads now").font(.caption)
            }

            Form {
                TextField("Name", text: $model.name)
                Picker("Alert me on", selection: $model.trigger) {
                    ForEach(WatchTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.trigger.needsKeyword {
                    TextField("Text", text: $model.keyword, prompt: Text("e.g. Ready, Sold out, Error"))
                    Toggle("Regular expression", isOn: $model.useRegex)
                    if !ChangeDetector(keyword: model.keyword, useRegex: model.useRegex).keywordIsValid {
                        Text("That isn't a valid regular expression.").font(.caption).foregroundStyle(.red)
                    }
                }
                Picker("Check every", selection: $model.interval) {
                    ForEach(Self.intervals, id: \.self) { Text(WatchManager.format($0)).tag($0) }
                }
            }
            .formStyle(.columns)

            HStack {
                Text("You'll get a notification when it fires.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction)
                Button("Start Watching") { done(true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart)
            }
        }
        .padding(18)
        .padding(.top, 14)
        .frame(width: 420)
    }
}
