import XCTest
@testable import LedgerKit

/// categories each get their own chart colour, and keep it
final class ColorSlotsTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    func testEightCategoriesGetEightDifferentColours() {
        // these four used to land on nearly the same green
        let ids = ["Expenses:Food", "Expenses:Transport", "Expenses:Shopping", "Expenses:Education",
                   "Expenses:Housing", "Expenses:Health", "Expenses:Fun", "Expenses:Travel"]
        XCTAssertEqual(Set(colorSlots(ids, count: 8).values).count, 8)
    }

    func testANinthSharesTheLeastUsedAndNoneBeforeItMoves() {
        let ids = (1...8).map { "Expenses:C\($0)" }
        let before = colorSlots(ids, count: 8)
        let after = colorSlots(ids + ["Expenses:Late"], count: 8)
        for id in ids { XCTAssertEqual(before[id], after[id], id) }
        XCTAssertNotNil(after["Expenses:Late"])
    }

    func testCategoriesKeepTheirColourWhenANewOneIsOpened() {
        let base = """
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Expenses:Food:Dining
        2026-01-01 open Expenses:Transport
        2026-02-01 open Expenses:Shopping
        2026-01-01 open Income:Salary
        2026-03-01 open Expenses:Old
        2026-04-01 close Expenses:Old

        """
        let before = categoryColorSlots(ledger(base), count: 8)
        // opened later, and alphabetically first: it must not take an older one's colour
        let after = categoryColorSlots(ledger(base + "2026-05-01 open Expenses:Art\n"), count: 8)
        for g in ["Expenses:Food", "Expenses:Transport", "Expenses:Shopping", "Income:Salary", "Expenses:Old"] {
            XCTAssertEqual(before[g], after[g], g)
        }
        XCTAssertEqual(Set(after.values).count, 6, "six groups, six colours")
        XCTAssertNil(after["Assets:Bank"])
    }
}
