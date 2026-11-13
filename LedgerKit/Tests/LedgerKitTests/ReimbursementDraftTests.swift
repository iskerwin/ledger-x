import XCTest
@testable import LedgerKit

final class ReimbursementDraftTests: XCTestCase {
    private let base = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank:Demo CNY
    2026-01-01 open Assets:Receivable:Reimbursement CNY
    2026-01-01 open Equity:Opening CNY
    2026-01-01 * "Opening"
      Assets:Bank:Demo  1000.00 CNY
      Equity:Opening  -1000.00 CNY

    """

    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }
    private func draft() -> Draft {
        var d = Draft()
        d.date = "2026-10-17"; d.reimb = true; d.amount = "25"
        d.funding = "Assets:Bank:Demo"; d.payee = "Demo supplier"
        return d
    }

    func testAdvanceNeedsNoExpenseAccount() {
        let L = ledger(base), D = Derived(L)
        let d = draft()
        XCTAssertNil(draftIssue(d, L, D))
        let text = draftText(d, L, D)
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.contains("Expenses:"))
        XCTAssertFalse(text.contains("category:"))
        XCTAssertTrue(checkText(text, L).ok)
        let after = ledger(base + text + "\n")
        let t = after.txns.last!
        XCTAssertEqual(t.postings.first { $0.account == D.receivable }?.units, 25)
        XCTAssertEqual(t.postings.first { $0.account == d.funding }?.units, -25)
        let back = draftFromTxn(t, after, Derived(after), defaultFunding: nil)
        XCTAssertTrue(back.reimb)
        XCTAssertEqual(back.account, "")
        XCTAssertTrue(sameTxn(t, ledger(base + draftText(back, after, Derived(after))).txns.last!))
    }

    func testPettyCashWithoutCategoryKeepsItsLink() {
        let prefix = base + """
        2026-10-01 * "Demo company" "Petty cash" ^float-demo-20261001
          Assets:Bank:Demo  100.00 CNY
          Assets:Receivable:Reimbursement  -100.00 CNY

        """
        let L = ledger(prefix), D = Derived(L)
        var d = draft(); d.link = "float-demo-20261001"; d.voucher = "发票"
        XCTAssertNil(draftIssue(d, L, D))
        let after = ledger(prefix + draftText(d, L, D) + "\n")
        let t = after.txns.last!, derived = Derived(after)
        let back = draftFromTxn(t, after, derived, defaultFunding: nil)
        XCTAssertEqual(back.link, d.link)
        XCTAssertEqual(back.voucher, d.voucher)
        XCTAssertEqual(back.account, "")
        XCTAssertTrue(sameTxn(t, ledger(prefix + draftText(back, after, derived)).txns.last!))
    }

    func testExistingCategorySurvivesEditing() {
        let L = ledger(base + """
        2026-01-01 open Expenses:Travel CNY
        2026-10-17 * "Demo supplier" "Taxi" #reimbursed
          Assets:Receivable:Reimbursement  25.00 CNY
            category: "Expenses:Travel"
          Assets:Bank:Demo  -25.00 CNY

        """)
        let D = Derived(L), t = L.txns.last!
        let back = draftFromTxn(t, L, D, defaultFunding: nil)
        XCTAssertEqual(back.account, "Expenses:Travel")
        XCTAssertTrue(sameTxn(t, ledger(base + draftText(back, L, D)).txns.last!))
    }

    func testPayeeSuggestionDoesNotInventOrReplaceReimbursementCategory() {
        var d = draft()
        d = applyingSuggestedAccounts(d, category: "Expenses:Travel", funding: nil)
        XCTAssertEqual(d.account, "")
        d.account = "Expenses:Legacy"
        d = applyingSuggestedAccounts(d, category: "Expenses:Travel", funding: nil)
        XCTAssertEqual(d.account, "Expenses:Legacy")
    }

    func testNormalExpenseStillRequiresCategoryAndAdvanceStillRequiresFunding() {
        let L = ledger(base), D = Derived(L)
        var d = draft(); d.reimb = false
        XCTAssertEqual(draftIssue(d, L, D)?.field, .category)
        XCTAssertEqual(draftText(d, L, D), "")
        d.reimb = true; d.funding = ""
        XCTAssertEqual(draftIssue(d, L, D)?.field, .funding)
        XCTAssertEqual(draftText(d, L, D), "")
    }
}
