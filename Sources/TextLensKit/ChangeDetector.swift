import Foundation

/// When a watched region should get your attention.
public enum WatchTrigger: String, CaseIterable, Codable, Sendable {
    /// The text changed at all.
    case anyChange
    /// The text now contains the keyword, and didn't before.
    case appears
    /// The text no longer contains the keyword, and did before.
    case disappears

    public var title: String {
        switch self {
        case .anyChange: "Any change"
        case .appears: "Text appears"
        case .disappears: "Text disappears"
        }
    }

    public var needsKeyword: Bool { self != .anyChange }
}

/// Decides whether a new reading of a watched region is a real change.
///
/// OCR of an unchanged screen isn't perfectly stable: anti-aliasing, a blinking caret or
/// a scrolled pixel can turn "l" into "I" for one frame. So readings are normalized
/// (whitespace collapsed, case and accents folded) and two readings count as the same
/// when nearly all of their words match. A reading must also differ from the last one
/// for `confirmations` readings in a row before it counts.
public struct ChangeDetector: Sendable {
    public var trigger: WatchTrigger
    public var keyword: String
    public var useRegex: Bool
    /// Word-set similarity at or above which two readings are treated as the same text.
    public var sameThreshold: Double
    public var confirmations: Int

    public private(set) var baseline: String?
    private var pending: String?
    private var pendingCount = 0

    public init(trigger: WatchTrigger = .anyChange, keyword: String = "", useRegex: Bool = false,
                sameThreshold: Double = 0.92, confirmations: Int = 2) {
        self.trigger = trigger
        self.keyword = keyword
        self.useRegex = useRegex
        self.sameThreshold = sameThreshold
        self.confirmations = max(1, confirmations)
    }

    public enum Outcome: Equatable, Sendable {
        /// The first reading, which becomes the baseline.
        case started
        case unchanged
        /// A different reading not yet seen often enough to trust.
        case settling
        /// The text changed, but not in the way the trigger asks about.
        case changedQuietly(old: String, new: String)
        case fired(old: String, new: String)
    }

    public mutating func feed(_ reading: String) -> Outcome {
        let text = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = baseline else {
            baseline = text
            return .started
        }
        if Self.similarity(current, text) >= sameThreshold {
            pending = nil
            pendingCount = 0
            return .unchanged
        }
        if let pending, Self.similarity(pending, text) >= sameThreshold {
            pendingCount += 1
        } else {
            pending = text
            pendingCount = 1
        }
        guard pendingCount >= confirmations else { return .settling }

        pending = nil
        pendingCount = 0
        baseline = text
        let fires: Bool
        switch trigger {
        case .anyChange: fires = true
        case .appears: fires = matches(text) && !matches(current)
        case .disappears: fires = !matches(current) ? false : !matches(text)
        }
        return fires ? .fired(old: current, new: text) : .changedQuietly(old: current, new: text)
    }

    public func matches(_ text: String) -> Bool {
        let needle = keyword.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }
        if useRegex {
            guard let regex = try? NSRegularExpression(pattern: needle, options: [.caseInsensitive]) else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        return Self.fold(text).contains(Self.fold(needle))
    }

    /// Whether the keyword is a usable regular expression (always true for plain text).
    public var keywordIsValid: Bool {
        !useRegex || (try? NSRegularExpression(pattern: keyword)) != nil
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Dice coefficient over the two readings' words, counting repeats.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let wordsA = fold(a).split(separator: " ")
        let wordsB = fold(b).split(separator: " ")
        if wordsA.isEmpty && wordsB.isEmpty { return 1 }
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return 0 }
        var counts: [Substring: Int] = [:]
        for w in wordsA { counts[w, default: 0] += 1 }
        var shared = 0
        for w in wordsB where (counts[w] ?? 0) > 0 {
            counts[w]! -= 1
            shared += 1
        }
        return 2 * Double(shared) / Double(wordsA.count + wordsB.count)
    }

    /// The words that are new in `new`, for a short notification body.
    public static func addedText(old: String, new: String, limit: Int = 140) -> String {
        var counts: [Substring: Int] = [:]
        for w in fold(old).split(separator: " ") { counts[w, default: 0] += 1 }
        var added: [Substring] = []
        for (folded, original) in zip(fold(new).split(separator: " "), new.split(whereSeparator: \.isWhitespace)) {
            if (counts[folded] ?? 0) > 0 { counts[folded]! -= 1 } else { added.append(original) }
        }
        let text = (added.isEmpty ? new.split(whereSeparator: \.isWhitespace) : added).joined(separator: " ")
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}
