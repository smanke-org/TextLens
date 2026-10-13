import AppKit
import Foundation
import Observation

/// Keeps settings in step across the Macs on one iCloud account, through a file in
/// iCloud Drive (`iCloud Drive/TextLens/Settings.plist`). Whole-document,
/// last-writer-wins: each change rewrites the file, and a newer file written by another
/// Mac replaces this Mac's settings.
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
        }
    }
    private(set) var lastSynced: Date?
    private(set) var lastSource: String?
    private(set) var lastError: String?

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
    nonisolated static var file: URL {
        iCloudDrive.appending(path: "TextLens").appending(path: "Settings.plist")
    }

    var iCloudDriveAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.iCloudDrive.path)
    }

    /// Must not touch Preferences: its initializer can report changes here.
    private init() {
        isEnabled = defaults.bool(forKey: Keys.enabled)
    }

    // MARK: - Lifecycle

    /// On a brand-new install, a settings file already in iCloud Drive means this user has
    /// TextLens on another Mac: turn sync on and start from those settings, rather than
    /// from the defaults.
    func adoptOnNewInstall() {
        guard !isEnabled, FileManager.default.fileExists(atPath: Self.file.path) else { return }
        NSLog("TextLens: new install found settings in iCloud Drive; turning sync on")
        isEnabled = true
    }

    func start() {
        guard isEnabled, !started else { return }
        guard iCloudDriveAvailable else {
            lastError = "iCloud Drive isn't turned on for this Mac. Turn it on in System Settings › Apple Account › iCloud."
            return
        }
        started = true
        lastError = nil
        pull()
        // iCloud delivers other Macs' edits in the background; look for them periodically.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { SettingsSync.shared.checkForRemoteChange() }
        }
    }

    private func stop() {
        started = false
        timer?.invalidate()
        timer = nil
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

    // MARK: - Reading and writing

    private struct Document {
        var updatedAt: Date
        var updatedBy: String
        var settings: [String: Any]
    }

    private func checkForRemoteChange() {
        guard started else { return }
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
        guard FileManager.default.fileExists(atPath: Self.file.path) else { return nil }
        var result: Document?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: Self.file, options: [], error: &coordinationError) { url in
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let updatedAt = plist["updatedAt"] as? Date,
                  let settings = plist["settings"] as? [String: Any]
            else {
                lastError = "The settings file in iCloud Drive couldn't be read."
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
        guard isEnabled, iCloudDriveAvailable else { return }
        let updatedAt = localModified ?? Self.now
        // The whole set, defaults included (see Preferences.snapshot).
        var settings = Preferences.shared.snapshot.filter { Self.syncedKeys.contains($0.key) }
        settings["showInDock"] = AppPresence.showInDock
        settings["showInMenuBar"] = AppPresence.showInMenuBar
        settings[UpdatePolicy.key] = UpdatePolicy.current.rawValue
        let plist: [String: Any] = ["version": 1, "updatedAt": updatedAt, "updatedBy": Self.deviceName, "settings": settings]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: Self.file, options: .forReplacing, error: &coordinationError) { url in
                do { try data.write(to: url, options: .atomic) } catch { writeError = error }
            }
            if let error = coordinationError ?? writeError { throw error }
            if localModified == nil { localModified = updatedAt }
            lastSeenFileDate = (try? Self.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            noteSynced(Document(updatedAt: updatedAt, updatedBy: Self.deviceName, settings: settings))
        } catch {
            lastError = "Settings couldn't be saved to iCloud Drive: \(error.localizedDescription)"
        }
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
