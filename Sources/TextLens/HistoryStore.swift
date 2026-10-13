import AppKit
import Observation
import TextLensKit

/// Every capture, saved on this Mac in Application Support/TextLens/History: an index
/// file plus a small picture of each capture. History is never synced through iCloud;
/// it can hold anything that was on screen.
@Observable
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var entries: [HistoryEntry] = []
    @ObservationIgnored private var thumbnailCache: [UUID: NSImage] = [:]

    let folder: URL = {
        if let override = ProcessInfo.processInfo.environment["TEXTLENS_HISTORY_FOLDER"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TextLens/History", directoryHint: .isDirectory)
    }()

    private var indexURL: URL { folder.appending(path: "history.json") }
    private var imagesFolder: URL { folder.appending(path: "Images", directoryHint: .isDirectory) }

    private init() { load() }

    @discardableResult
    func add(kind: HistoryEntry.Kind, text: String, translation: String? = nil, sourceLanguage: String? = nil,
             targetLanguage: String? = nil, app: SourceApp, image: CGImage?) -> HistoryEntry? {
        let prefs = Preferences.shared
        guard prefs.historyEnabled, !text.isEmpty else { return nil }
        var entry = HistoryEntry(kind: kind, text: text, translation: translation, sourceLanguage: sourceLanguage,
                                 targetLanguage: targetLanguage, appName: app.name, appBundleID: app.bundleID)
        if prefs.historySaveImages, let data = image?.thumbnail().pngData {
            let name = "\(entry.id.uuidString).png"
            do {
                try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
                try data.write(to: imagesFolder.appending(path: name), options: .atomic)
                entry.thumbnail = name
            } catch {
                NSLog("TextLens: couldn't save history image: \(error.localizedDescription)")
            }
        }
        entries.insert(entry, at: 0)
        prune()
        save()
        return entry
    }

    func update(_ entry: HistoryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func togglePin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].pinned.toggle()
        save()
    }

    func delete(_ ids: Set<UUID>) {
        for entry in entries where ids.contains(entry.id) { removeImage(entry) }
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func clear(keepPinned: Bool) {
        delete(Set(entries.filter { !keepPinned || !$0.pinned }.map(\.id)))
    }

    /// Applies the size and age limits from Settings.
    func prune() {
        let prefs = Preferences.shared
        let drop = HistoryQuery.expired(entries, maxCount: prefs.historyMaxCount, maxAgeDays: prefs.historyMaxDays)
        guard !drop.isEmpty else { return }
        for entry in entries where drop.contains(entry.id) { removeImage(entry) }
        entries.removeAll { drop.contains($0.id) }
        save()
    }

    func image(for entry: HistoryEntry) -> NSImage? {
        if let cached = thumbnailCache[entry.id] { return cached }
        guard let name = entry.thumbnail, let image = NSImage(contentsOf: imagesFolder.appending(path: name)) else { return nil }
        thumbnailCache[entry.id] = image
        return image
    }

    private func removeImage(_ entry: HistoryEntry) {
        thumbnailCache[entry.id] = nil
        if let name = entry.thumbnail { try? FileManager.default.removeItem(at: imagesFolder.appending(path: name)) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        do {
            entries = try JSONDecoder().decode([HistoryEntry].self, from: data)
        } catch {
            NSLog("TextLens: history index unreadable, starting fresh: \(error.localizedDescription)")
            try? FileManager.default.moveItem(at: indexURL, to: folder.appending(path: "history-unreadable-\(Int(Date().timeIntervalSince1970)).json"))
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .deferredToDate
            try encoder.encode(entries).write(to: indexURL, options: .atomic)
        } catch {
            NSLog("TextLens: couldn't save history: \(error.localizedDescription)")
        }
    }
}
