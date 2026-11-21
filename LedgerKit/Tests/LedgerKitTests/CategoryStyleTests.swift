import XCTest
@testable import LedgerKit

/// The category grid's style lives in ledger-x.json, so the phone and the Mac show the same icons, names, colours,
/// order and hidden groups.
final class CategoryStyleTests: XCTestCase {
    func testTheStyleGoesThroughTheFileWholeAndInOrder() throws {
        var c = LedgerXConfig()
        c.editCategories { s in
            s.setIcon("Expenses:Food", "fork.knife")
            s.setTitle("Expenses:Food", " 吃饭 ")
            s.setColor("Assets:Bank", "purple")
            s.setHidden("Expenses:Misc", true)
            // an order by hand is not sorted when written
            s.setOrder("Expenses:", ["Expenses:Transport", "Expenses:Food", "Expenses:Misc", "Expenses:Food"])
        }
        let back = try XCTUnwrap(LedgerXConfig.parse(c.json()))
        XCTAssertEqual(back, c)
        let s = try XCTUnwrap(back.categories)
        XCTAssertEqual(s.order["Expenses:"], ["Expenses:Transport", "Expenses:Food", "Expenses:Misc"])
        XCTAssertEqual(s.titles["Expenses:Food"], "吃饭")
        XCTAssertEqual(s.colors["Assets:Bank"], "purple")
        XCTAssertEqual(s.hidden, ["Expenses:Misc"])
        XCTAssertTrue(c.json().contains(#""categories" : {"#))
    }

    func testTwoChangesToDifferentGroupsBothStay() {
        // each is applied to the file as the change before it left it (another device's included)
        var c = LedgerXConfig()
        c.editCategories { $0.setIcon("Expenses:Food", "fork.knife") }
        c.editCategories { $0.setColor("Expenses:Transport", "blue") }
        c.editCategories { $0.setHidden("Expenses:Food", true) }
        XCTAssertEqual(c.categories?.icons, ["Expenses:Food": "fork.knife"])
        XCTAssertEqual(c.categories?.colors, ["Expenses:Transport": "blue"])
        XCTAssertEqual(c.categories?.hidden, ["Expenses:Food"])
    }

    func testDefaultsAgainLeaveNoKey() {
        var c = LedgerXConfig()
        c.editCategories { $0.setIcon("Expenses:Food", "fork.knife"); $0.setHidden("Expenses:Food", true) }
        c.editCategories { $0.resetIconsAndNames(["Expenses:Food"]) }
        XCTAssertNil(c.categories)
        c.editCategories { $0.setTitle("Expenses:Food", "  "); $0.setColor("Expenses:Food", nil); $0.setIcon("Expenses:Food", "") }
        XCTAssertNil(c.categories)
        XCTAssertFalse(c.json().contains("categories"))
    }

    func testAFileWithoutOrWithABrokenStyleStillLoads() throws {
        XCTAssertNil(try XCTUnwrap(LedgerXConfig.parse(#"{"main": "main.bean"}"#)).categories)
        let broken = try XCTUnwrap(LedgerXConfig.parse(#"{"main": "a.bean", "categories": "nonsense"}"#))
        XCTAssertEqual(broken.main, "a.bean")
        XCTAssertNil(broken.categories)
        // a part missing or of the wrong kind: the others still read
        let some = try XCTUnwrap(LedgerXConfig.parse(#"{"categories": {"icons": {"Expenses:Food": "cart"}, "hidden": 3}}"#))
        XCTAssertEqual(some.categories?.icons, ["Expenses:Food": "cart"])
        XCTAssertEqual(some.categories?.hidden, [])
        // what the phone kept before colours existed
        let old = #"{"icons":{"Expenses:Food":"cup.and.saucer"},"titles":{"Expenses:Food":"Coffee"},"order":{},"hidden":[]}"#
        let s = try JSONDecoder().decode(CategoryStyle.self, from: Data(old.utf8))
        XCTAssertEqual(s.icons["Expenses:Food"], "cup.and.saucer")
        XCTAssertEqual(s.colors, [:])
    }

    func testAStyleKeptForSeveralLedgersTakesOnlyThisOnesGroups() {
        var s = CategoryStyle()
        s.icons = ["Expenses:Food:Coffee": "cup.and.saucer", "Expenses:Pets": "pawprint"]
        s.titles = ["Expenses:Food": "吃", "Income:Other": "别的"]
        s.colors = ["Assets:Bank": "purple", "Assets:Broker": "green"]
        s.hidden = ["Expenses:Pets", "Expenses:Food"]
        s.order = ["Expenses:": ["Expenses:Pets", "Expenses:Food"], "Income:": ["Income:Other"]]
        let kept = s.normalized().kept(for: ["Expenses:Food:Coffee", "Expenses:Food:Lunch", "Assets:Bank:Example"])
        // an icon kept under a lone account moves to its group
        XCTAssertEqual(kept.icons, ["Expenses:Food": "cup.and.saucer"])
        XCTAssertEqual(kept.titles, ["Expenses:Food": "吃"])
        XCTAssertEqual(kept.colors, ["Assets:Bank": "purple"])
        XCTAssertEqual(kept.hidden, ["Expenses:Food"])
        XCTAssertEqual(kept.order, ["Expenses:": ["Expenses:Food"]])
        XCTAssertTrue(s.kept(for: ["Expenses:Travel:Hotel"]).isEmpty)
    }

    func testThePhonesStyleGoesIntoALedgerOnceAndNeverOverAnother() {
        var local = CategoryStyle()
        local.icons = ["Expenses:Food": "fork.knife", "Expenses:Pets": "pawprint"]
        var c = LedgerXConfig()
        c.takeLocalCategories(local, accounts: ["Expenses:Food:Lunch"])
        XCTAssertEqual(c.categories?.icons, ["Expenses:Food": "fork.knife"])
        // a style already in the file (written by another device) stays as it is
        var other = LedgerXConfig()
        other.editCategories { $0.setIcon("Expenses:Food", "cart") }
        other.takeLocalCategories(local, accounts: ["Expenses:Food:Lunch"])
        XCTAssertEqual(other.categories?.icons, ["Expenses:Food": "cart"])
        // nothing of this ledger's: nothing written
        var none = LedgerXConfig()
        none.takeLocalCategories(local, accounts: ["Expenses:Travel"])
        XCTAssertNil(none.categories)
    }

    func testTheStyleFollowsARenameOrMerge() throws {
        var c = LedgerXConfig()
        c.editCategories { s in
            s.setIcon("Expenses:Food", "fork.knife")
            s.setColor("Expenses:Food", "orange")
            s.setTitle("Expenses:Food", "吃")
            s.setHidden("Expenses:Food", true)
            s.setOrder("Expenses:", ["Expenses:Food", "Expenses:Dining", "Expenses:Transport"])
        }
        let moved = try XCTUnwrap(c.renamingAccount("Expenses:Food", to: "Expenses:Dining")).categories
        XCTAssertEqual(moved?.icons, ["Expenses:Dining": "fork.knife"])
        XCTAssertEqual(moved?.colors, ["Expenses:Dining": "orange"])
        XCTAssertEqual(moved?.titles, ["Expenses:Dining": "吃"])
        XCTAssertEqual(moved?.hidden, ["Expenses:Dining"])
        XCTAssertEqual(moved?.order["Expenses:"], ["Expenses:Dining", "Expenses:Transport"], "a merge keeps one place")
        XCTAssertNil(c.renamingAccount("Expenses:Travel", to: "Expenses:Trips"))
    }
}
