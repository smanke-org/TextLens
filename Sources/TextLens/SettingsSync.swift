import AppKit
import CryptoKit
import Foundation
import Observation
import TextLensKit

/// Keeps settings in step across the Macs on one iCloud account, through a file in
/// iCloud Drive (`iCloud Drive/TextLens/Settings.tlsync`). Whole-document,
/// last-writer-wins: each change rewrites the file, and a newer file written by another
/// Mac replaces this Mac's settings.
///
/// End-to-end encrypted (1.0.8 and later): every file TextLens puts in iCloud Drive is
/// sealed with AES-256-GCM under a random data key. iCloud holds that key only wrapped by
/// the sync passphrase (`Keyring.json`, see `SyncCrypto`); each Mac keeps the unwrapped key
/// in its login keychain. Until this Mac has the key, nothing is read or written.
///
/// A plain file needs no iCloud entitlement or provisioning profile, which works only
/// because the app is not sandboxed. Left on each Mac: open at login (a per-Mac login
/// item) and the capture history, which can hold anything that was on screen.
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
            }
            ActivitySync.shared.start()
            HistorySync.shared.start()
        }
    }
    private(set) var lastSynced: Date?
    private(set) var lastSource: String?
    private(set) var lastError: String?

    /// What sync needs before it can run.
    enum KeyState: Equatable {
        /// This Mac holds the key that opens the synced files.
        case ready
        /// Nothing is set up in iCloud yet: choose a passphrase.
        case needsNewPassphrase
        /// Another Mac set up encryption: enter its passphrase.
        case needsPassphrase
        /// iCloud Drive hasn't downloaded the keyring yet.
        case waitingForKeyring
    }
    private(set) var keyState: KeyState = .needsNewPassphrase

    /// The data key, once this Mac has it. Read by `ActivitySync` too.
    @ObservationIgnored private(set) var key: SymmetricKey?

    /// When settings last changed on this Mac, or were adopted from iCloud.
    private var localModified: Date? {
        get { defaults.object(forKey: Keys.localModified) as? Date }
        set { defaults.set(newValue, forKey: Keys.localModified) }
    }

    private let defaults = UserDefaults.standard
    private var applying = false
    private var started = false
    private var writeTask: Task<Void, Never>?
    private var timer: Timer?
    private var keyringTimer: Timer?
    private var lastSeenFileDate: Date?

    private enum Keys {
        static let enabled = "sync.enabled"
        static let localModified = "sync.localModified"
    }

    /// Settings that follow the user between Macs.
    static var syncedKeys: [String] {
        Preferences.keys + ["showInDock", "showInMenuBar", UpdatePolicy.key]
    }

    nonisolated static var iCloudDrive: URL {
        if let override = ProcessInfo.processInfo.environment["TEXTLENS_SYNC_FOLDER"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
    }
    nonisolated static var folder: URL { iCloudDrive.appending(path: "TextLens") }
    nonisolated static var file: URL { folder.appending(path: "Settings.tlsync") }
    nonisolated static var keyringFile: URL { folder.appending(path: "Keyring.json") }
    /// Where 1.0.7 and earlier kept settings, unencrypted. Removed once this Mac writes the
    /// encrypted file, and never read.
    nonisolated static var legacyFile: URL { folder.appending(path: "Settings.plist") }

    var iCloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.iCloudDrive.path)
    }

    var isReady: Bool { isEnabled && keyState == .ready && iCloudDriveAvailable }

    /// Must not touch Preferences: its initializer can report changes here.
    private init() {
        isEnabled = defaults.bool(forKey: Keys.enabled)
        key = SyncKeychain.loadKey()
    }

    // MARK: - Lifecycle

    /// On a brand-new install, sync files already in iCloud Drive mean this user has
    /// TextLens on another Mac: turn sync on (it then asks for the passphrase) rather than
    /// starting from the defaults.
    func adoptOnNewInstall() {
        let fm = FileManager.default
        guard !isEnabled, [Self.keyringFile, Self.file, Self.legacyFile].contains(where: { fm.fileExists(atPath: $0.path) })
                || fm.fileExists(atPath: Self.placeholder(for: Self.keyringFile).path) else { return }
        NSLog("TextLens: new install found settings in iCloud Drive; turning sync on")
        isEnabled = true
    }

    func start() {
        guard isEnabled, !started else { return }
        guard iCloudDriveAvailable else {
            lastError = "iCloud Drive isn't turned on for this Mac. Turn it on in System Settings › Apple Account › iCloud."
            return
        }
        lastError = nil
        refreshKeyState()
        guard keyState == .ready else {
            // Look again now and then: the keyring may still be downloading, or another
            // Mac may start over with a new one.
            if keyringTimer == nil {
                keyringTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
                    MainActor.assumeIsolated { SettingsSync.shared.recheckKeyring() }
                }
            }
            return
        }
        keyringTimer?.invalidate()
        keyringTimer = nil
        started = true
        pull()
        // iCloud delivers other Macs' edits in the background; look for them periodically.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { SettingsSync.shared.checkForRemoteChange() }
        }
        ActivitySync.shared.start()
    }

    private func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        keyringTimer?.invalidate()
        keyringTimer = nil
        writeTask?.cancel()
        lastError = nil
    }

    func syncNow() {
        guard isEnabled else { return }
        if !started { start() } else { pull() }
    }

    /// Called whenever a synced setting really changes on this Mac.
    func localDidChange() {
        guard !applying else { return }
        localModified = Self.now
        guard started else { return }
        writeTask?.cancel()
        // Debounced, so dragging a slider writes once rather than for every step.
        writeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            write()
        }
    }

    // MARK: - Passphrase and key

    /// Works out whether this Mac's key still opens what's in iCloud.
    private func refreshKeyState() {
        let fm = FileManager.default
        if let keyring = readKeyring() {
            if let key, SyncCrypto.keyID(for: key) == keyring.keyID {
                keyState = .ready
            } else {
                // No key yet, or another Mac started over with a new passphrase.
                if key != nil { forgetKey() }
                keyState = .needsPassphrase
            }
        } else if fm.fileExists(atPath: Self.placeholder(for: Self.keyringFile).path) {
            try? fm.startDownloadingUbiquitousItem(at: Self.keyringFile)
            keyState = .waitingForKeyring
        } else {
            // Nothing in iCloud. A key this Mac already holds keeps working (its keyring may
            // simply not have arrived); otherwise set one up.
            keyState = key == nil ? .needsNewPassphrase : .ready
        }
    }

    private func recheckKeyring() {
        guard isEnabled, !started else { keyringTimer?.invalidate(); keyringTimer = nil; return }
        let before = keyState
        refreshKeyState()
        if keyState == .ready { start() } else if keyState != before { lastError = nil }
    }

    /// Sets up encryption with a new passphrase: a fresh key, wrapped into Keyring.json.
    /// `replacing` starts over, removing files sealed with an old key nobody can open.
    func createPassphrase(_ passphrase: String, replacing: Bool = false) async throws {
        if !replacing, readKeyring() != nil {
            // Another Mac set up encryption meanwhile: join it instead.
            refreshKeyState()
            throw SyncError.alreadySetUp
        }
        let (keyring, newKey) = try await Task.detached { try SyncCrypto.createKeyring(passphrase: passphrase) }.value
        if replacing { removeSealedFiles() }
        try writeKeyring(keyring)
        adopt(newKey)
        // This Mac's settings become the shared copy.
        localModified = localModified ?? Self.now
        NSLog("TextLens: set up encrypted sync (key \(keyring.keyID))")
    }

    /// Unlocks the key another Mac set up. Throws `SyncCrypto.CryptoError.wrongPassphrase`.
    func enterPassphrase(_ passphrase: String) async throws {
        guard let keyring = readKeyring() else { throw SyncError.noKeyring }
        let unlocked = try await Task.detached { try SyncCrypto.unwrap(keyring, passphrase: passphrase) }.value
        // Adopt what the other Macs share rather than overwriting it.
        localModified = nil
        adopt(unlocked)
    }

    /// Rewraps the same key with a new passphrase, so other Macs keep working.
    func changePassphrase(_ passphrase: String) async throws {
        guard let key else { throw SyncError.noKeyring }
        let keyring = try await Task.detached { try SyncCrypto.wrap(key, passphrase: passphrase) }.value
        try writeKeyring(keyring)
    }

    private func adopt(_ newKey: SymmetricKey) {
        key = newKey
        SyncKeychain.saveKey(newKey)
        keyState = .ready
        lastError = nil
        started = false
        timer?.invalidate()
        start()
        ActivitySync.shared.keyDidChange()
        HistorySync.shared.start()
    }

    private func forgetKey() {
        key = nil
        SyncKeychain.deleteKey()
    }

    enum SyncError: LocalizedError {
        case noKeyring, alreadySetUp
        var errorDescription: String? {
            switch self {
            case .noKeyring: "The sync keyring isn't in iCloud Drive yet. Try again in a moment."
            case .alreadySetUp: "Another Mac has just set up encrypted sync. Enter the passphrase you chose there."
            }
        }
    }

    private func readKeyring() -> SyncCrypto.Keyring? {
        guard FileManager.default.fileExists(atPath: Self.keyringFile.path) else { return nil }
        var keyring: SyncCrypto.Keyring?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: Self.keyringFile, options: [], error: &coordinationError) { url in
            if let data = try? Data(contentsOf: url) { keyring = try? Self.keyringDecoder.decode(SyncCrypto.Keyring.self, from: data) }
        }
        return keyring
    }

    private func writeKeyring(_ keyring: SyncCrypto.Keyring) throws {
        let data = try Self.keyringEncoder.encode(keyring)
        try coordinatedWrite(data, to: Self.keyringFile)
    }

    /// Settings, every Mac's activity file and the synced history, after starting over
    /// with a new key.
    private func removeSealedFiles() {
        var targets = [Self.file]
        for sub in ["Activity", "History"] {
            let folder = Self.folder.appending(path: sub)
            if let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
                targets += names.filter { $0.contains(".tlsync") }.map { folder.appending(path: $0) }
            }
        }
        targets.forEach(Self.coordinatedDelete)
    }

    private static let keyringEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let keyringDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Reading and writing

    private struct Document {
        var updatedAt: Date
        var updatedBy: String
        var settings: [String: Any]
    }

    private func checkForRemoteChange() {
        guard started else { return }
        // Another Mac may have started over with a new passphrase.
        refreshKeyState()
        guard keyState == .ready else {
            stop()
            start()
            HistorySync.shared.start()
            return
        }
        let date = (try? Self.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if date != lastSeenFileDate { pull() }
    }

    private func pull() {
        guard let remote = readRemote() else {
            // Nothing in iCloud yet: this Mac's settings become the shared copy.
            if lastError == nil { write() }
            return
        }
        if let local = localModified, local > remote.updatedAt {
            write()
        } else if localModified == nil || remote.updatedAt > localModified! {
            apply(remote)
        } else {
            noteSynced(remote)
        }
    }

    private func readRemote() -> Document? {
        guard let key else { return nil }
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.file.path) else {
            if fm.fileExists(atPath: Self.placeholder(for: Self.file).path) {
                try? fm.startDownloadingUbiquitousItem(at: Self.file)
                lastError = "Waiting for iCloud Drive to download your settings…"
            }
            return nil
        }
        var result: Document?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: Self.file, options: [], error: &coordinationError) { url in
            guard let sealed = try? Data(contentsOf: url),
                  let data = try? SyncCrypto.open(sealed, using: key),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let updatedAt = plist["updatedAt"] as? Date,
                  let settings = plist["settings"] as? [String: Any]
            else {
                lastError = "The settings in iCloud Drive couldn't be opened with this Mac's key."
                return
            }
            result = Document(updatedAt: updatedAt, updatedBy: plist["updatedBy"] as? String ?? "another Mac", settings: settings)
            lastError = nil
        }
        if let coordinationError { lastError = coordinationError.localizedDescription }
        lastSeenFileDate = (try? Self.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return result
    }

    private func write() {
        guard isEnabled, iCloudDriveAvailable, let key else { return }
        let updatedAt = localModified ?? Self.now
        // The whole set, defaults included (see Preferences.snapshot).
        var settings = Preferences.shared.snapshot.filter { Self.syncedKeys.contains($0.key) }
        settings["showInDock"] = AppPresence.showInDock
        settings["showInMenuBar"] = AppPresence.showInMenuBar
        settings[UpdatePolicy.key] = UpdatePolicy.current.rawValue
        let plist: [String: Any] = ["version": 2, "updatedAt": updatedAt, "updatedBy": Self.deviceName, "settings": settings]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            try coordinatedWrite(try SyncCrypto.seal(data, using: key), to: Self.file)
            if localModified == nil { localModified = updatedAt }
            lastSeenFileDate = (try? Self.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            noteSynced(Document(updatedAt: updatedAt, updatedBy: Self.deviceName, settings: settings))
            // The unencrypted copy from 1.0.7 and earlier goes once the encrypted one is there.
            if FileManager.default.fileExists(atPath: Self.legacyFile.path) { Self.coordinatedDelete(Self.legacyFile) }
        } catch {
            lastError = "Settings couldn't be saved to iCloud Drive: \(error.localizedDescription)"
        }
    }

    private func coordinatedWrite(_ data: Data, to target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let error = coordinationError ?? writeError { throw error }
    }

    nonisolated static func coordinatedDelete(_ target: URL) {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forDeleting, error: &coordinationError) { url in
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// iCloud Drive can evict a file to save space, leaving ".<name>.icloud" in its place.
    nonisolated static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
    }

    private func apply(_ remote: Document) {
        applying = true
        defer { applying = false }
        // Only what the file holds. Files written before 1.5.1 left out settings at their
        // defaults; treating a missing setting as "reset it" wiped out this Mac's choices,
        // so a missing setting now keeps this Mac's value.
        for key in Self.syncedKeys {
            if let value = remote.settings[key] { defaults.set(value, forKey: key) }
        }
        Preferences.shared.reload()
        AutoUpdater.shared.policy = UpdatePolicy.current
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

    /// Whole seconds, so a date read back from the file compares equal to the one written.
    private static var now: Date {
        Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
    }

    static var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}

/// The sync data key, kept in this Mac's login keychain.
enum SyncKeychain {
    static let service = "com.smanke.TextLens.sync"
    /// A test run pointed at its own sync folder keeps its key apart from the real one.
    static let account: String = {
        guard let folder = ProcessInfo.processInfo.environment["TEXTLENS_SYNC_FOLDER"] else { return "data-key" }
        return "data-key-test-" + SyncCrypto.sha256Hex(Data((folder + (Bundle.main.bundleIdentifier ?? "")).utf8)).prefix(8)
    }()

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
                    UserDefaults.standard.set("ok", forKey: "debug.syncCommand")
                } catch {
                    UserDefaults.standard.set("error: \(error.localizedDescription)", forKey: "debug.syncCommand")
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
                }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let d = UserDefaults.standard
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
