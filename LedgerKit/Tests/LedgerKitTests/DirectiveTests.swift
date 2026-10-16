import XCTest
@testable import LedgerKit

/// note and Beancount's own event directive: written by the app, read back as written
final class DirectiveTests: XCTestCase {
    func ledger(_ text: String) -> Ledger {
        loadLedger(root: "main.bean") { _ in text }
    }

    func testLifeEvents() {
        let L = ledger("""
        2024-01-01 open Assets:Bank:Main
        2025-07-01 event "location" "广州"
        2024-03-01 event "location" "深圳"
        2024-03-01 event "employer" "星河"
        2026-01-01 event "location" "深圳"
        """)
        let ev = lifeEvents(L)
        XCTAssertEqual(ev.map { $0.type }, ["location", "employer"])
        let loc = ev[0]
        XCTAssertEqual(loc.spans.map { $0.value }, ["深圳", "广州", "深圳"], "latest first")
        XCTAssertEqual(loc.spans.map { $0.start }, ["2026-01-01", "2025-07-01", "2024-03-01"])
        XCTAssertEqual(loc.spans.map { $0.end }, [nil, "2025-12-31", "2025-06-30"])
        XCTAssertEqual(loc.current?.value, "深圳")
        XCTAssertEqual(ev[1].current?.value, "星河")
    }

    func testTextReadsBack() {
        let n = noteText(date: "2024-03-05", account: "Assets:Bank:Main", comment: "说 \"明天\" 到账\n\\ 再查")
        let e = lifeEventText(date: "2024-03-01", type: "location", value: "深圳 \"南山\"")
        let L = ledger("2024-01-01 open Assets:Bank:Main\n" + n + "\n" + e + "\n")
        XCTAssertTrue(L.errors.isEmpty, L.errors.map { $0.msg }.joined())
        XCTAssertEqual(L.notes.first?.comment, "说 \"明天\" 到账 \\ 再查")
        XCTAssertEqual(L.events.first?.eventDescription, "深圳 \"南山\"")
    }

    func testWhereTheyGo() {
        let L = loadSet("realistic")
        let note = Entry(type: .note, date: "2026-01-01", file: "", line: 0, startLine: 0, endLine: 0)
        note.account = "Assets:Bank:CGB"
        let balanceFile = Dictionary(grouping: L.balances, by: { $0.file }).max { $0.value.count < $1.value.count }?.key
        if L.notes.isEmpty { XCTAssertEqual(fileFor(note, L), balanceFile) }
        let ev = Entry(type: .event, date: "2026-01-01", file: "", line: 0, startLine: 0, endLine: 0)
        if L.events.isEmpty && L.notes.isEmpty { XCTAssertEqual(fileFor(ev, L), RepoLayout().journalPath("2026-01-01")) }
    }
}
