import XCTest
@testable import LedgerKit

/// Daily totals, the short amount, the heat scale and the six-row grid. All of it on made-up entries.
final class CalendarHeatTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private let book = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank CNY
    2026-01-01 open Assets:Wise USD
    2026-01-01 open Assets:Cash CNY
    2026-01-01 open Assets:Receivable:Work CNY
    2026-01-01 open Expenses:Food
    2026-01-01 open Income:Salary
    2026-01-01 open Income:Rewards
    2026-01-01 price USD 7.20 CNY

    2026-09-30 * "Sep dinner"
      Expenses:Food  40.00 CNY
      Assets:Bank
    2026-10-01 * "Lunch"
      Expenses:Food  25.00 CNY
      Income:Rewards  -9.00 CNY
      Assets:Bank
    2026-10-01 * "Refund lunch"
      Expenses:Food  -5.00 CNY
      Assets:Bank
    2026-10-02 * "Pay"
      Income:Salary  -1000.00 CNY
      Assets:Bank
    2026-10-02 * "Coffee abroad"
      Expenses:Food  10.00 USD
      Assets:Wise
    2026-10-03 * "Advance"
      Assets:Receivable:Work  80.00 CNY
      Assets:Bank
    2026-10-04 * "Move"
      Assets:Cash  15.00 CNY
      Assets:Bank
    2026-10-05 * "Huge"
      Expenses:Food  100000.00 CNY
      Assets:Bank
    2026-10-06 * "Small"
      Expenses:Food  80.00 CNY
      Assets:Bank
    2026-10-07 * "Only a refund"
      Expenses:Food  -12.00 CNY
      Assets:Bank

    """

    func testDayMoneySplitsTheMonthAndLeavesOutWhatIsNotSpending() {
        let L = ledger(book)
        XCTAssertTrue(L.errors.isEmpty, L.errors.map(\.msg).joined(separator: "; "))
        let days = dayMoney(L.txns, L)
        // September stays in September. The reward on the lunch is not a second income, and the refund lowers the day.
        XCTAssertEqual(days["2026-09-30"]?.expense, 40, accuracy: 0.001)
        XCTAssertEqual(days["2026-10-01"]?.expense, 20, accuracy: 0.001)
        XCTAssertEqual(days["2026-10-01"]?.income ?? 0, 0, accuracy: 0.001)
        // 10 USD at 7.20, beside a salary that is only income.
        XCTAssertEqual(days["2026-10-02"]?.expense, 72, accuracy: 0.001)
        XCTAssertEqual(days["2026-10-02"]?.income, 1000, accuracy: 0.001)
        // an advance and a transfer are neither
        XCTAssertNil(days["2026-10-03"])
        XCTAssertNil(days["2026-10-04"])
        XCTAssertEqual(days["2026-10-05"]?.expense, 100_000, accuracy: 0.001)
        XCTAssertEqual(days["2026-10-06"]?.expense, 80, accuracy: 0.001)
        // a refund with nothing to refund against is not spending
        XCTAssertEqual(days["2026-10-07"]?.expense, -12, accuracy: 0.001)
        XCTAssertEqual(dayMoney([], L).count, 0)
    }

    func testAHugeDayDoesNotFlattenTheOthers() {
        let L = ledger(book)
        let days = dayMoney(L.txns, L)
        let peak = days["2026-10-05"]!.expense
        let small = days["2026-10-06"]!.expense
        XCTAssertEqual(heatIntensity(amount: peak, peak: peak), 1, accuracy: 1e-9)
        let shade = heatIntensity(amount: small, peak: peak)
        // 80 against 100000 is almost nothing on a linear scale, and still a light but real shade on the log scale
        XCTAssertLessThan(small / peak, 0.001)
        XCTAssertGreaterThan(shade, 0.25)
        XCTAssertLessThan(shade, 0.5)
        XCTAssertEqual(shade, log1p(small) / log1p(peak), accuracy: 1e-9)
        // two ordinary days stay close to each other; a linear scale would leave the smaller one at half
        XCTAssertGreaterThan(heatIntensity(amount: 100, peak: 200), 0.8)
        XCTAssertEqual(heatIntensity(amount: 0, peak: peak), 0, accuracy: 1e-9)
        XCTAssertEqual(heatIntensity(amount: 10, peak: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(heatIntensity(amount: -5, peak: 100), 0, accuracy: 1e-9)
        XCTAssertEqual(heatIntensity(amount: 500, peak: 100), 1, accuracy: 1e-9)
    }

    func testCompactAmount() {
        XCTAssertEqual(compactAmount(0), "")
        XCTAssertEqual(compactAmount(0.4), "")
        XCTAssertEqual(compactAmount(0.5), "1")
        XCTAssertEqual(compactAmount(72), "72")
        XCTAssertEqual(compactAmount(999.4), "999")
        XCTAssertEqual(compactAmount(999.6), "1k")
        XCTAssertEqual(compactAmount(1000), "1k")
        XCTAssertEqual(compactAmount(1200), "1.2k")
        XCTAssertEqual(compactAmount(1250), "1.3k")
        XCTAssertEqual(compactAmount(2000), "2k")
        XCTAssertEqual(compactAmount(2400), "2.4k")
        XCTAssertEqual(compactAmount(6842), "6.8k")
        XCTAssertEqual(compactAmount(12345), "12.3k")
        XCTAssertEqual(compactAmount(100_000), "100k")
        XCTAssertEqual(compactAmount(999_499), "999.5k")
        XCTAssertEqual(compactAmount(999_500), "1m")
        XCTAssertEqual(compactAmount(1_500_000), "1.5m")
        XCTAssertEqual(compactAmount(-1500), "1.5k")
    }

    func testTheGridIsSixRowsAndFollowsTheFirstWeekday() {
        // 2026-10-01 is a Thursday. Monday-first leaves three days of September in front of it.
        let monday = monthGrid(month: "2026-10", firstWeekday: 2)
        XCTAssertEqual(monday.count, 42)
        XCTAssertEqual(monday.map(\.date).first, "2026-09-28")
        XCTAssertEqual(monday[3].date, "2026-10-01")
        XCTAssertFalse(monday[0].inMonth)
        XCTAssertTrue(monday[3].inMonth)
        XCTAssertEqual(monday.filter(\.inMonth).count, 31)
        XCTAssertEqual(calendarRow(of: "2026-10-25", in: monday), 3)
        XCTAssertEqual(calendarRow(of: "2026-10-01", in: monday), 0)
        XCTAssertNil(calendarRow(of: "2026-08-01", in: monday))

        // Sunday-first starts one day earlier, so the 25th drops to the next row.
        let sunday = monthGrid(month: "2026-10", firstWeekday: 1)
        XCTAssertEqual(sunday.count, 42)
        XCTAssertEqual(sunday.map(\.date).first, "2026-09-27")
        XCTAssertEqual(calendarRow(of: "2026-10-25", in: sunday), 4)
        XCTAssertEqual(monthGrid(month: "2026-10", firstWeekday: 0).map(\.date).first, sunday.map(\.date).first)
        XCTAssertEqual(monthGrid(month: "2026-10", firstWeekday: 9).map(\.date).first, sunday.map(\.date).first)
    }

    func testFebruaryKeepsSixRowsInALeapYearAndOtherwise() {
        // 2024-02-01 is a Thursday; the 29th is on the grid, and the grid is still six rows.
        let leap = monthGrid(month: "2024-02", firstWeekday: 2)
        XCTAssertEqual(leap.count, 42)
        XCTAssertEqual(leap.map(\.date).first, "2024-01-29")
        XCTAssertEqual(leap.filter(\.inMonth).count, 29)
        XCTAssertTrue(leap.contains { $0.date == "2024-02-29" && $0.inMonth })
        let leapSunday = monthGrid(month: "2024-02", firstWeekday: 1)
        XCTAssertEqual(leapSunday.map(\.date).first, "2024-01-28")
        XCTAssertTrue(leapSunday.contains { $0.date == "2024-02-29" && $0.inMonth })

        // 2021-02-01 is a Monday: the month itself is exactly four rows, and two rows of March fill the six.
        let short = monthGrid(month: "2021-02", firstWeekday: 2)
        XCTAssertEqual(short.count, 42)
        XCTAssertEqual(short.map(\.date).first, "2021-02-01")
        XCTAssertEqual(short.filter(\.inMonth).count, 28)
        XCTAssertEqual(short.map(\.date).last, "2021-03-14")
        XCTAssertFalse(short.last!.inMonth)

        // 2026 is not a leap year. Sunday-first starts on the 1st; Monday-first borrows the end of January.
        let feb = monthGrid(month: "2026-02", firstWeekday: 1)
        XCTAssertEqual(feb.count, 42)
        XCTAssertEqual(feb.map(\.date).first, "2026-02-01")
        XCTAssertEqual(feb.filter(\.inMonth).count, 28)
        XCTAssertFalse(feb.contains { $0.date == "2026-02-29" })
        XCTAssertEqual(monthGrid(month: "2026-02", firstWeekday: 2).map(\.date).first, "2026-01-26")

        XCTAssertTrue(monthGrid(month: "2026-13", firstWeekday: 1).isEmpty)
        XCTAssertTrue(monthGrid(month: "", firstWeekday: 2).isEmpty)
        XCTAssertTrue(monthGrid(month: "2026", firstWeekday: 2).isEmpty)
    }
}
