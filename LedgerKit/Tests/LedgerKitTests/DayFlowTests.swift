import XCTest
@testable import LedgerKit

/// a day's income and spending in each currency (the calendar's day sheet)
final class DayFlowTests: XCTestCase {
    func testFlowsByCurrency() {
        let L = loadLedger(root: "main.bean") { _ in """
        option "operating_currency" "CNY"
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Assets:Wise USD
        2026-01-01 open Assets:Receivable:Work CNY
        2026-01-01 open Expenses:Food
        2026-01-01 open Income:Rewards
        2026-01-01 open Income:Invest

        2026-10-14 * "Lunch"
          Expenses:Food   25.00 CNY
          Income:Rewards  -9.00 CNY
          Assets:Bank
        2026-10-14 * "Refund"
          Expenses:Food   -5.00 CNY
          Assets:Bank
        2026-10-14 * "Dividend"
          Income:Invest  -0.41 USD
          Assets:Wise
        2026-10-14 * "Advance for work"
          Assets:Receivable:Work  100.00 CNY
          Assets:Bank
        2026-10-14 * "Move"
          Assets:Wise  10.00 USD
          Assets:Bank  -70.00 CNY

        """ }
        XCTAssertTrue(L.errors.isEmpty, L.errors.map { $0.msg }.joined(separator: "; "))
        let f = flowsByCurrency(L.txns)
        // the lunch counts as spending (its reward is part of it, as classify reads it), the refund lowers it;
        // the advance and the transfer count as neither
        XCTAssertEqual(f, [CurrencyFlow(currency: "CNY", income: 0, expenses: 20),
                           CurrencyFlow(currency: "USD", income: 0.41, expenses: 0)])
        XCTAssertEqual(f[1].net, 0.41, accuracy: 0.0001)
    }
}
