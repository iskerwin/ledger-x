import XCTest
@testable import LedgerKit

/// A refund may also take back the bank fee of the expense: off by default (merchants seldom refund it), and when
/// chosen, the fee category goes back down and the account that paid the fee gets it back.
final class RefundFeeTests: XCTestCase {
    private let ledger = """
    2020-01-01 open Assets:Bank:DemoBank CNY
    2020-01-01 open Assets:Cash CNY
    2020-01-01 open Expenses:Shopping
    2020-01-01 open Expenses:Fee:Bank
    2020-01-01 open Equity:Opening-Balances
    2020-01-02 * "Opening"
      Assets:Bank:DemoBank   10000.00 CNY
      Assets:Cash             1000.00 CNY
      Equity:Opening-Balances

    """

    private func refund(of expense: String) throws -> (Draft, Ledger, Derived) {
        let L = loadLedger(root: "main.bean") { _ in self.ledger + expense }
        XCTAssertTrue(L.errors.isEmpty, L.errors.map(\.msg).joined())
        let D = Derived(L, today: "2026-10-23")
        let t = try XCTUnwrap(L.txns.last)
        return (refundDraft(t, L, D, defaultFunding: nil), L, D)
    }

    private func posting(_ text: String, _ account: String) -> Double? {
        let v = validateText(text, loadLedger(root: "main.bean") { _ in self.ledger })
        return v.txn?.postings.filter { $0.account == account }.compactMap(\.units).reduce(0, +)
    }

    func testAFeeChargedOnTopComesBackToThePayingAccount() throws {
        var (d, L, D) = try refund(of: """
        2026-10-20 * "Demo shop" "lamp"
          fee_mode: "added"
          Expenses:Fee:Bank        5.00 CNY
          Expenses:Shopping      200.00 CNY
          Assets:Bank:DemoBank  -205.00 CNY
        """)
        XCTAssertEqual(d.refundFee, RefundFee(amount: 5, currency: "CNY", account: "Assets:Bank:DemoBank"))
        let off = draftText(d, L, D)
        XCTAssertTrue(validateText(off, L).ok, off)
        XCTAssertNil(off.range(of: "Expenses:Fee:Bank"))
        XCTAssertEqual(posting(off, "Assets:Bank:DemoBank"), 200)

        d.refundFee?.on = true
        let on = draftText(d, L, D)
        XCTAssertTrue(validateText(on, L).ok, on)
        XCTAssertEqual(posting(on, "Expenses:Fee:Bank"), -5)
        XCTAssertEqual(posting(on, "Expenses:Shopping"), -200)
        XCTAssertEqual(posting(on, "Assets:Bank:DemoBank"), 205)
    }

    func testAFeePaidFromAnotherAccountGoesBackThere() throws {
        var (d, L, D) = try refund(of: """
        2026-10-20 * "Demo shop" "lamp"
          fee_mode: "separate"
          fee_account: "Assets:Cash"
          Expenses:Fee:Bank        3.00 CNY
          Expenses:Shopping      200.00 CNY
          Assets:Bank:DemoBank  -200.00 CNY
          Assets:Cash             -3.00 CNY
        """)
        XCTAssertEqual(d.refundFee?.account, "Assets:Cash")
        d.refundFee?.on = true
        let on = draftText(d, L, D)
        XCTAssertTrue(validateText(on, L).ok, on)
        XCTAssertEqual(posting(on, "Assets:Bank:DemoBank"), 200)
        XCTAssertEqual(posting(on, "Assets:Cash"), 3)
        XCTAssertEqual(posting(on, "Expenses:Fee:Bank"), -3)
    }

    func testAnExpenseWithoutAFeeOffersNothing() throws {
        let (d, _, _) = try refund(of: """
        2026-10-20 * "Demo shop" "lamp"
          Expenses:Shopping      200.00 CNY
          Assets:Bank:DemoBank  -200.00 CNY
        """)
        XCTAssertNil(d.refundFee)
    }
}
