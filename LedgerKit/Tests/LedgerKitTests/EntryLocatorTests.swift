import XCTest
@testable import LedgerKit

final class EntryLocatorTests: XCTestCase {
    private let transaction = """
    2026-10-17 * "Shop" "Coffee"
      Expenses:Food  12.00 CNY
      Assets:Bank
    """

    func testFollowsSourceWhenLinesShiftButRejectsChangedOrDeletedEntry() throws {
        let original = try XCTUnwrap(parseFile(transaction, file: "journal.bean").entries.first)
        let locator = EntryLocator(original)
        XCTAssertEqual(locator.text(in: "; added above\n\n" + transaction), transaction)
        XCTAssertNil(locator.text(in: transaction.replacingOccurrences(of: "12.00", with: "20.00")))
        XCTAssertNil(locator.text(in: "2026-10-17 note Assets:Bank \"replacement\""))
        XCTAssertNil(locator.text(in: ""))
    }

    func testDuplicateSourceAndOtherFileAreNotGuessed() throws {
        let original = try XCTUnwrap(parseFile(transaction, file: "journal.bean").entries.first)
        let locator = EntryLocator(original)
        XCTAssertNil(locator.text(in: transaction + "\n\n" + transaction))
        XCTAssertNil(locator.resolve(in: parseFile(transaction, file: "other.bean").entries))
        original.synthetic = true
        XCTAssertNil(EntryLocator(original).text(in: transaction))
    }

    func testDirectiveIncludesMetadataAndDoesNotMatchSimilarAssertion() throws {
        let assertion = "2026-10-18 balance Assets:Bank 100.00 CNY\n  note: \"bank checked\""
        let original = try XCTUnwrap(parseFile(assertion, file: "balances.bean").entries.first)
        let locator = EntryLocator(original)
        let other = "2026-10-18 balance Assets:Bank 200.00 CNY"
        XCTAssertEqual(locator.text(in: other + "\n\n" + assertion), assertion)
        XCTAssertNil(locator.text(in: other))
        XCTAssertNil(locator.text(in: assertion.replacingOccurrences(of: "bank checked", with: "changed")))
    }

    func testDocumentRemovalLeavesAttachmentAndOtherEntriesAlone() throws {
        let document = "2026-10-17 document Assets:Bank \"documents/statement.pdf\""
        let file = document + "\n\n" + transaction
        let original = try XCTUnwrap(parseFile(file, file: "journal.bean").entries.first)
        let old = try XCTUnwrap(EntryLocator(original).text(in: file))
        var op = Op(kind: .remove, path: "journal.bean")
        op.old = old
        let edited = try applyOps(file, path: "journal.bean", ops: [op])
        XCTAssertEqual(parseFile(edited, file: "journal.bean").entries.map(\.type), [.txn])
        XCTAssertTrue(edited.contains(transaction))
        XCTAssertEqual(op.kind, .remove, "Removing a document directive never creates a deleteFile operation")
    }
}
