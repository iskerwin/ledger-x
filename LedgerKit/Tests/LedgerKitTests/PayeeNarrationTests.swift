import XCTest
@testable import LedgerKit

/// Narration counts on a payee stay in the same order after they are gathered without copying the dictionary
/// on every transaction: most used first, then by the text.
final class PayeeNarrationTests: XCTestCase {
    func testNarrationsStayMostUsedFirst() {
        let text = """
        option "operating_currency" "CNY"
        2026-01-01 open Assets:Bank CNY
        2026-01-01 open Expenses:Food CNY

        2026-03-01 * "食堂" "甲"
          Expenses:Food  1.00 CNY
          Assets:Bank
        2026-03-02 * "食堂" "乙"
          Expenses:Food  1.00 CNY
          Assets:Bank
        2026-03-03 * "食堂" "甲"
          Expenses:Food  1.00 CNY
          Assets:Bank
        2026-03-04 * "食堂" "丙"
          Expenses:Food  1.00 CNY
          Assets:Bank
        2026-03-05 * "食堂" "乙"
          Expenses:Food  1.00 CNY
          Assets:Bank
        2026-03-06 * "食堂" "乙"
          Expenses:Food  1.00 CNY
          Assets:Bank
        2026-03-07 * "食堂" ""
          Expenses:Food  1.00 CNY
          Assets:Bank
        2026-03-08 * "别家" "甲"
          Expenses:Food  2.00 CNY
          Assets:Bank

        """
        let L = loadLedger(root: "main.bean") { _ in text }
        XCTAssertTrue(L.errors.isEmpty, L.errors.map(\.msg).joined(separator: "\n"))
        let d = Derived(L, today: "2026-03-15")
        let canteen = d.payee("食堂")
        XCTAssertEqual(canteen?.n, 7)
        XCTAssertEqual(canteen?.narrations, ["乙", "甲", "丙"])
        XCTAssertEqual(canteen?.narr["乙"], 3)
        XCTAssertEqual(canteen?.narr["甲"], 2)
        XCTAssertEqual(canteen?.narr["丙"], 1)
        // an empty narration is not a suggestion, and the other payee keeps its own
        XCTAssertEqual(d.payee("别家")?.narrations, ["甲"])
        XCTAssertEqual(d.payee("别家")?.n, 1)
        // the same counts a fresh dictionary would have reached
        var ref: [String: [String: Int]] = [:]
        for t in L.txns where !t.payee.isEmpty && !t.narration.isEmpty {
            ref[t.payee, default: [:]][t.narration, default: 0] += 1
        }
        for (name, counts) in ref {
            XCTAssertEqual(d.payee(name)?.narr, counts, name)
        }
    }
}
