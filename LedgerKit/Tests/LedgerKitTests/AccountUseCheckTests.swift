import XCTest
@testable import LedgerKit

/// A form is checked against the accounts' open lines as the whole ledger is: currency, opening and closing day.
/// These can't be 仍然提交: bean-check rejects them whatever the reason.
final class AccountUseCheckTests: XCTestCase {
    private let ledger = """
    2020-01-01 open Assets:Bank:DemoBank CNY
    2020-01-01 open Liabilities:CreditCard:DemoUS USD
    2026-06-01 open Assets:Bank:DemoNew CNY
    2020-01-01 open Assets:Bank:DemoOld CNY
    2026-03-31 close Assets:Bank:DemoOld
    2020-01-01 open Expenses:Shopping
    2020-01-01 open Equity:Opening-Balances
    2020-01-02 * "Opening"
      Assets:Bank:DemoBank       1000.00 CNY
      Equity:Opening-Balances

    """

    private func entry(_ date: String, from account: String, _ currency: String = "CNY") -> String {
        """
        \(date) * "Demo shop"
          Expenses:Shopping          12.00 \(currency)
          \(account)                -12.00 \(currency)
        """
    }

    func testTheFormCheckSeesCurrencyAndOpenAndCloseDays() {
        let L = loadLedger(root: "main.bean") { _ in self.ledger }
        XCTAssertTrue(checkText(entry("2026-10-20", from: "Assets:Bank:DemoBank"), L).ok)
        let currency = checkText(entry("2026-10-20", from: "Liabilities:CreditCard:DemoUS"), L)
        XCTAssertFalse(currency.ok)
        XCTAssertTrue(currency.errors.contains { $0.accountMisuse && $0.msg.contains("CNY") })
        XCTAssertFalse(checkText(entry("2026-05-01", from: "Assets:Bank:DemoNew"), L).ok, "before the account opened")
        XCTAssertFalse(checkText(entry("2026-10-20", from: "Assets:Bank:DemoOld"), L).ok, "after the account closed")
        XCTAssertTrue(checkText(entry("2026-03-01", from: "Assets:Bank:DemoOld"), L).ok)
    }

    func testOnlyAccountMisuseBlocksSubmitting() {
        let before = loadLedger(root: "main.bean") { _ in self.ledger }
        let misuse = loadLedger(root: "main.bean") { _ in self.ledger + self.entry("2026-10-20", from: "Liabilities:CreditCard:DemoUS") }
        let issues = reviewChange(before: before, after: misuse)
        XCTAssertFalse(issues.isEmpty)
        XCTAssertTrue(issues.allSatisfy { $0.blocking })
        // spending more than the account holds is the user's call: it can still be submitted
        let overdraw = loadLedger(root: "main.bean") { _ in self.ledger + """
            2026-10-20 * "Demo shop"
              Expenses:Shopping        5000.00 CNY
              Assets:Bank:DemoBank    -5000.00 CNY
            """ }
        let low = reviewChange(before: before, after: overdraw)
        XCTAssertEqual(low.map(\.kind), [.insufficient])
        XCTAssertFalse(low.contains { $0.blocking })
    }
}
