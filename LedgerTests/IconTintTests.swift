import XCTest
import SwiftUI
@testable import Ledger

/// A group's icon can take a colour of one's own, used wherever its icon is drawn. (How the style reads back from
/// ledger-x.json, and from what this phone kept before colours existed: LedgerKit's CategoryStyleTests.)
@MainActor
final class IconTintTests: XCTestCase {
    private func drawn(_ c: Color) -> Color.Resolved { c.resolve(in: EnvironmentValues()) }

    func testTheColourPickedIsUsedAndFollowsARename() {
        let store = Store()
        // a ledger that hasn't taken this phone's style yet shows it
        let moved = store.pk("catStyle.moved")
        let wasMoved = Prefs.get(moved, false)
        let saved = store.localCatStyle
        defer { store.localCatStyle = saved; Prefs.set(moved, wasMoved) }
        Prefs.set(moved, false)
        var s = saved
        s.setColor("Assets:Bank", "purple")
        s.setColor("Expenses:Food", "orange")
        store.localCatStyle = s
        XCTAssertEqual(drawn(store.groupIcon("Assets:Bank:Example").color), drawn(.purple))
        XCTAssertEqual(drawn(store.groupIcon("Expenses:Food:Coffee").color), drawn(.orange))
        // the others keep their own: the theme's for categories, the kind's for accounts
        XCTAssertEqual(drawn(store.groupIcon("Expenses:Transport").color), drawn(.jade))
        XCTAssertEqual(drawn(store.groupIcon("Liabilities:CreditCard:Example").color), drawn(AccountKind.of("Liabilities:CreditCard").color))
        // the Add card's 付款账户 cell takes the picked colour; without one it keeps the theme's
        XCTAssertEqual(store.pickedTint("Assets:Bank:Example").map(drawn), drawn(.purple))
        XCTAssertNil(store.pickedTint("Liabilities:CreditCard:Example"))
        store.renameInGrid("Expenses:Food", to: "Expenses:Dining")
        XCTAssertEqual(store.catStyle.colors["Expenses:Dining"], "orange")
        XCTAssertNil(store.catStyle.colors["Expenses:Food"])
    }
}
