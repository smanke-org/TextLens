import AppKit
import CryptoKit
import Foundation
import Observation
import TextLensKit

/// Syncs the capture history between Macs through CloudKit, end-to-end encrypted with the
/// same key as the settings (see `SettingsSync`, `CloudSync`).
///
/// Each capture is one record, `Capture_<entry id>`, whose asset holds the entry and its
/// picture, sealed. Deleting a capture deletes its record, and CloudKit tells every Mac.
/// Newest change wins, per entry.
///
/// Runs while settings sync is unlocked and both History and "Sync history" are on. Changes
/// made while it isn't running wait in an outbox.
@Observable
@MainActor
final class HistorySync {
    static let shared = HistorySync()

    private(set) var lastSynced: Date?
    var lastError: String? { CloudSync.shared.lastError }
    /// Captures waiting to go up, for Settings.
    var pendingUploads: Int { CloudSync.shared.pendingCaptures + (started ? 0 : loadOutbox().count) }

    @ObservationIgnored private var started = false

    private static let tombstoneLifetime: TimeInterval = 90 * 86_400

    private enum Keys {
        static let outbox = "historySync.outbox"
        /// The key ID this Mac last uploaded its whole history to CloudKit under.
        static let uploadedFor = "ck.historyUploadedForKey"
    }

    var isActive: Bool {
        SettingsSync.shared.isReady && Preferences.shared.historyEnabled && Preferences.shared.historySync
    }

    private var db: HistoryDatabase? { HistoryStore.shared.db }

    // MARK: - Lifecycle

    /// When the sync engine starts, and whenever sync, the key or the History settings change.
    func start() {
        guard isActive, CloudSync.shared.isRunning, let key = SettingsSync.shared.key, let db else {
            started = false
            return
        }
        started = true
        // What changed while sync wasn't running.
        let outbox = loadOutbox()
        if !outbox.isEmpty {
            send(outbox)
            saveOutbox([])
        }
        // Everything this Mac has goes up once per key (first sync, after starting over,
        // after moving from iCloud Drive), once what's already in iCloud has come down.
        let keyID = SyncCrypto.keyID(for: key)
        if db.string(forKey: Keys.uploadedFor) != keyID {
            CloudSync.shared.afterFirstFetch { [weak self] in
                guard let self, self.started, let db = self.db else { return }
                CloudSync.shared.queueSave(HistoryStore.shared.entries.map { CloudSync.Name.capture($0.id) })
                try? db.set(keyID, forKey: Keys.uploadedFor)
                NSLog("TextLens: uploading \(HistoryStore.shared.entries.count) history entries")
            }
        }
        // Deletions are told by CloudKit now; old local tombstones only guard against stale copies.
        let cutoff = Date().addingTimeInterval(-Self.tombstoneLifetime)
        for (id, at) in db.tombstones() where at < cutoff { try? db.removeTombstone(id) }
    }

    /// Entries added, changed or deleted on this Mac.
    func localDidChange(_ ids: Set<UUID>) {
        if started {
            send(ids)
        } else if SettingsSync.shared.isEnabled && Preferences.shared.historySync {
            // Kept until sync runs again (locked, offline at launch).
            var outbox = loadOutbox()
            outbox.formUnion(ids)
            saveOutbox(outbox)
        }
    }

    private func send(_ ids: Set<UUID>) {
        let store = HistoryStore.shared
        let existing = Set(store.entries.map(\.id))
        CloudSync.shared.queueSave(ids.filter { existing.contains($0) }.map(CloudSync.Name.capture))
        CloudSync.shared.queueDelete(ids.filter { !existing.contains($0) }.map(CloudSync.Name.capture))
    }

    func syncNow() {
        guard started else { return SettingsSync.shared.syncNow() }
        CloudSync.shared.fetchNow()
        CloudSync.shared.sendNow()
    }

    /// Looks for other Macs' changes (opening History, for instance).
    func scan() {
        guard started else { return }
        CloudSync.shared.fetchNow()
    }

    func didSync() {
        if started { lastSynced = Date() }
    }

    private func loadOutbox() -> Set<UUID> {
        guard let data = db?.data(forKey: Keys.outbox), let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(ids)
    }

    private func saveOutbox(_ ids: Set<UUID>) {
        try? db?.set(ids.isEmpty ? nil : try? JSONEncoder().encode(Array(ids)), forKey: Keys.outbox)
    }

    // MARK: - From CloudSync

    /// One entry and its picture, sealed, for its record; nil if it's gone.
    func sealedCapture(_ id: UUID, using key: SymmetricKey) -> Data? {
        guard let db, let entry = db.entry(id) else { return nil }
        let capture = SyncedCapture(entry: entry, png: entry.thumbnail == nil ? nil : db.image(id))
        return try? SyncCrypto.seal(capture.encoded(), using: key)
    }

    /// Records that arrived from iCloud: (record name, sealed payload). `conflict` means this
    /// Mac's save lost a race; the newer of the two wins and the loser is sent again if it
    /// was this Mac's.
    func received(_ records: [(String, Data)], conflict: Bool = false) {
        guard started || conflict, let key = SettingsSync.shared.key, let db else { return }
        var updates: [(HistoryEntry, png: Data?)] = []
        var resend: [String] = []
        for (name, sealed) in records {
            guard let plain = try? SyncCrypto.open(sealed, using: key),
                  let capture = try? SyncedCapture.decode(plain), let entry = capture.entry else { continue }
            let local = db.entry(capture.id)
            let localTomb = db.tombstone(capture.id)
            let localDate = local?.lastModified ?? localTomb
            if SyncedCapture.wins(capture.modified, incomingIsDeletion: false, over: localDate,
                                  localIsDeletion: local == nil && localTomb != nil) {
                updates.append((entry, png: capture.png))
            } else if let localDate, localDate > capture.modified {
                // This Mac's copy is newer (or was deleted later): it goes up again. An equal
                // copy is the same change coming back, and stays put.
                if local != nil { resend.append(name) } else { CloudSync.shared.queueDelete([name]) }
            }
        }
        HistoryStore.shared.applyRemote(updates)
        CloudSync.shared.queueSave(resend)
        if !updates.isEmpty { NSLog("TextLens: history sync brought \(updates.count) change(s)") }
    }

    /// Captures deleted on another Mac.
    func receivedDeletions(_ names: [String]) {
        guard started else { return }
        let ids = names.compactMap { UUID(uuidString: String($0.dropFirst(CloudSync.Name.capturePrefix.count))) }
        let present = Set(HistoryStore.shared.entries.map(\.id))
        let now = Date()
        HistoryStore.shared.applyRemoteDeletions(ids.filter(present.contains).map { ($0, now) })
    }
}
