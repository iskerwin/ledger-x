import XCTest
@testable import LedgerKit

/// an account's months: what moved in each, what it held at the end, the latest first
final class AccountMonthsTests: XCTestCase {
    func testEachMonthItMovedInWithWhatItHeldAtTheEnd() {
        let L = loadLedger(root: "main.bean") { _ in """
        2026-01-01 open Assets:Bank CNY,USD
        2026-01-01 open Assets:Bank:Saving CNY
        2026-01-01 open Expenses:Food CNY
        2026-01-01 open Income:Salary CNY,USD

        2026-01-05 * "工资"
          Income:Salary  -100.00 CNY
          Assets:Bank  100.00 CNY

        2026-01-20 * "饭"
          Expenses:Food  30.00 CNY
          Assets:Bank:Saving  -30.00 CNY

        2026-03-02 * "奖金"
          Income:Salary  -10.00 USD
          Assets:Bank  10.00 USD

        2026-03-03 * "饭"
          Expenses:Food  5.00 CNY
          Assets:Bank  -5.00 CNY
        """ }
        let months = accountMonths(L, account: "Assets:Bank")
        // February moved nothing
        XCTAssertEqual(months.map(\.month), ["2026-03", "2026-01"])
        XCTAssertEqual(months[1].change.amounts, ["CNY": 70])
        XCTAssertEqual(months[1].end.amounts, ["CNY": 70])
        XCTAssertEqual(months[0].change.amounts, ["USD": 10, "CNY": -5])
        XCTAssertEqual(months[0].end.amounts, ["CNY": 65, "USD": 10])
        XCTAssertTrue(accountMonths(L, account: "Assets:Cash").isEmpty)
    }
}
