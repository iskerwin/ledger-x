import XCTest
@testable import LedgerKit

/// events (#tag + custom "event") and the unusual-spending alerts
final class EventsTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private let base = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank CNY
    2026-01-01 open Assets:Receivable:Reimbursement CNY
    2026-01-01 open Expenses:Food CNY
    2026-01-01 open Expenses:Travel CNY
    2026-01-01 open Expenses:Shopping CNY
    2026-01-01 open Income:Salary CNY
    2026-01-01 open Equity:Opening

    2026-01-02 * "Opening"
      Assets:Bank  100000.00 CNY
      Equity:Opening

    2026-08-03 custom "event" "zhengzhou-2026" "郑州出差"

    2026-08-04 * "酒店" "住宿" #zhengzhou-2026
      Expenses:Travel  300.00 CNY
      Assets:Bank

    2026-08-05 * "五金店" "工具" #zhengzhou-2026 #reimbursed ^reimburse-co-20260901
      Assets:Receivable:Reimbursement  50.00 CNY
      Assets:Bank

    2026-08-06 * "面馆" "午餐" #zhengzhou-2026 #reimbursed
      Assets:Receivable:Reimbursement  20.00 CNY
      Assets:Bank

    2026-08-07 * "面馆" "晚餐"
      Expenses:Food  25.00 CNY
      Assets:Bank

    2026-05-01 * "店" "旧" #old-trip
      Expenses:Food  10.00 CNY
      Assets:Bank

    2026-05-03 * "店" "旧" #old-trip
      Expenses:Food  10.00 CNY
      Assets:Bank

    """

    func testEvents() {
        let L = ledger(base)
        let evs = ledgerEvents(L, today: "2026-08-10")
        XCTAssertEqual(evs.map { $0.tag }, ["zhengzhou-2026", "old-trip"])
        XCTAssertEqual(evs[0].title, "郑州出差")
        XCTAssertNil(evs[0].end)
        XCTAssertTrue(evs[0].ongoing("2026-08-10"))
        XCTAssertEqual(evs[1].start, "2026-05-01")
        XCTAssertEqual(evs[1].end, "2026-05-03")
        XCTAssertEqual(activeEvents(L, on: "2026-08-10").map { $0.tag }, ["zhengzhou-2026"])
        XCTAssertEqual(activeEvents(L, on: "2026-08-01").count, 0)

        let s = eventSummary(L, "zhengzhou-2026", openLinks: ["reimburse-co-20260901"])
        XCTAssertEqual(s.spent, 300)
        XCTAssertEqual(s.advanced, 70)
        XCTAssertEqual(s.unpaid, 70)
        XCTAssertEqual(s.txns.count, 3)
        XCTAssertEqual(eventSummary(L, "zhengzhou-2026").unpaid, 20)   // the linked claim was paid back
        XCTAssertEqual(eventCandidates(L, evs[0], today: "2026-08-10").map { $0.narration }, ["晚餐"])

        // ended: the directive gets the last day
        let ended = ledger(base.replacingOccurrences(of: "\"郑州出差\"\n", with: "\"郑州出差\" 2026-08-06\n"))
        let e = ledgerEvents(ended, today: "2026-08-10")[0]
        XCTAssertEqual(e.end, "2026-08-06")
        XCTAssertFalse(e.ongoing("2026-08-10"))
        XCTAssertEqual(eventLine(tag: "a-2026", title: "A", start: "2026-01-01", end: "2026-01-05"), "2026-01-01 custom \"event\" \"a-2026\" \"A\" 2026-01-05")
        XCTAssertTrue(validateText(eventLine(tag: "a-2026", title: "A", start: "2026-01-01", end: "2026-01-05"), L, single: false).ok)
        let tag = eventTag("郑州出差", year: "2026")
        XCTAssertTrue(tag.hasPrefix("zhengzhou") && tag.hasSuffix("-2026") && isValidTag(tag), tag)
    }

    func testDraftGetsEventTags() {
        let L = ledger(base)
        let D = Derived(L, today: "2026-08-10")
        var d = Draft()
        d.kind = .expense; d.date = "2026-08-10"; d.account = "Expenses:Food"; d.funding = "Assets:Bank"; d.amount = "12"
        d.events = ["zhengzhou-2026"]
        XCTAssertTrue(draftText(d, L, D).hasPrefix("2026-08-10 * \"\" \"\" #zhengzhou-2026"), draftText(d, L, D))
        d.kind = .transfer; d.to = "Assets:Receivable:Reimbursement"
        XCTAssertFalse(draftText(d, L, D).contains("#zhengzhou"))
    }

    func testAnomalies() throws {
        let L = ledger(base + """
        2026-08-08 * "超市" "买菜"
          Expenses:Food  88.00 CNY
          Assets:Bank

        2026-08-08 * "超市" "买菜"
          Expenses:Food  88.00 CNY
          Assets:Bank

        2026-08-09 * "电器城" "电视"
          Expenses:Shopping  3999.00 CNY
          Assets:Bank

        """ + (2...7).map { m in "2026-0\(m)-15 * \"店\" \"吃饭\"\n  Expenses:Food  100.00 CNY\n  Assets:Bank\n\n" }.joined()
          + "2026-08-09 * \"餐厅\" \"聚餐\"\n  Expenses:Food  600.00 CNY\n  Assets:Bank\n")
        let a = anomalies(L, today: "2026-08-10", subs: [])
        XCTAssertEqual(Set(a.map { $0.kind }), [.duplicate, .large, .category])
        let copies = try XCTUnwrap(a.first { $0.kind == .duplicate }?.entries)
        XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(entrySignature(copies[0]), entrySignature(copies[1]))
        XCTAssertNotEqual(copies[0].startLine, copies[1].startLine)
        // confirming the alert only stores its id; each copy can still be told apart by the line it occupies
        XCTAssertEqual(copies.map { EntryLocator($0).resolve(in: L.entries)?.startLine }, copies.map { Optional($0.startLine) })
        XCTAssertEqual(a.first { $0.kind == .large }?.entries.first?.narration, "电视")
        XCTAssertEqual(a.first { $0.kind == .category }?.subject, "Expenses:Food")
        // ids don't change between loads
        XCTAssertEqual(a.map { $0.id }, anomalies(L, today: "2026-08-10", subs: []).map { $0.id })
        XCTAssertFalse(anomalies(L, today: "2026-08-10", settings: AnomalySettings(large: 0), subs: []).contains { $0.kind == .large })
    }
}
