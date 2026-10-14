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

    /// Fava's conversion menu: at cost, at market value, converted to one currency
    func testModes() {
        let L = ledger(text)
        // at cost: the share is 80 USD, and buying it leaves nothing in the conversions
        let cost = balanceSheet(L, at: "2026-03-31", mode: .cost)
        XCTAssertNil(cost.assets.shown.amounts["AAPL"])
        XCTAssertEqual(cost.assets.shown.amounts["USD"] ?? 0, 20 + 80, accuracy: 1e-6)
        XCTAssertEqual(cost.conversions.amounts["USD"] ?? 0, -(100 + 15), accuracy: 1e-6)
        XCTAssertNil(cost.conversions.amounts["AAPL"])
        // units are kept beside it, and so are the operating-currency totals
        XCTAssertEqual(cost.assets.balance.amounts["AAPL"] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(cost.netWorth, balanceSheet(L, at: "2026-03-31").netWorth, accuracy: 1e-6)
        // at market value: 90 USD; the 10 USD gain shows in the conversions
        let mv = balanceSheet(L, at: "2026-03-31", mode: .market)
        XCTAssertEqual(mv.assets.shown.amounts["USD"] ?? 0, 20 + 90, accuracy: 1e-6)
        XCTAssertEqual(mv.conversions.amounts["USD"] ?? 0, -(100 + 15) - 10, accuracy: 1e-6)
        // converted to USD at 7.2: everything in one currency, each side still balances with the conversions
        let usd = balanceSheet(L, at: "2026-03-31", mode: .convert("USD"))
        XCTAssertEqual(usd.assets.shown.byCurrency(base: "CNY").map { $0.currency }, ["USD"])
        let all = usd.assets.shown + usd.liabilities.shown + usd.equityByCurrency
        for (c, v) in all.amounts { XCTAssertEqual(v, 0, accuracy: 0.0001, c) }
        // the income statement too
        let inc = incomeStatement(L, from: "2026-01-01", to: "2026-03-31", mode: .convert("CNY"))
        XCTAssertEqual(inc.expenses.shown.amounts["CNY"] ?? 0, 30 + 15 * 7.2, accuracy: 1e-6)
        XCTAssertEqual(ReportMode(raw: "to:HKD"), .convert("HKD"))
        XCTAssertEqual(ReportMode(raw: ReportMode.market.raw), .market)
        XCTAssertEqual(ReportMode(raw: "x"), .units)
    }

    func testInventoryHelpers() {
        var a = Inventory(); a.add(1, "USD"); a.add(2, "CNY"); a.add(0.001, "EUR")
        var b = Inventory(); b.add(-1, "USD"); b.add(3, "HKD")
        let s = a + b
        XCTAssertEqual(s.byCurrency(base: "CNY").map { $0.currency }, ["CNY", "HKD"])
        XCTAssertEqual((-s).amounts["CNY"], -2)
    }
}
