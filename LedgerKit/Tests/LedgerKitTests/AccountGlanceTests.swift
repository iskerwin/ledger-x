import XCTest
@testable import LedgerKit

final class AccountGlanceTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger {
        loadLedger(root: "main.bean") { _ in text }
    }

    private let text = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank:CMB
    2026-01-01 open Assets:Wallet:Wise
    2026-01-01 open Expenses:Food CNY
    2026-01-01 open Income:Salary
    2026-01-01 open Equity:Opening

    2026-09-20 * "Opening"
      Assets:Bank:CMB  500.00 CNY
      Equity:Opening

    2026-10-02 * "Salary"
      Assets:Bank:CMB  1000.00 CNY
      Income:Salary

    2026-10-05 * "Lunch"
      Assets:Bank:CMB  -30.00 CNY
      Expenses:Food

    2026-10-05 * "Lunch, in dollars"
      Assets:Wallet:Wise  -5.00 USD
      Expenses:Food  36.00 CNY

    2026-10-06 balance Assets:Bank:CMB 1470.00 CNY
    2026-10-20 balance Assets:Bank:CMB 1470.00 CNY

    2026-11-03 * "Later"
      Assets:Bank:CMB  -100.00 CNY
      Expenses:Food
    """

    func testTheLatestCheckThisMonthsFlowAndTheDailyBalances() {
        let g = accountGlance(ledger(text), "Assets:Bank", currency: "CNY", today: "2026-10-31", days: 30)
        XCTAssertEqual(g.lastCheck, "2026-10-20")
        XCTAssertEqual(g.inflow, 1000, accuracy: 0.001)
        XCTAssertEqual(g.outflow, 30, accuracy: 0.001)
        XCTAssertEqual(g.trend.count, 30)
        // 10-02 is the first of the 30 days: the salary that day is in its end-of-day balance
        XCTAssertEqual(g.trend.first ?? 0, 1500, accuracy: 0.001)
        XCTAssertEqual(g.trend[2], 1500, accuracy: 0.001)
        XCTAssertEqual(g.trend[3], 1470, accuracy: 0.001)
        // what comes after today is left out
        XCTAssertEqual(g.trend.last ?? 0, 1470, accuracy: 0.001)
    }

    func testOnlyTheCurrencyAskedForCounts() {
        let L = ledger(text)
        let usd = accountGlance(L, "Assets:Wallet:Wise", currency: "USD", today: "2026-10-31")
        XCTAssertEqual(usd.outflow, 5, accuracy: 0.001)
        XCTAssertEqual(usd.trend.last ?? 0, -5, accuracy: 0.001)
        let cny = accountGlance(L, "Assets:Wallet:Wise", currency: "CNY", today: "2026-10-31")
        XCTAssertEqual(cny.outflow, 0)
        XCTAssertNil(cny.lastCheck)
    }

    func testAMonthWithNothingYetStartsAtZeroAndCarriesTheBalance() {
        let g = accountGlance(ledger(text), "Assets:Bank:CMB", currency: "CNY", today: "2026-12-10", days: 7)
        XCTAssertEqual(g.inflow, 0)
        XCTAssertEqual(g.outflow, 0)
        XCTAssertEqual(g.trend, Array(repeating: 1370, count: 7))
    }
}
