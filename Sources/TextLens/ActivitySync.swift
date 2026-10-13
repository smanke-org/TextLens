import AppKit
import CryptoKit
import Foundation
import IOKit
import Observation
import SystemConfiguration
import TextLensKit

/// Combines the Activity graph's counts from every Mac that shares TextLens settings
/// through iCloud Drive.
///
/// Each Mac writes only its own file, `iCloud Drive/TextLens/Activity/<device>.json`, and
/// reads the others'. With one writer per file there are no conflicts to resolve, and the
/// counts are whole-day totals, so reading a file twice never counts anything twice. Only
/// numbers are shared, never what was captured. Takes part only while settings sync is on;
/// turning it off removes this Mac's file, so the other Macs stop counting it.
@Observable
@MainActor
final class ActivitySync {
    static let shared = ActivitySync()

    /// The other Macs' latest files, by device ID.
    private(set) var remotes: [String: DeviceActivity] = [:]

    @ObservationIgnored private var started = false
    @ObservationIgnored private var observingWake = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.smanke.TextLens.activitysync", qos: .utility)

    private enum Keys {
        static let remoteCache = "activitySync.remotes"
        static let macCount = "diagnostics.activityMacCount"
        static let allMacsCaptures = "diagnostics.activityAllMacsCaptures"
    }

    private init() {
        // Last-known counts from the other Macs, so the graph is complete at once rather
        // than showing only this Mac until the first read lands.
        if let data = UserDefaults.standard.data(forKey: Keys.remoteCache),
           let cached = try? DeviceActivity.decoder.decode([String: DeviceActivity].self, from: data) {
            remotes = cached
        }
    }

    // MARK: - What the graph shows

    /// Whether other Macs' counts are combined: settings sync is on and iCloud Drive is there.
    var isActive: Bool {
        SettingsSync.shared.isEnabled && SettingsSync.shared.iCloudDriveAvailable
    }

    /// The other Macs whose counts are combined; none while sync is off.
    var activeRemotes: [DeviceActivity] {
        isActive ? remotes.values.sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending } : []
    }

    /// This Mac's counts plus the other Macs'.
    var combinedLog: ActivityLog {
        ActivityLog.combined([ActivityStore.shared.log] + activeRemotes.map(\.log))
    }

    // MARK: - Lifecycle

    /// At launch, and whenever settings sync is turned on or off.
    func start() {
        guard SettingsSync.shared.isEnabled else {
            stop()
            return
        }
        guard !started else { return }
        started = true
        publish()
        refresh()
        // Other Macs' captures arrive in the background; look for them now and then.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { ActivitySync.shared.refresh() }
        }
        guard !observingWake else { return }
        observingWake = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ActivitySync.shared.refresh() }
        }
    }

    /// Settings sync was turned off: stop sharing, and take this Mac's file away so the
    /// other Macs no longer count it.
    private func stop() {
        guard started else { return }
        started = false
        timer?.invalidate()
        timer = nil
        publishTask?.cancel()
        guard let folder = Self.folder else { return }
        let url = folder.appending(path: "\(DeviceIdentity.deviceID).json")
        queue.async {
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
                try? FileManager.default.removeItem(at: target)
            }
        }
    }

    /// A capture was counted on this Mac. Written a few seconds later, so a burst of
    /// captures writes once.
    func localDidChange() {
        guard started else { return }
        publishTask?.cancel()
        publishTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            publishTask = nil
            publish()
        }
    }

    /// At quit, writes a capture still waiting for its debounced write.
    func flush() {
        guard started, publishTask != nil else { return }
        publishTask?.cancel()
        publishTask = nil
        publish(waiting: true)
    }

    // MARK: - Files

    /// `iCloud Drive/TextLens/Activity`, or nil while iCloud Drive is off. Follows
    /// `TEXTLENS_SYNC_FOLDER`, so a test build never overwrites the installed app's file
    /// (both share this Mac's device ID).
    nonisolated static var folder: URL? {
        let drive = SettingsSync.iCloudDrive
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appending(path: "TextLens").appending(path: "Activity")
    }

    /// `waiting` blocks briefly for the write, for quit, where there's no later chance.
    private func publish(waiting: Bool = false) {
        guard started, let folder = Self.folder else { return }
        let done = DispatchSemaphore(value: 0)
        let record = DeviceActivity(deviceID: DeviceIdentity.deviceID, deviceName: DeviceIdentity.deviceName,
                                    updatedAt: Date(), appVersion: AppInfo.version, log: ActivityStore.shared.log)
        queue.async {
            defer { done.signal() }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let data = try DeviceActivity.encoder.encode(record)
                let url = folder.appending(path: "\(record.deviceID).json")
                var coordinationError: NSError?
                var writeError: Error?
                NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                    do { try data.write(to: target, options: .atomic) } catch { writeError = error }
                }
                if let error = coordinationError ?? writeError { throw error }
            } catch {
                NSLog("TextLens: couldn't share activity through iCloud Drive: \(error.localizedDescription)")
            }
        }
        // Bounded, so a busy iCloud daemon can't hold up quitting.
        if waiting { _ = done.wait(timeout: .now() + 2) }
    }

    /// Reads the other Macs' files. Off the main thread, since a coordinated read can wait
    /// on iCloud.
    func refresh() {
        guard started, let folder = Self.folder else { return }
        let ownID = DeviceIdentity.deviceID
        queue.async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            var fresh: [String: DeviceActivity] = [:]
            var downloading = Set<String>()
            for name in names {
                // iCloud Drive can evict a file to save space, leaving ".<name>.icloud".
                // Ask for it back and keep the last-known counts meanwhile.
                if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                    let real = String(name.dropFirst().dropLast(".icloud".count))
                    let id = String(real.dropLast(".json".count))
                    guard id != ownID else { continue }
                    try? FileManager.default.startDownloadingUbiquitousItem(at: folder.appending(path: real))
                    downloading.insert(id)
                    continue
                }
                guard name.hasSuffix(".json") else { continue }
                var data: Data?
                var coordinationError: NSError?
                NSFileCoordinator().coordinate(readingItemAt: folder.appending(path: name), options: [], error: &coordinationError) { target in
                    data = try? Data(contentsOf: target)
                }
                guard let data, let record = try? DeviceActivity.decoder.decode(DeviceActivity.self, from: data),
                      record.deviceID != ownID else { continue }
                fresh[record.deviceID] = record
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ActivitySync.shared.apply(fresh, downloading: downloading) }
            }
        }
    }

    private func apply(_ fresh: [String: DeviceActivity], downloading: Set<String>) {
        var merged = fresh
        for id in downloading where merged[id] == nil { merged[id] = remotes[id] }
        // A Mac whose file is gone (sync turned off there, or the file deleted) drops out.
        if merged != remotes { remotes = merged }
        if let data = try? DeviceActivity.encoder.encode(remotes) {
            UserDefaults.standard.set(data, forKey: Keys.remoteCache)
        }
        // So the combined numbers can be checked with `defaults read com.smanke.TextLens`.
        UserDefaults.standard.set(activeRemotes.count + 1, forKey: Keys.macCount)
        UserDefaults.standard.set(combinedLog.days.values.reduce(0) { $0 + $1.values.reduce(0, +) }, forKey: Keys.allMacsCaptures)
    }
}

/// A stable identity for this Mac that is safe to write into iCloud Drive.
enum DeviceIdentity {
    /// From the hardware UUID, so it survives reinstalls and is not carried to a new Mac
    /// by Migration Assistant (an ID kept in UserDefaults would be, and two Macs would then
    /// share one file). Hashed, so the hardware identifier never leaves the Mac.
    static let deviceID: String = {
        let source = hardwareUUID() ?? fallbackUUID()
        let digest = SHA256.hash(data: Data("\(source):com.smanke.TextLens".utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }()

    /// The name in System Settings › General › About. Not `Host.current().localizedName`,
    /// which can block for seconds on DNS.
    static var deviceName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    /// Only reached if IOKit won't give up the hardware UUID.
    private static func fallbackUUID() -> String {
        let key = "activitySync.fallbackDeviceUUID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}
