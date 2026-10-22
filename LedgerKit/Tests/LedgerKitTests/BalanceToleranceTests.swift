import XCTest
@testable import LedgerKit

/// Whole numbers don't loosen the balance check, as in Beancount (bean-check rejects 100 against -99.60 by 0.40).
final class BalanceToleranceTests: XCTestCase {
    private let head = """
    2020-01-01 open Assets:Bank CNY
    2020-01-01 open Expenses:Shopping

    """

    private func errors(_ body: String, options: String = "") -> [String] {
        let L = loadLedger(root: "main.bean") { _ in options + self.head + body }
        return L.errors.map(\.msg)
    }

    func testAWholeNumberDoesNotLetFortyCentsThrough() {
        let body = """
        2026-10-20 * "Shop"
          Expenses:Shopping       100 CNY
          Assets:Bank          -99.60 CNY
        """
        XCTAssertEqual(errors(body).count, 1, "Beancount: Transaction does not balance: (0.40 CNY)")
        XCTAssertFalse(checkText(body, loadLedger(root: "main.bean") { _ in self.head }).ok)
    }

    func testWholeNumbersMustBalanceExactly() {
        XCTAssertEqual(errors("""
        2026-10-20 * "Shop"
          Expenses:Shopping       100 CNY
          Assets:Bank            -100 CNY
        """), [])
        XCTAssertEqual(errors("""
        2026-10-20 * "Shop"
          Expenses:Shopping       100 CNY
          Assets:Bank         -100.004 CNY
        """).count, 1, "nothing written with decimals in CNY at 0.01 or coarser, and -100.004 allows 0.0005")
    }

    func testDecimalsStillAllowHalfTheLastDigit() {
        XCTAssertEqual(errors("""
        2026-10-20 * "Shop"
          Expenses:Shopping    100.00 CNY
          Assets:Bank         -100.004 CNY
        """), [], "-100.004 is within 0.005 of 100.00")
    }

    func testTheLedgersOwnDefaultApplies() {
        let body = """
        2026-10-20 * "Shop"
          Expenses:Shopping       100 CNY
          Assets:Bank            -99 CNY
        """
        XCTAssertEqual(errors(body).count, 1)
        XCTAssertEqual(errors(body, options: "option \"inferred_tolerance_default\" \"CNY:1\"\n"), [])
        XCTAssertEqual(errors(body, options: "option \"inferred_tolerance_default\" \"*:1\"\n"), [])
    }
}
