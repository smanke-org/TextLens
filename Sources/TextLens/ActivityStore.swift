import Foundation
import Observation
import TextLensKit

/// Counts of captures per day, for the Activity graph in Settings.
///
/// Kept apart from History on purpose: History can be turned off, trimmed or cleared, and
/// the graph should still show how much TextLens was used. Only numbers are stored, in
/// Application Support/TextLens/activity.json.
@Observable
@MainActor
final class ActivityStore {
    static let shared = ActivityStore()

    private(set) var log = ActivityLog()

    private var url: URL {
        HistoryStore.shared.folder.deletingLastPathComponent().appending(path: "activity.json")
    }

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(ActivityLog.self, from: data) {
            log = saved
        } else {
            seedFromHistory()
        }
    }

    func record(_ kind: HistoryEntry.Kind) {
        log.record(kind.rawValue)
        log.trim()
        save()
        ActivitySync.shared.localDidChange()
    }

    /// The first time the graph exists, start it from whatever History already holds.
    private func seedFromHistory() {
        // Only this Mac's captures: synced ones are counted by the Mac that took them.
        for entry in HistoryStore.shared.entries where entry.origin == nil || entry.origin == DeviceIdentity.deviceID {
            log.record(entry.kind.rawValue, at: entry.date)
        }
        if !log.days.isEmpty { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(log).write(to: url, options: .atomic)
        } catch {
            NSLog("TextLens: couldn't save activity: \(error.localizedDescription)")
        }
    }
}
