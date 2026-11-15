import XCTest
@testable import LedgerKit

final class DayGridTests: XCTestCase {
    private func withWeekStart(_ start: Int, _ body: () -> Void) {
        let saved = Day.firstWeekdayOverride
        defer { Day.firstWeekdayOverride = saved }
        Day.firstWeekdayOverride = start
        body()
    }

    func testStringPadsLikeTheFormat() {
        for (y, m, d) in [(2026, 1, 5), (2026, 11, 30), (999, 3, 9), (2000, 12, 31)] {
            let date = Day.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
            XCTAssertEqual(Day.string(date), String(format: "%04d-%02d-%02d", y, m, d))
        }
    }

    func testMonthGridIsTheSixWeeksFromTheWeekStart() {
        for start in 1...7 {
            withWeekStart(start) {
                for month in ["2026-02", "2026-11", "2024-02", "2025-12"] {
                    let first = month + "-01"
                    let offset = Day.daysAfterWeekStart(first)
                    let expected = (0..<42).map { Day.shift(first, $0 - offset) }
                    XCTAssertEqual(Day.monthGrid(month), expected, "\(month) from weekday \(start)")
                    XCTAssertEqual(Day.monthGrid(month).count, 42)
                }
            }
        }
    }

    func testMonthGridOfNonsenseIsEmpty() {
        XCTAssertEqual(Day.monthGrid("nope"), [])
    }

    func testDayLabelFromColumnMatchesTheDate() {
        for start in 1...7 {
            withWeekStart(start) {
                for (column, day) in Day.monthGrid("2026-11").enumerated() {
                    XCTAssertEqual(Day.dayLabel(day, weekday: (start - 1 + column % 7) % 7), Day.dayLabel(day), day)
                }
            }
        }
    }

    func testDaysAfterWeekStart() {
        // 2026-11-15 is a Sunday
        XCTAssertEqual(Day.daysAfterWeekStart("2026-11-15", firstWeekday: 1), 0)
        XCTAssertEqual(Day.daysAfterWeekStart("2026-11-15", firstWeekday: 2), 6)
        XCTAssertEqual(Day.daysAfterWeekStart("2026-11-16", firstWeekday: 2), 0)
    }
}
