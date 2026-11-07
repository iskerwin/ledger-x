import XCTest
@testable import LedgerKit

final class RunningBalanceTests: XCTestCase {
    private let ledger = loadLedger(root: "main.bean", listFiles: { ["main.bean"] }) { _ in """
    2025-01-01 open Assets:Bank
    2025-01-01 open Assets:Bank:Sub
    2025-01-01 open Assets:Banker
    2025-01-01 open Expenses:Food
    2025-01-01 open Equity:Opening

    2025-01-02 pad Assets:Bank Equity:Opening
    2025-01-03 balance Assets:Bank 100.00 CNY

    2025-01-04 * "Sample" "First of the day"
      Expenses:Food  10.00 CNY
      Assets:Bank  -10.00 CNY

    2025-01-04 * "Sample" "Second of the day"
      Expenses:Food  5.00 CNY
      Assets:Bank  -5.00 CNY

    2025-01-05 * "Sample" "Similar name"
      Assets:Banker  7.00 CNY
      Expenses:Food  -7.00 CNY

    2025-01-06 * "Sample" "Below"
      Assets:Bank:Sub  3.00 USD
      Expenses:Food  -3.00 USD

    2025-01-07 * "Sample" "Within the account"
      Assets:Bank:Sub  20.00 CNY
      Assets:Bank  -20.00 CNY

    """ }

    private func amounts(_ note: String) -> [String: Double]? {
        let entry = ledger.txns.first { $0.narration == note }!
        return runningBalances(ledger, account: "Assets:Bank")[ObjectIdentifier(entry)]?.amounts
    }

    func testEachEntryShowsWhatTheAccountHoldsAfterIt() {
        XCTAssertEqual(amounts("First of the day"), ["CNY": 90])
        XCTAssertEqual(amounts("Second of the day"), ["CNY": 85])
    }

    func testAPaddedOpeningCounts() {
        let pad = ledger.txns.first { $0.synthetic }!
        XCTAssertEqual(runningBalances(ledger, account: "Assets:Bank")[ObjectIdentifier(pad)]?.amounts, ["CNY": 100])
    }

    func testAccountsBelowCountAndSimilarNamesDoNot() {
        XCTAssertNil(amounts("Similar name"))
        XCTAssertEqual(amounts("Below"), ["CNY": 85, "USD": 3])
    }

    func testMovingWithinTheAccountChangesNothing() {
        XCTAssertEqual(amounts("Within the account"), ["CNY": 85, "USD": 3])
    }

    func testTheLastEntryAgreesWithTheAccountsPage() {
        let held = periodBalances(ledger).filter { isExcluded($0.key, ["Assets:Bank"]) }.values.reduce(Inventory()) { $0 + $1 }
        XCTAssertEqual(amounts("Within the account"), held.amounts)
    }
}
