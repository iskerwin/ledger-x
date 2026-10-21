import XCTest
@testable import LedgerKit

/// the way the money goes, whatever order the lines are written in
final class RouteTests: XCTestCase {
    func testRoute() {
        let L = loadLedger(root: "main.bean") { _ in """
        2026-01-01 open Assets:Bank:BOC CNY
        2026-01-01 open Liabilities:CreditCard:CEB CNY

        2026-09-10 * "CEB Credit Card" "Repayment"
          Liabilities:CreditCard:CEB                         100.00 CNY
          Assets:Bank:BOC                                   -100.00 CNY

        2026-09-11 * "Transfer" "BOC -> CEB"
          Assets:Bank:BOC                                   -50.00 CNY
          Liabilities:CreditCard:CEB

        """ }
        XCTAssertEqual(moneyRoute(L.txns[0]), ["Assets:Bank:BOC", "Liabilities:CreditCard:CEB"])
        // an amount left for Beancount to work out counts once it is worked out
        XCTAssertEqual(moneyRoute(L.txns[1]), ["Assets:Bank:BOC", "Liabilities:CreditCard:CEB"])
    }
}
