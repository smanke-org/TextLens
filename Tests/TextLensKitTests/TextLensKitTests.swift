import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import TextLensKit

/// A line at row `row` (0 = top) of a page with lines 0.05 tall and 0.03 apart.
private func line(_ text: String, row: Double, x: Double = 0.05, width: Double = 0.9, gapRows: Double = 0) -> RecognizedLine {
    let top = 0.95 - (row + gapRows) * 0.08
    return RecognizedLine(text: text, box: CGRect(x: x, y: top - 0.05, width: width, height: 0.05))
}

@Suite struct AssemblerTests {
    @Test func keepsLineBreaks() {
        let lines = [line("second", row: 1), line("first", row: 0)]
        #expect(TextAssembler.assemble(lines, keepLineBreaks: true) == "first\nsecond")
    }

    @Test func reflowsWrappedParagraph() {
        let lines = [line("The quick brown fox jumps over", row: 0),
                     line("the lazy dog.", row: 1, width: 0.3)]
        #expect(TextAssembler.assemble(lines, keepLineBreaks: false) == "The quick brown fox jumps over the lazy dog.")
    }

    @Test func mendsHyphenation() {
        let lines = [line("an extra-", row: 0), line("ordinary day", row: 1)]
        #expect(TextAssembler.assemble(lines, keepLineBreaks: false) == "an extraordinary day")
    }

    @Test func keepsShortSentenceEndAsBreak() {
        let lines = [line("Title.", row: 0, width: 0.2), line("Body text here", row: 1)]
        #expect(TextAssembler.assemble(lines, keepLineBreaks: false) == "Title.\nBody text here")
    }

    @Test func blankGapMakesParagraph() {
        let lines = [line("One", row: 0), line("Two", row: 1, gapRows: 1)]
        #expect(TextAssembler.assemble(lines, keepLineBreaks: false) == "One\n\nTwo")
    }

    @Test func listItemsStayOnTheirOwnLines() {
        let lines = [line("Groceries", row: 0), line("• milk", row: 1), line("• eggs", row: 2), line("1. first", row: 3)]
        #expect(TextAssembler.assemble(lines, keepLineBreaks: false) == "Groceries\n• milk\n• eggs\n1. first")
    }

    @Test func sameRowJoinsLeftToRightWithTabForColumns() {
        let lines = [line("Price", row: 0, x: 0.6, width: 0.2), line("Item", row: 0, x: 0.05, width: 0.2),
                     line("Apple", row: 1, x: 0.05, width: 0.2), line("1.00", row: 1, x: 0.6, width: 0.2)]
        #expect(TextAssembler.assemble(lines, keepLineBreaks: false) == "Item\tPrice\nApple\t1.00")
    }

    @Test func emptyInput() {
        #expect(TextAssembler.assemble([], keepLineBreaks: false) == "")
    }
}

@Suite struct CodePayloadTests {
    @Test func url() {
        #expect(CodePayload.parse("https://example.com/a?b=1") == .url(URL(string: "https://example.com/a?b=1")!))
        #expect(CodePayload.parse("example.com/page") == .url(URL(string: "https://example.com/page")!))
        #expect(CodePayload.parse("version 1.2") == .text("version 1.2"))
        #expect(CodePayload.parse("3.14") == .text("3.14"))
    }

    @Test func wifi() {
        let parsed = CodePayload.parse(#"WIFI:T:WPA;S:My\;Net;P:pa\:ss;H:true;;"#)
        #expect(parsed == .wifi(.init(ssid: "My;Net", password: "pa:ss", security: "WPA", hidden: true)))
        let open = CodePayload.parse("WIFI:T:nopass;S:Cafe;;")
        #expect(open == .wifi(.init(ssid: "Cafe", password: nil, security: "nopass", hidden: false)))
    }

    @Test func wifiRoundTrip() {
        let code = CodePayload.wifiCode(ssid: "A;B", password: "x,y", security: "WPA", hidden: false)
        #expect(code == #"WIFI:T:WPA;S:A\;B;P:x\,y;;"#)
        #expect(CodePayload.parse(code) == .wifi(.init(ssid: "A;B", password: "x,y", security: "WPA", hidden: false)))
        #expect(CodePayload.wifiCode(ssid: "Open", password: "", security: "WPA", hidden: true) == "WIFI:T:nopass;S:Open;H:true;;")
    }

    @Test func contactsAndOthers() {
        if case .contact(_, let name) = CodePayload.parse("BEGIN:VCARD\nVERSION:3.0\nFN:Jane Example\nEND:VCARD") {
            #expect(name == "Jane Example")
        } else { Issue.record("not a contact") }
        if case .contact(let card, let name) = CodePayload.parse("MECARD:N:Example,Jane;TEL:5551234;;") {
            #expect(name == "Example,Jane")
            #expect(card.contains("FN:Jane Example"))
            #expect(card.contains("TEL:5551234"))
        } else { Issue.record("not a contact") }
        #expect(CodePayload.parse("mailto:a@b.com?subject=Hi%20there") == .email(address: "a@b.com", subject: "Hi there"))
        #expect(CodePayload.parse("tel:+15551234") == .phone("+15551234"))
        #expect(CodePayload.parse("SMSTO:5551234:hello") == .sms(number: "5551234", body: "hello"))
        #expect(CodePayload.parse("geo:40.7,-74.0") == .geo(latitude: 40.7, longitude: -74.0))
        #expect(CodePayload.parse("0123456789012") == .text("0123456789012"))
    }
}

@Suite struct ChangeDetectorTests {
    @Test func anyChangeNeedsConfirmation() {
        var d = ChangeDetector(trigger: .anyChange, confirmations: 2)
        #expect(d.feed("Price: $10") == .started)
        #expect(d.feed("Price:  $10 ") == .unchanged)
        #expect(d.feed("Price: $12") == .settling)
        #expect(d.feed("Price: $12") == .fired(old: "Price: $10", new: "Price: $12"))
        #expect(d.feed("Price: $12") == .unchanged)
    }

    @Test func oneFrameGlitchIsIgnored() {
        var d = ChangeDetector(trigger: .anyChange, confirmations: 2)
        _ = d.feed("Status: waiting")
        #expect(d.feed("Status: walting") == .settling)
        #expect(d.feed("Status: waiting") == .unchanged)
        #expect(d.baseline == "Status: waiting")
    }

    @Test func toleratesSmallJitterInLongText() {
        var d = ChangeDetector(trigger: .anyChange, sameThreshold: 0.9, confirmations: 1)
        let words = (1...30).map { "word\($0)" }
        _ = d.feed(words.joined(separator: " "))
        var jittered = words
        jittered[4] = "wOrd5x"
        #expect(d.feed(jittered.joined(separator: " ")) == .unchanged)
    }

    @Test func appearsAndDisappears() {
        var appear = ChangeDetector(trigger: .appears, keyword: "ready", confirmations: 1)
        _ = appear.feed("Build running")
        #expect(appear.feed("Build Ready ✓") == .fired(old: "Build running", new: "Build Ready ✓"))
        #expect(appear.feed("Build ready, uploading now") == .changedQuietly(old: "Build Ready ✓", new: "Build ready, uploading now"))

        var gone = ChangeDetector(trigger: .disappears, keyword: "error", confirmations: 1)
        _ = gone.feed("1 error found")
        #expect(gone.feed("All checks passed") == .fired(old: "1 error found", new: "All checks passed"))
    }

    @Test func regexKeyword() {
        var d = ChangeDetector(trigger: .appears, keyword: #"\$\d{3,}"#, useRegex: true, confirmations: 1)
        _ = d.feed("Bid $99")
        #expect(d.feed("Bid $105") == .fired(old: "Bid $99", new: "Bid $105"))
        #expect(ChangeDetector(keyword: "([", useRegex: true).keywordIsValid == false)
    }

    @Test func addedText() {
        #expect(ChangeDetector.addedText(old: "Queue: 3 jobs", new: "Queue: 4 jobs") == "4")
    }
}

@Suite struct HistoryTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func searchMatchesAllWordsIgnoringCaseAndAccents() {
        let a = HistoryEntry(date: now, kind: .text, text: "Café menu prices", appName: "Safari")
        let b = HistoryEntry(date: now.addingTimeInterval(10), kind: .translation, text: "Hola", translation: "Hello")
        let c = HistoryEntry(date: now.addingTimeInterval(-10), kind: .code, text: "https://example.com", pinned: true)
        #expect(HistoryQuery.search([a, b, c], query: "cafe SAFARI").map(\.id) == [a.id])
        #expect(HistoryQuery.search([a, b, c], query: "hello").map(\.id) == [b.id])
        #expect(HistoryQuery.search([a, b, c], query: "").map(\.id) == [c.id, b.id, a.id])
        #expect(HistoryQuery.search([a, b, c], query: "", kind: .text).map(\.id) == [a.id])
    }

    @Test func expiryKeepsPinnedAndNewest() {
        let old = HistoryEntry(date: now.addingTimeInterval(-40 * 86_400), kind: .text, text: "old")
        let oldPinned = HistoryEntry(date: now.addingTimeInterval(-40 * 86_400), kind: .text, text: "keep", pinned: true)
        let recent = (0..<5).map { HistoryEntry(date: now.addingTimeInterval(Double(-$0)), kind: .text, text: "r\($0)") }
        let drop = HistoryQuery.expired([old, oldPinned] + recent, maxCount: 4, maxAgeDays: 30, now: now)
        #expect(drop.contains(old.id))
        #expect(!drop.contains(oldPinned.id))
        // 4 slots, one taken by the pinned entry: the three newest stay.
        #expect(drop.contains(recent[3].id) && drop.contains(recent[4].id))
        #expect(!drop.contains(recent[2].id))
    }

    @Test func decodesWithoutPinned() throws {
        let json = #"{"id":"5A1C2D3E-0000-0000-0000-000000000000","date":0,"kind":"text","text":"x"}"#
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))
        #expect(entry.pinned == false)
    }
}

@Suite struct CaptureStatsTests {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    @Test func rangeGrowsWithHistory() {
        let today = day(2026, 10, 13)
        #expect(CaptureStats.range(firstDay: nil, today: today, calendar: cal) == .week)
        #expect(CaptureStats.range(firstDay: today, today: today, calendar: cal) == .week)
        #expect(CaptureStats.range(firstDay: day(2026, 10, 7), today: today, calendar: cal) == .week)      // 7 days
        #expect(CaptureStats.range(firstDay: day(2026, 10, 6), today: today, calendar: cal) == .month)     // 8 days
        #expect(CaptureStats.range(firstDay: day(2026, 9, 14), today: today, calendar: cal) == .month)     // 30 days
        #expect(CaptureStats.range(firstDay: day(2026, 9, 13), today: today, calendar: cal) == .quarter)   // 31 days
        #expect(CaptureStats.range(firstDay: day(2026, 7, 16), today: today, calendar: cal) == .quarter)   // 90 days
        #expect(CaptureStats.range(firstDay: day(2026, 7, 15), today: today, calendar: cal) == .halfYear)  // 91 days
        #expect(CaptureStats.range(firstDay: day(2026, 4, 17), today: today, calendar: cal) == .halfYear)  // 180 days
        #expect(CaptureStats.range(firstDay: day(2026, 4, 16), today: today, calendar: cal) == .year)
        #expect(CaptureStats.range(firstDay: day(2024, 1, 1), today: today, calendar: cal) == .year)
    }

    @Test func dailyBarsEndToday() {
        let today = day(2026, 10, 13, hour: 23)
        let counts: [Date: Int] = [day(2026, 10, 13): 3, day(2026, 10, 7): 2, day(2026, 10, 6): 9]
        let bars = CaptureStats.bars(counts: counts, range: .week, today: today, calendar: cal)
        #expect(bars.count == 7)
        #expect(bars.first!.start == cal.startOfDay(for: day(2026, 10, 7)))
        #expect(bars.last!.count == 3)
        #expect(bars.first!.count == 2)                       // Oct 6 falls outside the week
        #expect(bars.map(\.count).reduce(0, +) == 5)
    }

    @Test func weeklyAndMonthlyBars() {
        let today = day(2026, 10, 13)
        let counts: [Date: Int] = [day(2026, 10, 13): 1, day(2026, 10, 7): 1, day(2026, 10, 6): 4, day(2025, 11, 2): 5, day(2025, 10, 30): 7]
        let quarter = CaptureStats.bars(counts: counts, range: .quarter, today: today, calendar: cal)
        #expect(quarter.count == 13)
        #expect(quarter.last!.count == 2)                     // Oct 7–13
        #expect(quarter[quarter.count - 2].count == 4)        // Sep 30–Oct 6
        let year = CaptureStats.bars(counts: counts, range: .year, today: today, calendar: cal)
        #expect(year.count == 12)
        #expect(year.first!.start == cal.date(from: DateComponents(year: 2025, month: 11, day: 1)))
        #expect(year.first!.count == 5)                       // Oct 30, 2025 is too old
        #expect(year.last!.count == 6)
    }

    @Test func logRecordsTrimsAndTotals() {
        var log = ActivityLog()
        log.record("text", at: day(2026, 10, 13), calendar: cal)
        log.record("text", at: day(2026, 10, 13), calendar: cal)
        log.record("code", at: day(2026, 10, 12), calendar: cal)
        log.record("watch", at: day(2025, 1, 1), calendar: cal)
        #expect(log.firstDay == "2025-01-01")
        #expect(log.counts(kinds: ["text", "code"], calendar: cal)[cal.startOfDay(for: day(2026, 10, 13))] == 2)
        #expect(log.totals(since: day(2026, 10, 1), calendar: cal) == ["text": 2, "code": 1])
        log.trim(keepDays: 400, now: day(2026, 10, 13), calendar: cal)
        #expect(log.days["2025-01-01"] == nil)
        #expect(log.firstDay == "2025-01-01")
    }
}

@Suite struct ActivitySyncTests {
    @Test func combinesMacs() {
        let a = ActivityLog(firstDay: "2026-09-01", days: ["2026-10-12": ["text": 2, "code": 1], "2026-10-13": ["text": 1]])
        let b = ActivityLog(firstDay: "2026-08-15", days: ["2026-10-13": ["text": 4, "watch": 2]])
        let all = ActivityLog.combined([a, b])
        #expect(all.firstDay == "2026-08-15")
        #expect(all.days["2026-10-12"] == ["text": 2, "code": 1])
        #expect(all.days["2026-10-13"] == ["text": 5, "watch": 2])
    }

    @Test func combiningNothingIsEmpty() {
        #expect(ActivityLog.combined([]) == ActivityLog())
        #expect(ActivityLog.combined([ActivityLog()]).firstDay == nil)
    }

    @Test func lifetimeOutlivesTrimmedDays() {
        let cal = Calendar(identifier: .gregorian)
        let old = cal.date(from: DateComponents(year: 2024, month: 1, day: 5))!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 13))!
        var log = ActivityLog()
        log.record("text", at: old, calendar: cal)
        log.record("text", at: now, calendar: cal)
        log.record("code", at: now, calendar: cal)
        log.trim(now: now, calendar: cal)
        #expect(log.days.count == 1)
        #expect(log.lifetimeTotals == ["text": 2, "code": 1])
    }

    @Test func olderLogsStartLifetimeFromTheirDays() {
        // A 1.0.5 file has no lifetime: it counts its days, and keeps them on the next capture.
        var log = ActivityLog(firstDay: "2026-10-01", days: ["2026-10-01": ["text": 4], "2026-10-02": ["watch": 2]])
        #expect(log.lifetimeTotals == ["text": 4, "watch": 2])
        log.record("text")
        #expect(log.lifetime == ["text": 5, "watch": 2])
        let all = ActivityLog.combined([log, ActivityLog(days: ["2026-10-03": ["text": 1]])])
        #expect(all.lifetimeTotals == ["text": 6, "watch": 2])
    }

    @Test func deviceFileRoundTrips() throws {
        let record = DeviceActivity(deviceID: "abc", deviceName: "Test Mac", updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                    appVersion: "1.0.5", log: ActivityLog(firstDay: "2026-10-13", days: ["2026-10-13": ["text": 3]]))
        let data = try DeviceActivity.encoder.encode(record)
        #expect(try DeviceActivity.decoder.decode(DeviceActivity.self, from: data) == record)
    }

    @Test func syncKeyringUnlocksOnlyWithItsPassphrase() throws {
        let (keyring, key) = try SyncCrypto.createKeyring(passphrase: "correct horse", iterations: 1_000)
        let unwrapped = try SyncCrypto.unwrap(keyring, passphrase: "correct horse")
        #expect(SyncCrypto.keyID(for: unwrapped) == keyring.keyID)
        #expect(SyncCrypto.keyID(for: key) == keyring.keyID)
        #expect(throws: SyncCrypto.CryptoError.self) { try SyncCrypto.unwrap(keyring, passphrase: "wrong horse") }
    }

    @Test func sealedFilesHideTheirContents() throws {
        let key = SymmetricKey(size: .bits256)
        let plain = Data(String(repeating: "captureShortcut=⌃⌥⌘1 ", count: 40).utf8)
        let sealed = try SyncCrypto.seal(plain, using: key)
        #expect(sealed.prefix(4) == Data("TLE1".utf8))
        #expect(sealed.range(of: Data("captureShortcut".utf8)) == nil)
        #expect(try SyncCrypto.open(sealed, using: key) == plain)
        #expect(throws: SyncCrypto.CryptoError.self) { try SyncCrypto.open(sealed, using: SymmetricKey(size: .bits256)) }
        #expect(throws: SyncCrypto.CryptoError.self) { try SyncCrypto.open(plain, using: key) }
    }
}
