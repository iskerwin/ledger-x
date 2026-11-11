import XCTest
@testable import LedgerKit

/// renaming and merging payees: only the payee on headers and `payee:` metadata changes
final class PayeeTests: XCTestCase {
    private let text = """
    2026-09-01 * "高德打车" "郑州出差" #reimbursed ^float-co-20260831
      Assets:Receivable:Reimbursement  9.59 CNY
      Assets:Bank  -9.59 CNY

    2026-09-02 * "高德地图打车" "打车 高德打车"
      Expenses:Transit  12.00 CNY
      Assets:Bank  -12.00 CNY

    2026-09-03 * "高德打车"
      Expenses:Transit  8.00 CNY
      Assets:Bank  -8.00 CNY

    2026-09-04 ! "Say \\"hi\\"" "x"
      Expenses:Transit  1.00 CNY
      Assets:Bank  -1.00 CNY

    2024-09-21 custom "subscription" "高德会员" "monthly" 15.00 CNY
      payee: "高德打车"
    """

    func testSummariesCountEachPayeeOnAHeaderMostUsedFirst() {
        let L = loadLedger(root: "main.bean") { _ in """
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Expenses:Transit CNY
        2026-01-01 open Income:Salary CNY

        2026-09-02 * "Taxi" "ride"
          Expenses:Transit  12.00 CNY
          Assets:Bank  -12.00 CNY

        2026-09-03 * "Taxi" "home"
          Expenses:Transit  8.00 CNY
          Assets:Bank  -8.00 CNY

        2026-09-04 * "Bus" "work"
          Expenses:Transit  2.00 CNY
          Assets:Bank  -2.00 CNY

        2026-09-05 * "Employer" "pay"
          Assets:Bank  100.00 CNY
          Income:Salary  -100.00 CNY

        2026-09-06 * "" "no payee"
          Expenses:Transit  1.00 CNY
          Assets:Bank  -1.00 CNY
        """ }
        let all = payeeSummaries(L)
        XCTAssertEqual(all.map(\.name), ["Taxi", "Bus", "Employer"])
        XCTAssertEqual(all[0].n, 2)
        XCTAssertEqual(all[0].last, "2026-09-03")
        XCTAssertEqual(all[0].spent, 20, accuracy: 0.001)
        XCTAssertEqual(all[2].received, 100, accuracy: 0.001)
        // a span keeps to what fell in it
        let some = payeeSummaries(L, span: ("2026-09-03", "2026-09-04"))
        XCTAssertEqual(some.map(\.name), ["Bus", "Taxi"])
        XCTAssertEqual(some[1].n, 1)
        XCTAssertEqual(some[1].spent, 8, accuracy: 0.001)
    }

    func testRename() {
        XCTAssertEqual(countPayee(text, "高德打车"), 2)   // the header with a payee, and the subscription
        let r = renamePayee(text, from: "高德打车", to: "高德地图打车")
        XCTAssertTrue(r.contains("2026-09-01 * \"高德地图打车\" \"郑州出差\" #reimbursed ^float-co-20260831"), r)
        XCTAssertTrue(r.contains("  payee: \"高德地图打车\""), r)
        // a narration that mentions the name, and a header with only a narration, stay as they are
        XCTAssertTrue(r.contains("\"打车 高德打车\""), r)
        XCTAssertTrue(r.contains("2026-09-03 * \"高德打车\"\n"), r)
        XCTAssertEqual(countPayee(r, "高德地图打车"), 3)
        // quotes inside a payee
        XCTAssertEqual(countPayee(text, "Say \"hi\""), 1)
        let q = renamePayee(text, from: "Say \"hi\"", to: "Hello")
        XCTAssertTrue(q.contains("2026-09-04 ! \"Hello\" \"x\""), q)
        // through the queue, as the app writes it
        var op = Op(kind: .renamePayee, path: "a.bean")
        op.old = "高德打车"; op.text = "高德地图打车"
        XCTAssertEqual(try applyOps(text, path: "a.bean", ops: [op]), r)
    }
}
