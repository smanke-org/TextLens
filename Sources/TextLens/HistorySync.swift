import AppKit
import CryptoKit
import Foundation
import Observation
import TextLensKit

/// Syncs the capture history between Macs through iCloud Drive, end-to-end encrypted with
/// the same key as the settings (see `SettingsSync`).
///
/// Each capture is one file, `iCloud Drive/TextLens/History/<entry id>.tlsync`: the entry
/// and its picture, sealed. A deletion replaces the file with a sealed tombstone, so a Mac
/// that was offline learns of it too. Newest change wins, per entry; a tombstone wins a
/// tie. Tombstones are removed after 90 days.
///
/// Runs while settings sync is unlocked and both History and "Sync history" are on.
@Observable
@MainActor
final class HistorySync {
    static let shared = HistorySync()

    private(set) var lastSynced: Date?
    private(set) var lastError: String?
    /// Captures waiting to go up, for Settings.
    private(set) var pendingUploads = 0

    @ObservationIgnored private var started = false
    @ObservationIgnored private var observingWake = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private let queue = DispatchQueue(label: "com.smanke.TextLens.historysync", qos: .utility)

    private static let tombstoneLifetime: TimeInterval = 90 * 86_400

    private enum Keys {
        static let outbox = "historySync.outbox"
        /// The key ID this Mac last uploaded its whole history under.
        static let uploadedFor = "historySync.uploadedForKey"
    }

    nonisolated static var folder: URL { SettingsSync.folder.appending(path: "History") }

    var isActive: Bool {
        SettingsSync.shared.isReady && Preferences.shared.historyEnabled && Preferences.shared.historySync
    }

    private var db: HistoryDatabase? { HistoryStore.shared.db }

    // MARK: - Lifecycle

    /// At launch, and whenever sync, the key or the History settings change.
    func start() {
        guard isActive, let key = SettingsSync.shared.key, let db else {
            stop()
            return
        }
        // Everything this Mac has goes up once per key: on first sync, and after starting over.
        let keyID = SyncCrypto.keyID(for: key)
        if db.string(forKey: Keys.uploadedFor) != keyID {
            var outbox = loadOutbox()
            outbox.formUnion(HistoryStore.shared.entries.map(\.id))
            outbox.formUnion(db.tombstones().map(\.0))
            saveOutbox(outbox)
            try? db.forgetSeenFiles()
            try? db.set(keyID, forKey: Keys.uploadedFor)
        }
        pendingUploads = loadOutbox().count
        guard !started else {
            scheduleFlush(after: 0.5)
            scan()
            return
        }
        started = true
        lastError = nil
        scheduleFlush(after: 0.5)
        scan()
        // Other Macs' captures arrive in the background; look for them now and then.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { HistorySync.shared.scan() }
        }
        guard !observingWake else { return }
        observingWake = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HistorySync.shared.scan() }
        }
    }

    private func stop() {
        guard started else { return }
        started = false
        timer?.invalidate()
        timer = nil
        flushTask?.cancel()
        flushTask = nil
    }

    /// Entries added, changed or deleted on this Mac.
    func localDidChange(_ ids: Set<UUID>) {
        guard let db else { return }
        // Queued even while sync is off or locked, so nothing is lost; `start` sends them.
        guard isActive || db.string(forKey: Keys.uploadedFor) != nil else { return }
        var outbox = loadOutbox()
        outbox.formUnion(ids)
        saveOutbox(outbox)
        pendingUploads = outbox.count
        if started { scheduleFlush(after: 2) }
    }

    func syncNow() {
        guard started else { return start() }
        scheduleFlush(after: 0)
        scan()
    }

    // MARK: - Uploading

    private func loadOutbox() -> Set<UUID> {
        guard let data = db?.data(forKey: Keys.outbox), let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(ids)
    }

    private func saveOutbox(_ ids: Set<UUID>) {
        try? db?.set(ids.isEmpty ? nil : try? JSONEncoder().encode(Array(ids)), forKey: Keys.outbox)
    }

    private func scheduleFlush(after seconds: Double) {
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    /// Writes each waiting entry (or its tombstone) as a sealed file, off the main thread.
    private func flush() {
        guard started, let key = SettingsSync.shared.key, let db else { return }
        let outbox = loadOutbox()
        guard !outbox.isEmpty else { return }
        let folder = Self.folder
        queue.async {
            var written: [String: Date?] = [:]
            var done = Set<UUID>()
            var failure: String?
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                failure = error.localizedDescription
            }
            for id in outbox where failure == nil {
                let capture: SyncedCapture
                if let entry = db.entry(id) {
                    capture = SyncedCapture(entry: entry, png: entry.thumbnail == nil ? nil : db.image(id))
                } else if let at = db.tombstone(id) {
                    capture = SyncedCapture(deleted: id, at: at)
                } else {
                    done.insert(id)
                    continue
                }
                let url = folder.appending(path: "\(id.uuidString).tlsync")
                do {
                    let sealed = try SyncCrypto.seal(capture.encoded(), using: key)
                    var coordinationError: NSError?
                    var writeError: Error?
                    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                        do { try sealed.write(to: target, options: .atomic) } catch { writeError = error }
                    }
                    if let error = coordinationError ?? writeError { throw error }
                    // So the next scan doesn't read back what this Mac just wrote.
                    written[url.lastPathComponent] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    done.insert(id)
                } catch {
                    failure = error.localizedDescription
                }
            }
            try? db.setSeen(written)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HistorySync.shared.finishedFlush(done, failure: failure) }
            }
        }
    }

    private func finishedFlush(_ done: Set<UUID>, failure: String?) {
        // Changes made while the files were being written stay queued.
        var outbox = loadOutbox()
        outbox.subtract(done)
        saveOutbox(outbox)
        pendingUploads = outbox.count
        if let failure {
            lastError = "History couldn't be saved to iCloud Drive: \(failure)"
            scheduleFlush(after: 60)
        } else {
            lastError = nil
            lastSynced = Date()
            if !outbox.isEmpty { scheduleFlush(after: 2) }
        }
    }

    // MARK: - Downloading

    /// Reads the files that changed since the last look, off the main thread.
    func scan() {
        guard started, !scanning, let key = SettingsSync.shared.key, let db else { return }
        scanning = true
        let folder = Self.folder
        let outbox = loadOutbox()
        queue.async {
            let fm = FileManager.default
            let seen = db.seenFiles()
            var changed: [(url: URL, mtime: Date)] = []
            var present = Set<String>()
            let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names {
                // iCloud Drive can evict a file, leaving ".<name>.icloud": ask for it back.
                if name.hasPrefix("."), name.hasSuffix(".tlsync.icloud") {
                    let real = String(name.dropFirst().dropLast(".icloud".count))
                    try? fm.startDownloadingUbiquitousItem(at: folder.appending(path: real))
                    present.insert(real)
                    continue
                }
                guard name.hasSuffix(".tlsync"), !name.hasPrefix(".") else { continue }
                present.insert(name)
                let url = folder.appending(path: name)
                guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                if seen[name] != mtime { changed.append((url, mtime)) }
            }

            var updates: [(HistoryEntry, png: Data?)] = []
            var deletions: [(UUID, Date)] = []
            var seenNow: [String: Date?] = [:]
            var expired: [URL] = []
            var rewrite = Set<UUID>()
            for (url, mtime) in changed {
                guard let (capture, conflictWon) = Self.read(url, key: key) else {
                    // Sealed with another key (from before someone started over) or still
                    // arriving: look again next time.
                    continue
                }
                seenNow[url.lastPathComponent] = mtime
                // The current file lost a conflict: write the winner back for the other Macs.
                if conflictWon { rewrite.insert(capture.id) }
                // A change still waiting to go up from this Mac is newer than anything here.
                if outbox.contains(capture.id) { continue }
                let local = db.entry(capture.id)
                let localTomb = db.tombstone(capture.id)
                let localDate = local?.lastModified ?? localTomb
                guard SyncedCapture.wins(capture.modified, incomingIsDeletion: capture.isDeletion,
                                         over: localDate, localIsDeletion: local == nil && localTomb != nil) else {
                    if capture.isDeletion, Date().timeIntervalSince(capture.modified) > Self.tombstoneLifetime { expired.append(url) }
                    continue
                }
                if let entry = capture.entry {
                    updates.append((entry, png: capture.png))
                } else if local != nil {
                    deletions.append((capture.id, capture.modified))
                } else if localTomb == nil {
                    // Never had it; remember the deletion so an old copy can't revive it.
                    deletions.append((capture.id, capture.modified))
                }
                if capture.isDeletion, Date().timeIntervalSince(capture.modified) > Self.tombstoneLifetime { expired.append(url) }
            }
            // Old tombstones go, in iCloud and here.
            for url in expired {
                SettingsSync.coordinatedDelete(url)
                seenNow[url.lastPathComponent] = .some(nil)
            }
            let cutoff = Date().addingTimeInterval(-Self.tombstoneLifetime)
            for (id, at) in db.tombstones() where at < cutoff && !present.contains("\(id.uuidString).tlsync") {
                try? db.removeTombstone(id)
            }
            // Files that disappeared (an expired tombstone removed elsewhere) are forgotten.
            for name in seen.keys where !present.contains(name) { seenNow[name] = .some(nil) }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    HistorySync.shared.finishedScan(updates: updates, deletions: deletions, seen: seenNow, rewrite: rewrite)
                }
            }
        }
    }

    private func finishedScan(updates: [(HistoryEntry, png: Data?)], deletions: [(UUID, Date)], seen: [String: Date?], rewrite: Set<UUID>) {
        scanning = false
        HistoryStore.shared.applyRemote(updates)
        HistoryStore.shared.applyRemoteDeletions(deletions)
        try? db?.setSeen(seen)
        if !rewrite.isEmpty { localDidChange(rewrite) }
        if !updates.isEmpty || !deletions.isEmpty {
            NSLog("TextLens: history sync brought \(updates.count) change(s) and \(deletions.count) deletion(s)")
        }
        if lastError == nil { lastSynced = Date() }
    }

    /// Opens one synced file. Where iCloud kept conflicting versions, the newest change wins
    /// and the others are discarded.
    nonisolated private static func read(_ url: URL, key: SymmetricKey) -> (SyncedCapture, conflictWon: Bool)? {
        var best: SyncedCapture?
        var conflictWon = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            if let data = try? Data(contentsOf: target) { best = open(data, key: key) }
        }
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !conflicts.isEmpty else { return best.map { ($0, false) } }
        for version in conflicts {
            if let data = try? Data(contentsOf: version.url), let other = open(data, key: key),
               best.map({ SyncedCapture.wins(other.modified, incomingIsDeletion: other.isDeletion, over: $0.modified, localIsDeletion: $0.isDeletion) }) ?? true {
                best = other
                conflictWon = true
            }
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        return best.map { ($0, conflictWon) }
    }

    nonisolated private static func open(_ data: Data, key: SymmetricKey) -> SyncedCapture? {
        guard let plain = try? SyncCrypto.open(data, using: key) else { return nil }
        return try? SyncedCapture.decode(plain)
    }
}
