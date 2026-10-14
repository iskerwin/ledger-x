import XCTest
@testable import LedgerKit

/// reports by currency: each currency balances by itself once Equity:Conversions is counted
final class ReportCurrencyTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private let text = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank CNY
    2026-01-01 open Assets:Bank:USD USD
    2026-01-01 open Assets:Broker:Stock AAPL
    2026-01-01 open Liabilities:CreditCard CNY
    2026-01-01 open Equity:Opening
    2026-01-01 open Income:Salary
    2026-01-01 open Expenses:Food
    2026-01-01 open Expenses:Travel
    2026-01-02 * "期初"
      Assets:Bank  1000.00 CNY
      Equity:Opening
    2026-02-01 * "工资"
      Assets:Bank  5000.00 CNY
      Income:Salary
    2026-02-03 * "换汇"
      Assets:Bank:USD  100.00 USD @ 7.00 CNY
      Assets:Bank  -700.00 CNY
    2026-02-05 * "买股票"
      Assets:Broker:Stock  1 AAPL {80.00 USD}
      Assets:Bank:USD  -80.00 USD
    2026-02-06 * "旅行"
      Expenses:Travel  15.00 USD
      Liabilities:CreditCard  -108.00 CNY @@ 15.00 USD
    2026-02-07 * "午饭"
      Expenses:Food  30.00 CNY
      Liabilities:CreditCard
    2026-03-01 price USD 7.20 CNY
    2026-03-01 price AAPL 90.00 USD

    """

    func testConversionsBalanceEachCurrency() {
        let L = ledger(text)
        let bs = balanceSheet(L, at: "2026-03-31")
        // as booked: CNY, USD and shares (as units)
        let assets = bs.assets.balance.byCurrency(base: "CNY")
        XCTAssertEqual(assets.map { $0.currency }, ["CNY", "AAPL", "USD"])
        XCTAssertEqual(bs.assets.balance.amounts["AAPL"] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(bs.assets.balance.amounts["USD"] ?? 0, 20, accuracy: 1e-9)
        // every currency: assets + liabilities + equity (with earnings and conversions) = 0
        let all = bs.assets.balance + bs.liabilities.balance + bs.equityByCurrency
        for (c, v) in all.amounts { XCTAssertEqual(v, 0, accuracy: 0.0001, c) }
        // the conversions: CNY into USD at 7, USD into shares at cost, a CNY card paying a USD expense
        let conv = bs.conversions
        XCTAssertEqual(conv.amounts["CNY"] ?? 0, 700 + 108, accuracy: 1e-6)
        XCTAssertEqual(conv.amounts["USD"] ?? 0, -(100 - 80 + 15), accuracy: 1e-6)
        XCTAssertEqual(conv.amounts["AAPL"] ?? 0, -1, accuracy: 1e-6)
        // earnings by currency: 5000 CNY income, 30 CNY and 15 USD spent
        XCTAssertEqual(bs.earningsByCurrency.amounts["CNY"] ?? 0, -5000 + 30, accuracy: 1e-6)
        XCTAssertEqual(bs.earningsByCurrency.amounts["USD"] ?? 0, 15, accuracy: 1e-6)
        // before anything was converted there is nothing to show
        XCTAssertTrue(conversions(L, to: "2026-02-01").byCurrency(base: "CNY").isEmpty)
    }

    func testInventoryHelpers() {
        var a = Inventory(); a.add(1, "USD"); a.add(2, "CNY"); a.add(0.001, "EUR")
        var b = Inventory(); b.add(-1, "USD"); b.add(3, "HKD")
        let s = a + b
        XCTAssertEqual(s.byCurrency(base: "CNY").map { $0.currency }, ["CNY", "HKD"])
        XCTAssertEqual((-s).amounts["CNY"], -2)
    }
}
