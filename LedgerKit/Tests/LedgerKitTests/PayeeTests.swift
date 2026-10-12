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
