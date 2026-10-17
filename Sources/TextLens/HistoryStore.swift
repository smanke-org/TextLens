import AppKit
import Observation
import TextLensKit

/// Every capture, saved in Application Support/TextLens/History/History.sqlite: each entry,
/// its picture and a full-text index (see `HistoryDatabase`). With history sync on, entries
/// also travel between Macs, end-to-end encrypted (see `HistorySync`).
///
/// `entries` mirrors the database newest first for the lists; every change writes just the
/// rows it touches.
@Observable
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    private(set) var entries: [HistoryEntry] = []
    @ObservationIgnored private var thumbnailCache: [UUID: NSImage] = [:]
    @ObservationIgnored private(set) var db: HistoryDatabase?

    let folder: URL = {
        if let override = ProcessInfo.processInfo.environment["TEXTLENS_HISTORY_FOLDER"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TextLens/History", directoryHint: .isDirectory)
    }()

    private var databaseURL: URL { folder.appending(path: "History.sqlite") }
    /// Where 1.0.8 and earlier kept history: an index file and a folder of pictures.
    private var legacyIndexURL: URL { folder.appending(path: "history.json") }
    private var legacyImagesFolder: URL { folder.appending(path: "Images", directoryHint: .isDirectory) }

    private init() {
        do {
            let db = try HistoryDatabase(url: databaseURL)
            self.db = db
            importLegacyHistory(into: db)
            entries = db.allEntries()
        } catch {
            NSLog("TextLens: \(error.localizedDescription)")
        }
    }

    // MARK: - Changes made on this Mac

    @discardableResult
    func add(kind: HistoryEntry.Kind, text: String, translation: String? = nil, sourceLanguage: String? = nil,
             targetLanguage: String? = nil, app: SourceApp, image: CGImage?) -> HistoryEntry? {
        let prefs = Preferences.shared
        guard prefs.historyEnabled, !text.isEmpty, let db else { return nil }
        let now = Date()
        var entry = HistoryEntry(date: now, kind: kind, text: text, translation: translation, sourceLanguage: sourceLanguage,
                                 targetLanguage: targetLanguage, appName: app.name, appBundleID: app.bundleID,
                                 modified: now, origin: DeviceIdentity.deviceID)
        let png = prefs.historySaveImages ? image?.thumbnail().pngData : nil
        if png != nil { entry.thumbnail = "\(entry.id.uuidString).png" }
        do {
            try db.upsert(entry, png: png)
        } catch {
            NSLog("TextLens: couldn't save to history: \(error.localizedDescription)")
            return nil
        }
        entries.insert(entry, at: 0)
        HistorySync.shared.localDidChange([entry.id])
        prune()
        return entry
    }

    func update(_ entry: HistoryEntry) {
        var entry = entry
        entry.modified = Date()
        save(entry)
    }

    func togglePin(_ id: UUID) {
        guard var entry = entries.first(where: { $0.id == id }) else { return }
        entry.pinned.toggle()
        entry.modified = Date()
        save(entry)
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty, let db else { return }
        do {
            try db.delete(Array(ids), tombstone: Date())
        } catch {
            NSLog("TextLens: couldn't delete from history: \(error.localizedDescription)")
            return
        }
        for id in ids { thumbnailCache[id] = nil }
        entries.removeAll { ids.contains($0.id) }
        HistorySync.shared.localDidChange(ids)
    }

    func clear(keepPinned: Bool) {
        delete(Set(entries.filter { !keepPinned || !$0.pinned }.map(\.id)))
    }

    /// Applies the size and age limits from Settings. The limits are shared settings, so
    /// what one Mac trims, every Mac would trim; it syncs as a deletion.
    func prune() {
        let prefs = Preferences.shared
        let drop = HistoryQuery.expired(entries, maxCount: prefs.historyMaxCount, maxAgeDays: prefs.historyMaxDays)
        delete(drop)
    }

    private func save(_ entry: HistoryEntry) {
        guard let db, let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        do { try db.upsert(entry) } catch {
            NSLog("TextLens: couldn't save to history: \(error.localizedDescription)")
            return
        }
        entries[index] = entry
        HistorySync.shared.localDidChange([entry.id])
    }

    // MARK: - Changes from other Macs

    /// A newer copy of an entry, or a new one, arrived from another Mac.
    func applyRemote(_ incoming: [(HistoryEntry, png: Data?)]) {
        guard let db, !incoming.isEmpty else { return }
        do { try db.upsert(incoming) } catch {
            NSLog("TextLens: couldn't save synced history: \(error.localizedDescription)")
            return
        }
        var byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (entry, _) in incoming {
            byID[entry.id] = entry
            thumbnailCache[entry.id] = nil
        }
        entries = byID.values.sorted { $0.date > $1.date }
        prune()
    }

    /// Entries deleted on another Mac. The tombstone keeps the other Mac's time, so an
    /// older copy arriving later can't bring the entry back.
    func applyRemoteDeletions(_ deletions: [(UUID, Date)]) {
        guard let db, !deletions.isEmpty else { return }
        let ids = Set(deletions.map(\.0))
        do {
            try db.transaction {
                for (id, at) in deletions { try db.delete([id], tombstone: at) }
            }
        } catch {
            NSLog("TextLens: couldn't apply synced deletions: \(error.localizedDescription)")
            return
        }
        for id in ids { thumbnailCache[id] = nil }
        entries.removeAll { ids.contains($0.id) }
    }

    // MARK: - Reading

    func entry(_ id: UUID) -> HistoryEntry? { entries.first { $0.id == id } }

    /// Entries matching every word of `query`, through the database's index. Pinned on top,
    /// then newest first.
    func search(_ query: String, kind: HistoryEntry.Kind?) -> [HistoryEntry] {
        var results: [HistoryEntry]
        if query.trimmingCharacters(in: .whitespaces).isEmpty || db == nil {
            results = entries
        } else {
            let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            results = db!.search(query).compactMap { byID[$0] }
        }
        if let kind { results = results.filter { $0.kind == kind } }
        return results.sorted { ($0.pinned ? 1 : 0, $0.date) > ($1.pinned ? 1 : 0, $1.date) }
    }

    func image(for entry: HistoryEntry) -> NSImage? {
        if let cached = thumbnailCache[entry.id] { return cached }
        guard entry.thumbnail != nil, let data = db?.image(entry.id), let image = NSImage(data: data) else { return nil }
        thumbnailCache[entry.id] = image
        return image
    }

    // MARK: - From 1.0.8 and earlier

    /// Moves history.json and its pictures into the database once. The old files are kept,
    /// renamed, in case anything goes wrong.
    private func importLegacyHistory(into db: HistoryDatabase) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyIndexURL.path) else { return }
        guard let data = try? Data(contentsOf: legacyIndexURL),
              let legacy = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
            NSLog("TextLens: history.json unreadable; leaving it for inspection")
            try? fm.moveItem(at: legacyIndexURL, to: folder.appending(path: "history-unreadable-\(Int(Date().timeIntervalSince1970)).json"))
            return
        }
        let rows: [(HistoryEntry, png: Data?)] = legacy.map { entry in
            var entry = entry
            let png = entry.thumbnail.flatMap { try? Data(contentsOf: legacyImagesFolder.appending(path: $0)) }
            if png == nil { entry.thumbnail = nil }
            entry.origin = entry.origin ?? DeviceIdentity.deviceID
            return (entry, png: png)
        }
        do {
            try db.upsert(rows)
            try fm.moveItem(at: legacyIndexURL, to: folder.appending(path: "history-before-database.json"))
            if fm.fileExists(atPath: legacyImagesFolder.path) {
                try? fm.moveItem(at: legacyImagesFolder, to: folder.appending(path: "Images-before-database", directoryHint: .isDirectory))
            }
            NSLog("TextLens: moved \(rows.count) history entries into the database")
        } catch {
            NSLog("TextLens: couldn't move history into the database: \(error.localizedDescription)")
        }
    }
}
