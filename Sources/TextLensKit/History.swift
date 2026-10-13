import Foundation

/// One saved capture.
public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case text, code, translation, watch

        public var title: String {
            switch self {
            case .text: "Text"
            case .code: "QR & Bar Codes"
            case .translation: "Translations"
            case .watch: "Watched Areas"
            }
        }

        public var symbol: String {
            switch self {
            case .text: "text.viewfinder"
            case .code: "qrcode.viewfinder"
            case .translation: "translate"
            case .watch: "eye"
            }
        }
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var text: String
    public var translation: String?
    public var sourceLanguage: String?
    public var targetLanguage: String?
    /// The app that was in front when the capture was taken.
    public var appName: String?
    public var appBundleID: String?
    /// File name of the thumbnail inside the history folder.
    public var thumbnail: String?
    public var pinned: Bool

    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind, text: String, translation: String? = nil,
                sourceLanguage: String? = nil, targetLanguage: String? = nil, appName: String? = nil,
                appBundleID: String? = nil, thumbnail: String? = nil, pinned: Bool = false) {
        self.id = id
        self.date = date
        self.kind = kind
        self.text = text
        self.translation = translation
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.appName = appName
        self.appBundleID = appBundleID
        self.thumbnail = thumbnail
        self.pinned = pinned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        translation = try c.decodeIfPresent(String.self, forKey: .translation)
        sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage)
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

/// Searching and trimming the history, kept apart from storage so it can be tested.
public enum HistoryQuery {
    /// Entries matching every word of `query` (in the text, translation or app name,
    /// ignoring case and accents), newest first, pinned entries on top.
    public static func search(_ entries: [HistoryEntry], query: String, kind: HistoryEntry.Kind? = nil) -> [HistoryEntry] {
        let terms = fold(query).split(separator: " ").map(String.init)
        return entries
            .filter { kind == nil || $0.kind == kind }
            .filter { entry in
                guard !terms.isEmpty else { return true }
                let haystack = fold([entry.text, entry.translation ?? "", entry.appName ?? ""].joined(separator: " "))
                return terms.allSatisfy { haystack.contains($0) }
            }
            .sorted { ($0.pinned ? 1 : 0, $0.date) > ($1.pinned ? 1 : 0, $1.date) }
    }

    /// What to drop to stay within `maxCount` entries and `maxAgeDays` (0 = no age limit).
    /// Pinned entries are never dropped.
    public static func expired(_ entries: [HistoryEntry], maxCount: Int, maxAgeDays: Int, now: Date = Date()) -> Set<UUID> {
        var drop = Set<UUID>()
        if maxAgeDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400)
            for e in entries where !e.pinned && e.date < cutoff { drop.insert(e.id) }
        }
        let kept = entries.filter { !drop.contains($0.id) && !$0.pinned }.sorted { $0.date > $1.date }
        let room = max(0, maxCount - entries.filter(\.pinned).count)
        if kept.count > room {
            for e in kept[room...] { drop.insert(e.id) }
        }
        return drop
    }

    /// A one-line preview of an entry's text.
    public static func snippet(_ text: String, limit: Int = 120) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
