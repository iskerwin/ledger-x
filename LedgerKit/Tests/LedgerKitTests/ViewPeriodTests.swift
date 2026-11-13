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

    /// the last 30 days end today; a span of days is the days picked, whichever was picked first, over a day and the unit
    func testTheLastThirtyDaysAndASpanOfDays() {
        let today = Day.today()
        let recent = ViewPeriod(unit: .recent, month: "2023-06")
        XCTAssertEqual(recent.span?.0, Day.shift(today, -29))
        XCTAssertEqual(recent.span?.1, today)
        XCTAssertEqual(recent.title, "近 30 天")
        XCTAssertEqual(recent.anchor, Day.ym(today))
        XCTAssertTrue(recent.isCurrent)
        XCTAssertFalse(recent.steps)
        XCTAssertEqual(recent.stepped(-1), recent)
        let picked = ViewPeriod(unit: .year, day: "2024-01-01", days: .init(from: "2024-11-11", to: "2024-10-03"))
        XCTAssertEqual(picked.span?.0, "2024-10-03")
        XCTAssertEqual(picked.span?.1, "2024-11-11")
        XCTAssertEqual(picked.title, "2024-10-03 至 2024-11-11")
        XCTAssertEqual(picked.anchor, "2024-11")
        XCTAssertFalse(picked.byYear)
        XCTAssertFalse(picked.isCurrent)
        XCTAssertEqual(picked.stepped(1), picked)
        // another unit puts the span away
        XCTAssertNil(picked.showing(.month).days)
        XCTAssertEqual(picked.showing(.month).month, "2024-11")
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
