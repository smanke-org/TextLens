import Foundation

/// How far back the Activity graph looks. It widens as TextLens collects more history:
/// a week at first, then 30, 90 and 180 days, then a year.
public enum StatsRange: Int, CaseIterable, Sendable {
    case week = 7, month = 30, quarter = 90, halfYear = 180, year = 365

    public var days: Int { rawValue }

    /// How the bars are grouped: a bar per day up to 30 days, per week for 90 and 180
    /// days, per month for a year.
    public var bucket: StatsBucket {
        switch self {
        case .week, .month: .day
        case .quarter, .halfYear: .week
        case .year: .month
        }
    }

    public var title: String {
        switch self {
        case .week: "last 7 days"
        case .month: "last 30 days"
        case .quarter: "last 90 days"
        case .halfYear: "last 180 days"
        case .year: "last year"
        }
    }

    /// The smallest range that covers `span` days of data (counting the first day and
    /// today); more than 180 days shows a year.
    public static func covering(span: Int) -> StatsRange {
        allCases.first { span <= $0.days } ?? .year
    }
}

public enum StatsBucket: Sendable { case day, week, month }

/// One bar on the Activity graph.
public struct StatsBar: Equatable, Identifiable, Sendable {
    public var start: Date
    /// Exclusive.
    public var end: Date
    public var count: Int
    public var id: Date { start }

    public init(start: Date, end: Date, count: Int) {
        self.start = start
        self.end = end
        self.count = count
    }
}

/// Turns per-day capture counts into the bars for the Activity graph.
public enum CaptureStats {
    /// The range to show, given the first day anything was recorded.
    public static func range(firstDay: Date?, today: Date, calendar: Calendar = .current) -> StatsRange {
        guard let firstDay else { return .week }
        let start = calendar.startOfDay(for: firstDay), end = calendar.startOfDay(for: today)
        let span = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        return covering(span)
    }

    static func covering(_ span: Int) -> StatsRange { StatsRange.covering(span: span) }

    /// Bars covering `range` and ending today. Weeks are counted back from today so the
    /// last bar always includes it; months are calendar months, the current one partial.
    public static func bars(counts: [Date: Int], range: StatsRange, today: Date,
                            calendar: Calendar = .current) -> [StatsBar] {
        let todayStart = calendar.startOfDay(for: today)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        let firstDay = calendar.date(byAdding: .day, value: -(range.days - 1), to: todayStart)!

        var edges: [Date] = []
        switch range.bucket {
        case .day:
            edges = (0...range.days).map { calendar.date(byAdding: .day, value: $0, to: firstDay)! }
        case .week:
            let weeks = Int((Double(range.days) / 7).rounded(.up))
            edges = (0...weeks).reversed().map { calendar.date(byAdding: .day, value: -7 * $0, to: tomorrow)! }
        case .month:
            let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: todayStart))!
            edges = (0...11).reversed().map { calendar.date(byAdding: .month, value: -$0, to: thisMonth)! }
            edges.append(tomorrow)
        }

        var bars = zip(edges, edges.dropFirst()).map { StatsBar(start: $0, end: $1, count: 0) }
        for (day, count) in counts where count > 0 {
            let start = calendar.startOfDay(for: day)
            guard start >= edges.first!, start < edges.last! else { continue }
            if let index = bars.firstIndex(where: { start >= $0.start && start < $0.end }) {
                bars[index].count += count
            }
        }
        return bars
    }
}

/// The per-day counts TextLens keeps for the Activity graph: numbers only, never what
/// was captured. Days are stored as "yyyy-MM-dd" in the Mac's time zone.
public struct ActivityLog: Codable, Equatable, Sendable {
    /// The first day anything was recorded, even if that day has since been trimmed.
    public var firstDay: String?
    /// Day → kind (a `HistoryEntry.Kind` raw value) → count.
    public var days: [String: [String: Int]]

    public init(firstDay: String? = nil, days: [String: [String: Int]] = [:]) {
        self.firstDay = firstDay
        self.days = days
    }

    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(for key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public mutating func record(_ kind: String, at date: Date = Date(), calendar: Calendar = .current) {
        let day = Self.key(for: date, calendar: calendar)
        days[day, default: [:]][kind, default: 0] += 1
        if firstDay.map({ day < $0 }) ?? true { firstDay = day }
    }

    /// Drops days older than `keepDays`, so the file stays small. `firstDay` is kept, so the
    /// graph's range still reflects how long TextLens has been in use.
    public mutating func trim(keepDays: Int = 400, now: Date = Date(), calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -keepDays, to: calendar.startOfDay(for: now)) else { return }
        let cutoffKey = Self.key(for: cutoff, calendar: calendar)
        days = days.filter { $0.key >= cutoffKey }
    }

    /// Totals per day for the given kinds.
    public func counts(kinds: Set<String>, calendar: Calendar = .current) -> [Date: Int] {
        var result: [Date: Int] = [:]
        for (key, perKind) in days {
            guard let date = Self.date(for: key, calendar: calendar) else { continue }
            let total = perKind.filter { kinds.contains($0.key) }.values.reduce(0, +)
            if total > 0 { result[date, default: 0] += total }
        }
        return result
    }

    /// Totals per kind since `start`.
    public func totals(since start: Date, calendar: Calendar = .current) -> [String: Int] {
        let startKey = Self.key(for: start, calendar: calendar)
        var result: [String: Int] = [:]
        for (key, perKind) in days where key >= startKey {
            for (kind, count) in perKind { result[kind, default: 0] += count }
        }
        return result
    }
}
