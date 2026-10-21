import XCTest
@testable import LedgerKit

final class ImportRecoveryTests: XCTestCase {
    func testResumeAfterCommitKeepsChoicesButSkipsAlreadyRecordedRow() throws {
        let L = loadLedger { _ in """
        2025-01-01 open Assets:Bank:Example CNY
        2025-01-01 open Expenses:Food CNY
        2025-02-01 * "Example shop" "Receipt one"
          order: "example-order-one"
          Expenses:Food  20 CNY
          Assets:Bank:Example  -20 CNY
        """ }
        var first = ImportRow(id: 1, date: "2025-02-01")
        first.payee = "Example shop"; first.amount = 20; first.orderID = "example-order-one"
        var second = ImportRow(id: 2, date: "2025-02-02")
        second.payee = "Example shop"; second.amount = 30; second.orderID = "example-order-two"
        let saved = [first, second].map {
            ImportChoice(id: $0.id, include: true, account: "Expenses:Food", funding: "Assets:Bank:Example", manual: true)
        }
        let restored = try JSONDecoder().decode([ImportChoice].self, from: JSONEncoder().encode(saved))
        let resumed = resumeImportChoices(restored, rows: [first, second], ledger: L)
        XCTAssertEqual(resumed.filter(\.include).map(\.id), [2])
        XCTAssertEqual(resumed.map(\.account), saved.map(\.account))
        XCTAssertTrue(resumed.allSatisfy(\.manual))
        var cancelled = second; cancelled.direction = .neutral
        XCTAssertFalse(try XCTUnwrap(resumeImportChoices(restored, rows: [cancelled], ledger: L).first).include)
    }
}
