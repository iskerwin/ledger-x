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

    /// the currency switches: held currencies on, the rest off; filtering and valuing together
    func testCurrencyView() {
        let L = ledger(text + """
        2026-01-01 open Assets:Cash:MOP MOP
        2026-03-02 * "换澳门元"
          Assets:Cash:MOP  10.00 MOP @ 0.90 CNY
          Assets:Bank  -9.00 CNY
        2026-03-03 * "花完"
          Expenses:Food  10.00 MOP @ 0.90 CNY
          Assets:Cash:MOP  -10.00 MOP

        """)
        XCTAssertEqual(ledgerCurrencies(L).first, "CNY")
        XCTAssertEqual(ledgerCurrencies(L).last, "MOP")     // not held: after the held ones
        XCTAssertEqual(heldCurrencies(L), ["CNY", "USD", "AAPL"])
        var v = CurrencyView()
        XCTAssertTrue(v.isDefault)
        XCTAssertEqual(v.mode(L), .convert("CNY"))
        XCTAssertEqual(v.selected(L), ["CNY", "USD", "AAPL"])
        XCTAssertNotNil(v.only(L))                           // MOP is off
        XCTAssertNil(v.label(L))
        v.toggle("MOP", L)
        XCTAssertNil(v.only(L))
        v.toggle("USD", L)
        XCTAssertEqual(v.selected(L), ["CNY", "AAPL", "MOP"])
        v.solo("USD", L)
        XCTAssertEqual(v.selected(L), ["USD"])
        v.modeRaw = ReportMode.units.raw
        XCTAssertEqual(v.label(L), "USD · " + ReportMode.units.name)
        v.solo("USD", L)
        XCTAssertEqual(v.selected(L), ["CNY", "USD", "AAPL"])

        // only USD, as booked: the USD account, the USD expense
        let bs = balanceSheet(L, at: "2026-03-31", mode: .units, only: ["USD"])
        XCTAssertEqual(bs.assets.shown.byCurrency(base: "CNY").map { $0.currency }, ["USD"])
        XCTAssertEqual(bs.netWorthShown.amounts["USD"] ?? 0, 20, accuracy: 1e-6)
        let all = bs.assets.shown + bs.liabilities.shown + bs.equityByCurrency
        for (c, x) in all.amounts { XCTAssertEqual(x, 0, accuracy: 0.0001, c) }
        // only the shares, converted to CNY at 90 USD × 7.2
        let sh = balanceSheet(L, at: "2026-03-31", mode: .convert("CNY"), only: ["AAPL"])
        XCTAssertEqual(sh.netWorthShown.single(base: "CNY")?.amount ?? 0, 648, accuracy: 1e-6)

        // net worth by month: converted, the parts add up to the old series
        let ws = worthSeries(L, today: "2026-03-31", mode: .convert("CNY"))
        let old = netWorthSeries(L, today: "2026-03-31")
        XCTAssertEqual(ws.count, old.count)
        XCTAssertEqual(ws.last!.total.amounts["CNY"] ?? 0, old.last!.netWorth, accuracy: 0.01)
        XCTAssertEqual(Set(ws.last!.bySource.keys), ["CNY", "USD", "AAPL"])
        // as booked, only USD
        let wu = worthSeries(L, today: "2026-03-31", mode: .units, only: ["USD"])
        XCTAssertEqual(wu.last!.total.amounts["USD"] ?? 0, 20, accuracy: 1e-6)

        // income and expenses by month
        let f = monthlyFlows(L, months: ["2026-02", "2026-03"], mode: .units)
        XCTAssertEqual(f["2026-02"]?.income.amounts["CNY"] ?? 0, 5000, accuracy: 1e-6)
        XCTAssertEqual(f["2026-02"]?.expenses.amounts["USD"] ?? 0, 15, accuracy: 1e-6)
        XCTAssertEqual(f["2026-03"]?.expenses.amounts["MOP"] ?? 0, 10, accuracy: 1e-6)
        let fc = monthlyFlows(L, months: ["2026-03"], mode: .convert("CNY"), only: ["MOP"])
        XCTAssertEqual(fc["2026-03"]?.expenses.amounts["CNY"] ?? 0, 9, accuracy: 0.01)
    }

    func testInventoryHelpers() {
        var a = Inventory(); a.add(1, "USD"); a.add(2, "CNY"); a.add(0.001, "EUR")
        var b = Inventory(); b.add(-1, "USD"); b.add(3, "HKD")
        let s = a + b
        XCTAssertEqual(s.byCurrency(base: "CNY").map { $0.currency }, ["CNY", "HKD"])
        XCTAssertEqual((-s).amounts["CNY"], -2)
    }
}
