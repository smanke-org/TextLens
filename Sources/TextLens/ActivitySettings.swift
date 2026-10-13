import Charts
import SwiftUI
import TextLensKit

/// Settings › Activity: how many captures TextLens has made over time. The graph starts at
/// a week and widens to 30, 90 and 180 days, then a year, as more days of data build up.
/// With settings sync on, it adds up every Mac that shares TextLens settings.
struct ActivitySettings: View {
    @State private var store = ActivityStore.shared
    @State private var sync = ActivitySync.shared
    @State private var settingsSync = SettingsSync.shared
    @State private var hovered: Date?
    /// Whether the graph shows every Mac or only this one. Kept on each Mac, not synced.
    @AppStorage("activity.showAllMacs") private var showAllMacs = true

    /// What counts as a capture: text, codes and translations. Watch alerts happen on their
    /// own, so they're reported beside the graph rather than in it.
    private static let captureKinds: Set<String> = [HistoryEntry.Kind.text.rawValue, HistoryEntry.Kind.code.rawValue,
                                                    HistoryEntry.Kind.translation.rawValue]

    var body: some View {
        let now = Date()
        let remotes = sync.activeRemotes
        let allMacs = showAllMacs && !remotes.isEmpty
        let log = allMacs ? sync.combinedLog : store.log
        let range = CaptureStats.range(firstDay: log.firstDay.flatMap { ActivityLog.date(for: $0) }, today: now)
        let bars = CaptureStats.bars(counts: log.counts(kinds: Self.captureKinds), range: range, today: now)
        let totals = log.totals(since: bars.first?.start ?? now)
        let total = Self.captureKinds.reduce(0) { $0 + (totals[$1] ?? 0) }
        let hoveredBar = hovered.flatMap { date in bars.first { date >= $0.start && date < $0.end } }

        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if !remotes.isEmpty {
                        Picker("Show", selection: $showAllMacs) {
                            Text("This Mac").tag(false)
                            Text("All Macs").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 8)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(total, format: .number)
                            .font(.system(size: 34, weight: .semibold))
                            .monospacedDigit()
                        Text("capture\(total == 1 ? "" : "s") in the \(range.title)\(remotes.isEmpty ? "" : allMacs ? " on \(remotes.count + 1) Macs" : " on this Mac")")
                            .foregroundStyle(.secondary)
                    }
                    Text(breakdown(totals))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    chart(bars, range: range, hovered: hoveredBar)
                        .frame(height: 190)
                        .padding(.top, 10)

                    Text(hoveredBar.map { readout($0, range: range) } ?? "Hover over a bar to see its count.")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(hoveredBar == nil ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("The graph widens as you use TextLens: 7 days at first, then 30, 90 and 180 days, then a year. It counts captures even when History is off; only the numbers are kept, never what you captured.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            macsSection()
        }
        .formStyle(.grouped)
        .onAppear { sync.refresh() }
    }

    /// Every Mac's captures since it started counting, and all of them together, so a Mac
    /// that has stopped syncing is easy to spot.
    @ViewBuilder
    private func macsSection() -> some View {
        let remotes = sync.activeRemotes
        Section {
            if !remotes.isEmpty {
                macRow(DeviceIdentity.deviceName, status: "This Mac", log: store.log)
                ForEach(remotes, id: \.deviceID) { mac in
                    macRow(mac.deviceName, status: "Synced \(mac.updatedAt.formatted(.relative(presentation: .named)))",
                           log: mac.log)
                }
            }
        } header: {
            HStack {
                Text("All Macs")
                Spacer()
                if !remotes.isEmpty {
                    Text("\(Self.captures(in: sync.combinedLog).formatted()) captures")
                        .monospacedDigit()
                }
            }
        } footer: {
            Group {
                if !settingsSync.isEnabled {
                    Text("Turn on “Sync settings with your other Macs” in General to add up captures from every Mac that uses TextLens.")
                } else if !settingsSync.iCloudDriveAvailable {
                    Text("Turn on iCloud Drive to add up captures from your other Macs.")
                } else if remotes.isEmpty {
                    Text("Captures from your other Macs are added here once TextLens on them has settings sync turned on.")
                } else {
                    Text("Each Mac's captures since TextLens started counting there. Every Mac with settings sync on is counted, through iCloud Drive › TextLens › Activity. Only the numbers are shared. Deleting a Mac's file there removes it.")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func macRow(_ name: String, status: String, log: ActivityLog) -> some View {
        LabeledContent {
            Text(Self.captures(in: log), format: .number).monospacedDigit()
        } label: {
            Text(name)
            Text(status)
        }
    }

    /// Captures since counting began; watch alerts aren't captures.
    private static func captures(in log: ActivityLog) -> Int {
        let totals = log.lifetimeTotals
        return captureKinds.reduce(0) { $0 + (totals[$1] ?? 0) }
    }

    @ViewBuilder
    private func chart(_ bars: [StatsBar], range: StatsRange, hovered: StatsBar?) -> some View {
        let peak = bars.map(\.count).max() ?? 0
        Chart(bars) { bar in
            // A ranged bar spans exactly its days; trimming each end leaves a gap between bars.
            let gap = bar.end.timeIntervalSince(bar.start) * 0.12
            RectangleMark(xStart: .value("From", bar.start.addingTimeInterval(gap)),
                          xEnd: .value("To", bar.end.addingTimeInterval(-gap)),
                          yStart: .value("Captures", 0), yEnd: .value("Captures", bar.count))
                .foregroundStyle(Color.accentColor.opacity(hovered == nil || hovered == bar ? 1 : 0.4))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                .accessibilityLabel(readout(bar, range: range))
        }
        .chartXSelection(value: $hovered)
        .chartYScale(domain: 0...max(peak, 4))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel().foregroundStyle(Color.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: xTicks(bars, range: range)) { value in
                AxisValueLabel(centered: false) {
                    if let date = value.as(Date.self) { Text(axisLabel(date, range: range)) }
                }
                .foregroundStyle(Color.secondary)
            }
        }
        .overlay {
            if peak == 0 {
                Text("No captures yet. Press \(Preferences.shared.captureTextHotKey?.display ?? "the capture shortcut") and drag over some text.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// Where the x-axis labels go: every day for a week, then about six evenly spaced ticks.
    private func xTicks(_ bars: [StatsBar], range: StatsRange) -> [Date] {
        guard !bars.isEmpty else { return [] }
        let step: Int
        switch range {
        case .week: step = 1
        case .month: step = 5
        case .quarter: step = 2
        case .halfYear: step = 4
        case .year: step = 2
        }
        // Counted from the left, and never on the last bar, whose label would run off the edge.
        let last = range == .week ? bars.count - 1 : bars.count - 2
        return stride(from: 0, through: last, by: step).map { bars[$0].start }
    }

    private func axisLabel(_ date: Date, range: StatsRange) -> String {
        switch range {
        case .week: date.formatted(.dateTime.weekday(.abbreviated))
        case .month, .quarter, .halfYear: date.formatted(.dateTime.month(.abbreviated).day())
        case .year: date.formatted(.dateTime.month(.abbreviated))
        }
    }

    private func readout(_ bar: StatsBar, range: StatsRange) -> String {
        let count = "\(bar.count.formatted()) capture\(bar.count == 1 ? "" : "s")"
        let lastDay = bar.end.addingTimeInterval(-1)
        switch range.bucket {
        case .day:
            return "\(bar.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())): \(count)"
        case .week:
            return "\(bar.start.formatted(.dateTime.month(.abbreviated).day())) – \(lastDay.formatted(.dateTime.month(.abbreviated).day())): \(count)"
        case .month:
            return "\(bar.start.formatted(.dateTime.month(.wide).year())): \(count)"
        }
    }

    private func breakdown(_ totals: [String: Int]) -> String {
        func part(_ kind: HistoryEntry.Kind, _ one: String, _ many: String) -> String? {
            guard let n = totals[kind.rawValue], n > 0 else { return nil }
            return "\(n.formatted()) \(n == 1 ? one : many)"
        }
        let parts = [part(.text, "text capture", "text captures"), part(.code, "code", "codes"),
                     part(.translation, "translation", "translations")].compactMap { $0 }
        let watch = part(.watch, "watch alert", "watch alerts")
        let main = parts.isEmpty ? "Nothing captured yet" : parts.joined(separator: " · ")
        return watch.map { "\(main), plus \($0)" } ?? main
    }
}
