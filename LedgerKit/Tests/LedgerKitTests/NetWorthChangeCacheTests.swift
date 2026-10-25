import XCTest
@testable import LedgerKit

final class NetWorthChangeCacheTests: XCTestCase {
    private let text = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank CNY
    2026-01-01 open Assets:Cash CNY
    2026-01-01 open Equity:Opening
    2026-01-01 open Expenses:Food

    2026-09-01 * "Opening"
      Assets:Bank 100 CNY
      Assets:Cash 50 CNY
      Equity:Opening -150 CNY

    2026-10-01 * "Cafe" "Coffee"
      Expenses:Food 10 CNY
      Assets:Bank -10 CNY

    2026-10-20 * "Bakery" "Bread"
      Expenses:Food 5 CNY
      Assets:Cash -5 CNY
    """

    func testScopeDateAndReloadEachGetTheirOwnResult() {
        let L = loadLedger(root: "main.bean") { _ in self.text }
        for _ in 0..<3 {
            XCTAssertEqual(netWorthSinceLastMonth(L, today: "2026-10-25"), -15)
            XCTAssertEqual(netWorthSinceLastMonth(L, today: "2026-10-25", exclude: ["Assets:Bank"]), -5)
            XCTAssertEqual(netWorthSinceLastMonth(L, today: "2026-11-01"), 0)
            XCTAssertNil(netWorthSinceLastMonth(L, today: "2026-09-30"))
        }
        let other = loadLedger(root: "main.bean") { _ in self.text.replacingOccurrences(of: "10 CNY", with: "20 CNY") }
        XCTAssertEqual(netWorthSinceLastMonth(other, today: "2026-10-25"), -25)
        XCTAssertEqual(netWorthSinceLastMonth(L, today: "2026-10-25"), -15)
    }

    func testRepeatedLookupsReuseTheLoadedLedgersCalculation() {
        let L = loadLedger(root: "main.bean") { _ in self.text }
        XCTAssertEqual(netWorthSinceLastMonth(L, today: "2026-10-25"), -15)
        // A loaded ledger is immutable in production. Here remove its input after warming the cache:
        // a second scan would return nil, so this verifies reuse without a timing threshold.
        L.txns = []
        XCTAssertEqual(netWorthSinceLastMonth(L, today: "2026-10-25"), -15)
        // Changing the date or scope must request a new calculation.
        XCTAssertNil(netWorthSinceLastMonth(L, today: "2026-10-26"))
        XCTAssertNil(netWorthSinceLastMonth(L, today: "2026-10-25", exclude: ["Assets:Bank"]))
    }
    func testMissingPreviousMonthIsCachedToo() {
        let empty = Ledger()
        XCTAssertNil(netWorthSinceLastMonth(empty, today: "2026-10-25"))
        let populated = loadLedger(root: "main.bean") { _ in self.text }
        empty.txns = populated.txns
        XCTAssertNil(netWorthSinceLastMonth(empty, today: "2026-10-25"))
        XCTAssertEqual(netWorthSinceLastMonth(empty, today: "2026-10-26"), -15)
    }

}
