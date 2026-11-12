import XCTest
@testable import LedgerKit

/// a payee or a note picked fills in the category and paying account from history, and leaves what was picked by hand
final class NarrationFillTests: XCTestCase {
    private let text = """
    2025-01-01 open Assets:Bank CNY
    2025-01-01 open Assets:Card CNY
    2025-01-01 open Assets:Cash CNY
    2025-01-01 open Expenses:Food CNY
    2025-01-01 open Expenses:Snacks CNY
    2025-01-01 open Expenses:Transit CNY

    2026-10-01 * "Cafe" "Lunch set"
      Expenses:Food  30.00 CNY
      Assets:Card  -30.00 CNY

    2026-10-02 * "Cafe" "Cookies"
      Expenses:Snacks  8.00 CNY
      Assets:Cash  -8.00 CNY

    2026-10-03 * "Metro" "Monthly pass"
      Expenses:Transit  100.00 CNY
      Assets:Bank  -100.00 CNY

    2026-10-04 * "Bakery" "Lunch set"
      Expenses:Snacks  25.00 CNY
      Assets:Cash  -25.00 CNY

    """

    private lazy var derived = Derived(loadLedger(root: "main.bean") { _ in self.text }, today: "2026-10-05")

    /// a new form: the paying account kept from the last entry saved, nothing picked here yet
    private func newForm() -> Draft {
        var d = Draft()
        d.kind = .expense
        d.funding = "Assets:Bank"
        return d
    }

    private func picked(_ d: Draft, category: String? = nil, funding: String? = nil) -> Draft {
        var d = d
        var selection = d.selection ?? DraftSelection()
        if let category { d.account = category; selection.category = true }
        if let funding { d.funding = funding; selection.funding = true }
        d.selection = selection
        return d
    }

    func testANotePickedFillsFromTheLastEntryWithIt() {
        let d = applyingNarration(newForm(), text: "Monthly pass", derived)
        XCTAssertEqual(d.narration, "Monthly pass")
        XCTAssertEqual(d.account, "Expenses:Transit")
        XCTAssertEqual(d.funding, "Assets:Bank")
    }

    func testWithAKnownPayeeTheNoteFillsFromThatPayeesEntry() {
        var d = applyingPayee(newForm(), name: "Cafe", derived)
        XCTAssertEqual(d.account, "Expenses:Snacks", "the payee's last entry")
        d = applyingNarration(d, text: "Lunch set", derived)
        XCTAssertEqual(d.account, "Expenses:Food", "Cafe's lunch, not the bakery's")
        XCTAssertEqual(d.funding, "Assets:Card")
    }

    func testANoteThePayeeNeverHadLeavesWhatThePayeeFilledIn() {
        let payee = applyingPayee(newForm(), name: "Metro", derived)
        let d = applyingNarration(payee, text: "Cookies", derived)
        XCTAssertEqual(d.account, payee.account)
        XCTAssertEqual(d.funding, payee.funding)
    }

    func testWhatWasPickedByHandStaysWhenAPayeeOrANoteIsPickedAfter() {
        let mine = picked(newForm(), category: "Expenses:Food", funding: "Assets:Bank")
        for d in [applyingPayee(mine, name: "Metro", derived), applyingNarration(mine, text: "Cookies", derived),
                  applyingNarration(applyingPayee(mine, name: "Cafe", derived), text: "Cookies", derived)] {
            XCTAssertEqual(d.account, "Expenses:Food")
            XCTAssertEqual(d.funding, "Assets:Bank")
        }
        let category = applyingNarration(picked(newForm(), category: "Expenses:Food"), text: "Cookies", derived)
        XCTAssertEqual(category.account, "Expenses:Food")
        XCTAssertEqual(category.funding, "Assets:Cash", "the account not picked here still follows the note")
    }

    func testTypedAndLeftOnlyFillsWhatIsBlank() {
        var d = newForm()
        d.account = "Expenses:Food"
        d = applyingNarration(d, text: "Monthly pass", derived, onlyBlanks: true)
        XCTAssertEqual(d.account, "Expenses:Food")
        XCTAssertEqual(d.funding, "Assets:Bank")
    }

    func testNotesAreOfferedLooselyThePayeesOwnFirst() {
        XCTAssertEqual(narrationSuggestions(derived, typed: "", payee: "Cafe", limit: 10).prefix(2).sorted(), ["Cookies", "Lunch set"])
        XCTAssertEqual(Set(narrationSuggestions(derived, typed: "", payee: "", limit: 10)), ["Lunch set", "Cookies", "Monthly pass"])
        XCTAssertEqual(narrationSuggestions(derived, typed: "mp", payee: "", limit: 10), ["Monthly pass"], "letters in order")
        XCTAssertEqual(narrationSuggestions(derived, typed: "lunch", payee: "", limit: 10), ["Lunch set"])
        XCTAssertEqual(narrationSuggestions(derived, typed: "set", payee: "Metro", limit: 10).first, "Lunch set", "held whole before spread through")
        XCTAssertEqual(narrationSuggestions(derived, typed: "", payee: "", limit: 2).count, 2)
    }

    /// whole beats spread; case is ignored; Chinese and mixed text alike
    func testFuzzyFindsWholeThenSpreadMatches() {
        XCTAssertEqual(fuzzy("", "午饭"), 2)
        XCTAssertEqual(fuzzy("午饭", "公司午饭 AA"), 2)
        XCTAssertEqual(fuzzy("Coffee", "morning COFFEE"), 2)
        XCTAssertEqual(fuzzy("公饭", "公司午饭"), 1)
        XCTAssertEqual(fuzzy("mc", "Morning coffee"), 1)
        XCTAssertEqual(fuzzy("饭午", "公司午饭"), 0)
        XCTAssertEqual(fuzzy("午饭晚饭", "午饭"), 0)
    }

}
