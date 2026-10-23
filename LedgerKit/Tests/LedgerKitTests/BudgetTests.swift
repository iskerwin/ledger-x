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
}
