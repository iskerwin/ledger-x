import XCTest
@testable import LedgerKit

final class BudgetTests: XCTestCase {
    /// A budget in another currency than the ledger's counts spending in every currency, converted on the day:
    /// a USD food budget sees 72 CNY (10 USD at 7.20) and 86.40 CNY worth of EUR (12 USD), not only the 5 USD.
    func testABudgetInAnotherCurrencyCountsEveryCurrencysSpending() throws {
        let L = loadLedger(root: "main.bean") { _ in """
        option "operating_currency" "CNY"
        2026-01-01 open Assets:Cash
        2026-01-01 open Expenses:Food
        2026-01-01 custom "budget" Expenses:Food "monthly" 100.00 USD
        2026-09-01 price USD 7.20 CNY
        2026-09-01 price EUR 8.64 CNY
        2026-09-05 * "Shop" "in CNY"
          Expenses:Food   72.00 CNY
          Assets:Cash
        2026-09-06 * "Shop" "in USD"
          Expenses:Food   5.00 USD
          Assets:Cash
        2026-09-07 * "Shop" "in EUR"
          Expenses:Food   10.00 EUR
          Assets:Cash
        """ }
        XCTAssertEqual(L.base, "CNY")
        let food = try XCTUnwrap(budgetProgress(L, key: "2026-09", today: "2026-09-30").first)
        XCTAssertEqual(food.spent, 27, accuracy: 0.005)
    }

    /// The page's total adds the spending budgets only: an income target isn't money to spend, and amounts in two
    /// currencies don't add up, so then there is no total at all.
    func testTheBudgetTotalAddsSpendingBudgetsInOneCurrency() throws {
        func ledger(_ second: String) -> Ledger {
            loadLedger(root: "main.bean") { _ in """
            2026-01-01 open Assets:Cash
            2026-01-01 open Expenses:Food
            2026-01-01 open Expenses:Home
            2026-01-01 open Income:Salary
            2026-01-01 custom "budget" Expenses:Food "monthly" 1000.00 CNY
            2026-01-01 custom "budget" Income:Salary "monthly" 9000.00 CNY
            \(second)
            2026-09-05 * "Shop" "food"
              Expenses:Food   1200.00 CNY
              Assets:Cash
            """ }
        }
        let same = try XCTUnwrap(budgetTotal(budgetProgress(ledger("2026-01-01 custom \"budget\" Expenses:Home \"monthly\" 500.00 CNY"), key: "2026-09", today: "2026-09-30")))
        XCTAssertEqual(same.currency, "CNY")
        XCTAssertEqual(same.limit, 1500, accuracy: 0.005)
        XCTAssertEqual(same.spent, 1200, accuracy: 0.005)
        XCTAssertEqual(same.remaining, 300, accuracy: 0.005)
        XCTAssertNil(budgetTotal(budgetProgress(ledger("2026-01-01 custom \"budget\" Expenses:Home \"monthly\" 500.00 USD"), key: "2026-09", today: "2026-09-30")))
        XCTAssertNil(budgetTotal([]))
    }

    /// Over budget, the page says which spending did most of it: the biggest transaction in the span, by payee
    /// (or the narration when there is none), in the budget's currency.
    func testAnOverspentBudgetKnowsItsBiggestSpending() throws {
        let L = loadLedger(root: "main.bean") { _ in """
        2026-01-01 open Assets:Cash
        2026-01-01 open Expenses:Home
        2026-01-01 custom "budget" Expenses:Home "monthly" 3000.00 CNY
        2026-10-01 * "房东" "十月房租"
          Expenses:Home   4500.00 CNY
          Assets:Cash
        2026-10-05 * "" "灯泡"
          Expenses:Home     36.00 CNY
          Assets:Cash
        """ }
        let home = try XCTUnwrap(budgetProgress(L, key: "2026-10", today: "2026-10-31").first)
        XCTAssertTrue(home.over)
        XCTAssertEqual(home.biggest?.what, "房东")
        XCTAssertEqual(home.biggest?.amount, 4500)
        XCTAssertEqual(home.biggest?.date, "2026-10-01")
    }
}
