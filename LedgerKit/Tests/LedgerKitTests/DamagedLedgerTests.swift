import XCTest
@testable import LedgerKit

/// A ledger with a mistake in it: the mistake is reported, the entry is dropped as Beancount drops it, and nothing
/// after it is lost or misread. Expected results are what Beancount itself does with the same text.
final class DamagedLedgerTests: XCTestCase {
    private let accounts = """
    2026-01-01 open Assets:Cash CNY
    2026-01-01 open Expenses:Food CNY

    """

    private func load(_ text: String) -> Ledger {
        loadLedger(root: "main.bean") { _ in self.accounts + text }
    }

    /// Beancount: "day 30 must be in range 1..28 for month 2", the entry is left out, 03-01 is read
    func testADayThatDoesNotExistIsReportedAndLeftOut() {
        let L = load("""
        2026-02-30 * "Shop" "Bad date"
          Expenses:Food   10.00 CNY
          Assets:Cash
        2026-13-01 * "Shop" "Bad month"
          Expenses:Food   20.00 CNY
          Assets:Cash
        2026-03-01 * "Shop" "Fine"
          Expenses:Food   5.00 CNY
          Assets:Cash
        """)
        XCTAssertEqual(L.txns.map(\.date), ["2026-03-01"])
        XCTAssertTrue(L.errors.contains { $0.line == 3 && $0.msg.contains("2026-02-30") })
        XCTAssertTrue(L.errors.contains { $0.line == 6 && $0.msg.contains("2026-13-01") })
        // a real 29 February is a day
        XCTAssertEqual(load("2028-02-29 * \"Leap\"\n  Expenses:Food  1.00 CNY\n  Assets:Cash\n").txns.count, 1)
    }
}
