import XCTest
@testable import LedgerKit

/// The rounding rules for amounts that get written into the ledger (Money.swift): worked out on the decimal
/// numbers, 四舍五入 for what the app works out, half to even where Beancount fills an amount in.
final class RoundingTests: XCTestCase {
    func testDecimalNotBinary() {
        // 1.005 is 1.00499… as a Double; rounded on its decimal value it is 1.01
        XCTAssertEqual(roundMoney(1.005, 2), 1.01)
        XCTAssertEqual(roundMoney(2.675, 2), 2.68)
        XCTAssertEqual(roundMoney(-2.675, 2), -2.68, "halves away from zero")
        XCTAssertEqual(roundMoney(0.1 + 0.2, 2), 0.3)
        XCTAssertEqual(roundMoney(2.665, 2, .halfEven), 2.66)
        XCTAssertEqual(roundMoney(2.675, 2, .halfEven), 2.68)
        XCTAssertEqual(roundMoney(123456789.125, 2), 123456789.13)
    }

    func testProductsAndQuotients() {
        XCTAssertEqual(mulMoney(3, 1.115, 2), 3.35, "3.3449999… as a Double product")
        XCTAssertEqual(mulMoney(90.23, 1.17972, 2), 106.45)
        XCTAssertEqual(divMoney(10, 3, 2), 3.33)
        XCTAssertNil(divMoney(1, 0, 2))
        XCTAssertEqual(solveRate(.converted, amount: 3, rate: 1.115, converted: nil), 3.35)
        XCTAssertEqual(solveRate(.amount, amount: nil, rate: 1.17972, converted: 106.45), 90.23)
    }

    func testWrittenText() {
        XCTAssertEqual(moneyText(1200, 2), "1200.00")
        XCTAssertEqual(moneyText(6.7, 2), "6.70")
        XCTAssertEqual(moneyText(-0.5, 2), "-0.50")
        XCTAssertEqual(moneyText(-0.004, 2), "0.00", "never -0.00")
        XCTAssertEqual(moneyText(1.0 / 3.0, 5), "0.33333")
        XCTAssertEqual(moneyText(0.5, 0), "1")
        XCTAssertEqual(rateString(7.10), "7.1")
        XCTAssertEqual(rateString(1.179715), "1.17972")
    }

    func testTypedExpressions() {
        XCTAssertEqual(evalExpr("1.115*3"), 3.345, "worked out in decimal")
        XCTAssertEqual(evalAmount("1.115×3"), 3.35)
        XCTAssertEqual(evalAmount("23.5+12×2"), 47.5)
        XCTAssertEqual(evalAmount("0.1+0.2"), 0.3)
        XCTAssertEqual(evalExpr("10/4"), 2.5)
        XCTAssertNil(evalExpr("1/0"))
        XCTAssertEqual(evalExpr("1,234.50"), 1234.5)
    }

    /// what Beancount fills in for these (worked out with Beancount 2.3.6): half to even on the decimal residual
    func testFilledInAmountsMatchBeancount() {
        func filled(_ price: String, _ units: String) -> Double? {
            let text = """
            2024-01-02 * "t"
              Assets:A                               \(units) XX @ \(price) USD
              Assets:B                              -10.00 USD
              Assets:C
            """
            let r = checkText(text, nil)
            return r.entries.first?.postings.first { $0.account == "Assets:C" }?.units
        }
        XCTAssertEqual(filled("1.115", "3"), 6.66)
        XCTAssertEqual(filled("2.665", "1"), 7.34)
        XCTAssertEqual(filled("2.675", "1"), 7.32, "7.325 to even; the Double sum used to give 7.33")
    }

    func testLedgerAmountExpressions() {
        let r = checkText("""
        2024-01-02 * "t"
          Assets:A                          (1.115 * 3) USD
          Assets:B
        """, nil)
        XCTAssertEqual(r.entries.first?.postings.first?.units, 3.345)
        XCTAssertEqual(r.entries.first?.postings.last?.units, -3.345)
    }
}
