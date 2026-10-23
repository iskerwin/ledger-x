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

    func testAPerCurrencyDefaultWidensWhatTheDecimalsAllow() {
        XCTAssertEqual(errors("""
        2026-10-20 * "Shop"
          Expenses:Shopping    100.00 CNY
          Assets:Bank          -99.50 CNY
        """, options: "option \"inferred_tolerance_default\" \"CNY:1\"\n"), [], "Beancount takes the larger of 0.005 and 1")
    }

    // Amounts Beancount 3.2.3 fills in: rounded to twice the tolerance, half to even, and exact when no amount in
    // that currency was written with decimals and no default is set.
    private func filled(_ body: String, options: String = "") -> (units: Double?, digits: Int?, errors: [String]) {
        let text = """
        2020-01-01 open Assets:A
        2020-01-01 open Assets:B
        2020-01-01 open Assets:C

        """ + body
        let L = loadLedger(root: "main.bean") { _ in options + text }
        let p = L.entries.last?.postings.first { $0.interpolated }
        return (p?.units, p?.digits, L.errors.map(\.msg))
    }

    func testAStockAwardAtCostIsFilledInExactly() {
        let body = """
        2026-10-21 * "ZABank" "Stock award"
          Assets:A
          Assets:B        0.002 AAPL {343.6395 USD}
        """
        let r = filled(body)
        XCTAssertEqual(r.units, -0.687279, "used to be filled in as -0.69, then off balance by 0.0027 USD")
        XCTAssertEqual(r.digits, 6)
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(filled(body, options: "option \"inferred_tolerance_default\" \"USD:0.005\"\n").units, -0.69)
        XCTAssertEqual(filled(body, options: "option \"inferred_tolerance_default\" \"*:0.005\"\n").units, -0.69)
        XCTAssertEqual(filled(body, options: "option \"inferred_tolerance_default\" \"USD:1\"\n").units, -1)
        let check = checkText(body, loadLedger(root: "main.bean") { _ in "2020-01-01 open Assets:A\n2020-01-01 open Assets:B\n" })
        XCTAssertTrue(check.ok, "\(check.errors.map(\.msg))")
    }

    func testFilledInAmountsRoundToTheCoarsestDecimals() {
        let r = filled("""
        2026-10-21 * "t"
          Assets:A        1.115 USD
          Assets:B       -10.00 USD
          Assets:C
        """)
        XCTAssertEqual(r.units, 8.88, "8.885 to two places, half to even")
        XCTAssertEqual(r.errors, [])
    }

    func testWholeNumbersLeaveTheFilledInAmountExact() {
        let body = """
        2026-10-21 * "t"
          Assets:A        3 XX @ 1.115 USD
          Assets:B      -10 USD
          Assets:C
        """
        XCTAssertEqual(filled(body).units, 6.655)
        XCTAssertEqual(filled(body).errors, [])
        XCTAssertEqual(filled(body, options: "option \"inferred_tolerance_default\" \"USD:0.005\"\n").units, 6.66)
    }
}
