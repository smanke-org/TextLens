import AppKit
import CryptoKit
import Foundation
import IOKit
import Observation
import SystemConfiguration
import TextLensKit

/// Combines the Activity graph's counts from every Mac that shares TextLens settings.
///
/// Each Mac writes only its own CloudKit record, `Device_<device>` (sealed with the sync key,
/// like the settings), and reads the others'. With one writer per record there are no
/// conflicts to resolve, and the counts are whole-day totals, so reading a record twice never
/// counts anything twice. Only numbers are shared, never what was captured. Takes part only
/// while settings sync is on; turning it off removes this Mac's record, so the other Macs
/// stop counting it.
@Observable
@MainActor
final class ActivitySync {
    static let shared = ActivitySync()

    /// The other Macs' latest records, by device ID.
    private(set) var remotes: [String: DeviceActivity] = [:]

    @ObservationIgnored private var started = false
    @ObservationIgnored private var publishTask: Task<Void, Never>?

    private enum Keys {
        static let remoteCache = "activitySync.remotes"
        static let macCount = "diagnostics.activityMacCount"
        static let allMacsCaptures = "diagnostics.activityAllMacsCaptures"
    }

    private init() {
        // Last-known counts from the other Macs, so the graph is complete at once rather
        // than showing only this Mac until the first fetch lands.
        if let data = AppDefaults.store.data(forKey: Keys.remoteCache),
           let cached = try? DeviceActivity.decoder.decode([String: DeviceActivity].self, from: data) {
            remotes = cached
        }
    }

    // MARK: - What the graph shows

    /// Whether other Macs' counts are combined: settings sync is on and unlocked.
    var isActive: Bool { SettingsSync.shared.isReady }

    /// The other Macs whose counts are combined; none while sync is off.
    var activeRemotes: [DeviceActivity] {
        isActive ? remotes.values.sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending } : []
    }

    /// This Mac's counts plus the other Macs'.
    var combinedLog: ActivityLog {
        ActivityLog.combined([ActivityStore.shared.log] + activeRemotes.map(\.log))
    }

    // MARK: - Lifecycle

    /// When the sync engine starts, and whenever settings sync is turned off.
    func start() {
        guard SettingsSync.shared.isEnabled else { return stop() }
        guard CloudSync.shared.isRunning else { return }
        started = true
        CloudSync.shared.queueSave([CloudSync.Name.device(DeviceIdentity.deviceID)])
    }

    /// Settings sync was turned off: stop sharing, and take this Mac's record away so the
    /// other Macs no longer count it.
    private func stop() {
        guard started else { return }
        started = false
        publishTask?.cancel()
        let name = CloudSync.Name.device(DeviceIdentity.deviceID)
        Task { await CloudSync.shared.deleteNow(name) }
    }

    /// A capture was counted on this Mac. Sent a few seconds later, so a burst of captures
    /// sends once.
    func localDidChange() {
        guard started else { return }
        publishTask?.cancel()
        publishTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            publishTask = nil
            CloudSync.shared.queueSave([CloudSync.Name.device(DeviceIdentity.deviceID)])
        }
    }

    /// At quit, queues a capture still waiting for its debounced send (it goes up next time
    /// if not now).
    func flush() {
        guard started, publishTask != nil else { return }
        publishTask?.cancel()
        publishTask = nil
        CloudSync.shared.queueSave([CloudSync.Name.device(DeviceIdentity.deviceID)])
    }

    /// Reads other Macs' counts again.
    func refresh() { CloudSync.shared.fetchNow() }

    // MARK: - From CloudSync

    /// This Mac's record, sealed.
    func sealedOwnRecord(using key: SymmetricKey) -> Data? {
        let record = DeviceActivity(deviceID: DeviceIdentity.deviceID, deviceName: DeviceIdentity.deviceName,
                                    updatedAt: Date(), appVersion: AppInfo.version, log: ActivityStore.shared.log)
        return try? SyncCrypto.seal(DeviceActivity.encoder.encode(record), using: key)
    }

    /// Another Mac's record arrived.
    func received(_ sealed: Data) {
        guard let key = SettingsSync.shared.key, let plain = try? SyncCrypto.open(sealed, using: key),
              let record = try? DeviceActivity.decoder.decode(DeviceActivity.self, from: plain),
              record.deviceID != DeviceIdentity.deviceID else { return }
        var merged = remotes
        merged[record.deviceID] = record
        apply(merged)
    }

    /// A Mac turned sync off (or its record was deleted): it drops out.
    func removed(deviceID: String) {
        guard remotes[deviceID] != nil else { return }
        var merged = remotes
        merged[deviceID] = nil
        apply(merged)
    }

    private func apply(_ merged: [String: DeviceActivity]) {
        if merged != remotes { remotes = merged }
        if let data = try? DeviceActivity.encoder.encode(remotes) {
            AppDefaults.store.set(data, forKey: Keys.remoteCache)
        }
        // So the combined numbers can be checked with `defaults read com.smanke.TextLens`.
        AppDefaults.store.set(activeRemotes.count + 1, forKey: Keys.macCount)
        AppDefaults.store.set(combinedLog.days.values.reduce(0) { $0 + $1.values.reduce(0, +) }, forKey: Keys.allMacsCaptures)
    }
}

/// A stable identity for this Mac that is safe to put in iCloud.
enum DeviceIdentity {
    /// From the hardware UUID, so it survives reinstalls and is not carried to a new Mac
    /// by Migration Assistant (an ID kept in UserDefaults would be, and two Macs would then
    /// share one file). Hashed, so the hardware identifier never leaves the Mac.
    static let deviceID: String = {
        #if DEBUG
        // Test copies on one Mac pretend to be different Macs.
        if let override = ProcessInfo.processInfo.environment["TEXTLENS_DEVICE_ID"] { return override }
        #endif
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
        if let existing = AppDefaults.store.string(forKey: key) { return existing }
        let created = UUID().uuidString
        AppDefaults.store.set(created, forKey: key)
        return created
    }
}
