import XCTest
@testable import LedgerKit

/// the line under the 资产 page's card: 收支 by the month and against last year, 净资产 against last month
final class YearPaceTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private let text = """
    option "operating_currency" "CNY"
    2025-01-01 open Assets:Bank CNY
    2025-01-01 open Assets:Wallet CNY
    2025-01-01 open Equity:Opening
    2025-01-01 open Income:Salary
    2025-01-01 open Expenses:Food
    2025-01-02 * "期初"
      Assets:Bank  10000.00 CNY
      Equity:Opening
    2025-02-10 * "午饭"
      Expenses:Food  400.00 CNY
      Assets:Bank
    2025-03-20 * "晚饭"
      Expenses:Food  9999.00 CNY
      Assets:Bank
    2026-01-05 * "工资"
      Assets:Bank  6000.00 CNY
      Income:Salary
    2026-02-10 * "午饭"
      Expenses:Food  300.00 CNY
      Assets:Bank
    2026-03-01 * "零钱"
      Assets:Wallet  100.00 CNY
      Assets:Bank

    """

    /// up to 15 March: three months gone; last year's same days had 400 of spending (not March's 20th)
    func testThisYearByTheMonthAndAgainstTheSameDaysLastYear() {
        let p = yearPace(ledger(text), year: "2026", today: "2026-03-15")
        XCTAssertEqual(p.monthlySpent, 100, accuracy: 0.001)
        XCTAssertEqual(p.monthlySaved, 1900, accuracy: 0.001)
        XCTAssertEqual(p.spentChange!, -0.25, accuracy: 0.0001)
    }

    /// the year the ledger starts in has nothing to compare with; a past year counts all twelve months
    func testNoComparisonBeforeTheLedgerAndAPastYearWhole() {
        let p = yearPace(ledger(text), year: "2025", today: "2026-03-15")
        XCTAssertNil(p.spentChange)
        XCTAssertEqual(p.monthlySpent, (400 + 9999) / 12.0, accuracy: 0.001)
    }

    /// a ledger begun in the middle of last year: its same days are not a year's worth, so no comparison
    func testALedgerBegunLateLastYearIsNotCompared() {
        let late = text.replacingOccurrences(of: "2025-01-02 * \"期初\"", with: "2025-06-02 * \"期初\"")
            .replacingOccurrences(of: "2025-02-10 * \"午饭\"", with: "2025-07-10 * \"午饭\"")
            .replacingOccurrences(of: "2025-03-20 * \"晚饭\"", with: "2025-08-20 * \"晚饭\"")
        XCTAssertNil(yearPace(ledger(late), year: "2026", today: "2026-03-15").spentChange)
    }

    /// 29 February is compared with the year before up to the 28th
    func testALeapDayComparesUpToThe28th() {
        let leap = text.replacingOccurrences(of: "2025", with: "2027").replacingOccurrences(of: "2026", with: "2028")
            .replacingOccurrences(of: "2027-03-20", with: "2027-02-28")
        XCTAssertEqual(yearPace(ledger(leap), year: "2028", today: "2028-02-29").spentChange!, (300 - 10399) / 10399.0, accuracy: 0.0001)
    }

    /// against last month's end: moving money between two accounts changes nothing, an account left out is not
    /// counted
    func testNetWorthAgainstLastMonth() {
        let L = ledger(text)
        XCTAssertEqual(netWorthSinceLastMonth(L, today: "2026-03-15")!, 0, accuracy: 0.001)
        XCTAssertEqual(netWorthSinceLastMonth(L, today: "2026-02-15")!, -300, accuracy: 0.001)
        XCTAssertEqual(netWorthSinceLastMonth(L, today: "2026-03-15", exclude: ["Assets:Wallet"])!, -100, accuracy: 0.001)
        XCTAssertNil(netWorthSinceLastMonth(L, today: "2025-01-15"))
    }
}
