import XCTest
import SwiftUI
@testable import Ledger

/// A group's icon can take a colour of one's own, used wherever its icon is drawn; the grid style saved before
/// colours existed still reads back whole.
@MainActor
final class IconTintTests: XCTestCase {
    private func drawn(_ c: Color) -> Color.Resolved { c.resolve(in: EnvironmentValues()) }

    func testAStyleSavedBeforeColoursKeepsItsIcons() throws {
        let old = #"{"icons":{"Expenses:Food":"cup.and.saucer"},"titles":{"Expenses:Food":"Coffee"},"order":{},"hidden":[]}"#
        let s = try JSONDecoder().decode(CatStyle.self, from: Data(old.utf8))
        XCTAssertEqual(s.icons["Expenses:Food"], "cup.and.saucer")
        XCTAssertEqual(s.titles["Expenses:Food"], "Coffee")
        XCTAssertNil(s.colors)
    }

    func testTheColourPickedIsUsedAndFollowsARename() {
        let store = Store()
        let saved = store.catStyle
        defer { store.catStyle = saved }
        var s = saved
        s.colors = tinted(nil, "Assets:Bank", "purple")
        s.colors = tinted(s.colors, "Expenses:Food", "orange")
        store.catStyle = s
        XCTAssertEqual(drawn(store.groupIcon("Assets:Bank:Example").color), drawn(.purple))
        XCTAssertEqual(drawn(store.groupIcon("Expenses:Food:Coffee").color), drawn(.orange))
        // the others keep their own: the theme's for categories, the kind's for accounts
        XCTAssertEqual(drawn(store.groupIcon("Expenses:Transport").color), drawn(.jade))
        XCTAssertEqual(drawn(store.groupIcon("Liabilities:CreditCard:Example").color), drawn(AccountKind.of("Liabilities:CreditCard").color))
        store.renameInGrid("Expenses:Food", to: "Expenses:Dining")
        XCTAssertEqual(store.catStyle.colors?["Expenses:Dining"], "orange")
        XCTAssertNil(store.catStyle.colors?["Expenses:Food"])
        // 默认 again: nothing kept once none is left
        XCTAssertNil(tinted(["Assets:Bank": "purple"], "Assets:Bank", nil))
    }
}
