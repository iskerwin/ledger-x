import XCTest
@testable import LedgerKit

final class CopyDraftTests: XCTestCase {
    func testExpenseIncomeAndUntaggedTransferKeepPartyAndDescription() throws {
        let L = loadLedger { _ in """
        2025-01-01 open Assets:Bank:Example CNY
        2025-01-01 open Assets:Cash CNY
        2025-01-01 open Expenses:Food CNY
        2025-01-01 open Income:Salary CNY
        2025-02-01 * "Example Shop" "Lunch note"
          Expenses:Food  20 CNY
          Assets:Cash  -20 CNY
        2025-02-02 * "Example Employer" "Pay note"
          Assets:Bank:Example  200 CNY
          Income:Salary  -200 CNY
        2025-02-03 * "Example Route" "Transfer note"
          Assets:Cash  30 CNY
          Assets:Bank:Example  -30 CNY
        """ }
        let D = Derived(L)
        for original in L.txns {
            let d = draftFromTxn(original, L, D, defaultFunding: nil)
            XCTAssertEqual(d.payee, original.payee)
            XCTAssertEqual(d.narration, original.narration)
            XCTAssertNil(d.replacing)
            let regenerated = try XCTUnwrap(validateText(draftText(d, L, D), L).txn)
            XCTAssertEqual(regenerated.payee, original.payee)
            XCTAssertEqual(regenerated.narration, original.narration)
        }
    }
}
