import CoreGraphics
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
