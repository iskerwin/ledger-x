import XCTest
@testable import LedgerKit

/// 更新价格 and 投资收入, shared by the phone's and the Mac's holdings
final class PricesTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private let text = """
    option "operating_currency" "CNY"
    2025-01-01 open Assets:Bank:Main CNY
    2025-01-01 open Assets:Bank:US USD
    2025-01-01 open Assets:Broker:Fund
    2025-01-01 open Income:Invest:Dividend
    2025-01-01 open Equity:Opening
    2026-01-01 commodity VOO
      price: "USD:yahoo/VOO"
    2026-01-01 commodity EXFUND
      price: "CNY:yahoo/510300.SS"

    2026-01-02 * "Opening"
      Assets:Bank:Main  10000.00 CNY
      Assets:Bank:US  100.00 USD
      Equity:Opening
    2026-02-03 * "Buy"
      Assets:Broker:Fund  1000 EXFUND {1.20 CNY}
      Assets:Bank:Main  -1200.00 CNY
    2025-06-01 * "Dividend"
      Assets:Bank:Main  30.00 CNY
      Income:Invest:Dividend  -30.00 CNY
    2026-06-01 * "Dividend"
      Assets:Bank:Main  50.00 CNY
      Income:Invest:Dividend  -50.00 CNY
    2026-10-30 price EXFUND 1.35 CNY
    """

    func testPriceItemsListHoldingsThenForeignCurrencies() {
        let items = priceItems(ledger(text))
        XCTAssertEqual(items.map(\.id), ["EXFUND/CNY", "USD/CNY"])
        XCTAssertEqual(items[0].last, 1.35)
        XCTAssertEqual(items[0].date, "2026-10-30")
        XCTAssertNil(items[1].last)
    }

    func testOnlyTypedPricesAreWritten() {
        let items = priceItems(ledger(text))
        let lines = typedPriceLines(items, ["EXFUND/CNY": "1.4", "USD/CNY": ""], date: "2026-11-26")
        XCTAssertEqual(lines, ["2026-11-26 price EXFUND" + String(repeating: " ", count: 20) + "1.4 CNY"])
    }

    func testTheCommoditysOwnSymbolElseTheCurrencyPair() {
        let L = ledger(text)
        XCTAssertEqual(PriceFetch.symbol("EXFUND", "CNY", L).0, "510300.SS")
        XCTAssertEqual(PriceFetch.symbol("USD", "CNY", L).0, "USDCNY=X")
        XCTAssertEqual(PriceFetch.symbol("ABC", "USD", L).0, "ABC")
    }

    func testInvestIncomeByYearAndInAll() {
        let rows = investIncome(ledger(text), year: "2026")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].account, "Income:Invest:Dividend")
        XCTAssertEqual(rows[0].year, 50, accuracy: 0.001)
        XCTAssertEqual(rows[0].all, 80, accuracy: 0.001)
    }
}
