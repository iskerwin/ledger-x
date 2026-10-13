import XCTest
@testable import LedgerKit

/// 明细搜索: words, fields, negation, amounts and Fava-style date ranges
final class SearchTests: XCTestCase {
    private let L: Ledger = loadLedger(root: "main.bean") { _ in """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank:CMB CNY
      name: "招商银行"
    2026-01-01 open Assets:Receivable:Personal
    2026-01-01 open Expenses:Food:Dining
    2026-01-01 open Expenses:Transit:Taxi

    2026-06-30 * "饭店" "晚饭 和 同事"
      Expenses:Food:Dining  120.00 CNY
      Assets:Bank:CMB
    2026-07-15 * "滴滴" "打车" #trip
      Expenses:Transit:Taxi  35.00 CNY
      Assets:Bank:CMB
    2026-08-02 * "饭店" "午饭"
      Expenses:Food:Dining  50.00 CNY
      Assets:Receivable:Personal  50.00 CNY
        person: "王五"
      Assets:Bank:CMB
    2026-09-20 ! "滴滴" "加班打车"
      Expenses:Transit:Taxi  210.00 CNY
      Assets:Bank:CMB

    """ }

    private func hits(_ q: String) -> [String] { L.txns.filter { TxQuery(q).matches($0) }.map { $0.date } }

    func testDates() {
        XCTAssertEqual(hits("2026-07"), ["2026-07-15"])
        // Fava's range, a tilde, two dots, or two dates side by side
        XCTAssertEqual(hits("2026-07 - 2026-08"), ["2026-07-15", "2026-08-02"])
        XCTAssertEqual(hits("2026-07~2026-08"), ["2026-07-15", "2026-08-02"])
        XCTAssertEqual(hits("2026-07..2026-08"), ["2026-07-15", "2026-08-02"])
        XCTAssertEqual(hits("2026-07 2026-08"), ["2026-07-15", "2026-08-02"])
        XCTAssertEqual(hits("2026-08 2026-07"), ["2026-07-15", "2026-08-02"])
        XCTAssertEqual(hits("2026-Q3"), ["2026-07-15", "2026-08-02", "2026-09-20"])
        XCTAssertEqual(hits("2026-06-30"), ["2026-06-30"])
        XCTAssertEqual(hits("2026 - 2026"), L.txns.map { $0.date })
        XCTAssertEqual(TxQuery("2026-07 2026-08").dateSpan?.0, "2026-07-01")
        XCTAssertEqual(TxQuery("2026-07 2026-08").dateSpan?.1, "2026-08-31")
    }

    func testCombined() {
        // a month and an account (its Chinese group name works too)
        XCTAssertEqual(hits("2026-07~2026-09 Taxi"), ["2026-07-15", "2026-09-20"])
        XCTAssertEqual(hits("2026-08 餐饮"), ["2026-08-02"])
        XCTAssertEqual(hits("科目:Dining"), ["2026-06-30", "2026-08-02"])
        XCTAssertEqual(hits("账户：CMB 2026-09"), ["2026-09-20"])
        // by the account's name: too, when the ledger is given
        XCTAssertEqual(L.txns.filter { TxQuery("账户:招商 2026-09").matches($0, L) }.map { $0.date }, ["2026-09-20"])
        // fields keep to their part: "饭" is in the payee and in a note
        XCTAssertEqual(hits("payee:饭店"), ["2026-06-30", "2026-08-02"])
        XCTAssertEqual(hits("备注:午饭"), ["2026-08-02"])
        XCTAssertEqual(hits("对方:王五"), ["2026-08-02"])
        XCTAssertEqual(hits("王五"), ["2026-08-02"])
        // a phrase with a space, and leaving things out
        XCTAssertEqual(hits("\"和 同事\""), ["2026-06-30"])
        XCTAssertEqual(hits("滴滴 -加班"), ["2026-07-15"])
        XCTAssertEqual(hits("-#trip 滴滴"), ["2026-09-20"])
        // amounts
        XCTAssertEqual(hits(">200"), ["2026-09-20"])
        XCTAssertEqual(hits("30~60"), ["2026-07-15", "2026-08-02"])
        XCTAssertEqual(hits("35"), ["2026-07-15"])
        XCTAssertEqual(hits("! 滴滴"), ["2026-09-20"])
        XCTAssertEqual(hits("#trip"), ["2026-07-15"])
        XCTAssertTrue(TxQuery("  ").isEmpty)
        XCTAssertTrue(TxQuery("-").isEmpty)
    }
}
