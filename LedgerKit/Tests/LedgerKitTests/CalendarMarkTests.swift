import XCTest
@testable import LedgerKit

final class CalendarMarkTests: XCTestCase {
    func testEmptyAndInvalidAmountsHaveNoMark() {
        for amount in [0.0, -1, .nan, .infinity] {
            XCTAssertEqual(markLevel(amount: amount, max: 100), 0)
        }
        for maximum in [0.0, -1, .nan, .infinity] {
            XCTAssertEqual(markLevel(amount: 1, max: maximum), 0)
        }
    }

    func testBandsOnBothSidesOfTheirBoundaries() {
        let lower = pow(1.0 / 3, 1.0 / 0.7)
        let upper = pow(2.0 / 3, 1.0 / 0.7)
        XCTAssertEqual(markLevel(amount: 1e-12, max: 1), 1)
        XCTAssertEqual(markLevel(amount: lower - 1e-10, max: 1), 1)
        XCTAssertEqual(markLevel(amount: lower, max: 1), 1)
        XCTAssertEqual(markLevel(amount: lower + 1e-10, max: 1), 2)
        XCTAssertEqual(markLevel(amount: upper - 1e-10, max: 1), 2)
        XCTAssertEqual(markLevel(amount: upper, max: 1), 2)
        XCTAssertEqual(markLevel(amount: upper + 1e-10, max: 1), 3)
        XCTAssertEqual(markLevel(amount: 1, max: 1), 3)
        XCTAssertEqual(markLevel(amount: 2, max: 1), 3)
    }

    func testOneLargeDayAndUniformMonth() {
        XCTAssertEqual([1.0, 10, 1000].map { markLevel(amount: $0, max: 1000) }, [1, 1, 3])
        XCTAssertEqual(Array(repeating: 20.0, count: 31).map { markLevel(amount: $0, max: 20) }, Array(repeating: 3, count: 31))
    }
}
