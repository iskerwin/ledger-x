import XCTest
@testable import LedgerKit

/// accounts with a statement / check day come up for a check once the day has passed
final class ReconcileTests: XCTestCase {
    private func ledger(_ text: String) -> Ledger { loadLedger(root: "main.bean") { _ in text } }

    private let base = """
    option "operating_currency" "CNY"
    2026-01-01 open Assets:Bank:BOC CNY
      statement_day: 10
    2026-01-01 open Assets:Cash
    2026-01-01 open Assets:Wallet CNY
    2026-01-01 open Liabilities:CreditCard:CMB CNY
      statement_day: 15
    2026-01-01 open Expenses:Food CNY
    2026-01-01 open Equity:Opening

    2026-01-02 * "Opening"
      Assets:Bank:BOC  500.00 CNY
      Assets:Cash  100 CNY
      Equity:Opening

    2026-10-09 * "Lunch"
      Expenses:Food  20.00 CNY
      Assets:Bank:BOC

    2026-10-10 * "Dinner"
      Expenses:Food  30.00 CNY
      Assets:Bank:BOC

    2026-10-11 * "Coffee"
      Expenses:Food  15.00 CNY
      Assets:Bank:BOC

    2026-10-12 * "Card"
      Expenses:Food  88.00 CNY
      Liabilities:CreditCard:CMB

    """

    func testDue() {
        let L = ledger(base)
        let due = reconcileDue(L, today: "2026-10-12")
        // only accounts with a day; the card's day (15th) last came on 09-15, before any spending
        XCTAssertEqual(due.map { $0.account }, ["Assets:Bank:BOC", "Liabilities:CreditCard:CMB"])
        let boc = due[0]
        XCTAssertEqual(boc.day, "2026-10-10")
        XCTAssertEqual(boc.date, "2026-10-10")
        XCTAssertEqual(boc.ledger, 480)     // start of the 10th: the 10th's dinner and later are after it
        XCTAssertEqual(boc.now, 435)        // what the bank app should show today
        XCTAssertEqual(boc.since, 2)
        XCTAssertEqual(boc.sinceTotal, -45)
        XCTAssertEqual(due[1].day, "2026-09-15")
        XCTAssertEqual(due[1].ledger, 0)
        XCTAssertEqual(due[1].now, -88)
        XCTAssertNil(boc.lastChecked)
    }

    func testDueOnTheDayItself() {
        // the day's assertion checks the balance the previous day ended with: final by the morning
        let due = reconcileDue(ledger(base), today: "2026-10-10").first { $0.account == "Assets:Bank:BOC" }
        XCTAssertEqual(due?.day, "2026-10-10")
        XCTAssertEqual(due?.ledger, 480)
        // never in the future
        for t in ["2026-10-09", "2026-10-10", "2026-10-11", "2026-10-31", "2026-11-01"] {
            XCTAssertTrue(reconcileDue(ledger(base), today: t).allSatisfy { $0.date <= t }, t)
        }
    }

    func testCheckedOnce() {
        // the check's assertion (or any later one) settles it until the next day comes round
        let checked = ledger(base + "2026-10-10 balance Assets:Bank:BOC 480.00 CNY\n")
        XCTAssertTrue(checked.balanceResults.allSatisfy { $0.ok })
        XCTAssertFalse(reconcileDue(checked, today: "2026-10-20").contains { $0.account == "Assets:Bank:BOC" })
        let next = reconcileDue(checked, today: "2026-11-10").first { $0.account == "Assets:Bank:BOC" }
        XCTAssertEqual(next?.day, "2026-11-10")
        XCTAssertEqual(next?.lastChecked, "2026-10-10")
        XCTAssertEqual(next?.ledger, 435)
        let op = reconcileOp(next!, amount: 435, path: "accounts/balance.bean")
        XCTAssertEqual(op.date, "2026-11-10")
        XCTAssertTrue(op.line?.hasPrefix("2026-11-10 balance Assets:Bank:BOC") ?? false)
        XCTAssertTrue(op.line?.hasSuffix("435.00 CNY") ?? false)
    }

    func testFutureEntriesLeftOut() {
        // something entered ahead of time isn't in the bank's balance yet
        let L = ledger(base + "2026-10-20 * \"Rent\"\n  Expenses:Food  100.00 CNY\n  Assets:Bank:BOC\n")
        XCTAssertEqual(reconcileDue(L, today: "2026-10-12").first?.now, 435)
    }

    func testOpenedAfterTheDay() {
        let L = ledger(base + "2026-10-10 open Assets:Bank:New CNY\n  statement_day: 10\n")
        XCTAssertFalse(reconcileDue(L, today: "2026-10-12").contains { $0.account == "Assets:Bank:New" })
    }
}
