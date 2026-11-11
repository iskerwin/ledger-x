import XCTest
@testable import LedgerKit

/// the window's time filter: what each unit spans, stepping and its names
final class ViewPeriodTests: XCTestCase {
    func testEachUnitSpansItsWholeStretch() {
        XCTAssertEqual(ViewPeriod(unit: .month, month: "2024-02").span?.0, "2024-02-01")
        XCTAssertEqual(ViewPeriod(unit: .month, month: "2024-02").span?.1, "2024-02-29")
        XCTAssertEqual(ViewPeriod(unit: .quarter, month: "2024-08").span?.0, "2024-07-01")
        XCTAssertEqual(ViewPeriod(unit: .quarter, month: "2024-08").span?.1, "2024-09-30")
        XCTAssertEqual(ViewPeriod(unit: .year, month: "2024-08").span?.0, "2024-01-01")
        XCTAssertEqual(ViewPeriod(unit: .year, month: "2024-08").span?.1, "2024-12-31")
        XCTAssertNil(ViewPeriod(unit: .all, month: "2024-08").span)
        // a day picked on the calendar is the whole of it, whatever the unit
        XCTAssertEqual(ViewPeriod(unit: .year, month: "2024-08", day: "2024-03-05").span?.0, "2024-03-05")
        XCTAssertEqual(ViewPeriod(unit: .year, month: "2024-08", day: "2024-03-05").span?.1, "2024-03-05")
    }

    func testSteppingMovesByTheUnitAndNeverPastNow() {
        XCTAssertEqual(ViewPeriod(unit: .month, month: "2024-01").stepped(-1).month, "2023-12")
        XCTAssertEqual(ViewPeriod(unit: .quarter, month: "2024-02").stepped(1).month, "2024-05")
        XCTAssertEqual(ViewPeriod(unit: .year, month: "2023-06").stepped(-1).month, "2022-06")
        let now = ViewPeriod()
        XCTAssertEqual(now.stepped(1), now)
        XCTAssertEqual(ViewPeriod(unit: .year).stepped(1).month, Day.ym(Day.today()))
        XCTAssertEqual(ViewPeriod(unit: .all, month: "2023-06").stepped(-1).month, "2023-06")
        XCTAssertEqual(ViewPeriod(day: "2024-03-01").stepped(-1).day, "2024-02-29")
        XCTAssertEqual(ViewPeriod(day: Day.today()).stepped(1).day, Day.today())
    }

    func testNamesAndWhatPagesOfMonthsOrYearsShow() {
        XCTAssertEqual(ViewPeriod(unit: .month, month: "2024-03").title, "2024 年 3 月")
        XCTAssertEqual(ViewPeriod(unit: .quarter, month: "2024-11").title, "2024 年第 4 季度")
        XCTAssertEqual(ViewPeriod(unit: .year, month: "2024-11").title, "2024 年")
        XCTAssertEqual(ViewPeriod(unit: .all).title, "全部时间")
        XCTAssertTrue(ViewPeriod(unit: .year).byYear)
        XCTAssertTrue(ViewPeriod(unit: .all).byYear)
        XCTAssertFalse(ViewPeriod(unit: .quarter).byYear)
        XCTAssertFalse(ViewPeriod(unit: .year, day: "2024-03-05").byYear)
        XCTAssertEqual(ViewPeriod(unit: .year, month: "2024-08", day: "2024-03-05").anchor, "2024-03")
        // another unit keeps the month and puts the day away
        XCTAssertEqual(ViewPeriod(unit: .month, month: "2024-08", day: "2024-03-05").showing(.year), ViewPeriod(unit: .year, month: "2024-03"))
    }

    func testCurrentHoldsToday() {
        XCTAssertTrue(ViewPeriod().isCurrent)
        XCTAssertTrue(ViewPeriod(unit: .all, month: "2020-01").isCurrent)
        XCTAssertFalse(ViewPeriod(unit: .month, month: "2020-01").isCurrent)
        XCTAssertEqual(ViewPeriod(unit: .quarter).current, "本季度")
    }
}
