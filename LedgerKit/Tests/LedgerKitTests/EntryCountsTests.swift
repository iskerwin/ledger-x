import XCTest
@testable import LedgerKit

final class EntryCountsTests: XCTestCase {
    private let ledger = loadLedger(root: "main.bean", listFiles: { ["main.bean"] }) { _ in """
    2025-01-01 open Assets:Bank CNY
    2025-01-01 open Expenses:Food CNY
    2025-01-01 open Expenses:Food:Lunch CNY
    2025-01-01 open Expenses:Foodie CNY

    2026-09-30 * "Sample" "Before"
      Expenses:Food  1.00 CNY
      Assets:Bank  -1.00 CNY

    2026-10-01 * "Sample" "First day"
      Expenses:Food  2.00 CNY
      Assets:Bank  -2.00 CNY

    2026-10-15 * "Sample" "Below"
      Expenses:Food:Lunch  4.00 CNY
      Assets:Bank  -4.00 CNY

    2026-10-16 * "Sample" "Similar name"
      Expenses:Foodie  8.00 CNY
      Assets:Bank  -8.00 CNY

    2026-10-31 * "Sample" "Last day"
      Expenses:Food  16.00 CNY
      Assets:Bank  -16.00 CNY

    2026-11-01 * "Sample" "After"
      Expenses:Food  32.00 CNY
      Assets:Bank  -32.00 CNY

    """ }

    private func notes(_ account: String, from: String? = nil, to: String? = nil) -> [String] {
        ledger.txns.filter { entryCounts($0, for: account, from: from, to: to) }.map(\.narration)
    }

    func testAnAccountCountsItselfAndWhatIsUnderItNotASimilarName() {
        XCTAssertEqual(notes("Expenses:Food"), ["Before", "First day", "Below", "Last day", "After"])
        XCTAssertEqual(notes("Expenses:Food:Lunch"), ["Below"])
        XCTAssertEqual(notes("Expenses:Foodie"), ["Similar name"])
    }

    func testBothEndsOfThePeriodCount() {
        XCTAssertEqual(notes("Expenses:Food", from: "2026-10-01", to: "2026-10-31"), ["First day", "Below", "Last day"])
    }

    func testTheEntriesAddUpToTheReportsNumber() throws {
        let report = incomeStatement(ledger, from: "2026-10-01", to: "2026-10-31")
        let node = try XCTUnwrap(report.expenses.children.first { $0.name == "Expenses:Food" })
        let sum = ledger.txns.filter { entryCounts($0, for: node.name, from: "2026-10-01", to: "2026-10-31") }
            .flatMap(\.postings).filter { isExcluded($0.account, [node.name]) }.compactMap(\.units).reduce(0, +)
        XCTAssertEqual(sum, node.total, accuracy: 0.001)
        XCTAssertEqual(sum, 22, accuracy: 0.001)
    }
}
