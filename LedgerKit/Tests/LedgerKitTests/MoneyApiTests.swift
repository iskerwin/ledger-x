import XCTest
@testable import LedgerKit

/// Exact-value tests for the read-only "is the money right?" APIs:
/// balancesAt, latestPrice, holdings, periodBalances, accountTree, netWorthSeries.
final class MoneyApiTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private let fx = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Cash CNY
    2026-01-01 open Assets:Cash:USD USD
    2026-01-01 open Assets:Broker AAPL,USD
    2026-01-01 open Expenses:Food CNY
    2026-01-01 open Income:Salary CNY
    2026-01-01 open Equity:Opening CNY,USD
    2026-01-01 price USD 7.20 CNY

    2026-01-02 * "Opening"
      Assets:Cash  10000.00 CNY
      Assets:Cash:USD  2000.00 USD
      Equity:Opening

    2026-01-05 * "Salary"
      Income:Salary  -8000.00 CNY
      Assets:Cash

    2026-01-10 * "Buy AAPL"
      Assets:Broker  10 AAPL {150 USD}
      Assets:Cash:USD  -1500.00 USD

    2026-01-15 price AAPL 170.00 USD

    2026-01-20 * "Lunch"
      Expenses:Food  50.00 CNY
      Assets:Cash

    """

    private func fxLedger() -> Ledger {
        let L = ledger(fx)
        XCTAssertTrue(L.errors.isEmpty, L.errors.map { $0.msg }.joined(separator: "; "))
        return L
    }

    func testBalancesAt() {
        let L = fxLedger()
        let b = balancesAt(L, "2026-01-05")
        XCTAssertEqual(b["Assets:Cash"]?["CNY"] ?? 0, 18000, accuracy: 1e-9)
        XCTAssertEqual(b["Assets:Cash:USD"]?["USD"] ?? 0, 2000, accuracy: 1e-9)
        XCTAssertEqual(b["Income:Salary"]?["CNY"] ?? 0, -8000, accuracy: 1e-9)
        XCTAssertEqual(b["Equity:Opening"]?["CNY"] ?? 0, -10000, accuracy: 1e-9)
        XCTAssertEqual(b["Equity:Opening"]?["USD"] ?? 0, -2000, accuracy: 1e-9)
        // later activity is excluded…
        XCTAssertNil(b["Expenses:Food"])
        XCTAssertNil(b["Assets:Broker"])

        let all = balancesAt(L, nil)
        XCTAssertEqual(all["Assets:Cash"]?["CNY"] ?? 0, 17950, accuracy: 1e-9)
        XCTAssertEqual(all["Assets:Cash:USD"]?["USD"] ?? 0, 500, accuracy: 1e-9)
        XCTAssertEqual(all["Assets:Broker"]?["AAPL"] ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(all["Expenses:Food"]?["CNY"] ?? 0, 50, accuracy: 1e-9)
    }

    func testLatestPrice() throws {
        let L = fxLedger()
        let px = try XCTUnwrap(latestPrice(L, "AAPL", "USD"))
        XCTAssertEqual(px.date, "2026-01-15")
        XCTAssertEqual(px.number, 170, accuracy: 1e-9)
        XCTAssertNil(latestPrice(L, "AAPL", "CNY"))
    }

    func testHoldings() throws {
        let L = fxLedger()
        let hs = holdings(L)
        XCTAssertEqual(hs.count, 1)
        let h = try XCTUnwrap(hs.first)
        XCTAssertEqual(h.acct, "Assets:Broker")
        XCTAssertEqual(h.c, "AAPL")
        XCTAssertEqual(h.q, "USD")
        XCTAssertEqual(h.units, 10, accuracy: 1e-9)
        XCTAssertEqual(h.cost, 1500, accuracy: 1e-9)
        XCTAssertEqual(h.avg, 150, accuracy: 1e-9)
        XCTAssertEqual(h.value ?? 0, 1700, accuracy: 1e-9)   // 10 × latest 170 USD
        XCTAssertEqual(h.pnl ?? 0, 200, accuracy: 1e-9)
    }

    func testPeriodBalances() {
        let L = fxLedger()
        let pb = periodBalances(L, from: "2026-01-01", to: "2026-01-10")
        XCTAssertEqual(pb["Assets:Cash"]?.amounts["CNY"] ?? 0, 18000, accuracy: 1e-9)
        XCTAssertEqual(pb["Assets:Cash:USD"]?.amounts["USD"] ?? 0, 500, accuracy: 1e-9)
        XCTAssertEqual(pb["Assets:Broker"]?.amounts["AAPL"] ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(pb["Income:Salary"]?.amounts["CNY"] ?? 0, -8000, accuracy: 1e-9)
        XCTAssertNil(pb["Expenses:Food"])  // lunch on 01-20 is outside the window
    }

    func testAccountTree() {
        let L = fxLedger()
        let tree = accountTree(periodBalances(L), root: "Assets", L, at: "2026-01-20")
        XCTAssertEqual(tree.name, "Assets")
        XCTAssertEqual(Set(tree.children.map { $0.name }), ["Assets:Cash", "Assets:Broker"])
        // native-currency balances roll up through ancestors
        XCTAssertEqual(tree.balance.amounts["CNY"] ?? 0, 17950, accuracy: 1e-9)
        XCTAssertEqual(tree.balance.amounts["USD"] ?? 0, 500, accuracy: 1e-9)
        XCTAssertEqual(tree.balance.amounts["AAPL"] ?? 0, 10, accuracy: 1e-9)
        let cash = tree.children.first { $0.name == "Assets:Cash" }
        XCTAssertEqual(cash?.balance.amounts["CNY"] ?? 0, 17950, accuracy: 1e-9)
        XCTAssertEqual(cash?.balance.amounts["USD"] ?? 0, 500, accuracy: 1e-9)
        XCTAssertEqual(cash?.children.map { $0.name }, ["Assets:Cash:USD"])
        // converted total: 17950 + 500×7.2 + 10×(170×7.2)
        XCTAssertEqual(tree.total, 33790, accuracy: 0.01)
    }

    func testNetWorthSeries() {
        let L = fxLedger()
        let nw = netWorthSeries(L, today: "2026-01-20")
        XCTAssertEqual(nw.count, 1)
        XCTAssertEqual(nw[0].month, "2026-01")
        XCTAssertEqual(nw[0].assets, 33790, accuracy: 0.01)
        XCTAssertEqual(nw[0].liabilities, 0, accuracy: 1e-9)
        XCTAssertEqual(nw[0].netWorth, 33790, accuracy: 0.01)
    }

    // MARK: - thousands separators (issue: "1,2,3" must not parse as 123)

    func testThousandsGroupingInLedger() {
        let bad = ledger("""
        option "operating_currency" "CNY"
        2026-01-01 open Expenses:Food CNY
        2026-01-01 open Assets:Cash CNY
        2026-01-02 * "bad"
          Expenses:Food  1,2,3 CNY
          Assets:Cash
        """)
        XCTAssertFalse(bad.errors.isEmpty, "badly grouped thousands must be a parse error, not 123")

        let good = ledger("""
        option "operating_currency" "CNY"
        2026-01-01 open Expenses:Food CNY
        2026-01-01 open Assets:Cash CNY
        2026-01-02 * "ok"
          Expenses:Food  1,234.50 CNY
          Assets:Cash
        """)
        XCTAssertTrue(good.errors.isEmpty, good.errors.map { $0.msg }.joined(separator: "; "))
        XCTAssertEqual(good.txns.first?.postings.first?.units ?? 0, 1234.5, accuracy: 1e-9)
    }

    func testThousandsGroupingOK() {
        XCTAssertTrue(thousandsGroupingOK("1,234.50"))
        XCTAssertTrue(thousandsGroupingOK("1,234,567"))
        XCTAssertTrue(thousandsGroupingOK("1234"))
        XCTAssertTrue(thousandsGroupingOK("1,234+5"))
        XCTAssertFalse(thousandsGroupingOK("1,2,3"))
        XCTAssertFalse(thousandsGroupingOK("12,34"))
        XCTAssertFalse(thousandsGroupingOK(",123"))
        XCTAssertFalse(thousandsGroupingOK("123,"))
        XCTAssertNil(evalAmount("1,2,3"))
        XCTAssertEqual(evalAmount("1,234.50") ?? 0, 1234.5, accuracy: 1e-9)
    }
}
