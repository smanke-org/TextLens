import AppKit
import CryptoKit
import Foundation
import Observation
import TextLensKit

/// Keeps settings in step across the Macs on one iCloud account, through the Settings
/// record in CloudKit (see `CloudSync`). Whole-document, last-writer-wins: each change
/// replaces the record, and a newer one written by another Mac replaces this Mac's settings.
///
/// End-to-end encrypted: every record TextLens puts in iCloud is sealed with AES-256-GCM
/// under a random data key. iCloud holds that key only wrapped by the sync passphrase (the
/// Keyring record, see `SyncCrypto`); each Mac keeps the unwrapped key in its login
/// keychain. Until this Mac has the key, the sync engine doesn't run.
///
/// 1.0.8 and 1.0.9 synced through files in iCloud Drive instead. The GitHub build (not
/// sandboxed) still reads that keyring once, so a Mac moves over without the passphrase,
/// and removes the old files two weeks later. Left on each Mac: open at login.
@Observable
@MainActor
final class SettingsSync {
    static let shared = SettingsSync()

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            if isEnabled {
                // Turning sync on adopts what other Macs share; this Mac's settings are
                // uploaded only if nothing is there yet.
                localModified = nil
                start()
            } else {
                stop()
                ActivitySync.shared.start()
                HistorySync.shared.start()
            }
        }
    }
    private(set) var lastSynced: Date?
    private(set) var lastSource: String?
    private(set) var lastError: String?

    /// What sync needs before it can run.
    enum KeyState: Equatable {
        /// This Mac holds the key that opens the synced records.
        case ready
        /// Nothing is set up in iCloud yet: choose a passphrase.
        case needsNewPassphrase
        /// Another Mac set up encryption: enter its passphrase.
        case needsPassphrase
        /// Still asking iCloud for the keyring (or it can't be reached).
        case waitingForKeyring
    }
    private(set) var keyState: KeyState = .waitingForKeyring

    /// The data key, once this Mac has it. Read by `ActivitySync`, `HistorySync` and `CloudSync`.
    @ObservationIgnored private(set) var key: SymmetricKey?
    /// The keyring as known in iCloud (or, moving over from iCloud Drive, the legacy one).
    @ObservationIgnored private var keyring: SyncCrypto.Keyring?
    /// The keyring to save in iCloud on the next send (a changed passphrase).
    @ObservationIgnored private(set) var keyringForUpload: SyncCrypto.Keyring?

    /// When settings last changed on this Mac, or were adopted from iCloud.
    private var localModified: Date? {
        get { defaults.object(forKey: Keys.localModified) as? Date }
        set { defaults.set(newValue, forKey: Keys.localModified) }
    }

    private let defaults = AppDefaults.store
    private var applying = false
    private var checking = false
    /// Whether the Settings record came down since the engine last started.
    private var settingsSeenThisRun = false
    private var retryTimer: Timer?

    private enum Keys {
        static let enabled = "sync.enabled"
        static let localModified = "sync.localModified"
        static let legacyMovedAt = "sync.legacyMovedAt"
    }

    /// Settings that follow the user between Macs.
    static var syncedKeys: [String] {
        Preferences.keys + ["showInDock", "showInMenuBar", UpdatePolicy.key,
         UpdateInterval.valueKey, UpdateInterval.unitKey]
    }

    var isReady: Bool { isEnabled && keyState == .ready && key != nil }

    /// Must not touch Preferences: its initializer can report changes here.
    private init() {
        isEnabled = defaults.bool(forKey: Keys.enabled)
        key = SyncKeychain.loadKey()
    }

    // MARK: - Lifecycle

    /// On a brand-new install, sync data already in iCloud means this user has TextLens on
    /// another Mac: turn sync on (it then asks for the passphrase) rather than starting from
    /// the defaults.
    func adoptOnNewInstall() {
        guard !isEnabled else { return }
        Task {
            let found = (try? await CloudSync.shared.fetchKeyring()) != nil || LegacySync.keyring() != nil
            guard found, !isEnabled else { return }
            NSLog("TextLens: new install found sync data in iCloud; turning sync on")
            isEnabled = true
        }
    }

    func start() {
        guard isEnabled, !checking else { return }
        checking = true
        lastError = nil
        Task {
            await refreshKeyState()
            checking = false
            if keyState == .ready, let key {
                retryTimer?.invalidate()
                retryTimer = nil
                CloudSync.shared.startEngine(keyID: SyncCrypto.keyID(for: key))
                afterEngineStart()
            } else if retryTimer == nil {
                // Look again now and then: iCloud may come back, or another Mac may finish
                // setting up.
                retryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let sync = SettingsSync.shared
                        if sync.isEnabled, !CloudSync.shared.isRunning { sync.start() } else { sync.retryTimer?.invalidate(); sync.retryTimer = nil }
                    }
                }
            }
        }
    }

    private func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        CloudSync.shared.stopEngine()
        lastError = nil
    }

    func syncNow() {
        guard isEnabled else { return }
        if CloudSync.shared.isRunning { CloudSync.shared.fetchNow(); CloudSync.shared.sendNow() } else { start() }
    }

    /// Called whenever a synced setting really changes on this Mac.
    func localDidChange() {
        guard !applying else { return }
        localModified = Self.now
        if CloudSync.shared.isRunning { CloudSync.shared.queueSave([CloudSync.Name.settings]) }
    }

    private func afterEngineStart() {
        // If nothing came down from iCloud, this Mac's settings become the shared copy.
        settingsSeenThisRun = false
        CloudSync.shared.afterFirstFetch { [weak self] in
            guard let self, !self.settingsSeenThisRun, !CloudSync.shared.knowsServerRecord(CloudSync.Name.settings) else { return }
            CloudSync.shared.queueSave([CloudSync.Name.settings])
        }
        LegacySync.cleanUpIfDue(movedAt: defaults.object(forKey: Keys.legacyMovedAt) as? Date) { [defaults] in
            defaults.set(Date(), forKey: Keys.legacyMovedAt)
        }
    }

    // MARK: - Passphrase and key

    /// Works out whether this Mac's key opens what's in iCloud.
    private func refreshKeyState() async {
        if let problem = await CloudSync.shared.accountProblem() {
            lastError = problem
            keyState = .waitingForKeyring
            return
        }
        let remote: SyncCrypto.Keyring?
        do {
            remote = try await CloudSync.shared.fetchKeyring()
        } catch {
            lastError = "Couldn't reach iCloud: \(error.localizedDescription)"
            keyState = .waitingForKeyring
            return
        }
        lastError = nil
        if let remote {
            keyring = remote
            if let key, SyncCrypto.keyID(for: key) == remote.keyID {
                keyState = .ready
            } else {
                // No key yet, or another Mac started over with a new passphrase.
                if key != nil { forgetKey() }
                keyState = .needsPassphrase
            }
            return
        }
        // Nothing in CloudKit. Moving over from iCloud Drive (1.0.8 and 1.0.9)?
        DebugLog.write("no CloudKit keyring")
        if let legacy = LegacySync.keyring() {
            keyring = legacy
            if let key, SyncCrypto.keyID(for: key) == legacy.keyID {
                // Same key and passphrase: bring the keyring across, no questions asked.
                do {
                    try await CloudSync.shared.saveKeyring(legacy, replacing: false)
                    defaults.set(Date(), forKey: Keys.legacyMovedAt)
                    NSLog("TextLens: moved the sync keyring from iCloud Drive to CloudKit")
                    keyState = .ready
                } catch SyncError.alreadySetUp {
                    return await refreshKeyState()
                } catch {
                    lastError = "Couldn't reach iCloud: \(error.localizedDescription)"
                    keyState = .waitingForKeyring
                }
            } else {
                keyState = .needsPassphrase
            }
            return
        }
        keyring = nil
        if key != nil { forgetKey() }
        keyState = .needsNewPassphrase
    }

    /// Sets up encryption with a new passphrase: a fresh key, wrapped into the keyring.
    /// `replacing` starts over, removing everything sealed with the old key.
    func createPassphrase(_ passphrase: String, replacing: Bool = false) async throws {
        let (newKeyring, newKey) = try await Task.detached { try SyncCrypto.createKeyring(passphrase: passphrase) }.value
        do {
            try await CloudSync.shared.saveKeyring(newKeyring, replacing: replacing)
        } catch SyncError.alreadySetUp {
            // Another Mac set up encryption meanwhile: join it instead.
            await refreshKeyState()
            throw SyncError.alreadySetUp
        }
        keyring = newKeyring
        // This Mac's settings become the shared copy.
        localModified = localModified ?? Self.now
        adopt(newKey)
        NSLog("TextLens: set up encrypted sync (key \(newKeyring.keyID))")
    }

    /// Unlocks the key another Mac set up. Throws `SyncCrypto.CryptoError.wrongPassphrase`.
    func enterPassphrase(_ passphrase: String) async throws {
        if keyring == nil { await refreshKeyState() }
        guard let keyring else { throw SyncError.noKeyring }
        let unlocked = try await Task.detached { try SyncCrypto.unwrap(keyring, passphrase: passphrase) }.value
        if (try? await CloudSync.shared.fetchKeyring()) == nil {
            // The legacy iCloud Drive keyring: CloudKit gets it now.
            try await CloudSync.shared.saveKeyring(keyring, replacing: false)
            defaults.set(Date(), forKey: Keys.legacyMovedAt)
        }
        // Adopt what the other Macs share rather than overwriting it.
        localModified = nil
        adopt(unlocked)
    }

    /// Rewraps the same key with a new passphrase, so other Macs keep working.
    func changePassphrase(_ passphrase: String) async throws {
        guard let key else { throw SyncError.noKeyring }
        let rewrapped = try await Task.detached { try SyncCrypto.wrap(key, passphrase: passphrase) }.value
        try await CloudSync.shared.saveKeyring(rewrapped, replacing: false)
        keyring = rewrapped
    }

    private func adopt(_ newKey: SymmetricKey) {
        key = newKey
        SyncKeychain.saveKey(newKey)
        keyState = .ready
        lastError = nil
        CloudSync.shared.stopEngine()
        CloudSync.shared.startEngine(keyID: SyncCrypto.keyID(for: newKey))
        afterEngineStart()
    }

    private func forgetKey() {
        key = nil
        SyncKeychain.deleteKey()
    }

    enum SyncError: LocalizedError {
        case noKeyring, alreadySetUp
        var errorDescription: String? {
            switch self {
            case .noKeyring: "The sync keyring isn't in iCloud yet. Try again in a moment."
            case .alreadySetUp: "Another Mac has just set up encrypted sync. Enter the passphrase you chose there."
            }
        }
    }

    // MARK: - From CloudSync

    /// The keyring record arrived or changed. A different key means another Mac started over.
    func receivedKeyring(_ incoming: SyncCrypto.Keyring) {
        keyring = incoming
        guard let key, SyncCrypto.keyID(for: key) != incoming.keyID else { return }
        NSLog("TextLens: the sync key changed on another Mac")
        CloudSync.shared.resetEngine()
        forgetKey()
        keyState = .needsPassphrase
    }

    /// Checks the keyring in iCloud still matches this Mac's key.
    func verifyKeyring() {
        Task {
            do {
                if let remote = try await CloudSync.shared.fetchKeyring() {
                    receivedKeyring(remote)
                } else {
                    keyringChangedElsewhere()
                }
            } catch {
                DebugLog.write("verifyKeyring: \(error)")
            }
        }
    }

    /// The zone or keyring went away: someone started over or deleted the synced data.
    func keyringChangedElsewhere() {
        CloudSync.shared.stopEngine()
        start()
    }

    /// Signed out of iCloud, or into another account.
    func accountChanged() {
        forgetKey()
        keyring = nil
        keyState = .waitingForKeyring
        start()
    }

    /// The Settings record arrived from iCloud (or won a conflict with this Mac's save).
    func receivedSettings(_ sealed: Data, conflict: Bool = false) {
        guard let key, let remote = Self.document(from: sealed, key: key) else {
            lastError = "The settings in iCloud couldn't be opened with this Mac's key."
            return
        }
        settingsSeenThisRun = true
        if let local = localModified, local > remote.updatedAt {
            CloudSync.shared.queueSave([CloudSync.Name.settings])
        } else if localModified == nil || remote.updatedAt > localModified! {
            apply(remote)
        } else {
            // The same settings: nothing to do.
            noteSynced(remote)
        }
    }

    /// The Settings record's contents: the whole set, defaults included (see Preferences.snapshot).
    func sealedSettings(using key: SymmetricKey) -> Data? {
        let updatedAt = localModified ?? Self.now
        var settings = Preferences.shared.snapshot.filter { Self.syncedKeys.contains($0.key) }
        settings["showInDock"] = AppPresence.showInDock
        settings["showInMenuBar"] = AppPresence.showInMenuBar
        settings[UpdatePolicy.key] = UpdatePolicy.current.rawValue
        settings[UpdateInterval.valueKey] = UpdateInterval.current.value
        settings[UpdateInterval.unitKey] = UpdateInterval.current.unit.rawValue
        let plist: [String: Any] = ["version": 3, "updatedAt": updatedAt, "updatedBy": Self.deviceName, "settings": settings]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0),
              let sealed = try? SyncCrypto.seal(data, using: key) else { return nil }
        if localModified == nil { localModified = updatedAt }
        noteSynced(Document(updatedAt: updatedAt, updatedBy: Self.deviceName, settings: settings))
        return sealed
    }

    // MARK: - Applying

    private struct Document {
        var updatedAt: Date
        var updatedBy: String
        var settings: [String: Any]
    }

    private static func document(from sealed: Data, key: SymmetricKey) -> Document? {
        guard let data = try? SyncCrypto.open(sealed, using: key),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let updatedAt = plist["updatedAt"] as? Date,
              let settings = plist["settings"] as? [String: Any] else { return nil }
        return Document(updatedAt: updatedAt, updatedBy: plist["updatedBy"] as? String ?? "another Mac", settings: settings)
    }

    private func apply(_ remote: Document) {
        applying = true
        defer { applying = false }
        // Only what the record holds; a missing setting keeps this Mac's value.
        for key in Self.syncedKeys {
            if let value = remote.settings[key] { defaults.set(value, forKey: key) }
        }
        Preferences.shared.reload()
        AutoUpdater.shared.policy = UpdatePolicy.current
        AutoUpdater.shared.interval = UpdateInterval.current
        HotKeyCenter.shared.apply()
        PresenceSettings.shared.reload()
        localModified = remote.updatedAt
        noteSynced(remote)
        NSLog("TextLens: adopted settings from \(remote.updatedBy) (\(remote.updatedAt))")
    }

    private func noteSynced(_ document: Document) {
        lastSynced = Date()
        lastSource = document.updatedBy
        lastError = nil
    }

    /// Whole seconds, so a date read back compares equal to the one written.
    private static var now: Date {
        Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
    }

    static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}

/// Sync through iCloud Drive files, as 1.0.8 and 1.0.9 did: only read to move over, then
/// removed. The App Store build is sandboxed and can't see iCloud Drive, so it starts fresh.
enum LegacySync {
    nonisolated static var folder: URL {
        if let override = ProcessInfo.processInfo.environment["TEXTLENS_SYNC_FOLDER"] {
            return URL(fileURLWithPath: override).appending(path: "TextLens")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs/TextLens")
    }

    /// The iCloud Drive keyring, if there is one.
    @MainActor static func keyring() -> SyncCrypto.Keyring? {
        #if APPSTORE
        return nil
        #else
        let url = folder.appending(path: "Keyring.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Evicted to save space: ask for it back for next time.
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        var keyring: SyncCrypto.Keyring?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            if let data = try? Data(contentsOf: target) {
                keyring = try? CloudSync.keyringDecoder.decode(SyncCrypto.Keyring.self, from: data)
            }
        }
        return keyring
        #endif
    }

    /// Two weeks after a Mac moved to CloudKit (time for the others to update), the old
    /// iCloud Drive folder goes.
    static func cleanUpIfDue(movedAt: Date?, markMoved: () -> Void) {
        #if !APPSTORE
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        DebugLog.write("legacy cleanup check, moved \(String(describing: movedAt))")
        guard let movedAt else { return markMoved() }
        guard Date().timeIntervalSince(movedAt) > 14 * 86_400 else { return }
        let target = folder
        DispatchQueue.global(qos: .utility).async {
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: target, options: .forDeleting, error: &coordinationError) { url in
                try? FileManager.default.removeItem(at: url)
            }
            NSLog("TextLens: removed the old iCloud Drive sync folder")
        }
        #endif
    }
}

/// The sync data key, kept in this Mac's login keychain.
enum SyncKeychain {
    static let service = "com.smanke.TextLens.sync"
    /// A test copy with its own defaults keeps its key apart from the real one.
    static let account: String = AppDefaults.suiteName.map { "data-key-test-\($0)" } ?? "data-key"

    static func saveKey(_ key: SymmetricKey) {
        deleteKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "TextLens sync key",
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { NSLog("TextLens: couldn't save the sync key (\(status))") }
    }

    static func loadKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func deleteKey() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

#if DEBUG
/// Debug builds only, for testing sync between scratch copies without typing:
/// `TEXTLENS_DEBUG_SYNC=create:<pass>|enter:<pass>|change:<pass>|startover:<pass>` runs once
/// after launch, and the sync state is written to `debug.sync*` defaults every two seconds.
enum SyncDebugHook {
    @MainActor static func run() {
        let sync = SettingsSync.shared
        if let command = ProcessInfo.processInfo.environment["TEXTLENS_DEBUG_SYNC"], let colon = command.firstIndex(of: ":") {
            let verb = String(command[..<colon]), pass = String(command[command.index(after: colon)...])
            Task {
                try? await Task.sleep(for: .seconds(1))
                do {
                    switch verb {
                    case "create": try await sync.createPassphrase(pass)
                    case "enter": try await sync.enterPassphrase(pass)
                    case "change": try await sync.changePassphrase(pass)
                    case "startover": try await sync.createPassphrase(pass, replacing: true)
                    default: break
                    }
                    AppDefaults.store.set("ok", forKey: "debug.syncCommand")
                } catch {
                    AppDefaults.store.set("error: \(error.localizedDescription)", forKey: "debug.syncCommand")
                }
            }
        }
        // `TEXTLENS_DEBUG_HISTORY=add:<text>|pin-first|delete-first`, a few seconds after launch.
        if let command = ProcessInfo.processInfo.environment["TEXTLENS_DEBUG_HISTORY"], !command.isEmpty {
            Task {
                try? await Task.sleep(for: .seconds(3))
                let store = HistoryStore.shared
                if command.hasPrefix("add:") {
                    let image = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
                    store.add(kind: .text, text: String(command.dropFirst(4)), app: SourceApp(name: "DebugHook", bundleID: nil), image: image)
                } else if command == "pin-first", let first = store.entries.first {
                    store.togglePin(first.id)
                } else if command == "delete-first", let first = store.entries.first {
                    store.delete([first.id])
                } else if command.hasPrefix("words:") {
                    Preferences.shared.customWords = String(command.dropFirst(6))
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let d = AppDefaults.store
                let store = HistoryStore.shared
                d.set(store.entries.count, forKey: "debug.historyCount")
                d.set(store.entries.filter(\.pinned).count, forKey: "debug.historyPinned")
                d.set(store.entries.filter { store.image(for: $0) != nil }.count, forKey: "debug.historyImages")
                d.set(store.entries.first.map { HistoryQuery.snippet($0.text, limit: 40) } ?? "", forKey: "debug.historyFirst")
                d.set(HistorySync.shared.pendingUploads, forKey: "debug.historyPending")
                d.set(HistorySync.shared.lastError ?? "", forKey: "debug.historyError")
                if let q = ProcessInfo.processInfo.environment["TEXTLENS_DEBUG_SEARCH"] {
                    d.set(store.search(q, kind: nil).count, forKey: "debug.historySearchCount")
                }
                d.set("\(sync.keyState)", forKey: "debug.syncKeyState")
                d.set(sync.lastError ?? "", forKey: "debug.syncError")
                d.set(sync.lastSource ?? "", forKey: "debug.syncSource")
                d.set(ActivitySync.shared.activeRemotes.count, forKey: "debug.syncRemotes")
            }
        }
    }
}
#endif
