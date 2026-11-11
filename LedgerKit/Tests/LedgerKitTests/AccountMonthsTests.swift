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

    func testMonthColumnsShowWhatMovedOrWhatWasHeldEachMonth() {
        let L = loadLedger(root: "main.bean") { _ in """
        option "operating_currency" "CNY"
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Expenses:Food:Lunch CNY
        2026-01-01 open Expenses:Food:Dinner CNY
        2026-01-01 open Expenses:Rent CNY

        2026-01-05 * "午饭"
          Expenses:Food:Lunch  20.00 CNY
          Assets:Bank  -20.00 CNY

        2026-02-05 * "晚饭"
          Expenses:Food:Dinner  50.00 CNY
          Assets:Bank  -50.00 CNY

        2026-02-06 * "房租"
          Expenses:Rent  1000.00 CNY
          Assets:Bank  -1000.00 CNY
        """ }
        let moved = monthColumns(L, months: ["2026-01", "2026-02"], roots: ["Expenses"], held: false)
        XCTAssertEqual(moved.value("Expenses:Food", "2026-01"), 20)
        XCTAssertEqual(moved.value("Expenses:Food", "2026-02"), 50)
        XCTAssertEqual(moved.value("Expenses:Rent", "2026-01"), 0)
        XCTAssertEqual(moved.value("Expenses", "2026-02"), 1050)
        // the shape has every account of every month: Dinner only moved in February, Lunch only in January
        let food = moved.roots[0].children.first { $0.name == "Expenses:Food" }
        XCTAssertEqual(food?.children.map(\.name).sorted(), ["Expenses:Food:Dinner", "Expenses:Food:Lunch"])
        let held = monthColumns(L, months: ["2026-01", "2026-02"], roots: ["Assets"], held: true)
        XCTAssertEqual(held.value("Assets:Bank", "2026-01"), -20)
        XCTAssertEqual(held.value("Assets:Bank", "2026-02"), -1070)
    }
}
