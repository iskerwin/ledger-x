import XCTest
import SwiftUI
@testable import Ledger

/// Under a calendar day only the dots there are get drawn, so the row is centred under the date whether it holds
/// one dot or two; a day with spending only used to keep an empty slot for income and sit left of centre.
@MainActor
final class CalendarDotsTests: XCTestCase {
    /// a dynamic colour is a new value each time it is asked for: compare what it draws
    private func colors(_ m: DayMark, themeMarks: Bool = false) -> [Color.Resolved] {
        m.dots(themeMarks: themeMarks).map { $0.color.resolve(in: EnvironmentValues()) }
    }
    private func drawn(_ c: [Color]) -> [Color.Resolved] { c.map { $0.resolve(in: EnvironmentValues()) } }

    func testOnlyTheDotsThereAreDrawn() {
        XCTAssertEqual(colors(DayMark(out: 2)), drawn([.loss]))
        XCTAssertEqual(colors(DayMark(inn: 3)), drawn([.gain]))
        XCTAssertEqual(colors(DayMark(out: 1, inn: 3)), drawn([.loss, .gain]))
        XCTAssertEqual(DayMark(out: 1, inn: 3).dots(themeMarks: false).map(\.level), [1, 3])
        XCTAssertEqual(colors(DayMark(other: true)), drawn([.secondary]))
        XCTAssertEqual(DayMark(out: 1, other: true).dots(themeMarks: false).count, 1)
        XCTAssertEqual(colors(DayMark(out: 2, inn: 2), themeMarks: true), drawn([.jade]))
        XCTAssertTrue(DayMark().dots(themeMarks: false).isEmpty)
    }
}
