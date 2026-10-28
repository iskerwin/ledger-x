import XCTest
import SwiftUI
@testable import Ledger

/// Under a calendar day only the dots there are get drawn, so the row is centred under the date whether it holds
/// one dot or two; a day with spending only used to keep an empty slot for income and sit left of centre.
final class CalendarDotsTests: XCTestCase {
    func testOnlyTheDotsThereAreDrawn() {
        XCTAssertEqual(DayMark(out: 2).dots(themeMarks: false).map(\.color), [.loss])
        XCTAssertEqual(DayMark(inn: 3).dots(themeMarks: false).map(\.color), [.gain])
        XCTAssertEqual(DayMark(out: 1, inn: 3).dots(themeMarks: false).map(\.color), [.loss, .gain])
        XCTAssertEqual(DayMark(out: 1, inn: 3).dots(themeMarks: false).map(\.level), [1, 3])
        XCTAssertEqual(DayMark(other: true).dots(themeMarks: false).map(\.color), [.secondary])
        XCTAssertEqual(DayMark(out: 1, other: true).dots(themeMarks: false).count, 1)
        XCTAssertEqual(DayMark(out: 2, inn: 2).dots(themeMarks: true).map(\.color), [.jade])
        XCTAssertTrue(DayMark().dots(themeMarks: false).isEmpty)
    }
}
